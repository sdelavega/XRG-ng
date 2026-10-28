// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Read-only kernel sysfs collection. Paths are injectable for hardware fixtures.
//! Values follow the power_supply and hwmon kernel ABIs; no subprocesses are used.
mod battery;
mod fans;
mod sensor_identity;
pub(crate) mod temperature;
pub use battery::{BatteryTime, TimeSource};
pub use fans::{Fan, fans};
use std::{
    fs::{self, OpenOptions},
    io::{self, Read},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

#[derive(Debug)]
pub struct Readings<T> {
    pub values: Vec<T>,
    pub errors: Vec<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Battery {
    pub name: String,
    pub percent: f64,
    pub status: String,
    pub watts: Option<f64>,
    pub health_percent: Option<f64>,
    pub condition: Option<String>,
    pub cycles: Option<u64>,
    pub time: Option<BatteryTime>,
    pub notes: Vec<String>,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Temperature {
    pub id: String,
    pub source_id: String,
    pub thermal: bool,
    pub name: String,
    pub celsius: f64,
}

pub(crate) fn text(path: &Path) -> Result<Option<String>, String> {
    let file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK)
        .open(path)
    {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    if !file.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err(format!("{}: expected a regular attribute", path.display()));
    }
    let mut bytes = Vec::new();
    file.take(4097)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    if bytes.len() > 4096 {
        return Err(format!("{}: oversized attribute", path.display()));
    }
    String::from_utf8(bytes)
        .map(|s| Some(s.trim().to_owned()))
        .map_err(|_| format!("{}: invalid UTF-8", path.display()))
}
pub(crate) fn integer(path: &Path) -> Result<Option<i64>, String> {
    text(path)?
        .map(|s| {
            s.parse()
                .map_err(|_| format!("{}: invalid integer", path.display()))
        })
        .transpose()
}
pub(crate) fn directories(path: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    let mut paths = entries
        .take(4097)
        .map(|entry| entry.map(|e| e.path()).map_err(|e| e.to_string()))
        .collect::<Result<Vec<_>, _>>()?;
    if paths.len() > 4096 {
        return Err(format!("{}: too many entries", path.display()));
    }
    paths.sort();
    Ok(paths)
}
pub(crate) fn short_label(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(64).collect()
}
pub fn batteries(sys: &Path) -> Result<Readings<Battery>, String> {
    let mut result = Readings {
        values: Vec::new(),
        errors: Vec::new(),
    };
    for directory in directories(&sys.join("class/power_supply"))? {
        let name = directory
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        // Skip HID/HID++ *before any attribute reads*: status/type can block on
        // sleeping or disconnected Bluetooth devices. Also skip scope=Device.
        if name.to_ascii_lowercase().starts_with("hid") {
            continue;
        }
        let read = || -> Result<Option<Battery>, String> {
            if text(&directory.join("scope"))?.as_deref() == Some("Device") {
                return Ok(None);
            }
            if text(&directory.join("type"))?.as_deref() != Some("Battery") {
                return Ok(None);
            }
            if integer(&directory.join("present"))? == Some(0) {
                return Ok(None);
            }
            battery::read(&directory, short_label(&name)).map(Some)
        };
        match read() {
            Ok(Some(value)) => result.values.push(value),
            Ok(None) => (),
            Err(error) => result.errors.push(format!("{name}: {error}")),
        }
    }
    Ok(result)
}
pub(crate) fn celsius(value: i64) -> Result<f64, String> {
    // Reject physically impossible values/sentinels; zero and negative readings
    // are valid. Kernel hwmon/thermal temperature inputs are millidegrees Celsius.
    if !(-273_150..=1_000_000).contains(&value) {
        return Err("Temperature out of range".into());
    }
    Ok(value as f64 / 1000.)
}
struct TemperatureBudget {
    start: std::time::Instant,
    attempted: usize,
}
impl TemperatureBudget {
    fn check(&self) -> Result<(), String> {
        if self.attempted >= 256 || self.start.elapsed() >= std::time::Duration::from_millis(100) {
            Err("Temperature scan limit reached; coverage is partial".into())
        } else {
            Ok(())
        }
    }
    fn attempt(&mut self) -> Result<(), String> {
        self.check()?;
        self.attempted += 1;
        Ok(())
    }
}
fn hwmon(
    sys: &Path,
    directory: &Path,
    result: &mut Readings<Temperature>,
    budget: &mut TemperatureBudget,
) -> Result<(), String> {
    let chip_name = text(&directory.join("name"))?;
    let chip = short_label(chip_name.as_deref().unwrap_or("hwmon"));
    let device = directory.file_name().unwrap().to_string_lossy();
    for input in directories(directory)? {
        let file = input.file_name().unwrap().to_string_lossy();
        let Some(channel) = file
            .strip_prefix("temp")
            .and_then(|s| s.strip_suffix("_input"))
        else {
            continue;
        };
        if channel.is_empty() || !channel.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        budget.attempt()?;
        let read = || -> Result<Option<Temperature>, String> {
            let (source_id, id) = sensor_identity::identity(sys, directory, &input, &chip)?;
            let Some(value) = temperature::read(directory, channel)? else {
                return Ok(None);
            };
            if value.chip != chip_name {
                return Err("Temperature chip changed during scan".into());
            }
            let label = text(&directory.join(format!("temp{channel}_label")))?
                .unwrap_or_else(|| format!("temp{channel}"));
            if sensor_identity::identity(sys, directory, &input, &chip)?.1 != id {
                return Err("Temperature sensor changed during read".into());
            }
            Ok(Some(Temperature {
                id: format!("{id}:type={:?}", value.kind),
                source_id,
                thermal: false,
                name: format!(
                    "{chip} ({device}) · {} [temp{channel}]",
                    short_label(&label)
                ),
                celsius: value.celsius,
            }))
        };
        match read() {
            Ok(Some(value)) => result.values.push(value),
            Ok(None) => (),
            Err(error) => result.errors.push(format!("{chip}/{file}: {error}")),
        }
    }
    Ok(())
}
pub fn temperatures(sys: &Path) -> Result<Readings<Temperature>, String> {
    collect_temperatures(sys, false)
}
pub fn temperature_sources(sys: &Path) -> Result<Readings<Temperature>, String> {
    collect_temperatures(sys, true)
}
fn collect_temperatures(sys: &Path, all: bool) -> Result<Readings<Temperature>, String> {
    let mut result = Readings {
        values: Vec::new(),
        errors: Vec::new(),
    };
    let mut budget = TemperatureBudget {
        start: std::time::Instant::now(),
        attempted: 0,
    };
    for directory in directories(&sys.join("class/hwmon"))? {
        if let Err(error) = budget.check() {
            result.errors.push(error);
            break;
        }
        if let Err(error) = hwmon(sys, &directory, &mut result, &mut budget) {
            result.errors.push(error);
        }
    }
    // Avoid duplicate hwmon/thermal readings. Thermal zones are a fallback for
    // machines whose kernel exposes no usable hwmon temperatures.
    if (all || result.values.is_empty())
        && let Err(error) = budget.check()
    {
        result.errors.push(error);
    }
    if (all || result.values.is_empty()) && budget.check().is_ok() {
        for directory in directories(&sys.join("class/thermal"))? {
            let name = directory.file_name().unwrap().to_string_lossy();
            if !name.starts_with("thermal_zone") {
                continue;
            }
            if let Err(error) = budget.attempt() {
                result.errors.push(error);
                break;
            }
            let read = || -> Result<Temperature, String> {
                let kind = text(&directory.join("type"))?;
                // A display fallback may contain class numbering; never use it
                // as device metadata or aliases would acquire different IDs.
                let chip = short_label(kind.as_deref().unwrap_or("thermal"));
                let label = kind.unwrap_or_else(|| name.to_string());
                let (source_id, id) =
                    sensor_identity::identity(sys, &directory, &directory.join("temp"), &chip)?;
                let value =
                    integer(&directory.join("temp"))?.ok_or("Missing thermal temperature")?;
                if sensor_identity::identity(sys, &directory, &directory.join("temp"), &chip)?.1
                    != id
                {
                    return Err("Thermal sensor changed during read".into());
                }
                Ok(Temperature {
                    id,
                    source_id,
                    thermal: true,
                    name: format!("{} ({name})", short_label(&label)),
                    celsius: celsius(value)?,
                })
            };
            match read() {
                Ok(value) => result.values.push(value),
                Err(error) => result.errors.push(error),
            }
        }
    }
    result.values.sort_by(|a, b| a.id.cmp(&b.id));
    result.values.dedup_by(|a, b| a.id == b.id);
    let mut counts = std::collections::BTreeMap::new();
    for value in &result.values {
        *counts.entry(value.source_id.clone()).or_insert(0usize) += 1;
    }
    result.values.retain(|value| counts[&value.source_id] == 1);
    if counts.values().any(|n| *n > 1) {
        result
            .errors
            .push("Ambiguous temperature source identities omitted".into());
    }
    result.values.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(result)
}
