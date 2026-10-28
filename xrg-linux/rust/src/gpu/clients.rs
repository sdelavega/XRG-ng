// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Readable DRM-client activity, not a device-wide utilization estimate.
use super::arm::{family, profiling, same_driver};
use crate::{
    drm_clients::{Counter, scan},
    gpu::Device,
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
fn eligible(device: &Device) -> bool {
    !device.suspended
        && (family(&device.gpu.driver).is_some()
            || device.vendor == "0x8086" && matches!(device.gpu.driver.as_str(), "i915" | "xe"))
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
        let nodes: BTreeMap<PathBuf, _> = devices
            .iter()
            .filter(|d| eligible(d))
            .flat_map(|d| {
                d.nodes.iter().map(|n| {
                    (
                        Path::new("/dev/dri").join(n),
                        (d.gpu.id.clone(), d.gpu.driver.clone()),
                    )
                })
            })
            .collect();
        if nodes.is_empty() {
            self.previous.clear();
            return;
        }
        let report = match scan(proc, &nodes, same_driver) {
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
