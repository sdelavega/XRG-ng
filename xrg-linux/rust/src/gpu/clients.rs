// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Readable DRM-client activity, not a device-wide utilization estimate.
use super::arm::{family, profiling, same_driver};
use crate::gpu::Device;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs, io,
    os::unix::fs::MetadataExt,
    path::Path,
    time::{Duration, Instant},
};

#[derive(Debug)]
struct Client {
    driver: String,
    id: u64,
    engines: BTreeMap<String, (Counter, u64)>,
    resident: Option<u64>,
    frequency: Option<u64>,
}
#[derive(Clone, Copy, Debug)]
enum Counter {
    Nanoseconds(u64),
    Cycles { busy: u64, total: u64 },
}
impl Counter {
    fn busy(self) -> u64 {
        match self {
            Self::Nanoseconds(value) | Self::Cycles { busy: value, .. } => value,
        }
    }
    fn same_kind(self, other: Self) -> bool {
        matches!(
            (self, other),
            (Self::Nanoseconds(_), Self::Nanoseconds(_))
                | (Self::Cycles { .. }, Self::Cycles { .. })
        )
    }
    fn percent(self, previous: Self, elapsed: Duration, capacity: u64) -> Option<f64> {
        let busy = self.busy().checked_sub(previous.busy())?;
        let denominator = match (self, previous) {
            (Self::Nanoseconds(_), Self::Nanoseconds(_)) => elapsed.as_secs_f64() * 1_000_000_000.,
            (Self::Cycles { total, .. }, Self::Cycles { total: old, .. }) => {
                total.checked_sub(old)? as f64
            }
            _ => return None,
        };
        (denominator > 0.).then(|| 100. * busy as f64 / denominator / capacity as f64)
    }
}
fn eligible(device: &Device) -> bool {
    !device.suspended
        && (family(&device.gpu.driver).is_some()
            || device.vendor == "0x8086" && matches!(device.gpu.driver.as_str(), "i915" | "xe"))
}
fn quantity(text: &str, kind: &str) -> Result<u64, String> {
    let parts: Vec<_> = text.split_whitespace().collect();
    let number = parts
        .first()
        .ok_or("Missing client counter")?
        .parse::<u64>()
        .map_err(|_| "Invalid client counter")?;
    let multiplier = match (kind, parts.get(1).copied(), parts.len()) {
        ("ns", Some("ns"), 2)
        | ("integer", None, 1)
        | ("bytes", None | Some("B"), 1..=2)
        | ("Hz", None | Some("Hz"), 1..=2) => 1,
        ("bytes", Some("KiB"), 2) => 1024,
        ("Hz", Some("kHz" | "KHz"), 2) => 1000,
        ("bytes", Some("MiB"), 2) => 1_048_576,
        ("Hz", Some("MHz"), 2) => 1_000_000,
        _ => return Err("Unsupported client counter unit".into()),
    };
    number
        .checked_mul(multiplier)
        .ok_or_else(|| "Client counter overflow".into())
}
fn parse(text: &str, gpu_id: &str) -> Result<Client, String> {
    let mut fields = BTreeMap::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.starts_with("drm-") && fields.insert(key, value.trim()).is_some() {
            return Err("Duplicate DRM client field".into());
        }
    }
    let driver = fields
        .get("drm-driver")
        .ok_or("Missing DRM driver")?
        .to_string();
    if let Some(expected) = crate::gpu::pci_id(gpu_id) {
        let reported = fields.get("drm-pdev").and_then(|v| crate::gpu::pci_id(v));
        if reported.as_ref() != Some(&expected) {
            return Err("DRM client PCI identity does not match device".into());
        }
    }
    let id = quantity(
        fields
            .get("drm-client-id")
            .ok_or("Missing DRM client identity")?,
        "integer",
    )?;
    let mut engines = BTreeMap::new();
    let mut frequency = None;
    for (key, value) in &fields {
        if key.starts_with("drm-engine-capacity-") {
            continue;
        }
        // Xe exports busy and total cycles, not elapsed nanoseconds. Never
        // substitute current/max clocks or the CPU polling interval for total.
        let name = if driver == "xe" {
            key.strip_prefix("drm-cycles-")
        } else {
            key.strip_prefix("drm-engine-")
        };
        if let Some(name) = name {
            if name.is_empty()
                || name.len() > 64
                || name.chars().any(|c| c.is_whitespace() || c.is_control())
                || engines.len() >= 64
            {
                return Err("Invalid DRM engine identity".into());
            }
            let capacity = fields
                .get(format!("drm-engine-capacity-{name}").as_str())
                .map(|s| quantity(s, "integer"))
                .transpose()?
                .unwrap_or(1);
            if capacity == 0 {
                return Err("Zero DRM engine capacity".into());
            }
            let counter = if driver == "xe" {
                let total = fields
                    .get(format!("drm-total-cycles-{name}").as_str())
                    .ok_or("Missing DRM total cycle counter")?;
                if fields.contains_key(format!("drm-maxfreq-{name}").as_str()) {
                    return Err("Conflicting DRM cycle denominator".into());
                }
                Counter::Cycles {
                    busy: quantity(value, "integer")?,
                    total: quantity(total, "integer")?,
                }
            } else {
                Counter::Nanoseconds(quantity(value, "ns")?)
            };
            engines.insert(name.to_owned(), (counter, capacity));
        }
        if key.starts_with("drm-curfreq-") {
            let hz = quantity(value, "Hz")?;
            frequency = Some(frequency.unwrap_or(0).max(hz));
        }
    }
    let mut resident = None::<u64>;
    for (key, value) in &fields {
        if let Some(region) = key.strip_prefix("drm-resident-") {
            if region.is_empty()
                || region.len() > 64
                || region.chars().any(|c| c.is_whitespace() || c.is_control())
            {
                return Err("Invalid DRM memory region".into());
            }
            let bytes = quantity(value, "bytes")?;
            resident = Some(
                resident
                    .unwrap_or(0)
                    .checked_add(bytes)
                    .ok_or("Client resident allocation overflow")?,
            );
        }
    }
    Ok(Client {
        driver,
        id,
        engines,
        resident,
        frequency,
    })
}
struct Scan {
    values: BTreeMap<(String, u64), Client>,
    partial: bool,
}
fn scan(proc: &Path, nodes: &BTreeMap<String, (String, String)>) -> Result<Scan, String> {
    let mut result = Scan {
        values: BTreeMap::new(),
        partial: false,
    };
    let deadline = Instant::now() + Duration::from_millis(50);
    let mut files = 0;
    let processes = fs::read_dir(proc).map_err(|e| e.to_string())?;
    for (count, entry) in processes.enumerate() {
        if count >= 4096 || Instant::now() >= deadline {
            result.partial = true;
            break;
        }
        let Ok(entry) = entry else {
            result.partial = true;
            continue;
        };
        if !entry
            .file_name()
            .to_string_lossy()
            .bytes()
            .all(|b| b.is_ascii_digit())
        {
            continue;
        }
        let entries = match fs::read_dir(entry.path().join("fdinfo")) {
            Ok(entries) => entries,
            Err(e) => {
                if e.kind() != io::ErrorKind::NotFound {
                    result.partial = true;
                }
                continue;
            }
        };
        for file in entries {
            if files >= 8192 || Instant::now() >= deadline {
                result.partial = true;
                return Ok(result);
            }
            files += 1;
            let Ok(file) = file else {
                result.partial = true;
                continue;
            };
            let name = file.file_name();
            if !name.to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
                continue;
            }
            let link = match fs::read_link(entry.path().join("fd").join(&name)) {
                Ok(link) => link,
                Err(e) => {
                    if e.kind() != io::ErrorKind::NotFound {
                        result.partial = true;
                    }
                    continue;
                }
            };
            if link.parent() != Some(Path::new("/dev/dri")) {
                continue;
            }
            let Some((gpu_id, expected_driver)) = link
                .file_name()
                .and_then(|n| n.to_str())
                .and_then(|n| nodes.get(n))
            else {
                continue;
            };
            let read = || -> Result<Client, String> {
                let bytes =
                    crate::system_file::read(&file.path(), 65_536).map_err(|e| e.to_string())?;
                let text = String::from_utf8(bytes).map_err(|_| "Invalid DRM client encoding")?;
                let client = parse(&text, gpu_id)?;
                if !same_driver(expected_driver, &client.driver) {
                    return Err("DRM client driver does not match device".into());
                }
                if fs::read_link(entry.path().join("fd").join(&name))
                    .ok()
                    .as_ref()
                    != Some(&link)
                {
                    return Err("DRM descriptor changed during read".into());
                }
                Ok(client)
            };
            match read() {
                Ok(client) => {
                    result
                        .values
                        .entry((gpu_id.clone(), client.id))
                        .or_insert(client);
                }
                Err(_) => result.partial = true,
            }
        }
    }
    Ok(result)
}
#[derive(Default)]
pub(super) struct ClientCollector {
    previous: BTreeMap<(String, u64, String), (Counter, u64, Instant)>,
    owners: BTreeMap<String, (String, u64, u64)>,
}
impl ClientCollector {
    pub(super) fn clear(&mut self) {
        self.previous.clear();
        self.owners.clear();
    }
    pub(super) fn collect(&mut self, proc: &Path, devices: &mut [Device], time: Instant) {
        let owners: BTreeMap<_, _> = devices
            .iter()
            .filter(|d| eligible(d))
            .filter_map(|d| {
                let m = fs::metadata(&d.path).ok()?;
                Some((d.gpu.id.clone(), (d.gpu.driver.clone(), m.dev(), m.ino())))
            })
            .collect();
        self.previous.retain(|(id, _, _), _| {
            owners
                .get(id)
                .is_some_and(|owner| self.owners.get(id) == Some(owner))
        });
        self.owners = owners;
        let nodes: BTreeMap<_, _> = devices
            .iter()
            .filter(|d| eligible(d))
            .flat_map(|d| {
                d.nodes
                    .iter()
                    .map(|n| (n.clone(), (d.gpu.id.clone(), d.gpu.driver.clone())))
            })
            .collect();
        if nodes.is_empty() {
            self.previous.clear();
            return;
        }
        let report = match scan(proc, &nodes) {
            Ok(report) => report,
            Err(_) => {
                for d in devices.iter_mut().filter(|d| eligible(d)) {
                    d.gpu.notes.push("DRM client stats unreadable".into());
                }
                self.previous.clear();
                return;
            }
        };
        let mut seen = BTreeSet::new();
        for device in devices.iter_mut().filter(|d| eligible(d)) {
            let identity = fs::metadata(&device.path)
                .ok()
                .map(|m| (device.gpu.driver.clone(), m.dev(), m.ino()));
            if identity.as_ref() != self.owners.get(&device.gpu.id)
                || super::driver(&device.path).ok().as_deref() != Some(&device.gpu.driver)
            {
                device
                    .gpu
                    .notes
                    .push("DRM device changed during client scan".into());
                continue;
            }
            let profiling = profiling(device);
            let clients: Vec<_> = report
                .values
                .iter()
                .filter(|((gpu, _), _)| gpu == &device.gpu.id)
                .map(|(_, c)| c)
                .collect();
            if !profiling {
                device.gpu.notes.push(
                    "Kernel job profiling disabled or unavailable; client activity not sampled"
                        .into(),
                );
            }
            if clients.is_empty() {
                device
                    .gpu
                    .notes
                    .push("No readable DRM client counters; activity unavailable".into());
                continue;
            }
            device.gpu.visible_clients = Some(clients.len());
            if profiling && clients.iter().all(|c| c.engines.is_empty()) {
                device
                    .gpu
                    .notes
                    .push("Driver reports no readable client engine activity counters".into());
            }
            if device.gpu.frequency_mhz.is_none() {
                device.gpu.frequency_mhz = clients
                    .iter()
                    .filter_map(|c| c.frequency)
                    .max()
                    .map(|hz| hz as f64 / 1_000_000.);
            }

            device.gpu.notes.push("Client activity covers readable clients only; protected/exiting clients may be omitted".into());
            if report.partial {
                device.gpu.notes.push(
                    "DRM client scan incomplete (permissions, limits or transient records)".into(),
                );
            }
            let mut engines: BTreeMap<String, (u64, f64)> = BTreeMap::new();
            let mut invalid_engines = BTreeSet::new();
            let mut warmup = false;
            let mut memory = None::<u64>;
            let mut memory_overflow = false;
            for client in clients {
                if let Some(resident) = client.resident {
                    match memory.unwrap_or(0).checked_add(resident) {
                        Some(total) => memory = Some(total),
                        None => memory_overflow = true,
                    }
                }
                if !profiling {
                    continue;
                }
                for (engine, &(counter, capacity)) in &client.engines {
                    let key = (device.gpu.id.clone(), client.id, engine.clone());
                    seen.insert(key.clone());
                    if let Some(&(previous, old_capacity, old_time)) = self.previous.get(&key) {
                        // The DRM ABI permits temporary regressions. Keep the
                        // larger baseline until the counter catches up.
                        if capacity != old_capacity || !counter.same_kind(previous) {
                            warmup = true;
                            self.previous.insert(key, (counter, capacity, time));
                            continue;
                        }
                        if counter.busy() < previous.busy() {
                            warmup = true;
                            continue;
                        }
                        if let Some(elapsed) = time
                            .checked_duration_since(old_time)
                            .filter(|d| !d.is_zero())
                        {
                            if elapsed <= Duration::from_secs(300) {
                                if let Some(rate) = counter.percent(previous, elapsed, capacity) {
                                    let entry =
                                        engines.entry(engine.clone()).or_insert((capacity, 0.));
                                    if entry.0 == capacity {
                                        entry.1 += rate;
                                    } else {
                                        invalid_engines.insert(engine.clone());
                                    }
                                } else {
                                    warmup = true;
                                }
                            } else {
                                warmup = true;
                            }
                        } else if time == old_time {
                            warmup = true;
                            continue;
                        } else {
                            // A regressed caller clock starts a fresh interval.
                            warmup = true;
                        }
                    } else {
                        warmup = true;
                    }
                    self.previous.insert(key, (counter, capacity, time));
                }
            }
            if !memory_overflow {
                device.gpu.client_resident_bytes = memory;
            } else {
                device
                    .gpu
                    .notes
                    .push("Client resident allocation sum overflowed".into());
            }
            let maximum = engines
                .iter()
                .filter(|(e, (_, value))| !invalid_engines.contains(*e) && *value <= 100.000_001)
                .map(|(_, (_, value))| *value)
                .reduce(f64::max);
            device.gpu.client_activity = maximum.map(|v| v.min(100.));
            if warmup {
                device
                    .gpu
                    .notes
                    .push("Some client counters need another monotonic interval".into());
            }
            if engines.values().any(|(_, value)| *value > 100.000_001)
                || !invalid_engines.is_empty()
            {
                device
                    .gpu
                    .notes
                    .push("Inconsistent or delayed client engine interval omitted".into());
            }
        }
        self.previous.retain(|key, _| seen.contains(key));
    }
}
