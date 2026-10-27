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
use xrg_ng_linux::gpu::GpuCollector;
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-arm-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        fs::create_dir(path.join("proc")).unwrap();
        Self(path)
    }
    fn put(&self, file: &str, contents: &str) {
        let path = self.0.join(file);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
    }
    fn link(&self, target: impl Into<PathBuf>, path: &str) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        symlink(target.into(), path).unwrap();
    }
    fn platform(&self, name: &str, driver: &str, node: Option<&str>) {
        let path = self.0.join(format!("devices/platform/{name}"));
        fs::create_dir_all(&path).unwrap();
        let binding = self.0.join(format!("bus/platform/drivers/{driver}"));
        fs::create_dir_all(&binding).unwrap();
        self.link(&binding, &format!("devices/platform/{name}/driver"));
        self.link(&path, &format!("bus/platform/drivers/{driver}/{name}"));
        if let Some(node) = node {
            self.link(&path, &format!("class/drm/{node}/device"));
        }
    }
    fn client(&self, pid: u32, fd: u32, node: &str, driver: &str, id: u64, counters: &str) {
        self.put(
            &format!("proc/{pid}/fdinfo/{fd}"),
            &format!("drm-driver: {driver}\ndrm-client-id: {id}\n{counters}"),
        );
        let target = self.0.join(format!("proc/{pid}/fd/{fd}"));
        if target.symlink_metadata().is_ok() {
            fs::remove_file(target).unwrap();
        }
        self.link(format!("/dev/dri/{node}"), &format!("proc/{pid}/fd/{fd}"));
    }
    fn collect(&self) -> GpuCollector {
        GpuCollector::new(&self.0, None).with_proc_root(self.0.join("proc"))
    }
    fn profiling(&self, name: &str, mask: &str) {
        self.put(&format!("devices/platform/{name}/profiling"), mask);
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn non_pci_platform_and_render_only_families_are_discovered() {
    for (driver, name) in [
        ("panfrost", "Mali"),
        ("panthor", "Mali"),
        ("lima", "Mali"),
        ("mali", "Mali"),
        ("adreno", "Adreno"),
        ("asahi", "Apple AGX"),
        ("v3d", "V3D"),
        ("etnaviv", "Vivante"),
        ("powervr", "PowerVR"),
    ] {
        let f = Fixture::new();
        f.platform("gpu0", driver, Some("renderD128"));
        let report = f.collect().sample().unwrap();
        assert_eq!(report.values.len(), 1, "{driver}");
        assert!(report.values[0].name.contains(name));
        assert_eq!(report.values[0].label, "renderD128");
        assert!(report.values[0].id.ends_with("devices/platform/gpu0"));
        assert_eq!(report.values[0].utilization, None);
    }
}
#[test]
fn platform_only_gpu_uses_owned_devfreq_and_device_tree_name() {
    let f = Fixture::new();
    f.platform("fb000000.gpu", "panfrost", None);
    f.put(
        "devices/platform/fb000000.gpu/of_node/compatible",
        "arm,mali-t860\0arm,mali-midgard\0",
    );
    f.put(
        "devices/platform/fb000000.gpu/devfreq/fb000000.gpu/cur_freq",
        "600000000",
    );
    let gpu = f.collect().sample().unwrap().values.remove(0);
    assert_eq!(gpu.frequency_mhz, Some(600.));
    assert!(gpu.name.contains("arm,mali-t860"));
    assert_eq!(gpu.client_activity, None);
    assert_eq!(gpu.memory_total, None);
}
#[test]
fn global_devfreq_must_belong_to_the_gpu() {
    let f = Fixture::new();
    f.platform("gpu0", "asahi", Some("renderD128"));
    f.put("class/devfreq/cpu-gpu-looking-name/cur_freq", "999000000");
    f.link(
        f.0.join("devices/platform/cpu"),
        "class/devfreq/cpu-gpu-looking-name/device",
    );
    assert_eq!(f.collect().sample().unwrap().values[0].frequency_mhz, None);
    f.put("class/devfreq/gpu-clock/cur_freq", "450000000");
    f.link(
        f.0.join("devices/platform/gpu0"),
        "class/devfreq/gpu-clock/device",
    );
    assert_eq!(
        f.collect().sample().unwrap().values[0].frequency_mhz,
        Some(450.)
    );
}
#[test]
fn platform_and_multiple_drm_aliases_deduplicate() {
    let f = Fixture::new();
    f.platform("gpu0", "panfrost", Some("card0"));
    f.link(
        f.0.join("devices/platform/gpu0"),
        "class/drm/renderD128/device",
    );
    f.link(
        f.0.join("devices/platform/gpu0"),
        "class/drm/card0-HDMI-A-1/device",
    );
    let report = f.collect().sample().unwrap();
    assert_eq!(report.values.len(), 1);
    assert_eq!(report.values[0].label, "card0");
}
#[test]
fn readable_clients_are_deduplicated_across_processes_and_fds() {
    let f = Fixture::new();
    f.platform("gpu0", "panfrost", Some("card0"));
    f.link(
        f.0.join("devices/platform/gpu0"),
        "class/drm/renderD128/device",
    );
    f.profiling("gpu0", "1");
    let mut collector = f.collect();
    let now = Instant::now();
    for (pid, fd, node) in [(100, 3, "card0"), (101, 5, "renderD128")] {
        f.client(
            pid,
            fd,
            node,
            "panfrost",
            7,
            "drm-engine-fragment: 100000000 ns\ndrm-resident-memory: 16 MiB\n",
        );
    }
    assert_eq!(
        collector.sample_at(now).unwrap().values[0].client_activity,
        None
    );
    for (pid, fd, node) in [(100, 3, "card0"), (101, 5, "renderD128")] {
        f.client(
            pid,
            fd,
            node,
            "panfrost",
            7,
            "drm-engine-fragment: 600000000 ns\ndrm-resident-memory: 16 MiB\n",
        );
    }
    let gpu = collector
        .sample_at(now + Duration::from_secs(1))
        .unwrap()
        .values
        .remove(0);
    assert_eq!(gpu.client_activity, Some(50.));
    assert_eq!(gpu.visible_clients, Some(1));
    assert_eq!(gpu.client_resident_bytes, Some(16 * 1048576));
    assert_eq!(gpu.memory_used, None);
    assert_eq!(gpu.memory_total, None);
    assert_eq!(gpu.utilization, None);
}
#[test]
fn busiest_engine_normalizes_capacity_without_summing_overlapping_engines() {
    let f = Fixture::new();
    f.platform("gpu0", "panfrost", Some("renderD128"));
    f.profiling("gpu0", "1");
    let mut collector = f.collect();
    let now = Instant::now();
    for id in [1, 2] {
        f.client(100, id as u32, "renderD128", "panfrost", id,
        "drm-engine-fragment: 0 ns\ndrm-engine-capacity-fragment: 2\ndrm-engine-vertex-tiler: 0 ns\ndrm-resident-memory: 4096 KiB\n");
    }
    collector.sample_at(now).unwrap();
    f.client(100, 1, "renderD128", "panfrost", 1, "drm-engine-fragment: 400000000 ns\ndrm-engine-capacity-fragment: 2\ndrm-engine-vertex-tiler: 800000000 ns\ndrm-resident-memory: 4096 KiB\n");
    f.client(100, 2, "renderD128", "panfrost", 2, "drm-engine-fragment: 200000000 ns\ndrm-engine-capacity-fragment: 2\ndrm-engine-vertex-tiler: 0 ns\ndrm-resident-memory: 4096 KiB\n");
    let gpu = collector
        .sample_at(now + Duration::from_secs(1))
        .unwrap()
        .values
        .remove(0);
    assert_eq!(gpu.client_activity, Some(80.));
    assert_eq!(gpu.client_resident_bytes, Some(8 * 1048576));
}
#[test]
fn disabled_panfrost_profiling_does_not_publish_false_idle_or_change_settings() {
    let f = Fixture::new();
    f.platform("gpu0", "panfrost", Some("renderD128"));
    f.profiling("gpu0", "0");
    f.client(
        100,
        3,
        "renderD128",
        "panfrost",
        1,
        "drm-engine-fragment: 0 ns\ndrm-resident-memory: 1 MiB\n",
    );
    let mut collector = f.collect();
    let now = Instant::now();
    collector.sample_at(now).unwrap();
    let gpu = collector
        .sample_at(now + Duration::from_secs(1))
        .unwrap()
        .values
        .remove(0);
    assert_eq!(gpu.client_activity, None);
    assert_eq!(gpu.client_resident_bytes, Some(1048576));
    assert!(gpu.notes.iter().any(|n| n.contains("profiling disabled")));
    assert_eq!(
        fs::read_to_string(f.0.join("devices/platform/gpu0/profiling")).unwrap(),
        "0"
    );
}
#[test]
fn panthor_requires_timestamp_profiling_bit_and_warms_up_after_enable() {
    let f = Fixture::new();
    f.platform("gpu0", "panthor", Some("renderD128"));
    f.profiling("gpu0", "1");
    f.client(
        100,
        3,
        "renderD128",
        "panthor",
        1,
        "drm-engine-panthor: 0 ns\n",
    );
    let mut collector = f.collect();
    let now = Instant::now();
    collector.sample_at(now).unwrap();
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(1))
            .unwrap()
            .values[0]
            .client_activity,
        None
    );
    f.profiling("gpu0", "2");
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(2))
            .unwrap()
            .values[0]
            .client_activity,
        None
    );
    f.client(
        100,
        3,
        "renderD128",
        "panthor",
        1,
        "drm-engine-panthor: 400000000 ns\n",
    );
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(3))
            .unwrap()
            .values[0]
            .client_activity,
        Some(40.)
    );
}
#[test]
fn same_driver_multiple_gpus_never_share_client_counters() {
    let f = Fixture::new();
    for (name, node) in [("gpu0", "renderD128"), ("gpu1", "renderD129")] {
        f.platform(name, "panfrost", Some(node));
        f.profiling(name, "1");
    }
    let mut collector = f.collect();
    let now = Instant::now();
    for (fd, node) in [(3, "renderD128"), (4, "renderD129")] {
        f.client(100, fd, node, "panfrost", 1, "drm-engine-fragment: 0 ns\n");
    }
    collector.sample_at(now).unwrap();
    f.client(
        100,
        3,
        "renderD128",
        "panfrost",
        1,
        "drm-engine-fragment: 250000000 ns\n",
    );
    f.client(
        100,
        4,
        "renderD129",
        "panfrost",
        1,
        "drm-engine-fragment: 750000000 ns\n",
    );
    let report = collector.sample_at(now + Duration::from_secs(1)).unwrap();
    assert_eq!(report.values[0].client_activity, Some(25.));
    assert_eq!(report.values[1].client_activity, Some(75.));
}
#[test]
fn counter_regression_keeps_the_larger_baseline_until_catchup() {
    let f = Fixture::new();
    f.platform("gpu0", "v3d", Some("renderD128"));
    let mut collector = f.collect();
    let now = Instant::now();
    f.client(
        100,
        3,
        "renderD128",
        "v3d",
        1,
        "drm-engine-render: 100000000 ns\n",
    );
    collector.sample_at(now).unwrap();
    f.client(
        100,
        3,
        "renderD128",
        "v3d",
        1,
        "drm-engine-render: 90000000 ns\n",
    );
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(1))
            .unwrap()
            .values[0]
            .client_activity,
        None
    );
    f.client(
        100,
        3,
        "renderD128",
        "v3d",
        1,
        "drm-engine-render: 300000000 ns\n",
    );
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(2))
            .unwrap()
            .values[0]
            .client_activity,
        Some(10.)
    );
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(3))
            .unwrap()
            .values[0]
            .client_activity,
        Some(0.)
    );
}
#[test]
fn removed_clients_need_a_new_interval_even_if_the_id_is_reused() {
    let f = Fixture::new();
    f.platform("gpu0", "v3d", Some("renderD128"));
    let now = Instant::now();
    f.client(
        100,
        3,
        "renderD128",
        "v3d",
        1,
        "drm-engine-render: 100000000 ns\n",
    );
    let mut collector = f.collect();
    collector.sample_at(now).unwrap();
    fs::remove_dir_all(f.0.join("proc/100")).unwrap();
    collector.sample_at(now + Duration::from_secs(1)).unwrap();
    f.client(
        100,
        3,
        "renderD128",
        "v3d",
        1,
        "drm-engine-render: 900000000 ns\n",
    );
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(2))
            .unwrap()
            .values[0]
            .client_activity,
        None
    );
}
#[test]
fn invalid_fdinfo_units_identity_capacity_and_overflow_are_not_samples() {
    for record in [
        "drm-engine-render: 1 ms\n",
        "drm-engine-render: 1 ns\ndrm-engine-capacity-render: 0\n",
        "drm-resident-memory: 18446744073709551615 MiB\n",
        "drm-client-id: 2\ndrm-engine-render: 0 ns\n",
    ] {
        let f = Fixture::new();
        f.platform("gpu0", "v3d", Some("renderD128"));
        f.client(100, 3, "renderD128", "v3d", 1, record);
        let gpu = f.collect().sample().unwrap().values.remove(0);
        assert_eq!(gpu.client_activity, None);
        assert_eq!(gpu.client_resident_bytes, None);
    }
    let f = Fixture::new();
    f.platform("gpu0", "v3d", Some("renderD128"));
    f.client(
        100,
        3,
        "renderD128",
        "panthor",
        1,
        "drm-engine-render: 0 ns\n",
    );
    assert_eq!(
        f.collect().sample().unwrap().values[0].visible_clients,
        None
    );
}
#[test]
fn apple_is_identified_without_inventing_unexposed_telemetry() {
    let f = Fixture::new();
    f.platform("204000000.gpu", "asahi", Some("renderD128"));
    f.put(
        "devices/platform/204000000.gpu/of_node/compatible",
        "apple,agx-t8103\0",
    );
    f.client(100, 3, "renderD128", "asahi", 1, "");
    let gpu = f.collect().sample().unwrap().values.remove(0);
    assert!(gpu.name.contains("Apple AGX"));
    assert!(gpu.name.contains("apple,agx-t8103"));
    assert_eq!(gpu.utilization, None);
    assert_eq!(gpu.client_activity, None);
    assert_eq!(gpu.frequency_mhz, None);
    assert_eq!(gpu.memory_total, None);
}
#[test]
fn kgsl_class_exposes_real_busy_intervals_and_hz_clock() {
    let f = Fixture::new();
    f.platform("3d00000.gpu", "kgsl-3d0", None);
    f.link(
        f.0.join("devices/platform/3d00000.gpu"),
        "class/kgsl/kgsl-3d0/device",
    );
    f.put("class/kgsl/kgsl-3d0/gpubusy", "200 1000");
    f.put("class/kgsl/kgsl-3d0/gpuclk", "900000000");
    let gpu = f.collect().sample().unwrap().values.remove(0);
    assert_eq!(gpu.utilization, Some(20.));
    assert_eq!(gpu.frequency_mhz, Some(900.));
    f.put("class/kgsl/kgsl-3d0/gpubusy", "0 0");
    assert_eq!(f.collect().sample().unwrap().values[0].utilization, None);
    f.put("class/kgsl/kgsl-3d0/gpubusy", "200 100");
    assert_eq!(f.collect().sample().unwrap().values[0].utilization, None);
}
#[test]
fn adreno_separate_drm_master_and_gpu_bindings_merge_only_unambiguous_pair() {
    let f = Fixture::new();
    f.platform("display-subsystem", "msm_drm", Some("renderD128"));
    f.platform("3d00000.gpu", "adreno", None);
    f.put(
        "devices/platform/3d00000.gpu/devfreq/gpu/cur_freq",
        "700000000",
    );
    f.client(100, 3, "renderD128", "msm", 1, "drm-engine-gpu: 0 ns\n");
    let now = Instant::now();
    let mut collector = f.collect();
    let first = collector.sample_at(now).unwrap();
    assert_eq!(first.values.len(), 1);
    assert!(first.values[0].id.ends_with("3d00000.gpu"));
    assert_eq!(first.values[0].frequency_mhz, Some(700.));
    f.client(
        100,
        3,
        "renderD128",
        "msm",
        1,
        "drm-engine-gpu: 500000000 ns\n",
    );
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(1))
            .unwrap()
            .values[0]
            .client_activity,
        Some(50.)
    );
    fs::remove_dir_all(f.0.join("devices/platform/3d00000.gpu/devfreq")).unwrap();
    f.put(
        "devices/platform/display-subsystem/devfreq/display/cur_freq",
        "999000000",
    );
    assert_eq!(
        collector
            .sample_at(now + Duration::from_secs(2))
            .unwrap()
            .values[0]
            .frequency_mhz,
        None
    );
}
#[test]
fn suspended_arm_gpu_skips_telemetry_and_restarts_client_baselines() {
    let f = Fixture::new();
    f.platform("gpu0", "panfrost", Some("renderD128"));
    f.profiling("gpu0", "1");
    f.put("devices/platform/gpu0/power/runtime_status", "suspended");
    f.put("devices/platform/gpu0/devfreq/gpu/cur_freq", "bad");
    f.client(
        100,
        3,
        "renderD128",
        "panfrost",
        1,
        "drm-engine-fragment: 100000000 ns\n",
    );
    let mut collector = f.collect();
    let gpu = collector.sample().unwrap().values.remove(0);
    assert_eq!(gpu.frequency_mhz, None);
    assert_eq!(gpu.client_activity, None);
    assert_eq!(gpu.notes.len(), 1);
    f.put("devices/platform/gpu0/power/runtime_status", "active");
    f.put("devices/platform/gpu0/devfreq/gpu/cur_freq", "500000000");
    assert_eq!(collector.sample().unwrap().values[0].client_activity, None);
}
#[test]
fn broken_platform_driver_directory_does_not_hide_other_gpus() {
    let f = Fixture::new();
    f.platform("gpu0", "v3d", Some("renderD128"));
    f.put("bus/platform/drivers/panfrost", "not a directory");
    let report = f.collect().sample().unwrap();
    assert_eq!(report.values.len(), 1);
    assert!(!report.errors.is_empty());
}
#[test]
fn resident_memory_sum_overflow_is_unavailable_and_not_vram() {
    let f = Fixture::new();
    f.platform("gpu0", "v3d", Some("renderD128"));
    for id in [1, 2] {
        f.client(
            100,
            id as u32,
            "renderD128",
            "v3d",
            id,
            "drm-resident-memory: 18446744073709551615\n",
        );
    }
    let gpu = f.collect().sample().unwrap().values.remove(0);
    assert_eq!(gpu.client_resident_bytes, None);
    assert_eq!(gpu.memory_used, None);
    assert!(gpu.notes.iter().any(|n| n.contains("overflow")));
}

