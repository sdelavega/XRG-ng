// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Sensor presentation histories are keyed by physical input incarnation, never
//! labels or enumeration order. Saved source identities are compared, not opened.
use crate::{
    engine::{Panel, Scale},
    hardware::{Fan, Readings, Temperature},
    metrics::SourceOption,
    settings::MetricSelection,
    shared::{History, TimedHistory},
    temperature::Text,
};
use std::collections::BTreeMap;

pub(crate) struct View {
    maximum: History,
    maximum_members: Option<Vec<String>>,
    temperatures: BTreeMap<String, History>,
    fans: BTreeMap<String, History>,
    automatic_fans: [Option<String>; 3],
    temperature_samples: u32,
    fan_samples: u32,
    fan_timed: BTreeMap<String, TimedHistory>,
    history_interval: f64,
}
impl Default for View {
    fn default() -> Self {
        Self {
            maximum: History::new(120),
            maximum_members: None,
            temperatures: BTreeMap::new(),
            fans: BTreeMap::new(),
            automatic_fans: Default::default(),
            temperature_samples: 0,
            fan_samples: 0,
            fan_timed: BTreeMap::new(),
            history_interval: 1.,
        }
    }
}
fn selected<'a>(primary: &'a str, extra: &'a [Option<String>; 2]) -> Vec<Option<&'a str>> {
    let mut slots = vec![Some(primary), extra[0].as_deref(), extra[1].as_deref()];
    slots.truncate(slots.iter().rposition(Option::is_some).unwrap() + 1);
    slots
}
/// Empty slots and unavailable selected inputs keep their series/color index.
/// Dropping an input removes its history, so reappearance starts a fresh curve.
fn curves(
    histories: &mut BTreeMap<String, History>,
    slots: &[Option<(&str, f64)>],
    requested: u32,
) -> Vec<Vec<f64>> {
    let capacity = View::capacity(requested);
    histories.retain(|id, _| slots.iter().flatten().any(|(key, _)| *key == id.as_str()));
    if slots.iter().all(Option::is_none) {
        return Vec::new();
    }
    slots
        .iter()
        .map(|slot| match slot {
            Some((id, value)) => {
                let history = histories
                    .entry((*id).into())
                    .or_insert_with(|| View::fresh_history(requested));
                history.append(*value);
                history.values()
            }
            None => vec![f64::NAN; capacity as usize],
        })
        .collect()
}
fn fan_detail(fan: &Fan, prefix: &str) -> String {
    let mut detail = format!(
        "\n{prefix}{}: {} RPM{}",
        fan.name,
        fan.rpm,
        match fan.alarm {
            Some(true) => " · driver alarm active",
            Some(false) => " · driver alarm clear",
            None => "",
        }
    );
    for note in &fan.notes {
        detail.push_str(&format!("\n{note}"));
    }
    detail
}
impl View {
    fn capacity(requested: u32) -> u32 {
        if requested == 0 { 120 } else { requested }
    }
    fn fresh_history(requested: u32) -> History {
        let mut history = History::new(Self::capacity(requested));
        if requested > 0 {
            history.clear();
        }
        history
    }
    pub fn set_history_samples(&mut self, temperature: u32, fans: u32) -> Result<(), String> {
        let maximum = crate::shared::sampling_settings()[3];
        if temperature > maximum || fans > maximum {
            return Err("Sensor history capacity is out of range".into());
        }
        if Self::capacity(temperature) != Self::capacity(self.temperature_samples) {
            self.maximum.resize(Self::capacity(temperature));
            for history in self.temperatures.values_mut() {
                history.resize(Self::capacity(temperature));
            }
        }
        if Self::capacity(fans) != Self::capacity(self.fan_samples) {
            for history in self.fans.values_mut() {
                history.resize(Self::capacity(fans));
            }
        }
        self.temperature_samples = temperature;
        self.fan_samples = fans;
        Ok(())
    }
    pub fn clear_temperatures(&mut self) {
        self.maximum.clear();
        for h in self.temperatures.values_mut() {
            h.clear();
        }
    }
    pub fn set_history_interval(&mut self, seconds: f64) {
        if seconds.is_finite() && seconds >= 0.2 {
            self.history_interval = seconds;
        }
    }
    pub fn clear_fans(&mut self) {
        for h in self.fan_timed.values_mut() {
            h.clear();
        }
        for h in self.fans.values_mut() {
            h.clear();
        }
    }
    pub fn temperatures(
        &mut self,
        report: Result<Readings<Temperature>, String>,
        selection: &MetricSelection,
    ) -> (Panel, Vec<SourceOption>) {
        let mut panel = Panel {
            title: "Temperature",
            label: String::new(),
            detail: String::new(),
            series: Vec::new(),
            scale: Scale::Celsius,
            temperature_text: None,
            weather_plot: None,
            readout: Default::default(),
        };
        let mut report = match report {
            Ok(report) => report,
            Err(error) => {
                self.maximum_members = None;
                self.temperatures.clear();
                return (
                    panel.with_temperature_text("Temperature unavailable".into(), error.into()),
                    Vec::new(),
                );
            }
        };
        let inventory = report
            .values
            .iter()
            .map(|s| SourceOption {
                id: s.source_id.clone(),
                label: s.name.clone(),
            })
            .collect();
        let mut detail = vec![Text::from(
            "Read-only temperatures. Driver labels do not establish CPU/GPU ownership. Curves use Celsius internally; units affect display only.",
        )];
        let label;
        if let Some(primary) = &selection.temperature {
            self.maximum_members = None;
            let sources = selected(primary, &selection.temperature_extra);
            let readings: Vec<_> = sources
                .iter()
                .map(|source| {
                    source.and_then(|id| report.values.iter().find(|s| s.source_id == id))
                })
                .collect();
            let slots: Vec<_> = readings
                .iter()
                .map(|r| r.map(|s| (s.id.as_str(), s.celsius)))
                .collect();
            panel.series = curves(&mut self.temperatures, &slots, self.temperature_samples);
            panel
                .readout
                .top
                .push(crate::dashboard::Row::new("Temp", ""));
            let mut labels = Vec::new();
            for (index, (source, reading)) in sources.iter().zip(readings).enumerate() {
                let Some(source) = source else {
                    continue;
                };
                if let Some(reading) = reading {
                    panel.readout.top.push(crate::dashboard::Row::new(
                        format!("{}: {}", index + 1, reading.name),
                        Text::reading("", reading.celsius, ""),
                    ));
                    labels.push(Text::reading(
                        &format!("{}: ", index + 1),
                        reading.celsius,
                        &if sources.len() == 1 {
                            format!(" · {}", reading.name)
                        } else {
                            String::new()
                        },
                    ));
                    detail.push(Text::reading(
                        &format!("Curve {} · {}: ", index + 1, reading.name),
                        reading.celsius,
                        "",
                    ));
                } else {
                    panel.readout.top.push(crate::dashboard::Row::new(
                        format!("{}: unavailable", index + 1),
                        "n/a",
                    ));
                    labels.push(format!("{}: unavailable", index + 1).into());
                    detail.push(format!("Curve {} unavailable: saved temperature source {source} is not readable in the latest sample. No fallback is substituted.", index+1).into());
                }
            }
            label = if panel.series.is_empty() {
                Text::from("Selected temperature sensor unavailable")
            } else {
                Text::join(labels, " / ")
            };
        } else {
            self.temperatures.clear();
            // The maximum retains the existing hwmon-first thermal fallback.
            if report.values.iter().any(|s| !s.thermal) {
                report.values.retain(|s| !s.thermal);
            }
            if report.values.is_empty() {
                self.maximum_members = None;
                label = if report.errors.is_empty() {
                    "No temperature sensors".into()
                } else {
                    "Temperature unavailable".into()
                };
                detail.push("No readable hwmon or thermal-zone temperature detected".into());
            } else {
                let mut members: Vec<_> = report.values.iter().map(|s| s.id.clone()).collect();
                members.sort();
                if self.maximum_members.as_ref() != Some(&members) {
                    self.maximum = Self::fresh_history(self.temperature_samples);
                    self.maximum_members = Some(members);
                }
                let maximum = report
                    .values
                    .iter()
                    .map(|s| s.celsius)
                    .fold(f64::NEG_INFINITY, f64::max);
                self.maximum.append(maximum);
                panel.series.push(self.maximum.values());
                panel.readout.top.push(crate::dashboard::Row::new(
                    "Temp (max)",
                    Text::reading("", maximum, ""),
                ));
                for sensor in report.values.iter().take(3) {
                    panel.readout.top.push(crate::dashboard::Row::new(
                        &sensor.name,
                        Text::reading("", sensor.celsius, ""),
                    ));
                }
                let count = report.values.len();
                label = Text::reading(
                    "",
                    maximum,
                    &format!(
                        " max · {count} {}",
                        if count == 1 { "sensor" } else { "sensors" }
                    ),
                );
                detail.push("Curve 1: maximum across the readable sensors below. Membership changes reset this aggregate history.".into());
                detail.extend(
                    report
                        .values
                        .iter()
                        .take(64)
                        .map(|s| Text::reading(&format!("{}: ", s.name), s.celsius, "")),
                );
                if report.values.len() > 64 {
                    detail.push("Additional temperature details omitted".into());
                }
            }
        }
        let label = if report.errors.is_empty() {
            label
        } else {
            Text::join([label, Text::from("partial")], " · ")
        };
        detail.extend(report.errors.into_iter().map(Text::from));
        (
            panel.with_temperature_text(label, Text::join(detail, "\n")),
            inventory,
        )
    }
    pub fn fans(
        &mut self,
        report: Result<Readings<Fan>, String>,
        selection: &MetricSelection,
    ) -> (Panel, Vec<SourceOption>) {
        let observed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|v| v.as_secs_f64())
            .unwrap_or(f64::NAN);
        self.fans_at(report, selection, observed)
    }
    fn fans_at(
        &mut self,
        report: Result<Readings<Fan>, String>,
        selection: &MetricSelection,
        observed: f64,
    ) -> (Panel, Vec<SourceOption>) {
        let mut panel = Panel { title: "Fans", label: "No readable fan sensors".into(), series: Vec::new(),
            detail: "Read-only hwmon fan RPM. Zero can mean a stopped fan; PWM duty is not RPM. Channel labels come from the driver and do not establish CPU/GPU ownership. Curve numbers identify graph colors and current-value bars.".into(), scale: Scale::Automatic, temperature_text: None,
            weather_plot: None, readout: Default::default() };
        let report = match report {
            Ok(report) => report,
            Err(error) => {
                self.fans.clear();
                self.fan_timed.clear();
                self.automatic_fans = Default::default();
                panel.label = "Fan readings unavailable".into();
                panel.detail.push_str(&format!("\n{error}"));
                return (panel, Vec::new());
            }
        };
        let inventory = report
            .values
            .iter()
            .map(|s| SourceOption {
                id: s.source_id.clone(),
                label: s.name.clone(),
            })
            .collect();
        let sources = if let Some(primary) = &selection.fan {
            self.automatic_fans = Default::default();
            selected(primary, &selection.fan_extra)
        } else {
            // Keep surviving automatic sources in their existing color slots.
            for source in &mut self.automatic_fans {
                if !report
                    .values
                    .iter()
                    .any(|s| Some(&s.source_id) == source.as_ref())
                {
                    *source = None;
                }
            }
            for fan in &report.values {
                if !self.automatic_fans.contains(&Some(fan.source_id.clone()))
                    && let Some(slot) = self.automatic_fans.iter_mut().find(|s| s.is_none())
                {
                    *slot = Some(fan.source_id.clone());
                }
            }
            let count = self
                .automatic_fans
                .iter()
                .rposition(Option::is_some)
                .map_or(0, |n| n + 1);
            self.automatic_fans[..count]
                .iter()
                .map(Option::as_deref)
                .collect()
        };
        let readings: Vec<_> = sources
            .iter()
            .map(|source| source.and_then(|id| report.values.iter().find(|s| s.source_id == id)))
            .collect();
        let slots: Vec<_> = readings
            .iter()
            .map(|r| r.map(|s| (s.id.as_str(), s.rpm as f64)))
            .collect();
        panel.series = curves(&mut self.fans, &slots, self.fan_samples);
        self.fan_timed
            .retain(|id, _| slots.iter().flatten().any(|(key, _)| *key == id));
        for (id, value) in slots.iter().flatten() {
            self.fan_timed
                .entry((*id).into())
                .or_insert_with(|| TimedHistory::new_limited(1, 60))
                .append(observed, &[*value]);
        }
        let minutes = selection.retained_minutes(crate::settings::Module::Fans);
        if minutes > 0 && !panel.series.is_empty() {
            let projected: Vec<_> = slots
                .iter()
                .map(|slot| {
                    slot.map(|(id, _)| {
                        self.fan_timed[id]
                            .values_at(minutes, self.history_interval)
                            .remove(0)
                    })
                })
                .collect();
            let count = projected.iter().flatten().next().map_or(0, Vec::len);
            panel.series = projected
                .into_iter()
                .map(|v| v.unwrap_or_else(|| vec![f64::NAN; count]))
                .collect();
            panel.detail.push_str(&format!("\nFans time window: {minutes} minutes ending at latest completed observation. Unobserved bins remain gaps; RPM is independent of temperature, PWM and session statistics."));
        }
        let mut labels = Vec::new();
        for (index, (source, reading)) in sources.iter().zip(readings).enumerate() {
            let Some(source) = source else {
                continue;
            };
            if let Some(fan) = reading {
                if panel.readout.top.is_empty() {
                    panel
                        .readout
                        .top
                        .push(crate::dashboard::Row::new("Fans", ""));
                }
                panel.readout.top.push(crate::dashboard::Row::new(
                    &fan.name,
                    format!("{} RPM", fan.rpm),
                ));
                labels.push(format!(
                    "{}: {}{} RPM{}",
                    index + 1,
                    if sources.len() == 1 {
                        format!("{} ", fan.name)
                    } else {
                        String::new()
                    },
                    fan.rpm,
                    if fan.alarm == Some(true) {
                        " · alarm"
                    } else {
                        ""
                    }
                ));
                panel
                    .detail
                    .push_str(&fan_detail(fan, &format!("Curve {} · ", index + 1)));
            } else {
                labels.push(format!("{}: unavailable", index + 1));
                panel.detail.push_str(&format!("\nCurve {} unavailable: saved fan source {source} is not readable in the latest sample. No fallback is substituted.",index+1));
            }
        }
        if !labels.is_empty() {
            panel.label = labels.join(" / ");
        }
        if panel.series.is_empty() && selection.fan.is_some() {
            panel.label = "Selected fan unavailable".into();
        } else if labels.is_empty() && !report.errors.is_empty() {
            panel.label = "Fan readings unavailable".into();
        }
        if selection.fan.is_none() && report.values.len() > 3 {
            panel.label.push_str(" (+more)");
        }
        if !report.errors.is_empty() || report.values.iter().any(|f| !f.notes.is_empty()) {
            panel.label.push_str(" · partial");
        }
        if selection.fan.is_none() {
            panel.detail.push_str("\nAutomatic view keeps up to three readable fans in stable color slots; new sources fill empty slots. Other readable fans:");
            for fan in report
                .values
                .iter()
                .filter(|s| !sources.contains(&Some(s.source_id.as_str())))
                .take(64)
            {
                panel.detail.push_str(&fan_detail(fan, ""));
            }
            if report
                .values
                .iter()
                .filter(|s| !sources.contains(&Some(s.source_id.as_str())))
                .count()
                > 64
            {
                panel.detail.push_str("\nAdditional fan details omitted");
            }
        }
        for error in report.errors {
            panel.detail.push_str(&format!("\n{error}"));
        }
        (panel, inventory)
    }
}

