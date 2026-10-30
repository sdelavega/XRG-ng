// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    collectors::LinuxSources,
    engine::Sampler,
    memory::{self, Paging, View},
};
const MEM: &str = "MemTotal: 1000 kB\nMemAvailable: 600 kB\nMemFree: 100 kB\nBuffers: 20 kB\nCached: 200 kB\nSlab: 50 kB\nSReclaimable: 30 kB\nSUnreclaim: 20 kB\nShmem: 40 kB\nDirty: 0 kB\nWriteback: 0 kB\nSwapTotal: 400 kB\nSwapFree: 300 kB\nHugePages_Total: 0\n";
#[test]
fn memory_capacity_preserves_paging_intervals_and_survives_missing_or_replaced_inputs() {
    let reading = memory::parse(MEM);
    let mut view = View::default();
    view.set_history_samples(3).unwrap();
    view.panel(&reading, &paging([100, 200], [2, 4]), 1.);
    view.panel(&reading, &paging([200, 400], [4, 8]), 2.);
    view.set_history_samples(6).unwrap();
    let p = view.panel(&reading, &paging([300, 600], [6, 12]), 3.);
    assert!(p.series.iter().all(|v| v.len() == 6 && v[0].is_nan()));
    assert_eq!(&p.series[0][4..], &[40., 40.]);
    assert!(p.detail.contains("Page I/O in / out: 100.0 / 200.0 KiB/s"));
    assert!(p.detail.contains("Swap in / out: 2.0 / 4.0 pages/s"));
    view.clear_graph();
    let p = view.panel(&reading, &paging([400, 800], [8, 16]), 4.);
    assert!(
        p.series
            .iter()
            .all(|v| v.len() == 6 && v[..5].iter().all(|x| x.is_nan()))
    );
    assert!(view.set_history_samples(20001).is_err());
    view.panel(&Err("unreadable".into()), &Err("unreadable".into()), 5.);
    let p = view.panel(&reading, &paging([600, 1200], [12, 24]), 6.);
    assert!(p.series.iter().all(|v| v.len() == 6));
    let changed = memory::parse(
        &MEM.replace("MemTotal: 1000", "MemTotal: 2000")
            .replace("SwapTotal: 400", "SwapTotal: 800"),
    );
    let p = view.panel(&changed, &paging([700, 1400], [14, 28]), 7.);
    assert!(p.series.iter().all(|v| v.len() == 6));
    view.set_history_samples(0).unwrap();
    assert!(
        view.panel(&changed, &paging([800, 1600], [16, 32]), 8.)
            .series
            .iter()
            .all(|v| v.len() == 120)
    );
}
fn paging(io: [u64; 2], swap: [u64; 2]) -> Result<Paging, String> {
    Ok(Paging {
        io_kib: Ok(io),
        swap_pages: Ok(swap),
    })
}
#[test]
fn ram_and_swap_use_separate_totals_and_keep_native_memory_categories() {
    let m = memory::parse(MEM).unwrap();
    assert_eq!(
        (m.total, m.available, m.cached),
        (1_024_000, 614_400, Some(204_800))
    );
    assert_eq!(m.used_percent(), 40.);
    assert_eq!(
        m.swap.as_ref().map(|s| (s.total, s.used)),
        Some((409_600, 102_400))
    );
    assert!(m.notes.is_empty());
    let panel = View::default().panel(&Ok(m), &paging([100, 200], [2, 4]), 1.);
    assert_eq!(panel.label, "RAM 40.0% · cache 20.0% · swap 25.0%");
    assert_eq!(
        panel
            .series
            .iter()
            .map(|s| *s.last().unwrap())
            .collect::<Vec<_>>(),
        [40., 20., 25.]
    );
    assert!(panel.detail.contains("Buffers: 0.0 MiB") && panel.detail.contains("Slab:"));
    assert!(panel.detail.contains("not stacked") && panel.detail.contains("not macOS wired"));
}
#[test]
fn required_memory_counters_reject_duplicates_wrong_units_overflow_and_invalid_totals() {
    for text in [
        "MemTotal: 1000 kB\n",
        "MemTotal: 0 kB\nMemAvailable: 0 kB",
        "MemTotal: 1 kB\nMemAvailable: 2 kB",
        "MemTotal: 1000 MB\nMemAvailable: 600 kB",
        "MemTotal: 1000 kB extra\nMemAvailable: 600 kB",
        "MemTotal: 18446744073709551615 kB\nMemAvailable: 0 kB",
        "MemTotal: 1000 kB\nMemAvailable: 600 kB\nMemTotal: 1000 kB",
        "MemTotal: 1000 kB\nMemAvailable: -1 kB",
        "MemTotal: +1000 kB\nMemAvailable: 0 kB",
    ] {
        assert!(memory::parse(text).is_err(), "{text}");
    }
}
#[test]
fn optional_failures_preserve_ram_without_turning_missing_swap_or_cache_into_zero() {
    let text = MEM
        .replace("Cached: 200 kB", "Cached: 200 MB")
        .replace("SwapFree: 300 kB", "SwapFree: 500 kB");
    let report = memory::parse(&text).unwrap();
    assert_eq!(report.used_percent(), 40.);
    assert!(report.cached.is_none() && report.swap.is_none());
    assert!(report.notes.iter().any(|e| e.contains("Cached:")));
    let panel = View::default().panel(&Ok(report), &Err("offline".into()), 1.);
    assert_eq!(panel.series.len(), 1);
    assert!(panel.label.contains("swap n/a") && panel.detail.contains("SwapFree exceeds"));
    for line in [
        "Cached: 1001 kB",
        "Cached: 10 kB\nCached: 10 kB",
        "Cached: 18446744073709551615 kB",
    ] {
        assert!(
            memory::parse(&MEM.replace("Cached: 200 kB", line))
                .unwrap()
                .cached
                .is_none()
        );
    }
    let m = memory::parse("MemTotal: 1000 kB\nMemAvailable: 0 kB").unwrap();
    assert_eq!(m.used_percent(), 100.);
    assert!(m.swap.is_none());
}
#[test]
fn no_swap_is_distinct_from_enabled_but_empty_swap_and_capacity_changes_reset_history() {
    let mut view = View::default();
    let no_swap = MEM
        .replace("SwapTotal: 400 kB", "SwapTotal: 0 kB")
        .replace("SwapFree: 300 kB", "SwapFree: 0 kB");
    let panel = view.panel(&memory::parse(&no_swap), &paging([0, 0], [0, 0]), 1.);
    assert_eq!(panel.series.len(), 2);
    assert!(panel.label.contains("no swap"));
    let empty = MEM.replace("SwapFree: 300 kB", "SwapFree: 400 kB");
    let panel = view.panel(&memory::parse(&empty), &paging([0, 0], [0, 0]), 2.);
    assert_eq!(panel.series[2].last(), Some(&0.));
    view.panel(&memory::parse(MEM), &paging([0, 0], [0, 0]), 3.);
    let resized = MEM.replace("SwapTotal: 400 kB", "SwapTotal: 600 kB");
    let panel = view.panel(&memory::parse(&resized), &paging([0, 0], [0, 0]), 4.);
    assert_eq!(&panel.series[2][118..], &[0., 50.]);
    let panel = view.panel(
        &memory::parse(&MEM.replace("MemTotal: 1000 kB", "MemTotal: 2000 kB")),
        &paging([0, 0], [0, 0]),
        5.,
    );
    assert_eq!(&panel.series[0][118..], &[0., 70.]);
    assert_eq!(&panel.series[1][118..], &[0., 10.]);
}
#[test]
fn paging_pairs_validate_independently_and_never_confuse_kib_with_pages() {
    let p =
        memory::paging("pgpgin 1024\npgpgout 2048\npswpin 3\npswpout 4\nnr_free_pages 0").unwrap();
    assert_eq!(p.io_kib, Ok([1024, 2048]));
    assert_eq!(p.swap_pages, Ok([3, 4]));
    for extra in [
        "pgpgin 2",
        "pgpgout -1",
        "pgpgout 3 kB",
        "pgpgout 18446744073709551616",
    ] {
        let p = memory::paging(&format!(
            "pgpgin 1\npgpgout 1\npswpin 0\npswpout 0\n{extra}"
        ))
        .unwrap();
        assert!(p.io_kib.is_err());
        assert_eq!(p.swap_pages, Ok([0, 0]));
    }
    assert!(memory::paging(&"x".repeat(256 * 1024 + 1)).is_err());
    assert!(memory::parse(&format!("{MEM}{}", "x\n".repeat(4097))).is_err());
    assert!(memory::parse(&format!("{MEM}{}", "x".repeat(4097))).is_err());
}
#[test]
fn elapsed_rates_wait_for_intervals_and_rebaseline_after_failures_resets_or_clock_gaps() {
    let mut view = View::default();
    let m = memory::parse(MEM);
    let first = view.panel(&m, &paging([1000, 2000], [10, 20]), 1.);
    assert!(
        first.detail.contains("Page I/O: waiting") && first.detail.contains("Swap I/O: waiting")
    );
    let panel = view.panel(&m, &paging([1100, 2200], [14, 28]), 3.);
    assert!(
        panel
            .detail
            .contains("Page I/O in / out: 50.0 / 100.0 KiB/s")
    );
    assert!(panel.detail.contains("Swap in / out: 2.0 / 4.0 pages/s"));
    view.panel(&m, &Err("vmstat unavailable".into()), 4.);
    let recovered = view.panel(&m, &paging([9000, 9000], [100, 100]), 5.);
    assert!(recovered.detail.contains("Page I/O: waiting"));
    for time in [5., 400., f64::NAN, 402.] {
        let panel = view.panel(&m, &paging([9000, 9000], [100, 100]), time);
        assert!(
            panel.detail.contains("Page I/O: waiting")
                || panel.detail.contains("invalid sample time")
        );
    }
    let reset = view.panel(&m, &paging([1, 9001], [1, 101]), 403.);
    assert!(
        reset.detail.contains("Page I/O: waiting") && reset.detail.contains("Swap I/O: waiting")
    );
    let zero = view.panel(&m, &paging([1, 9001], [1, 101]), 405.);
    assert!(zero.detail.contains("Page I/O in / out: 0.0 / 0.0 KiB/s"));
    assert!(zero.detail.contains("Swap in / out: 0.0 / 0.0 pages/s"));
}
#[test]
fn memory_failure_and_missing_optional_series_clear_their_own_histories() {
    let mut view = View::default();
    view.panel(&memory::parse(MEM), &paging([0, 0], [0, 0]), 1.);
    let failed = view.panel(
        &Err("meminfo offline".into()),
        &paging([999, 999], [999, 999]),
        2.,
    );
    assert!(failed.series.is_empty() && failed.label.contains("unavailable"));
    let recovered = view.panel(&memory::parse(MEM), &paging([999, 999], [999, 999]), 3.);
    assert_eq!(&recovered.series[0][118..], &[0., 40.]);
    assert!(recovered.detail.contains("Page I/O: waiting"));
    view.panel(
        &memory::parse(&MEM.replace("Cached: 200 kB\n", "")),
        &paging([999, 999], [999, 999]),
        4.,
    );
    let panel = view.panel(&memory::parse(MEM), &paging([999, 999], [999, 999]), 5.);
    assert_eq!(&panel.series[1][118..], &[0., 20.]);
    assert_eq!(&panel.series[2][118..], &[25., 25.]);
}
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "xrg-memory-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(p.join("proc/net")).unwrap();
        fs::create_dir_all(p.join("sys/block/sda")).unwrap();
        fs::write(p.join("proc/stat"), "cpu 1 0 0 1 0 0 0 0").unwrap();
        fs::write(p.join("proc/meminfo"), MEM).unwrap();
        fs::write(
            p.join("proc/vmstat"),
            "pgpgin 1\npgpgout 2\npswpin 0\npswpout 0",
        )
        .unwrap();
        fs::write(
            p.join("proc/net/dev"),
            "h\nh\nlo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0",
        )
        .unwrap();
        fs::write(p.join("proc/diskstats"), "8 0 sda 1 0 10 0 1 0 20 0 0 0 0").unwrap();
        Self(p)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn sampler_publishes_memory_details_and_bounded_reads_reject_symlinks_special_files_and_invalid_utf8()
 {
    let f = Fixture::new();
    let root = f.0.join("proc");
    let mut sampler = Sampler::with_sources(LinuxSources::with_roots(&root, f.0.join("sys")));
    let snapshot = sampler.sample();
    assert_eq!(snapshot.panels.len(), 13);
    assert_eq!(snapshot.panels[1].series.len(), 3);
    assert!(snapshot.panels[1].detail.contains("Swap used:"));
    fs::remove_file(root.join("meminfo")).unwrap();
    std::os::unix::fs::symlink(root.join("vmstat"), root.join("meminfo")).unwrap();
    assert!(memory::read(&root).is_err());
    fs::remove_file(root.join("meminfo")).unwrap();
    fs::create_dir(root.join("meminfo")).unwrap();
    assert!(memory::read(&root).is_err());
    fs::remove_dir(root.join("meminfo")).unwrap();
    fs::write(root.join("meminfo"), [0xff, 0xfe]).unwrap();
    assert!(memory::read(&root).is_err());
    fs::write(root.join("meminfo"), "x".repeat(256 * 1024 + 1)).unwrap();
    assert!(memory::read(&root).is_err());
    assert!(sampler.sample().panels[1].series.is_empty());
}

