// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use crate::{
    gpu::{
        Device, driver,
        intel::discovery::{cpu, identity},
        pci_id,
    },
    system_file,
};
use std::{
    fs,
    path::{Path, PathBuf},
};
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Spec {
    pub device: PathBuf,
    device_identity: (u64, u64),
    binding: (u64, u64),
    pub pmu: PathBuf,
    pmu_identity: (u64, u64),
    pub event_type: u32,
    pub cpu: u32,
    pub node: PathBuf,
    class: PathBuf,
    class_identity: (u64, u64),
    pub dev: (u32, u32),
}
fn text(path: &Path) -> Result<String, String> {
    String::from_utf8(system_file::read(path, 4096).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())
}
fn optional(path: &Path) -> Result<Option<String>, String> {
    match text(path) {
        Ok(s) => Ok(Some(s)),
        Err(_)
            if fs::symlink_metadata(path)
                .is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
        {
            Ok(None)
        }
        Err(e) => Err(e),
    }
}
fn binding(device: &Path) -> Result<(u64, u64), String> {
    use std::os::unix::fs::MetadataExt;
    let meta = fs::symlink_metadata(device.join("driver")).map_err(|e| e.to_string())?;
    if !meta.file_type().is_symlink() {
        return Err("Xe binding is not a driver link".into());
    }
    Ok((meta.dev(), meta.ino()))
}
fn state(device: &Path) -> Result<(), String> {
    match fs::symlink_metadata(device.join("physfn")) {
        Ok(_) => return Err("Xe PMU VF activity is not supported".into()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
        Err(e) => return Err(e.to_string()),
    }
    if optional(&device.join("sriov_numvfs"))?
        .is_some_and(|s| s.trim().parse::<u32>().ok() != Some(0))
    {
        return Err("Xe PMU is deferred while SR-IOV VFs are enabled".into());
    }
    if optional(&device.join("power/runtime_status"))?.is_some_and(|s| s.trim() != "active") {
        return Err("Xe PMU waits for an active runtime power state".into());
    }
    if driver(device)? != "xe" || text(&device.join("vendor"))?.trim() != "0x8086" {
        return Err("Xe PCI driver/vendor changed".into());
    }
    Ok(())
}
fn dev(path: &Path) -> Result<(u32, u32), String> {
    let s = text(path)?;
    let (a, b) = s
        .trim()
        .split_once(':')
        .ok_or("Invalid DRM device number")?;
    let a = a.parse::<u32>().map_err(|_| "Invalid DRM major")?;
    let b = b.parse::<u32>().map_err(|_| "Invalid DRM minor")?;
    if a == 0 || a > 4095 || b > 1_048_575 {
        return Err("DRM device number out of range".into());
    }
    Ok((a, b))
}
fn abi(pmu: &Path) -> Result<(), String> {
    for (name, value) in [
        ("event", "config:0-11"),
        ("engine_class", "config:20-27"),
        ("engine_instance", "config:12-19"),
        ("gt", "config:60-63"),
    ] {
        if text(&pmu.join("format").join(name))?.trim() != value {
            return Err(format!("Unsupported Xe PMU {name} layout"));
        }
    }
    if optional(&pmu.join("format/function"))?.is_some_and(|s| s.trim() != "config:44-59") {
        return Err("Unsupported Xe function layout".into());
    }
    for (name, id) in [("engine-active-ticks", 2), ("engine-total-ticks", 3)] {
        let value = text(&pmu.join("events").join(name))?;
        let value = value
            .trim()
            .strip_prefix("event=")
            .ok_or("Unsupported Xe event definition")?;
        let parsed = if let Some(s) = value.strip_prefix("0x") {
            u64::from_str_radix(s, 16)
        } else {
            value.parse::<u64>()
        };
        if parsed.ok() != Some(id) {
            return Err("Unexpected Xe engine event ID".into());
        }
        if optional(&pmu.join("events").join(format!("{name}.unit")))?
            .is_some_and(|s| s.trim() != "ticks")
        {
            return Err("Unexpected Xe engine counter unit".into());
        }
        if optional(&pmu.join("events").join(format!("{name}.scale")))?
            .is_some_and(|s| s.trim().parse::<f64>().ok() != Some(1.))
        {
            return Err("Unexpected Xe engine counter scale".into());
        }
    }
    Ok(())
}
pub(super) fn describe(sys: &Path, device: &Device) -> Result<Spec, String> {
    state(&device.path)?;
    let id = pci_id(&device.gpu.id).ok_or("Xe PMU requires a PCI identity")?;
    let root = fs::canonicalize(sys).map_err(|e| e.to_string())?;
    let pmu = fs::canonicalize(
        sys.join("bus/event_source/devices")
            .join(format!("xe_{}", id.replace(':', "_"))),
    )
    .map_err(|e| e.to_string())?;
    if !pmu.starts_with(&root) || !device.path.starts_with(&root) {
        return Err("Xe PMU mapping escaped sysfs".into());
    }
    abi(&pmu)?;
    let event_type = text(&pmu.join("type"))?
        .trim()
        .parse::<u32>()
        .map_err(|_| "Invalid Xe PMU type")?;
    if event_type < 6 {
        return Err("Xe PMU type is not dynamically registered".into());
    }
    let cpu = cpu(
        optional(&pmu.join("cpumask"))?.as_deref(),
        &text(&sys.join("devices/system/cpu/online"))?,
    )?;
    for name in &device.nodes {
        if !name
            .strip_prefix("renderD")
            .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
        {
            continue;
        }
        let class =
            fs::canonicalize(sys.join("class/drm").join(name)).map_err(|e| e.to_string())?;
        if !class.starts_with(&root)
            || fs::canonicalize(class.join("device")).map_err(|e| e.to_string())? != device.path
        {
            return Err("Xe render node does not map to this PCI device".into());
        }
        let spec = Spec {
            device: device.path.clone(),
            device_identity: identity(&device.path)?,
            binding: binding(&device.path)?,
            pmu_identity: identity(&pmu)?,
            pmu,
            event_type,
            cpu,
            node: Path::new("/dev/dri").join(name),
            class_identity: identity(&class)?,
            dev: dev(&class.join("dev"))?,
            class,
        };
        spec.verify()?;
        return Ok(spec);
    }
    Err("No mapped Xe render node is readable".into())
}
impl Spec {
    pub fn verify(&self) -> Result<(), String> {
        state(&self.device)?;
        if identity(&self.device)? != self.device_identity
            || binding(&self.device)? != self.binding
            || identity(&self.pmu)? != self.pmu_identity
            || identity(&self.class)? != self.class_identity
            || dev(&self.class.join("dev"))? != self.dev
            || fs::canonicalize(self.class.join("device")).map_err(|e| e.to_string())?
                != self.device
            || text(&self.pmu.join("type"))?.trim().parse::<u32>().ok() != Some(self.event_type)
        {
            return Err("Xe device/PMU/node identity changed".into());
        }
        abi(&self.pmu)
    }
}
