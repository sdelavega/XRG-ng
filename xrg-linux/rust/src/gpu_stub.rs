// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux stub for the GPU collector. Discovery, sysfs/DRM telemetry,
//! perf counters and the NVIDIA query are all Linux interfaces, so sampling
//! reports "unavailable" and no adapter is ever invented. The crate-visible
//! API shape of the Linux module is kept so callers compile unchanged; the
//! pure PCI-address parser is shared logic and behaves identically.
#![allow(dead_code)]

use crate::hardware::Readings;
use std::{path::PathBuf, time::Instant};

pub const IMPLEMENTATION: &str = "stub";

#[derive(Clone, Debug)]
pub struct EngineActivity {
    pub percent: f64,
    pub engines: Vec<(String, f64)>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActivitySource {
    Device,
    Engines,
    Clients,
}
impl ActivitySource {
    pub fn suffix(self) -> &'static str {
        match self {
            Self::Device => "",
            Self::Engines => " PMU",
            Self::Clients => " clients",
        }
    }
}
#[derive(Clone, Debug, Default)]
pub struct Gpu {
    pub id: String,
    pub label: String,
    pub name: String,
    pub driver: String,
    pub utilization: Option<f64>,
    pub engine_activity: Option<EngineActivity>,
    pub memory_used: Option<u64>,
    pub memory_total: Option<u64>,
    pub client_activity: Option<f64>,
    pub client_resident_bytes: Option<u64>,
    pub visible_clients: Option<usize>,
    pub temperature: Option<f64>,
    pub power_watts: Option<f64>,
    pub frequency_mhz: Option<f64>,
    pub fan_rpm: Option<u64>,
    pub fan_percent: Option<f64>,
    pub notes: Vec<String>,
}
impl Gpu {
    pub fn activity(&self) -> Option<(ActivitySource, f64)> {
        self.utilization
            .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
            .map(|v| (ActivitySource::Device, v))
            .or_else(|| {
                self.engine_activity
                    .as_ref()
                    .filter(|v| v.percent.is_finite() && (0.0..=100.0).contains(&v.percent))
                    .map(|v| (ActivitySource::Engines, v.percent))
            })
            .or_else(|| {
                self.client_activity
                    .filter(|v| v.is_finite() && (0.0..=100.0).contains(v))
                    .map(|v| (ActivitySource::Clients, v))
            })
    }
}

pub fn pci_id(value: &str) -> Option<String> {
    let fields: Vec<_> = value.trim().split([':', '.']).collect();
    if fields.len() != 4
        || fields
            .iter()
            .any(|s| s.is_empty() || !s.bytes().all(|c| c.is_ascii_hexdigit()))
    {
        return None;
    }
    let domain = u32::from_str_radix(fields[0], 16).ok()?;
    let bus = u8::from_str_radix(fields[1], 16).ok()?;
    let device = u8::from_str_radix(fields[2], 16).ok()?;
    let function = u8::from_str_radix(fields[3], 16).ok()?;
    if device > 31 || function > 7 {
        return None;
    }
    Some(format!("{domain:04x}:{bus:02x}:{device:02x}.{function}"))
}

pub fn parse_nvidia(text: &str) -> Readings<Gpu> {
    let _ = text;
    Readings {
        values: Vec::new(),
        errors: vec!["NVIDIA query parsing requires the Linux collector".into()],
    }
}

pub fn find_nvidia_smi() -> Option<PathBuf> {
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .filter(|path| path.is_absolute())
        .map(|p| p.join("nvidia-smi"))
        .find(|p| p.is_file())
}

pub struct GpuCollector {
    program: Option<PathBuf>,
}
impl GpuCollector {
    /// Custom roots do not execute commands unless a program is explicitly supplied.
    pub fn new(sys: impl Into<PathBuf>, nvidia_program: Option<PathBuf>) -> Self {
        let _ = sys;
        Self {
            program: nvidia_program,
        }
    }
    pub fn set_xe_pmu(&mut self, enabled: bool) {
        let _ = enabled;
    }
    pub fn with_proc_root(self, proc: impl Into<PathBuf>) -> Self {
        let _ = proc.into();
        self
    }
    pub fn sample(&mut self) -> Result<Readings<Gpu>, String> {
        self.sample_at(Instant::now())
    }
    pub fn sample_at(&mut self, time: Instant) -> Result<Readings<Gpu>, String> {
        let _ = (time, &self.program);
        Err("GPU telemetry requires Linux sysfs/DRM".into())
    }
}
