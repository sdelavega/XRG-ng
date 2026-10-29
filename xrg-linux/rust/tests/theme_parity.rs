// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::settings::ThemeDocument;

#[derive(serde::Deserialize)]
struct Case {
    name: String,
    json: String,
    valid: bool,
}

#[test]
fn swift_and_rust_use_the_same_wire_acceptance_cases() {
    let cases: Vec<Case> = serde_json::from_slice(include_bytes!(
        "../../../Shared/Tests/Fixtures/theme-validation-cases.json"
    ))
    .unwrap();
    for item in cases {
        assert_eq!(
            ThemeDocument::parse(item.json.as_bytes()).is_ok(),
            item.valid,
            "{}",
            item.name
        );
    }
}

#[test]
fn portable_colors_and_names_round_trip_without_precision_loss() {
    let doc = ThemeDocument::parse(include_bytes!(
        "../../../Shared/Tests/Fixtures/portable-theme.json"
    ))
    .unwrap();
    let encoded = serde_json::to_vec(&doc).unwrap();
    assert_eq!(ThemeDocument::parse(&encoded).unwrap(), doc);
    assert_eq!(doc.colors[0][0], 0.012_345_678_901_234_567);
    let mut oversized = encoded.clone();
    oversized.resize(128 * 1024 + 1, b' ');
    assert!(ThemeDocument::parse(&oversized).is_err());
}
