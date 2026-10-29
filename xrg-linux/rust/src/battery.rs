// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Battery capacity and signed power retain separate histories and axes.
use crate::{
    engine::{Panel, Scale},
    hardware::{Battery, Readings},
    shared::History,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, VecDeque};
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Mode {
    #[default]
    Charge,
    Power,
}
#[derive(Default)]
pub struct View {
    charge: BTreeMap<String, History>,
    power: BTreeMap<String, VecDeque<f64>>,
}
fn watts(reading: &Battery) -> Option<f64> {
    let value = reading.watts.filter(|v| v.is_finite() && *v >= 0.)?;
    if value == 0. {
        return Some(0.);
    }
    match reading.status.as_str() {
        "Charging" => Some(value),
        "Discharging" => Some(-value),
        _ => None,
    }
}
impl View {
    pub fn clear_graph(&mut self) {
        for h in self.charge.values_mut() {
            h.clear();
        }
        for h in self.power.values_mut() {
            h.iter_mut().for_each(|v| *v = f64::NAN);
        }
    }
    pub fn panel(&mut self, report: Result<Readings<Battery>, String>, mode: Mode) -> Panel {
        let mut panel = Panel {
            title: "Battery",
            label: "Battery unavailable".into(),
            detail: String::new(),
            series: Vec::new(),
            scale: if mode == Mode::Power {
                Scale::SignedWatts
            } else {
                Scale::Percent
            },
            temperature_text: None,
            readout: Default::default(),
        };
        let report = match report {
            Ok(r) => r,
            Err(error) => {
                for h in self.power.values_mut() {
                    h.pop_front();
                    h.push_back(f64::NAN);
                }
                panel.detail = error;
                return panel;
            }
        };
        if report.values.is_empty() {
            if report.errors.is_empty() {
                self.charge.clear();
                self.power.clear();
                panel.label = "No system battery".into();
                panel.detail = "No present system battery detected".into();
            } else {
                for h in self.power.values_mut() {
                    h.pop_front();
                    h.push_back(f64::NAN);
                }
                panel.detail = report.errors.join("\n");
            }
            return panel;
        }
        let visible: Vec<_> = report.values.iter().take(3).collect();
        self.charge
            .retain(|name, _| visible.iter().any(|v| v.name == *name));
        self.power
            .retain(|name, _| visible.iter().any(|v| v.name == *name));
        let mut labels = Vec::new();
        for reading in visible {
            let charge = self
                .charge
                .entry(reading.name.clone())
                .or_insert_with(|| History::new(120));
            charge.append(reading.percent);
            let power = self
                .power
                .entry(reading.name.clone())
                .or_insert_with(|| std::iter::repeat_n(f64::NAN, 120).collect());
            let value = watts(reading);
            power.pop_front();
            power.push_back(value.unwrap_or(f64::NAN));
            panel.series.push(if mode == Mode::Power {
                power.iter().copied().collect()
            } else {
                charge.values()
            });
            labels.push(if mode == Mode::Power {
                format!(
                    "{} {} · {:.0}%",
                    reading.name,
                    value
                        .map(|v| format!("{v:+.1} W"))
                        .unwrap_or("n/a W".into()),
                    reading.percent
                )
            } else {
                format!("{} {:.0}%", reading.name, reading.percent)
            });
        }
        panel.label = labels.join(" / ");
        if report.values.len() > 3 {
            panel
                .label
                .push_str(&format!(" (+{})", report.values.len() - 3));
        }
        if !report.errors.is_empty() || report.values.iter().any(|v| !v.notes.is_empty()) {
            panel.label.push_str(" · partial");
        }
        let mut detail: Vec<_> = report.values.iter().map(Battery::description).collect();
        detail.extend(report.errors);
        detail.push(if mode==Mode::Power {"Graph: battery power in watts; charging is positive and discharging negative, with a symmetric axis of at least ±30 W. Direction comes from reported status, not an assumed current sign. Missing power/direction remains a gap; measured zero is retained. Both modes collect together, so changing the display does not relabel percentage history as watts. This is battery power, not whole-machine wall power."} else {"Graph: battery charge percentage (0–100%). Signed charging/discharging power is available as a separate graph mode."}.into());
        panel.detail = detail.join("\n");
        panel
    }
}
