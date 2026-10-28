// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! i915 PMU names and event ABI; never assign an ambiguous global PMU to a GPU.
use crate::{
    gpu::{Device, pci_id},
    system_file,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Event {
    pub name: String,
    pub config: u64,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Spec {
    pub path: PathBuf,
    pub event_type: u32,
    pub cpu: u32,
    pub events: Vec<Event>,
    pub device_identity: (u64, u64),
    pub pmu_identity: (u64, u64),
}
pub(super) fn identity(path: &Path) -> Result<(u64, u64), String> {
    use std::os::unix::fs::MetadataExt;
    let metadata = fs::metadata(path).map_err(|e| e.to_string())?;
    if !metadata.is_dir() {
        return Err("Expected a PMU/device directory".into());
    }
    Ok((metadata.dev(), metadata.ino()))
}
fn text(path: &Path) -> Result<String, String> {
    String::from_utf8(system_file::read(path, 4096).map_err(|e| e.to_string())?)
        .map_err(|_| "Invalid PMU text".into())
}
fn number(value: &str) -> Result<u64, String> {
    let value = value.trim();
    if let Some(value) = value.strip_prefix("0x") {
        if value.is_empty() || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("Invalid PMU number".into());
        }
        u64::from_str_radix(value, 16)
    } else {
        if value.is_empty() || !value.bytes().all(|b| b.is_ascii_digit()) {
            return Err("Invalid PMU number".into());
        }
        value.parse()
    }
    .map_err(|_| "PMU number overflow".into())
}
pub(super) fn config(value: &str) -> Result<u64, String> {
    let config = number(
        value
            .trim()
            .strip_prefix("config=")
            .ok_or("Unknown PMU event layout")?,
    )?;
    if config >= 0x100000 || config & 0xf != 0 {
        return Err("Not an i915 engine-busy event".into());
    }
    Ok(config)
}
fn ranges(text: &str) -> Result<Vec<(u32, u32)>, String> {
    let mut ranges = Vec::new();
    for value in text.trim().split(',') {
        if ranges.len() >= 256 {
            return Err("CPU-list limit exceeded".into());
        }
        let (first, last) = value.split_once('-').unwrap_or((value, value));
        let first = u32::try_from(number(first)?).map_err(|_| "Invalid PMU CPU")?;
        let last = u32::try_from(number(last)?).map_err(|_| "Invalid PMU CPU")?;
        if first > last || last > 1_048_575 {
            return Err("Invalid PMU CPU range".into());
        }
        if ranges.last().is_some_and(|(_, old)| *old >= first) {
            return Err("Unordered or duplicate PMU CPU range".into());
        }
        ranges.push((first, last));
    }
    Ok(ranges)
}
pub(super) fn cpu(allowed: Option<&str>, online: &str) -> Result<u32, String> {
    let online = ranges(online)?;
    let allowed = allowed
        .map(ranges)
        .transpose()?
        .unwrap_or_else(|| online.clone());
    for (first, last) in allowed {
        for (start, end) in &online {
            let candidate = first.max(*start);
            if candidate <= last.min(*end) {
                return Ok(candidate);
            }
        }
    }
    Err("PMU has no online reader CPU".into())
}
fn named(sys: &Path, id: &str) -> Option<PathBuf> {
    let root = fs::canonicalize(sys).ok()?;
    let candidate = sys
        .join("bus/event_source/devices")
        .join(format!("i915_{}", id.replace(':', "_")));
    let path = fs::canonicalize(candidate).ok()?;
    path.starts_with(root).then_some(path)
}
pub(super) fn global_owner(sys: &Path) -> Result<Option<String>, String> {
    let start = Instant::now();
    let mut unmatched = BTreeSet::new();
    for (count, entry) in fs::read_dir(sys.join("bus/pci/devices"))
        .map_err(|e| e.to_string())?
        .enumerate()
    {
        if count >= 4096 || start.elapsed() > Duration::from_millis(25) {
            return Err("PMU PCI mapping budget exceeded".into());
        }
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        let Some(id) = name.to_str().and_then(pci_id) else {
            continue;
        };
        let driver = match fs::read_link(entry.path().join("driver")) {
            Ok(link) => link,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e.to_string()),
        };
        if driver.file_name().and_then(|s| s.to_str()) != Some("i915") {
            continue;
        }
        if text(&entry.path().join("vendor"))?.trim() != "0x8086" {
            return Err("Unexpected i915 PCI vendor".into());
        }
        if named(sys, &id).is_none() {
            unmatched.insert(id);
        }
    }
    Ok((unmatched.len() == 1).then(|| unmatched.pop_first().unwrap()))
}
pub(super) fn describe(
    sys: &Path,
    device: &Device,
    global: &Result<Option<String>, String>,
) -> Result<Spec, String> {
    let root = fs::canonicalize(sys).map_err(|e| e.to_string())?;
    let path = if let Some(path) = named(sys, &device.gpu.id) {
        path
    } else {
        if global.as_ref().map_err(Clone::clone)?.as_deref() != Some(device.gpu.id.as_str()) {
            return Err("i915 PMU association unavailable or ambiguous".into());
        }
        fs::canonicalize(sys.join("bus/event_source/devices/i915")).map_err(|e| e.to_string())?
    };
    if !path.starts_with(&root) || !device.path.starts_with(&root) {
        return Err("PMU mapping escaped its sysfs root".into());
    }
    let pmu_identity = identity(&path)?;
    let device_identity = identity(&device.path)?;
    let event_type =
        u32::try_from(number(&text(&path.join("type"))?)?).map_err(|_| "Invalid PMU type")?;
    if event_type < 6 {
        return Err("PMU type is not dynamically registered".into());
    }
    let online = text(&sys.join("devices/system/cpu/online"))?;
    let mask = match text(&path.join("cpumask")) {
        Ok(value) => Some(value),
        Err(_) if !path.join("cpumask").exists() => None,
        Err(error) => return Err(error),
    };
    let cpu = cpu(mask.as_deref(), &online)?;
    let mut events = Vec::new();
    let mut configs = BTreeMap::new();
    let start = Instant::now();
    for (count, entry) in fs::read_dir(path.join("events"))
        .map_err(|e| e.to_string())?
        .enumerate()
    {
        if count >= 1024 || start.elapsed() > Duration::from_millis(25) {
            return Err("PMU event enumeration budget exceeded".into());
        }
        let entry = entry.map_err(|e| e.to_string())?;
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Some(engine) = name.strip_suffix("-busy") else {
            continue;
        };
        if engine.is_empty()
            || name.len() > 64
            || !engine
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'_')
            || events.len() >= 64
        {
            return Err("Invalid or excessive PMU engine list".into());
        }
        if text(&path.join("events").join(format!("{name}.unit")))?.trim() != "ns" {
            return Err("Unknown PMU busy-counter unit".into());
        }
        let scale = path.join("events").join(format!("{name}.scale"));
        if scale.exists() && text(&scale)?.trim().parse::<f64>().ok() != Some(1.) {
            return Err("Unsupported PMU busy-counter scale".into());
        }
        let config = config(&text(&entry.path())?)?;
        if configs.insert(config, name.to_owned()).is_some() {
            return Err("Duplicate PMU engine event".into());
        }
        events.push(Event {
            name: engine.into(),
            config,
        });
    }
    if events.is_empty() {
        return Err("No exported i915 busy events".into());
    }
    events.sort_by(|a, b| a.name.cmp(&b.name));
    let spec = Spec {
        path,
        event_type,
        cpu,
        events,
        device_identity,
        pmu_identity,
    };
    spec.verify(device)?;
    Ok(spec)
}
impl Spec {
    pub fn verify(&self, device: &Device) -> Result<(), String> {
        if identity(&device.path)? != self.device_identity
            || identity(&self.path)? != self.pmu_identity
            || number(&text(&self.path.join("type"))?)? != self.event_type as u64
            || crate::gpu::driver(&device.path)? != "i915"
        {
            return Err("PMU device identity changed during acquisition".into());
        }
        Ok(())
    }
}
