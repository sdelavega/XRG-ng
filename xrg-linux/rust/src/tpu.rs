// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! TPU/NPU inventory and externally reported inference statistics. Detection does
//! not prove usable inference, and producer counters are not device utilization.
mod npu;
use crate::{
    hardware::{self, Readings, short_label},
    system_file,
};
pub use npu::parse_rockchip_load;
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
const MAX_AGE: f64 = 30.;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    Coral,
    Intel,
    Amd,
    Apple,
    Rockchip,
    Qualcomm,
    QualcommCloud,
    ArmEthos,
    NvidiaDla,
    Samsung,
    MediaTek,
}
impl Family {
    pub fn name(self) -> &'static str {
        match self {
            Self::Coral => "Coral Edge TPU",
            Self::Intel => "Intel NPU",
            Self::Amd => "AMD XDNA NPU",
            Self::Apple => "Apple Neural Engine",
            Self::Rockchip => "Rockchip NPU",
            Self::Qualcomm => "Qualcomm Hexagon / compute DSP",
            Self::QualcommCloud => "Qualcomm Cloud AI",
            Self::ArmEthos => "Arm Ethos NPU",
            Self::NvidiaDla => "NVIDIA DLA",
            Self::Samsung => "Samsung Exynos NPU",
            Self::MediaTek => "MediaTek APU",
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Device {
    pub id: String,
    pub label: String,
    pub initialized: bool,
    pub suspended: bool,
    pub temperature_c: Option<f64>,
    pub family: Family,
    pub driver: Option<String>,
    /// Known SoC capability only, not an enumerated Linux accelerator endpoint.
    pub capability_only: bool,
    pub utilization: Option<f64>,
    pub frequency_mhz: Option<f64>,
    pub memory_bytes: Option<u64>,
    pub notes: Vec<String>,
    pub busy_time_us: Option<u64>,
}
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Categories {
    #[serde(default)]
    pub direct: Option<u64>,
    #[serde(default)]
    pub hooked: Option<u64>,
    #[serde(default)]
    pub logged: Option<u64>,
    #[serde(default)]
    pub warming: Option<u64>,
}
#[derive(Clone, Debug, Deserialize, PartialEq)]
pub struct Stats {
    pub total_inferences: u64,
    pub last_latency_ms: Option<f64>,
    pub avg_latency_ms: Option<f64>,
    pub model_name: Option<String>,
    pub timestamp: Option<f64>,
    pub temperature: Option<f64>,
    pub by_category: Option<Categories>,
    /// Optional extension for detecting producer restarts before counters decrease.
    pub session_id: Option<String>,
}
impl Stats {
    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        if bytes.len() > 65_536 {
            return Err("TPU statistics exceed 64 KiB".into());
        }
        let mut value: Self =
            serde_json::from_slice(bytes).map_err(|e| format!("Invalid TPU statistics: {e}"))?;
        for latency in [value.last_latency_ms, value.avg_latency_ms]
            .into_iter()
            .flatten()
        {
            if !latency.is_finite() || latency < 0. {
                return Err("Invalid TPU latency".into());
            }
        }
        if value.timestamp.is_some_and(|v| !v.is_finite() || v < 0.) {
            return Err("Invalid TPU timestamp".into());
        }
        if value
            .temperature
            .is_some_and(|v| !v.is_finite() || !(-273.15..=300.).contains(&v))
        {
            return Err("Invalid TPU producer temperature".into());
        }
        if value.session_id.as_ref().is_some_and(|s| s.len() > 1024) {
            return Err("TPU producer session identity too long".into());
        }
        value.model_name = value.model_name.map(|s| short_label(&s));
        Ok(value)
    }
}
#[derive(Debug)]
pub struct Inference {
    pub stats: Stats,
    pub rate: Option<f64>,
    pub age_seconds: f64,
}
#[derive(Debug)]
pub struct Report {
    pub devices: Result<Readings<Device>, String>,
    pub inference: Result<Inference, String>,
}
struct Baseline {
    total: u64,
    time: f64,
    session: Option<String>,
}
pub struct Collector {
    sys: PathBuf,
    stats: Option<PathBuf>,
    previous: Option<Baseline>,
    activity: npu::Activity,
    start: Instant,
}
impl Collector {
    pub fn new(sys: PathBuf, stats: Option<PathBuf>) -> Self {
        Self {
            sys,
            stats,
            previous: None,
            activity: npu::Activity::default(),
            start: Instant::now(),
        }
    }
    pub fn sample(&mut self) -> Report {
        self.sample_at(self.start.elapsed().as_secs_f64(), SystemTime::now())
    }
    pub fn sample_at(&mut self, time: f64, wall: SystemTime) -> Report {
        let mut devices = discover(&self.sys);
        self.activity.update(&mut devices, time);
        let inference = self.read(time, wall);
        if inference.is_err() {
            self.previous = None;
        }
        Report { devices, inference }
    }
    fn read(&mut self, time: f64, wall: SystemTime) -> Result<Inference, String> {
        if !time.is_finite() || time < 0. {
            return Err("Invalid TPU sample time".into());
        }
        let path = self
            .stats
            .as_ref()
            .ok_or("TPU producer statistics are not configured")?;
        // Check both metadata and producer timestamp. A leftover file must not
        // continue presenting a disconnected/stopped producer as idle hardware.
        let before = fs::symlink_metadata(path)
            .map_err(|e| format!("TPU producer statistics unavailable: {e}"))?;
        if !before.is_file() {
            return Err("TPU statistics must be a regular file, without symlinks".into());
        }
        let bytes = system_file::read(path, 65_536).map_err(|e| e.to_string())?;
        let after = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
        if stamp(&before) != stamp(&after) {
            return Err("TPU statistics changed while reading; retrying".into());
        }
        let stats = Stats::parse(&bytes)?;
        let now = wall
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "Invalid wall clock")?
            .as_secs_f64();
        let modified = after
            .modified()
            .map_err(|e| e.to_string())?
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "Invalid file timestamp")?
            .as_secs_f64();
        let age = now - stats.timestamp.unwrap_or(modified);
        let modified_age = now - modified;
        if age < -5. || modified_age < -5. {
            return Err("TPU statistics timestamp is in the future".into());
        }
        if age > MAX_AGE || modified_age > MAX_AGE {
            return Err("TPU producer statistics are stale (over 30 seconds)".into());
        }
        let rate = self
            .previous
            .as_ref()
            .filter(|p| time > p.time && p.session == stats.session_id)
            .and_then(|p| {
                stats
                    .total_inferences
                    .checked_sub(p.total)
                    .map(|delta| delta as f64 / (time - p.time))
            })
            .filter(|v| v.is_finite());
        if self.previous.as_ref().is_none_or(|p| time > p.time) {
            self.previous = Some(Baseline {
                total: stats.total_inferences,
                time,
                session: stats.session_id.clone(),
            });
        }
        Ok(Inference {
            stats,
            rate,
            age_seconds: age.max(0.),
        })
    }
}
fn stamp(m: &fs::Metadata) -> (u64, u64, u64, i64, i64, i64, i64) {
    (
        m.dev(),
        m.ino(),
        m.len(),
        m.mtime(),
        m.mtime_nsec(),
        m.ctime(),
        m.ctime_nsec(),
    )
}
fn attr(path: &Path, name: &str) -> Result<Option<String>, String> {
    hardware::text(&path.join(name))
}
fn id(path: &Path, name: &str) -> Result<Option<u16>, String> {
    attr(path, name)?
        .map(|s| {
            u16::from_str_radix(s.trim_start_matches("0x"), 16)
                .map_err(|_| format!("Invalid TPU {name}"))
        })
        .transpose()
}
fn coral_pci(path: &Path) -> Result<bool, String> {
    Ok(id(path, "vendor")? == Some(0x1ac1) && id(path, "device")? == Some(0x089a))
}
fn canonical(path: &Path) -> Result<String, String> {
    fs::canonicalize(path)
        .map(|p| p.to_string_lossy().into_owned())
        .map_err(|e| e.to_string())
}
fn note(errors: &mut Vec<String>, error: String) {
    if errors.len() < 32 {
        errors.push(error);
    }
}
/// Uses read-only sysfs attributes. Never opens /dev/apex*, USB devices, BARs or
/// performance/clock-gating controls; discovery cannot reset or initialize a TPU/NPU.
pub fn discover(sys: &Path) -> Result<Readings<Device>, String> {
    if !sys.is_dir() {
        return Err("TPU sysfs root unavailable".into());
    }
    let start = Instant::now();
    let mut found = BTreeMap::new();
    let mut errors = Vec::new();
    for (kind, root) in [
        (0, "bus/usb/devices"),
        (1, "bus/pci/devices"),
        (2, "class/apex"),
    ] {
        let paths = match hardware::directories(&sys.join(root)) {
            Ok(v) => v,
            Err(e) => {
                note(&mut errors, e);
                continue;
            }
        };
        for path in paths {
            if start.elapsed() > Duration::from_millis(100) {
                note(&mut errors, "TPU discovery time budget reached".into());
                break;
            }
            let result = (|| -> Result<(), String> {
                if kind == 0 {
                    let vendor = id(&path, "idVendor")?;
                    let product = id(&path, "idProduct")?;
                    let initialized = match (vendor, product) {
                        (Some(0x1a6e), Some(0x089a)) => false,
                        (Some(0x18d1), Some(0x9302)) => true,
                        _ => return Ok(()),
                    };
                    let identity = canonical(&path)?;
                    let label = format!(
                        "Coral USB · {}",
                        path.file_name().unwrap_or_default().to_string_lossy()
                    );
                    found.entry(identity.clone()).or_insert(Device {
                        id: identity,
                        label,
                        initialized,
                        suspended: attr(&path, "power/runtime_status")?.as_deref()
                            == Some("suspended"),
                        temperature_c: None,
                        family: Family::Coral,
                        driver: None,
                        capability_only: false,
                        utilization: None,
                        frequency_mhz: None,
                        memory_bytes: None,
                        notes: Vec::new(),
                        busy_time_us: None,
                    });
                } else {
                    let physical = if kind == 2 {
                        let name = path.file_name().unwrap_or_default().to_string_lossy();
                        if !name
                            .strip_prefix("apex_")
                            .is_some_and(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
                        {
                            return Ok(());
                        }
                        fs::canonicalize(path.join("device")).map_err(|e| e.to_string())?
                    } else {
                        path.clone()
                    };
                    if !coral_pci(&physical)? {
                        return Ok(());
                    }
                    let identity = canonical(&physical)?;
                    let driver = fs::read_link(physical.join("driver"))
                        .ok()
                        .and_then(|p| p.file_name().map(|n| n == "apex"))
                        .unwrap_or(false);
                    let suspended = matches!(
                        attr(&physical, "power/runtime_status")?.as_deref(),
                        Some("suspended" | "suspending" | "resuming" | "error")
                    );
                    let device = found.entry(identity.clone()).or_insert(Device {
                        id: identity,
                        label: format!(
                            "Coral PCIe/M.2 · {}",
                            physical.file_name().unwrap_or_default().to_string_lossy()
                        ),
                        initialized: driver,
                        suspended,
                        temperature_c: None,
                        family: Family::Coral,
                        driver: driver.then(|| "apex".into()),
                        capability_only: false,
                        utilization: None,
                        frequency_mhz: None,
                        memory_bytes: None,
                        notes: Vec::new(),
                        busy_time_us: None,
                    });
                    if kind == 2
                        && driver
                        && !suspended
                        && let Some(value) = hardware::integer(&path.join("temp"))?
                    {
                        let c = value as f64 / 1000.;
                        if !(-273.15..=300.).contains(&c) {
                            return Err("Invalid apex temperature".into());
                        }
                        device.temperature_c = Some(c);
                    }
                }
                Ok(())
            })();
            if let Err(error) = result {
                note(&mut errors, format!("{}: {error}", path.display()));
            }
        }
    }
    npu::extend(sys, start, &mut found, &mut errors);
    Ok(Readings {
        values: found.into_values().collect(),
        errors,
    })
}