#[test]
fn drm_current_frequency_units_are_converted_without_load_estimation() {
    for frequency in ["650000000 Hz", "650000 KHz", "650 MHz"] {
        let f = Fixture::new();
        f.platform("gpu0", "v3d", Some("renderD128"));
        f.client(
            100,
            3,
            "renderD128",
            "v3d",
            1,
            &format!("drm-curfreq-render: {frequency}\n"),
        );
        let gpu = f.collect().sample().unwrap().values.remove(0);
        assert_eq!(gpu.frequency_mhz, Some(650.));
        assert_eq!(gpu.client_activity, None);
        assert_eq!(gpu.utilization, None);
    }
}
#[test]
fn gpu_panel_labels_client_scope_and_resets_history_when_counter_scope_changes() {
    use xrg_ng_linux::{collectors::LinuxSources, engine::Sampler};
    let f = Fixture::new();
    f.platform("gpu0", "kgsl-3d0", Some("renderD128"));
    f.put("proc/stat", "cpu 100 0 50 800 50 0 0 0");
    f.put("proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 500 kB");
    f.put("proc/net/dev", "h\nh\nlo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0");
    f.put("proc/diskstats", "8 0 sda 1 0 10 0 1 0 20 0 0 0 0");
    fs::create_dir_all(f.0.join("block/sda")).unwrap();
    f.put("devices/platform/gpu0/gpubusy", "200 1000");
    f.client(
        100,
        3,
        "renderD128",
        "kgsl-3d0",
        1,
        "drm-engine-gpu: 0 ns\ndrm-resident-memory: 1 MiB\n",
    );
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
    sampler.sample();
    fs::remove_file(f.0.join("devices/platform/gpu0/gpubusy")).unwrap();
    let next = sampler.sample();
    let panel = next.panels.iter().find(|p| p.title == "GPU").unwrap();
    assert!(panel.label.contains("clients"));
    assert!(
        panel
            .detail
            .contains("Readable-client busiest-engine activity")
    );
    assert!(panel.detail.contains("resident allocations: 1.0 MiB"));
    assert!(!panel.detail.contains("VRAM"));
    assert!(!panel.series[0].contains(&20.));
}
#[test]
fn delayed_counter_intervals_over_capacity_are_not_clamped_into_false_load() {
    let f = Fixture::new();
    f.platform("gpu0", "v3d", Some("renderD128"));
    let now = Instant::now();
    f.client(100, 3, "renderD128", "v3d", 1, "drm-engine-render: 0 ns\n");
    let mut collector = f.collect();
    collector.sample_at(now).unwrap();
    f.client(
        100,
        3,
        "renderD128",
        "v3d",
        1,
        "drm-engine-render: 2000000000 ns\n",
    );
    let gpu = collector
        .sample_at(now + Duration::from_secs(1))
        .unwrap()
        .values
        .remove(0);
    assert_eq!(gpu.client_activity, None);
    assert!(gpu.notes.iter().any(|n| n.contains("delayed")));
}

