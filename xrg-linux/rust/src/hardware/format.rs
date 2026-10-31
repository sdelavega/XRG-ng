// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Portable hardware reading types and presentation formatting shared by the
//! Linux sysfs collector and its stub twin, so battery descriptions, labels
//! and temperature conversion can never diverge between platforms. The types
//! keep the exact field shape of the Linux collector so presentation code
//! compiles unchanged everywhere.
#[allow(dead_code)] // `celsius` only feeds the Linux thermal-zone scan; off Linux it is API parity.
pub fn celsius(value: i64) -> Result<f64, String> {
    // Reject physically impossible values/sentinels; zero and negative readings
    // are valid. Kernel hwmon/thermal temperature inputs are millidegrees Celsius.
    if !(-273_150..=1_000_000).contains(&value) {
        return Err("Temperature out of range".into());
    }
    Ok(value as f64 / 1000.)
}
pub fn short_label(text: &str) -> String {
    text.chars().filter(|c| !c.is_control()).take(64).collect()
}

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

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn celsius_converts_millidegrees_and_rejects_impossible_values() {
        assert_eq!(celsius(0).unwrap(), 0.);
        assert_eq!(celsius(-40_000).unwrap(), -40.);
        assert_eq!(celsius(25_500).unwrap(), 25.5);
        assert!(celsius(-273_151).is_err());
        assert!(celsius(1_000_001).is_err());
    }
    #[test]
    fn short_label_strips_control_characters_and_bounds_the_length() {
        assert_eq!(short_label("abc\r\n"), "abc");
        assert_eq!(short_label(""), "");
        assert_eq!(short_label(&"y".repeat(100)).len(), 64);
    }
    #[test]
    fn battery_description_lists_every_present_field() {
        let battery = Battery {
            name: "BAT0".into(),
            percent: 50.,
            status: "Charging".into(),
            watts: Some(10.),
            health_percent: Some(90.),
            condition: Some("healthy".into()),
            cycles: Some(12),
            time: Some(BatteryTime {
                seconds: 120.,
                source: TimeSource::EnergyPower,
            }),
            notes: vec!["note".into()],
        };
        let text = battery.description();
        assert!(text.contains("BAT0: 50.0% · Charging"));
        assert!(text.contains("Reported power: 10.0 W"));
        assert!(text.contains("Reported full/design capacity: 90.0%"));
        assert!(text.contains("Driver health: healthy"));
        assert!(text.contains("Cycle count: 12"));
        assert!(text.contains("Time to full: 0 h 2 min"));
        assert!(text.contains("estimate from energy/power"));
        assert!(text.contains("note"));
        let bare = Battery {
            name: "BAT1".into(),
            percent: 0.,
            status: "Unknown".into(),
            watts: None,
            health_percent: None,
            condition: None,
            cycles: None,
            time: None,
            notes: Vec::new(),
        };
        assert!(bare.description().contains("Time estimate unavailable"));
    }
}
