// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Explicit process actions. A pidfd pins the validated target through review;
//! signal delivery never falls back to a numeric PID or a process group.
#[cfg(target_os = "linux")]
pub const IMPLEMENTATION: &str = "linux";
#[cfg(not(target_os = "linux"))]
pub const IMPLEMENTATION: &str = "stub";
use super::Process;
#[cfg(target_os = "linux")]
use std::{
    io,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    Terminate,
    ForceKill,
    Pause,
    Resume,
}
impl Action {
    pub const ALL: [Self; 4] = [Self::Terminate, Self::ForceKill, Self::Pause, Self::Resume];
    pub fn name(self) -> &'static str {
        match self {
            Self::Terminate => "Terminate (SIGTERM)",
            Self::ForceKill => "Force Kill (SIGKILL)",
            Self::Pause => "Pause (SIGSTOP)",
            Self::Resume => "Resume (SIGCONT)",
        }
    }
    pub fn id(self) -> &'static str {
        match self {
            Self::Terminate => "terminate",
            Self::ForceKill => "force-kill",
            Self::Pause => "pause",
            Self::Resume => "resume",
        }
    }
    pub fn explanation(self) -> &'static str {
        match self {
            Self::Terminate => {
                "Ask this process to exit. It may handle or ignore the request. Unsaved work may be lost."
            }
            Self::ForceKill => {
                "End this process immediately without allowing cleanup. Unsaved work will be lost."
            }
            Self::Pause => {
                "Suspend this process until resumed. Work and services it provides will stop while it is paused."
            }
            Self::Resume => "Allow this stopped process to run again.",
        }
    }
    pub fn enabled(self, process: &Process) -> bool {
        eligible(process).is_ok()
            && match self {
                Self::Pause => !matches!(process.state, 'T' | 't'),
                Self::Resume => matches!(process.state, 'T' | 't'),
                _ => true,
            }
    }
    #[cfg(target_os = "linux")]
    fn signal(self) -> i32 {
        match self {
            Self::Terminate => libc::SIGTERM,
            Self::ForceKill => libc::SIGKILL,
            Self::Pause => libc::SIGSTOP,
            Self::Resume => libc::SIGCONT,
        }
    }
}
pub fn eligible(process: &Process) -> Result<(), String> {
    if !cfg!(target_os = "linux") {
        return Err("Process controls require Linux pidfd support".into());
    }
    if process.pid <= 1 || process.pid > i32::MAX as u32 {
        return Err("PID 0, PID 1 and invalid PIDs cannot be controlled".into());
    }
    if process.pid == std::process::id() {
        return Err("XRG-ng cannot send signals to itself".into());
    }
    if process.identity.is_none() {
        return Err(
            "Process controls require an identified process from the live /proc namespace".into(),
        );
    }
    if process.uid.is_none() {
        return Err("Process ownership is unavailable; refresh before acting".into());
    }
    if matches!(process.state, 'Z' | 'X' | 'x') {
        return Err("This process has already exited".into());
    }
    Ok(())
}
/// Inspection is read-only, and only uses the fixed live proc mount. Fixture
/// collectors never acquire the private identity needed for signal delivery.
pub fn inspect(pid: u32) -> Result<Process, String> {
    if !super::live_namespace(std::path::Path::new("/proc")) {
        return Err("Live /proc PID namespace is unavailable".into());
    }
    // sysconf page size is POSIX; every unix target reads the real value.
    // The procfs reads that follow remain Linux-only.
    #[cfg(unix)]
    let page_size = u64::try_from(unsafe { libc::sysconf(libc::_SC_PAGESIZE) }).unwrap_or(0);
    #[cfg(not(unix))]
    let page_size = 0;
    super::read_process(std::path::Path::new("/proc"), pid, page_size)
        .map_err(|e| format!("Process is no longer readable: {e}"))
}
pub struct Target {
    process: Process,
    #[cfg(target_os = "linux")]
    handle: OwnedFd,
}
impl Target {
    pub fn process(&self) -> &Process {
        &self.process
    }
    pub fn prepare(process: &Process) -> Result<Self, String> {
        eligible(process)?;
        #[cfg(target_os = "linux")]
        {
            let fd =
                unsafe { libc::syscall(libc::SYS_pidfd_open, process.pid as libc::pid_t, 0u32) };
            if fd < 0 {
                return Err(error("Open process handle", io::Error::last_os_error()));
            }
            // pidfd_open supplies CLOEXEC. OwnedFd closes every refusal/cancel path.
            let handle = unsafe { OwnedFd::from_raw_fd(fd as i32) };
            let current = inspect(process.pid)?;
            if !process.same_instance(&current) {
                return Err(
                    "Process identity or ownership changed; refresh and select it again".into(),
                );
            }
            eligible(&current)?;
            probe(&handle)?;
            Ok(Self {
                process: current,
                handle,
            })
        }
        #[cfg(not(target_os = "linux"))]
        Err("Process controls require Linux pidfd support".into())
    }
    pub fn send(self, action: Action) -> Result<(), String> {
        #[cfg(target_os = "linux")]
        {
            let current = inspect(self.process.pid)?;
            if !self.process.same_instance(&current) || self.process.name != current.name {
                return Err(
                    "Process identity, name or ownership changed during review; select it again"
                        .into(),
                );
            }
            eligible(&current)?;
            let result = unsafe {
                libc::syscall(
                    libc::SYS_pidfd_send_signal,
                    self.handle.as_raw_fd(),
                    action.signal(),
                    std::ptr::null::<libc::siginfo_t>(),
                    0u32,
                )
            };
            if result < 0 {
                return Err(error("Send signal", io::Error::last_os_error()));
            }
            Ok(())
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = action;
            Err("Process controls require Linux pidfd support".into())
        }
    }
}
#[cfg(target_os = "linux")]
fn probe(handle: &OwnedFd) -> Result<(), String> {
    // Signal 0 checks existence and kernel permission without delivering a signal.
    let result = unsafe {
        libc::syscall(
            libc::SYS_pidfd_send_signal,
            handle.as_raw_fd(),
            0i32,
            std::ptr::null::<libc::siginfo_t>(),
            0u32,
        )
    };
    if result < 0 {
        return Err(error(
            "Check process permission",
            io::Error::last_os_error(),
        ));
    }
    Ok(())
}
#[cfg(target_os = "linux")]
fn error(operation: &str, error: io::Error) -> String {
    let reason = match error.raw_os_error() {
        Some(libc::ENOSYS) => {
            "Linux pidfd operations are unavailable; no numeric-PID fallback is used"
        }
        Some(libc::EPERM) | Some(libc::EACCES) => {
            "Permission denied by the kernel or sandbox; XRG-ng does not elevate privileges"
        }
        Some(libc::ESRCH) => "The selected process has exited",
        _ => "The process operation failed",
    };
    format!("{operation}: {reason} ({error})")
}
