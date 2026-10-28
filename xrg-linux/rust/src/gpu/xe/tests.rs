// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
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
        let p = std::env::temp_dir().join(format!(
            "xrg-xe-pmu-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Self(p)
    }
    fn put(&self, p: &str, s: &str) {
        let p = self.0.join(p);
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, s).unwrap();
    }
    fn setup(&self) -> Device {
        use std::os::unix::fs::symlink;
        self.put("bus/pci/devices/0000:00:02.0/vendor", "0x8086");
        fs::create_dir_all(self.0.join("drivers/xe")).unwrap();
        let pci = self.0.join("bus/pci/devices/0000:00:02.0");
        symlink(self.0.join("drivers/xe"), pci.join("driver")).unwrap();
        self.put("class/drm/renderD128/dev", "226:128");
        symlink(pci.clone(), self.0.join("class/drm/renderD128/device")).unwrap();
        self.put("devices/system/cpu/online", "0-3");
        self.put("bus/event_source/devices/xe_0000_00_02.0/type", "25");
        for (k, v) in [
            ("event", "config:0-11"),
            ("gt", "config:60-63"),
            ("engine_class", "config:20-27"),
            ("engine_instance", "config:12-19"),
            ("function", "config:44-59"),
        ] {
            self.pmu(&format!("format/{k}"), v);
        }
        self.pmu("events/engine-active-ticks", "event=0x02");
        self.pmu("events/engine-total-ticks", "event=0x03");
        crate::gpu::device(pci, Some(self.0.join("class/drm/renderD128")), "0x8086").unwrap()
    }
    fn pmu(&self, p: &str, s: &str) {
        self.put(&format!("bus/event_source/devices/xe_0000_00_02.0/{p}"), s);
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn r(active: u64, total: u64, time: u64) -> Reading {
    Reading {
        active,
        total,
        enabled: time,
        running: time,
    }
}
#[test]
fn engine_queries_validate_identity_layout_and_build_exact_event_configs() {
    let mut bytes = vec![0u8; 72];
    bytes[..4].copy_from_slice(&2u32.to_ne_bytes());
    bytes[8..10].copy_from_slice(&4u16.to_ne_bytes());
    bytes[10..12].copy_from_slice(&3u16.to_ne_bytes());
    bytes[12..14].copy_from_slice(&1u16.to_ne_bytes());
    let list = native::engines(&bytes).unwrap();
    assert_eq!(list.len(), 2);
    assert_eq!(list[1].name(), "gt1 compute3");
    assert_eq!(list[1].config(2), 0x1000000000403002);
    for pos in [4, 14, 16] {
        let mut bad = bytes.clone();
        bad[pos] = 1;
        assert!(native::engines(&bad).is_err());
    }
    let mut duplicate = bytes.clone();
    duplicate[8..40].fill(0);
    assert!(native::engines(&duplicate).is_err());
    for (offset, value) in [(8, 5u16), (10, 256), (12, 16)] {
        let mut bad = bytes.clone();
        bad[offset..offset + 2].copy_from_slice(&value.to_ne_bytes());
        assert!(native::engines(&bad).is_err());
    }
    assert!(native::engines(&bytes[..71]).is_err());
    assert!(native::engines(&[0; 8]).is_err());
}
#[test]
fn perf_group_ids_handle_reordered_values_and_reject_malformed_records() {
    let encode = |v: [u64; 7]| v.into_iter().flat_map(u64::to_ne_bytes).collect::<Vec<_>>();
    let bytes = encode([2, 100, 100, 900, 8, 450, 7]);
    let reading = native::decode(&bytes, 7, 8).unwrap();
    assert_eq!((reading.active, reading.total), (450, 900));
    for v in [
        [1, 100, 100, 900, 8, 450, 7],
        [2, 100, 100, 900, 8, 450, 8],
        [2, 100, 100, 900, 8, 450, 99],
    ] {
        assert!(native::decode(&encode(v), 7, 8).is_err());
    }
    assert!(native::decode(&bytes[..55], 7, 8).is_err());
    assert!(native::decode(&bytes, 7, 7).is_err());
}
#[test]
fn active_total_tick_math_preserves_zero_precision_and_rejects_bad_intervals() {
    let base = 1u64 << 60;
    assert_eq!(
        percent(r(base, base, 1), r(base + 80, base + 100, 101)).unwrap(),
        80.
    );
    assert_eq!(percent(r(0, 0, 1), r(0, 100, 101)).unwrap(), 0.);
    assert_eq!(percent(r(0, 0, 1), r(105, 100, 101)).unwrap(), 100.);
    for (old, next) in [
        (r(0, 0, 1), r(106, 100, 101)),
        (r(20, 50, 1), r(10, 100, 101)),
        (r(0, 100, 1), r(0, 100, 101)),
        (r(0, 100, 1), r(0, 90, 101)),
        (r(0, 0, 10), r(1, 2, 9)),
    ] {
        assert!(percent(old, next).is_err());
    }
    let mut multiplexed = r(50, 100, 101);
    multiplexed.running = 100;
    assert!(percent(r(0, 0, 1), multiplexed).is_err());
}
#[test]
fn discovery_checks_formats_mapping_power_and_sriov_before_opening() {
    let f = Fixture::new();
    let d = f.setup();
    let spec = discovery::describe(&f.0, &d).unwrap();
    assert_eq!(spec.dev, (226, 128));
    assert_eq!(spec.cpu, 0);
    assert_eq!(spec.node, PathBuf::from("/dev/dri/renderD128"));
    f.pmu("cpumask", "2");
    assert_eq!(discovery::describe(&f.0, &d).unwrap().cpu, 2);
    f.pmu("format/gt", "config:56-59");
    assert!(discovery::describe(&f.0, &d).is_err());
    f.pmu("format/gt", "config:60-63");
    f.pmu("events/engine-active-ticks", "event=0x03");
    assert!(discovery::describe(&f.0, &d).is_err());
    f.pmu("events/engine-active-ticks", "event=0x02");
    f.put("bus/pci/devices/0000:00:02.0/sriov_numvfs", "1");
    assert!(spec.verify().is_err());
    f.put("bus/pci/devices/0000:00:02.0/sriov_numvfs", "0");
    f.put(
        "bus/pci/devices/0000:00:02.0/power/runtime_status",
        "suspended",
    );
    assert!(spec.verify().is_err());
    f.put(
        "bus/pci/devices/0000:00:02.0/power/runtime_status",
        "active",
    );
    spec.verify().unwrap();
    f.put("class/drm/renderD128/dev", "226:129");
    assert!(spec.verify().is_err());
}
#[test]
fn custom_roots_and_default_policy_never_enable_native_acquisition() {
    let f = Fixture::new();
    let d = f.setup();
    let mut collector = Collector::new(&f.0);
    assert!(!collector.enabled && !collector.allowed);
    collector.set_enabled(true);
    collector.collect(&f.0, &mut [d], Instant::now());
    assert!(collector.backend.states.is_empty());
    collector.set_enabled(false);
    assert!(!collector.enabled);
}
type Queue = Arc<Mutex<VecDeque<Result<Reading, String>>>>;
struct FakeCounter {
    queue: Queue,
    drops: Arc<AtomicUsize>,
}
impl Counter for FakeCounter {
    fn read(&mut self) -> Result<Reading, String> {
        self.queue
            .lock()
            .unwrap()
            .pop_front()
            .expect("Unexpected counter read")
    }
}
impl Drop for FakeCounter {
    fn drop(&mut self) {
        self.drops.fetch_add(1, Ordering::Relaxed);
    }
}
struct FakeOpen {
    queues: Vec<Queue>,
    opens: Arc<AtomicUsize>,
    drops: Arc<AtomicUsize>,
    fail: bool,
}
impl Open for FakeOpen {
    fn open(&mut self, _: &discovery::Spec) -> Result<Counters, String> {
        self.opens.fetch_add(1, Ordering::Relaxed);
        if self.fail {
            return Err("Fixture permission denied".into());
        }
        Ok(self
            .queues
            .iter()
            .enumerate()
            .map(|(i, q)| {
                (
                    format!("engine{i}"),
                    Box::new(FakeCounter {
                        queue: q.clone(),
                        drops: self.drops.clone(),
                    }) as Box<dyn Counter>,
                )
            })
            .collect())
    }
}
fn fake(readings: Vec<Vec<Reading>>) -> Backend<FakeOpen> {
    Backend {
        states: BTreeMap::new(),
        open: FakeOpen {
            queues: readings
                .into_iter()
                .map(|v| Arc::new(Mutex::new(v.into_iter().map(Ok).collect())))
                .collect(),
            opens: Arc::new(AtomicUsize::new(0)),
            drops: Arc::new(AtomicUsize::new(0)),
            fail: false,
        },
    }
}
#[test]
fn sessions_warm_up_plot_the_maximum_and_release_all_handles_on_removal() {
    let f = Fixture::new();
    let mut devices = vec![f.setup()];
    let time = Instant::now();
    let mut b = fake(vec![
        vec![r(0, 0, 0), r(40, 100, 100)],
        vec![r(0, 0, 0), r(70, 100, 100)],
    ]);
    b.collect(&f.0, &mut devices, time);
    assert!(devices[0].gpu.engine_activity.is_none());
    b.collect(&f.0, &mut devices, time); // Same timestamp must not read the counters.
    b.collect(&f.0, &mut devices, time + Duration::from_secs(1));
    assert_eq!(
        devices[0].gpu.engine_activity.as_ref().unwrap().percent,
        70.
    );
    b.collect(&f.0, &mut [], time + Duration::from_secs(2));
    assert_eq!(b.open.drops.load(Ordering::Relaxed), 2);
}
#[test]
fn permission_errors_back_off_and_changed_bindings_release_open_sessions() {
    let f = Fixture::new();
    let mut devices = vec![f.setup()];
    let time = Instant::now();
    let mut b = fake(vec![vec![r(0, 0, 0)]]);
    b.open.fail = true;
    b.collect(&f.0, &mut devices, time);
    b.collect(&f.0, &mut devices, time + Duration::from_secs(1));
    assert_eq!(b.open.opens.load(Ordering::Relaxed), 1);
    b.open.fail = false;
    b.collect(&f.0, &mut devices, time + Duration::from_secs(31));
    assert_eq!(b.open.opens.load(Ordering::Relaxed), 2);
    f.put("bus/event_source/devices/xe_0000_00_02.0/type", "invalid");
    b.collect(&f.0, &mut devices, time + Duration::from_secs(32));
    assert_eq!(b.open.drops.load(Ordering::Relaxed), 1);
    assert!(b.states.is_empty());
}
#[test]
fn backwards_clocks_and_long_gaps_rebase_and_suspended_devices_close() {
    let f = Fixture::new();
    let mut devices = vec![f.setup()];
    let time = Instant::now();
    let mut b = fake(vec![vec![r(0, 0, 0), r(1, 10, 10), r(2, 20, 20)]]);
    b.collect(&f.0, &mut devices, time + Duration::from_secs(1));
    b.collect(&f.0, &mut devices, time);
    assert!(devices[0].gpu.engine_activity.is_none());
    b.collect(&f.0, &mut devices, time + Duration::from_secs(301));
    assert!(devices[0].gpu.engine_activity.is_none());
    devices[0].suspended = true;
    b.collect(&f.0, &mut devices, time + Duration::from_secs(302));
    assert!(b.states.is_empty());
    assert_eq!(b.open.drops.load(Ordering::Relaxed), 1);
}
#[test]
fn counter_failures_drop_the_whole_adapter_instead_of_publishing_partial_utilization() {
    let f = Fixture::new();
    let mut devices = vec![f.setup()];
    let time = Instant::now();
    let mut b = fake(vec![
        vec![r(0, 0, 0), r(0, 100, 100)],
        vec![r(0, 0, 0), r(200, 100, 100)],
    ]);
    b.collect(&f.0, &mut devices, time);
    b.collect(&f.0, &mut devices, time + Duration::from_secs(1));
    assert!(devices[0].gpu.engine_activity.is_none());
    assert_eq!(b.open.drops.load(Ordering::Relaxed), 2);
    assert!(b.states.values().all(|s| s.session.is_none()));
}

#[test]
fn stopping_a_backend_releases_sessions_before_a_future_sample() {
    let f = Fixture::new();
    let mut devices = vec![f.setup()];
    let mut b = fake(vec![vec![r(0, 0, 0)]]);
    b.collect(&f.0, &mut devices, Instant::now());
    assert_eq!(b.open.drops.load(Ordering::Relaxed), 0);
    b.stop();
    assert!(b.states.is_empty());
    assert_eq!(b.open.drops.load(Ordering::Relaxed), 1);
}

#[test]
fn an_unchanged_driver_name_with_a_new_binding_invalidates_the_old_session() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    let device = f.setup();
    let spec = discovery::describe(&f.0, &device).unwrap();
    let next = device.path.join("driver-next");
    symlink(f.0.join("drivers/xe"), &next).unwrap();
    fs::rename(next, device.path.join("driver")).unwrap();
    assert!(spec.verify().is_err());
    assert_ne!(discovery::describe(&f.0, &device).unwrap(), spec);
}