#[cfg(test)]
mod dashboard_tests {

    fn thermal(
        id: &str,
        value: f64,
    ) -> Result<crate::hardware::Readings<crate::hardware::Temperature>, String> {
        Ok(crate::hardware::Readings {
            values: vec![crate::hardware::Temperature {
                id: id.into(),
                source_id: "saved".into(),
                thermal: false,
                name: "Cold sensor".into(),
                celsius: value,
            }],
            errors: vec![],
        })
    }
    fn fan(id: &str, rpm: u64) -> Result<crate::hardware::Readings<crate::hardware::Fan>, String> {
        Ok(crate::hardware::Readings {
            values: vec![crate::hardware::Fan {
                id: id.into(),
                source_id: "fan".into(),
                name: "Fan".into(),
                rpm,
                alarm: Some(false),
                notes: vec![],
            }],
            errors: vec![],
        })
    }
    #[test]
    fn fan_windows_preserve_physical_boundaries_zero_and_temperature_state() {
        use crate::settings::{MetricSelection, Module};
        let mut view = super::View::default();
        let mut selection = MetricSelection::default();
        selection.history_minutes.insert(Module::Fans, 1);
        selection.fan = Some("fan".into());
        selection.fan_extra = [Some("missing".into()), None];
        view.temperatures(
            thermal("temperature", -10.),
            &MetricSelection {
                temperature: Some("saved".into()),
                ..Default::default()
            },
        );
        view.fans_at(fan("physical", 1000), &selection, 100.);
        let p = view.fans_at(fan("physical", 0), &selection, 110.).0;
        assert_eq!(p.series.len(), 2);
        assert_eq!(p.series[0].len(), 61);
        assert_eq!(p.series[0][50], 1000.);
        assert_eq!(p.series[0][60], 0.);
        assert!(p.series[0][51..60].iter().all(|v| v.is_nan()));
        assert!(p.series[1].iter().all(|v| v.is_nan()));
        view.set_history_samples(300, 600).unwrap();
        view.set_history_interval(0.2);
        let p = view.fans_at(fan("physical", 500), &selection, 111.).0;
        assert_eq!(p.series[0].len(), 301);
        view.clear_fans();
        assert!(view.temperatures["temperature"].values().contains(&-10.));
        let p = view.fans_at(fan("physical", 500), &selection, 112.).0;
        assert!(p.series[0][..300].iter().all(|v| v.is_nan()));
        let p = view.fans_at(fan("replacement", 800), &selection, 113.).0;
        assert!(p.series[0][..300].iter().all(|v| v.is_nan()));
        assert!(
            view.fans_at(Err("offline".into()), &selection, 114.)
                .0
                .series
                .is_empty()
        );
        let p = view.fans_at(fan("replacement", 800), &selection, 115.).0;
        assert!(p.series[0][..300].iter().all(|v| v.is_nan()));
        selection.history_minutes.remove(&Module::Fans);
        assert_eq!(
            view.fans_at(fan("replacement", 800), &selection, 116.)
                .0
                .series[0]
                .len(),
            600
        );
    }
    #[test]
    fn sensor_retention_preserves_newest_cold_observations_and_independent_stopped_fans() {
        use crate::{sensors::View, settings::MetricSelection};
        let mut view = View::default();
        let selection = MetricSelection {
            temperature: Some("saved".into()),
            temperature_extra: [Some("missing".into()), None],
            ..Default::default()
        };
        view.temperatures(thermal("physical", -10.), &selection);
        view.fans(fan("physical-fan", 1000), &selection);
        view.set_history_samples(300, 600).unwrap();
        let temp = view.temperatures(thermal("physical", -5.), &selection).0;
        assert_eq!(
            temp.series.iter().map(Vec::len).collect::<Vec<_>>(),
            [300, 300]
        );
        assert_eq!(&temp.series[0][298..], [-10., -5.]);
        assert!(temp.series[0][..179].iter().all(|v| v.is_nan()));
        // Automatic's pre-existing zero padding is retained; only added positions are missing.
        assert!(temp.series[0][179..298].iter().all(|v| *v == 0.));
        assert!(temp.series[1].iter().all(|v| v.is_nan()));
        let fans = view.fans(fan("physical-fan", 0), &selection).0;
        assert_eq!(fans.series[0].len(), 600);
        assert_eq!(&fans.series[0][598..], [1000., 0.]);
        assert!(view.set_history_samples(1, 20001).is_err());
        assert_eq!(view.temperatures["physical"].values().len(), 300);
        view.set_history_samples(1, 2).unwrap();
        assert_eq!(view.temperatures["physical"].values(), [-5.]);
        assert_eq!(view.fans["physical-fan"].values(), [1000., 0.]);
        view.set_history_samples(0, 0).unwrap();
        assert_eq!(view.temperatures["physical"].values().len(), 120);
        assert_eq!(view.fans["physical-fan"].values().last(), Some(&0.));
    }
    #[test]
    fn sensor_retention_survives_failures_reincarnation_and_maximum_membership_reset() {
        use crate::{sensors::View, settings::MetricSelection};
        let mut view = View::default();
        let selection = MetricSelection::default();
        view.set_history_samples(257, 301).unwrap();
        view.temperatures(thermal("old", 20.), &selection);
        view.temperatures(thermal("old", 30.), &selection);
        let fresh = view.temperatures(thermal("new", 40.), &selection).0;
        assert_eq!(fresh.series[0].len(), 257);
        assert!(fresh.series[0][..256].iter().all(|v| v.is_nan()));
        assert_eq!(fresh.series[0][256], 40.);
        view.temperatures(Err("offline".into()), &selection);
        let recovered = view.temperatures(thermal("new", -2.), &selection).0;
        assert_eq!(recovered.series[0].len(), 257);
        assert!(recovered.series[0][..256].iter().all(|v| v.is_nan()));
        view.fans(fan("old", 1000), &selection);
        view.fans(Err("offline".into()), &selection);
        let recovered = view.fans(fan("new", 0), &selection).0;
        assert_eq!(recovered.series[0].len(), 301);
        assert!(recovered.series[0][..300].iter().all(|v| v.is_nan()));
        assert_eq!(recovered.series[0][300], 0.);
        view.clear_fans();
        view.clear_temperatures();
        assert!(view.maximum.values().iter().all(|v| v.is_nan()));
        assert!(view.fans["new"].values().iter().all(|v| v.is_nan()));
        assert_eq!(view.temperature_samples, 257);
        assert_eq!(view.fan_samples, 301);
    }