#[test]
fn msm_display_master_clock_and_sensor_are_never_gpu_telemetry() {
    let f = Fixture::new();
    f.platform("display-subsystem", "msm_drm", Some("renderD128"));
    f.put(
        "devices/platform/display-subsystem/devfreq/display/cur_freq",
        "999000000",
    );
    f.put(
        "devices/platform/display-subsystem/hwmon/hwmon0/temp1_input",
        "55000",
    );
    let gpu = f.collect().sample().unwrap().values.remove(0);
    assert_eq!(gpu.frequency_mhz, None);
    assert_eq!(gpu.temperature, None);
    assert!(
        gpu.notes
            .iter()
            .any(|n| n.contains("physical GPU telemetry mapping unavailable"))
    );
}

#[test]
fn vendor_mali_devfreq_load_is_measured_activity_not_a_clock_ratio() {
    let f = Fixture::new();
    f.platform("gpu0", "mali", None);
    let path = "devices/platform/gpu0/devfreq/gpu/load";
    for (text, busy) in [
        ("35@800000000Hz", 35.),
        ("0@800000000Hz", 0.),
        ("100@200000000Hz", 100.),
    ] {
        f.put(path, text);
        let gpu = f.collect().sample().unwrap().values.remove(0);
        assert_eq!(gpu.utilization, Some(busy));
        assert!(gpu.frequency_mhz.is_some());
        assert_eq!(gpu.client_activity, None);
    }
}
#[test]
fn vendor_mali_invalid_or_empty_devfreq_load_does_not_invent_idle() {
    let f = Fixture::new();
    f.platform("gpu0", "mali", None);
    for text in [
        "",
        "101@500000000Hz",
        "-1@500000000Hz",
        "25@0Hz",
        "25@500000000MHz",
        "500000000",
        "NaN@500000000Hz",
    ] {
        f.put("devices/platform/gpu0/devfreq/gpu/load", text);
        assert_eq!(
            f.collect().sample().unwrap().values[0].utilization,
            None,
            "{text}"
        );
    }
}
#[test]
fn multiple_devfreq_domains_do_not_guess_gpu_load_from_memory_activity() {
    let f = Fixture::new();
    f.platform("gpu0", "mali", None);
    f.put("devices/platform/gpu0/devfreq/core/load", "25@400000000Hz");
    f.put(
        "devices/platform/gpu0/devfreq/memory/load",
        "90@800000000Hz",
    );
    assert_eq!(f.collect().sample().unwrap().values[0].utilization, None);
}
