// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::discovery::{Event, config, cpu};
use super::*;
use std::{
    collections::VecDeque,
    fs,
    path::PathBuf,
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-i915-pmu-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn put(&self, path: &str, value: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, value).unwrap();
    }
    fn gpu(&self, id: &str) -> Device {
        use std::os::unix::fs::symlink;
        self.put(&format!("bus/pci/devices/{id}/vendor"), "0x8086");
        let driver = self.0.join("drivers/i915");
        fs::create_dir_all(&driver).unwrap();
        let path = self.0.join(format!("bus/pci/devices/{id}"));
        symlink(driver, path.join("driver")).unwrap();
        super::super::device(path, None, "0x8086").unwrap()
    }
    fn pmu(&self, name: &str) {
        self.put(&format!("bus/event_source/devices/{name}/type"), "25");
        self.put("devices/system/cpu/online", "0-3");
        self.put(&format!("bus/event_source/devices/{name}/cpumask"), "0");
        for (engine, config) in [("rcs0", 0), ("vcs0", 0x2000)] {
            self.put(
                &format!("bus/event_source/devices/{name}/events/{engine}-busy"),
                &format!("config=0x{config:x}"),
            );
            self.put(
                &format!("bus/event_source/devices/{name}/events/{engine}-busy.unit"),
                "ns",
            );
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn reading(value: u64, time: u64) -> Reading {
    Reading {
        value,
        enabled: time,
        running: time,
    }
}
type Queue = Arc<Mutex<VecDeque<Result<Reading, String>>>>;
struct FakeCounter {
    readings: Queue,
    closed: Arc<AtomicUsize>,
}
impl Counter for FakeCounter {
    fn read(&mut self) -> Result<Reading, String> {
        self.readings
            .lock()
            .unwrap()
            .pop_front()
            .expect("Unexpected PMU read")
    }
}
impl Drop for FakeCounter {
    fn drop(&mut self) {
        self.closed.fetch_add(1, Ordering::SeqCst);
    }
}
struct FakeOpen {
    values: BTreeMap<String, Queue>,
    opened: Arc<AtomicUsize>,
    closed: Arc<AtomicUsize>,
    fail_on: Option<usize>,
}
impl FakeOpen {
    fn new() -> Self {
        Self {
            values: BTreeMap::new(),
            opened: Arc::new(AtomicUsize::new(0)),
            closed: Arc::new(AtomicUsize::new(0)),
            fail_on: None,
        }
    }
    fn values(&mut self, name: &str, values: Vec<Result<Reading, String>>) {
        self.values
            .insert(name.into(), Arc::new(Mutex::new(values.into())));
    }
}
impl Open for FakeOpen {
    fn open(&mut self, _: &Spec, event: &Event) -> Result<Box<dyn Counter>, String> {
        let count = self.opened.fetch_add(1, Ordering::SeqCst) + 1;
        if self.fail_on == Some(count) {
            return Err("Fixture: PMU permission denied".into());
        }
        Ok(Box::new(FakeCounter {
            readings: self
                .values
                .get(&event.name)
                .cloned()
                .unwrap_or_else(|| Arc::new(Mutex::new(VecDeque::new()))),
            closed: self.closed.clone(),
        }))
    }
}
fn collect(backend: &mut Backend<FakeOpen>, f: &Fixture, devices: &mut [Device], time: Instant) {
    for d in devices.iter_mut() {
        d.gpu.engine_activity = None;
        d.gpu.notes.clear();
    }
    backend.collect(&f.0, devices, time);
}
#[test]
fn config_units_and_reader_cpu_are_validated_without_guessing() {
    assert_eq!(config("config=0x2000\n"), Ok(0x2000));
    assert_eq!(config("config=0"), Ok(0));
    for invalid in [
        "event=0",
        "config=0,config1=1",
        "config=-1",
        "config=0x100000",
        "config=0x2001",
        "config=0xzz",
    ] {
        assert!(config(invalid).is_err(), "{invalid}");
    }
    assert_eq!(cpu(Some("2-4,8"), "0-3,7-9"), Ok(2));
    assert_eq!(cpu(None, "4-7"), Ok(4));
    for mask in ["", "8-2", "0,0", "1-1048576", "0-3,2", "bad"] {
        assert!(cpu(Some(mask), "0-7").is_err());
    }
    assert!(cpu(Some("8"), "0-7").is_err());
}
#[test]
fn global_pmu_only_binds_to_an_unambiguous_unmatched_pci_device() {
    let f = Fixture::new();
    let first = f.gpu("0000:00:02.0");
    f.pmu("i915");
    let owner = discovery::global_owner(&f.0).unwrap();
    assert_eq!(owner.as_deref(), Some("0000:00:02.0"));
    assert_eq!(
        discovery::describe(&f.0, &first, &Ok(owner))
            .unwrap()
            .events
            .len(),
        2
    );
    let second = f.gpu("0000:03:00.0");
    assert!(discovery::global_owner(&f.0).unwrap().is_none());
    assert!(discovery::describe(&f.0, &first, &Ok(None)).is_err());
    f.pmu("i915_0000_03_00.0");
    let owner = discovery::global_owner(&f.0).unwrap();
    assert_eq!(owner.as_deref(), Some(first.gpu.id.as_str()));
    let specific = discovery::describe(&f.0, &second, &Ok(owner)).unwrap();
    assert!(specific.path.ends_with("i915_0000_03_00.0"));
}
#[test]
fn bad_metadata_and_duplicate_events_never_open_perf() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let open = FakeOpen::new();
    let count = open.opened.clone();
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    f.put(
        "bus/event_source/devices/i915/events/rcs0-busy.unit",
        "cycles",
    );
    collect(&mut backend, &f, &mut devices, Instant::now());
    assert_eq!(count.load(Ordering::SeqCst), 0);
    assert!(devices[0].gpu.notes[0].contains("unit"));
    f.put("bus/event_source/devices/i915/events/rcs0-busy.unit", "ns");
    f.put("bus/event_source/devices/i915/events/vcs0-busy", "config=0");
    collect(&mut backend, &f, &mut devices, Instant::now());
    assert_eq!(count.load(Ordering::SeqCst), 0);
    assert!(devices[0].gpu.notes[0].contains("Duplicate"));
}
#[test]
fn busy_is_the_maximum_engine_and_zero_waiting_and_mux_stay_distinct() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let mut open = FakeOpen::new();
    open.values(
        "rcs0",
        vec![
            Ok(reading(0, 0)),
            Ok(reading(0, 1_000_000_000)),
            Ok(reading(250_000_000, 2_000_000_000)),
        ],
    );
    open.values(
        "vcs0",
        vec![
            Ok(reading(0, 0)),
            Ok(reading(0, 1_000_000_000)),
            Ok(reading(750_000_000, 2_000_000_000)),
        ],
    );
    let opened = open.opened.clone();
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    let time = Instant::now();
    collect(&mut backend, &f, &mut devices, time);
    assert!(devices[0].gpu.engine_activity.is_none());
    collect(&mut backend, &f, &mut devices, time);
    assert!(devices[0].gpu.engine_activity.is_none());
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(1),
    );
    assert_eq!(devices[0].gpu.engine_activity.as_ref().unwrap().percent, 0.);
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(2),
    );
    let activity = devices[0].gpu.engine_activity.as_ref().unwrap();
    assert_eq!(activity.percent, 75.);
    assert_eq!(
        activity.engines,
        vec![("rcs0".into(), 25.), ("vcs0".into(), 75.)]
    );
    assert!(devices[0].gpu.utilization.is_none());
    assert_eq!(opened.load(Ordering::SeqCst), 2);
}
#[test]
fn partial_open_permission_failure_closes_handles_and_backs_off() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let mut open = FakeOpen::new();
    open.fail_on = Some(2);
    let opened = open.opened.clone();
    let closed = open.closed.clone();
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    let time = Instant::now();
    collect(&mut backend, &f, &mut devices, time);
    assert_eq!(closed.load(Ordering::SeqCst), 1);
    assert!(devices[0].gpu.notes[0].contains("permission denied"));
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(1),
    );
    assert_eq!(opened.load(Ordering::SeqCst), 2);
    backend.open.fail_on = Some(3);
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(30),
    );
    assert_eq!(opened.load(Ordering::SeqCst), 3);
    assert!(devices[0].gpu.engine_activity.is_none());
}
#[test]
fn read_failure_suspension_and_removal_release_all_handles() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let mut open = FakeOpen::new();
    open.values(
        "rcs0",
        vec![
            Ok(reading(0, 0)),
            Err("Fixture: counter disappeared".into()),
        ],
    );
    open.values("vcs0", vec![Ok(reading(0, 0))]);
    let closed = open.closed.clone();
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    let time = Instant::now();
    collect(&mut backend, &f, &mut devices, time);
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(1),
    );
    assert_eq!(closed.load(Ordering::SeqCst), 2);
    assert!(devices[0].gpu.engine_activity.is_none());
    // A suspended device is excluded before metadata or counter reads.
    devices[0].suspended = true;
    fs::remove_dir_all(f.0.join("bus/event_source")).unwrap();
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(2),
    );
    assert!(backend.states.is_empty());
    collect(&mut backend, &f, &mut [], time + Duration::from_secs(3));
    assert!(backend.states.is_empty());
}
#[test]
fn topology_changes_restart_the_counter_interval() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let mut open = FakeOpen::new();
    for name in ["rcs0", "vcs0"] {
        open.values(
            name,
            vec![
                Ok(reading(0, 0)),
                Ok(reading(10, 100)),
                Ok(reading(20, 200)),
            ],
        );
    }
    let opened = open.opened.clone();
    let closed = open.closed.clone();
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    let time = Instant::now();
    collect(&mut backend, &f, &mut devices, time);
    f.put("bus/event_source/devices/i915/cpumask", "1");
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(1),
    );
    assert_eq!(opened.load(Ordering::SeqCst), 4);
    assert_eq!(closed.load(Ordering::SeqCst), 2);
    assert!(devices[0].gpu.engine_activity.is_none());
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(2),
    );
    assert_eq!(
        devices[0].gpu.engine_activity.as_ref().unwrap().percent,
        10.
    );
}
#[test]
fn fixture_roots_do_not_enable_native_perf() {
    let f = Fixture::new();
    assert!(!perf::available(&f.0));
    let mut collector = Collector::new(&f.0);
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    collector.collect(&f.0, &mut devices, Instant::now());
    assert!(devices[0].gpu.engine_activity.is_none());
    assert!(collector.backend.states.is_empty());
}

