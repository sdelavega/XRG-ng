// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{
    engine::{Panel, Scale},
    settings::{
        Module, Settings,
        network_scale::{self, MAX},
    },
    temperature::Units,
};
#[test]
fn network_scale_units_convert_exactly_and_reject_invalid_or_overflowing_values() {
    for (text, unit, expected) in [
        ("0", 0, 0),
        (" 4 ", 1, 4096),
        ("3", 2, 3_145_728),
        ("1025", 0, 1025),
    ] {
        assert_eq!(network_scale::parse(text, unit).unwrap(), expected);
    }
    for value in [0, 1, 1024, 4096, 1_048_576, 3_145_728, 1025, MAX] {
        let (text, unit) = network_scale::display(value);
        assert_eq!(network_scale::parse(&text, unit).unwrap(), value);
    }
    assert_eq!(network_scale::display(1025), ("1025".into(), 0));
    for bad in [
        "",
        " ",
        "-1",
        "+1",
        "1.5",
        "1e3",
        "NaN",
        "inf",
        "one",
        "1 024",
        "1,024",
        "18446744073709551616",
    ] {
        assert!(network_scale::parse(bad, 0).is_err(), "accepted {bad}");
    }
    for unit in 0..3 {
        assert!(network_scale::parse("18446744073709551615", unit).is_err());
    }
    assert!(network_scale::parse("1", 3).is_err());
    assert!(network_scale::parse("1", u32::MAX).is_err());
    assert!(network_scale::parse(&(MAX / 1_048_576 + 1).to_string(), 2).is_err());
}
#[test]
fn network_floor_grows_with_history_and_never_clips_to_a_capacity_percentage() {
    let samples = vec![vec![0., 100., 200., 128.], vec![0., 90., 50., 64.]];
    let before = samples.clone();
    assert_eq!(
        Scale::Automatic.bounds_with_minimum(&samples, 4096),
        (0., 4096.)
    );
    assert!((Scale::Automatic.bounds_with_minimum(&samples, 64).1 - 220.).abs() < 1e-10);
    assert_eq!(
        Scale::Automatic.bounds_with_minimum(&samples, 0),
        Scale::Automatic.bounds(&samples)
    );
    assert_eq!(Scale::Automatic.bounds_with_minimum(&[], 4096), (0., 4096.));
    assert_eq!(
        Scale::Automatic.bounds_with_minimum(&[vec![0., 0.]], 4096),
        (0., 4096.)
    );
    assert_eq!(samples, before);
    for scale in [
        Scale::Percent,
        Scale::Celsius,
        Scale::Weather(Units::Fahrenheit),
    ] {
        assert_eq!(
            scale.bounds_with_minimum(&samples, 4096),
            scale.bounds(&samples)
        );
    }
    let settings = Settings {
        network_min_scale: 4096,
        ..Settings::default()
    };
    for module in Module::ALL {
        assert_eq!(
            settings.minimum_scale(module),
            if module == Module::Network { 4096 } else { 0 }
        );
    }
}
#[test]
fn network_activity_descriptions_use_the_same_axis_floor_without_mutating_samples() {
    let panel = Panel {
        title: "Network",
        label: "128 / 64 B/s".into(),
        series: vec![vec![128.], vec![64.]],
        scale: Scale::Automatic,
        detail: "Network fixture".into(),
        temperature_text: None,
        weather_plot: None,
        readout: Default::default(),
    };
    let description = panel.activity_description_with_minimum(Units::Celsius, 4096);
    assert!(description.contains("0.00–4096.00"));
    assert!(description.contains("not device capacity"));
    assert_eq!(panel.series, [vec![128.], vec![64.]]);
    assert_eq!(panel.label, "128 / 64 B/s");
}
