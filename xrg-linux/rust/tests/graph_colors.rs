// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    legacy,
    settings::{GraphColors, GraphStyle, Module, Settings, Store},
    shared,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "xrg-graph-colors-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Self(p)
    }
    fn path(&self) -> PathBuf {
        self.0.join("settings.conf")
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
#[test]
fn individual_overrides_keep_zero_alpha_and_inherit_unedited_colors_from_each_theme() {
    let themes = shared::themes();
    let mut colors = GraphColors::default();
    colors.set(0, Some([0., 0., 0., 0.])).unwrap();
    colors
        .set(2, Some([0.12345678912345678, 0.5, 0.75, 0.25]))
        .unwrap();
    for base in &themes {
        let resolved = colors.palette(base);
        assert_eq!(resolved.colors[1], [0., 0., 0., 0.]);
        assert_eq!(resolved.colors[3], [0.12345678912345678, 0.5, 0.75, 0.25]);
        for index in [0, 2, 4, 5, 6] {
            assert_eq!(resolved.colors[index], base.colors[index]);
        }
        assert_eq!(resolved.name, base.name);
    }
    colors.set(2, None).unwrap();
    assert_eq!(colors.palette(&themes[1]).colors[3], themes[1].colors[3]);
    assert!(!colors.is_inherited());
    colors.set(0, None).unwrap();
    assert!(colors.is_inherited());
}
#[test]
fn version_eight_upgrades_without_writing_or_changing_styles_sources_and_palette() {
    let f = Fixture::new();
    let mut expected = Settings::default();
    for (i, module) in expected.modules.iter_mut().enumerate() {
        module.style = GraphStyle::ALL[i % 4];
        module.visible = i % 2 == 0;
    }
    expected
        .module_mut(xrg_ng_linux::settings::Module::Weather)
        .visible = false;
    expected.move_module(Module::Memory, 6);
    expected.metrics.cpu = Some(2);
    expected.ai.ollama = false;
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 8.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    let original = serde_json::to_vec_pretty(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert!(loaded.modules.iter().all(|m| m.colors.is_inherited()));
    assert_eq!(fs::read(f.path()).unwrap(), original);
    loaded
        .modules
        .iter_mut()
        .find(|m| m.id == Module::Memory)
        .unwrap()
        .colors
        .set(1, Some([0.12345678912345678, 0., 0., 0.25]))
        .unwrap();
    store.save(&loaded).unwrap();
    assert_eq!(
        Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
        loaded
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&fs::read(f.path()).unwrap()).unwrap()["version"],
        15
    );
}
#[test]
fn color_choices_follow_module_identity_through_reorder_and_theme_round_trips() {
    let mut settings = Settings::default();
    settings
        .module_mut(Module::Network)
        .colors
        .set(1, Some([1., 0., 0., 0.5]))
        .unwrap();
    settings.move_module(Module::Network, -2);
    settings.modules[0].visible = false;
    let before = settings.theme.palette().unwrap();
    let loaded = Settings::parse(&serde_json::to_vec(&settings).unwrap()).unwrap();
    assert_eq!(loaded, settings);
    assert_eq!(loaded.theme.palette().unwrap().colors, before.colors);
    let network = loaded
        .modules
        .iter()
        .find(|m| m.id == Module::Network)
        .unwrap();
    assert_eq!(network.colors.palette(&before).colors[2], [1., 0., 0., 0.5]);
    assert!(
        loaded
            .modules
            .iter()
            .filter(|m| m.id != Module::Network)
            .all(|m| m.colors.is_inherited())
    );
    let theme = xrg_ng_linux::settings::ThemeDocument::new(&before);
    let wire = serde_json::to_value(&theme).unwrap();
    assert!(wire.get("modules").is_none() && wire.get("graph_colors").is_none());
}
#[test]
fn invalid_overrides_reject_whole_documents_and_keep_existing_files_protected() {
    let mut colors = GraphColors::default();
    colors.set(1, Some([0., 0., 0., 0.])).unwrap();
    for bad in [
        [f64::NAN, 0., 0., 1.],
        [0., 0., 0., -0.1],
        [0., 1.1, 0., 1.],
        [f64::INFINITY, 0., 0., 1.],
    ] {
        let before = colors.clone();
        assert!(colors.set(1, Some(bad)).is_err());
        assert_eq!(colors, before);
        let mut settings = Settings::default();
        settings.modules[0].colors.background = Some(bad);
        assert!(settings.validate().is_err());
    }
    assert!(colors.set(4, None).is_err());
    for bad in [
        serde_json::json!({"series":[[0,0,0,1]]}),
        serde_json::json!({"text":[1,1,1,1]}),
        serde_json::json!({"background":[1,2,3,4]}),
    ] {
        let f = Fixture::new();
        let mut wire = serde_json::to_value(Settings::default()).unwrap();
        wire["modules"][0]["colors"] = bad;
        let original = serde_json::to_vec(&wire).unwrap();
        fs::write(f.path(), &original).unwrap();
        let (mut store, loaded, error) = Store::open(Some(f.path()));
        assert!(error.is_some());
        assert!(store.save(&loaded).is_err());
        assert_eq!(fs::read(f.path()).unwrap(), original);
    }
}
#[test]
fn legacy_module_colors_import_only_the_named_components_and_reject_invalid_values_atomically() {
    let mut base = Settings::default();
    base.module_mut(Module::Disk)
        .colors
        .set(3, Some([0., 1., 0., 0.5]))
        .unwrap();
    let fields = [
        ("memory_bg", Module::Memory, 0),
        ("memory_fg1", Module::Memory, 1),
        ("memory_fg2", Module::Memory, 2),
        ("memory_fg3", Module::Memory, 3),
        ("network_bg", Module::Network, 0),
        ("network_fg1", Module::Network, 1),
        ("network_fg2", Module::Network, 2),
        ("disk_bg", Module::Disk, 0),
        ("disk_fg1", Module::Disk, 1),
        ("disk_fg2", Module::Disk, 2),
        ("aitoken_bg", Module::Ai, 0),
        ("aitoken_fg1", Module::Ai, 1),
        ("aitoken_fg2", Module::Ai, 2),
    ];
    let mut text = "[Colors]\n".to_owned();
    for (key, _, _) in fields {
        text.push_str(&format!("{key}=rgba(0,128,255,0)\n"));
    }
    let report = legacy::parse(text.as_bytes(), &base).unwrap();
    assert_eq!(report.imported.len(), 13);
    assert!(report.skipped.is_empty());
    for (_, id, index) in fields {
        assert_eq!(
            report
                .settings
                .modules
                .iter()
                .find(|m| m.id == id)
                .unwrap()
                .colors
                .components()[index],
            Some([0., 128. / 255., 1., 0.])
        );
    }
    assert_eq!(report.settings.theme, base.theme);
    assert_eq!(
        report.settings.module(Module::Disk).colors.series[2],
        Some([0., 1., 0., 0.5])
    );
    let partial = legacy::parse(b"[Colors]\nnetwork_fg1=#000\ngraph_fg2=#fff\n", &base).unwrap();
    assert_eq!(
        partial.settings.module(Module::Network).colors.series[0],
        Some([0., 0., 0., 1.])
    );
    assert!(partial.settings.module(Module::Network).colors.series[1].is_none());
    assert_eq!(
        partial.settings.theme.palette().unwrap().colors[3],
        [1., 1., 1., 1.]
    );
    assert!(
        legacy::parse(
            b"[Colors]\nmemory_fg1=#fff\nnetwork_bg=rgba(0,0,0,2)\n",
            &base
        )
        .is_err()
    );
    assert!(base.module_mut(Module::Memory).colors.is_inherited());
}