    #[test]
    fn temperature_face_identifies_maximum_and_keeps_selected_curve_gaps_and_units() {
        use crate::{
            hardware::{Readings, Temperature},
            sensors::View,
            settings::MetricSelection,
            temperature::Units,
        };
        let report = || {
            Ok(Readings {
                values: (0..4)
                    .map(|id| Temperature {
                        id: format!("kernel-{id}"),
                        source_id: format!("sensor-{id}"),
                        thermal: false,
                        name: format!("Sensor {id}"),
                        celsius: 10. + id as f64 * 10.,
                    })
                    .collect(),
                errors: Vec::new(),
            })
        };
        let mut view = View::default();
        let automatic = view.temperatures(report(), &MetricSelection::default()).0;
        assert_eq!(automatic.readout.top[0].left, "Temp (max)");
        assert_eq!(
            automatic.readout.top[0].right.render(Units::Celsius),
            "40.0 °C"
        );
        assert_eq!(
            automatic.readout.top[0].right.render(Units::Fahrenheit),
            "104.0 °F"
        );
        let selected = MetricSelection {
            temperature: Some("sensor-0".into()),
            temperature_extra: [Some("missing".into()), Some("sensor-3".into())],
            ..Default::default()
        };
        let pinned = view.temperatures(report(), &selected).0;
        assert_eq!(pinned.readout.top[1].left, "1: Sensor 0");
        assert_eq!(pinned.readout.top[2].right.render(Units::Celsius), "n/a");
        assert_eq!(pinned.readout.top[3].left, "3: Sensor 3");
    }
}
