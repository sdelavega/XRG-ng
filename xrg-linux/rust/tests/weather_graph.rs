// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{
    shared, temperature,
    weather::{Graph, Preferences, Units, Update},
};
const WALL: i64 = 1_793_103_000;
fn update(station: &str, raw: &str) -> Update {
    Update {
        preferences: Preferences {
            enabled: true,
            station: station.into(),
            ..Default::default()
        },
        observation: shared::metar_latest(raw.as_bytes(), station, WALL),
        summary: format!("{station} observation"),
        detail: "Fixture · no network".into(),
        stale: false,
        cooldown_seconds: 0,
    }
}
fn reading() -> Update {
    update("KSEA", "KSEA 271200Z 00000KT M1/4SM 00/M02 A3000")
}
#[test]
fn distinct_observations_and_same_time_corrections_are_not_one_sample_per_tick() {
    let mut graph = Graph::default();
    let first = reading();
    for _ in 0..12 {
        assert_eq!(graph.panel(Some(&first)).series[0], vec![0.]);
    }
    let corrected = update("KSEA", "KSEA 271200Z 00000KT M1/4SM M01/M02 A3000");
    assert_eq!(graph.panel(Some(&corrected)).series[0], vec![-1.]);
    let next = update("KSEA", "KSEA 271205Z 00000KT 10SM 02/M02 Q1013");
    assert_eq!(graph.panel(Some(&next)).series[0], vec![-1., 2.]);
    let stale = graph.panel(Some(&corrected));
    assert!(stale.label.contains("older observation"));
    assert!(stale.series[0].last().unwrap().is_nan());
    assert_eq!(
        stale.readout.top[1]
            .right
            .render(temperature::Units::Celsius),
        "n/a"
    );
}
#[test]
fn fresh_zero_missing_and_stale_observations_remain_distinct() {
    let mut graph = Graph::default();
    let mut value = reading();
    let fresh = graph.panel(Some(&value));
    assert_eq!(
        fresh.readout.top[1]
            .right
            .render(temperature::Units::Celsius),
        "0.0 °C"
    );
    assert_eq!(
        fresh.readout.top[2]
            .right
            .render(temperature::Units::Celsius),
        "calm"
    );
    assert_eq!(
        fresh.readout.top[4]
            .right
            .render(temperature::Units::Celsius),
        "<0.40km"
    );
    value.stale = true;
    let stale = graph.panel(Some(&value));
    assert!(stale.label.contains("stale"));
    assert_eq!(
        stale.readout.top[0]
            .right
            .render(temperature::Units::Celsius),
        "STALE"
    );
    assert!(stale.series[0].last().unwrap().is_nan());
    assert_eq!(graph.panel(Some(&value)).series[0].len(), 2);
    value.observation = None;
    assert_eq!(
        graph.panel(Some(&value)).readout.top[1]
            .right
            .render(temperature::Units::Celsius),
        "n/a"
    );
    let missing = update("KSEA", "KSEA 271205Z 00000KT");
    assert!(
        graph.panel(Some(&missing)).series[0]
            .last()
            .unwrap()
            .is_nan()
    );
}
#[test]
fn weather_units_override_system_temperature_units_without_changing_history() {
    let mut graph = Graph::default();
    let mut value = reading();
    let celsius = graph.panel(Some(&value));
    value.preferences.units = Units::Us;
    let fahrenheit = graph.panel(Some(&value));
    assert_eq!(celsius.series, fahrenheit.series);
    let effective = fahrenheit
        .scale
        .temperature_units(temperature::Units::Celsius);
    assert_eq!(effective, temperature::Units::Fahrenheit);
    assert_eq!(fahrenheit.readout.top[1].right.render(effective), "32.0 °F");
    assert!(
        fahrenheit
            .activity_description(temperature::Units::Celsius)
            .contains("23.0–41.0 °F")
    );
    assert!(fahrenheit.detail.contains("not a 24-hour archive"));
    assert!(
        fahrenheit
            .detail
            .contains("Retained session high / low: 32.0 °F / 32.0 °F")
    );
    assert_eq!(fahrenheit.readout.top[8].right.render(effective), "32/32°F");
}
#[test]
fn station_disable_and_mismatched_reports_do_not_mix_histories_or_readings() {
    let mut graph = Graph::default();
    graph.panel(Some(&reading()));
    let mut wrong = reading();
    wrong.preferences.station = "KJFK".into();
    let result = graph.panel(Some(&wrong));
    assert!(result.series.is_empty());
    assert_eq!(
        result.readout.top[1]
            .right
            .render(temperature::Units::Celsius),
        "n/a"
    );
    wrong.preferences.enabled = false;
    assert!(graph.panel(Some(&wrong)).series.is_empty());
    assert_eq!(graph.panel(Some(&wrong)).label, "Weather disabled");
    assert_eq!(graph.panel(Some(&reading())).series[0], vec![0.]);
}
#[test]
fn retained_observations_are_bounded_and_long_gaps_stay_gaps() {
    let mut graph = Graph::default();
    let mut value = reading();
    let start = value.observation.as_ref().unwrap().observed_at;
    for i in 0..125 {
        let report = value.observation.as_mut().unwrap();
        report.observed_at = start + i * 300;
        report.temperature_c = Some(i as f64 / 10.);
        graph.panel(Some(&value));
    }
    let result = graph.panel(Some(&value));
    assert_eq!(result.series[0].len(), 120);
    assert_eq!(result.series[0][0], 0.5);
    value.observation.as_mut().unwrap().observed_at += 7201;
    let result = graph.panel(Some(&value));
    assert!(result.series[0][result.series[0].len() - 2].is_nan());
    assert_eq!(*result.series[0].last().unwrap(), 12.4);
}

