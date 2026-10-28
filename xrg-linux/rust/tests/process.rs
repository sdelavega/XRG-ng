// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::process::{self, Collector, Sort};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-process-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        fs::write(root.join("meminfo"), "MemTotal: 1024 kB\n").unwrap();
        Self(root)
    }
    fn put(&self, pid: u32, stat: &str, uid: Option<u32>) {
        let dir = self.0.join(pid.to_string());
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("stat"), stat).unwrap();
        if let Some(uid) = uid {
            fs::write(
                dir.join("status"),
                format!("Name:\ttest\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"),
            )
            .unwrap();
        }
    }
    fn collector(&self) -> Collector {
        Collector::with_parameters(self.0.clone(), 100, 4096)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn stat(pid: u32, name: &str, state: &str, ticks: u64, start: u64, rss: i64) -> String {
    let mut fields = vec!["0".to_owned(); 22];
    fields[0] = state.into();
    fields[11] = ticks.to_string();
    fields[12] = "0".into();
    fields[16] = "-5".into();
    fields[17] = "3".into();
    fields[19] = start.to_string();
    fields[20] = "12345678".into();
    fields[21] = rss.to_string();
    format!("{pid} ({name}) {}\n", fields.join(" "))
}
#[test]
fn stat_handles_parentheses_spaces_and_control_characters() {
    let p = process::parse_stat(
        stat(42, "a (b) ) c\nname", "R", 9, 7, 2).as_bytes(),
        42,
        4096,
    )
    .unwrap();
    assert_eq!(p.name, "a (b) ) cname");
    assert_eq!(p.start_ticks, 7);
    assert_eq!(p.cpu_ticks, 9);
    assert_eq!(p.rss_bytes, 8192);
    assert_eq!(p.virtual_bytes, 12345678);
    assert_eq!(p.nice, -5);
    assert_eq!(p.threads, 3);
    assert_eq!(
        process::parse_stat(stat(42, "x", "S", 0, 1, 2).as_bytes(), 42, 65536)
            .unwrap()
            .rss_bytes,
        131072
    );
}
#[test]
fn malformed_pid_fields_signed_rss_and_overflow_are_rejected() {
    assert!(process::parse_stat(b"1 (x) S 0", 1, 4096).is_err());
    assert!(process::parse_stat(stat(1, "x", "R", 0, 1, 0).as_bytes(), 2, 4096).is_err());
    assert!(process::parse_stat(stat(1, "x", "?", 0, 1, 0).as_bytes(), 1, 4096).is_err());
    assert!(process::parse_stat(stat(1, "x", "R", 0, 1, -1).as_bytes(), 1, 4096).is_err());
    assert!(process::parse_stat(stat(1, "x", "R", 0, 1, i64::MAX).as_bytes(), 1, 65536).is_err());
    let mut fields = stat(1, "x", "S", u64::MAX, 1, 0);
    fields = fields.replace(
        &format!("{0} 0 0 0", u64::MAX),
        &format!("{0} 1 0 0", u64::MAX),
    );
    assert!(process::parse_stat(fields.as_bytes(), 1, 4096).is_err());
}
#[test]
fn cpu_is_elapsed_one_core_percentage_and_zero_counter_is_a_valid_baseline() {
    let f = Fixture::new();
    f.put(1, &stat(1, "worker", "R", 0, 99, 2), Some(1000));
    let mut c = f.collector();
    assert_eq!(c.sample_at(1.).unwrap().processes[0].cpu_percent, None);
    f.put(1, &stat(1, "worker", "S", 600, 99, 2), Some(1000));
    let r = c.sample_at(3.).unwrap();
    let p = &r.processes[0];
    assert_eq!(p.cpu_percent, Some(300.));
    assert_eq!(p.memory_percent, Some(8192. / 1048576. * 100.));
    assert_eq!(p.uid, Some(1000));
}
#[test]
fn pid_reuse_and_counter_regression_restart_the_interval() {
    let f = Fixture::new();
    f.put(7, &stat(7, "old", "S", 100, 1, 1), None);
    let mut c = f.collector();
    c.sample_at(1.).unwrap();
    f.put(7, &stat(7, "new", "S", 5000, 2, 1), None);
    assert_eq!(c.sample_at(2.).unwrap().processes[0].cpu_percent, None);
    f.put(7, &stat(7, "new", "S", 5100, 2, 1), None);
    assert_eq!(
        c.sample_at(3.).unwrap().processes[0].cpu_percent,
        Some(100.)
    );
    f.put(7, &stat(7, "new", "S", 1, 2, 1), None);
    assert_eq!(c.sample_at(4.).unwrap().processes[0].cpu_percent, None);
    f.put(7, &stat(7, "new", "S", 26, 2, 1), None);
    assert_eq!(c.sample_at(5.).unwrap().processes[0].cpu_percent, Some(25.));
}
#[test]
fn stale_time_does_not_consume_newer_counters() {
    let f = Fixture::new();
    f.put(1, &stat(1, "x", "S", 0, 1, 1), None);
    let mut c = f.collector();
    c.sample_at(1.).unwrap();
    f.put(1, &stat(1, "x", "S", 90, 1, 1), None);
    assert_eq!(c.sample_at(1.).unwrap().processes[0].cpu_percent, None);
    f.put(1, &stat(1, "x", "S", 100, 1, 1), None);
    assert_eq!(
        c.sample_at(2.).unwrap().processes[0].cpu_percent,
        Some(100.)
    );
    assert!(c.sample_at(f64::NAN).is_err());
    assert_eq!(c.sample_at(3.).unwrap().processes[0].cpu_percent, None);
}
#[test]
fn exited_unreadable_and_returning_processes_do_not_keep_stale_baselines() {
    let f = Fixture::new();
    f.put(1, &stat(1, "x", "S", 1, 1, 1), None);
    let mut c = f.collector();
    c.sample_at(1.).unwrap();
    fs::write(f.0.join("1/stat"), "broken").unwrap();
    let report = c.sample_at(2.).unwrap();
    assert_eq!(report.unreadable, 1);
    assert!(report.partial());
    assert!(report.processes.is_empty());
    f.put(1, &stat(1, "x", "S", 500, 1, 1), None);
    assert_eq!(c.sample_at(3.).unwrap().processes[0].cpu_percent, None);
    fs::remove_dir_all(f.0.join("1")).unwrap();
    assert!(c.sample_at(4.).unwrap().processes.is_empty());
    f.put(1, &stat(1, "x", "S", 1000, 1, 1), None);
    assert_eq!(c.sample_at(5.).unwrap().processes[0].cpu_percent, None);
}
#[test]
fn ranking_filters_are_stable_and_do_not_discard_background_baselines() {
    let f = Fixture::new();
    for (pid, name, uid, rss) in [
        (1, "Beta", 1000, 1),
        (2, "alpha", 2000, 4),
        (3, "ALPHA", 1000, 2),
    ] {
        f.put(pid, &stat(pid, name, "S", 0, 1, rss), Some(uid));
    }
    let mut c = f.collector();
    let r = c.sample_at(1.).unwrap();
    assert_eq!(
        r.ranked(Sort::Memory, None, "", 2)
            .iter()
            .map(|p| p.pid)
            .collect::<Vec<_>>(),
        [2, 3]
    );
    assert_eq!(
        r.ranked(Sort::Name, None, "alpha", 10)
            .iter()
            .map(|p| p.pid)
            .collect::<Vec<_>>(),
        [2, 3]
    );
    assert_eq!(r.ranked(Sort::Pid, Some(1000), "alpha", 10)[0].pid, 3);
    assert!(r.ranked(Sort::Cpu, Some(123), "", 10).is_empty());
    f.put(2, &stat(2, "alpha", "R", 200, 1, 4), Some(2000));
    let r = c.sample_at(2.).unwrap();
    assert_eq!(r.ranked(Sort::Cpu, None, "", 1)[0].pid, 2);
    assert_eq!(r.ranked(Sort::Cpu, None, "", 1)[0].cpu_percent, Some(200.));
}
#[test]
fn uid_and_memory_unknown_are_not_fabricated_as_root_or_zero() {
    let f = Fixture::new();
    f.put(1, &stat(1, "x", "S", 0, 1, 1), None);
    fs::write(f.0.join("meminfo"), "MemTotal: 10 MB\n").unwrap();
    let report = f.collector().sample_at(1.).unwrap();
    let p = &report.processes[0];
    assert_eq!(p.uid, None);
    assert_eq!(p.memory_percent, None);
    assert!(report.partial());
    assert!(report.ranked(Sort::Pid, Some(0), "", 10).is_empty());
}
#[test]
fn symlinks_special_files_and_invalid_pid_directories_are_not_read() {
    let f = Fixture::new();
    f.put(1, &stat(1, "good", "R", 0, 1, 1), None);
    std::os::unix::fs::symlink(f.0.join("1"), f.0.join("2")).unwrap();
    f.put(3, &stat(3, "bad", "S", 0, 1, 1), None);
    fs::remove_file(f.0.join("3/stat")).unwrap();
    let path = std::ffi::CString::new(f.0.join("3/stat").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    fs::create_dir(f.0.join("04")).unwrap();
    fs::create_dir(f.0.join("5abc")).unwrap();
    let report = f.collector().sample_at(1.).unwrap();
    assert_eq!(report.discovered, 2);
    assert_eq!(report.processes.len(), 1);
    assert_eq!(report.unreadable, 1);
}
#[test]
fn missing_proc_root_and_invalid_host_parameters_are_errors() {
    let f = Fixture::new();
    assert!(
        Collector::with_parameters(f.0.join("missing"), 100, 4096)
            .sample_at(1.)
            .is_err()
    );
    assert!(
        Collector::with_parameters(f.0.clone(), 0, 4096)
            .sample_at(1.)
            .is_err()
    );
    assert!(
        Collector::with_parameters(f.0.clone(), 100, 0)
            .sample_at(1.)
            .is_err()
    );
}

#[test]
fn process_table_queries_filter_before_limiting_and_keep_unknown_cpu_distinct() {
    use xrg_ng_linux::settings::ProcessView;
    let f = Fixture::new();
    for pid in 1..=35 {
        let (uid, name, rss) = if pid <= 15 {
            (1000, format!("Alpha-{pid}"), pid as i64)
        } else {
            (2000, format!("other-{pid}"), 1000)
        };
        f.put(pid, &stat(pid, &name, "S", 0, 1, rss), Some(uid));
    }
    let report = f.collector().sample_at(1.).unwrap();
    let view = ProcessView {
        sort: Sort::Memory,
        uid: Some(1000),
        filter: "ALPHA".into(),
        limit: 10,
    };
    let listing = report.listing(&view).unwrap();
    assert_eq!(listing.matched, 15);
    assert_eq!(listing.readable, 35);
    assert_eq!(listing.rows.len(), 10);
    assert_eq!(listing.rows[0].pid, 15);
    assert_eq!(listing.rows[9].pid, 6);
    assert!(
        listing
            .rows
            .iter()
            .all(|p| p.cpu_percent.is_none() && p.uid == Some(1000))
    );
    let missing = ProcessView {
        uid: Some(9999),
        ..view
    };
    assert!(report.listing(&missing).unwrap().rows.is_empty());
}
#[test]
fn process_table_queries_reject_invalid_limits_and_filters() {
    use xrg_ng_linux::settings::ProcessView;
    let f = Fixture::new();
    f.put(1, &stat(1, "worker", "S", 0, 1, 1), None);
    let report = f.collector().sample_at(1.).unwrap();
    assert!(
        report
            .listing(&ProcessView {
                limit: 9,
                ..Default::default()
            })
            .is_err()
    );
    assert!(
        report
            .listing(&ProcessView {
                filter: "x".repeat(129),
                ..Default::default()
            })
            .is_err()
    );
    let uid = report
        .listing(&ProcessView {
            uid: Some(0),
            ..Default::default()
        })
        .unwrap();
    assert_eq!(uid.matched, 0);
}

#[test]
fn lifetime_cpu_time_uses_the_collectors_clock_without_float_rounding_or_child_time() {
    let f = Fixture::new();
    f.put(7, &stat(7, "worker", "S", 625, 1, 1), None);
    let mut collector = Collector::with_parameters(f.0.clone(), 100, 4096);
    assert_eq!(
        collector.sample_at(1.).unwrap().processes[0].cpu_time,
        Some(std::time::Duration::from_millis(6250))
    );
    f.put(7, &stat(7, "worker", "S", 1, 1, 1), None);
    let mut collector = Collector::with_parameters(f.0.clone(), 1024, 4096);
    assert_eq!(
        collector.sample_at(1.).unwrap().processes[0].cpu_time,
        Some(std::time::Duration::from_nanos(976562))
    );
    f.put(7, &stat(7, "worker", "S", u64::MAX, 1, 1), None);
    let mut collector = Collector::with_parameters(f.0.clone(), 1, 4096);
    assert_eq!(
        collector.sample_at(1.).unwrap().processes[0].cpu_time,
        Some(std::time::Duration::from_secs(u64::MAX))
    );
}
