// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Read-only NPU discovery. Driver-specific counters are never guessed from a
//! clock, a loaded module, CPU model, memory allocation or firmware availability.
use super::{Device, Family, note};
use crate::hardware::{self, Readings};
#[cfg(unix)]
use std::os::unix::fs::MetadataExt;
use std::{
    collections::BTreeMap,
    fs,
    path::Path,
    time::{Duration, Instant},
};

const BUDGET: Duration = Duration::from_millis(100);
fn driver(path: &Path) -> Result<Option<String>, String> {
    match fs::read_link(path.join("driver")) {
        Ok(link) => Ok(link.file_name().map(|s| s.to_string_lossy().into_owned())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}
fn pci_family(path: &Path) -> Result<Option<Family>, String> {
    let vendor = super::id(path, "vendor")?;
    if !matches!(vendor, Some(0x8086 | 0x1022 | 0x17cb)) {
        return Ok(None);
    }
    let device = super::id(path, "device")?;
    Ok(match (vendor, device) {
        (Some(0x8086), Some(0x7d1d | 0xad1d | 0x643e | 0xb03e | 0xfd3e | 0xd71d)) => {
            Some(Family::Intel)
        }
        (Some(0x1022), Some(0x1502 | 0x17f0 | 0x17f2 | 0x17f3 | 0x1b0b | 0x1b0c)) => {
            Some(Family::Amd)
        }
        (Some(0x17cb), Some(0xa080 | 0xa100 | 0xa110 | 0xa111)) => Some(Family::QualcommCloud),
        _ => None,
    })
}
fn compatible_family(value: &str) -> Option<Family> {
    for compatible in value.split('\0') {
        let Some((vendor, device)) = compatible.split_once(',') else {
            continue;
        };
        let family = match vendor {
            "apple" if device == "ane" || device.ends_with("-ane") => Family::Apple,
            "rockchip"
                if device.ends_with("-rknpu")
                    || device.ends_with("-rknn")
                    || device.ends_with("-rknn-core") =>
            {
                Family::Rockchip
            }
            "qcom"
                if device.ends_with("-cdsp-pas")
                    || device.ends_with("-nsp0-pas")
                    || device.ends_with("-nsp1-pas")
                    || device.ends_with("-npu")
                    || device == "npu" =>
            {
                Family::Qualcomm
            }
            "arm"
                if matches!(
                    device,
                    "ethos-u55" | "ethos-u65" | "ethos-u85" | "ethos-n77" | "ethos-n78" | "ethosn"
                ) =>
            {
                Family::ArmEthos
            }
            "nvidia" if device.ends_with("-nvdla") || device.ends_with("-dla") => Family::NvidiaDla,
            "samsung"
                if device == "exynos-npu"
                    || device
                        .strip_prefix("exynos")
                        .and_then(|s| s.strip_suffix("-npu"))
                        .is_some_and(|s| {
                            !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
                        }) =>
            {
                Family::Samsung
            }
            // Do not count mt8195-iommu-apu, clock or power controller nodes.
            "mediatek"
                if device
                    .strip_prefix("mt")
                    .and_then(|s| s.split_once('-'))
                    .is_some_and(|(soc, block)| {
                        !soc.is_empty()
                            && soc.bytes().all(|b| b.is_ascii_digit())
                            && matches!(block, "apu" | "apusys")
                    }) =>
            {
                Family::MediaTek
            }
            _ => continue,
        };
        return Some(family);
    }
    None
}
fn driver_family(name: &str) -> Option<Family> {
    match name {
        "intel_vpu" | "ivpu" => Some(Family::Intel),
        "amdxdna" => Some(Family::Amd),
        "ane" | "apple-ane" | "ane_t6021" => Some(Family::Apple),
        "rknpu" | "RKNPU" | "rocket" => Some(Family::Rockchip),
        "msm_npu" | "qcom-npu" => Some(Family::Qualcomm),
        "qaic" => Some(Family::QualcommCloud),
        "ethosu" | "ethos-n" | "ethosn" => Some(Family::ArmEthos),
        "nvdla" | "tegra-dla" => Some(Family::NvidiaDla),
        _ => None,
    }
}
fn unsigned(path: &Path) -> Result<Option<u64>, String> {
    hardware::text(path)?
        .map(|s| {
            s.parse()
                .map_err(|_| format!("{}: invalid unsigned counter", path.display()))
        })
        .transpose()
}
fn optional<T>(device: &mut Device, value: Result<Option<T>, String>) -> Option<T> {
    match value {
        Ok(value) => value,
        Err(error) => {
            device.notes.push(error);
            None
        }
    }
}
fn device(path: &Path) -> Result<Option<Device>, String> {
    let physical = fs::canonicalize(path).map_err(|e| e.to_string())?;
    let bound = driver(&physical)?;
    let compatible = hardware::text(&physical.join("of_node/compatible"))?.unwrap_or_default();
    let family = match bound
        .as_deref()
        .and_then(driver_family)
        .or_else(|| compatible_family(&compatible))
    {
        Some(family) => family,
        None => match pci_family(&physical)? {
            Some(family) => family,
            None => return Ok(None),
        },
    };
    let suspended = matches!(
        hardware::text(&physical.join("power/runtime_status"))?.as_deref(),
        Some("suspended" | "suspending" | "resuming" | "error")
    );
    let basename =
        hardware::short_label(&physical.file_name().unwrap_or_default().to_string_lossy());
    let mut result = Device {
        id: physical.to_string_lossy().into_owned(),
        label: format!("{} · {basename}", family.name()),
        initialized: bound.is_some(),
        suspended,
        temperature_c: None,
        family,
        driver: bound,
        capability_only: false,
        utilization: None,
        client_activity: None,
        frequency_mhz: None,
        memory_bytes: None,
        notes: Vec::new(),
        busy_time_us: None,
    };
    if let Some(status) = hardware::text(&physical.join("of_node/status"))? {
        let status = status.trim_end_matches('\0');
        if !matches!(status, "okay" | "ok") {
            result.initialized = false;
            result.notes.push(format!(
                "Firmware node status: {}",
                hardware::short_label(status)
            ));
        }
    }
    if !compatible.is_empty() {
        result.notes.push(format!(
            "Firmware compatible: {}",
            hardware::short_label(
                &compatible
                    .split('\0')
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .join(" / ")
            )
        ));
    }
    if family == Family::Qualcomm {
        result.notes.push("Compute DSP/HTP endpoint; this does not verify a QNN runtime, tensor architecture or successful inference. Audio/modem DSPs and generic FastRPC presence are not counted.".into());
        let remotes = match hardware::directories(&physical.join("remoteproc")) {
            Ok(paths) => paths,
            Err(error) => {
                result.notes.push(error);
                Vec::new()
            }
        };
        if remotes.len() > 32 {
            result
                .notes
                .push("Remote processor inventory truncated to 32 entries".into());
        }
        for remote in remotes.into_iter().take(32) {
            if let Some(state) = optional(&mut result, hardware::text(&remote.join("state"))) {
                result.notes.push(format!(
                    "Remote processor: {}",
                    hardware::short_label(&state)
                ));
            }
        }
    }
    if result.initialized && !suspended && family == Family::Intel {
        result.busy_time_us = optional(&mut result, unsigned(&physical.join("npu_busy_time_us")));
        let frequency = optional(
            &mut result,
            unsigned(&physical.join("npu_current_frequency_mhz")),
        );
        result.frequency_mhz = frequency.map(|v| v as f64);
        result.memory_bytes = optional(
            &mut result,
            unsigned(&physical.join("npu_memory_utilization")),
        );
    }
    Ok(Some(result))
}

pub(super) fn extend(
    sys: &Path,
    start: Instant,
    found: &mut BTreeMap<String, Device>,
    errors: &mut Vec<String>,
) {
    // Class and bus aliases use one physical identity. PCI fallback detects
    // supported integrated NPUs even without a loaded accelerator driver.
    'scan: for (root, class) in [
        ("class/accel", true),
        ("bus/platform/devices", false),
        ("bus/pci/devices", false),
    ] {
        let paths = match hardware::directories(&sys.join(root)) {
            Ok(paths) => paths,
            Err(error) => {
                note(errors, error);
                continue;
            }
        };
        for path in paths {
            if start.elapsed() > BUDGET || found.len() >= 256 {
                note(
                    errors,
                    "NPU discovery budget/device limit reached; inventory is partial".into(),
                );
                break 'scan;
            }
            let target = if class {
                let name = path.file_name().unwrap_or_default().to_string_lossy();
                if !name
                    .strip_prefix("accel")
                    .is_some_and(|n| !n.is_empty() && n.bytes().all(|c| c.is_ascii_digit()))
                {
                    continue;
                }
                path.join("device")
            } else {
                path
            };
            if let Ok(identity) = super::canonical(&target)
                && found.contains_key(&identity)
            {
                continue;
            }
            match device(&target) {
                Ok(Some(value)) => {
                    found.entry(value.id.clone()).or_insert(value);
                }
                Ok(None) => (),
                Err(error) => note(errors, format!("{}: {error}", target.display())),
            }
        }
    }
    let rockchip: Vec<_> = found
        .values_mut()
        .filter(|d| {
            d.family == Family::Rockchip && matches!(d.driver.as_deref(), Some("rknpu" | "RKNPU"))
        })
        .collect();
    // This driver exposes a global debugfs load report. With multiple devices
    // its ownership is ambiguous, so never copy the same reading onto each one.
    if rockchip.len() == 1 {
        let device = rockchip.into_iter().next().unwrap();
        if device.initialized && !device.suspended {
            let load = hardware::text(&sys.join("kernel/debug/rknpu/load"))
                .and_then(|s| s.map(|s| parse_rockchip_load(&s)).transpose());
            device.utilization = optional(device, load);
            if device.utilization.is_some() {
                device.notes.push("Activity: vendor-reported mean core load from rknpu/load (not inference throughput)".into());
            }
        }
    }
    // Some firmware describes a known NPU-bearing SoC but no Linux NPU
    // endpoint. Keep this explicitly separate from enumerated hardware.
    match hardware::text(&sys.join("firmware/devicetree/base/compatible")) {
        Ok(Some(compatible)) => {
            for soc in compatible.split('\0') {
                if found.len() >= 256 {
                    break;
                }
                let Some(family) = soc_family(soc) else {
                    continue;
                };
                if found.values().any(|d| d.family == family) {
                    continue;
                }
                let id = format!("npu-capability:{soc}");
                found.insert(id.clone(), Device {
                    id, label:format!("{} · {soc} (SoC capability)",family.name()),
                    initialized:false, suspended:false,temperature_c:None,
                    family, driver:None, capability_only:true, client_activity:None,
                    utilization:None,frequency_mhz:None,memory_bytes:None,busy_time_us:None,
                    notes:vec!["Known SoC includes a neural compute engine; no corresponding Linux accelerator endpoint was detected. Availability and activity are unverified.".into()],
                });
            }
        }
        Ok(None) => (),
        Err(error) => note(errors, error),
    }
}
fn soc_family(soc: &str) -> Option<Family> {
    Some(match soc {
        "apple,t8103" | "apple,t6000" | "apple,t6001" | "apple,t6002" | "apple,t8112"
        | "apple,t6020" | "apple,t6021" | "apple,t6022" | "apple,t8122" | "apple,t6030"
        | "apple,t6031" | "apple,t6032" | "apple,t6034" | "apple,t8132" | "apple,t6040"
        | "apple,t6041" | "apple,t8142" | "apple,t6050" | "apple,t6051" | "apple,t6052" => {
            Family::Apple
        }
        "rockchip,rk1808" | "rockchip,rk3566" | "rockchip,rk3568" | "rockchip,rk3588"
        | "rockchip,rk3588s" => Family::Rockchip,
        "qcom,x1e80100" | "qcom,sc8280xp" | "qcom,sm8550" | "qcom,sm8650" | "qcom,sm8750" => {
            Family::Qualcomm
        }
        _ => return None,
    })
}

/// Rockchip's driver prints one load percentage, or Core0..CoreN percentages.
/// Its `%2.d` format renders zero as spaces, which is valid only before `%`.
pub fn parse_rockchip_load(text: &str) -> Result<f64, String> {
    let body = text
        .trim()
        .strip_prefix("NPU load:")
        .ok_or("Invalid Rockchip NPU load header")?
        .trim();
    let body = body.strip_suffix(',').unwrap_or(body);
    let mut total = 0u32;
    let mut count = 0usize;
    for (index, field) in body.split(',').enumerate() {
        if index >= 16 {
            return Err("Too many Rockchip NPU cores".into());
        }
        let field = field.trim();
        let value = if let Some(core) = field.strip_prefix("Core") {
            let (number, value) = core.split_once(':').ok_or("Invalid Rockchip core load")?;
            if !number.bytes().all(|b| b.is_ascii_digit())
                || number.parse::<usize>().ok() != Some(index)
            {
                return Err("Missing/duplicate Rockchip NPU core".into());
            }
            value.trim()
        } else {
            if body.contains(',') || index != 0 {
                return Err("Missing Rockchip NPU core identity".into());
            }
            field
        };
        let digits = value
            .strip_suffix('%')
            .ok_or("Missing Rockchip NPU percent unit")?
            .trim();
        let percent = if digits.is_empty() {
            0
        } else {
            if !digits.bytes().all(|b| b.is_ascii_digit()) {
                return Err("Invalid Rockchip NPU percentage".into());
            }
            digits
                .parse::<u32>()
                .map_err(|_| "Invalid Rockchip NPU percentage")?
        };
        if percent > 100 {
            return Err("Rockchip NPU load is out of range".into());
        }
        total += percent;
        count += 1;
    }
    Ok(total as f64 / count as f64)
}

#[derive(Default)]
pub(super) struct Activity {
    previous: BTreeMap<String, BusyBaseline>,
}
#[derive(Clone)]
struct BusyBaseline {
    total: u64,
    time: f64,
    identity: (Option<String>, u64, u64),
}
impl Activity {
    pub fn update(&mut self, report: &mut Result<Readings<Device>, String>, time: f64) {
        let Ok(report) = report else {
            self.previous.clear();
            return;
        };
        let mut next = BTreeMap::new();
        for device in &mut report.values {
            let Some(total) = device.busy_time_us else {
                continue;
            };
            if !time.is_finite() || time < 0. || device.suspended {
                continue;
            }
            let root = Path::new(&device.id);
            // Inode incarnation metadata is POSIX; every unix target keeps it.
            #[cfg(unix)]
            let identity = fs::metadata(root).and_then(|physical| {
                fs::symlink_metadata(root.join("driver"))
                    .map(|driver| (device.driver.clone(), physical.ino(), driver.ino()))
            });
            #[cfg(not(unix))]
            let identity = fs::metadata(root).and_then(|_| {
                // No inode incarnation metadata off Unix; the bound driver
                // name keys the activity identity instead.
                fs::symlink_metadata(root.join("driver")).map(|_| (device.driver.clone(), 0, 0))
            });
            let identity = match identity {
                Ok(value) => value,
                Err(error) => {
                    device
                        .notes
                        .push(format!("NPU identity changed while reading: {error}"));
                    continue;
                }
            };
            if let Some(before) = self.previous.get(&device.id)
                && before.identity == identity
                && time > before.time
            {
                let elapsed = (time - before.time) * 1_000_000.;
                if let Some(delta) = total.checked_sub(before.total) {
                    let percent = delta as f64 / elapsed * 100.;
                    // Allow small read/scheduling skew, reject impossible counters.
                    if percent.is_finite() && percent <= 102. {
                        device.utilization = Some(percent.min(100.));
                    } else {
                        device.notes.push(
                            "NPU busy-time delta exceeds elapsed time; activity unavailable".into(),
                        );
                    }
                } else {
                    device
                        .notes
                        .push("NPU busy-time counter reset; waiting for interval".into());
                }
            }
            if let Some(previous) = self.previous.get(&device.id)
                && previous.identity == identity
                && time <= previous.time
            {
                next.insert(device.id.clone(), previous.clone());
            } else {
                next.insert(
                    device.id.clone(),
                    BusyBaseline {
                        total,
                        time,
                        identity,
                    },
                );
            }
        }
        self.previous = next;
    }
}
