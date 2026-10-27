// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    os::unix::fs::symlink,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::SystemTime,
};
use xrg_ng_linux::{
    collectors::LinuxSources,
    engine::{Sampler, Scale},
    tpu::{self, Collector, Family},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-npu-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn put(&self, path: impl AsRef<Path>, text: impl AsRef<[u8]>) {
        let path = self.0.join(path);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, text).unwrap();
    }
    fn link(&self, target: impl AsRef<Path>, alias: impl AsRef<Path>) {
        let path = self.0.join(alias);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        symlink(self.0.join(target), path).unwrap();
    }
    fn bind(&self, path: &str, driver: &str) {
        fs::create_dir_all(self.0.join(format!("drivers/{driver}"))).unwrap();
        self.link(format!("drivers/{driver}"), format!("{path}/driver"));
    }
    fn pci(&self, name: &str, vendor: &str, id: &str, driver: Option<&str>) -> String {
        let path = format!("devices/{name}");
        self.put(format!("{path}/vendor"), vendor);
        self.put(format!("{path}/device"), id);
        self.link(&path, format!("bus/pci/devices/{name}"));
        if let Some(driver) = driver {
            self.bind(&path, driver)
        }
        path
    }
    fn platform(&self, name: &str, compatible: &str, driver: Option<&str>) -> String {
        let path = format!("devices/platform/{name}");
        self.put(format!("{path}/of_node/compatible"), compatible);
        self.link(&path, format!("bus/platform/devices/{name}"));
        if let Some(driver) = driver {
            self.bind(&path, driver)
        }
        path
    }
    fn core(&self) {
        self.put("proc/stat", "cpu 100 0 50 800 50 0 0 0");
        self.put("proc/meminfo", "MemTotal: 1000 kB\nMemAvailable: 600 kB");
        self.put(
            "proc/net/dev",
            "header\nheader\nlo: 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n",
        );
        self.put("proc/diskstats", "");
    }
    fn sample(&self, c: &mut Collector, time: f64) -> Vec<tpu::Device> {
        c.sample_at(time, SystemTime::now()).devices.unwrap().values
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

#[test]
fn pci_inventory_includes_integrated_intel_amd_and_qualcomm_without_guessing_from_vendor() {
    let f = Fixture::new();
    for (index, id) in ["7d1d", "ad1d", "643e", "b03e", "fd3e", "d71d"]
        .iter()
        .enumerate()
    {
        f.pci(&format!("0000:00:{index:02x}.0"), "0x8086", id, None);
    }
    for (index, id) in ["1502", "17f0", "17f2", "17f3", "1b0b", "1b0c"]
        .iter()
        .enumerate()
    {
        f.pci(
            &format!("0000:01:{index:02x}.0"),
            "0x1022",
            id,
            Some("amdxdna"),
        );
    }
    f.pci("0000:02:00.0", "0x17cb", "0xa100", Some("qaic"));
    f.pci("0000:03:00.0", "0x8086", "0x1234", None);
    f.pci("0000:04:00.0", "0x1002", "0x17f0", None);
    let r = tpu::discover(&f.0).unwrap();
    assert!(r.errors.is_empty(), "{:?}", r.errors);
    assert_eq!(r.values.len(), 13);
    assert_eq!(
        r.values
            .iter()
            .filter(|d| d.family == Family::Intel)
            .count(),
        6
    );
    assert!(
        r.values
            .iter()
            .filter(|d| d.family == Family::Intel)
            .all(|d| !d.initialized)
    );
    assert!(r.values.iter().all(|d| d.utilization.is_none()));
}

#[test]
fn class_aliases_deduplicate_and_intel_busy_time_preserves_zero_and_optional_memory_clock() {
    let f = Fixture::new();
    let path = f.pci("0000:00:0b.0", "0x8086", "0x7d1d", Some("intel_vpu"));
    f.link(&path, "class/accel/accel0/device");
    f.put(format!("{path}/npu_busy_time_us"), "100000");
    f.put(format!("{path}/npu_current_frequency_mhz"), "0");
    f.put(
        format!("{path}/npu_memory_utilization"),
        "18446744073709551615",
    );
    let mut c = Collector::new(f.0.clone(), None);
    let first = f.sample(&mut c, 1.);
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].frequency_mhz, Some(0.));
    assert_eq!(first[0].memory_bytes, Some(u64::MAX));
    assert_eq!(first[0].utilization, None);
    f.put(format!("{path}/npu_busy_time_us"), "600000");
    assert_eq!(f.sample(&mut c, 2.)[0].utilization, Some(50.));
    assert_eq!(f.sample(&mut c, 3.)[0].utilization, Some(0.));
    assert_eq!(
        fs::read_to_string(f.0.join(format!("{path}/npu_busy_time_us"))).unwrap(),
        "600000"
    );
}

