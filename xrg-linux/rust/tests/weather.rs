// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{
    shared,
    weather::{Collector, Fetcher, Preferences, Units, endpoint},
};
const WALL: i64 = 1_793_103_000; // 2026-10-27 12:10 UTC
fn body(station: &str) -> Vec<u8> {
    format!("{station} 271200Z 09010G20KT M1/4SM 00/M02 A3000").into_bytes()
}
fn enabled() -> Preferences {
    Preferences {
        enabled: true,
        station: "KSEA".into(),
        ..Default::default()
    }
}
struct Fake {
    response: Result<Vec<u8>, String>,
    calls: Vec<String>,
}
impl Default for Fake {
    fn default() -> Self {
        Self {
            response: Ok(body("KSEA")),
            calls: Vec::new(),
        }
    }
}
impl Fetcher for Fake {
    fn get(&mut self, station: &str) -> Result<Vec<u8>, String> {
        self.calls.push(station.into());
        self.response.clone()
    }
}
#[test]
fn station_and_shared_ffi_preserve_zero_missing_values_and_bounds() {
    assert_eq!(shared::metar_station(" ksea ").as_deref(), Some("KSEA"));
    for bad in ["", "KSE", "KSEAA", "KSEA?x=1", "../x", "KSEA\0"] {
        assert!(shared::metar_station(bad).is_none());
    }
    let report = shared::metar_latest(&body("KSEA"), "ksea", WALL).unwrap();
    assert_eq!(report.observed_at, WALL - 600);
    assert_eq!(report.temperature_c, Some(0.));
    assert_eq!(report.dewpoint_c, Some(-2.));
    assert_eq!(report.visibility_qualifier, "<");
    assert_eq!(report.visibility_miles, Some(0.25));
    let minimal = shared::metar_latest(b"KSEA 271200Z 00000KT", "KSEA", WALL).unwrap();
    assert_eq!(minimal.wind_knots, Some(0.));
    assert_eq!(minimal.temperature_c, None);
    assert_eq!(minimal.pressure_hpa, None);
    for input in [
        b"KSEA 271200Z NIL".as_slice(),
        b"KJFK 271200Z 00000KT",
        b"KSEA 271230Z 00000KT",
        b"KSEA 251200Z 00000KT",
        &[0xff],
    ] {
        assert!(shared::metar_latest(input, "KSEA", WALL).is_none());
    }
    assert!(shared::metar_latest(&vec![b'x'; 2_097_153], "KSEA", WALL).is_none());
    assert!(
        shared::metar_latest(
            format!("KSEA 271200Z {}", "9999 ".repeat(257)).as_bytes(),
            "KSEA",
            WALL
        )
        .is_none()
    );
}
#[test]
fn ffi_chooses_latest_across_months_without_reading_other_station_fields() {
    let reference = 1_793_491_800; // Nov 1 00:10
    let raw = b"KSEA 312253Z 09020KT 10SM 20/10 A2990\nKSEA 312353Z 00000KT 10SM M01/M02 Q1013\nKJFK 010001Z 18030KT 1SM 30/20 A2900";
    let report = shared::metar_latest(raw, "KSEA", reference).unwrap();
    assert_eq!(report.observed_at, reference - 17 * 60);
    assert_eq!(report.temperature_c, Some(-1.));
    assert_eq!(report.wind_knots, Some(0.));
    assert!(!report.raw.contains("KJFK"));
}
#[test]
fn disabled_weather_never_queries_and_preferences_do_not_allow_url_injection() {
    struct Never;
    impl Fetcher for Never {
        fn get(&mut self, _: &str) -> Result<Vec<u8>, String> {
            panic!("Disabled weather queried")
        }
    }
    let mut collector = Collector::new(Preferences::default()).unwrap();
    assert_eq!(
        collector.sample(0., WALL, true, &mut Never).summary,
        "Weather disabled"
    );
    assert!(endpoint("KSEA&ids=KJFK").is_err());
    assert_eq!(
        endpoint(" ksea ").unwrap(),
        "https://aviationweather.gov/api/data/metar?ids=KSEA&format=raw&hours=24"
    );
    assert!(
        Preferences {
            enabled: true,
            ..Default::default()
        }
        .validate()
        .is_err()
    );
    assert!(
        Preferences {
            refresh_minutes: 4,
            ..enabled()
        }
        .validate()
        .is_err()
    );
}
#[test]
fn refresh_bursts_coalesce_and_auto_polling_obeys_its_interval() {
    let mut collector = Collector::new(Preferences {
        refresh_minutes: 5,
        ..enabled()
    })
    .unwrap();
    let mut api = Fake::default();
    collector.sample(0., WALL, false, &mut api);
    assert_eq!(api.calls.len(), 1);
    for n in 1..60 {
        collector.sample(n as f64, WALL + n, true, &mut api);
    }
    assert_eq!(api.calls.len(), 1);
    collector.sample(60., WALL + 60, false, &mut api);
    assert_eq!(api.calls.len(), 2);
    let queued = collector.sample(61., WALL + 61, true, &mut api);
    assert_eq!(queued.cooldown_seconds, 59);
    collector.sample(120., WALL + 120, false, &mut api);
    assert_eq!(api.calls.len(), 3);
    collector.sample(419., WALL + 419, false, &mut api);
    assert_eq!(api.calls.len(), 3);
    collector.sample(420., WALL + 420, false, &mut api);
    assert_eq!(api.calls.len(), 4);
}
#[test]
fn failed_refresh_keeps_the_same_station_explicitly_stale_and_recovers() {
    let mut collector = Collector::new(enabled()).unwrap();
    let mut api = Fake::default();
    let first = collector.sample(0., WALL, false, &mut api);
    assert!(!first.stale);
    api.response = Err("offline fixture".into());
    let stale = collector.sample(60., WALL + 60, true, &mut api);
    assert!(stale.stale && stale.detail.contains("offline fixture"));
    assert_eq!(stale.observation, first.observation);
    api.response = Ok(body("KJFK"));
    assert!(collector.sample(120., WALL + 120, true, &mut api).stale);
    api.response = Ok(body("KSEA"));
    assert!(!collector.sample(180., WALL + 180, true, &mut api).stale);
}
#[test]
fn station_changes_and_disable_clear_cache_without_bypassing_global_cooldown() {
    let mut collector = Collector::new(enabled()).unwrap();
    let mut api = Fake::default();
    collector.sample(0., WALL, false, &mut api);
    collector
        .configure(Preferences {
            station: "kjfk".into(),
            ..enabled()
        })
        .unwrap();
    let pending = collector.sample(1., WALL + 1, false, &mut api);
    assert!(pending.observation.is_none() && pending.summary.contains("KJFK"));
    assert_eq!(api.calls.len(), 1);
    api.response = Ok(body("KJFK"));
    let changed = collector.sample(60., WALL + 60, false, &mut api);
    assert_eq!(changed.observation.unwrap().station, "KJFK");
    assert_eq!(api.calls, ["KSEA", "KJFK"]);
    collector.configure(Preferences::default()).unwrap();
    assert!(
        collector
            .sample(61., WALL + 61, true, &mut api)
            .observation
            .is_none()
    );
    assert_eq!(api.calls.len(), 2);
}
#[test]
fn units_change_cached_presentation_without_another_query_or_losing_qualifiers() {
    let mut collector = Collector::new(enabled()).unwrap();
    let mut api = Fake::default();
    let metric = collector.sample(0., WALL, false, &mut api);
    assert!(metric.detail.contains("Temperature: 0.0 °C"));
    collector
        .configure(Preferences {
            units: Units::Us,
            ..enabled()
        })
        .unwrap();
    let us = collector.sample(1., WALL + 1, false, &mut api);
    assert!(
        us.detail.contains("Temperature: 32.0 °F")
            && us.detail.contains("Pressure: 30.00 inHg")
            && us.detail.contains("Visibility: <0.25 mi")
    );
    assert_eq!(api.calls.len(), 1);
    assert_eq!(us.observation, metric.observation);
}
#[test]
fn stale_observations_clock_errors_and_invalid_responses_never_become_fresh_data() {
    let mut collector = Collector::new(enabled()).unwrap();
    let mut api = Fake {
        response: Ok(b"KSEA 270900Z 00000KT".to_vec()),
        ..Default::default()
    };
    assert!(collector.sample(10., WALL, false, &mut api).stale);
    let calls = api.calls.len();
    assert!(collector.sample(f64::NAN, WALL, true, &mut api).stale);
    assert!(
        collector
            .sample(9., WALL, true, &mut api)
            .detail
            .contains("clock")
    );
    assert_eq!(api.calls.len(), calls);
    let mut collector = Collector::new(enabled()).unwrap();
    api.response = Ok(vec![b'x'; 2_097_153]);
    let failed = collector.sample(0., WALL, false, &mut api);
    assert!(failed.observation.is_none() && failed.detail.contains("2 MiB"));
}

