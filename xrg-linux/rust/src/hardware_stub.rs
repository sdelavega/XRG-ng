// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Non-Linux stub for kernel sysfs collection. There is no sysfs off Linux,
//! so every scan returns the module's existing "nothing found" reading (an
// empty list, never a zero or invented measurement) and attribute helpers
//! report values as absent, exactly as Linux does for a machine without the
//! corresponding sysfs class. The reading types keep the field-for-field
//! shape of the Linux module so presentation code compiles unchanged.
use std::path::{Path, PathBuf};

pub const IMPLEMENTATION: &str = "stub";

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
impl Battery {
    pub fn description(&self) -> String {
        let mut fields = vec![format!(
            "{}: {:.1}% · {}",
            self.name, self.percent, self.status
        )];
        if let Some(watts) = self.watts {
            fields.push(format!("Reported power: {watts:.1} W"));
        }
        if let Some(health) = self.health_percent {
            fields.push(format!("Reported full/design capacity: {health:.1}%"));
        }
        if let Some(condition) = &self.condition {
            fields.push(format!("Driver health: {condition}"));
        }
        if let Some(cycles) = self.cycles {
            fields.push(format!("Cycle count: {cycles}"));
        }
        if let Some(time) = self.time {
            let duration = if time.seconds < 60. {
                "<1 min".into()
            } else {
                let minutes = (time.seconds / 60.) as u64;
                format!("{} h {} min", minutes / 60, minutes % 60)
            };
            let source = match time.source {
                TimeSource::Driver => "driver reported",
                TimeSource::EnergyPower => "estimate from energy/power",
                TimeSource::ChargeCurrent => "estimate from charge/current",
            };
            let direction = if self.status == "Charging" {
                "full"
            } else {
                "empty"
            };
            fields.push(format!(
                "Time to {direction}: {duration} ({source}; changes with load/charge rate)"
            ));
        } else {
            fields.push("Time estimate unavailable".into());
        }
        fields.extend(self.notes.clone());
        fields.join("\n")
    }
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TimeSource {
    Driver,
    EnergyPower,
    ChargeCurrent,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BatteryTime {
    pub seconds: f64,
    pub source: TimeSource,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Temperature {
    pub id: String,
    pub source_id: String,
    pub thermal: bool,
    pub name: String,
    pub celsius: f64,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Fan {
    pub id: String,
    pub source_id: String,
    pub name: String,
    pub rpm: u64,
    pub alarm: Option<bool>,
    pub notes: Vec<String>,
}

pub fn batteries(_sys: &Path) -> Result<Readings<Battery>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub fn temperatures(_sys: &Path) -> Result<Readings<Temperature>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub fn temperature_sources(_sys: &Path) -> Result<Readings<Temperature>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub fn fans(_sys: &Path) -> Result<Readings<Fan>, String> {
    Ok(Readings {
        values: Vec::new(),
        errors: Vec::new(),
    })
}
pub(crate) fn text(_path: &Path) -> Result<Option<String>, String> {
    // No sysfs exists off Linux; an attribute is absent, not unreadable.
    Ok(None)
}
pub(crate) fn integer(_path: &Path) -> Result<Option<i64>, String> {
    // Attribute values are absent off Linux (see `text`); never invented.
    Ok(None)
}
pub(crate) fn directories(_path: &Path) -> Result<Vec<PathBuf>, String> {
    Ok(Vec::new())
}
pub(crate) fn short_label(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(64).collect()
}
#[allow(dead_code)] // Retained for API parity with the Linux module.
pub(crate) fn celsius(value: i64) -> Result<f64, String> {
    // Reject physically impossible values/sentinels; zero and negative readings
    // are valid. Kernel hwmon/thermal temperature inputs are millidegrees Celsius.
    if !(-273_150..=1_000_000).contains(&value) {
        return Err("Temperature out of range".into());
    }
    Ok(value as f64 / 1000.)
}