#[test]
fn busy_counter_resets_failures_suspend_hotplug_and_driver_rebind_warm_up_again() {
    let f = Fixture::new();
    let path = f.pci("0000:00:0b.0", "0x8086", "0x7d1d", Some("intel_vpu"));
    let attr = format!("{path}/npu_busy_time_us");
    f.put(&attr, "100");
    let mut c = Collector::new(f.0.clone(), None);
    f.sample(&mut c, 1.);
    f.put(&attr, "0");
    assert_eq!(f.sample(&mut c, 2.)[0].utilization, None);
    f.put(&attr, "500000");
    assert_eq!(f.sample(&mut c, 3.)[0].utilization, Some(50.));
    f.put(&attr, "broken");
    let r = f.sample(&mut c, 4.);
    assert_eq!(r[0].utilization, None);
    assert!(!r[0].notes.is_empty());
    f.put(&attr, "600000");
    assert_eq!(f.sample(&mut c, 5.)[0].utilization, None);
    f.put(format!("{path}/power/runtime_status"), "suspended");
    f.put(&attr, "broken");
    let r = f.sample(&mut c, 6.);
    assert!(r[0].suspended);
    assert_eq!(r[0].busy_time_us, None);
    f.put(format!("{path}/power/runtime_status"), "active");
    f.put(&attr, "900000");
    assert_eq!(f.sample(&mut c, 7.)[0].utilization, None);
    fs::rename(
        f.0.join(format!("{path}/driver")),
        f.0.join(format!("{path}/old_driver")),
    )
    .unwrap();
    f.bind(&path, "intel_vpu");
    f.put(&attr, "950000");
    assert_eq!(f.sample(&mut c, 8.)[0].utilization, None);
    fs::remove_file(f.0.join("bus/pci/devices/0000:00:0b.0")).unwrap();
    assert!(f.sample(&mut c, 9.).is_empty());
    f.link(&path, "bus/pci/devices/0000:00:0b.0");
    assert_eq!(f.sample(&mut c, 10.)[0].utilization, None);
}

#[test]
fn impossible_busy_deltas_invalid_times_and_equal_timestamps_never_invent_activity() {
    let f = Fixture::new();
    let path = f.pci("0000:00:0b.0", "0x8086", "0x7d1d", Some("intel_vpu"));
    let attr = format!("{path}/npu_busy_time_us");
    f.put(&attr, "18446744073708551615");
    let mut c = Collector::new(f.0.clone(), None);
    f.sample(&mut c, 1.);
    f.put(&attr, "18446744073709051615");
    assert_eq!(f.sample(&mut c, 1.)[0].utilization, None);
    assert_eq!(f.sample(&mut c, 2.)[0].utilization, Some(50.));
    f.put(&attr, "18446744073709551615");
    assert_eq!(f.sample(&mut c, 2.000001)[0].utilization, None);
    assert_eq!(f.sample(&mut c, f64::NAN)[0].utilization, None);
    assert_eq!(f.sample(&mut c, 3.)[0].utilization, None);
    f.put(&attr, "0");
    f.sample(&mut c, 4.);
    f.put(&attr, "1010000");
    assert_eq!(f.sample(&mut c, 5.)[0].utilization, Some(100.));
    f.put(&attr, "2040000");
    assert_eq!(f.sample(&mut c, 6.)[0].utilization, None);
}

