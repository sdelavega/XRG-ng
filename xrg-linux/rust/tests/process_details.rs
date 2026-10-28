// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::sync::Arc;
use xrg_ng_linux::{
    process::{
        self, Process, Report,
        details::{Status, View},
    },
    settings::ProcessView,
};
fn process() -> Process {
    let mut fields = vec!["0".to_owned(); 22];
    fields[0] = "S".into();
    fields[1] = "7".into();
    fields[11] = "625".into();
    fields[12] = "125".into();
    fields[13] = "99999".into();
    fields[14] = "88888".into();
    fields[15] = "15".into();
    fields[16] = "-5".into();
    fields[17] = "3".into();
    fields[19] = "42".into();
    fields[20] = "10485760".into();
    fields[21] = "256".into();
    let mut process = process::parse_stat(
        format!("42 (name (worker)) {}", fields.join(" ")).as_bytes(),
        42,
        4096,
    )
    .unwrap();
    process.uid = Some(1000);
    process
}
fn report(processes: Vec<Process>, partial: bool) -> Result<Arc<Report>, String> {
    Ok(Arc::new(Report {
        discovered: processes.len() + usize::from(partial),
        attempted: processes.len(),
        processes,
        vanished: 0,
        unreadable: usize::from(partial),
        errors: Vec::new(),
    }))
}
#[test]
fn detail_snapshot_preserves_zero_unknown_and_stat_field_meanings() {
    let mut p = process();
    assert_eq!(
        (p.parent_pid, p.priority, p.user_ticks, p.system_ticks),
        (7, 15, 625, 125)
    );
    assert_eq!(p.cpu_ticks, 750);
    let mut view = View::new(p.clone());
    view.update(&report(vec![p.clone()], false));
    let unknown = view.text();
    assert!(
        unknown.contains("CPU: unavailable")
            && unknown.contains("Lifetime CPU time: unavailable")
            && unknown.contains("Real UID: 1000")
    );
    p.cpu_percent = Some(0.);
    p.rss_bytes = 0;
    p.memory_percent = Some(0.);
    p.cpu_time = Some(std::time::Duration::ZERO);
    view.update(&report(vec![p], false));
    let zero = view.text();
    assert!(
        zero.contains("CPU: 0.0%")
            && zero.contains("RAM share: 0.00%")
            && zero.contains("Resident: 0.00 MiB (0 bytes)")
    );
    assert!(zero.contains("Lifetime CPU time: 0d 00:00:00.000"));
    assert!(zero.contains("Kernel priority: 15 (raw /proc value)"));
}
#[test]
fn filtering_and_rename_do_not_retarget_or_freeze_live_details() {
    let mut p = process();
    let mut view = View::new(p.clone());
    p.name = "renamed or exec'd same instance".into();
    p.cpu_percent = Some(225.);
    let report = report(vec![p.clone()], false);
    assert!(
        report
            .as_ref()
            .unwrap()
            .listing(&ProcessView {
                filter: "nothing matches".into(),
                ..Default::default()
            })
            .unwrap()
            .rows
            .is_empty()
    );
    view.update(&report);
    assert_eq!(view.process(), &p);
    assert_eq!(view.status(), &Status::Live { partial: false });
    assert!(view.text().contains("CPU: 225.0%"));
}
#[test]
fn missing_partial_and_failed_scans_retain_last_values_and_can_recover() {
    let p = process();
    let mut view = View::new(p.clone());
    view.update(&report(vec![p.clone()], false));
    view.update(&report(Vec::new(), false));
    assert_eq!(view.status(), &Status::Missing { partial: false });
    assert!(view.text().contains("last observed, not current"));
    view.update(&report(Vec::new(), true));
    assert_eq!(view.status(), &Status::Missing { partial: true });
    view.update(&Err("fixture permission failure".into()));
    assert_eq!(view.process(), &p);
    assert!(
        view.text().contains("Process data unavailable")
            && view.text().contains("fixture permission failure")
    );
    view.update(&report(vec![p], true));
    assert_eq!(view.status(), &Status::Live { partial: true });
}
#[test]
fn pid_reuse_and_uid_changes_are_terminal_even_if_an_old_report_arrives() {
    for ownership in [false, true] {
        let p = process();
        let mut view = View::new(p.clone());
        view.update(&report(vec![p.clone()], false));
        let mut changed = p.clone();
        if ownership {
            changed.uid = Some(2000);
        } else {
            changed.start_ticks += 1;
        }
        changed.name = "replacement".into();
        view.update(&report(vec![changed], false));
        assert_eq!(view.status(), &Status::IdentityChanged);
        assert_eq!(view.process(), &p);
        view.update(&report(vec![p.clone()], false));
        assert_eq!(view.status(), &Status::IdentityChanged);
        assert!(!view.text().contains("replacement"));
    }
}
#[test]
fn invalid_parent_pid_and_priority_do_not_become_valid_zero_details() {
    let text = "42 (worker) S 7 0 0 0 0 0 0 0 0 0 625 125 0 0 15 -5 3 0 42 10485760 256";
    assert!(process::parse_stat(text.as_bytes(), 42, 4096).is_ok());
    for bad in [
        text.replacen("S 7 ", "S -1 ", 1),
        text.replacen("S 7 ", "S 4294967295 ", 1),
        text.replacen(" 15 -5 ", " invalid -5 ", 1),
        text.replacen(" 15 -5 ", " 9223372036854775808 -5 ", 1),
    ] {
        assert!(process::parse_stat(bad.as_bytes(), 42, 4096).is_err());
    }
}
