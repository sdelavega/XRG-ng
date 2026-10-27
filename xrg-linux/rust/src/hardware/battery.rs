// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use super::{Battery, integer, short_label, text};
use std::path::Path;

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
fn pair(directory: &Path, prefix: &str) -> Result<Option<(i64, i64)>, String> {
    let now = integer(&directory.join(format!("{prefix}_now")))?;
    let full = integer(&directory.join(format!("{prefix}_full")))?;
    match (now, full) {
        (Some(now), Some(full)) if now >= 0 && full > 0 && now <= full => Ok(Some((now, full))),
        (Some(_), Some(_)) => Err(format!("Invalid {prefix} counters")),
        _ => Ok(None),
    }
}
fn optional(directory: &Path, field: &str, notes: &mut Vec<String>) -> Option<i64> {
    match integer(&directory.join(field)) {
        Ok(value) => value,
        Err(error) => {
            notes.push(error);
            None
        }
    }
}
fn health(directory: &Path, notes: &mut Vec<String>) -> Option<f64> {
    for prefix in ["energy", "charge"] {
        let full = optional(directory, &format!("{prefix}_full"), notes);
        let design = optional(directory, &format!("{prefix}_full_design"), notes);
        if let (Some(full), Some(design)) = (full, design) {
            if full > 0 && design > 0 {
                // New batteries can exceed their design rating. Preserve that
                // reported ratio rather than clamping it to 100 percent.
                return Some(100. * full as f64 / design as f64);
            }
            notes.push(format!("Invalid {prefix} full/design capacity"));
        }
    }
    None
}
pub(super) fn read(directory: &Path, name: String) -> Result<Battery, String> {
    let energy = pair(directory, "energy")?;
    // Preserve the original preferred energy capacity, even if charge metadata
    // is broken; alternate units are only read when needed for capacity/time.
    let charge = if energy.is_none() {
        pair(directory, "charge")?
    } else {
        None
    };
    let percent = if let Some((now, full)) = energy.or(charge) {
        now as f64 / full as f64 * 100.
    } else {
        let capacity = integer(&directory.join("capacity"))?.ok_or("Missing battery capacity")?;
        if !(0..=100).contains(&capacity) {
            return Err("Invalid battery capacity".into());
        }
        capacity as f64
    };
    let status = text(&directory.join("status"))?.unwrap_or_else(|| "Unknown".into());
    let status = match status.as_str() {
        "Charging" | "Discharging" | "Full" | "Not charging" => status,
        _ => "Unknown".into(),
    };
    let mut notes = Vec::new();
    let power = optional(directory, "power_now", &mut notes).map(|v| (v as f64).abs());
    let current = optional(directory, "current_now", &mut notes).map(|v| (v as f64).abs());
    let voltage = optional(directory, "voltage_now", &mut notes).filter(|v| *v > 0);
    let watts = power.map(|v| v / 1_000_000.).or_else(|| {
        current
            .zip(voltage)
            .map(|(a, v)| a * v as f64 / 1_000_000_000_000.)
    });
    let health_percent = health(directory, &mut notes);
    let cycles = optional(directory, "cycle_count", &mut notes).and_then(|v| {
        if v >= 0 {
            Some(v as u64)
        } else {
            notes.push("Invalid cycle count".into());
            None
        }
    });
    let condition = match text(&directory.join("health")) {
        Ok(value) => value.map(|v| short_label(&v)).filter(|v| !v.is_empty()),
        Err(error) => {
            notes.push(error);
            None
        }
    };
    let time = if status == "Charging" || status == "Discharging" {
        let field = if status == "Charging" {
            "time_to_full_now"
        } else {
            "time_to_empty_now"
        };
        let reported = optional(directory, field, &mut notes).filter(|v| {
            if *v >= 0 {
                true
            } else {
                notes.push(format!("Invalid {field}"));
                false
            }
        });
        if let Some(seconds) = reported.filter(|s| {
            *s > 0
                || (status == "Discharging" && percent == 0.)
                || (status == "Charging" && percent == 100.)
        }) {
            Some(BatteryTime {
                seconds: seconds as f64,
                source: TimeSource::Driver,
            })
        } else {
            let remaining = |(now, full): (i64, i64)| {
                if status == "Charging" {
                    full - now
                } else {
                    now
                }
            };
            // Use complete matching units only; current polarity varies by driver,
            // so the explicit status selects time-to-full versus time-to-empty.
            let energy_time = energy
                .zip(power.filter(|p| *p > 0.))
                .map(|(pair, p)| (3600. * remaining(pair) as f64 / p, TimeSource::EnergyPower));
            let charge_time = || {
                let charge = charge.or_else(|| match pair(directory, "charge") {
                    Ok(value) => value,
                    Err(error) => {
                        notes.push(error);
                        None
                    }
                });
                charge.zip(current.filter(|a| *a > 0.)).map(|(pair, a)| {
                    (
                        3600. * remaining(pair) as f64 / a,
                        TimeSource::ChargeCurrent,
                    )
                })
            };
            energy_time
                .or_else(charge_time)
                .and_then(|(seconds, source)| {
                    (seconds.is_finite() && seconds >= 0. && seconds < u64::MAX as f64)
                        .then_some(BatteryTime { seconds, source })
                })
        }
    } else {
        None
    };
    Ok(Battery {
        name,
        percent,
        status,
        watts,
        health_percent,
        condition,
        cycles,
        time,
        notes,
    })
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
