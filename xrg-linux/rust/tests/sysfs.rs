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
fn via_external_channels_require_board_calibration() {
    let f = Fixture::new();
    f.sensor("hwmon0", "3", "950");
    f.put("class/hwmon/hwmon0/temp3_type", "4");
    f.sensor("hwmon0", "2", "55000");
    f.put("class/hwmon/hwmon0/name", "vt1211");
    let report = hardware::temperatures(&f.0).unwrap();
    assert_eq!(report.values.len(), 1);
    assert_eq!(report.values[0].celsius, 55.);
    assert_eq!(report.errors.len(), 1);
    assert!(report.errors[0].contains("board-specific calibration"));
}

#[test]
fn kernel_converted_thermistors_are_celsius_including_negative_and_zero() {
    for chip in [
        "b57330v2103",
        "b57891s0103",
        "ncp03wb473",
        "ncp03wf104",
        "ncp15wb473",
        "ncp15wl333",
        "ncp15xh103",
        "ncp18wb473",
        "ncp21wb473",
        "ssg1404_001221",
        "ncp18wm474",
        "w83782d",
        "it87",
    ] {
        let f = Fixture::new();
        for (channel, raw) in [("1", "-12500"), ("2", "0"), ("3", "55025")] {
            f.sensor("hwmon0", channel, raw);
            f.put(&format!("class/hwmon/hwmon0/temp{channel}_type"), "4");
        }
        f.put("class/hwmon/hwmon0/name", chip);
        f.put("class/thermal/thermal_zone0/temp", "99999");
        let report = hardware::temperatures(&f.0).unwrap();
        assert!(report.errors.is_empty(), "{chip}: {:?}", report.errors);
        assert_eq!(
            report.values.iter().map(|v| v.celsius).collect::<Vec<_>>(),
            [-12.5, 0., 55.025],
            "{chip}"
        );
        assert!(report.values.iter().all(|v| !v.thermal));
    }
}

#[test]
fn via_raw_channels_without_type_metadata_never_become_celsius() {
    for (chip, channels) in [
        ("vt1211", vec![1, 3, 4, 5, 6, 7]),
        ("vt8231", vec![1, 2, 3, 4, 5, 6]),
    ] {
        let f = Fixture::new();
        for channel in &channels {
            f.sensor("hwmon0", &channel.to_string(), "1100");
        }
        f.put("class/hwmon/hwmon0/name", chip);
        f.put("class/thermal/thermal_zone0/temp", "42000");
        let report = hardware::temperatures(&f.0).unwrap();
        assert_eq!(report.values.len(), 1);
        assert_eq!(report.values[0].celsius, 42.);
        assert!(report.values[0].thermal);
        assert_eq!(report.errors.len(), channels.len());
        assert!(
            report
                .errors
                .iter()
                .all(|e| e.contains("calibration") && e.contains("not Celsius"))
        );
    }
}

#[test]
fn thermistor_faults_disable_flags_and_unsupported_types_do_not_create_samples() {
    let f = Fixture::new();
    for channel in 1..=6 {
        f.sensor("hwmon0", &channel.to_string(), "0");
    }
    f.put("class/hwmon/hwmon0/name", "ncp15wb473");
    f.put("class/hwmon/hwmon0/temp1_enable", "0");
    f.put("class/hwmon/hwmon0/temp1_type", "invalid while disabled");
    f.put("class/hwmon/hwmon0/temp1_fault", "invalid while disabled");
    f.put("class/hwmon/hwmon0/temp2_type", "4");
    f.put("class/hwmon/hwmon0/temp2_fault", "1");
    for (channel, kind) in [(3, "0"), (4, "-1"), (5, "7"), (6, "bad")] {
        f.put(&format!("class/hwmon/hwmon0/temp{channel}_type"), kind);
    }
    let report = hardware::temperatures(&f.0).unwrap();
    assert!(report.values.is_empty());
    assert_eq!(report.errors.len(), 5);
    assert!(report.errors.iter().any(|e| e.contains("fault")));
}

