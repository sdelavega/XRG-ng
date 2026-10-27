// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::temperature::{Text, Units};

#[test]
fn converts_signed_zero_and_positive_temperatures_without_changing_plain_text() {
    for (celsius, expected) in [
        (-40., "-40.0"),
        (-25., "-13.0"),
        (0., "32.0"),
        (100., "212.0"),
    ] {
        let value = Text::reading("温度 · sensor named 75.0 °C: ", celsius, " · partial");
        assert_eq!(
            value.render(Units::Fahrenheit),
            format!("温度 · sensor named 75.0 °C: {expected} °F · partial")
        );
        assert_eq!(
            value.render(Units::Celsius),
            format!("温度 · sensor named 75.0 °C: {celsius:.1} °C · partial")
        );
    }
    let missing = Text::from("Temperature unavailable: failed at 25.0 °C");
    assert_eq!(
        missing.render(Units::Fahrenheit),
        missing.render(Units::Celsius)
    );
}

#[test]
fn nested_temperature_text_keeps_every_span_and_does_not_convert_diagnostic_values() {
    let details = Text::join(
        [
            Text::join(
                [
                    Text::from("GPU · 25.0 °C label"),
                    Text::reading("Temperature: ", 54.025, ""),
                ],
                "\n",
            ),
            Text::reading("Producer: ", -10., " (unscoped)"),
            "error: 54.0 °C".into(),
        ],
        "\n\n",
    );
    assert_eq!(
        details.render(Units::Fahrenheit),
        "GPU · 25.0 °C label\nTemperature: 129.2 °F\n\nProducer: 14.0 °F (unscoped)\n\nerror: 54.0 °C"
    );
    assert!(
        details
            .render(Units::Celsius)
            .contains("Temperature: 54.0 °C")
    );
    assert_eq!(Text::join([], "\n").render(Units::Fahrenheit), "");
}
