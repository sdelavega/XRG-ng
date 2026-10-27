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
    assert_eq!(second.panels.len(), 12);
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
    use xrg_ng_linux::temperature::Units;
    let panel = &next.panels[5];
    let history = panel.series.clone();
    assert!(
        panel
            .display_label(Units::Fahrenheit)
            .starts_with("167.0 °F max")
    );
    assert!(panel.display_detail(Units::Fahrenheit).contains("131.0 °F"));
    assert_eq!(panel.display_label(Units::Celsius), panel.label);
    assert_eq!(panel.series, history);
    f.put("class/hwmon/hwmon0/temp1_input", "-25000");
    f.put("class/hwmon/hwmon0/temp2_input", "bad");
    let next = sampler.sample();
    assert!(next.panels[5].label.contains("partial"));
    assert_eq!(next.panels[5].series[0].last(), Some(&-25.));
    assert!(
        next.panels[5]
            .display_label(Units::Fahrenheit)
            .starts_with("-13.0 °F max")
    );
    assert_eq!(
        next.panels[5].scale.bounds(&next.panels[5].series),
        (-30., 120.)
    );
    assert_eq!(Scale::Percent.bounds(&[]), (0., 100.));
}

#[test]
fn process_panel_counts_readable_tasks_and_exposes_rankings() {
    let f = Fixture::new();
    f.core();
    f.put(
        "proc/123/stat",
        "123 (fixture worker) R 1 2 3 4 5 0 0 0 0 0 10 2 0 0 20 0 2 0 100 1048576 5\n",
    );
    f.put("proc/123/status", "Uid: 1000 1000 1000 1000\n");
    let mut sampler = Sampler::with_sources(f.sources());
    let snapshot = sampler.sample();
    let panel = snapshot
        .panels
        .iter()
        .find(|p| p.title == "Processes")
        .unwrap();
    assert!(panel.label.contains("1 readable"));
    assert!(panel.label.contains("1 running"));
    assert!(panel.detail.contains("fixture worker"));
    assert!(panel.detail.contains("UID 1000"));
    assert!(panel.detail.contains("Top RSS"));
    assert_eq!(panel.series.len(), 2);
}
#[test]
fn tpu_panel_keeps_producer_scope_and_omits_invalid_or_missing_series() {
    let f = Fixture::new();
    f.core();
    f.put(
        "stats.json",
        "{\"total_inferences\":5,\"last_latency_ms\":2.5,\"temperature\":-10,\"model_name\":\"Model 25.0 °C\"}",
    );
    let mut sampler = Sampler::with_sources(f.sources().with_tpu_stats(f.0.join("stats.json")));
    let snapshot = sampler.sample();
    let panel = snapshot
        .panels
        .iter()
        .find(|p| p.title == "TPU / NPU")
        .unwrap();
    let fahrenheit = panel.display_detail(xrg_ng_linux::temperature::Units::Fahrenheit);
    assert!(fahrenheit.contains("Producer-reported temperature: 14.0 °F (unscoped)"));
    assert!(fahrenheit.contains("Model: Model 25.0 °C"));
    assert!(panel.label.contains("hardware unverified"));
    assert!(panel.detail.contains("2.50 ms"));
    assert!(panel.series.is_empty());
    f.put("stats.json", "{\"total_inferences\":6}");
    let snapshot = sampler.sample();
    let panel = snapshot
        .panels
        .iter()
        .find(|p| p.title == "TPU / NPU")
        .unwrap();
    assert_eq!(panel.series.len(), 1);
    f.put("stats.json", "{\"total_inferences\":7,\"timestamp\":0}");
    let snapshot = sampler.sample();
    let panel = snapshot
        .panels
        .iter()
        .find(|p| p.title == "TPU / NPU")
        .unwrap();
    assert!(panel.series.is_empty());
    assert!(panel.detail.contains("stale"));
}

