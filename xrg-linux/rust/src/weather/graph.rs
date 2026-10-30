// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Received station observations, not one invented reading per worker tick.
use super::{Secondary, Units, Update};
use crate::{
    dashboard::{Readout, Row},
    engine::{Panel, Scale},
    shared,
    temperature::{self, Text},
};
use std::collections::BTreeMap;
#[derive(Clone, Debug)]
pub struct SecondaryAxis {
    pub lower: f64,
    pub upper: f64,
    pub label: String,
}
#[derive(Clone, Debug)]
pub struct ObservationPlot {
    pub positions: Vec<f64>,
    pub secondary: Option<SecondaryAxis>,
    pub range_label: String,
}
#[derive(Default)]
pub struct Graph {
    station: Option<String>,
    observations: BTreeMap<i64, shared::Metar>,
    newest: Option<i64>,
    cleared_before: Option<i64>,
}
impl Graph {
    /// Keep the latest observation as the restart point and freshness watermark.
    /// Clearing must not promote an older response to a current observation.
    pub fn clear_graph(&mut self) {
        if let Some((&last, _)) = self.observations.last_key_value() {
            self.observations.retain(|time, _| *time == last);
            self.cleared_before = Some(last);
        }
    }
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
            weather_plot: None,
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
            self.newest = None;
            self.cleared_before = None;
        }
        self.station = station.clone();
        if !update.preferences.enabled {
            panel.label = "Weather disabled".into();
            return panel;
        }
        let metric = update
            .preferences
            .distance_units
            .unwrap_or(update.preferences.units)
            == Units::Metric;
        let temperature_metric = update
            .preferences
            .temperature_units
            .unwrap_or(update.preferences.units)
            == Units::Metric;
        let pressure_metric = update
            .preferences
            .pressure_units
            .unwrap_or(update.preferences.units)
            == Units::Metric;
        let wind_units = update.preferences.wind_system();
        panel.scale = Scale::Weather(if temperature_metric {
            temperature::Units::Celsius
        } else {
            temperature::Units::Fahrenheit
        });
        let Some(station) = station else {
            panel.label = "Invalid weather station".into();
            return panel;
        };
        let report = update.observation.as_ref().filter(|r| r.station == station);
        let older = report.is_some_and(|r| self.newest.is_some_and(|time| r.observed_at < time));
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
        if !older && let Some(report) = report {
            self.newest = Some(report.observed_at);
            let rows: Vec<_> = if update.preferences.history_hours.is_some() {
                update
                    .history
                    .iter()
                    .chain(std::iter::once(report))
                    .collect()
            } else {
                vec![report]
            };
            for row in rows {
                if row.station == station
                    && self
                        .cleared_before
                        .is_none_or(|time| row.observed_at >= time)
                {
                    self.observations.insert(row.observed_at, row.clone());
                }
            }
        }
        let reference = update.reference_time.or(self.newest).unwrap_or(0);
        let hours = update.preferences.history_hours;
        if hours.is_some() {
            self.observations
                .retain(|time, _| *time >= reference.saturating_sub(129600));
        }
        let limit = if hours.is_some() { 2048 } else { 120 };
        while self.observations.len() > limit {
            self.observations.pop_first();
        }
        let start = hours.map(|hours| reference.saturating_sub(hours as i64 * 3600));
        let retained: Vec<_> = self
            .observations
            .iter()
            .filter(|(time, _)| start.is_none_or(|start| **time >= start && **time <= reference))
            .collect();
        let mut values = Vec::new();
        let mut secondary_values = Vec::new();
        let mut positions = Vec::new();
        let mut previous = None;
        let selected = update.preferences.secondary;
        let secondary_value = |r: &shared::Metar| match selected {
            Secondary::None => None,
            Secondary::Wind => r.wind_knots.map(|v| v * wind_units.factor()),
            Secondary::Humidity => r.humidity,
            // A visibility bound is not an exact measurement.
            Secondary::Visibility => r
                .visibility_miles
                .filter(|_| r.visibility_qualifier.is_empty())
                .map(|v| v * if metric { 1.609344 } else { 1. }),
            Secondary::Dewpoint => r
                .dewpoint_c
                .map(|v| if temperature_metric { v } else { v * 1.8 + 32. }),
            Secondary::Pressure => {
                if pressure_metric {
                    r.pressure_hpa
                } else {
                    r.pressure_in
                }
            }
        };
        for (time, row) in &retained {
            if previous.is_some_and(|old| **time - old > 7200) {
                values.push(f64::NAN);
                secondary_values.push(f64::NAN);
                positions.push(start.map_or(0., |start| {
                    ((previous.unwrap() + **time) / 2 - start) as f64
                        / (reference - start).max(1) as f64
                }));
            }
            values.push(
                row.temperature_c
                    .filter(|v| v.is_finite())
                    .unwrap_or(f64::NAN),
            );
            secondary_values.push(
                secondary_value(row)
                    .filter(|v| v.is_finite())
                    .unwrap_or(f64::NAN),
            );
            positions.push(start.map_or(0., |start| {
                (**time - start) as f64 / (reference - start).max(1) as f64
            }));
            previous = Some(**time);
        }
        if stale
            || report.is_none()
            || (hours.is_some()
                && report.is_some_and(|r| r.observed_at > reference || Some(r.observed_at) < start))
        {
            values.push(f64::NAN);
            secondary_values.push(f64::NAN);
            positions.push(1.);
        }
        if start.is_none() {
            let n = positions.len().saturating_sub(1).max(1);
            for (i, x) in positions.iter_mut().enumerate() {
                *x = i as f64 / n as f64;
            }
        }
        if !retained.is_empty() {
            panel.series.push(values);
        }
        let secondary = if selected == Secondary::None {
            None
        } else {
            let finite: Vec<_> = secondary_values
                .iter()
                .copied()
                .filter(|v| v.is_finite())
                .collect();
            let low = finite.iter().copied().reduce(f64::min);
            let high = finite.iter().copied().reduce(f64::max);
            let label = match selected {
                Secondary::Wind => format!("Wind ({})", wind_units.suffix()),
                Secondary::Humidity => "Humidity (%)".into(),
                Secondary::Visibility => {
                    format!("Visibility ({})", if metric { "km" } else { "mi" })
                }
                Secondary::Dewpoint => {
                    format!("Dewpoint (°{})", if temperature_metric { "C" } else { "F" })
                }
                Secondary::Pressure => format!(
                    "Pressure ({})",
                    if pressure_metric { "hPa" } else { "inHg" }
                ),
                Secondary::None => unreachable!(),
            };
            let (lower, upper) = match selected {
                Secondary::Humidity => (0., 100.),
                Secondary::Wind | Secondary::Visibility => {
                    (0., high.map_or(1., |v| (v * 1.1).max(1.)))
                }
                _ => {
                    let min = low.unwrap_or(0.);
                    let max = high.unwrap_or(1.);
                    let margin = ((max - min) * 0.1).max(
                        if selected == Secondary::Pressure && !pressure_metric {
                            0.01
                        } else {
                            1.
                        },
                    );
                    (min - margin, max + margin)
                }
            };
            if !retained.is_empty() {
                panel.series.push(secondary_values);
            }
            panel.detail.push_str(&format!("\nSecondary curve: {label}, own axis {lower:.2}–{upper:.2}. Missing or bounded visibility stays a gap; the primary curve remains temperature."));
            Some(SecondaryAxis {
                lower,
                upper,
                label,
            })
        };
        if hours.is_some() || secondary.is_some() {
            let range_label = hours.map_or_else(
                || "Retained session observations".into(),
                |h| format!("Last {h} hours (UTC observation times)"),
            );
            panel.weather_plot = Some(ObservationPlot {
                positions,
                secondary,
                range_label,
            });
        }
        if let Some(hours) = hours {
            panel.detail.push_str(&format!("\n\nWeather history: last {hours} hours, using actual observation timestamps. Only received observations are plotted; this is not a guaranteed complete archive or forecast. No forward fill, interpolation samples or invented zero values are added. Lines connect readings at most two hours apart; longer gaps, missing fields and stale current values stay gaps."));
        } else {
            panel.detail.push_str("\n\nWeather history: up to 120 distinct observations received during this station session, ordered by observation time and equally spaced; not a 24-hour archive or a forecast. Repeated polls do not add samples. Corrections at the latest timestamp replace samples. Gaps over two hours, missing temperatures and stale/latest unavailable readings stay gaps. Session H/L covers retained readings, not a daily high/low. Weather units are independent of system temperature units.");
        }
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
                        number(Some(speed), wind_units.factor(), wind_units.suffix())
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
        let pressure = if pressure_metric {
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
                wind_units.factor(),
                wind_units.suffix(),
            ),
        ));
        let temperatures: Vec<_> = retained
            .iter()
            .filter_map(|(_, r)| r.temperature_c)
            .filter(|v| v.is_finite())
            .collect();
        let high = temperatures.iter().copied().reduce(f64::max);
        let low = temperatures.iter().copied().reduce(f64::min);
        let full_high_low = Text::join([temp(high), temp(low)], " / ");
        let units = panel.scale.temperature_units(temperature::Units::Celsius);
        panel.detail.push_str(&format!(
            "\n{} high / low: {}",
            hours.map_or("Retained session".into(), |h| format!("Received {h}-hour")),
            full_high_low.render(units)
        ));
        let abbreviated = |value: Option<f64>| {
            value
                .map(|v| format!("{:.0}", units.convert_celsius(v)))
                .unwrap_or_else(|| "n/a".into())
        };
        panel.readout.top.push(Row::new(
            hours.map_or("H/L (session)".into(), |h| format!("H/L ({h}h)")),
            format!(
                "{}/{}°{}",
                abbreviated(high),
                abbreviated(low),
                if temperature_metric { "C" } else { "F" }
            ),
        ));
        panel
    }
}
