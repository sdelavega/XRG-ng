// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! A read-only inspector consumes complete worker reports, never table filters.
use super::{Process, Report};
use std::{sync::Arc, time::Duration};
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Status {
    Live { partial: bool },
    Missing { partial: bool },
    Unavailable(String),
    IdentityChanged,
}
impl Status {
    pub fn description(&self) -> String {
        match self {
            Self::Live{partial:false}=>"Live · latest readable process scan".into(),
            Self::Live{partial:true}=>"Live · process found in a partial scan".into(),
            Self::Missing{partial:false}=>"Not present in the latest readable scan · values below are last observed, not current".into(),
            Self::Missing{partial:true}=>"Not found in a partial scan · values below are last observed, not current".into(),
            Self::Unavailable(error)=>format!("Process data unavailable · values below are last observed, not current\n{error}"),
            Self::IdentityChanged=>"Process identity changed · updates stopped; values below belong to the originally selected process".into(),
        }
    }
}
pub struct View {
    target: Process,
    last: Process,
    status: Status,
}
impl View {
    pub fn new(process: Process) -> Self {
        Self {
            target: process.clone(),
            last: process,
            status: Status::Unavailable("Waiting for a fresh worker report".into()),
        }
    }
    pub fn matches(&self, process: &Process) -> bool {
        self.target.same_instance(process)
    }
    pub fn status(&self) -> &Status {
        &self.status
    }
    pub fn process(&self) -> &Process {
        &self.last
    }
    pub fn update(&mut self, report: &Result<Arc<Report>, String>) {
        // Identity changes are terminal. A delayed old report cannot reactivate
        // an inspector after a different process has been seen at this PID.
        if self.status == Status::IdentityChanged {
            return;
        }
        match report {
            Err(error) => self.status = Status::Unavailable(error.clone()),
            Ok(report) => match report.processes.iter().find(|p| p.pid == self.target.pid) {
                Some(process) if self.matches(process) => {
                    self.last = process.clone();
                    self.status = Status::Live {
                        partial: report.partial(),
                    };
                }
                Some(_) => self.status = Status::IdentityChanged,
                None => {
                    self.status = Status::Missing {
                        partial: report.partial(),
                    }
                }
            },
        }
    }
    pub fn text(&self) -> String {
        let p = &self.last;
        let cpu = p
            .cpu_percent
            .map(|v| format!("{v:.1}%"))
            .unwrap_or_else(|| "unavailable · waiting for a valid interval".into());
        let memory = p
            .memory_percent
            .map(|v| format!("{v:.2}% of exposed system RAM"))
            .unwrap_or_else(|| "unavailable".into());
        let uid = p
            .uid
            .map(|v| v.to_string())
            .unwrap_or_else(|| "unavailable".into());
        let time = p
            .cpu_time
            .map(duration)
            .unwrap_or_else(|| "unavailable · sampling clock not supplied".into());
        format!(
            "{} · PID {}\n\n{}\n\nIdentity\n  PID: {}\n  Parent PID: {}\n  Real UID: {uid}\n  Started: {} clock ticks after boot\n\nExecution\n  State: {} ({})\n  Threads: {}\n  CPU: {cpu}\n  Lifetime CPU time: {time}\n  User / kernel ticks: {} / {}\n\nMemory\n  Resident: {:.2} MiB ({} bytes)\n  Virtual: {:.2} MiB ({} bytes)\n  RAM share: {memory}\n\nScheduling\n  Nice: {}\n  Kernel priority: {} (raw /proc value)\n\n100% CPU is one core; a multithreaded process can exceed 100%. CPU time is accumulated user + kernel time, not elapsed uptime or child CPU time. Guest time already included in user ticks is counted once. RSS can include shared pages; virtual size is address space, not allocated RAM. RAM share uses the exposed /proc total, not a container limit.\n\nThis inspector stays with this PID, start time, ownership and source identity. Filtering, sorting or hiding its table row does not retarget it. A missing row does not prove exit; scans can be partial or permissions can change. No additional process files or user database lookups are read by this view.",
            p.name,
            p.pid,
            self.status.description(),
            p.pid,
            p.parent_pid,
            p.start_ticks,
            p.state,
            state_name(p.state),
            p.threads,
            p.user_ticks,
            p.system_ticks,
            p.rss_bytes as f64 / 1_048_576.,
            p.rss_bytes,
            p.virtual_bytes as f64 / 1_048_576.,
            p.virtual_bytes,
            p.nice,
            p.priority
        )
    }
}
fn duration(value: Duration) -> String {
    let seconds = value.as_secs();
    format!(
        "{}d {:02}:{:02}:{:02}.{:03}",
        seconds / 86400,
        seconds / 3600 % 24,
        seconds / 60 % 60,
        seconds % 60,
        value.subsec_millis()
    )
}
fn state_name(state: char) -> &'static str {
    match state {
        'R' => "running or runnable",
        'S' => "sleeping",
        'D' => "uninterruptible wait",
        'Z' => "zombie",
        'T' => "stopped",
        't' => "tracing stop",
        'X' | 'x' => "dead",
        'I' => "idle",
        _ => "kernel state",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matching_pid_start_and_uid_cannot_replace_the_pinned_source_identity() {
        let mut process = crate::process::parse_stat(
            b"42 (worker) S 7 0 0 0 0 0 0 0 0 0 625 125 0 0 15 -5 3 0 42 10485760 256",
            42,
            4096,
        )
        .unwrap();
        process.uid = Some(1000);
        process.identity = Some(crate::process::Identity {
            device: 1,
            inode: 10,
        });
        let mut changed = process.clone();
        changed.identity = Some(crate::process::Identity {
            device: 1,
            inode: 11,
        });
        let mut view = View::new(process.clone());
        view.update(&Ok(Arc::new(Report {
            processes: vec![changed],
            discovered: 1,
            attempted: 1,
            vanished: 0,
            unreadable: 0,
            errors: Vec::new(),
        })));
        assert_eq!(view.status(), &Status::IdentityChanged);
        assert_eq!(view.process(), &process);
    }
}