#[test]
fn platform_inventory_covers_arm_vendors_and_rejects_audio_modem_gpu_and_clock_nodes() {
    let f = Fixture::new();
    for (name, compatible, driver) in [
        ("ane", "apple,t8103-ane\0", Some("ane")),
        ("rknpu", "rockchip,rk3588-rknpu\0", Some("rknpu")),
        ("rknn", "rockchip,rk3588-rknn-core\0", Some("rocket")),
        ("cdsp", "qcom,x1e80100-cdsp-pas\0", Some("qcom_q6v5_pas")),
        ("ethos", "arm,ethos-u85\0", Some("ethosu")),
        ("dla", "nvidia,tegra194-nvdla\0", Some("nvdla")),
        ("exynos", "samsung,exynos-npu\0", None),
        ("apu", "mediatek,mt8195-apu\0", None),
        ("adsp", "qcom,x1e80100-adsp-pas\0", Some("qcom_q6v5_pas")),
        ("modem", "qcom,sm8550-mpss-pas\0", None),
        ("gpu", "apple,t8103-gpu\0", None),
        ("clock", "rockchip,rk3588-npu-cru\0", None),
        ("fastrpc", "qcom,fastrpc\0", None),
        ("iommu-apu", "mediatek,mt8195-iommu-apu\0", None),
    ] {
        f.platform(name, compatible, driver);
    }
    let r = tpu::discover(&f.0).unwrap();
    assert!(r.errors.is_empty(), "{:?}", r.errors);
    assert_eq!(r.values.len(), 8);
    for family in [
        Family::Apple,
        Family::Rockchip,
        Family::Qualcomm,
        Family::ArmEthos,
        Family::NvidiaDla,
        Family::Samsung,
        Family::MediaTek,
    ] {
        assert!(r.values.iter().any(|d| d.family == family));
    }
    assert!(r.values.iter().all(|d| d.utilization.is_none()));
}

#[test]
fn apple_machine_capability_is_explicitly_unverified_and_not_duplicated_by_bound_ane() {
    let f = Fixture::new();
    f.put(
        "firmware/devicetree/base/compatible",
        "apple,j313\0apple,t8103\0apple,arm-platform\0",
    );
    let r = tpu::discover(&f.0).unwrap();
    assert_eq!(r.values.len(), 1);
    assert!(r.values[0].capability_only);
    assert!(!r.values[0].initialized);
    assert_eq!(r.values[0].utilization, None);
    f.platform("ane", "apple,t8103-ane\0", Some("ane"));
    let r = tpu::discover(&f.0).unwrap();
    assert_eq!(r.values.len(), 1);
    assert!(!r.values[0].capability_only);
    assert!(r.values[0].initialized);
    let g = Fixture::new();
    g.put(
        "firmware/devicetree/base/compatible",
        "apple,unknown\0qcom,unknown\0",
    );
    assert!(tpu::discover(&g.0).unwrap().values.is_empty());
}

#[test]
fn known_rockchip_and_snapdragon_machine_ids_are_capabilities_without_device_endpoints() {
    for (compatible, family) in [
        ("rockchip,rk3588\0", Family::Rockchip),
        ("qcom,x1e80100\0", Family::Qualcomm),
    ] {
        let f = Fixture::new();
        f.put("firmware/devicetree/base/compatible", compatible);
        let report = tpu::discover(&f.0).unwrap();
        assert_eq!(report.values.len(), 1);
        let device = &report.values[0];
        assert_eq!(device.family, family);
        assert!(device.capability_only);
        assert!(!device.initialized);
        assert_eq!(device.utilization, None);
    }
}