#[test]
fn memory_time_windows_preserve_percentages_and_paging_intervals_through_mode_cadence_and_graph_edits()
 {
    let reading = memory::parse(MEM);
    let mut view = View::default();
    view.set_history_samples(3).unwrap();
    view.panel_at(&reading, &paging([100, 200], [2, 4]), 1., 100.);
    view.set_time_window(1).unwrap();
    let p = view.panel_at(&reading, &paging([200, 400], [4, 8]), 2., 110.);
    assert_eq!(p.series.len(), 3);
    for (series, value) in p.series.iter().zip([40., 20., 25.]) {
        assert_eq!(series.len(), 61);
        assert_eq!(series[50], value);
        assert_eq!(series[60], value);
        assert!(series[51..60].iter().all(|v| v.is_nan()));
    }
    assert!(p.detail.contains("Page I/O in / out: 100.0 / 200.0 KiB/s"));
    view.set_history_samples(6).unwrap();
    view.set_history_interval(0.2);
    let p = view.panel_at(&reading, &paging([300, 600], [6, 12]), 3., 111.);
    assert!(p.series.iter().all(|v| v.len() == 301));
    assert!(p.detail.contains("Swap in / out: 2.0 / 4.0 pages/s"));
    view.clear_graph();
    let p = view.panel_at(&reading, &paging([400, 800], [8, 16]), 4., 112.);
    assert!(p.series.iter().all(|v| v[..300].iter().all(|x| x.is_nan())));
    assert!(p.detail.contains("Page I/O in / out: 100.0 / 200.0 KiB/s"));
    let p = view.panel_at(&reading, &paging([500, 1000], [10, 20]), 5., 50.);
    assert!(p.series.iter().all(|v| v[..300].iter().all(|x| x.is_nan())));
    assert!(p.detail.contains("Swap in / out: 2.0 / 4.0 pages/s"));
    assert!(view.set_time_window(61).is_err());
    view.set_time_window(0).unwrap();
    assert!(
        view.panel_at(&reading, &paging([600, 1200], [12, 24]), 6., 51.)
            .series
            .iter()
            .all(|v| v.len() == 6)
    );
}
#[test]
fn memory_time_gaps_keep_channel_identity_and_capacity_boundaries_independent() {
    let reading = memory::parse(MEM);
    let mut view = View::default();
    view.set_time_window(1).unwrap();
    view.panel_at(&reading, &paging([100, 200], [2, 4]), 1., 100.);
    let p = view.panel_at(&Err("offline".into()), &Err("offline".into()), 2., 110.);
    assert!(p.series.is_empty());
    let p = view.panel_at(&reading, &paging([200, 400], [4, 8]), 3., 111.);
    assert!(p.detail.contains("waiting for a fresh interval"));
    for series in &p.series {
        assert!(series[49].is_finite() && series[59].is_nan() && series[60].is_finite());
    }
    let missing = memory::parse(
        &MEM.replace("Cached: 200 kB\n", "")
            .replace("SwapTotal: 400 kB\n", ""),
    );
    assert_eq!(
        view.panel_at(&missing, &paging([300, 600], [6, 12]), 4., 112.)
            .series
            .len(),
        1
    );
    let p = view.panel_at(&reading, &paging([400, 800], [8, 16]), 5., 113.);
    assert!(p.series[0][59].is_finite());
    assert!(p.series[1][59].is_nan() && p.series[2][59].is_nan());
    let changed = memory::parse(&MEM.replace("MemTotal: 1000 kB", "MemTotal: 2000 kB"));
    let p = view.panel_at(&changed, &paging([500, 1000], [10, 20]), 6., 114.);
    assert!(
        p.series[0][..60].iter().all(|v| v.is_nan())
            && p.series[1][..60].iter().all(|v| v.is_nan())
    );
    assert_eq!(p.series[2][59], 25.);
    let swap_changed = memory::parse(
        &MEM.replace("MemTotal: 1000 kB", "MemTotal: 2000 kB")
            .replace("SwapTotal: 400 kB", "SwapTotal: 800 kB"),
    );
    let p = view.panel_at(&swap_changed, &paging([600, 1200], [12, 24]), 7., 115.);
    assert_eq!(p.series[0][59], 70.);
    assert!(p.series[2][..60].iter().all(|v| v.is_nan()));
    let no_swap = memory::parse(
        &MEM.replace("MemTotal: 1000 kB", "MemTotal: 2000 kB")
            .replace("SwapTotal: 400 kB", "SwapTotal: 0 kB")
            .replace("SwapFree: 300 kB", "SwapFree: 0 kB"),
    );
    assert_eq!(
        view.panel_at(&no_swap, &paging([700, 1400], [14, 28]), 8., 116.)
            .series
            .len(),
        2
    );
    let p = view.panel_at(&swap_changed, &paging([800, 1600], [16, 32]), 9., 117.);
    assert!(p.series[2][..60].iter().all(|v| v.is_nan()));
    assert!(p.detail.contains("Page I/O in / out: 100.0 / 200.0 KiB/s"));
}
