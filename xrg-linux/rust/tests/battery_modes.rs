// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{
    battery::{Mode, View},
    engine::Scale,
    hardware::{Battery, Readings},
    settings::{MetricSelection, Module, Settings},
};
fn reading(name: &str, status: &str, watts: Option<f64>, percent: f64) -> Battery {
    Battery {
        name: name.into(),
        status: status.into(),
        watts,
        percent,
        health_percent: None,
        condition: None,
        cycles: None,
        time: None,
        notes: Vec::new(),
    }
}
fn report(values: Vec<Battery>) -> Result<Readings<Battery>, String> {
    Ok(Readings {
        values,
        errors: Vec::new(),
    })
}
#[test]
fn direction_zero_and_missing_power_are_distinct_and_axes_match_units() {
    let mut view = View::default();
    let panel = view.panel(
        report(vec![
            reading("BAT0", "Charging", Some(10.), 50.),
            reading("BAT1", "Discharging", Some(7.), 80.),
            reading("BAT2", "Unknown", Some(0.), 40.),
        ]),
        Mode::Power,
    );
    assert_eq!(panel.scale, Scale::SignedWatts);
    assert_eq!(
        panel
            .series
            .iter()
            .map(|s| *s.last().unwrap())
            .collect::<Vec<_>>(),
        [10., -7., 0.]
    );
    assert!(panel.series[0][..119].iter().all(|v| v.is_nan()));
    assert_eq!(panel.scale.bounds(&panel.series), (-30., 30.));
    assert!(
        panel
            .activity_description(xrg_ng_linux::temperature::Units::Fahrenheit)
            .contains("charging positive")
    );
    let missing = view.panel(
        report(vec![reading("BAT0", "Unknown", Some(10.), 50.)]),
        Mode::Power,
    );
    assert!(missing.series[0].last().unwrap().is_nan());
    assert!(missing.label.contains("n/a W"));
    let missing = view.panel(
        report(vec![reading("BAT0", "Charging", None, 50.)]),
        Mode::Power,
    );
    assert!(missing.series[0].last().unwrap().is_nan());
    let high = view.panel(
        report(vec![reading("BAT0", "Discharging", Some(60.), 49.)]),
        Mode::Power,
    );
    assert_eq!(high.scale.bounds(&high.series), (-60., 60.));
}
#[test]
fn mode_switch_keeps_separate_histories_clear_preserves_current_collection() {
    let mut view = View::default();
    view.panel(
        report(vec![reading("BAT0", "Charging", Some(5.), 50.)]),
        Mode::Charge,
    );
    let power = view.panel(
        report(vec![reading("BAT0", "Discharging", Some(4.), 49.)]),
        Mode::Power,
    );
    assert_eq!(&power.series[0][118..], [5., -4.]);
    let charge = view.panel(
        report(vec![reading("BAT0", "Charging", Some(3.), 51.)]),
        Mode::Charge,
    );
    assert_eq!(charge.scale, Scale::Percent);
    assert_eq!(&charge.series[0][117..], [50., 49., 51.]);
    view.clear_graph();
    let power = view.panel(
        report(vec![reading("BAT0", "Charging", Some(2.), 52.)]),
        Mode::Power,
    );
    assert!(power.series[0][..119].iter().all(|v| v.is_nan()));
    assert_eq!(power.series[0][119], 2.);
}
#[test]
fn failures_and_hotplug_do_not_connect_power_across_missing_readings() {
    let mut view = View::default();
    view.panel(
        report(vec![reading("BAT0", "Charging", Some(5.), 50.)]),
        Mode::Power,
    );
    assert!(
        view.panel(Err("fixture failure".into()), Mode::Power)
            .series
            .is_empty()
    );
    let restored = view.panel(
        report(vec![reading("BAT0", "Discharging", Some(4.), 49.)]),
        Mode::Power,
    );
    assert_eq!(restored.series[0][117], 5.);
    assert!(restored.series[0][118].is_nan());
    assert_eq!(restored.series[0][119], -4.);
    view.panel(report(Vec::new()), Mode::Charge);
    let replaced = view.panel(
        report(vec![reading("BAT0", "Charging", Some(1.), 20.)]),
        Mode::Power,
    );
    assert!(replaced.series[0][..119].iter().all(|v| v.is_nan()));
}
#[test]
fn mode_is_persistent_and_queued_percentage_plots_do_not_match_power_selection() {
    let mut settings = Settings::default();
    settings.metrics.battery_mode = Mode::Power;
    let saved = Settings::parse(&serde_json::to_vec(&settings).unwrap()).unwrap();
    assert_eq!(saved, settings);
    assert!(!MetricSelection::default().matches(&saved.metrics, Module::Battery));
    assert!(MetricSelection::default().matches(&saved.metrics, Module::Network));
    let mut wire = serde_json::to_value(&settings).unwrap();
    wire["version"] = 22.into();
    wire["metrics"]
        .as_object_mut()
        .unwrap()
        .remove("battery_mode");
    let migrated = Settings::parse(&serde_json::to_vec(&wire).unwrap()).unwrap();
    assert_eq!(migrated.version, 23);
    assert_eq!(migrated.metrics.battery_mode, Mode::Charge);
    wire["metrics"]["battery_mode"] = "invented".into();
    assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
}
