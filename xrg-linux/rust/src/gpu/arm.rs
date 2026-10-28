// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Device, device, driver, insert_device, sysfs_metrics, unsigned};
use crate::hardware;
use std::{collections::BTreeMap, fs, path::Path};

#[derive(Clone, Copy, Debug, PartialEq)]
pub(super) enum Family {
    Mali,
    Adreno,
    Apple,
    Broadcom,
    Vivante,
    PowerVR,
}
impl Family {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Mali => "Arm Mali",
            Self::Adreno => "Qualcomm Adreno",
            Self::Apple => "Apple AGX",
            Self::Broadcom => "Broadcom V3D",
            Self::Vivante => "Vivante",
            Self::PowerVR => "Imagination PowerVR",
        }
    }
}
pub(super) fn family(driver: &str) -> Option<Family> {
    match driver {
        "panfrost" | "panthor" | "lima" | "mali" | "mali-kbase" | "mali-midgard"
        | "mali-bifrost" => Some(Family::Mali),
        "adreno" | "msm" | "msm_drm" | "msm-drm" | "msm_dpu" | "kgsl" | "kgsl-3d" | "kgsl-3d0" => {
            Some(Family::Adreno)
        }
        "asahi" => Some(Family::Apple),
        "v3d" => Some(Family::Broadcom),
        "etnaviv" => Some(Family::Vivante),
        "powervr" | "pvr" => Some(Family::PowerVR),
        _ => None,
    }
}
const DRIVERS: &[&str] = &[
    "panfrost",
    "panthor",
    "lima",
    "mali",
    "mali-kbase",
    "mali-midgard",
    "mali-bifrost",
    "adreno",
    "asahi",
    "kgsl",
    "kgsl-3d",
    "kgsl-3d0",
    "v3d",
    "etnaviv",
    "powervr",
    "pvr",
];
pub(super) fn discover(
    sys: &Path,
    devices: &mut BTreeMap<String, Device>,
    errors: &mut Vec<String>,
) {
    for binding in DRIVERS {
        let entries = match hardware::directories(&sys.join("bus/platform/drivers").join(binding)) {
            Ok(entries) => entries,
            Err(error) => {
                errors.push(error);
                continue;
            }
        };
        for entry in entries {
            if !fs::symlink_metadata(&entry).is_ok_and(|m| m.file_type().is_symlink()) {
                continue;
            }
            let Ok(path) = fs::canonicalize(&entry) else {
                continue;
            };
            if driver(&path).ok().as_deref() != Some(binding) {
                continue;
            }
            match device(path, None, "") {
                Ok(d) => insert_device(devices, d),
                Err(e) => errors.push(e),
            }
        }
    }
    // Qualcomm's vendor KGSL class has telemetry on the class device rather
    // than its parent platform device. Identity remains the canonical parent.
    let kgsl = match hardware::directories(&sys.join("class/kgsl")) {
        Ok(entries) => entries,
        Err(error) => {
            errors.push(error);
            Vec::new()
        }
    };
    for entry in kgsl {
        if entry.file_name().and_then(|n| n.to_str()) != Some("kgsl-3d0") {
            continue;
        }
        match device(entry.join("device"), None, "") {
            Ok(mut d) if family(&d.gpu.driver) == Some(Family::Adreno) => {
                d.metrics_paths.push(entry);
                insert_device(devices, d);
            }
            Ok(_) => (),
            Err(e) => errors.push(e),
        }
    }
    // Mainline MSM's DRM master can be a display-subsystem parent while the
    // GPU binds separately to adreno. Associate only an unambiguous 1:1 pair.
    let masters: Vec<_> = devices
        .values()
        .filter(|d| {
            matches!(
                d.gpu.driver.as_str(),
                "msm" | "msm_drm" | "msm-drm" | "msm_dpu"
            )
        })
        .map(|d| d.gpu.id.clone())
        .collect();
    let gpus: Vec<_> = devices
        .values()
        .filter(|d| d.gpu.driver == "adreno")
        .map(|d| d.gpu.id.clone())
        .collect();
    if masters.len() == 1 && gpus.len() == 1 {
        let master = devices.remove(&masters[0]).unwrap();
        let gpu = devices.get_mut(&gpus[0]).unwrap();
        gpu.nodes.extend(master.nodes);
        // The DRM master may be a display controller. Its nodes identify
        // clients, but its clocks/sensors do not describe the GPU.
        if gpu.card.is_none() {
            gpu.card = master.card;
            gpu.gpu.label = master.gpu.label;
        }
    }
}