#[test]
fn stale_or_regressed_sample_times_restart_the_interval_without_fake_zeros() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let mut open = FakeOpen::new();
    for name in ["rcs0", "vcs0"] {
        open.values(
            name,
            vec![
                Ok(reading(0, 0)),
                Ok(reading(10, 100)),
                Ok(reading(20, 200)),
                Ok(reading(30, 300)),
                Ok(reading(40, 400)),
            ],
        );
    }
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    let time = Instant::now();
    collect(&mut backend, &f, &mut devices, time);
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(301),
    );
    assert!(devices[0].gpu.engine_activity.is_none());
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(302),
    );
    assert_eq!(
        devices[0].gpu.engine_activity.as_ref().unwrap().percent,
        10.
    );
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(300),
    );
    assert!(devices[0].gpu.engine_activity.is_none());
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(301),
    );
    assert_eq!(
        devices[0].gpu.engine_activity.as_ref().unwrap().percent,
        10.
    );
}
#[test]
fn pmu_type_changes_and_cpu_offline_do_not_reuse_an_old_session() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let mut open = FakeOpen::new();
    for name in ["rcs0", "vcs0"] {
        open.values(name, vec![Ok(reading(0, 0)), Ok(reading(10, 100))]);
    }
    let closed = open.closed.clone();
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    let time = Instant::now();
    collect(&mut backend, &f, &mut devices, time);
    f.put("bus/event_source/devices/i915/type", "26");
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(1),
    );
    assert_eq!(closed.load(Ordering::SeqCst), 2);
    assert!(devices[0].gpu.engine_activity.is_none());
    f.put("devices/system/cpu/online", "1-3");
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(2),
    );
    assert_eq!(closed.load(Ordering::SeqCst), 4);
    assert!(devices[0].gpu.notes[0].contains("online"));
}

