// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Received station observations, not one invented reading per worker tick.
use super::{Units, Update};
use crate::{
    dashboard::{Readout, Row},
    engine::{Panel, Scale},
    shared,
    temperature::{self, Text},
};
use std::collections::BTreeMap;
#[derive(Default)]
pub struct Graph {
    station: Option<String>,
    observations: BTreeMap<i64, shared::Metar>,
}
impl Graph {
    pub fn panel(&mut self, update: Option<&Update>) -> Panel {
        let mut panel = Panel {
            title: "Weather",
            label: "Waiting for weather source".into(),
            detail:
                "Weather is opt-in. Open Weather settings to choose a station and enable requests."
                    .into(),
            series: Vec::new(),
            scale: Scale::Weather(temperature::Units::Celsius),
            temperature_text: None,
            readout: Readout::default(),
        };
        let Some(update) = update else {
            return panel;
        };
        panel.label = update.summary.clone();
        panel.detail = update.detail.clone();
        let station = shared::metar_station(&update.preferences.station);
        if !update.preferences.enabled || station != self.station {
            self.observations.clear();
        }
        self.station = station.clone();
        if !update.preferences.enabled {
            panel.label = "Weather disabled".into();
            return panel;
        }
        let metric = update.preferences.units == Units::Metric;
        panel.scale = Scale::Weather(if metric {
            temperature::Units::Celsius
        } else {
            temperature::Units::Fahrenheit
        });
        let Some(station) = station else {
            panel.label = "Invalid weather station".into();
            return panel;
        };
        let report = update.observation.as_ref().filter(|r| r.station == station);
        let older = report.is_some_and(|r| {
            self.observations
                .last_key_value()
                .is_some_and(|(time, _)| r.observed_at < *time)
        });
        let stale = update.stale || older;
        if update.stale && report.is_some() {
            panel.label = format!("{station} · stale observation");
            panel.detail.push_str(
                "\nCached observation shown as stale; current-value bars are suppressed.",
            );
        }
        panel.readout.top.push(Row::new(
            &station,
            if stale {
                "STALE"
            } else if report.is_none() {
                "n/a"
            } else {
                "Weather"
            },
        ));
        if !stale && let Some(report) = report {
            // Corrections replace the observation at the same timestamp. Repeated
            // snapshots never add samples or change their relative spacing.
            self.observations.insert(report.observed_at, report.clone());
            while self.observations.len() > 120 {
                self.observations.pop_first();
            }
        }
        let mut values = Vec::new();
        let mut previous = None;
        for (time, report) in &self.observations {
            if previous.is_some_and(|old| time - old > 7200) {
                values.push(f64::NAN);
            }
            values.push(
                report
                    .temperature_c
                    .filter(|v| v.is_finite())
                    .unwrap_or(f64::NAN),
            );
            previous = Some(*time);
        }
        if stale || report.is_none() {
            values.push(f64::NAN);
        }
        if !self.observations.is_empty() {
            panel.series.push(values);
        }
        panel.detail.push_str("\n\nWeather history: up to 120 distinct observations received during this station session, ordered by observation time and equally spaced; not a 24-hour archive or a forecast. Repeated polls do not add samples. Corrections at the latest timestamp replace samples. Gaps over two hours, missing temperatures and stale/latest unavailable readings stay gaps. Session H/L covers retained readings, not a daily high/low. Weather units are independent of system temperature units.");
        if older {
            panel.label = format!("{station} · older observation received");
            panel.detail.push_str("\nThe source regressed to an older observation. Current fields are suppressed until a current observation returns.");
        }
        let current = report.filter(|_| !older);
        let number = |value: Option<f64>, factor: f64, unit: &str| {
            value
                .filter(|v| v.is_finite())
                .map(|v| format!("{:.0}{unit}", v * factor))
                .unwrap_or_else(|| "n/a".into())
        };
        let temp = |value: Option<f64>| {
            value
                .filter(|v| v.is_finite())
                .map(|v| Text::reading("", v, ""))
                .unwrap_or_else(|| Text::from("n/a"))
        };
        panel.readout.top.push(Row::new(
            "Temp",
            temp(current.and_then(|r| r.temperature_c)),
        ));
        let wind = current
            .and_then(|r| r.wind_knots)
            .filter(|v| v.is_finite())
            .map(|speed| {
                if speed == 0. {
                    "calm".into()
                } else {
                    let direction = current
                        .and_then(|r| r.wind_degrees)
                        .filter(|v| v.is_finite())
                        .map(|v| -> String {
                            if v == -1. {
                                "VRB".into()
                            } else {
                                ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
                                    [((v + 22.5).rem_euclid(360.) / 45.) as usize]
                                    .into()
                            }
                        })
                        .unwrap_or_else(|| "?".into());
                    format!(
                        "{direction} {}",
                        number(
                            Some(speed),
                            if metric { 1.852 } else { 1.150779448 },
                            if metric { "km/h" } else { "mph" }
                        )
                    )
                }
            })
            .unwrap_or_else(|| "n/a".into());
        panel.readout.top.push(Row::new("Wind", wind));
        panel.readout.top.push(Row::new(
            "Humidity",
            number(current.and_then(|r| r.humidity), 1., "%"),
        ));
        let visibility = current
            .and_then(|r| r.visibility_miles)
            .filter(|v| v.is_finite())
            .map(|v| {
                format!(
                    "{}{:.2}{}",
                    current.map_or("", |r| r.visibility_qualifier),
                    v * if metric { 1.609344 } else { 1. },
                    if metric { "km" } else { "mi" }
                )
            })
            .unwrap_or_else(|| "n/a".into());
        panel.readout.top.push(Row::new("Visibility", visibility));
        let pressure = if metric {
            number(current.and_then(|r| r.pressure_hpa), 1., "hPa")
        } else {
            current
                .and_then(|r| r.pressure_in)
                .filter(|v| v.is_finite())
                .map(|v| format!("{v:.2}inHg"))
                .unwrap_or_else(|| "n/a".into())
        };
        panel.readout.top.push(Row::new("Pressure", pressure));
        panel.readout.top.push(Row::new(
            "Dewpoint",
            temp(current.and_then(|r| r.dewpoint_c)),
        ));
        panel.readout.top.push(Row::new(
            "Gust",
            number(
                current.and_then(|r| r.gust_knots),
                if metric { 1.852 } else { 1.150779448 },
                if metric { "km/h" } else { "mph" },
            ),
        ));
        let temperatures: Vec<_> = self
            .observations
            .values()
            .filter_map(|r| r.temperature_c)
            .filter(|v| v.is_finite())
            .collect();
        let high = temperatures.iter().copied().reduce(f64::max);
        let low = temperatures.iter().copied().reduce(f64::min);
        let full_high_low = Text::join([temp(high), temp(low)], " / ");
        let units = panel.scale.temperature_units(temperature::Units::Celsius);
        panel.detail.push_str(&format!(
            "\nRetained session high / low: {}",
            full_high_low.render(units)
        ));
        let abbreviated = |value: Option<f64>| {
            value
                .map(|v| format!("{:.0}", units.convert_celsius(v)))
                .unwrap_or_else(|| "n/a".into())
        };
        panel.readout.top.push(Row::new(
            "H/L (session)",
            format!(
                "{}/{}°{}",
                abbreviated(high),
                abbreviated(low),
                if metric { "C" } else { "F" }
            ),
        ));
        panel
    }
}
