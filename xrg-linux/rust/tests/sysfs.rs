// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    collectors::LinuxSources,
    engine::{Sampler, Scale},
    hardware,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-sysfs-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn put(&self, path: &str, contents: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }
    fn battery(&self, name: &str, fields: &[(&str, &str)]) {
        self.put(&format!("class/power_supply/{name}/type"), "Battery");
        for (key, value) in fields {
            self.put(&format!("class/power_supply/{name}/{key}"), value);
        }
    }
    fn sensor(&self, device: &str, channel: &str, value: &str) {
        self.put(&format!("class/hwmon/{device}/name"), "coretemp");
        self.put(&format!("class/hwmon/{device}/temp{channel}_input"), value);
    }
    fn sources(&self) -> LinuxSources {
        LinuxSources::with_roots(self.0.join("proc"), &self.0)
    }
    fn core(&self) {
        self.put("proc/stat", "cpu 100 0 50 800 50 0 0 0");
        self.put("proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 600 kB");
        self.put("proc/net/dev", "header\nheader\nlo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\neth0: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0");
        self.put("proc/diskstats", "8 0 sda 1 0 10 0 1 0 20 0 0 0 0");
        fs::create_dir_all(self.0.join("block/sda")).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn energy_percent_zero_and_signed_power() {
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("energy_now", "0"),
            ("energy_full", "50000000"),
            ("status", "Discharging"),
            ("current_now", "-2000000"),
            ("voltage_now", "12000000"),
        ],
    );
    let report = hardware::batteries(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(report.values[0].percent, 0.);
    assert_eq!(report.values[0].watts, Some(24.));
    assert_eq!(report.values[0].status, "Discharging");
}
#[test]
fn never_mix_energy_with_charge_counters() {
    let f = Fixture::new();
    // Incomplete energy pair must not be divided by charge_full.
    f.battery(
        "BAT0",
        &[
            ("energy_now", "50000000"),
            ("charge_now", "1500000"),
            ("charge_full", "3000000"),
        ],
    );
    let report = hardware::batteries(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(report.values[0].percent, 50.);
    assert_eq!(report.values[0].watts, None);
    assert_eq!(report.values[0].status, "Unknown");
}
#[test]
fn capacity_fallback_is_bounded_and_optional_power_is_not_zero() {
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("capacity", "73"),
            ("power_now", "-12000000"),
            ("status", "Charging"),
        ],
    );
    f.battery("BAT1", &[("capacity", "20"), ("power_now", "broken")]);
    let report = hardware::batteries(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(report.values.len(), 2);
    assert_eq!(report.values[0].percent, 73.);
    assert_eq!(report.values[0].watts, Some(12.));
    assert_eq!(report.values[1].watts, None);
    f.put("class/power_supply/BAT0/capacity", "101");
    let report = hardware::batteries(&f.0).unwrap();
    assert_eq!(report.values.len(), 1);
    assert_eq!(report.errors.len(), 1);
}
#[test]
fn skips_hid_device_scope_absent_and_mains_supplies() {
    let f = Fixture::new();
    // Directories in place of attributes would produce errors if read.
    for name in ["hid-disconnected-battery", "hidpp_battery_0"] {
        fs::create_dir_all(f.0.join(format!("class/power_supply/{name}/type"))).unwrap();
        fs::create_dir_all(f.0.join(format!("class/power_supply/{name}/scope"))).unwrap();
    }
    f.battery("mouse", &[("scope", "Device")]);
    f.battery("BAT0", &[("present", "0")]);
    f.put("class/power_supply/AC/type", "Mains");
    let report = hardware::batteries(&f.0).unwrap();
    assert!(report.values.is_empty() && report.errors.is_empty());
}
#[test]
fn malformed_battery_does_not_hide_a_healthy_device() {
    let f = Fixture::new();
    f.battery("BAT0", &[("energy_now", "20"), ("energy_full", "0")]);
    f.battery("BAT1", &[("capacity", "44")]);
    let report = hardware::batteries(&f.0).unwrap();
    assert_eq!(report.values[0].name, "BAT1");
    assert_eq!(report.errors.len(), 1);
}
#[test]
fn absence_and_directory_errors_are_distinct() {
    let f = Fixture::new();
    assert!(hardware::batteries(&f.0).unwrap().values.is_empty());
    assert!(hardware::temperatures(&f.0).unwrap().values.is_empty());
    f.put("class/power_supply", "not a directory");
    assert!(hardware::batteries(&f.0).is_err());
    f.put("class/hwmon", "not a directory");
    assert!(hardware::temperatures(&f.0).is_err());
}
#[test]
fn hwmon_preserves_negative_zero_and_labels_without_thermal_duplicates() {
    let f = Fixture::new();
    f.sensor("hwmon0", "1", "-5250");
    f.sensor("hwmon0", "2", "0");
    f.put("class/hwmon/hwmon0/temp1_label", "Package id 0");
    f.put("class/thermal/thermal_zone0/temp", "99999");
    let report = hardware::temperatures(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(report.values.len(), 2);
    assert_eq!(report.values[0].celsius, -5.25);
    assert!(report.values[0].name.contains("Package id 0"));
    assert_eq!(report.values[1].celsius, 0.);
}
#[test]
fn disabled_faulty_and_malformed_sensors_are_not_fake_zeros() {
    let f = Fixture::new();
    f.sensor("hwmon0", "1", "56025");
    f.sensor("hwmon0", "2", "70000");
    f.sensor("hwmon0", "3", "80000");
    f.sensor("hwmon0", "4", "NaN");
    f.sensor("hwmon0", "5", "2147483647");
    f.put("class/hwmon/hwmon0/temp2_enable", "0");
    f.put("class/hwmon/hwmon0/temp3_fault", "1");
    let report = hardware::temperatures(&f.0).unwrap();
    assert_eq!(report.values.len(), 1);
    assert_eq!(report.values[0].celsius, 56.025);
    assert_eq!(report.errors.len(), 3);
}
#[test]
fn thermistor_channels_require_calibrated_conversion() {
    let f = Fixture::new();
    f.sensor("hwmon0", "1", "950");
    f.put("class/hwmon/hwmon0/temp1_type", "4");
    f.sensor("hwmon0", "2", "55000");
    let report = hardware::temperatures(&f.0).unwrap();
    assert_eq!(report.values.len(), 1);
    assert_eq!(report.values[0].celsius, 55.);
    assert_eq!(report.errors.len(), 1);
    assert!(report.errors[0].contains("Thermistor conversion"));
}

#[test]
fn thermal_zone_fallback_ignores_cooling_devices() {
    let f = Fixture::new();
    f.put("class/thermal/thermal_zone0/temp", "42000");
    f.put("class/thermal/thermal_zone0/type", "x86_pkg_temp");
    f.put("class/thermal/cooling_device0/type", "Processor");
    let report = hardware::temperatures(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(report.values[0].name, "x86_pkg_temp");
    assert_eq!(report.values[0].celsius, 42.);
}
#[test]
fn optional_hardware_does_not_fail_the_live_core_gate() {
    let f = Fixture::new();
    f.core();
    let mut sampler = Sampler::with_sources(f.sources());
    let first = sampler.sample();
    assert!(!first.valid);
    f.put("proc/stat", "cpu 150 0 50 840 60 0 0 0");
    let second = sampler.sample();
    assert!(second.valid);
    assert_eq!(second.panels.len(), 8);
    assert_eq!(second.panels[4].label, "No system battery");
    assert!(second.panels[4].series.is_empty());
    assert_eq!(second.panels[5].label, "No temperature sensors");
    assert!(second.panels[5].series.is_empty());
}
#[test]
fn battery_histories_follow_devices_through_failures_and_hotplug() {
    let f = Fixture::new();
    f.core();
    f.battery("BAT0", &[("capacity", "50")]);
    f.battery("BAT1", &[("capacity", "80")]);
    let mut sampler = Sampler::with_sources(f.sources());
    assert_eq!(sampler.sample().panels[4].series[1].last(), Some(&80.));
    fs::remove_dir_all(f.0.join("class/power_supply/BAT0")).unwrap();
    f.put("class/power_supply/BAT1/capacity", "79");
    let next = sampler.sample();
    assert_eq!(&next.panels[4].series[0][118..], [80., 79.]);
    f.put("class/power_supply/BAT1/capacity", "bad");
    assert_eq!(sampler.sample().panels[4].label, "Battery unavailable");
    f.put("class/power_supply/BAT1/capacity", "0");
    let next = sampler.sample();
    assert_eq!(&next.panels[4].series[0][118..], [79., 0.]);
    fs::remove_dir_all(f.0.join("class/power_supply/BAT1")).unwrap();
    assert!(sampler.sample().panels[4].series.is_empty());
    f.battery("BAT1", &[("capacity", "25")]);
    let next = sampler.sample();
    assert_eq!(&next.panels[4].series[0][118..], [0., 25.]);
}
#[test]
fn temperature_graph_uses_maximum_and_keeps_signed_scale() {
    let f = Fixture::new();
    f.core();
    f.sensor("hwmon0", "1", "55000");
    f.sensor("hwmon0", "2", "75000");
    let mut sampler = Sampler::with_sources(f.sources());
    let next = sampler.sample();
    assert_eq!(next.panels[5].series[0].last(), Some(&75.));
    assert!(next.panels[5].detail.contains("55.0 °C"));
    f.put("class/hwmon/hwmon0/temp1_input", "-25000");
    f.put("class/hwmon/hwmon0/temp2_input", "bad");
    let next = sampler.sample();
    assert!(next.panels[5].label.contains("partial"));
    assert_eq!(next.panels[5].series[0].last(), Some(&-25.));
    assert_eq!(
        next.panels[5].scale.bounds(&next.panels[5].series),
        (-30., 120.)
    );
    assert_eq!(Scale::Percent.bounds(&[]), (0., 100.));
}
