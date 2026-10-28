// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::SystemTime,
};
use xrg_ng_linux::tpu::{Collector, Device};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-npu-clients-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        let f = Self(root);
        f.device("0000:01:00.0", "accel0", "0x17f0");
        f
    }
    fn put(&self, path: impl AsRef<Path>, value: impl AsRef<[u8]>) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, value).unwrap();
    }
    fn link(&self, target: impl AsRef<Path>, alias: impl AsRef<Path>) {
        let path = self.0.join(alias);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        symlink(target, path).unwrap();
    }
    fn device(&self, pci: &str, node: &str, id: &str) {
        let physical = self.0.join(format!("sys/devices/{pci}"));
        self.put(format!("sys/devices/{pci}/vendor"), "0x1022");
        self.put(format!("sys/devices/{pci}/device"), id);
        fs::create_dir_all(self.0.join("sys/drivers/amdxdna")).unwrap();
        self.link(
            self.0.join("sys/drivers/amdxdna"),
            format!("sys/devices/{pci}/driver"),
        );
        self.link(&physical, format!("sys/bus/pci/devices/{pci}"));
        self.link(&physical, format!("sys/class/accel/{node}/device"));
    }
    fn record(&self, pid: u32, fd: u32, node: &str, pci: &str, client: u64, counter: &str) {
        let link = self.0.join(format!("proc/{pid}/fd/{fd}"));
        if !link.is_symlink() {
            self.link(format!("/dev/accel/{node}"), format!("proc/{pid}/fd/{fd}"));
        }
        self.put(format!("proc/{pid}/fdinfo/{fd}"), format!("drm-driver: amdxdna_accel_driver\ndrm-client-id: {client}\ndrm-pdev: {pci}\n{counter}\n"));
    }
    fn busy(&self, pid: u32, fd: u32, client: u64, total: u64) {
        self.record(
            pid,
            fd,
            "accel0",
            "0000:01:00.0",
            client,
            &format!("drm-engine-npu: {total} ns"),
        );
    }
    fn collector(&self) -> Collector {
        Collector::new(self.0.join("sys"), None).with_proc_root(self.0.join("proc"))
    }
    fn sample(&self, collector: &mut Collector, time: f64) -> Vec<Device> {
        collector
            .sample_at(time, SystemTime::now())
            .devices
            .unwrap()
            .values
    }
    fn one(&self, collector: &mut Collector, time: f64) -> Device {
        self.sample(collector, time).remove(0)
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn amd_client_warmup_zero_and_busiest_client_are_not_device_occupancy_or_a_sum() {
    let f = Fixture::new();
    f.busy(10, 3, 1, 100_000_000);
    f.busy(20, 4, 2, 200_000_000);
    let mut c = f.collector();
    let first = f.one(&mut c, 1.);
    assert!(first.utilization.is_none());
    assert_eq!(first.client_activity.unwrap().percent, None);
    f.busy(10, 3, 1, 600_000_000);
    f.busy(20, 4, 2, 1_000_000_000);
    let d = f.one(&mut c, 2.);
    assert!(d.utilization.is_none());
    assert_eq!(d.activity_percent(), Some(80.));
    assert_eq!(d.client_activity.unwrap().clients, 2);
    assert_eq!(f.one(&mut c, 3.).activity_percent(), Some(0.));
}
#[test]
fn inherited_fds_deduplicate_and_equal_client_ids_on_different_devices_do_not() {
    let f = Fixture::new();
    f.device("0000:02:00.0", "accel1", "0x1502");
    f.busy(10, 3, 1, 0);
    f.busy(20, 4, 1, 0);
    f.record(10, 5, "accel1", "0000:02:00.0", 1, "drm-engine-npu: 0 ns");
    let mut c = f.collector();
    f.sample(&mut c, 1.);
    f.busy(10, 3, 1, 500_000_000);
    f.busy(20, 4, 1, 500_000_000);
    f.record(
        10,
        5,
        "accel1",
        "0000:02:00.0",
        1,
        "drm-engine-npu: 250000000 ns",
    );
    let devices = f.sample(&mut c, 2.);
    assert_eq!(devices[0].activity_percent(), Some(50.));
    assert_eq!(devices[0].client_activity.as_ref().unwrap().clients, 1);
    assert_eq!(devices[1].activity_percent(), Some(25.));
}
#[test]
fn wrong_pci_driver_node_engine_capacity_and_units_are_not_measurements() {
    for case in 0..8 {
        let f = Fixture::new();
        f.busy(10, 3, 1, 0);
        let path = "proc/10/fdinfo/3";
        let original = fs::read_to_string(f.0.join(path)).unwrap();
        let invalid = match case {
            0 => original.replace("0000:01:00.0", "0000:02:00.0"),
            1 => original.replace("amdxdna_accel_driver", "amdgpu"),
            2 => original.replace("0 ns", "0 cycles"),
            3 => original.replace("drm-engine-npu", "drm-engine-amdxdna_accel_driver"),
            4 => format!("{original}drm-engine-capacity-npu: 2\n"),
            5 => format!("{original}drm-engine-npu: 0 ns\n"),
            6 => original.replace(
                "drm-engine-npu: 0 ns",
                "drm-cycles-npu: 0\ndrm-total-cycles-npu: 0",
            ),
            7 => {
                fs::remove_file(f.0.join("proc/10/fd/3")).unwrap();
                f.link("/dev/dri/renderD128", "proc/10/fd/3");
                original
            }
            _ => unreachable!(),
        };
        f.put(path, invalid);
        let mut c = f.collector();
        assert!(f.one(&mut c, 1.).client_activity.is_none(), "case {case}");
        assert!(
            f.one(&mut c, 2.).activity_percent().is_none(),
            "case {case}"
        );
    }
}
#[test]
fn counter_regressions_gaps_and_clock_changes_wait_for_valid_intervals() {
    let f = Fixture::new();
    f.busy(10, 3, 1, 1_000_000_000);
    let mut c = f.collector();
    f.one(&mut c, 1.);
    f.busy(10, 3, 1, 500_000_000);
    assert!(f.one(&mut c, 2.).activity_percent().is_none());
    f.busy(10, 3, 1, 1_500_000_000);
    assert_eq!(f.one(&mut c, 3.).activity_percent(), Some(25.));
    assert!(f.one(&mut c, 3.).activity_percent().is_none());
    assert!(f.one(&mut c, 2.).activity_percent().is_none());
    assert!(f.one(&mut c, 303.).activity_percent().is_none());
    assert_eq!(f.one(&mut c, 304.).activity_percent(), Some(0.));
    assert!(f.one(&mut c, f64::NAN).client_activity.is_none());
    assert!(f.one(&mut c, 305.).activity_percent().is_none());
}
#[test]
fn new_lost_and_rebound_clients_change_scope_and_warm_up_again() {
    let f = Fixture::new();
    f.busy(10, 3, 1, 0);
    let mut c = f.collector();
    let before = f.one(&mut c, 1.).client_activity.unwrap().scope;
    f.busy(20, 4, 2, 0);
    let joined = f.one(&mut c, 2.).client_activity.unwrap();
    assert_ne!(before, joined.scope);
    assert_eq!(joined.percent, None);
    assert_eq!(f.one(&mut c, 3.).activity_percent(), Some(0.));
    fs::remove_dir_all(f.0.join("proc/20")).unwrap();
    let left = f.one(&mut c, 4.).client_activity.unwrap();
    assert_ne!(left.scope, joined.scope);
    fs::rename(
        f.0.join("sys/devices/0000:01:00.0/driver"),
        f.0.join("sys/devices/0000:01:00.0/driver-old"),
    )
    .unwrap();
    f.link(
        f.0.join("sys/drivers/amdxdna"),
        "sys/devices/0000:01:00.0/driver",
    );
    let rebound = f.one(&mut c, 5.).client_activity.unwrap();
    assert_ne!(left.scope, rebound.scope);
    assert_eq!(rebound.percent, None);
}
#[test]
fn suspension_missing_records_and_unsupported_aie4_do_not_fabricate_idle() {
    let f = Fixture::new();
    f.busy(10, 3, 1, 0);
    let mut c = f.collector();
    f.one(&mut c, 1.);
    f.put("sys/devices/0000:01:00.0/power/runtime_status", "suspended");
    assert!(f.one(&mut c, 2.).client_activity.is_none());
    f.put("sys/devices/0000:01:00.0/power/runtime_status", "active");
    assert!(f.one(&mut c, 3.).activity_percent().is_none());
    assert_eq!(f.one(&mut c, 4.).activity_percent(), Some(0.));
    fs::remove_file(f.0.join("proc/10/fdinfo/3")).unwrap();
    assert!(f.one(&mut c, 5.).client_activity.is_none());
    f.busy(10, 3, 1, 0);
    assert!(f.one(&mut c, 6.).activity_percent().is_none());
    f.put("sys/devices/0000:01:00.0/device", "0x17f2");
    assert!(f.one(&mut c, 7.).client_activity.is_none());
}
#[test]
fn impossible_deltas_and_oversized_or_symlinked_records_are_unavailable() {
    let f = Fixture::new();
    f.busy(10, 3, 1, 0);
    let mut c = f.collector();
    f.one(&mut c, 1.);
    f.busy(10, 3, 1, 1_500_000_000);
    assert!(f.one(&mut c, 2.).activity_percent().is_none());
    f.busy(10, 3, 1, 2_510_000_000);
    assert_eq!(f.one(&mut c, 3.).activity_percent(), Some(100.));
    f.put("proc/10/fdinfo/3", vec![b'0'; 65537]);
    assert!(f.one(&mut c, 4.).client_activity.is_none());
    fs::remove_file(f.0.join("proc/10/fdinfo/3")).unwrap();
    f.put("outside", "drm-engine-npu: 0 ns");
    f.link(f.0.join("outside"), "proc/10/fdinfo/3");
    assert!(f.one(&mut c, 5.).client_activity.is_none());
}
