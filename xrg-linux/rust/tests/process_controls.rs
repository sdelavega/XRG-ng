// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#![cfg(target_os = "linux")]
use std::{
    os::unix::process::ExitStatusExt,
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
use xrg_ng_linux::process::{
    self,
    control::{self, Action, Target},
};
struct Disposable(Child);
impl Disposable {
    fn new() -> Self {
        Self(
            Command::new("/bin/sleep")
                .arg("120")
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        )
    }
    fn inspect(&self) -> process::Process {
        control::inspect(self.0.id()).unwrap()
    }
    fn state(&self, stopped: bool) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let process = self.inspect();
            if matches!(process.state, 'T' | 't') == stopped {
                return;
            }
            assert!(
                Instant::now() < deadline,
                "Child state did not become stopped={stopped}"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    fn exited(&mut self, signal: i32) {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(status) = self.0.try_wait().unwrap() {
                assert_eq!(status.signal(), Some(signal));
                return;
            }
            assert!(Instant::now() < deadline, "Child did not exit");
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}
impl Drop for Disposable {
    fn drop(&mut self) {
        if matches!(self.0.try_wait(), Ok(None)) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
}
#[test]
fn terminate_and_force_kill_only_the_chosen_child_and_report_actual_delivery() {
    let mut untouched = Disposable::new();
    for (action, signal) in [
        (Action::Terminate, libc::SIGTERM),
        (Action::ForceKill, libc::SIGKILL),
    ] {
        let mut child = Disposable::new();
        Target::prepare(&child.inspect())
            .unwrap()
            .send(action)
            .unwrap();
        child.exited(signal);
        assert!(untouched.0.try_wait().unwrap().is_none());
    }
}
#[test]
fn pause_and_resume_change_a_disposable_child_state_through_pidfds() {
    let child = Disposable::new();
    let process = child.inspect();
    assert!(Action::Pause.enabled(&process));
    assert!(!Action::Resume.enabled(&process));
    Target::prepare(&process)
        .unwrap()
        .send(Action::Pause)
        .unwrap();
    child.state(true);
    let stopped = child.inspect();
    assert!(!Action::Pause.enabled(&stopped));
    assert!(Action::Resume.enabled(&stopped));
    Target::prepare(&stopped)
        .unwrap()
        .send(Action::Resume)
        .unwrap();
    child.state(false);
}
#[test]
fn stale_start_time_and_ownership_are_refused_before_a_signal() {
    let mut child = Disposable::new();
    let process = child.inspect();
    for mismatch in 0..2 {
        let mut stale = process.clone();
        if mismatch == 0 {
            stale.start_ticks = stale.start_ticks.wrapping_add(1);
        } else {
            stale.uid = Some(stale.uid.unwrap().wrapping_add(1));
        }
        assert!(Target::prepare(&stale).is_err());
        assert!(child.0.try_wait().unwrap().is_none());
        child.state(false);
    }
}
#[test]
fn fixture_records_self_init_and_missing_ownership_cannot_be_action_targets() {
    let child = Disposable::new();
    let process = child.inspect();
    let bytes = std::fs::read(format!("/proc/{}/stat", child.0.id())).unwrap();
    let mut fixture = process::parse_stat(&bytes, child.0.id(), 4096).unwrap();
    fixture.uid = process.uid;
    assert!(Target::prepare(&fixture).is_err());
    for pid in [0, 1, u32::MAX, std::process::id()] {
        let mut invalid = process.clone();
        invalid.pid = pid;
        assert!(Target::prepare(&invalid).is_err());
    }
    let mut unknown = process.clone();
    unknown.uid = None;
    assert!(Target::prepare(&unknown).is_err());
}
#[test]
fn an_exited_pinned_target_never_falls_back_to_another_process() {
    let mut child = Disposable::new();
    let target = Target::prepare(&child.inspect()).unwrap();
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    let mut other = Disposable::new();
    assert!(target.send(Action::ForceKill).is_err());
    assert!(other.0.try_wait().unwrap().is_none());
}

#[test]
fn copied_pid_and_start_fields_cannot_substitute_a_different_proc_directory_identity() {
    let first = Disposable::new();
    let mut other = Disposable::new();
    let mut stale = first.inspect();
    let replacement = other.inspect();
    stale.pid = replacement.pid;
    stale.start_ticks = replacement.start_ticks;
    stale.uid = replacement.uid;
    assert!(Target::prepare(&stale).is_err());
    assert!(other.0.try_wait().unwrap().is_none());
}
#[test]
fn a_fixture_collector_cannot_acquire_control_provenance_even_with_a_live_pid() {
    let child = Disposable::new();
    let pid = child.0.id();
    let root =
        std::env::temp_dir().join(format!("xrg-process-control-{}-{pid}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    std::fs::create_dir(root.join(pid.to_string())).unwrap();
    for file in ["stat", "status"] {
        std::fs::copy(
            format!("/proc/{pid}/{file}"),
            root.join(pid.to_string()).join(file),
        )
        .unwrap();
    }
    std::fs::write(root.join("meminfo"), "MemTotal: 1024 kB\n").unwrap();
    let mut collector = process::Collector::new(root.clone());
    let report = collector.sample().unwrap();
    assert_eq!(report.processes.len(), 1);
    assert!(Target::prepare(&report.processes[0]).is_err());
    std::fs::remove_dir_all(root).unwrap();
}