#[test]
fn special_or_oversized_optional_attributes_keep_inventory_without_blocking() {
    let f = Fixture::new();
    let path = f.pci("0000:00:0b.0", "0x8086", "0x7d1d", Some("intel_vpu"));
    let attr = f.0.join(format!("{path}/npu_busy_time_us"));
    let name = std::ffi::CString::new(attr.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let mut c = Collector::new(f.0.clone(), None);
    let devices = f.sample(&mut c, 1.);
    assert_eq!(devices.len(), 1);
    assert!(devices[0].busy_time_us.is_none());
    assert!(!devices[0].notes.is_empty());
    fs::remove_file(&attr).unwrap();
    f.put(format!("{path}/npu_busy_time_us"), vec![b'1'; 4097]);
    let devices = f.sample(&mut c, 2.);
    assert_eq!(devices.len(), 1);
    assert!(devices[0].utilization.is_none());
}

#[test]
fn excessive_discovery_is_partial_and_does_not_build_unbounded_inventory() {
    let f = Fixture::new();
    for index in 0..270 {
        f.platform(&format!("npu{index:03}"), "arm,ethos-u85\0", Some("ethosu"));
    }
    let report = tpu::discover(&f.0).unwrap();
    assert!(report.values.len() <= 256);
    assert!(!report.errors.is_empty());
}

#[test]
fn qualcomm_compute_dsp_states_are_inventory_not_utilization_or_inference_readiness() {
    let f = Fixture::new();
    let path = f.platform("cdsp", "qcom,sc8280xp-nsp0-pas\0", Some("qcom_q6v5_pas"));
    f.put(format!("{path}/remoteproc/remoteproc3/state"), "offline");
    let r = tpu::discover(&f.0).unwrap();
    assert_eq!(r.values.len(), 1);
    assert!(r.values[0].notes.iter().any(|n| n.contains("offline")));
    assert_eq!(r.values[0].utilization, None);
    f.put(format!("{path}/of_node/status"), "disabled\0");
    let r = tpu::discover(&f.0).unwrap();
    assert!(!r.values[0].initialized);
}

#[test]
fn rockchip_driver_load_parser_validates_cores_percent_and_zero_rendered_as_spaces() {
    for (s, v) in [
        ("NPU load: 50%", 50.),
        ("NPU load:  %", 0.),
        ("NPU load: Core0: 0%, Core1: 50%, Core2: 100%,\n", 50.),
        ("NPU load: Core0:  %, Core1:  %", 0.),
    ] {
        assert_eq!(tpu::parse_rockchip_load(s).unwrap(), v);
    }
    for s in [
        "50%",
        "NPU load:",
        "NPU load: 101%",
        "NPU load: -1%",
        "NPU load: +1%",
        "NPU load: 50MHz",
        "NPU load: Core1: 50%",
        "NPU load: Core0: 5%, Core0: 10%",
        "NPU load: 0%, 50%",
        "NPU load: Core0: nan%",
        "NPU load: 5%, garbage",
    ] {
        assert!(tpu::parse_rockchip_load(s).is_err(), "{s}");
    }
}

#[test]
fn rockchip_global_load_is_not_assigned_to_multiple_devices_or_suspended_hardware() {
    let f = Fixture::new();
    let path = f.platform("npu", "rockchip,rk3588-rknpu\0", Some("rknpu"));
    f.put(
        "kernel/debug/rknpu/load",
        "NPU load: Core0: 0%, Core1: 50%, Core2: 100%,",
    );
    assert_eq!(
        tpu::discover(&f.0).unwrap().values[0].utilization,
        Some(50.)
    );
    f.put(format!("{path}/power/runtime_status"), "suspended");
    assert_eq!(tpu::discover(&f.0).unwrap().values[0].utilization, None);
    f.put(format!("{path}/power/runtime_status"), "active");
    f.platform("npu2", "rockchip,rk3568-rknpu\0", Some("rknpu"));
    assert!(
        tpu::discover(&f.0)
            .unwrap()
            .values
            .iter()
            .all(|d| d.utilization.is_none())
    );
}

#[test]
fn graph_switches_between_measured_percent_and_unscoped_rate_without_mixing_histories() {
    let f = Fixture::new();
    f.core();
    f.platform("npu", "rockchip,rk3588-rknpu\0", Some("rknpu"));
    f.put("kernel/debug/rknpu/load", "NPU load: 50%");
    f.put("stats.json", r#"{"total_inferences":5}"#);
    let mut s = Sampler::with_sources(
        LinuxSources::with_roots(f.0.join("proc"), &f.0).with_tpu_stats(f.0.join("stats.json")),
    );
    let first = s.sample();
    let p = &first.panels[9];
    assert_eq!(p.title, "TPU / NPU");
    assert_eq!(p.scale, Scale::Percent);
    assert_eq!(p.series[0].last(), Some(&50.));
    f.put("kernel/debug/rknpu/load", "NPU load: 0%");
    f.put("stats.json", r#"{"total_inferences":6}"#);
    let next = s.sample();
    let p = &next.panels[9];
    assert_eq!(p.scale, Scale::Percent);
    assert_eq!(p.series.len(), 1);
    assert_eq!(p.series[0].last(), Some(&0.));
    assert!(p.detail.contains("Unscoped producer rate:"));
    fs::remove_file(f.0.join("kernel/debug/rknpu/load")).unwrap();
    let next = s.sample();
    assert_eq!(next.panels[9].scale, Scale::Automatic);
    f.put("kernel/debug/rknpu/load", "NPU load: 10%");
    let next = s.sample();
    let p = &next.panels[9];
    assert_eq!(p.scale, Scale::Percent);
    assert_eq!(p.series[0].last(), Some(&10.));
    assert!(!p.series[0].contains(&50.));
}
