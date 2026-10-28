// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#![cfg(unix)]
use std::{
    fs,
    os::unix::fs::symlink,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};
use xrg_ng_linux::gpu::{ActivitySource, Gpu, GpuCollector};
static NEXT: AtomicU64 = AtomicU64::new(0);
const ID: &str = "0000:03:00.0";
struct Fixture(PathBuf);
impl Fixture {
    fn new(driver: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-intel-clients-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        let f = Self(path);
        fs::create_dir(f.0.join("proc")).unwrap();
        f.gpu(ID, "renderD128", driver);
        f
    }
    fn put(&self, path: &str, value: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, value).unwrap();
    }
    fn gpu(&self, id: &str, node: &str, driver: &str) {
        self.put(&format!("devices/{id}/vendor"), "0x8086");
        let binding = self.0.join(format!("drivers/{driver}"));
        fs::create_dir_all(&binding).unwrap();
        symlink(binding, self.0.join(format!("devices/{id}/driver"))).unwrap();
        let class = self.0.join(format!("class/drm/{node}"));
        fs::create_dir_all(&class).unwrap();
        symlink(self.0.join(format!("devices/{id}")), class.join("device")).unwrap();
    }
    fn client(&self, fd: u32, node: &str, driver: &str, id: &str, counter: &str) {
        self.put(
            &format!("proc/100/fdinfo/{fd}"),
            &format!("drm-driver: {driver}\ndrm-client-id: 7\ndrm-pdev: {id}\n{counter}"),
        );
        let path = self.0.join(format!("proc/100/fd/{fd}"));
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        if path.symlink_metadata().is_ok() {
            fs::remove_file(&path).unwrap();
        }
        symlink(format!("/dev/dri/{node}"), path).unwrap();
    }
    fn xe(&self, busy: u64, total: u64, capacity: u64) {
        self.client(3, "renderD128", "xe", ID, &format!("drm-cycles-ccs: {busy}\ndrm-total-cycles-ccs: {total}\ndrm-engine-capacity-ccs: {capacity}\n"));
    }
    fn collector(&self) -> GpuCollector {
        GpuCollector::new(&self.0, None).with_proc_root(self.0.join("proc"))
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn sample(c: &mut GpuCollector, time: Instant) -> Gpu {
    c.sample_at(time).unwrap().values.remove(0)
}
#[test]
fn xe_cycles_use_the_gpu_denominator_and_engine_capacity() {
    let f = Fixture::new("xe");
    let mut c = f.collector();
    let now = Instant::now();
    f.xe(100, 1000, 2);
    assert!(sample(&mut c, now).activity().is_none());
    f.xe(700, 2000, 2);
    // 600 / 1000 / 2 = 30%, regardless of the seven-second CPU interval.
    let gpu = sample(&mut c, now + Duration::from_secs(7));
    assert_eq!(gpu.activity(), Some((ActivitySource::Clients, 30.)));
    assert!(gpu.utilization.is_none() && gpu.engine_activity.is_none());
    assert_eq!(gpu.visible_clients, Some(1));
    f.xe(700, 3000, 2);
    assert_eq!(
        sample(&mut c, now + Duration::from_secs(8)).client_activity,
        Some(0.)
    );
}
#[test]
fn i915_nanoseconds_work_without_a_host_pmu() {
    let f = Fixture::new("i915");
    let mut c = f.collector();
    let now = Instant::now();
    f.client(
        3,
        "renderD128",
        "i915",
        ID,
        "drm-engine-render: 0 ns\ndrm-engine-video: 0 ns\n",
    );
    sample(&mut c, now);
    f.client(
        3,
        "renderD128",
        "i915",
        ID,
        "drm-engine-render: 250000000 ns\ndrm-engine-video: 750000000 ns\n",
    );
    let gpu = sample(&mut c, now + Duration::from_secs(1));
    assert_eq!(gpu.client_activity, Some(75.));
    assert_eq!(gpu.activity().unwrap().0.suffix(), " clients");
    assert!(gpu.engine_activity.is_none());
}
#[test]
fn inherited_fds_deduplicate_but_equal_client_ids_on_other_gpus_do_not() {
    let f = Fixture::new("xe");
    let second = "0000:04:00.0";
    f.gpu(second, "renderD129", "xe");
    let mut c = f.collector();
    let now = Instant::now();
    for (fd, node, id) in [
        (3, "renderD128", ID),
        (4, "renderD128", ID),
        (5, "renderD129", second),
    ] {
        f.client(
            fd,
            node,
            "xe",
            id,
            "drm-cycles-rcs: 0\ndrm-total-cycles-rcs: 100\n",
        );
    }
    c.sample_at(now).unwrap();
    for (fd, node, id, busy) in [
        (3, "renderD128", ID, 50),
        (4, "renderD128", ID, 50),
        (5, "renderD129", second, 80),
    ] {
        f.client(
            fd,
            node,
            "xe",
            id,
            &format!("drm-cycles-rcs: {busy}\ndrm-total-cycles-rcs: 200\n"),
        );
    }
    let report = c.sample_at(now + Duration::from_secs(1)).unwrap();
    assert_eq!(
        report
            .values
            .iter()
            .map(|g| g.client_activity.unwrap())
            .collect::<Vec<_>>(),
        vec![50., 80.]
    );
    assert!(report.values.iter().all(|g| g.visible_clients == Some(1)));
}
#[test]
fn malformed_or_incomplete_xe_counters_never_become_zero_load() {
    for counters in [
        "drm-cycles-rcs: 0\n",
        "drm-cycles-rcs: 0 ns\ndrm-total-cycles-rcs: 100\n",
        "drm-cycles-rcs: 0\ndrm-total-cycles-rcs: -1\n",
        "drm-cycles-rcs: 0\ndrm-total-cycles-rcs: 100\ndrm-maxfreq-rcs: 100 MHz\n",
        "drm-cycles-rcs: 0\ndrm-total-cycles-rcs: 100\ndrm-engine-capacity-rcs: 0\n",
        "drm-cycles-rcs: 0\ndrm-cycles-rcs: 1\ndrm-total-cycles-rcs: 100\n",
        "drm-engine-rcs: 0 ns\ndrm-curfreq-rcs: 100 MHz\n",
    ] {
        let f = Fixture::new("xe");
        f.client(3, "renderD128", "xe", ID, counters);
        let mut c = f.collector();
        let now = Instant::now();
        sample(&mut c, now);
        assert!(
            sample(&mut c, now + Duration::from_secs(1))
                .activity()
                .is_none(),
            "{counters}"
        );
    }
}
#[test]
fn descriptor_pci_and_driver_must_match_the_discovered_adapter() {
    for (driver, id) in [("xe", "0000:04:00.0"), ("i915", ID), ("xe", "bad")] {
        let f = Fixture::new("xe");
        f.client(
            3,
            "renderD128",
            driver,
            id,
            "drm-cycles-rcs: 0\ndrm-total-cycles-rcs: 100\n",
        );
        let gpu = sample(&mut f.collector(), Instant::now());
        assert!(gpu.visible_clients.is_none());
        assert!(gpu.notes.iter().any(|s| s.contains("No readable")));
    }
}
#[test]
fn counter_regressions_zero_total_and_excess_busy_are_unavailable() {
    let f = Fixture::new("xe");
    let mut c = f.collector();
    let now = Instant::now();
    f.xe(100, 1000, 1);
    sample(&mut c, now);
    for (second, busy, total) in [(1, 90, 1100), (2, 200, 1000), (3, 500, 900), (4, 900, 1000)] {
        f.xe(busy, total, 1);
        assert!(
            sample(&mut c, now + Duration::from_secs(second))
                .client_activity
                .is_none()
        );
    }
    f.xe(950, 1100, 1);
    assert_eq!(
        sample(&mut c, now + Duration::from_secs(5)).client_activity,
        Some(50.)
    );
}
#[test]
fn busy_regression_holds_the_larger_baseline_until_catchup() {
    let f = Fixture::new("xe");
    let mut c = f.collector();
    let now = Instant::now();
    f.xe(100, 1000, 1);
    sample(&mut c, now);
    f.xe(90, 1100, 1);
    assert!(
        sample(&mut c, now + Duration::from_secs(1))
            .client_activity
            .is_none()
    );
    f.xe(150, 1500, 1);
    assert_eq!(
        sample(&mut c, now + Duration::from_secs(2)).client_activity,
        Some(10.)
    );
}
#[test]
fn capacity_changes_long_gaps_and_backward_clocks_restart_the_interval() {
    let f = Fixture::new("xe");
    let mut c = f.collector();
    let now = Instant::now();
    f.xe(0, 0, 1);
    sample(&mut c, now);
    f.xe(100, 100, 2);
    assert!(
        sample(&mut c, now + Duration::from_secs(1))
            .client_activity
            .is_none()
    );
    f.xe(150, 200, 2);
    assert_eq!(
        sample(&mut c, now + Duration::from_secs(2)).client_activity,
        Some(25.)
    );
    f.xe(200, 300, 2);
    assert!(
        sample(&mut c, now + Duration::from_secs(303))
            .client_activity
            .is_none()
    );
    assert!(
        sample(&mut c, now + Duration::from_secs(302))
            .client_activity
            .is_none()
    );
    f.xe(250, 400, 2);
    assert_eq!(
        sample(&mut c, now + Duration::from_secs(303)).client_activity,
        Some(25.)
    );
}
#[test]
fn suspend_removal_and_driver_changes_do_not_reuse_a_client_interval() {
    let f = Fixture::new("xe");
    let mut c = f.collector();
    let now = Instant::now();
    f.xe(0, 0, 1);
    sample(&mut c, now);
    f.put(&format!("devices/{ID}/power/runtime_status"), "suspended");
    assert!(
        sample(&mut c, now + Duration::from_secs(1))
            .visible_clients
            .is_none()
    );
    f.put(&format!("devices/{ID}/power/runtime_status"), "active");
    f.xe(500, 1000, 1);
    assert!(
        sample(&mut c, now + Duration::from_secs(2))
            .client_activity
            .is_none()
    );
    fs::remove_dir_all(f.0.join("proc/100")).unwrap();
    sample(&mut c, now + Duration::from_secs(3));
    f.xe(900, 2000, 1);
    assert!(
        sample(&mut c, now + Duration::from_secs(4))
            .client_activity
            .is_none()
    );
    fs::remove_file(f.0.join(format!("devices/{ID}/driver"))).unwrap();
    fs::create_dir(f.0.join("drivers/i915")).unwrap();
    symlink(
        f.0.join("drivers/i915"),
        f.0.join(format!("devices/{ID}/driver")),
    )
    .unwrap();
    f.client(
        3,
        "renderD128",
        "i915",
        ID,
        "drm-engine-rcs: 1000000000 ns\n",
    );
    assert!(
        sample(&mut c, now + Duration::from_secs(5))
            .client_activity
            .is_none()
    );
}
#[test]
fn resident_regions_are_readable_client_allocations_and_not_dedicated_vram() {
    let f = Fixture::new("xe");
    f.client(
        3,
        "renderD128",
        "xe",
        ID,
        "drm-resident-system: 1 MiB\ndrm-resident-gtt: 2 KiB\ndrm-resident-vram0: 3 MiB\n",
    );
    let gpu = sample(&mut f.collector(), Instant::now());
    assert_eq!(gpu.client_resident_bytes, Some(4 * 1048576 + 2048));
    assert!(gpu.memory_used.is_none() && gpu.memory_total.is_none());
    assert!(gpu.client_activity.is_none());
}
#[test]
fn fdinfo_symlinks_and_fifos_are_rejected_without_blocking() {
    for fifo in [false, true] {
        let f = Fixture::new("xe");
        f.xe(0, 0, 1);
        let path = f.0.join("proc/100/fdinfo/3");
        fs::rename(&path, f.0.join("record")).unwrap();
        if fifo {
            let path = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
            assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
        } else {
            symlink(f.0.join("record"), path).unwrap();
        }
        let gpu = sample(&mut f.collector(), Instant::now());
        assert!(gpu.visible_clients.is_none());
    }
}
