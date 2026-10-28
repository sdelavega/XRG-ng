// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{
    legacy,
    settings::{MetricSelection, Module, Settings, Store},
};
#[test]
fn pinned_sources_and_holes_round_trip_and_legacy_import_keeps_them() {
    let settings = Settings {
        metrics: MetricSelection {
            temperature: Some("primary".into()),
            temperature_extra: [None, Some("third".into())],
            fan: Some("fan-one".into()),
            fan_extra: [Some("fan-two".into()), Some("fan-three".into())],
            ..Default::default()
        },
        ..Default::default()
    };
    let loaded = Settings::parse(&serde_json::to_vec(&settings).unwrap()).unwrap();
    assert_eq!(loaded, settings);
    let imported = legacy::parse(
        b"[Modules]\nshow_cpu=false\n[Display]\nshow_activity_bars=true",
        &settings,
    )
    .unwrap();
    assert_eq!(imported.settings.metrics, settings.metrics);
    assert!(
        Settings::default()
            .metrics
            .temperature_extra
            .iter()
            .all(Option::is_none)
    );
}
#[test]
fn optional_channels_require_a_primary_unique_bounded_source_ids_and_exact_slot_count() {
    let base = MetricSelection {
        temperature: Some("primary".into()),
        fan: Some("fan".into()),
        ..Default::default()
    };
    for invalid in ["", "bad\nsource", &"x".repeat(4097)] {
        for temperature in [true, false] {
            let mut selection = base.clone();
            if temperature {
                selection.temperature_extra[0] = Some(invalid.into());
            } else {
                selection.fan_extra[1] = Some(invalid.into());
            }
            assert!(selection.validate().is_err());
        }
    }
    for temperature in [true, false] {
        let mut selection = base.clone();
        let (primary, extra) = if temperature {
            (&mut selection.temperature, &mut selection.temperature_extra)
        } else {
            (&mut selection.fan, &mut selection.fan_extra)
        };
        extra[0] = primary.clone();
        assert!(
            selection
                .validate()
                .unwrap_err()
                .contains("different sensor")
        );
        let mut selection = base.clone();
        if temperature {
            selection.temperature = None;
            selection.temperature_extra[1] = Some("third".into());
        } else {
            selection.fan = None;
            selection.fan_extra[1] = Some("third".into());
        }
        assert!(selection.validate().unwrap_err().contains("primary sensor"));
        let mut selection = base.clone();
        if temperature {
            selection.temperature_extra = [Some("same".into()), Some("same".into())];
        } else {
            selection.fan_extra = [Some("same".into()), Some("same".into())];
        }
        assert!(selection.validate().is_err());
    }
    for field in ["temperature_extra", "fan_extra"] {
        for invalid in [
            serde_json::json!(["one"]),
            serde_json::json!(["one", "two", "three"]),
            serde_json::json!([1, null]),
            serde_json::json!(null),
        ] {
            let mut wire = serde_json::to_value(Settings::default()).unwrap();
            wire["metrics"][field] = invalid;
            assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
        }
    }
}
#[test]
fn snapshot_guards_include_optional_curves_and_only_invalidate_the_changed_graph() {
    let base = MetricSelection {
        temperature: Some("one".into()),
        fan: Some("fan-one".into()),
        ..Default::default()
    };
    for module in [Module::Temperature, Module::Fans] {
        let mut changed = base.clone();
        if module == Module::Temperature {
            changed.temperature_extra[1] = Some("two".into());
        } else {
            changed.fan_extra[0] = Some("fan-two".into());
        }
        for graph in Module::ALL {
            assert_eq!(base.matches(&changed, graph), graph != module);
        }
    }
}
#[test]
fn version_eleven_loads_existing_sensor_choices_without_writing_and_protects_invalid_new_files() {
    let root = std::env::temp_dir().join(format!("xrg-sensor-settings-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("settings.conf");
    let mut expected = Settings::default();
    expected.metrics.temperature = Some("saved-offline-temperature".into());
    expected.metrics.fan = Some("saved-offline-fan".into());
    expected.modules[0].height = Some(164);
    expected.activity_bars.visible = false;
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 11.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    let original = serde_json::to_vec(&wire).unwrap();
    std::fs::write(&path, &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(path.clone()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(std::fs::read(&path).unwrap(), original);
    store.save(&loaded).unwrap();
    let mut invalid = serde_json::to_value(&expected).unwrap();
    invalid["metrics"]["temperature_extra"] =
        serde_json::json!(["saved-offline-temperature", null]);
    let original = serde_json::to_vec(&invalid).unwrap();
    std::fs::write(&path, &original).unwrap();
    let (mut protected, fallback, error) = Store::open(Some(path.clone()));
    assert!(error.is_some());
    assert!(protected.save(&fallback).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), original);
    std::fs::remove_dir_all(&root).unwrap();
}
