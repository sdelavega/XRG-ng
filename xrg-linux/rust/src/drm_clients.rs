// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Bounded read-only DRM fdinfo scan shared by GPU and accelerator collectors.
/// The Linux implementation of the DRM client scan.
pub const IMPLEMENTATION: &str = "linux";
use std::{
    collections::BTreeMap,
    fs, io,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
#[derive(Debug)]
pub(crate) struct Client {
    pub(crate) driver: String,
    pub(crate) id: u64,
    pub(crate) engines: BTreeMap<String, (Counter, u64)>,
    pub(crate) resident: Option<u64>,
    pub(crate) frequency: Option<u64>,
}
#[derive(Clone, Copy, Debug)]
pub(crate) enum Counter {
    Nanoseconds(u64),
    Cycles { busy: u64, total: u64 },
}
impl Counter {
    pub(crate) fn busy(self) -> u64 {
        match self {
            Self::Nanoseconds(value) | Self::Cycles { busy: value, .. } => value,
        }
    }
    pub(crate) fn same_kind(self, other: Self) -> bool {
        matches!(
            (self, other),
            (Self::Nanoseconds(_), Self::Nanoseconds(_))
                | (Self::Cycles { .. }, Self::Cycles { .. })
        )
    }
    pub(crate) fn percent(self, previous: Self, elapsed: Duration, capacity: u64) -> Option<f64> {
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
    let expected = crate::gpu::pci_id(gpu_id).or_else(|| {
        Path::new(gpu_id)
            .file_name()
            .and_then(|v| v.to_str())
            .and_then(crate::gpu::pci_id)
    });
    if let Some(expected) = expected {
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
pub(crate) struct Scan {
    pub(crate) values: BTreeMap<(String, u64), Client>,
    pub(crate) partial: bool,
}
pub(crate) fn scan(
    proc: &Path,
    nodes: &BTreeMap<PathBuf, (String, String)>,
    driver_matches: fn(&str, &str) -> bool,
) -> Result<Scan, String> {
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
            let Some((gpu_id, expected_driver)) = nodes.get(&link) else {
                continue;
            };
            let read = || -> Result<Client, String> {
                let bytes =
                    crate::system_file::read(&file.path(), 65_536).map_err(|e| e.to_string())?;
                let text = String::from_utf8(bytes).map_err(|_| "Invalid DRM client encoding")?;
                let client = parse(&text, gpu_id)?;
                if !driver_matches(expected_driver, &client.driver) {
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
