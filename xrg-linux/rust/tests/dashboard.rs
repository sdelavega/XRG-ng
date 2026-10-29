// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use xrg_ng_linux::{
    dashboard,
    settings::{GraphStyle, Module, Settings},
};
#[test]
fn compact_defaults_and_existing_profiles_preserve_custom_choices() {
    let defaults = Settings::default();
    assert_eq!((defaults.graph_width, defaults.graph_height), (140, 90));
    let visible: Vec<_> = defaults
        .modules
        .iter()
        .filter(|m| m.visible)
        .map(|m| m.id)
        .collect();
    assert_eq!(
        &visible[..4],
        &[Module::Cpu, Module::Gpu, Module::Tpu, Module::Memory]
    );
    let mut old = defaults;
    old.version = 13;
    let weather = old.modules.pop().unwrap();
    old.graph_width = 360;
    old.graph_height = 100;
    old.modules.reverse();
    old.module_mut(Module::Cpu).height = Some(160);
    old.module_mut(Module::Memory).style = GraphStyle::Hollow;
    old.activity_bars.use_series_colors = false;
    let loaded = Settings::parse(&serde_json::to_vec(&old).unwrap()).unwrap();
    old.version = 23;
    old.modules.push(weather);
    assert_eq!(loaded, old);
}
#[test]
fn compact_units_are_binary_and_unavailable_never_becomes_zero() {
    assert_eq!(dashboard::bytes(0.), "0B");
    assert_eq!(dashboard::bytes(1024.), "1.00K");
    assert_eq!(dashboard::bytes(25. * 1024. * 1024.), "25.0M");
    assert_eq!(dashboard::bytes(f64::NAN), "n/a");
    assert_eq!(dashboard::bytes(-1.), "n/a");
}