#[test]
fn temperature_probe_type_changes_reset_history_but_keep_saved_source_identity() {
    use xrg_ng_linux::settings::MetricSelection;
    let f = Fixture::new();
    f.core();
    f.sensor("hwmon0", "1", "42000");
    f.put("class/hwmon/hwmon0/temp1_type", "1");
    let before = hardware::temperatures(&f.0).unwrap().values.remove(0);
    let selection = MetricSelection {
        temperature: Some(before.source_id.clone()),
        ..Default::default()
    };
    let mut sampler = Sampler::with_sources(f.sources());
    sampler.set_selection(selection.clone()).unwrap();
    assert_eq!(sampler.sample().panels[5].series[0].last(), Some(&42.));
    f.put("class/hwmon/hwmon0/temp1_type", "4");
    f.put("class/hwmon/hwmon0/temp1_input", "43000");
    let after = hardware::temperatures(&f.0).unwrap().values.remove(0);
    assert_eq!(after.source_id, before.source_id);
    assert_ne!(after.id, before.id);
    let snapshot = sampler.sample();
    assert_eq!(snapshot.selection, selection);
    assert_eq!(snapshot.panels[5].series[0][118..], [0., 43.]);
}

#[test]
fn kernel_thermistor_class_aliases_do_not_duplicate_or_modify_the_sensor() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    let path = "devices/platform/board/hwmon/hwmon0";
    f.put(&format!("{path}/name"), "ncp15wb473");
    f.put(&format!("{path}/temp1_type"), "4");
    f.put(&format!("{path}/temp1_input"), "25000");
    fs::create_dir_all(f.0.join("class/hwmon")).unwrap();
    for alias in ["hwmon0", "hwmon8"] {
        symlink(f.0.join(path), f.0.join("class/hwmon").join(alias)).unwrap();
    }
    let report = hardware::temperature_sources(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(report.values.len(), 1);
    assert_eq!(report.values[0].celsius, 25.);
    assert_eq!(
        fs::read_to_string(f.0.join(format!("{path}/temp1_type"))).unwrap(),
        "4"
    );
}

