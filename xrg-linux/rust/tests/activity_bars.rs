// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{
    engine::{Panel, Scale},
    legacy,
    settings::{ActivityBars, GraphStyle, Settings, Store, ThemeDocument},
    temperature::Units,
};
#[test]
fn old_settings_preserve_appearance_and_only_upgrade_on_explicit_save() {
    let root = std::env::temp_dir().join(format!("xrg-bars-{}", std::process::id()));
    std::fs::create_dir(&root).unwrap();
    let path = root.join("settings.conf");
    let mut expected = Settings::default();
    expected.modules[0].height = Some(164);
    expected.modules[1].colors.series[0] = Some([0., 1., 0., 0.25]);
    expected.metrics.cpu = Some(2);
    expected.activity_bars.visible = false;
    expected.activity_bars.use_series_colors = false;
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 10.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    wire.as_object_mut().unwrap().remove("activity_bars");
    let original = serde_json::to_vec(&wire).unwrap();
    std::fs::write(&path, &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(path.clone()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(std::fs::read(&path).unwrap(), original);
    store.save(&loaded).unwrap();
    assert_eq!(
        Settings::parse(&std::fs::read(&path).unwrap()).unwrap(),
        expected
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&std::fs::read(&path).unwrap()).unwrap()["version"],
        17
    );
    std::fs::remove_dir_all(&root).unwrap();
    assert!(
        !Settings::parse(b"theme=Ocean")
            .unwrap()
            .activity_bars
            .visible
    );
    assert!(Settings::default().activity_bars.visible);
}
#[test]
fn all_bar_styles_and_transparent_black_round_trip_without_changing_theme_or_graph_preferences() {
    for style in GraphStyle::ALL {
        let settings = Settings {
            activity_bars: ActivityBars {
                use_series_colors: false,
                visible: true,
                style,
                color: [0.; 4],
            },
            ..Settings::default()
        };
        let loaded = Settings::parse(&serde_json::to_vec(&settings).unwrap()).unwrap();
        assert_eq!(loaded, settings);
        let wire =
            serde_json::to_value(ThemeDocument::new(&settings.theme.palette().unwrap())).unwrap();
        assert!(wire.get("activity_bars").is_none());
    }
}
#[test]
fn corrupt_bar_preferences_reject_whole_settings() {
    for bad in [
        serde_json::json!({"visible":"yes"}),
        serde_json::json!({"style":"gradient"}),
        serde_json::json!({"color":[0,1,0,-0.1]}),
        serde_json::json!({"color":[0,1,0,1.01]}),
        serde_json::json!({"color":[0,1,0]}),
        serde_json::json!({"unknown":true}),
    ] {
        let mut wire = serde_json::to_value(Settings::default()).unwrap();
        wire["activity_bars"] = bad;
        assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
    }
    for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
        let bars = ActivityBars {
            color: [value, 0., 0., 1.],
            ..ActivityBars::default()
        };
        assert!(bars.validate().is_err());
    }
}
#[test]
fn legacy_bars_import_independently_and_bad_entries_are_atomic() {
    let base = Settings::default();
    for (index, style) in GraphStyle::ALL.into_iter().enumerate() {
        let text = format!(
            "[Display]\nshow_activity_bars=false\nactivity_bar_style={index}\n[Colors]\nactivity_bar=rgba(0,128,255,0.375)"
        );
        let report = legacy::parse(text.as_bytes(), &base).unwrap();
        let mut expected = base.clone();
        expected.activity_bars = ActivityBars {
            use_series_colors: false,
            visible: false,
            style,
            color: [0., 128. / 255., 1., 0.375],
        };
        assert_eq!(report.settings, expected);
        assert_eq!(report.imported.len(), 3);
        assert!(report.skipped.is_empty());
        assert_eq!(
            legacy::parse(b"[Modules]\nshow_cpu=true", &expected)
                .unwrap()
                .settings,
            expected
        );
    }
    for (group, key, bad) in [
        ("Display", "show_activity_bars", "True"),
        ("Display", "show_activity_bars", "1"),
        ("Display", "activity_bar_style", "4"),
        ("Display", "activity_bar_style", "-1"),
        ("Display", "activity_bar_style", "1.0"),
        ("Colors", "activity_bar", "rgba(0,0,0,NaN)"),
        ("Colors", "activity_bar", "#12"),
    ] {
        let text = format!("[Modules]\nshow_cpu=false\n[{group}]\n{key}={bad}");
        assert!(legacy::parse(text.as_bytes(), &base).is_err());
    }
    assert_eq!(base, Settings::default());
}
#[test]
fn bar_axis_text_never_calls_rates_or_temperatures_utilization() {
    let mut panel = Panel {
        title: "Fixture",
        label: String::new(),
        detail: String::new(),
        temperature_text: None,
        readout: Default::default(),
        series: vec![vec![0., 50.]],
        scale: Scale::Percent,
    };
    assert!(
        panel
            .activity_description(Units::Celsius)
            .contains("0–100%")
    );
    panel.scale = Scale::Automatic;
    assert!(
        panel
            .activity_description(Units::Celsius)
            .contains("not device capacity")
    );
    assert!(!panel.activity_description(Units::Celsius).contains('%'));
    panel.scale = Scale::Celsius;
    panel.series = vec![vec![-20., 50.]];
    assert!(
        panel
            .activity_description(Units::Fahrenheit)
            .contains("-4.0–248.0 °F")
    );
    assert!(
        panel
            .activity_description(Units::Celsius)
            .contains("not a thermal limit")
    );
}
