// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
#![cfg(unix)]
use std::{
    cell::RefCell,
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::{Path, PathBuf},
    sync::{
        Mutex, MutexGuard,
        atomic::{AtomicU64, Ordering},
    },
    time::{Duration, Instant},
};
use xrg_ng_linux::{
    collectors::LinuxSources,
    command::BoundedCommand,
    engine::Sampler,
    gpu::{GpuCollector, parse_nvidia, pci_id},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
// A concurrent spawn can inherit another test's still-open script writer until
// exec closes CLOEXEC descriptors. Linux then rejects that script with ETXTBSY.
// Isolate executable creation AND use; production queries never write programs.
static EXECUTABLE_FIXTURES: Mutex<()> = Mutex::new(());
struct Fixture(PathBuf, RefCell<Option<MutexGuard<'static, ()>>>);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-gpu-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path, RefCell::new(None))
    }
    fn put(&self, path: &str, value: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, value).unwrap();
    }
    fn gpu(&self, card: &str, pci: &str, vendor: &str, driver: &str) {
        self.put(&format!("bus/pci/devices/{pci}/vendor"), vendor);
        let module = self.0.join(format!("drivers/{driver}"));
        fs::create_dir_all(&module).unwrap();
        symlink(module, self.0.join(format!("bus/pci/devices/{pci}/driver"))).unwrap();
        if !card.is_empty() {
            let directory = self.0.join(format!("class/drm/{card}"));
            fs::create_dir_all(&directory).unwrap();
            symlink(
                self.0.join(format!("bus/pci/devices/{pci}")),
                directory.join("device"),
            )
            .unwrap();
        }
    }
    fn program(&self, name: &str, code: &str) -> PathBuf {
        if self.1.borrow().is_none() {
            let guard = EXECUTABLE_FIXTURES
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *self.1.borrow_mut() = Some(guard);
        }
        self.put(name, &format!("#!/bin/sh\n{code}\n"));
        let path = self.0.join(name);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }
    fn collector(&self) -> GpuCollector {
        GpuCollector::new(&self.0, None)
    }
    fn core(&self) {
        self.put("proc/stat", "cpu 100 0 50 800 50 0 0 0");
        self.put("proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 500 kB");
        self.put("proc/net/dev", "h\nh\nlo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0");
        self.put("proc/diskstats", "8 0 sda 1 0 10 0 1 0 20 0 0 0 0");
        fs::create_dir_all(self.0.join("block/sda")).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
const ROW: &str = "00000000:03:00.0, NVIDIA Test, 37, 512, 8192, 52, 45.5, 20, 1200";

#[test]
fn amd_metrics_have_correct_units_and_zero_is_real() {
    let f = Fixture::new();
    f.gpu("card1", "0000:03:00.0", "0x1002", "amdgpu");
    let base = "bus/pci/devices/0000:03:00.0";
    f.put(&format!("{base}/gpu_busy_percent"), "0");
    f.put(&format!("{base}/mem_info_vram_used"), "1048576");
    f.put(&format!("{base}/mem_info_vram_total"), "8388608");
    for (file, value) in [
        ("temp1_input", "54025"),
        ("power1_average", "45000000"),
        ("freq1_input", "1200000000"),
        ("fan1_input", "1500"),
    ] {
        f.put(&format!("{base}/hwmon/hwmon0/{file}"), value);
    }
    let report = f.collector().sample().unwrap();
    let gpu = &report.values[0];
    assert!(report.errors.is_empty() && gpu.notes.is_empty());
    assert_eq!(gpu.utilization, Some(0.));
    assert_eq!(gpu.memory_used, Some(1048576));
    assert_eq!(gpu.temperature, Some(54.025));
    assert_eq!(gpu.power_watts, Some(45.));
    assert_eq!(gpu.frequency_mhz, Some(1200.));
    assert_eq!(gpu.fan_rpm, Some(1500));
    assert_eq!(gpu.fan_percent, None);
    f.core();
    let mut sampler = Sampler::with_sources(LinuxSources::with_roots(f.0.join("proc"), &f.0));
    let snapshot = sampler.sample();
    let panel = &snapshot.panels[6];
    assert!(
        panel
            .display_detail(xrg_ng_linux::temperature::Units::Fahrenheit)
            .contains("Temperature: 129.2 °F")
    );
    assert!(panel.detail.contains("Temperature: 54.0 °C"));
}
#[test]
fn intel_clock_is_not_fabricated_utilization() {
    let f = Fixture::new();
    f.gpu("card0", "0000:00:02.0", "0x8086", "i915");
    f.put("class/drm/card0/gt_cur_freq_mhz", "500");
    let gpu = f.collector().sample().unwrap().values.remove(0);
    assert_eq!(gpu.frequency_mhz, Some(500.));
    assert_eq!(gpu.utilization, None);
    assert_eq!(gpu.memory_total, None);
    f.core();
    let mut sampler = Sampler::with_sources(LinuxSources::with_roots(f.0.join("proc"), &f.0));
    let panel = sampler
        .sample()
        .panels
        .into_iter()
        .find(|p| p.title == "GPU")
        .unwrap();
    assert!(panel.series.is_empty());
    assert!(panel.label.contains("unavailable"));
    assert!(panel.detail.contains("500 MHz"));
}
#[test]
fn malformed_and_missing_metrics_are_not_idle_samples() {
    let f = Fixture::new();
    f.gpu("card0", "0000:03:00.0", "0x1002", "amdgpu");
    f.put("bus/pci/devices/0000:03:00.0/gpu_busy_percent", "101");
    f.put("bus/pci/devices/0000:03:00.0/mem_info_vram_used", "1000");
    f.put("bus/pci/devices/0000:03:00.0/mem_info_vram_total", "10");
    let gpu = f.collector().sample().unwrap().values.remove(0);
    assert_eq!(gpu.utilization, None);
    assert_eq!(gpu.memory_used, None);
    assert_eq!(gpu.memory_total, None);
    assert_eq!(gpu.notes.len(), 2);
}
#[test]
fn connectors_aliases_and_render_nodes_do_not_duplicate_gpus() {
    let f = Fixture::new();
    f.gpu("card0", "0000:03:00.0", "0x1002", "amdgpu");
    for alias in ["card1", "card0-HDMI-A-1", "renderD128"] {
        let directory = f.0.join(format!("class/drm/{alias}"));
        fs::create_dir_all(&directory).unwrap();
        symlink(
            f.0.join("bus/pci/devices/0000:03:00.0"),
            directory.join("device"),
        )
        .unwrap();
    }
    assert_eq!(f.collector().sample().unwrap().values.len(), 1);
}
#[test]
fn nvidia_is_driver_and_vendor_gated() {
    let f = Fixture::new();
    f.gpu("card0", "0000:03:00.0", "0x10de", "nouveau");
    f.gpu("card1", "0000:04:00.0", "0x8086", "nvidia");
    let program = f.program(
        "smi",
        &format!(
            "touch '{}'\nprintf '%s\\n' '{}'",
            f.0.join("called").display(),
            ROW
        ),
    );
    let report = GpuCollector::new(&f.0, Some(program)).sample().unwrap();
    assert!(!f.0.join("called").exists());
    assert!(report.values.iter().all(|g| g.utilization.is_none()));
}
#[test]
fn suspended_device_does_not_wake_or_query_nvidia() {
    let f = Fixture::new();
    f.gpu("card0", "0000:03:00.0", "0x10de", "nvidia");
    f.put(
        "bus/pci/devices/0000:03:00.0/power/runtime_status",
        "suspended",
    );
    let program = f.program("smi", &format!("touch '{}'", f.0.join("called").display()));
    let report = GpuCollector::new(&f.0, Some(program)).sample().unwrap();
    assert!(!f.0.join("called").exists());
    assert!(report.values[0].notes[0].contains("suspended"));
}
#[test]
fn compute_only_nvidia_and_csv_pci_mapping_work() {
    let f = Fixture::new();
    f.gpu("", "0000:03:00.0", "0x10de", "nvidia");
    let program = f.program(
        "smi",
        &format!(
            "printf '%s\\n' '{}'\nprintf '%s\\n' \"$@\" > '{}'",
            ROW,
            f.0.join("args").display()
        ),
    );
    let report = GpuCollector::new(&f.0, Some(program)).sample().unwrap();
    assert_eq!(report.values[0].id, "0000:03:00.0");
    assert_eq!(report.values[0].utilization, Some(37.), "{report:?}");
    assert_eq!(report.values[0].memory_total, Some(8192 * 1048576));
    assert_eq!(report.values[0].fan_percent, Some(20.));
    assert_eq!(report.values[0].fan_rpm, None);
    assert!(
        fs::read_to_string(f.0.join("args"))
            .unwrap()
            .contains("--id=0000:03:00.0")
    );
}
#[test]
fn nvidia_unsupported_values_and_quoted_names_are_preserved() {
    let report = parse_nvidia(
        "00000000:03:00.0, \"NVIDIA, Test \"\"GPU\"\"\", N/A, 512, 8192, N/A, [Not Supported], 0, 1200",
    );
    assert!(report.errors.is_empty());
    let gpu = &report.values[0];
    assert_eq!(gpu.name, "NVIDIA, Test \"GPU\"");
    assert_eq!(gpu.utilization, None);
    assert_eq!(gpu.temperature, None);
    assert_eq!(gpu.power_watts, None);
    assert_eq!(gpu.fan_percent, Some(0.));
}
#[test]
fn nvidia_invalid_numbers_duplicates_and_identity_are_rejected() {
    let report = parse_nvidia("0000:03:00.0, GPU, NaN, 99, 1, inf, -1, 101, 0");
    let gpu = &report.values[0];
    assert_eq!(gpu.utilization, None);
    assert_eq!(gpu.memory_used, None);
    assert_eq!(gpu.temperature, None);
    assert_eq!(gpu.power_watts, None);
    assert_eq!(gpu.fan_percent, None);
    let report = parse_nvidia(&format!("{ROW}\n{ROW}"));
    assert!(report.values.is_empty());
    assert_eq!(report.errors.len(), 1);
    assert!(parse_nvidia("bad, fields").values.is_empty());
    assert_eq!(pci_id("00000000:AB:01.7"), Some("0000:ab:01.7".into()));
    assert_eq!(pci_id("0000:03:99.8"), None);
    assert_eq!(pci_id("0000:03:00.0;touch /tmp/no"), None);
}
#[test]
fn nvidia_results_are_matched_by_pci_not_output_order() {
    let f = Fixture::new();
    f.gpu("card0", "0000:03:00.0", "0x10de", "nvidia");
    f.gpu("card1", "0000:04:00.0", "0x10de", "nvidia");
    let program = f.program(
        "smi",
        &format!(
            "printf '%s\\n' '{}' '{}'",
            ROW.replace("03:00.0", "04:00.0").replace(", 37,", ", 80,"),
            ROW
        ),
    );
    let report = GpuCollector::new(&f.0, Some(program)).sample().unwrap();
    assert_eq!(report.values[0].label, "card0");
    assert_eq!(report.values[0].utilization, Some(37.));
    assert_eq!(report.values[1].label, "card1");
    assert_eq!(report.values[1].utilization, Some(80.));
}
#[test]
fn timeout_is_bounded_and_failure_cooldown_prevents_respawning() {
    let f = Fixture::new();
    f.gpu("card0", "0000:03:00.0", "0x10de", "nvidia");
    let program = f.program(
        "smi",
        &format!(
            "echo call >> '{}'\nexec sleep 30",
            f.0.join("calls").display()
        ),
    );
    let mut collector = GpuCollector::new(&f.0, Some(program));
    let start = Instant::now();
    let report = collector.sample().unwrap();
    assert!(report.values[0].notes[0].contains("timed out"));
    assert!(start.elapsed() < Duration::from_secs(3));
    collector.sample().unwrap();
    assert_eq!(fs::read_to_string(f.0.join("calls")).unwrap(), "call\n");
}
#[test]
fn command_bounds_output_and_handles_exit_and_spawn_errors() {
    let f = Fixture::new();
    let mut command = BoundedCommand::default();
    let flood = f.program(
        "flood",
        "while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; done",
    );
    assert!(
        command
            .output(&flood, &[], Duration::from_secs(1), 100)
            .unwrap_err()
            .contains("output limit")
    );
    let exit = f.program("exit", "exit 7");
    assert!(
        command
            .output(&exit, &[], Duration::from_secs(1), 100)
            .unwrap_err()
            .contains("exited")
    );
    assert!(
        command
            .output(
                Path::new("/does-not-exist/xrg-smi"),
                &[],
                Duration::from_secs(1),
                100
            )
            .unwrap_err()
            .contains("Cannot start")
    );
}
#[test]
fn descendant_held_pipe_does_not_escape_the_timeout() {
    let f = Fixture::new();
    let marker = f.0.join("escaped");
    let program = f.program(
        "descendant",
        &format!("(sleep 0.3; touch '{}') &\nexit 0", marker.display()),
    );
    let mut command = BoundedCommand::default();
    let start = Instant::now();
    let error = command
        .output(&program, &[], Duration::from_millis(80), 100)
        .unwrap_err();
    assert!(
        error.contains("timed out"),
        "Unexpected query error: {error}"
    );
    assert!(start.elapsed() < Duration::from_secs(2));
    std::thread::sleep(Duration::from_millis(400));
    assert!(!marker.exists());
}
#[test]
fn gpu_histories_follow_pci_identity_across_card_renumbering() {
    let f = Fixture::new();
    f.core();
    f.gpu("card0", "0000:03:00.0", "0x1002", "amdgpu");
    let busy = "bus/pci/devices/0000:03:00.0/gpu_busy_percent";
    f.put(busy, "20");
    let mut sampler = Sampler::with_sources(LinuxSources::with_roots(f.0.join("proc"), &f.0));
    assert_eq!(
        sampler
            .sample()
            .panels
            .iter()
            .find(|p| p.title == "GPU")
            .unwrap()
            .series[0]
            .last(),
        Some(&20.)
    );
    fs::rename(f.0.join("class/drm/card0"), f.0.join("class/drm/card2")).unwrap();
    f.put(busy, "40");
    let next = sampler.sample();
    let gpu = next.panels.iter().find(|p| p.title == "GPU").unwrap();
    assert_eq!(&gpu.series[0][118..], [20., 40.]);
    assert!(gpu.label.contains("card2"));
    f.put(busy, "invalid");
    assert!(
        sampler
            .sample()
            .panels
            .iter()
            .find(|p| p.title == "GPU")
            .unwrap()
            .series
            .is_empty()
    );
    f.put(busy, "0");
    let next = sampler.sample();
    assert_eq!(
        &next
            .panels
            .iter()
            .find(|p| p.title == "GPU")
            .unwrap()
            .series[0][118..],
        [40., 0.]
    );
    fs::remove_dir_all(f.0.join("class/drm/card2")).unwrap();
    let next = sampler.sample();
    assert!(
        next.panels
            .iter()
            .find(|p| p.title == "GPU")
            .unwrap()
            .series
            .is_empty()
    );
    assert_eq!(
        next.panels.iter().find(|p| p.title == "GPU").unwrap().label,
        "No GPU detected"
    );
}

#[test]
fn gpu_selection_keeps_full_inventory_but_plots_only_the_chosen_adapter() {
    use xrg_ng_linux::settings::MetricSelection;
    let f = Fixture::new();
    f.core();
    for (card, pci, value) in [
        ("card0", "0000:03:00.0", "10"),
        ("card1", "0000:04:00.0", "70"),
    ] {
        f.gpu(card, pci, "0x1002", "amdgpu");
        f.put(&format!("bus/pci/devices/{pci}/gpu_busy_percent"), value);
        f.put(
            &format!("bus/pci/devices/{pci}/mem_info_vram_used"),
            if card == "card1" { "300" } else { "40" },
        );
        f.put(&format!("bus/pci/devices/{pci}/mem_info_vram_total"), "400");
    }
    let report = f.collector().sample().unwrap();
    let selected = report
        .values
        .iter()
        .find(|g| g.label == "card1")
        .unwrap()
        .id
        .clone();
    let mut sampler = Sampler::with_sources(LinuxSources::with_roots(f.0.join("proc"), &f.0));
    sampler
        .set_selection(MetricSelection {
            gpu: Some(selected.clone()),
            ..Default::default()
        })
        .unwrap();
    let snapshot = sampler.sample();
    let gpu = snapshot.panels.iter().find(|p| p.title == "GPU").unwrap();
    assert_eq!(snapshot.inventory.gpus.len(), 2);
    assert_eq!(gpu.series.len(), 1);
    assert_eq!(gpu.series[0].last(), Some(&70.));
    assert!(gpu.detail.contains("card1"));
    assert!(!gpu.detail.contains("card0"));
    let vram = &snapshot.panels[10];
    assert_eq!(vram.series.len(), 1);
    assert_eq!(vram.series[0].last(), Some(&75.));
    assert!(vram.detail.contains("card1"));
    assert!(!vram.detail.contains("card0"));
    sampler
        .set_selection(MetricSelection {
            gpu: Some("missing-adapter".into()),
            ..Default::default()
        })
        .unwrap();
    let snapshot = sampler.sample();
    let gpu = snapshot.panels.iter().find(|p| p.title == "GPU").unwrap();
    assert!(gpu.series.is_empty());
    assert_eq!(gpu.label, "Selected GPU unavailable");
    assert!(snapshot.panels[10].series.is_empty());
    assert!(
        snapshot.panels[10]
            .detail
            .contains("Selected GPU unavailable")
    );
    assert_eq!(snapshot.selection.gpu.as_deref(), Some("missing-adapter"));
}
#[test]
fn rejected_selection_does_not_mutate_existing_gpu_history() {
    use xrg_ng_linux::settings::MetricSelection;
    let f = Fixture::new();
    f.core();
    f.gpu("card0", "0000:03:00.0", "0x1002", "amdgpu");
    let busy = "bus/pci/devices/0000:03:00.0/gpu_busy_percent";
    f.put(busy, "10");
    let mut sampler = Sampler::with_sources(LinuxSources::with_roots(f.0.join("proc"), &f.0));
    sampler.sample();
    f.put(busy, "20");
    sampler.sample();
    assert!(
        sampler
            .set_selection(MetricSelection {
                cpu: Some(u32::MAX),
                gpu: Some("other".into()),
                ..Default::default()
            })
            .is_err()
    );
    f.put(busy, "30");
    let snapshot = sampler.sample();
    let gpu = snapshot.panels.iter().find(|p| p.title == "GPU").unwrap();
    assert_eq!(&gpu.series[0][117..], [10., 20., 30.]);
    assert_eq!(snapshot.selection, MetricSelection::default());
}

#[cfg(target_os = "linux")]
#[test]
fn executable_writer_reports_busy_and_runs_only_after_the_writer_is_closed() {
    let f = Fixture::new();
    let program = f.program("writer-held", "printf ready");
    let writer = fs::OpenOptions::new().write(true).open(&program).unwrap();
    let mut command = BoundedCommand::default();
    let error = command
        .output(&program, &[], Duration::from_secs(1), 100)
        .unwrap_err();
    assert!(
        error.contains("Cannot start query") && error.contains("os error 26"),
        "{error}"
    );
    drop(writer);
    assert_eq!(
        command
            .output(&program, &[], Duration::from_secs(1), 100)
            .unwrap(),
        b"ready"
    );
}
