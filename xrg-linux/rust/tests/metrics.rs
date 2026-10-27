// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    collectors::LinuxSources, metric_sources, metrics::Sampler, settings::MetricSelection,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-metrics-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let f = Self(root);
        f.cpu(0);
        f.net(&[("lo", 9999, 9999), ("eth0", 100, 200), ("wlan0", 300, 500)]);
        f.disk(10, 20, 30, 40, 9999);
        for name in ["sda", "sdb"] {
            fs::create_dir_all(f.0.join(format!("sys/block/{name}"))).unwrap();
        }
        fs::create_dir_all(f.0.join("sys/class/block/sda1")).unwrap();
        for (name, id) in [("lo", 1), ("eth0", 2), ("wlan0", 3)] {
            f.put(&format!("sys/class/net/{name}/ifindex"), &id.to_string());
        }
        f
    }
    fn put(&self, path: &str, value: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, value).unwrap();
    }
    fn source(&self) -> LinuxSources {
        LinuxSources::with_roots(self.0.join("proc"), self.0.join("sys"))
    }
    fn cpu(&self, n: u64) {
        self.put("proc/stat",&format!("cpu {} 0 0 {} 0 0 0 0 900 0\ncpu0 {} 0 0 {} 0 0 0 0 800 0\ncpu2 90 0 0 {} 0 0 0 0 100 0\n",100+50*n,900+150*n,10+50*n,490+50*n,410+100*n));
        self.put("proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 500 kB");
    }
    fn net(&self, values: &[(&str, u64, u64)]) {
        let rows = values
            .iter()
            .map(|(n, a, b)| format!(" {n}: {a} 0 0 0 0 0 0 0 {b} 0 0 0 0 0 0 0"))
            .collect::<Vec<_>>()
            .join("\n");
        self.put("proc/net/dev", &format!("header\nheader\n{rows}\n"));
    }
    fn disk(&self, a: u64, b: u64, c: u64, d: u64, p: u64) {
        self.put("proc/diskstats",&format!("8 0 sda 1 0 {a} 0 1 0 {b} 0 0 0 0\n8 16 sdb 1 0 {c} 0 1 0 {d} 0 0 0 0\n8 1 sda1 1 0 {p} 0 1 0 {p} 0 0 0 0\n"));
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn aggregate_and_per_core_percentages_exclude_guest_and_keep_sparse_indices() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    let first = s.sample(&source, 1.);
    assert!(!first.valid);
    assert_eq!(first.inventory.cpus, [0, 2]);
    f.cpu(1);
    let next = s.sample(&source, 3.);
    assert!(next.valid);
    assert_eq!(next.cpu.series[0].last(), Some(&25.));
    s.set_selection(MetricSelection {
        cpu: Some(0),
        ..Default::default()
    })
    .unwrap();
    f.cpu(2);
    let core = s.sample(&source, 4.);
    assert_eq!(core.cpu.series[0].last(), Some(&50.));
    assert!(core.cpu.series[0][..119].iter().all(|n| *n == 0.));
    assert!(core.cpu.label.starts_with("CPU 0"));
}
#[test]
fn offline_core_does_not_fall_back_to_aggregate_or_fake_idle() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    s.set_selection(MetricSelection {
        cpu: Some(2),
        ..Default::default()
    })
    .unwrap();
    s.sample(&source, 1.);
    f.cpu(1);
    assert_eq!(s.sample(&source, 2.).cpu.series[0].last(), Some(&0.));
    f.put(
        "proc/stat",
        "cpu 200 0 0 1200 0 0 0 0\ncpu0 110 0 0 590 0 0 0 0\n",
    );
    let missing = s.sample(&source, 3.);
    assert!(missing.cpu.series.is_empty());
    assert!(missing.cpu.label.contains("unavailable"));
    f.cpu(3);
    let returned = s.sample(&source, 4.);
    assert!(returned.cpu.series.is_empty());
    assert!(returned.cpu.label.contains("waiting"));
    f.cpu(4);
    assert_eq!(s.sample(&source, 5.).cpu.series[0].last(), Some(&0.));
}
#[test]
fn cpu_recovery_and_invalid_sample_time_clear_the_old_plot() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    s.sample(&source, 1.);
    f.cpu(1);
    assert_eq!(s.sample(&source, 2.).cpu.series[0].last(), Some(&25.));
    f.put("proc/stat", "broken");
    assert!(s.sample(&source, 3.).cpu.series.is_empty());
    f.cpu(3);
    assert!(s.sample(&source, 4.).cpu.series.is_empty());
    f.cpu(4);
    let recovered = s.sample(&source, 5.);
    assert_eq!(recovered.cpu.series[0].last(), Some(&25.));
    assert!(recovered.cpu.series[0][..119].iter().all(|n| *n == 0.));
    assert!(s.sample(&source, f64::NAN).cpu.series.is_empty());
    f.cpu(5);
    assert!(s.sample(&source, 6.).cpu.series.is_empty());
    f.cpu(6);
    let recovered = s.sample(&source, 7.);
    assert!(recovered.cpu.series[0][..119].iter().all(|n| *n == 0.));
}
#[test]
fn chosen_interface_and_loopback_rates_are_distinct_from_aggregate() {
    let f = Fixture::new();
    let source = f.source();
    let mut all = Sampler::default();
    let mut one = Sampler::default();
    one.set_selection(MetricSelection {
        network: Some("eth0".into()),
        ..Default::default()
    })
    .unwrap();
    all.sample(&source, 1.);
    one.sample(&source, 1.);
    f.cpu(1);
    f.net(&[
        ("lo", 14999, 14999),
        ("eth0", 200, 400),
        ("wlan0", 500, 800),
    ]);
    assert_eq!(
        all.sample(&source, 3.).network.series[0].last(),
        Some(&150.)
    );
    let p = one.sample(&source, 3.).network;
    assert_eq!(p.series[0].last(), Some(&50.));
    assert_eq!(p.series[1].last(), Some(&100.));
    one.set_selection(MetricSelection {
        network: Some("lo".into()),
        ..Default::default()
    })
    .unwrap();
    one.sample(&source, 4.);
    f.net(&[
        ("lo", 15999, 16999),
        ("eth0", 200, 400),
        ("wlan0", 500, 800),
    ]);
    let p = one.sample(&source, 5.).network;
    assert_eq!(p.series[0].last(), Some(&1000.));
    assert_eq!(p.series[1].last(), Some(&2000.));
}
#[test]
fn joining_or_leaving_aggregate_members_resets_history_without_counter_spikes() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    s.sample(&source, 1.);
    f.net(&[("eth0", 200, 300), ("wlan0", 400, 600)]);
    assert_eq!(s.sample(&source, 2.).network.series[0].last(), Some(&200.));
    f.put("sys/class/net/veth0/ifindex", "4");
    f.net(&[
        ("eth0", 300, 400),
        ("wlan0", 500, 700),
        ("veth0", 1_000_000_000, 2_000_000_000),
    ]);
    let joined = s.sample(&source, 3.).network;
    assert!(joined.series.iter().flatten().all(|n| *n == 0.));
    f.net(&[
        ("eth0", 400, 500),
        ("wlan0", 600, 800),
        ("veth0", 1_000_000_100, 2_000_000_100),
    ]);
    assert_eq!(s.sample(&source, 4.).network.series[0].last(), Some(&300.));
    f.net(&[("eth0", 500, 600), ("wlan0", 700, 900)]);
    assert_eq!(s.sample(&source, 5.).network.series[0].last(), Some(&0.));
}
#[test]
fn interface_replacement_with_same_name_and_increasing_counter_warms_up() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    s.set_selection(MetricSelection {
        network: Some("eth0".into()),
        ..Default::default()
    })
    .unwrap();
    s.sample(&source, 1.);
    f.put("sys/class/net/eth0/ifindex", "77");
    f.net(&[("eth0", 1_000_000_000, 2_000_000_000)]);
    assert_eq!(s.sample(&source, 2.).network.series[0].last(), Some(&0.));
    f.net(&[("eth0", 1_000_000_100, 2_000_000_200)]);
    assert_eq!(s.sample(&source, 3.).network.series[0].last(), Some(&100.));
}
#[test]
fn disk_aggregate_excludes_partitions_but_an_individual_partition_is_selectable() {
    let f = Fixture::new();
    let source = f.source();
    let mut all = Sampler::default();
    let mut partition = Sampler::default();
    partition
        .set_selection(MetricSelection {
            disk: Some("sda1".into()),
            ..Default::default()
        })
        .unwrap();
    all.sample(&source, 1.);
    partition.sample(&source, 1.);
    f.disk(20, 40, 50, 80, 10099);
    let next = all.sample(&source, 3.);
    assert_eq!(next.disk.series[0].last(), Some(&7680.));
    assert_eq!(next.disk.series[1].last(), Some(&15360.));
    assert!(next.inventory.disks.contains(&"sda1".into()));
    assert_eq!(
        partition.sample(&source, 3.).disk.series[0].last(),
        Some(&25600.)
    );
}
#[test]
fn disk_replacement_identity_and_scope_changes_reset_rates() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    s.set_selection(MetricSelection {
        disk: Some("sda".into()),
        ..Default::default()
    })
    .unwrap();
    s.sample(&source, 1.);
    f.disk(20, 40, 50, 80, 9999);
    assert_eq!(s.sample(&source, 3.).disk.series[0].last(), Some(&2560.));
    fs::rename(f.0.join("sys/block/sda"), f.0.join("old-sda")).unwrap();
    fs::create_dir(f.0.join("sys/block/sda")).unwrap();
    f.disk(1_000_000, 2_000_000, 50, 80, 9999);
    assert_eq!(s.sample(&source, 4.).disk.series[0].last(), Some(&0.));
    s.set_selection(MetricSelection::default()).unwrap();
    assert!(
        s.sample(&source, 5.)
            .disk
            .series
            .iter()
            .flatten()
            .all(|n| *n == 0.)
    );
}
#[test]
fn missing_targets_keep_selection_and_recovery_cannot_charge_old_counters() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    let config = MetricSelection {
        network: Some("absent".into()),
        disk: Some("missing".into()),
        ..Default::default()
    };
    s.set_selection(config.clone()).unwrap();
    s.sample(&source, 1.);
    f.cpu(1);
    let missing = s.sample(&source, 2.);
    assert!(missing.valid);
    assert!(missing.network.series.is_empty() && missing.disk.series.is_empty());
    assert_eq!(s.selection(), &config);
    f.net(&[("absent", 4_000_000_000, 9_000_000_000)]);
    assert_eq!(s.sample(&source, 3.).network.series[0].last(), Some(&0.));
}
#[test]
fn failed_reads_and_regressed_counters_do_not_create_bogus_rates() {
    let f = Fixture::new();
    let source = f.source();
    let mut s = Sampler::default();
    s.sample(&source, 1.);
    f.put("proc/net/dev", "broken");
    assert!(s.sample(&source, 2.).network.series.is_empty());
    f.net(&[("eth0", 1_000_000_000, 2_000_000_000)]);
    assert_eq!(s.sample(&source, 3.).network.series[0].last(), Some(&0.));
    f.net(&[("eth0", 1, 2)]);
    assert_eq!(s.sample(&source, 4.).network.series[0].last(), Some(&0.));
    f.net(&[("eth0", 101, 202)]);
    assert_eq!(s.sample(&source, 5.).network.series[0].last(), Some(&100.));
    assert!(!s.sample(&source, f64::NAN).valid);
    assert_eq!(s.sample(&source, 6.).network.series[0].last(), Some(&0.));
}
#[test]
fn duplicate_malformed_overflowed_and_unsafe_rows_are_rejected() {
    assert!(metric_sources::cpu_records("cpu 1 0 0 9\ncpu0 1 0 0 9\ncpu0 2 0 0 9").is_err());
    assert!(metric_sources::cpu_records("cpu 1 0 0 9\ncpu1048576 1 0 0 9").is_err());
    assert!(metric_sources::network_records("h\nh\n ..: 1 0 0 0 0 0 0 0 2 0 0 0 0 0 0 0").is_err());
    assert!(metric_sources::network_records("h\nh\neth0: 1 2").is_err());
    assert!(metric_sources::disk_records("8 0 sda 1 0 18446744073709551615 0 1 0 20").is_err());
    assert!(metric_sources::disk_records("8 0 ../sda 1 0 10 0 1 0 20").is_err());
}
#[test]
fn cpu_inventory_and_proc_read_sizes_are_bounded() {
    let mut text = "cpu 1 0 0 9\n".to_owned();
    for n in 0..8193 {
        text.push_str(&format!("cpu{n} 1 0 0 9\n"));
    }
    assert!(metric_sources::cpu_records(&text).is_err());
    let f = Fixture::new();
    fs::File::create(f.0.join("proc/stat"))
        .unwrap()
        .set_len(4 * 1024 * 1024 + 1)
        .unwrap();
    assert!(metric_sources::cpus(&f.source()).is_err());
}