#[test]
fn thermal_zone_fallback_ignores_cooling_devices() {
    let f = Fixture::new();
    f.put("class/thermal/thermal_zone0/temp", "42000");
    f.put("class/thermal/thermal_zone0/type", "x86_pkg_temp");
    f.put("class/thermal/cooling_device0/type", "Processor");
    let report = hardware::temperatures(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(report.values[0].name, "x86_pkg_temp (thermal_zone0)");
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
    assert_eq!(second.panels.len(), 13);
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

#[test]
fn selected_temperature_and_fan_never_fall_back_and_clear_replaced_history() {
    use xrg_ng_linux::settings::MetricSelection;
    let f = Fixture::new();
    f.core();
    f.sensor("hwmon0", "1", "10000");
    f.sensor("hwmon0", "2", "90000");
    f.put("class/hwmon/hwmon0/temp1_label", "Same label");
    f.put("class/hwmon/hwmon0/temp2_label", "Same label");
    f.put("class/hwmon/hwmon0/fan1_input", "1100");
    f.put("class/hwmon/hwmon0/fan2_input", "0");
    let temperatures = hardware::temperatures(&f.0).unwrap().values;
    let fans = hardware::fans(&f.0).unwrap().values;
    let temperature = temperatures
        .iter()
        .find(|s| s.celsius == 10.)
        .unwrap()
        .source_id
        .clone();
    let fan = fans.iter().find(|s| s.rpm == 0).unwrap().source_id.clone();
    assert_ne!(temperatures[0].source_id, temperatures[1].source_id);
    let mut s = Sampler::with_sources(f.sources());
    let selection = MetricSelection {
        temperature: Some(temperature.clone()),
        fan: Some(fan.clone()),
        ..Default::default()
    };
    s.set_selection(selection.clone()).unwrap();
    let first = s.sample();
    assert_eq!(first.inventory.temperatures.len(), 2);
    assert_eq!(first.inventory.fans.len(), 2);
    assert_eq!(first.panels[5].series[0].last(), Some(&10.));
    assert!(!first.panels[5].label.contains(" max"));
    assert_eq!(first.panels[11].series.len(), 1);
    assert_eq!(first.panels[11].series[0].last(), Some(&0.));
    f.put("class/hwmon/hwmon0/temp1_label", "Renamed temperature");
    f.put("class/hwmon/hwmon0/fan2_label", "Renamed fan");
    f.put("class/hwmon/hwmon0/temp1_input", "12000");
    f.put("class/hwmon/hwmon0/fan2_input", "600");
    let next = s.sample();
    assert_eq!(next.panels[5].series[0][118..], [10., 12.]);
    assert_eq!(next.panels[11].series[0][118..], [0., 600.]);
    // Keep old inodes allocated, forcing a distinct attribute incarnation.
    for path in ["temp1_input", "fan2_input"] {
        let path = f.0.join("class/hwmon/hwmon0").join(path);
        fs::rename(&path, path.with_extension("old")).unwrap();
    }
    f.put("class/hwmon/hwmon0/temp1_input", "15000");
    f.put("class/hwmon/hwmon0/fan2_input", "900");
    let replaced = s.sample();
    assert_eq!(replaced.selection, selection);
    assert_eq!(replaced.panels[5].series[0][118..], [0., 15.]);
    assert_eq!(replaced.panels[11].series[0][118..], [0., 900.]);
    fs::remove_file(f.0.join("class/hwmon/hwmon0/temp1_input")).unwrap();
    fs::remove_file(f.0.join("class/hwmon/hwmon0/fan2_input")).unwrap();
    let missing = s.sample();
    assert!(
        missing.panels[5]
            .label
            .contains("Selected temperature sensor unavailable")
    );
    assert!(
        missing.panels[11]
            .label
            .contains("Selected fan unavailable")
    );
    assert!(missing.panels[5].series.is_empty() && missing.panels[11].series.is_empty());
    assert_eq!(missing.selection, selection);
    f.put("class/hwmon/hwmon0/temp1_input", "17000");
    f.put("class/hwmon/hwmon0/fan2_input", "1200");
    let returned = s.sample();
    assert_eq!(returned.panels[5].series[0][118..], [0., 17.]);
    assert_eq!(returned.panels[11].series[0][118..], [0., 1200.]);
    s.set_selection(MetricSelection::default()).unwrap();
    let aggregate = s.sample();
    assert_eq!(aggregate.panels[5].series[0][118..], [0., 90.]);
    assert_eq!(aggregate.panels[11].series.len(), 2);
}

#[test]
fn physical_sensor_identity_survives_hwmon_renumbering_and_aliases() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    f.put("devices/platform/board/hwmon/hwmon0/name", "board");
    f.put("devices/platform/board/hwmon/hwmon0/temp1_input", "42000");
    f.put("devices/platform/board/hwmon/hwmon0/fan1_input", "1234");
    fs::create_dir_all(f.0.join("class/hwmon")).unwrap();
    symlink(
        f.0.join("devices/platform/board/hwmon/hwmon0"),
        f.0.join("class/hwmon/hwmon0"),
    )
    .unwrap();
    symlink(
        f.0.join("devices/platform/board/hwmon/hwmon0"),
        f.0.join("class/hwmon/hwmon7"),
    )
    .unwrap();
    let old_temperature = hardware::temperatures(&f.0).unwrap().values;
    let old_fan = hardware::fans(&f.0).unwrap().values;
    assert_eq!(old_temperature.len(), 1);
    assert_eq!(old_fan.len(), 1);
    fs::remove_file(f.0.join("class/hwmon/hwmon0")).unwrap();
    fs::remove_file(f.0.join("class/hwmon/hwmon7")).unwrap();
    fs::rename(
        f.0.join("devices/platform/board/hwmon/hwmon0"),
        f.0.join("devices/platform/board/hwmon/hwmon9"),
    )
    .unwrap();
    symlink(
        f.0.join("devices/platform/board/hwmon/hwmon9"),
        f.0.join("class/hwmon/hwmon9"),
    )
    .unwrap();
    let new_temperature = hardware::temperatures(&f.0).unwrap().values;
    let new_fan = hardware::fans(&f.0).unwrap().values;
    assert_eq!(new_temperature[0].source_id, old_temperature[0].source_id);
    assert_eq!(new_fan[0].source_id, old_fan[0].source_id);
    assert_eq!(new_temperature[0].id, old_temperature[0].id);
    assert_eq!(new_fan[0].id, old_fan[0].id);
}

#[test]
fn ambiguous_physical_channels_are_not_assigned_to_a_saved_choice() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    fs::create_dir_all(f.0.join("class/hwmon")).unwrap();
    for node in ["hwmon0", "hwmon1"] {
        let path = format!("devices/platform/board/hwmon/{node}");
        f.put(&format!("{path}/name"), "board");
        f.put(&format!("{path}/temp1_input"), "42000");
        f.put(&format!("{path}/fan1_input"), "1234");
        symlink(f.0.join(path), f.0.join("class/hwmon").join(node)).unwrap();
    }
    let temperatures = hardware::temperatures(&f.0).unwrap();
    let fans = hardware::fans(&f.0).unwrap();
    assert!(temperatures.values.is_empty() && fans.values.is_empty());
    assert!(temperatures.errors.iter().any(|s| s.contains("Ambiguous")));
    assert!(fans.errors.iter().any(|s| s.contains("Ambiguous")));
}

