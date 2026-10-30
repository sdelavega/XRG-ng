// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    legacy,
    settings::{GraphStyle, Module, Settings, Store},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "xrg-styles-{}-{}",
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
fn real_versions_one_through_seven_keep_line_styles_without_early_writes() {
    for version in 1..=7 {
        let f = Fixture::new();
        let mut settings = Settings::default();
        settings.modules.reverse();
        for module in &mut settings.modules {
            module.visible = false;
        }
        settings.metrics.cpu = Some(2);
        settings.ai.ollama = false;
        let mut wire = serde_json::to_value(&settings).unwrap();
        wire["version"] = version.into();
        wire["modules"]
            .as_array_mut()
            .unwrap()
            .retain(|m| m["id"] != "weather");
        let modules = wire["modules"].as_array_mut().unwrap();
        if version <= 2 {
            modules.retain(|m| !["gpu_memory", "fans"].contains(&m["id"].as_str().unwrap()));
        }
        for module in modules {
            module.as_object_mut().unwrap().remove("style");
        }
        let original = serde_json::to_vec(&wire).unwrap();
        fs::write(f.path(), &original).unwrap();
        let (mut store, loaded, error) = Store::open(Some(f.path()));
        assert!(error.is_none(), "version {version}: {error:?}");
        assert_eq!(loaded.version, 40);
        assert!(loaded.modules.iter().all(|m| m.height.is_none()
            && m.effective_height(loaded.graph_height) == loaded.graph_height));
        assert!(loaded.modules.iter().all(|m| !m.visible
            && (m.id == xrg_ng_linux::settings::Module::Weather || m.style == GraphStyle::Hollow)));
        assert_eq!(loaded.metrics, settings.metrics);
        assert_eq!(loaded.theme, settings.theme);
        assert_eq!(loaded.ai, settings.ai);
        let original_order: Vec<_> = wire["modules"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        let loaded_order: Vec<_> = loaded
            .modules
            .iter()
            .take(original_order.len())
            .map(|m| serde_json::to_value(m.id).unwrap())
            .collect();
        assert_eq!(loaded_order, original_order);
        assert_eq!(fs::read(f.path()).unwrap(), original);
        store.save(&loaded).unwrap();
        assert_eq!(
            Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
            loaded
        );
    }
    let loaded = Settings::parse(b"theme=Ocean\n").unwrap();
    assert!(loaded.modules.iter().all(|m| m.style == GraphStyle::Hollow));
}
#[test]
fn new_installs_fill_and_each_graph_style_survives_reorder_hide_and_round_trip() {
    let f = Fixture::new();
    let mut settings = Settings::default();
    assert!(
        settings
            .modules
            .iter()
            .all(|m| m.style == GraphStyle::Solid)
    );
    for (index, module) in settings.modules.iter_mut().enumerate() {
        module.style = GraphStyle::ALL[index % 4];
        module.visible = index % 2 == 0;
    }
    settings.move_module(Module::Cpu, 8);
    let (mut store, _, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    store.save(&settings).unwrap();
    assert_eq!(
        Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
        settings
    );
    let mut bad = serde_json::to_value(&settings).unwrap();
    bad["modules"][0]["style"] = "unknown".into();
    let original = serde_json::to_vec(&bad).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, fallback, error) = Store::open(Some(f.path()));
    assert!(error.is_some());
    assert!(store.save(&fallback).is_err());
    assert_eq!(fs::read(f.path()).unwrap(), original);
}
#[test]
fn all_c_module_styles_import_and_invalid_supported_values_reject_the_entire_import() {
    let mut base = Settings::default();
    for m in &mut base.modules {
        m.style = GraphStyle::Hollow;
    }
    let keys = [
        ("cpu_style", Module::Cpu),
        ("memory_style", Module::Memory),
        ("network_style", Module::Network),
        ("disk_style", Module::Disk),
        ("gpu_style", Module::Gpu),
        ("battery_style", Module::Battery),
        ("temperature_style", Module::Temperature),
        ("aitoken_style", Module::Ai),
        ("tpu_style", Module::Tpu),
    ];
    let mut text = "[GraphStyles]\n".to_owned();
    for (i, (key, _)) in keys.iter().enumerate() {
        text.push_str(&format!("{key}={}\n", i % 4));
    }
    text.push_str("process_style=99\n");
    let imported = legacy::parse(text.as_bytes(), &base).unwrap();
    for (i, (_, id)) in keys.iter().enumerate() {
        assert_eq!(
            imported
                .settings
                .modules
                .iter()
                .find(|m| m.id == *id)
                .unwrap()
                .style,
            GraphStyle::ALL[i % 4]
        );
    }
    assert_eq!(imported.settings.theme, base.theme);
    assert_eq!(imported.imported.len(), 9);
    assert_eq!(imported.skipped, ["[GraphStyles] process_style"]);
    assert!(imported.summary().contains("cpu_style = Solid"));
    for raw in ["-1", "4", "pixel", "4294967296", ""] {
        let text = format!("[Modules]\nshow_cpu=false\n[GraphStyles]\ncpu_style={raw}\n");
        assert!(legacy::parse(text.as_bytes(), &base).is_err());
        assert!(base.modules[0].visible);
    }
}
