// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Readable DRM-client activity, not a device-wide utilization estimate.
use super::{family, profiling, same_driver};
use crate::gpu::Device;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File},
    io::{self, Read},
    path::Path,
    time::{Duration, Instant},
};

#[derive(Debug)]
struct Client {
    driver: String,
    id: u64,
    engines: BTreeMap<String, (u64, u64)>,
    resident: Option<u64>,
    frequency: Option<u64>,
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
fn parse(text: &str) -> Result<Client, String> {
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
        if let Some(name) = key.strip_prefix("drm-engine-") {
            if name.is_empty()
                || name.len() > 64
                || name.chars().any(char::is_whitespace)
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
            engines.insert(name.to_owned(), (quantity(value, "ns")?, capacity));
        }
        if key.starts_with("drm-curfreq-") {
            let hz = quantity(value, "Hz")?;
            frequency = Some(frequency.unwrap_or(0).max(hz));
        }
    }
    let resident = fields
        .get("drm-resident-memory")
        .map(|s| quantity(s, "bytes"))
        .transpose()?;
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
                let mut bytes = Vec::new();
                File::open(file.path())
                    .map_err(|e| e.to_string())?
                    .take(65_537)
                    .read_to_end(&mut bytes)
                    .map_err(|e| e.to_string())?;
                if bytes.len() > 65_536 {
                    return Err("Oversized DRM client record".into());
                }
                let text = String::from_utf8(bytes).map_err(|_| "Invalid DRM client encoding")?;
                let client = parse(&text)?;
                if !same_driver(expected_driver, &client.driver) {
                    return Err("DRM client driver does not match device".into());
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
    previous: BTreeMap<(String, u64, String), (u64, u64, Instant)>,
}
impl ClientCollector {
    pub(super) fn collect(&mut self, proc: &Path, devices: &mut [Device], time: Instant) {
        let nodes: BTreeMap<_, _> = devices
            .iter()
            .filter(|d| !d.suspended && family(&d.gpu.driver).is_some())
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
                for d in devices
                    .iter_mut()
                    .filter(|d| !d.suspended && family(&d.gpu.driver).is_some())
                {
                    d.gpu.notes.push("DRM client stats unreadable".into());
                }
                self.previous.clear();
                return;
            }
        };
        let mut seen = BTreeSet::new();
        for device in devices
            .iter_mut()
            .filter(|d| !d.suspended && family(&d.gpu.driver).is_some())
        {
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
                    .push("Driver reports no readable client engine-time counters".into());
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
                        if counter < previous {
                            warmup = true;
                            continue;
                        }
                        if let Some(elapsed) = time
                            .checked_duration_since(old_time)
                            .filter(|d| !d.is_zero())
                        {
                            if capacity == old_capacity {
                                let rate = (counter - previous) as f64
                                    / elapsed.as_secs_f64()
                                    / 1_000_000_000.
                                    / capacity as f64
                                    * 100.;
                                let entry = engines.entry(engine.clone()).or_insert((capacity, 0.));
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
                            continue;
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
