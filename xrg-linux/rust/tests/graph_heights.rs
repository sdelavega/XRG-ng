// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    legacy,
    settings::{GraphStyle, Layout, Module, Settings, Store},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "xrg-heights-{}-{}",
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
fn independent_sizes_follow_identity_and_global_changes_only_affect_inherited_graphs() {
    let mut settings = Settings::default();
    settings.module_mut(Module::Cpu).height = Some(164);
    settings.module_mut(Module::Memory).height = Some(88);
    settings
        .module_mut(Module::Memory)
        .colors
        .set(1, Some([1., 0., 0., 0.5]))
        .unwrap();
    settings.module_mut(Module::Memory).style = GraphStyle::Dot;
    settings.graph_height = 124;
    settings.move_module(Module::Memory, 5);
    for layout in [Layout::Vertical, Layout::Horizontal] {
        settings.layout = layout;
        let loaded = Settings::parse(&serde_json::to_vec(&settings).unwrap()).unwrap();
        assert_eq!(loaded, settings);
        assert_eq!(
            loaded
                .modules
                .iter()
                .find(|m| m.id == Module::Cpu)
                .unwrap()
                .effective_height(loaded.graph_height),
            164
        );
        assert_eq!(
            loaded
                .modules
                .iter()
                .find(|m| m.id == Module::Memory)
                .unwrap()
                .effective_height(loaded.graph_height),
            88
        );
        assert_eq!(
            loaded
                .modules
                .iter()
                .find(|m| m.id == Module::Network)
                .unwrap()
                .effective_height(loaded.graph_height),
            124
        );
    }
    settings.graph_height = 112;
    let memory = settings
        .modules
        .iter_mut()
        .find(|m| m.id == Module::Memory)
        .unwrap();
    memory.visible = false;
    assert_eq!(memory.effective_height(112), 88);
    assert_eq!(memory.style, GraphStyle::Dot);
    assert_eq!(memory.colors.series[0], Some([1., 0., 0., 0.5]));
    memory.height = None;
    assert_eq!(memory.effective_height(112), 112);
}
#[test]
fn version_nine_preserves_existing_layout_and_palette_until_explicit_save() {
    let f = Fixture::new();
    let mut expected = Settings {
        graph_height: 137,
        layout: Layout::Horizontal,
        ..Settings::default()
    };
    expected.modules[0].visible = false;
    expected.modules[1].style = GraphStyle::Pixel;
    expected.modules[1]
        .colors
        .set(2, Some([0.1, 0.2, 0.3, 0.4]))
        .unwrap();
    expected.metrics.cpu = Some(2);
    expected.ai.ollama = false;
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 9.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    let original = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert!(
        loaded
            .modules
            .iter()
            .all(|m| m.height.is_none() && m.effective_height(137) == 137)
    );
    assert_eq!(fs::read(f.path()).unwrap(), original);
    loaded.modules[1].height = Some(156);
    store.save(&loaded).unwrap();
    assert_eq!(
        Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
        loaded
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&fs::read(f.path()).unwrap()).unwrap()["version"],
        33
    );
}
#[test]
fn invalid_per_graph_dimensions_reject_the_whole_file_without_overwriting_it() {
    for invalid in [
        serde_json::json!(0),
        serde_json::json!(63),
        serde_json::json!(241),
        serde_json::json!(-1),
        serde_json::json!(1.5),
        serde_json::json!(true),
        serde_json::json!("128"),
        serde_json::json!(4294967296u64),
    ] {
        let f = Fixture::new();
        let mut wire = serde_json::to_value(Settings::default()).unwrap();
        wire["modules"][0]["height"] = invalid;
        let original = serde_json::to_vec(&wire).unwrap();
        fs::write(f.path(), &original).unwrap();
        let (mut store, fallback, error) = Store::open(Some(f.path()));
        assert!(error.is_some());
        assert!(store.save(&fallback).is_err());
        assert_eq!(fs::read(f.path()).unwrap(), original);
    }
    for height in [64, 137, 240] {
        let mut settings = Settings::default();
        settings.modules[0].height = Some(height);
        assert!(settings.validate().is_ok());
    }
    let mut settings = Settings::default();
    settings.modules[0].height = Some(u32::MAX);
    assert!(settings.validate().is_err());
}
#[test]
fn legacy_window_geometry_never_becomes_graph_dimensions_or_discards_existing_overrides() {
    let mut base = Settings::default();
    base.modules[0].height = Some(160);
    base.modules[1].height = Some(88);
    let report =
        legacy::parse(b"[Window]\nheight=700\n[Modules]\nshow_cpu=false\n", &base).unwrap();
    let mut expected = base.clone();
    expected.modules[0].visible = false;
    assert_eq!(report.settings, expected);
    assert_eq!(report.skipped, ["[Window] height"]);
}