#[test]
fn battery_energy_health_cycles_and_time_use_matching_units() {
    use hardware::TimeSource;
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("energy_now", "20000000"),
            ("energy_full", "40000000"),
            ("energy_full_design", "50000000"),
            ("power_now", "-10000000"),
            ("status", "Discharging"),
            ("cycle_count", "0"),
            ("health", "Good"),
        ],
    );
    let report = hardware::batteries(&f.0).unwrap();
    let b = &report.values[0];
    assert_eq!(b.percent, 50.);
    assert_eq!(b.health_percent, Some(80.));
    assert_eq!(b.cycles, Some(0));
    assert_eq!(b.condition.as_deref(), Some("Good"));
    assert_eq!(b.time.unwrap().seconds, 7200.);
    assert_eq!(b.time.unwrap().source, TimeSource::EnergyPower);
    assert!(b.description().contains("Time to empty: 2 h 0 min"));
    assert!(b.notes.is_empty());
}
#[test]
fn charging_charge_time_does_not_require_voltage_or_mix_energy_counters() {
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("energy_now", "900000000"),
            ("charge_now", "1000000"),
            ("charge_full", "3000000"),
            ("charge_full_design", "4000000"),
            ("current_now", "-500000"),
            ("status", "Charging"),
        ],
    );
    let b = hardware::batteries(&f.0).unwrap().values.remove(0);
    assert_eq!(b.health_percent, Some(75.));
    assert_eq!(b.watts, None);
    assert_eq!(b.time.unwrap().seconds, 14400.);
    assert_eq!(b.time.unwrap().source, hardware::TimeSource::ChargeCurrent);
    assert!(b.description().contains("Time to full"));
}
#[test]
fn driver_time_wins_and_inactive_states_do_not_invent_countdowns() {
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("energy_now", "10000000"),
            ("energy_full", "20000000"),
            ("power_now", "10000000"),
            ("status", "Discharging"),
            ("time_to_empty_now", "1234"),
        ],
    );
    let b = hardware::batteries(&f.0).unwrap().values.remove(0);
    assert_eq!(b.time.unwrap().seconds, 1234.);
    assert_eq!(b.time.unwrap().source, hardware::TimeSource::Driver);
    for status in ["Full", "Not charging", "Unknown", "garbage"] {
        f.put("class/power_supply/BAT0/status", status);
        assert!(hardware::batteries(&f.0).unwrap().values[0].time.is_none());
    }
    f.put("class/power_supply/BAT0/status", "Discharging");
    f.put("class/power_supply/BAT0/time_to_empty_now", "0");
    assert_eq!(
        hardware::batteries(&f.0).unwrap().values[0]
            .time
            .unwrap()
            .seconds,
        3600.
    );
    f.put("class/power_supply/BAT0/time_to_empty_now", "-1");
    let b = hardware::batteries(&f.0).unwrap().values.remove(0);
    assert!(!b.notes.is_empty());
    assert_eq!(b.time.unwrap().source, hardware::TimeSource::EnergyPower);
}
#[test]
fn incomplete_battery_units_and_missing_optional_fields_stay_unknown() {
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("capacity", "61"),
            ("energy_now", "9999999"),
            ("charge_full", "3000000"),
            ("energy_full_design", "50000000"),
            ("power_now", "1000000"),
            ("status", "Discharging"),
        ],
    );
    let b = hardware::batteries(&f.0).unwrap().values.remove(0);
    assert_eq!(b.percent, 61.);
    assert!(b.health_percent.is_none() && b.time.is_none() && b.cycles.is_none());
}
#[test]
fn bad_optional_battery_details_preserve_capacity_and_report_partial_data() {
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("capacity", "40"),
            ("power_now", "bad"),
            ("energy_full", "20000000"),
            ("energy_full_design", "0"),
            ("cycle_count", "-1"),
            ("time_to_empty_now", "bad"),
            ("status", "Discharging"),
        ],
    );
    let report = hardware::batteries(&f.0).unwrap();
    assert!(report.errors.is_empty());
    let b = &report.values[0];
    assert_eq!(b.percent, 40.);
    assert_eq!(b.watts, None);
    assert!(b.notes.len() >= 4);
    let mut s = Sampler::with_sources(f.sources());
    assert!(s.sample().panels[4].label.contains("partial"));
}
#[test]
fn battery_design_excess_and_zero_rates_are_not_clamped_or_infinite() {
    let f = Fixture::new();
    f.battery(
        "BAT0",
        &[
            ("energy_now", "26000000"),
            ("energy_full", "52000000"),
            ("energy_full_design", "50000000"),
            ("power_now", "0"),
            ("current_now", "0"),
            ("status", "Charging"),
        ],
    );
    let b = hardware::batteries(&f.0).unwrap().values.remove(0);
    assert_eq!(b.health_percent, Some(104.));
    assert_eq!(b.watts, Some(0.));
    assert!(b.time.is_none());
}
#[test]
fn fans_keep_stopped_zero_distinct_from_disabled_faulted_and_negative() {
    let f = Fixture::new();
    for (channel, rpm) in [(1, "0"), (2, "1500"), (3, "1000"), (4, "2000"), (5, "-1")] {
        f.put(&format!("class/hwmon/hwmon0/fan{channel}_input"), rpm);
    }
    f.put("class/hwmon/hwmon0/name", "board");
    f.put("class/hwmon/hwmon0/fan1_label", "Chassis");
    f.put("class/hwmon/hwmon0/fan2_alarm", "1");
    f.put("class/hwmon/hwmon0/fan3_enable", "0");
    f.put("class/hwmon/hwmon0/fan4_fault", "1");
    f.put("class/hwmon/hwmon0/pwm1", "255");
    let report = hardware::fans(&f.0).unwrap();
    assert_eq!(report.values.len(), 2);
    assert_eq!(report.values[0].rpm, 0);
    assert!(report.values[0].name.contains("Chassis"));
    assert_eq!(report.values[1].rpm, 1500);
    assert_eq!(report.values[1].alarm, Some(true));
    assert_eq!(report.errors.len(), 2);
    assert_eq!(
        fs::read_to_string(f.0.join("class/hwmon/hwmon0/pwm1")).unwrap(),
        "255"
    );
}
#[test]
fn fan_aliases_deduplicate_and_history_resets_after_missing_or_replaced_sources() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    f.put("class/hwmon/hwmon0/name", "board");
    f.put("class/hwmon/hwmon0/fan1_input", "1000");
    symlink(
        f.0.join("class/hwmon/hwmon0"),
        f.0.join("class/hwmon/hwmon9"),
    )
    .unwrap();
    assert_eq!(hardware::fans(&f.0).unwrap().values.len(), 1);
    let mut s = Sampler::with_sources(f.sources());
    assert_eq!(s.sample().panels[11].series[0].last(), Some(&1000.));
    f.put("class/hwmon/hwmon0/fan1_input", "1500");
    assert_eq!(s.sample().panels[11].series[0][118..], [1000., 1500.]);
    fs::remove_file(f.0.join("class/hwmon/hwmon0/fan1_input")).unwrap();
    assert!(s.sample().panels[11].series.is_empty());
    f.put("class/hwmon/hwmon0/fan1_input", "2000");
    let panel = s.sample().panels.remove(11);
    assert_eq!(panel.series[0].last(), Some(&2000.));
    assert!(panel.series[0][..119].iter().all(|v| *v == 0.));
    assert_eq!(panel.scale, Scale::Automatic);
}
#[test]
fn fan_special_files_malformed_flags_and_oversized_labels_are_bounded_errors() {
    use std::{ffi::CString, os::unix::ffi::OsStrExt};
    let f = Fixture::new();
    f.put("class/hwmon/hwmon0/name", "board");
    let fifo = f.0.join("class/hwmon/hwmon0/fan1_input");
    let c = CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    f.put("class/hwmon/hwmon0/fan2_input", "1000");
    f.put("class/hwmon/hwmon0/fan2_enable", "2");
    f.put("class/hwmon/hwmon0/fan3_input", "2000");
    f.put("class/hwmon/hwmon0/fan3_label", &"x".repeat(4097));
    let report = hardware::fans(&f.0).unwrap();
    assert!(report.values.is_empty());
    assert_eq!(report.errors.len(), 3);
}
#[test]
fn fan_scan_work_is_capped_and_reports_partial_coverage() {
    let f = Fixture::new();
    f.put("class/hwmon/hwmon0/name", "board");
    for n in 1..=257 {
        f.put(&format!("class/hwmon/hwmon0/fan{n}_input"), "1000");
    }
    let report = hardware::fans(&f.0).unwrap();
    assert!(report.values.len() <= 256);
    assert!(report.errors.iter().any(|e| e.contains("partial")));
}
