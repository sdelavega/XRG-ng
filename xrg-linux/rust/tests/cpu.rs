// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::Duration,
};
use xrg_ng_linux::{
    collectors::{cpu, cpu_percent, cpu_usage},
    cpu::{self as presentation, Overview, View},
    metric_sources,
};
fn overview() -> Overview {
    Overview {
        load: presentation::load("1.25 2.50 3.75 2/123 42\n"),
        uptime: presentation::uptime("90061.50 180123.00\n"),
    }
}
fn records(n: u64, cores: bool) -> Result<metric_sources::CpuRecords, String> {
    let counters = format!(
        "{} {} {} {} {} {} {} {} 900 800",
        100 + 20 * n,
        10 + 5 * n,
        30 + 10 * n,
        800 + 50 * n,
        10 + 5 * n,
        2 + 2 * n,
        3 + 3 * n,
        5 + 5 * n
    );
    metric_sources::cpu_records(&format!(
        "cpu {counters}\n{}",
        if cores {
            format!("cpu0 {counters}\ncpu2 {counters}\n")
        } else {
            String::new()
        }
    ))
}
#[test]
fn user_nice_kernel_interrupt_and_steal_deltas_share_one_denominator_without_extra_guest_time() {
    let before = cpu("cpu 100 10 30 800 10 2 3 5 900 800").unwrap();
    let after = cpu("cpu 120 15 40 850 15 4 6 10 999 999").unwrap();
    let usage = cpu_usage(before, after).unwrap();
    assert_eq!(
        (
            usage.busy,
            usage.user,
            usage.system,
            usage.nice,
            usage.steal,
            usage.iowait,
            usage.idle
        ),
        (45., 25., 15., 5., 5., 5., 50.)
    );
    assert_eq!(usage.user + usage.system + usage.steal, usage.busy);
    assert_eq!(cpu_percent(before, after), Some(45.));
    assert_eq!(before.total, 960);
}
#[test]
fn individual_counter_regressions_do_not_hide_behind_increasing_total_or_idle_sums() {
    let before = cpu("cpu 100 10 30 800 10 2 3 5").unwrap();
    for raw in [
        "cpu 200 10 30 900 9 2 3 5",
        "cpu 200 9 30 900 20 2 3 5",
        "cpu 200 10 29 900 20 2 3 5",
        "cpu 200 10 30 900 20 1 3 5",
        "cpu 200 10 30 900 20 2 2 5",
        "cpu 200 10 30 900 20 2 3 4",
    ] {
        let next = cpu(raw).unwrap();
        assert!(next.total > before.total);
        assert_eq!(cpu_percent(before, next), None, "{raw}");
    }
    assert!(cpu_usage(before, before).is_none());
    assert!(cpu_usage(before, cpu("cpu 200 10 30 900").unwrap()).is_none());
    for text in [
        "cpu 1 2 3",
        "cpu 1 2 3 4 0 0 0 0 0 0 1",
        "cpu 18446744073709551615 1 0 0",
        "cpu 1 2 3 4 invalid",
        "cpu 1 2 3 4 0 0 0 0 NaN",
    ] {
        assert!(cpu(text).is_err(), "{text}");
    }
}
#[test]
fn system_load_is_a_count_and_uptime_accepts_combined_idle_above_elapsed_time() {
    let load = presentation::load("12.00 8.50 4.25 12/512 2147483647\n").unwrap();
    assert_eq!(load.averages, [12., 8.5, 4.25]);
    assert_eq!(
        (load.runnable, load.tasks, load.last_pid),
        (12, 512, i32::MAX as u32)
    );
    assert_eq!(
        presentation::uptime("90061.50 1000000.00\n"),
        Ok(Duration::from_millis(90_061_500))
    );
    assert_eq!(presentation::uptime("0.00 0.00"), Ok(Duration::ZERO));
    for text in [
        "NaN 0 0 0/1 1",
        "inf 0 0 0/1 1",
        "-1 0 0 0/1 1",
        "1e3 0 0 0/1 1",
        "1 0 0 2/1 1",
        "1 0 0 0/0 1",
        "1 0 0 1/2/3 1",
        "1 0 0 1/2 2147483648",
        "1 0 0 1/2 1 extra",
        "1 0\n0 1/2 1",
    ] {
        assert!(presentation::load(text).is_err(), "{text}");
    }
    for text in [
        "NaN 0",
        "-1 0",
        "1 NaN",
        "18446744073709551616 0",
        "1. 0",
        "1 0 0",
        "1\n0",
    ] {
        assert!(presentation::uptime(text).is_err(), "{text}");
    }
    assert!(presentation::load(&"1".repeat(4097)).is_err());
}
#[test]
fn cpu_curves_and_auxiliary_readings_reach_details_with_distinct_scopes() {
    let mut view = View::default();
    let first = view.panel(records(0, true), &overview(), None, 1.).0;
    assert!(first.series.is_empty());
    assert!(
        first.detail.contains("1.25 / 2.50 / 3.75") && first.detail.contains("Uptime: 1d 01:01:01")
    );
    let (panel, valid, inventory) = view.panel(records(1, true), &overview(), None, 2.);
    assert!(valid);
    assert_eq!(inventory, [0, 2]);
    assert_eq!(
        panel
            .series
            .iter()
            .map(|s| *s.last().unwrap())
            .collect::<Vec<_>>(),
        [45., 25., 15.]
    );
    assert!(panel.detail.contains("Steal: 5.0%") && panel.detail.contains("not CPU percent"));
    let panel = view.panel(records(2, true), &overview(), Some(2), 3.).0;
    assert!(panel.label.starts_with("CPU 2"));
    assert!(panel.detail.contains("logical CPU 2") && panel.detail.contains("stay system-wide"));
    assert_eq!(&panel.series[0][118..], &[0., 45.]);
}
#[test]
fn missing_optional_overview_files_never_suppress_cpu_or_leave_stale_overview_values() {
    let mut view = View::default();
    view.panel(records(0, false), &overview(), None, 1.);
    let missing = Overview {
        load: Err("loadavg missing".into()),
        uptime: Err("uptime missing".into()),
    };
    let (panel, valid, inventory) = view.panel(records(1, false), &missing, None, 2.);
    assert!(valid && inventory.is_empty());
    assert_eq!(panel.series[0].last(), Some(&45.));
    assert!(
        panel.detail.contains("Load average: unavailable")
            && panel.detail.contains("Uptime: unavailable")
    );
    assert!(!panel.detail.contains("1.25 / 2.50 / 3.75"));
    let broken = view
        .panel(Err("stat unreadable".into()), &overview(), None, 3.)
        .0;
    assert!(broken.series.is_empty() && broken.detail.contains("Uptime: 1d"));
    assert!(
        view.panel(records(2, false), &overview(), None, 4.)
            .0
            .series
            .is_empty()
    );
    let recovered = view.panel(records(3, false), &overview(), None, 5.).0;
    assert_eq!(&recovered.series[0][118..], &[0., 45.]);
}
#[test]
fn hotplug_resets_aggregate_but_an_existing_selected_core_keeps_its_own_baseline() {
    let mut all = View::default();
    let mut one = View::default();
    all.panel(records(0, true), &overview(), None, 1.);
    one.panel(records(0, true), &overview(), Some(0), 1.);
    let mut next = records(1, true).unwrap();
    next.cores.remove(&2);
    assert!(
        all.panel(Ok(next.clone()), &overview(), None, 2.)
            .0
            .series
            .is_empty()
    );
    assert_eq!(
        one.panel(Ok(next), &overview(), Some(0), 2.).0.series[0].last(),
        Some(&45.)
    );
    let mut next = records(2, true).unwrap();
    next.cores.remove(&2);
    let panel = all.panel(Ok(next), &overview(), None, 3.).0;
    assert_eq!(&panel.series[0][118..], &[0., 45.]);
    let mut absent = records(3, true).unwrap();
    absent.cores.remove(&0);
    let panel = one.panel(Ok(absent), &overview(), Some(0), 4.).0;
    assert!(panel.label.contains("unavailable") && panel.series.is_empty());
    assert!(
        one.panel(records(4, true), &overview(), Some(0), 5.)
            .0
            .series
            .is_empty()
    );
}
#[test]
fn clock_regressions_stale_gaps_and_raw_resets_wait_for_a_fresh_interval() {
    for time in [1., 0.5, 302., f64::NAN, -1.] {
        let mut view = View::default();
        view.panel(records(0, true), &overview(), None, 1.);
        assert!(
            view.panel(records(1, true), &overview(), None, time)
                .0
                .series
                .is_empty()
        );
    }
    let mut view = View::default();
    view.panel(records(0, true), &overview(), None, 1.);
    view.panel(records(1, true), &overview(), None, 2.);
    assert!(
        view.panel(records(0, true), &overview(), None, 3.)
            .0
            .series
            .is_empty()
    );
    let panel = view.panel(records(1, true), &overview(), None, 4.).0;
    assert_eq!(&panel.series[0][118..], &[0., 45.]);
    let mut idle = View::default();
    let a = metric_sources::cpu_records("cpu 0 0 0 100 0 0 0 0");
    idle.panel(a, &overview(), None, 1.);
    let panel = idle
        .panel(
            metric_sources::cpu_records("cpu 0 0 0 200 0 0 0 0"),
            &overview(),
            None,
            2.,
        )
        .0;
    assert!(panel.series.iter().all(|s| s.last() == Some(&0.)));
}
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn optional_readers_are_bounded_and_reject_symlinks_special_files_and_invalid_encoding() {
    let f = Fixture(std::env::temp_dir().join(format!(
        "xrg-cpu-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    )));
    fs::create_dir(&f.0).unwrap();
    fs::write(f.0.join("loadavg"), "1.25 2.50 3.75 2/123 42\n").unwrap();
    fs::write(f.0.join("uptime"), "90061.50 180123.00\n").unwrap();
    let read = presentation::overview(&f.0);
    assert!(read.load.is_ok() && read.uptime.is_ok());
    fs::remove_file(f.0.join("loadavg")).unwrap();
    std::os::unix::fs::symlink(f.0.join("uptime"), f.0.join("loadavg")).unwrap();
    assert!(presentation::overview(&f.0).load.is_err());
    fs::remove_file(f.0.join("loadavg")).unwrap();
    fs::create_dir(f.0.join("loadavg")).unwrap();
    assert!(presentation::overview(&f.0).load.is_err());
    fs::remove_dir(f.0.join("loadavg")).unwrap();
    fs::write(f.0.join("loadavg"), [0xff, 0xfe]).unwrap();
    assert!(presentation::overview(&f.0).load.is_err());
    fs::write(f.0.join("loadavg"), "1".repeat(4097)).unwrap();
    assert!(presentation::overview(&f.0).load.is_err());
    assert!(presentation::overview(&f.0).uptime.is_ok());
}