#[test]
fn clear_history_retains_latest_observation_and_older_response_guard() {
    let mut graph = Graph::default();
    let first = reading();
    graph.panel(Some(&first));
    let next = update("KSEA", "KSEA 271205Z 00000KT 10SM 02/M02 Q1013");
    assert_eq!(graph.panel(Some(&next)).series[0].len(), 2);
    graph.clear_graph();
    assert_eq!(graph.panel(Some(&next)).series[0], vec![2.]);
    let older = graph.panel(Some(&first));
    assert!(older.label.contains("older observation"));
    assert_eq!(older.series[0][0], 2.);
    assert!(older.series[0][1].is_nan());
}

#[test]
fn independent_units_change_presentation_without_replacing_history() {
    use xrg_ng_linux::weather::WindUnits;
    let mut value = update("KSEA", "KSEA 271200Z 21010G20KT 10SM 20/10 A3000");
    let mut graph = Graph::default();
    let original = graph.panel(Some(&value)).series[0].clone();
    value.preferences.temperature_units = Some(Units::Us);
    value.preferences.distance_units = Some(Units::Metric);
    value.preferences.pressure_units = Some(Units::Metric);
    value.preferences.wind_units = Some(WindUnits::Knots);
    let panel = graph.panel(Some(&value));
    assert_eq!(panel.series[0], original);
    assert_eq!(
        panel.scale.temperature_units(temperature::Units::Celsius),
        temperature::Units::Fahrenheit
    );
    let rows: Vec<_> = panel
        .readout
        .top
        .iter()
        .map(|r| r.right.render(temperature::Units::Fahrenheit).into_owned())
        .collect();
    assert!(rows.contains(&"68.0 °F".into()));
    assert!(rows.contains(&"SW 10kt".into()));
    assert!(rows.contains(&"16.09km".into()));
    assert!(rows.contains(&"1016hPa".into()));
    assert!(rows.contains(&"20kt".into()));
    value.preferences.distance_units = Some(Units::Us);
    value.preferences.pressure_units = Some(Units::Us);
    value.preferences.wind_units = None;
    let panel = graph.panel(Some(&value));
    assert_eq!(panel.series[0], original);
    assert!(panel.readout.top.iter().any(|r| {
        r.right
            .render(temperature::Units::Fahrenheit)
            .contains("mph")
    }));
    assert!(
        panel
            .readout
            .top
            .iter()
            .any(|r| r.right.render(temperature::Units::Fahrenheit) == "30.00inHg")
    );
}