#[derive(Default)]
pub(super) struct ArmCollector;
impl ArmCollector {
    pub(super) fn collect(&mut self, sys: &Path, devices: &mut [Device]) {
        for device in devices
            .iter_mut()
            .filter(|d| !d.suspended && family(&d.gpu.driver).is_some())
        {
            if matches!(
                device.gpu.driver.as_str(),
                "msm" | "msm_drm" | "msm-drm" | "msm_dpu"
            ) {
                device
                    .gpu
                    .notes
                    .push("DRM display master: physical GPU telemetry mapping unavailable".into());
            } else {
                sysfs_metrics(device);
                devfreq(sys, device);
            }
            if matches!(device.gpu.driver.as_str(), "kgsl" | "kgsl-3d" | "kgsl-3d0") {
                kgsl(device);
            }
        }
    }
}
fn devfreq(sys: &Path, device: &mut Device) {
    let mut domains = Vec::new();
    for root in &device.metrics_paths {
        match hardware::directories(&root.join("devfreq")) {
            Ok(entries) => domains.extend(entries),
            Err(e) => device.gpu.notes.push(e),
        }
    }
    // Global class aliases are accepted only when their canonical parent/device
    // belongs to this GPU, never by a name containing "gpu" or frequency value.
    if domains.is_empty()
        && let Ok(entries) = hardware::directories(&sys.join("class/devfreq"))
    {
        for entry in entries {
            let canonical = fs::canonicalize(&entry).ok();
            let owner = fs::canonicalize(entry.join("device")).ok();
            if device.metrics_paths.iter().any(|p| {
                owner.as_ref() == Some(p)
                    || canonical
                        .as_ref()
                        .is_some_and(|c| c.starts_with(p.join("devfreq")))
            }) {
                domains.push(entry);
            }
        }
    }
    // Collapse class/local aliases before deciding whether a single domain
    // unambiguously describes device load (not e.g. a separate memory clock).
    domains = domains
        .into_iter()
        .filter_map(|p| fs::canonicalize(p).ok())
        .collect();
    domains.sort();
    domains.dedup();
    let single_domain = domains.len() == 1;
    for domain in domains {
        if single_domain {
            match hardware::text(&domain.join("load")) {
                Ok(Some(value)) if !value.is_empty() => {
                    // Rockchip's devfreq ABI publishes measured busy percent and
                    // the reporting clock as "percent@frequencyHz", not a frequency ratio.
                    let parsed = value
                        .split_once('@')
                        .and_then(|(busy, hz)| {
                            Some((
                                busy.parse::<u64>().ok()?,
                                hz.strip_suffix("Hz")?.parse::<u64>().ok()?,
                            ))
                        })
                        .filter(|(busy, hz)| *busy <= 100 && *hz > 0);
                    if let Some((busy, hz)) = parsed {
                        device.gpu.utilization = Some(busy as f64);
                        if device.gpu.frequency_mhz.is_none() {
                            device.gpu.frequency_mhz = Some(hz as f64 / 1_000_000.);
                        }
                    } else {
                        device
                            .gpu
                            .notes
                            .push("Invalid GPU devfreq load sample".into());
                    }
                }
                Ok(_) => (),
                Err(error) => device.gpu.notes.push(error),
            }
        }

        if let Some(hz) = unsigned(&domain.join("cur_freq"), &mut device.gpu.notes)
            && device.gpu.frequency_mhz.is_none()
        {
            device.gpu.frequency_mhz = Some(hz as f64 / 1_000_000.);
        }
    }
}
fn kgsl(device: &mut Device) {
    for root in &device.metrics_paths {
        if device.gpu.frequency_mhz.is_none() {
            device.gpu.frequency_mhz = unsigned(&root.join("gpuclk"), &mut device.gpu.notes)
                .map(|v| v as f64 / 1_000_000.);
        }
        match hardware::text(&root.join("gpubusy")) {
            Ok(Some(text)) => {
                let fields = text
                    .split_whitespace()
                    .map(str::parse::<u64>)
                    .collect::<Result<Vec<_>, _>>();
                match fields {
                    Ok(v) if v.len() == 2 && v[1] > 0 && v[0] <= v[1] => {
                        device.gpu.utilization = Some(100. * v[0] as f64 / v[1] as f64)
                    }
                    Ok(v) if v == [0, 0] => (), // no valid measurement interval
                    _ => device
                        .gpu
                        .notes
                        .push("Invalid KGSL busy/total interval".into()),
                }
            }
            Ok(None) => (),
            Err(e) => device.gpu.notes.push(e),
        }
    }
}
pub(super) fn profiling(device: &Device) -> bool {
    let required = match device.gpu.driver.as_str() {
        "panfrost" => 1,
        "panthor" => 2,
        _ => return true,
    };
    hardware::integer(&device.path.join("profiling"))
        .ok()
        .flatten()
        .is_some_and(|v| v >= 0 && v & required != 0)
}
pub(super) fn same_driver(driver: &str, reported: &str) -> bool {
    driver == reported || (family(driver) == Some(Family::Adreno) && reported == "msm")
}