#[test]
fn weather_override_migration_is_opt_in_and_rejects_invalid_unit_values() {
    let mut settings = xrg_ng_linux::settings::Settings::default();
    settings.weather.units = Units::Us;
    let mut wire = serde_json::to_value(&settings).unwrap();
    wire["version"] = 22.into();
    let migrated =
        xrg_ng_linux::settings::Settings::parse(&serde_json::to_vec(&wire).unwrap()).unwrap();
    assert_eq!(migrated.weather.temperature_units, None);
    assert_eq!(migrated.weather.pressure_units, None);
    assert_eq!(
        migrated.weather.wind_system(),
        xrg_ng_linux::weather::WindUnits::Mph
    );
    wire["weather"]["wind_units"] = "knots".into();
    wire["weather"]["temperature_units"] = "metric".into();
    wire["weather"]["pressure_units"] = "us".into();
    let mixed =
        xrg_ng_linux::settings::Settings::parse(&serde_json::to_vec(&wire).unwrap()).unwrap();
    assert_eq!(mixed.weather.temperature_units, Some(Units::Metric));
    assert_eq!(
        mixed.weather.wind_system(),
        xrg_ng_linux::weather::WindUnits::Knots
    );
    wire["weather"]["pressure_units"] = "invented".into();
    assert!(xrg_ng_linux::settings::Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
}

#[test]
fn mixed_units_reformat_cached_inspector_without_a_new_request() {
    struct Count(usize);
    impl Fetcher for Count {
        fn get(&mut self, station: &str) -> Result<Vec<u8>, String> {
            self.0 += 1;
            Ok(body(station))
        }
    }
    let mut preferences = enabled();
    let mut collector = Collector::new(preferences.clone()).unwrap();
    let mut fetcher = Count(0);
    collector.sample(0., WALL, false, &mut fetcher);
    preferences.temperature_units = Some(Units::Us);
    preferences.distance_units = Some(Units::Us);
    preferences.pressure_units = Some(Units::Metric);
    preferences.wind_units = Some(xrg_ng_linux::weather::WindUnits::Knots);
    collector.configure(preferences).unwrap();
    let update = collector.sample(1., WALL, false, &mut fetcher);
    assert_eq!(fetcher.0, 1);
    assert!(!update.stale);
    assert_eq!(update.observation.as_ref().unwrap().temperature_c, Some(0.));
    assert!(update.detail.contains("Temperature: 32.0 °F"));
    assert!(update.detail.contains("Wind speed: 10.0 kt"));
    assert!(update.detail.contains("Visibility: <0.25 mi"));
    assert!(update.detail.contains("Pressure: 1016 hPa"));
}

#[test]
fn archive_parser_orders_deduplicates_and_preserves_missing_fields() {
    let rows = shared::metar_history(b"KSEA 271200Z 00/M02 Q1013\nKSEA 271100Z 00000KT\nKSEA 271200Z 30/20 Q1000\nKJFK 271205Z 40/20 Q999\nKSEA 251200Z 10/05", "KSEA", WALL).unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].observed_at, WALL - 4200);
    assert_eq!(rows[0].temperature_c, None);
    assert_eq!(rows[0].wind_knots, Some(0.));
    assert_eq!(rows[1].temperature_c, Some(0.));
    assert!(shared::metar_history(b"invalid", "KSEA", WALL).is_none());
    assert!(shared::metar_history(&body("KSEA"), "KSEA", -1).is_none());
}
#[test]
fn archives_merge_corrections_reject_regression_and_presentation_does_not_fetch() {
    let mut preferences = enabled();
    let mut collector = Collector::new(preferences.clone()).unwrap();
    let mut api = Fake {
        response: Ok(b"KSEA 271100Z 10/05 Q1012\nKSEA 271200Z 20/10 Q1013".to_vec()),
        ..Default::default()
    };
    let initial = collector.sample(0., WALL, false, &mut api);
    assert_eq!(initial.history.len(), 2);
    preferences.history_hours = Some(24);
    preferences.secondary = xrg_ng_linux::weather::Secondary::Pressure;
    collector.configure(preferences).unwrap();
    assert_eq!(
        collector.sample(1., WALL + 1, false, &mut api).history,
        initial.history
    );
    assert_eq!(api.calls.len(), 1);
    api.response = Ok(b"KSEA 271100Z 11/05 Q1012\nKSEA 271200Z 21/10 Q1013".to_vec());
    let corrected = collector.sample(60., WALL + 60, true, &mut api);
    assert_eq!(corrected.history[0].temperature_c, Some(11.));
    assert_eq!(
        corrected.observation.as_ref().unwrap().temperature_c,
        Some(21.)
    );
    api.response = Ok(b"KSEA 271100Z 99/05 Q1012".to_vec());
    let old = collector.sample(120., WALL + 120, true, &mut api);
    assert!(old.stale && old.detail.contains("older observation"));
    assert_eq!(old.history, corrected.history);
    assert_eq!(old.observation, corrected.observation);
}
#[test]
fn history_settings_upgrade_preserves_legacy_and_validates_before_writing() {
    use xrg_ng_linux::settings::Settings;
    let mut wire = serde_json::to_value(Settings::default()).unwrap();
    wire["version"] = 23.into();
    wire["weather"]
        .as_object_mut()
        .unwrap()
        .remove("history_hours");
    wire["weather"].as_object_mut().unwrap().remove("secondary");
    let parse = |wire: &serde_json::Value| Settings::parse(&serde_json::to_vec(wire).unwrap());
    let legacy = parse(&wire).unwrap();
    assert_eq!(legacy.weather.history_hours, None);
    assert_eq!(
        legacy.weather.secondary,
        xrg_ng_linux::weather::Secondary::None
    );
    wire["weather"]["history_hours"] = 12.into();
    wire["weather"]["secondary"] = "pressure".into();
    let loaded = parse(&wire).unwrap();
    assert_eq!(loaded.weather.history_hours, Some(12));
    assert_eq!(
        parse(&serde_json::to_value(loaded).unwrap())
            .unwrap()
            .weather
            .history_hours,
        Some(12)
    );
    wire["weather"]["history_hours"] = 1.into();
    assert!(parse(&wire).is_err());
    wire["weather"]["history_hours"] = 6.into();
    wire["weather"]["secondary"] = "invented".into();
    assert!(parse(&wire).is_err());
}
