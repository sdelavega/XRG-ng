// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Counter, Counters, Open, Reading, discovery::Spec};
use std::collections::BTreeSet;
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub(super) struct Engine {
    pub class: u16,
    pub instance: u16,
    pub gt: u16,
}
impl Engine {
    pub fn name(self) -> String {
        format!(
            "gt{} {}{}",
            self.gt,
            ["render", "copy", "video-decode", "video-enhance", "compute"][self.class as usize],
            self.instance
        )
    }
    pub fn config(self, event: u64) -> u64 {
        event
            | ((self.gt as u64) << 60)
            | ((self.class as u64) << 20)
            | ((self.instance as u64) << 12)
    }
}
pub(super) fn engines(bytes: &[u8]) -> Result<Vec<Engine>, String> {
    if bytes.len() < 8 || bytes.len() > 8 + 64 * 32 {
        return Err("Invalid Xe engine query size".into());
    }
    let count = u32::from_ne_bytes(bytes[..4].try_into().unwrap()) as usize;
    if count == 0 || count > 64 || bytes[4..8] != [0; 4] || bytes.len() != 8 + count * 32 {
        return Err("Invalid Xe engine query header/count".into());
    }
    let mut result = BTreeSet::new();
    for record in bytes[8..].as_chunks::<32>().0 {
        let engine = Engine {
            class: u16::from_ne_bytes(record[..2].try_into().unwrap()),
            instance: u16::from_ne_bytes(record[2..4].try_into().unwrap()),
            gt: u16::from_ne_bytes(record[4..6].try_into().unwrap()),
        };
        if engine.class > 4
            || engine.instance > 255
            || engine.gt > 15
            || record[6..].iter().any(|b| *b != 0)
            || !result.insert(engine)
        {
            return Err("Unsupported or duplicate Xe engine identity".into());
        }
    }
    Ok(result.into_iter().collect())
}
pub(super) fn decode(bytes: &[u8], active_id: u64, total_id: u64) -> Result<Reading, String> {
    if bytes.len() != 56 || active_id == 0 || total_id == 0 || active_id == total_id {
        return Err("Invalid Xe perf group record/IDs".into());
    }
    let values: Vec<_> = bytes
        .as_chunks::<8>()
        .0
        .iter()
        .map(|s| u64::from_ne_bytes(*s))
        .collect();
    if values[0] != 2 {
        return Err("Unexpected Xe perf group count".into());
    }
    let mut active = None;
    let mut total = None;
    for pair in values[3..].as_chunks::<2>().0 {
        if pair[1] == active_id && active.is_none() {
            active = Some(pair[0]);
        } else if pair[1] == total_id && total.is_none() {
            total = Some(pair[0]);
        } else {
            return Err("Unexpected/duplicate Xe perf counter ID".into());
        }
    }
    Ok(Reading {
        active: active.ok_or("Missing Xe active counter")?,
        total: total.ok_or("Missing Xe total counter")?,
        enabled: values[1],
        running: values[2],
    })
}
#[cfg(any(target_os = "linux", test))]
#[derive(Default)]
#[repr(C)]
struct Query {
    extensions: u64,
    query: u32,
    size: u32,
    data: u64,
    reserved: [u64; 2],
}
#[cfg(any(target_os = "linux", test))]
#[derive(Default)]
#[repr(C)]
struct Version {
    major: i32,
    minor: i32,
    patch: i32,
    pad: i32,
    name_len: u64,
    name: u64,
    date_len: u64,
    date: u64,
    desc_len: u64,
    desc: u64,
}
#[derive(Default)]
pub(super) struct Native;
#[cfg(target_os = "linux")]
struct Group {
    // The sibling closes before the group leader.
    _total: std::os::fd::OwnedFd,
    active: std::os::fd::OwnedFd,
    active_id: u64,
    total_id: u64,
}
#[cfg(target_os = "linux")]
impl Counter for Group {
    fn read(&mut self) -> Result<Reading, String> {
        use std::os::fd::AsRawFd;
        let mut bytes = [0u8; 56];
        for _ in 0..4 {
            let count = unsafe {
                libc::read(
                    self.active.as_raw_fd(),
                    bytes.as_mut_ptr().cast(),
                    bytes.len(),
                )
            };
            if count == 56 {
                return decode(&bytes, self.active_id, self.total_id);
            }
            let error = std::io::Error::last_os_error();
            if count < 0 && error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(if count < 0 {
                format!("Read Xe perf group: {error}")
            } else {
                "Short Xe perf group read".into()
            });
        }
        Err("Interrupted Xe perf group read".into())
    }
}
#[cfg(target_os = "linux")]
fn ioctl(fd: i32, request: libc::c_ulong, value: *mut std::ffi::c_void) -> Result<(), String> {
    if unsafe { libc::ioctl(fd, request, value) } < 0 {
        Err(format!(
            "Xe query/perf ioctl: {}",
            std::io::Error::last_os_error()
        ))
    } else {
        Ok(())
    }
}
#[cfg(target_os = "linux")]
fn query(fd: i32) -> Result<Vec<Engine>, String> {
    let mut name = [0u8; 16];
    let mut version = Version {
        name_len: name.len() as u64,
        name: name.as_mut_ptr() as u64,
        ..Default::default()
    };
    ioctl(fd, 0xc0406400, (&mut version as *mut Version).cast())?;
    if version.name_len != 2 || &name[..2] != b"xe" {
        return Err("Render node is not the Xe DRM driver".into());
    }
    let mut query = Query::default();
    ioctl(fd, 0xc0286440, (&mut query as *mut Query).cast())?;
    let size = query.size as usize;
    if !(40..=8 + 64 * 32).contains(&size) || !(size - 8).is_multiple_of(32) {
        return Err("Invalid Xe engine query allocation size".into());
    }
    let mut data = vec![0u64; size / 8];
    query.data = data.as_mut_ptr() as u64;
    ioctl(fd, 0xc0286440, (&mut query as *mut Query).cast())?;
    if query.size as usize != size
        || query.extensions != 0
        || query.query != 0
        || query.reserved != [0; 2]
    {
        return Err("Xe query changed during acquisition".into());
    }
    let bytes: Vec<_> = data.iter().flat_map(|v| v.to_ne_bytes()).collect();
    engines(&bytes)
}
impl Open for Native {
    fn open(&mut self, spec: &Spec) -> Result<Counters, String> {
        #[cfg(target_os = "linux")]
        {
            use std::{
                fs::OpenOptions,
                os::{
                    fd::AsRawFd,
                    unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt},
                },
            };
            if !cfg!(any(target_arch = "x86_64", target_arch = "aarch64")) {
                return Err("Xe PMU acquisition currently requires a 64-bit target".into());
            }
            let started = std::time::Instant::now();
            spec.verify()?;
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(&spec.node)
                .map_err(|e| format!("Open Xe render node: {e}"))?;
            let meta = file.metadata().map_err(|e| e.to_string())?;
            if !meta.file_type().is_char_device()
                || (libc::major(meta.rdev()), libc::minor(meta.rdev())) != spec.dev
            {
                return Err("Xe render device number changed".into());
            }
            let list = query(file.as_raw_fd())?;
            spec.verify()?;
            let mut result = Vec::new();
            for engine in list {
                if started.elapsed() > std::time::Duration::from_millis(100) {
                    return Err("Xe PMU open budget exceeded".into());
                }
                let active = crate::gpu::intel::perf::open_event(
                    spec.event_type,
                    spec.cpu,
                    engine.config(2),
                    -1,
                    true,
                    15,
                )?;
                let total = crate::gpu::intel::perf::open_event(
                    spec.event_type,
                    spec.cpu,
                    engine.config(3),
                    active.as_raw_fd(),
                    false,
                    15,
                )?;
                let mut active_id = 0u64;
                let mut total_id = 0u64;
                ioctl(
                    active.as_raw_fd(),
                    0x80082407,
                    (&mut active_id as *mut u64).cast(),
                )?;
                ioctl(
                    total.as_raw_fd(),
                    0x80082407,
                    (&mut total_id as *mut u64).cast(),
                )?;
                if active_id == 0 || total_id == 0 || active_id == total_id {
                    return Err("Invalid Xe perf IDs".into());
                }
                if unsafe { libc::ioctl(active.as_raw_fd(), 0x2400, 1 as libc::c_ulong) } < 0 {
                    return Err(format!(
                        "Enable Xe perf group: {}",
                        std::io::Error::last_os_error()
                    ));
                }
                result.push((
                    engine.name(),
                    Box::new(Group {
                        _total: total,
                        active,
                        active_id,
                        total_id,
                    }) as Box<dyn Counter>,
                ));
            }
            spec.verify()?;
            Ok(result)
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = spec;
            Err("Xe PMU acquisition requires Linux".into())
        }
    }
}
#[cfg(test)]
mod abi_tests {
    use super::*;
    #[test]
    fn query_abi_sizes_match_linux_uapi() {
        assert_eq!(std::mem::size_of::<Query>(), 40);
        assert_eq!(std::mem::size_of::<Version>(), 64);
        assert_eq!(std::mem::offset_of!(Query, data), 16);
    }
}
