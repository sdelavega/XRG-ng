// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! AMD AIE2 busy-time accounting from readable, already-open DRM clients.
use super::{ClientActivity, Device, Family};
use crate::{
    drm_clients::{self, Counter},
    hardware::{self, Readings},
};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
};

type Owner = (u64, u64, u64);
fn supported(device: &Device) -> bool {
    let path = Path::new(&device.id);
    device.family == Family::Amd && device.initialized && !device.suspended
        && device.driver.as_deref() == Some("amdxdna")
        && super::id(path, "vendor").ok().flatten() == Some(0x1022)
        // Only AIE2 job accounting was verified. AIE4 exports must not be
        // interpreted as measured idle until its accounting hooks are verified.
        && matches!(super::id(path, "device").ok().flatten(), Some(0x1502 | 0x17f0))
}
fn owner(device: &Device) -> Result<Owner, String> {
    let path = Path::new(&device.id);
    if !matches!(
        hardware::text(&path.join("power/runtime_status"))?.as_deref(),
        None | Some("active")
    ) {
        return Err("AMD NPU power transition; client sampling deferred".into());
    }
    let physical = fs::metadata(path).map_err(|e| e.to_string())?;
    let bound = path.join("driver");
    let link = fs::symlink_metadata(&bound).map_err(|e| e.to_string())?;
    if !link.file_type().is_symlink()
        || fs::canonicalize(&bound)
            .map_err(|e| e.to_string())?
            .file_name()
            .and_then(|v| v.to_str())
            != Some("amdxdna")
    {
        return Err("AMD NPU driver changed during client scan".into());
    }
    Ok((physical.dev(), physical.ino(), link.ino()))
}
#[derive(Default)]
pub(super) struct Collector {
    owners: BTreeMap<String, Owner>,
    previous: BTreeMap<(String, u64), (u64, f64)>,
}
impl Collector {
    pub(super) fn collect(
        &mut self,
        proc: &Path,
        sys: &Path,
        result: &mut Result<Readings<Device>, String>,
        time: f64,
    ) {
        let Ok(result) = result else {
            self.previous.clear();
            self.owners.clear();
            return;
        };
        if !time.is_finite() || time < 0. {
            self.previous.clear();
            self.owners.clear();
            return;
        }
        let mut owners = BTreeMap::new();
        for device in result.values.iter_mut().filter(|d| supported(d)) {
            match owner(device) {
                Ok(identity) => {
                    owners.insert(device.id.clone(), identity);
                }
                Err(error) => device.notes.push(error),
            }
        }
        self.previous.retain(|(id, _), _| {
            owners
                .get(id)
                .is_some_and(|o| self.owners.get(id) == Some(o))
        });
        self.owners = owners;
        if self.owners.is_empty() {
            return;
        }
        let mut nodes = BTreeMap::<PathBuf, (String, String)>::new();
        let classes = hardware::directories(&sys.join("class/accel"));
        let classes = match classes {
            Ok(paths) => paths,
            Err(error) => {
                for device in result
                    .values
                    .iter_mut()
                    .filter(|d| self.owners.contains_key(&d.id))
                {
                    device
                        .notes
                        .push(format!("AMD accelerator nodes unavailable: {error}"));
                }
                self.previous.clear();
                return;
            }
        };
        let nodes_partial = classes.len() > 256;
        for path in classes.into_iter().take(256) {
            let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            if !name
                .strip_prefix("accel")
                .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
            {
                continue;
            }
            if let Ok(physical) = fs::canonicalize(path.join("device"))
                && let Some(id) = physical.to_str().filter(|id| self.owners.contains_key(*id))
            {
                nodes.insert(
                    Path::new("/dev/accel").join(name),
                    (id.to_owned(), "amdxdna".into()),
                );
            }
        }
        if nodes.is_empty() {
            for device in result
                .values
                .iter_mut()
                .filter(|d| self.owners.contains_key(&d.id))
            {
                device.notes.push(
                    "No mapped AMD accelerator class node; client activity unavailable".into(),
                );
            }
            self.previous.clear();
            return;
        }
        let scan = drm_clients::scan(proc, &nodes, |expected, reported| {
            expected == "amdxdna" && reported == "amdxdna_accel_driver"
        });
        let scan = match scan {
            Ok(scan) => scan,
            Err(error) => {
                for device in result
                    .values
                    .iter_mut()
                    .filter(|d| self.owners.contains_key(&d.id))
                {
                    device
                        .notes
                        .push(format!("AMD NPU client records unavailable: {error}"));
                }
                self.previous.clear();
                return;
            }
        };
        let mut seen = BTreeSet::new();
        for device in result
            .values
            .iter_mut()
            .filter(|d| self.owners.contains_key(&d.id))
        {
            let identity = owner(device);
            if identity.as_ref().ok() != self.owners.get(&device.id) {
                device
                    .notes
                    .push("AMD NPU identity/power changed during client scan".into());
                continue;
            }
            let clients: Vec<_> = scan
                .values
                .iter()
                .filter(|((id, _), _)| id == &device.id)
                .map(|(_, client)| client)
                .filter_map(|client| match client.engines.get("npu") {
                    Some((Counter::Nanoseconds(value), 1)) => Some((client.id, *value)),
                    _ => None,
                })
                .take(257)
                .collect();
            if clients.is_empty() {
                device.notes.push(
                    "No readable AMD NPU nanosecond client counters; activity unavailable".into(),
                );
                continue;
            }
            let mut maximum: Option<f64> = None;
            let mut waiting = false;
            for &(client, total) in clients.iter().take(256) {
                let key = (device.id.clone(), client);
                seen.insert(key.clone());
                if let Some(&(old, old_time)) = self.previous.get(&key) {
                    // The DRM ABI permits a temporary regression. Keep the
                    // larger baseline until it catches up, without inventing idle.
                    if total < old && time > old_time && time - old_time <= 300. {
                        waiting = true;
                        continue;
                    }
                    let elapsed = time - old_time;
                    if elapsed > 0. && elapsed <= 300. {
                        if let Some(delta) = total.checked_sub(old) {
                            let percent = 100. * delta as f64 / (elapsed * 1_000_000_000.);
                            if percent.is_finite() && percent <= 102. {
                                maximum = Some(maximum.unwrap_or(0.).max(percent.min(100.)));
                            } else {
                                waiting = true;
                            }
                        } else {
                            waiting = true;
                        }
                    } else if time == old_time {
                        waiting = true;
                        continue;
                    } else {
                        waiting = true;
                    }
                } else {
                    waiting = true;
                }
                if self.previous.len() < 1024 || self.previous.contains_key(&key) {
                    self.previous.insert(key, (total, time));
                } else {
                    waiting = true;
                }
            }
            let (dev, ino, bound) = identity.unwrap();
            let ids = clients
                .iter()
                .take(256)
                .map(|(id, _)| id.to_string())
                .collect::<Vec<_>>()
                .join(",");
            device.client_activity = Some(ClientActivity {
                percent: if waiting { None } else { maximum },
                clients: clients.len().min(256),
                scope: format!("{dev}:{ino}:{bound}:{ids}"),
            });
            device.notes.push("AMD NPU client activity: busiest observed readable client, from drm-engine-npu busy nanoseconds. Clients may overlap and are not summed. This is driver-accounted submitted work, not device-wide occupancy, TOPS or inference throughput.".into());
            if scan.partial || nodes_partial || clients.len() > 256 {
                device.notes.push("AMD NPU client scan is partial (permissions, transient records or limits); unreadable clients are not assumed idle".into());
            }
            if waiting {
                device
                    .notes
                    .push("AMD NPU client counters need another valid monotonic interval".into());
            }
        }
        self.previous.retain(|key, _| seen.contains(key));
    }
}
