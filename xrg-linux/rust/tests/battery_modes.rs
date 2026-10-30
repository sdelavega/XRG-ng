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
    assert_eq!(migrated.version, 38);
    assert_eq!(migrated.metrics.battery_mode, Mode::Charge);
    wire["metrics"]["battery_mode"] = "invented".into();
    assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
}

#[test]
fn retention_preserves_signed_newest_power_separate_charge_and_zero() {
    let mut view = View::default();
    view.panel(
        report(vec![reading("BAT0", "Charging", Some(5.), 50.)]),
        Mode::Power,
    );
    view.panel(
        report(vec![reading("BAT0", "Discharging", Some(4.), 49.)]),
        Mode::Charge,
    );
    view.set_history_samples(300).unwrap();
    let power = view.panel(
        report(vec![reading("BAT0", "Unknown", Some(0.), 48.)]),
        Mode::Power,
    );
    assert_eq!(power.series[0].len(), 300);
    assert_eq!(&power.series[0][297..], [5., -4., 0.]);
    assert!(power.series[0][..297].iter().all(|v| v.is_nan()));
    assert!(view.set_history_samples(20001).is_err());
    let charge = view.panel(
        report(vec![reading("BAT0", "Unknown", None, 47.)]),
        Mode::Charge,
    );
    assert_eq!(charge.series[0].len(), 300);
    assert_eq!(&charge.series[0][296..], [50., 49., 48., 47.]);
    view.set_history_samples(2).unwrap();
    let power = view.panel(
        report(vec![reading("BAT0", "Discharging", Some(3.), 46.)]),
        Mode::Power,
    );
    assert!(power.series[0][0].is_nan());
    assert_eq!(power.series[0][1], -3.);
    view.set_history_samples(0).unwrap();
    let power = view.panel(
        report(vec![reading("BAT0", "Discharging", Some(2.), 45.)]),
        Mode::Power,
    );
    assert_eq!(power.series[0].len(), 120);
    assert_eq!(&power.series[0][118..], [-3., -2.]);
}
#[test]
fn battery_retention_survives_missing_reports_disappearance_and_clear() {
    let mut view = View::default();
    view.set_history_samples(257).unwrap();
    view.panel(
        report(vec![reading("BAT0", "Discharging", Some(4.), 50.)]),
        Mode::Power,
    );
    view.panel(Err("offline".into()), Mode::Power);
    view.set_history_samples(301).unwrap();
    let power = view.panel(
        report(vec![reading("BAT0", "Charging", Some(2.), 51.)]),
        Mode::Power,
    );
    assert_eq!(power.series[0].len(), 301);
    assert_eq!(power.series[0][298], -4.);
    assert!(power.series[0][299].is_nan());
    assert_eq!(power.series[0][300], 2.);
    view.panel(report(vec![]), Mode::Power);
    let fresh = view.panel(
        report(vec![reading("BAT1", "Unknown", None, 80.)]),
        Mode::Power,
    );
    assert_eq!(fresh.series[0].len(), 301);
    assert!(fresh.series[0].iter().all(|v| v.is_nan()));
    view.clear_graph();
    let charge = view.panel(
        report(vec![reading("BAT1", "Charging", Some(1.), 81.)]),
        Mode::Charge,
    );
    assert_eq!(charge.series[0].len(), 301);
    assert_eq!(charge.series[0][300], 81.);
    assert!(charge.series[0][..300].iter().all(|v| v.is_nan()));
}
