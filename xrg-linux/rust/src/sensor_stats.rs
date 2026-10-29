// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Session statistics for every readable temperature/fan input, independent of
//! graph selection. Statistics are sample-weighted, not time-weighted.
use crate::{
    hardware::{Fan, Readings, Temperature},
    temperature::Units,
};
use std::collections::BTreeMap;
const LIMIT: usize = 4096;
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Kind {
    Temperature,
    Fan,
}
#[derive(Clone, Debug)]
pub struct Row {
    pub kind: Kind,
    pub source_id: String,
    pub incarnation: String,
    pub name: String,
    pub current: Option<f64>,
    pub minimum: f64,
    pub average: f64,
    pub maximum: f64,
    pub samples: u64,
}
impl Row {
    pub fn display(&self, value: Option<f64>, units: Units) -> String {
        value
            .map(|v| match self.kind {
                Kind::Temperature => format!(
                    "{:.1} °{}",
                    units.convert_celsius(v),
                    if units == Units::Fahrenheit { "F" } else { "C" }
                ),
                Kind::Fan => format!("{v:.0} RPM"),
            })
            .unwrap_or_else(|| "n/a".into())
    }
}
#[derive(Clone, Debug, Default)]
pub struct Report {
    pub rows: Vec<Row>,
    pub errors: Vec<String>,
    pub elapsed_seconds: f64,
    pub generation: u64,
}
impl Report {
    pub fn text(&self, units: Units) -> String {
        use std::fmt::Write;
        let mut text = format!(
            "XRG-ng {} · Linux sensor report\nSession statistics: {:.1}s since start/reset · generation {}\nSample-weighted min / average / max. Missing current readings are n/a; historical values are retained. Replaced input incarnations start new statistics. Temperatures are stored in Celsius. No hardware controls are changed.\n",
            env!("CARGO_PKG_VERSION"),
            self.elapsed_seconds,
            self.generation
        );
        for row in &self.rows {
            let _ = writeln!(
                text,
                "\n{:?} · {:?}\nSource: {:?}\nIncarnation: {:?}\nCurrent: {} · Min: {} · Average: {} · Max: {} · Samples: {}",
                row.kind,
                row.name,
                row.source_id,
                row.incarnation,
                row.display(row.current, units),
                row.display(Some(row.minimum), units),
                row.display(Some(row.average), units),
                row.display(Some(row.maximum), units),
                row.samples
            );
        }
        if self.rows.is_empty() {
            text.push_str("\nNo sensor readings accumulated.\n");
        }
        for error in &self.errors {
            let _ = writeln!(text, "Collection note: {error:?}");
        }
        text
    }
}
#[derive(Default)]
pub(crate) struct Statistics {
    rows: BTreeMap<(Kind, String), Row>,
    errors: BTreeMap<Kind, Vec<String>>,
    started: Option<f64>,
    generation: u64,
}
impl Statistics {
    pub fn reset(&mut self) {
        self.rows.clear();
        self.errors.clear();
        self.started = None;
        self.generation = self.generation.wrapping_add(1);
    }
    fn begin(&mut self, kind: Kind, at: f64) {
        self.started.get_or_insert(at);
        for ((k, _), row) in &mut self.rows {
            if *k == kind {
                row.current = None;
            }
        }
        self.errors.insert(kind, Vec::new());
    }
    fn add(&mut self, kind: Kind, source: &str, id: &str, name: &str, value: f64) {
        if !value.is_finite() {
            self.note(kind, format!("Invalid non-finite reading: {name}"));
            return;
        }
        let key = (kind, source.to_owned());
        if !self.rows.contains_key(&key) && self.rows.len() >= LIMIT {
            self.note(
                kind,
                "Sensor statistics limit reached; coverage is partial".into(),
            );
            return;
        }
        let row = self.rows.entry(key).or_insert_with(|| Row {
            kind,
            source_id: source.into(),
            incarnation: id.into(),
            name: name.into(),
            current: None,
            minimum: value,
            maximum: value,
            average: value,
            samples: 0,
        });
        if row.incarnation != id {
            *row = Row {
                kind,
                source_id: source.into(),
                incarnation: id.into(),
                name: name.into(),
                current: None,
                minimum: value,
                maximum: value,
                average: value,
                samples: 0,
            };
        }
        row.name = name.into();
        row.current = Some(value);
        row.minimum = row.minimum.min(value);
        row.maximum = row.maximum.max(value);
        if let Some(n) = row.samples.checked_add(1) {
            // Weighted form avoids overflowing a running sum.
            row.average = row.average * (1. - 1. / n as f64) + value / n as f64;
            row.samples = n;
        }
    }
    fn note(&mut self, kind: Kind, error: String) {
        let errors = self.errors.entry(kind).or_default();
        if errors.len() < 64 && !errors.contains(&error) {
            errors.push(error);
        }
    }
    pub fn temperatures(&mut self, report: &Result<Readings<Temperature>, String>, at: f64) {
        self.begin(Kind::Temperature, at);
        match report {
            Ok(report) => {
                for s in &report.values {
                    self.add(Kind::Temperature, &s.source_id, &s.id, &s.name, s.celsius);
                }
                for error in &report.errors {
                    self.note(Kind::Temperature, error.clone());
                }
            }
            Err(error) => self.note(Kind::Temperature, error.clone()),
        }
    }
    pub fn fans(&mut self, report: &Result<Readings<Fan>, String>, at: f64) {
        self.begin(Kind::Fan, at);
        match report {
            Ok(report) => {
                for s in &report.values {
                    self.add(Kind::Fan, &s.source_id, &s.id, &s.name, s.rpm as f64);
                    if s.alarm == Some(true) {
                        self.note(Kind::Fan, format!("{}: driver alarm active", s.name));
                    }
                    for note in &s.notes {
                        self.note(Kind::Fan, format!("{}: {note}", s.name));
                    }
                }
                for error in &report.errors {
                    self.note(Kind::Fan, error.clone());
                }
            }
            Err(error) => self.note(Kind::Fan, error.clone()),
        }
    }
    pub fn report(&self, at: f64) -> Report {
        Report {
            rows: self.rows.values().cloned().collect(),
            errors: self.errors.values().flatten().cloned().collect(),
            elapsed_seconds: self.started.map_or(0., |start| (at - start).max(0.)),
            generation: self.generation,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn readings(value: f64, id: &str) -> Result<Readings<Temperature>, String> {
        Ok(Readings {
            values: vec![Temperature {
                id: id.into(),
                source_id: "stable-source".into(),
                thermal: false,
                name: "CPU \"package\"".into(),
                celsius: value,
            }],
            errors: vec![],
        })
    }
    #[test]
    fn statistics_missing_replacement_conversion_and_reset() {
        let mut stats = Statistics::default();
        stats.temperatures(&readings(10., "input-1"), 1.);
        stats.temperatures(&readings(30., "input-1"), 2.);
        let report = stats.report(2.);
        let row = &report.rows[0];
        assert_eq!(
            (row.minimum, row.average, row.maximum, row.samples),
            (10., 20., 30., 2)
        );
        assert_eq!(row.display(row.current, Units::Fahrenheit), "86.0 °F");
        assert!(report.text(Units::Celsius).contains("20.0 °C"));
        stats.temperatures(&Err("unreadable".into()), 3.);
        let report = stats.report(3.);
        assert_eq!(report.rows[0].current, None);
        assert_eq!(report.rows[0].samples, 2);
        assert!(report.text(Units::Celsius).contains("Current: n/a"));
        stats.temperatures(&readings(50., "input-2"), 4.);
        assert_eq!(stats.report(4.).rows[0].samples, 1);
        assert_eq!(stats.report(4.).rows[0].minimum, 50.);
        stats.reset();
        stats.temperatures(&readings(70., "input-2"), 5.);
        let report = stats.report(5.);
        assert_eq!(report.generation, 1);
        assert_eq!(report.elapsed_seconds, 0.);
        assert_eq!(report.rows[0].samples, 1);
    }
    #[test]
    fn invalid_readings_are_not_samples_and_fans_keep_zero() {
        let mut stats = Statistics::default();
        stats.temperatures(&readings(f64::NAN, "bad"), 0.);
        assert!(stats.report(0.).rows.is_empty());
        assert_eq!(stats.report(0.).errors.len(), 1);
        stats.fans(
            &Ok(Readings {
                values: vec![Fan {
                    id: "fan-1".into(),
                    source_id: "fan".into(),
                    name: "Fan".into(),
                    rpm: 0,
                    alarm: Some(true),
                    notes: vec![],
                }],
                errors: vec![],
            }),
            0.,
        );
        let report = stats.report(0.);
        assert_eq!(report.rows[0].current, Some(0.));
        assert_eq!(report.rows[0].display(Some(0.), Units::Fahrenheit), "0 RPM");
        assert!(report.text(Units::Celsius).contains("driver alarm active"));
    }
}
