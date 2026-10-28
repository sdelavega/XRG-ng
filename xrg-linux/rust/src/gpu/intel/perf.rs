// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Counting-only perf ABI; no sampling buffers, helpers or privilege changes.
use super::discovery::{Event, Spec};
#[derive(Clone, Copy, Debug)]
pub(super) struct Reading {
    pub value: u64,
    pub enabled: u64,
    pub running: u64,
}
pub(super) trait Counter: Send {
    fn read(&mut self) -> Result<Reading, String>;
}
pub(super) trait Open {
    fn open(&mut self, spec: &Spec, event: &Event) -> Result<Box<dyn Counter>, String>;
}
#[derive(Default)]
pub(super) struct Native;
#[cfg(any(target_os = "linux", test))]
#[repr(C)]
#[derive(Default)]
struct Attr {
    kind: u32,
    size: u32,
    config: u64,
    sample_period: u64,
    sample_type: u64,
    read_format: u64,
    flags: u64,
    wakeup_events: u32,
    bp_type: u32,
    config1: u64,
}
#[cfg(target_os = "linux")]
struct Handle(std::os::fd::OwnedFd);
#[cfg(target_os = "linux")]
impl Counter for Handle {
    fn read(&mut self) -> Result<Reading, String> {
        use std::os::fd::AsRawFd;
        let mut bytes = [0u8; 24];
        let mut interrupted = 0;
        loop {
            let count =
                unsafe { libc::read(self.0.as_raw_fd(), bytes.as_mut_ptr().cast(), bytes.len()) };
            if count == 24 {
                return decode(&bytes);
            }
            let error = std::io::Error::last_os_error();
            if count < 0 && error.kind() == std::io::ErrorKind::Interrupted && interrupted < 3 {
                interrupted += 1;
                continue;
            }
            return Err(if count < 0 {
                format!("Read i915 PMU: {error}")
            } else {
                "Short i915 PMU counter read".into()
            });
        }
    }
}
#[cfg(any(target_os = "linux", test))]
fn decode(bytes: &[u8]) -> Result<Reading, String> {
    let bytes = <&[u8; 24]>::try_from(bytes).map_err(|_| "Invalid PMU record size")?;
    Ok(Reading {
        value: u64::from_ne_bytes(bytes[0..8].try_into().unwrap()),
        enabled: u64::from_ne_bytes(bytes[8..16].try_into().unwrap()),
        running: u64::from_ne_bytes(bytes[16..24].try_into().unwrap()),
    })
}
impl Open for Native {
    fn open(&mut self, spec: &Spec, event: &Event) -> Result<Box<dyn Counter>, String> {
        #[cfg(target_os = "linux")]
        {
            use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
            let attr = Attr {
                kind: spec.event_type,
                size: 64,
                config: event.config,
                read_format: 3,
                ..Default::default()
            };
            let fd = unsafe {
                libc::syscall(
                    libc::SYS_perf_event_open,
                    &attr,
                    -1i32,
                    spec.cpu as i32,
                    -1i32,
                    8u64,
                )
            };
            if fd < 0 {
                let error = std::io::Error::last_os_error();
                return Err(match error.raw_os_error() {
                    Some(libc::EPERM) | Some(libc::EACCES) => {
                        format!("i915 PMU permission denied by kernel/sandbox: {error}")
                    }
                    _ => format!("Open i915 PMU: {error}"),
                });
            }
            let handle = unsafe { OwnedFd::from_raw_fd(fd as i32) };
            let flags = unsafe { libc::fcntl(handle.as_raw_fd(), libc::F_GETFL) };
            if flags < 0
                || unsafe {
                    libc::fcntl(handle.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK)
                } < 0
            {
                return Err(format!(
                    "Configure PMU handle: {}",
                    std::io::Error::last_os_error()
                ));
            }
            Ok(Box::new(Handle(handle)))
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (spec, event);
            Err("i915 PMU acquisition requires Linux".into())
        }
    }
}
pub(super) fn available(sys: &std::path::Path) -> bool {
    #[cfg(target_os = "linux")]
    {
        if sys != std::path::Path::new("/sys") {
            return false;
        }
        let mut stat = std::mem::MaybeUninit::<libc::statfs>::uninit();
        unsafe {
            libc::statfs(c"/sys".as_ptr(), stat.as_mut_ptr()) == 0
                && stat.assume_init().f_type == 0x62656572
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = sys;
        false
    }
}
pub(super) fn percent(before: Reading, next: Reading) -> Result<f64, String> {
    let value = next
        .value
        .checked_sub(before.value)
        .ok_or("PMU busy counter regressed")?;
    let enabled = next
        .enabled
        .checked_sub(before.enabled)
        .ok_or("PMU enabled time regressed")?;
    let running = next
        .running
        .checked_sub(before.running)
        .ok_or("PMU running time regressed")?;
    // i915's software PMU normally runs continuously. Reject multiplexed windows
    // rather than estimating unobserved activity. Tiny timing skew is tolerated.
    if enabled == 0 || running == 0 || running > enabled || enabled - running > enabled / 10000 {
        return Err("PMU interval incomplete or multiplexed".into());
    }
    let percent = 100. * value as f64 / running as f64;
    if percent > 105. {
        return Err("PMU busy interval exceeds elapsed time".into());
    }
    Ok(percent.min(100.))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn abi_layout_is_the_kernel_v0_prefix() {
        assert_eq!(std::mem::size_of::<Attr>(), 64);
        assert_eq!(std::mem::offset_of!(Attr, read_format), 32);
        assert_eq!(std::mem::offset_of!(Attr, flags), 40);
        assert_eq!(std::mem::offset_of!(Attr, config1), 56);
    }
    #[test]
    fn native_records_are_exact_and_zero_is_a_measured_value() {
        let mut data = Vec::new();
        for v in [0u64, 1_000_000_000, 1_000_000_000] {
            data.extend(v.to_ne_bytes());
        }
        let next = decode(&data).unwrap();
        assert_eq!(
            percent(
                Reading {
                    value: 0,
                    enabled: 0,
                    running: 0
                },
                next
            ),
            Ok(0.)
        );
        assert!(decode(&data[..23]).is_err());
        data.push(0);
        assert!(decode(&data).is_err());
    }
    #[test]
    fn counter_resets_and_mux_do_not_become_idle() {
        let old = Reading {
            value: 50,
            enabled: 100,
            running: 100,
        };
        for next in [
            Reading {
                value: 49,
                enabled: 200,
                running: 200,
            },
            Reading {
                value: 50,
                enabled: 99,
                running: 200,
            },
            Reading {
                value: 60,
                enabled: 200,
                running: 150,
            },
            Reading {
                value: 200,
                enabled: 200,
                running: 200,
            },
            old,
        ] {
            assert!(percent(old, next).is_err());
        }
        assert_eq!(
            percent(
                old,
                Reading {
                    value: 75,
                    enabled: 200,
                    running: 200
                }
            ),
            Ok(25.)
        );
    }
}

#[cfg(all(test, target_os = "linux"))]
mod native_test {
    use super::*;
    #[test]
    fn software_counter_checks_the_native_read_abi_or_reports_kernel_refusal() {
        let cpu = unsafe { libc::sched_getcpu() };
        assert!(cpu >= 0, "No online test CPU");
        // A software CPU-clock event exercises the same 64-byte attr and
        // 24-byte read ABI without requiring Intel hardware or changing policy.
        let spec = Spec {
            path: Default::default(),
            event_type: 1,
            cpu: cpu as u32,
            events: Vec::new(),
            device_identity: (0, 0),
            pmu_identity: (0, 0),
        };
        match Native.open(
            &spec,
            &Event {
                name: "software-clock ABI check".into(),
                config: 0,
            },
        ) {
            Ok(mut counter) => {
                let value = counter.read().unwrap();
                assert!(value.running <= value.enabled);
            }
            Err(error) => assert!(
                error.contains("permission denied")
                    || error.contains("Function not implemented")
                    || error.contains("Operation not supported"),
                "Unexpected perf ABI failure: {error}"
            ),
        }
    }
}