#[test]
fn active_suspend_and_device_removal_close_counters_before_any_more_reads() {
    let f = Fixture::new();
    let mut devices = vec![f.gpu("0000:00:02.0")];
    f.pmu("i915");
    let mut open = FakeOpen::new();
    for name in ["rcs0", "vcs0"] {
        open.values(name, vec![Ok(reading(0, 0)), Ok(reading(10, 100))]);
    }
    let closed = open.closed.clone();
    let opened = open.opened.clone();
    let mut backend = Backend {
        open,
        states: BTreeMap::new(),
    };
    let time = Instant::now();
    collect(&mut backend, &f, &mut devices, time);
    assert_eq!(closed.load(Ordering::SeqCst), 0);
    devices[0].suspended = true;
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(1),
    );
    assert_eq!(closed.load(Ordering::SeqCst), 2);
    devices[0].suspended = false;
    collect(
        &mut backend,
        &f,
        &mut devices,
        time + Duration::from_secs(2),
    );
    assert_eq!(opened.load(Ordering::SeqCst), 4);
    assert!(devices[0].gpu.engine_activity.is_none());
    collect(&mut backend, &f, &mut [], time + Duration::from_secs(3));
    assert_eq!(closed.load(Ordering::SeqCst), 4);
}
#[test]
fn metadata_type_units_scale_and_symlink_failures_remain_unavailable() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    let device = f.gpu("0000:00:02.0");
    f.pmu("i915");
    let owner = Ok(Some(device.gpu.id.clone()));
    f.put("bus/event_source/devices/i915/type", "1");
    assert!(discovery::describe(&f.0, &device, &owner).is_err());
    f.put("bus/event_source/devices/i915/type", "25");
    f.put(
        "bus/event_source/devices/i915/events/rcs0-busy.scale",
        "1e-9",
    );
    assert!(discovery::describe(&f.0, &device, &owner).is_err());
    fs::remove_file(f.0.join("bus/event_source/devices/i915/events/rcs0-busy.scale")).unwrap();
    fs::remove_file(f.0.join("bus/event_source/devices/i915/events/rcs0-busy")).unwrap();
    symlink(
        f.0.join("bus/event_source/devices/i915/events/vcs0-busy"),
        f.0.join("bus/event_source/devices/i915/events/rcs0-busy"),
    )
    .unwrap();
    assert!(discovery::describe(&f.0, &device, &owner).is_err());
}