#[test]
fn thermal_fallback_does_not_replace_a_missing_selected_hwmon_source() {
    let f = Fixture::new();
    f.core();
    f.sensor("hwmon0", "1", "42000");
    let id = hardware::temperatures(&f.0).unwrap().values[0]
        .source_id
        .clone();
    let mut s = Sampler::with_sources(f.sources());
    s.set_selection(xrg_ng_linux::settings::MetricSelection {
        temperature: Some(id),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(s.sample().panels[5].series[0].last(), Some(&42.));
    fs::remove_dir_all(f.0.join("class/hwmon")).unwrap();
    f.put("class/thermal/thermal_zone0/type", "x86_pkg_temp");
    f.put("class/thermal/thermal_zone0/temp", "90000");
    let missing = s.sample();
    assert!(missing.panels[5].series.is_empty());
    assert_eq!(missing.inventory.temperatures.len(), 1);
}

#[test]
fn temperature_scan_budget_and_nonstandard_enable_flags_report_partial_coverage() {
    let f = Fixture::new();
    for channel in 1..=257 {
        f.sensor("hwmon0", &channel.to_string(), "42000");
    }
    let report = hardware::temperatures(&f.0).unwrap();
    assert!(report.values.len() <= 256);
    assert!(!report.errors.is_empty());
    let f = Fixture::new();
    f.sensor("hwmon0", "1", "42000");
    f.put("class/hwmon/hwmon0/temp1_enable", "2");
    let report = hardware::temperatures(&f.0).unwrap();
    assert!(report.values.is_empty());
    assert!(report.errors.iter().any(|e| e.contains("enable flag")));
}

#[test]
fn selected_thermal_zone_stays_readable_when_hwmon_appears() {
    let f = Fixture::new();
    f.core();
    f.put("class/thermal/thermal_zone0/type", "x86_pkg_temp");
    f.put("class/thermal/thermal_zone0/temp", "40000");
    let id = hardware::temperature_sources(&f.0).unwrap().values[0]
        .source_id
        .clone();
    let mut s = Sampler::with_sources(f.sources());
    s.set_selection(xrg_ng_linux::settings::MetricSelection {
        temperature: Some(id.clone()),
        ..Default::default()
    })
    .unwrap();
    assert_eq!(s.sample().panels[5].series[0].last(), Some(&40.));
    f.sensor("hwmon0", "1", "90000");
    let selected = s.sample();
    assert_eq!(selected.inventory.temperatures.len(), 2);
    assert_eq!(selected.panels[5].series[0].last(), Some(&40.));
    assert_eq!(selected.selection.temperature, Some(id));
    s.set_selection(Default::default()).unwrap();
    assert_eq!(s.sample().panels[5].series[0].last(), Some(&90.));
}

#[test]
fn thermal_aliases_without_type_metadata_are_still_one_source() {
    let f = Fixture::new();
    f.put("class/thermal/thermal_zone0/temp", "42000");
    std::os::unix::fs::symlink(
        f.0.join("class/thermal/thermal_zone0"),
        f.0.join("class/thermal/thermal_zone8"),
    )
    .unwrap();
    let report = hardware::temperature_sources(&f.0).unwrap();
    assert!(report.errors.is_empty());
    assert_eq!(
        report.values.len(),
        1,
        "An alias must not create a second source when type metadata is missing"
    );
}

fn sensor_channels(f: &Fixture) -> ([String; 3], [String; 3]) {
    f.core();
    for (channel, temperature, fan) in [
        (1, "10000", "1000"),
        (2, "20000", "0"),
        (3, "-5000", "2400"),
    ] {
        f.sensor("hwmon0", &channel.to_string(), temperature);
        f.put(
            &format!("class/hwmon/hwmon0/temp{channel}_label"),
            "Same label",
        );
        f.put(&format!("class/hwmon/hwmon0/fan{channel}_input"), fan);
        f.put(
            &format!("class/hwmon/hwmon0/fan{channel}_label"),
            "Same label",
        );
    }
    let temperatures = hardware::temperature_sources(&f.0).unwrap().values;
    let fans = hardware::fans(&f.0).unwrap().values;
    (
        std::array::from_fn(|i| {
            temperatures
                .iter()
                .find(|s| s.source_id.contains(&format!("temp{}_input", i + 1)))
                .unwrap()
                .source_id
                .clone()
        }),
        std::array::from_fn(|i| {
            fans.iter()
                .find(|s| s.source_id.contains(&format!("fan{}_input", i + 1)))
                .unwrap()
                .source_id
                .clone()
        }),
    )
}
fn three_channels(
    temperatures: &[String; 3],
    fans: &[String; 3],
) -> xrg_ng_linux::settings::MetricSelection {
    xrg_ng_linux::settings::MetricSelection {
        temperature: Some(temperatures[0].clone()),
        temperature_extra: [Some(temperatures[1].clone()), Some(temperatures[2].clone())],
        fan: Some(fans[0].clone()),
        fan_extra: [Some(fans[1].clone()), Some(fans[2].clone())],
        ..Default::default()
    }
}
#[test]
fn pinned_curves_follow_identity_and_keep_histories_through_reordering_and_unit_changes() {
    use xrg_ng_linux::temperature::Units;
    let f = Fixture::new();
    let (temperatures, fans) = sensor_channels(&f);
    let mut sampler = Sampler::with_sources(f.sources());
    let mut selection = three_channels(&temperatures, &fans);
    sampler.set_selection(selection.clone()).unwrap();
    let first = sampler.sample();
    for (panel, expected) in [(5, [10., 20., -5.]), (11, [1000., 0., 2400.])] {
        assert_eq!(first.panels[panel].series.len(), 3);
        for (series, value) in first.panels[panel].series.iter().zip(expected) {
            assert_eq!(series.last(), Some(&value));
        }
    }
    assert!(
        first.panels[5]
            .display_label(Units::Fahrenheit)
            .contains("23.0 °F")
    );
    assert!(
        first.panels[5]
            .display_detail(Units::Fahrenheit)
            .contains("Curve 3")
    );
    assert_eq!(first.panels[5].series[2].last(), Some(&-5.));
    f.put("class/hwmon/hwmon0/temp1_input", "11000");
    f.put("class/hwmon/hwmon0/temp1_label", "Renamed channel");
    f.put("class/hwmon/hwmon0/fan2_input", "600");
    let second = sampler.sample();
    assert_eq!(second.panels[5].series[0][118..], [10., 11.]);
    assert_eq!(second.panels[11].series[1][118..], [0., 600.]);
    selection.temperature_extra.swap(0, 1);
    selection.fan_extra.swap(0, 1);
    sampler.set_selection(selection).unwrap();
    let reordered = sampler.sample();
    assert_eq!(reordered.panels[5].series[0][117..], [10., 11., 11.]);
    assert_eq!(reordered.panels[5].series[1][117..], [-5., -5., -5.]);
    assert_eq!(reordered.panels[5].series[2][117..], [20., 20., 20.]);
    assert_eq!(reordered.panels[11].series[2][117..], [0., 600., 600.]);
}
#[test]
fn missing_pinned_primary_never_shifts_peers_or_falls_back_and_replacement_resets_only_its_history()
{
    let f = Fixture::new();
    let (temperatures, fans) = sensor_channels(&f);
    let mut sampler = Sampler::with_sources(f.sources());
    let selection = three_channels(&temperatures, &fans);
    sampler.set_selection(selection.clone()).unwrap();
    sampler.sample();
    for kind in ["temp", "fan"] {
        fs::remove_file(f.0.join(format!("class/hwmon/hwmon0/{kind}1_input"))).unwrap();
    }
    f.sensor("hwmon0", "4", "99000");
    f.put("class/hwmon/hwmon0/fan4_input", "9999");
    let missing = sampler.sample();
    for panel in [5, 11] {
        assert_eq!(missing.panels[panel].series.len(), 3);
        assert!(missing.panels[panel].series[0].iter().all(|v| v.is_nan()));
        assert!(missing.panels[panel].label.contains("1: unavailable"));
    }
    assert_eq!(missing.panels[5].series[1][118..], [20., 20.]);
    assert_eq!(missing.panels[11].series[1][118..], [0., 0.]);
    for kind in ["temp", "fan"] {
        let path = f.0.join(format!("class/hwmon/hwmon0/{kind}2_input"));
        fs::rename(&path, path.with_extension("old")).unwrap();
    }
    f.put("class/hwmon/hwmon0/temp2_input", "65000");
    f.put("class/hwmon/hwmon0/fan2_input", "1500");
    let replaced = sampler.sample();
    assert_eq!(replaced.panels[5].series[1][118..], [0., 65.]);
    assert_eq!(replaced.panels[11].series[1][118..], [0., 1500.]);
    assert_eq!(replaced.panels[5].series[2][117..], [-5., -5., -5.]);
    for kind in ["temp", "fan"] {
        for channel in [2, 3] {
            fs::remove_file(f.0.join(format!("class/hwmon/hwmon0/{kind}{channel}_input"))).unwrap();
        }
    }
    let absent = sampler.sample();
    assert!(absent.panels[5].series.is_empty() && absent.panels[11].series.is_empty());
    assert_eq!(absent.selection, selection);
    assert_eq!(absent.inventory.temperatures.len(), 1);
    f.put("class/hwmon/hwmon0/temp1_input", "17000");
    f.put("class/hwmon/hwmon0/fan1_input", "1200");
    let returned = sampler.sample();
    assert_eq!(returned.panels[5].series[0][118..], [0., 17.]);
    assert_eq!(returned.panels[11].series[0][118..], [0., 1200.]);
    assert!(returned.panels[5].series[2].iter().all(|v| v.is_nan()));
}
#[test]
fn unassigned_curve_two_keeps_curve_three_color_and_a_real_zero_is_not_missing() {
    let f = Fixture::new();
    let (temperatures, fans) = sensor_channels(&f);
    let mut selection = three_channels(&temperatures, &fans);
    selection.temperature_extra[0] = None;
    selection.fan_extra = [None, Some(fans[1].clone())];
    let mut sampler = Sampler::with_sources(f.sources());
    sampler.set_selection(selection).unwrap();
    let snapshot = sampler.sample();
    for panel in [5, 11] {
        assert_eq!(snapshot.panels[panel].series.len(), 3);
        assert!(snapshot.panels[panel].series[1].iter().all(|v| v.is_nan()));
    }
    assert_eq!(snapshot.panels[11].series[2].last(), Some(&0.));
    assert!(snapshot.panels[11].label.contains("3: 0 RPM"));
    assert!(snapshot.panels[5].detail.contains("Curve 3"));
}
#[test]
fn automatic_fans_keep_surviving_color_slots_and_new_sources_fill_only_empty_slots() {
    let f = Fixture::new();
    sensor_channels(&f);
    let mut sampler = Sampler::with_sources(f.sources());
    sampler.sample();
    fs::remove_file(f.0.join("class/hwmon/hwmon0/fan1_input")).unwrap();
    let missing = sampler.sample();
    assert_eq!(missing.panels[11].series.len(), 3);
    assert!(missing.panels[11].series[0].iter().all(|v| v.is_nan()));
    assert_eq!(missing.panels[11].series[1][118..], [0., 0.]);
    assert_eq!(missing.panels[11].series[2][118..], [2400., 2400.]);
    f.put("class/hwmon/hwmon0/fan4_input", "4500");
    let new = sampler.sample();
    assert_eq!(new.panels[11].series[0][118..], [0., 4500.]);
    assert_eq!(new.panels[11].series[2][117..], [2400., 2400., 2400.]);
}
#[test]
fn sensor_scan_failure_clears_inventory_and_never_leaves_a_stale_curve() {
    let f = Fixture::new();
    sensor_channels(&f);
    let mut sampler = Sampler::with_sources(f.sources());
    let first = sampler.sample();
    assert_eq!(first.inventory.fans.len(), 3);
    fs::remove_dir_all(f.0.join("class/hwmon")).unwrap();
    f.put("class/hwmon", "not a directory");
    let failed = sampler.sample();
    assert!(failed.inventory.fans.is_empty() && failed.inventory.temperatures.is_empty());
    assert!(failed.panels[5].series.is_empty() && failed.panels[11].series.is_empty());
}

#[test]
fn automatic_fan_details_keep_alarms_and_notes_for_channels_outside_the_plotted_three() {
    let f = Fixture::new();
    sensor_channels(&f);
    f.put("class/hwmon/hwmon0/fan4_input", "4500");
    f.put("class/hwmon/hwmon0/fan4_alarm", "1");
    f.put("class/hwmon/hwmon0/fan5_input", "5500");
    f.put("class/hwmon/hwmon0/fan5_alarm", "2");
    let mut sampler = Sampler::with_sources(f.sources());
    let panel = sampler.sample().panels.remove(11);
    assert_eq!(panel.series.len(), 3);
    assert!(
        panel
            .detail
            .contains("[fan4]: 4500 RPM · driver alarm active")
    );
    assert!(
        panel
            .detail
            .contains("[fan5]: 5500 RPM\nInvalid fan alarm flag")
    );
    assert!(panel.label.contains("partial"));
}
