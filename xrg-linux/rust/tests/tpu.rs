// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use xrg_ng_linux::tpu::{self, Collector, Stats};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-tpu-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn put(&self, name: &str, data: impl AsRef<[u8]>) {
        let path = self.0.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, data).unwrap();
    }
    fn usb(&self, name: &str, vendor: &str, product: &str) {
        self.put(&format!("bus/usb/devices/{name}/idVendor"), vendor);
        self.put(&format!("bus/usb/devices/{name}/idProduct"), product);
    }
    fn pci(&self, name: &str, driver: bool) {
        self.put(&format!("devices/{name}/vendor"), "0x1ac1");
        self.put(&format!("devices/{name}/device"), "0x089a");
        fs::create_dir_all(self.0.join("bus/pci/devices")).unwrap();
        std::os::unix::fs::symlink(
            self.0.join(format!("devices/{name}")),
            self.0.join(format!("bus/pci/devices/{name}")),
        )
        .unwrap();
        if driver {
            fs::create_dir_all(self.0.join("bus/pci/drivers/apex")).unwrap();
            std::os::unix::fs::symlink(
                self.0.join("bus/pci/drivers/apex"),
                self.0.join(format!("devices/{name}/driver")),
            )
            .unwrap();
        }
    }
    fn apex(&self, name: &str, pci: &str, temp: &str) {
        self.put(&format!("class/apex/{name}/temp"), temp);
        std::os::unix::fs::symlink(
            self.0.join(format!("devices/{pci}")),
            self.0.join(format!("class/apex/{name}/device")),
        )
        .unwrap();
    }
    fn collector(&self) -> Collector {
        Collector::new(self.0.clone(), Some(self.0.join("stats.json")))
    }
    fn stats(&self, total: u64, extra: &str) {
        self.put(
            "stats.json",
            format!("{{\"total_inferences\":{total}{extra}}}"),
        );
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn usb_detects_both_ids_but_does_not_treat_bootloader_as_initialized() {
    let f = Fixture::new();
    f.usb("1-1", "1a6e", "089a");
    f.usb("1-2", "18D1", "9302");
    f.usb("1-3", "18d1", "ffff");
    let r = tpu::discover(&f.0).unwrap();
    assert!(r.errors.is_empty());
    assert_eq!(r.values.len(), 2);
    assert!(
        !r.values
            .iter()
            .find(|d| d.label.contains("1-1"))
            .unwrap()
            .initialized
    );
    assert!(
        r.values
            .iter()
            .find(|d| d.label.contains("1-2"))
            .unwrap()
            .initialized
    );
}
#[test]
fn pcie_apex_aliases_deduplicate_and_read_millicelsius() {
    let f = Fixture::new();
    f.pci("0000:01:00.0", true);
    f.apex("apex_0", "0000:01:00.0", "42500");
    let r = tpu::discover(&f.0).unwrap();
    assert!(r.errors.is_empty());
    assert_eq!(r.values.len(), 1);
    assert_eq!(r.values[0].temperature_c, Some(42.5));
    assert!(r.values[0].initialized);
    f.put("class/apex/apex_0/temp", "0");
    assert_eq!(
        tpu::discover(&f.0).unwrap().values[0].temperature_c,
        Some(0.)
    );
}
#[test]
fn unbound_and_suspended_pcie_skip_temperature_reads() {
    let f = Fixture::new();
    f.pci("0000:01:00.0", false);
    f.apex("apex_0", "0000:01:00.0", "broken");
    let r = tpu::discover(&f.0).unwrap();
    assert!(r.errors.is_empty());
    assert_eq!(r.values[0].temperature_c, None);
    assert!(!r.values[0].initialized);
    let g = Fixture::new();
    g.pci("0000:02:00.0", true);
    g.apex("apex_1", "0000:02:00.0", "broken");
    g.put("devices/0000:02:00.0/power/runtime_status", "suspended");
    let r = tpu::discover(&g.0).unwrap();
    assert!(r.errors.is_empty());
    assert!(r.values[0].suspended);
    assert_eq!(r.values[0].temperature_c, None);
}
#[test]
fn unrelated_pci_and_invalid_temperature_do_not_invent_telemetry() {
    let f = Fixture::new();
    f.pci("0000:01:00.0", true);
    f.apex("apex_0", "0000:01:00.0", "999999");
    let r = tpu::discover(&f.0).unwrap();
    assert_eq!(r.values.len(), 1);
    assert!(r.values[0].temperature_c.is_none());
    assert!(!r.errors.is_empty());
    f.put("devices/0000:01:00.0/vendor", "0x10de");
    assert!(tpu::discover(&f.0).unwrap().values.is_empty());
}
#[test]
fn usb_hotplug_and_reenumeration_keep_physical_identity() {
    let f = Fixture::new();
    f.usb("1-1", "1a6e", "089a");
    let before = tpu::discover(&f.0).unwrap().values.remove(0);
    f.usb("1-1", "18d1", "9302");
    let after = tpu::discover(&f.0).unwrap().values.remove(0);
    assert_eq!(before.id, after.id);
    assert!(after.initialized);
    fs::remove_dir_all(f.0.join("bus/usb/devices/1-1")).unwrap();
    assert!(tpu::discover(&f.0).unwrap().values.is_empty());
}
#[test]
fn producer_schema_keeps_optional_fields_and_large_integer_exactness() {
    let value=Stats::parse(br#"{"total_inferences":18446744073709551615,"last_latency_ms":0,"avg_latency_ms":1.25,"temperature":-10,"model_name":"test\nname","by_category":{"direct":9,"warming":2},"future_field":true}"#).unwrap();
    assert_eq!(value.total_inferences, u64::MAX);
    assert_eq!(value.model_name.as_deref(), Some("testname"));
    assert_eq!(value.by_category.unwrap().hooked, None);
    assert_eq!(value.last_latency_ms, Some(0.));
    let minimal = Stats::parse(br#"{"total_inferences":0}"#).unwrap();
    assert!(minimal.by_category.is_none());
    assert!(minimal.temperature.is_none());
}
#[test]
fn invalid_types_numbers_duplicates_and_oversized_reports_are_rejected() {
    for bytes in [
        br#"{}"#.as_slice(),
        br#"{"total_inferences":-1}"#,
        br#"{"total_inferences":1.5}"#,
        br#"{"total_inferences":"5"}"#,
        br#"{"total_inferences":1,"last_latency_ms":-1}"#,
        br#"{"total_inferences":1,"temperature":500}"#,
        br#"{"total_inferences":1,"timestamp":-1}"#,
        br#"{"total_inferences":1,"total_inferences":2}"#,
        br#"{"total_inferences":1,"by_category":{"direct":-1}}"#,
    ] {
        assert!(Stats::parse(bytes).is_err(), "accepted {bytes:?}");
    }
    assert!(Stats::parse(&vec![b' '; 65537]).is_err());
}
#[test]
fn initial_elapsed_fractional_rates_counter_resets_and_session_changes() {
    let f = Fixture::new();
    let mut c = f.collector();
    f.stats(100, "");
    assert!(
        c.sample_at(1., SystemTime::now())
            .inference
            .unwrap()
            .rate
            .is_none()
    );
    f.stats(101, "");
    assert_eq!(
        c.sample_at(3., SystemTime::now()).inference.unwrap().rate,
        Some(0.5)
    );
    f.stats(1, "");
    assert!(
        c.sample_at(4., SystemTime::now())
            .inference
            .unwrap()
            .rate
            .is_none()
    );
    f.stats(11, "");
    assert_eq!(
        c.sample_at(6., SystemTime::now()).inference.unwrap().rate,
        Some(5.)
    );
    f.stats(1000, ",\"session_id\":\"new\"");
    assert!(
        c.sample_at(7., SystemTime::now())
            .inference
            .unwrap()
            .rate
            .is_none()
    );
    f.stats(1010, ",\"session_id\":\"new\"");
    assert_eq!(
        c.sample_at(8., SystemTime::now()).inference.unwrap().rate,
        Some(10.)
    );
}
#[test]
fn stale_mtime_and_producer_timestamp_are_unavailable_and_recovery_warms_up() {
    let f = Fixture::new();
    let mut c = f.collector();
    f.stats(10, "");
    let now = SystemTime::now();
    c.sample_at(1., now).inference.unwrap();
    assert!(
        c.sample_at(2., now + Duration::from_secs(31))
            .inference
            .unwrap_err()
            .contains("stale")
    );
    f.stats(100, "");
    assert!(
        c.sample_at(3., SystemTime::now())
            .inference
            .unwrap()
            .rate
            .is_none()
    );
    let stale = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
        - 60.;
    f.stats(101, &format!(",\"timestamp\":{stale}"));
    assert!(c.sample_at(4., SystemTime::now()).inference.is_err());
}
#[test]
fn future_timestamp_invalid_wall_time_and_stale_monotonic_time_are_handled() {
    let f = Fixture::new();
    let mut c = f.collector();
    f.stats(0, "");
    c.sample_at(1., SystemTime::now()).inference.unwrap();
    f.stats(10, "");
    assert!(
        c.sample_at(1., SystemTime::now())
            .inference
            .unwrap()
            .rate
            .is_none()
    );
    f.stats(20, "");
    assert_eq!(
        c.sample_at(2., SystemTime::now()).inference.unwrap().rate,
        Some(20.)
    );
    let future = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs_f64()
        + 60.;
    f.stats(21, &format!(",\"timestamp\":{future}"));
    assert!(
        c.sample_at(3., SystemTime::now())
            .inference
            .unwrap_err()
            .contains("future")
    );
    assert!(c.sample_at(f64::NAN, SystemTime::now()).inference.is_err());
}
#[test]
fn atomic_replacement_preserves_rate_while_missing_and_bad_reports_reset_it() {
    let f = Fixture::new();
    let mut c = f.collector();
    f.stats(10, "");
    c.sample_at(1., SystemTime::now()).inference.unwrap();
    f.put("next", br#"{"total_inferences":20}"#);
    fs::rename(f.0.join("next"), f.0.join("stats.json")).unwrap();
    assert_eq!(
        c.sample_at(2., SystemTime::now()).inference.unwrap().rate,
        Some(10.)
    );
    f.put("stats.json", "{broken");
    assert!(c.sample_at(3., SystemTime::now()).inference.is_err());
    f.stats(100, "");
    assert!(
        c.sample_at(4., SystemTime::now())
            .inference
            .unwrap()
            .rate
            .is_none()
    );
    fs::remove_file(f.0.join("stats.json")).unwrap();
    assert!(c.sample_at(5., SystemTime::now()).inference.is_err());
}
#[test]
fn stats_symlinks_fifo_and_unconfigured_sources_are_not_opened_as_reports() {
    let f = Fixture::new();
    f.put("target", br#"{"total_inferences":1}"#);
    std::os::unix::fs::symlink(f.0.join("target"), f.0.join("stats.json")).unwrap();
    assert!(f.collector().sample().inference.is_err());
    fs::remove_file(f.0.join("stats.json")).unwrap();
    let path =
        std::ffi::CString::new(f.0.join("stats.json").as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    assert!(f.collector().sample().inference.is_err());
    assert!(
        Collector::new(f.0.clone(), None)
            .sample()
            .inference
            .is_err()
    );
}
#[test]
fn producer_data_does_not_require_or_prove_detected_hardware() {
    let f = Fixture::new();
    f.stats(5, "");
    let report = f.collector().sample();
    assert!(report.devices.unwrap().values.is_empty());
    assert_eq!(report.inference.unwrap().stats.total_inferences, 5);
    assert!(tpu::discover(&f.0.join("missing")).is_err());
}
