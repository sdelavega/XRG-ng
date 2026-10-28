// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    legacy,
    settings::{Layout, Module, Settings, Store},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!(
            "xrg-widths-{}-{}",
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
fn previous_settings_keep_the_original_minimum_without_an_early_write() {
    let f = Fixture::new();
    let mut expected = Settings {
        layout: Layout::Horizontal,
        graph_height: 137,
        ..Default::default()
    };
    expected.modules[0].height = Some(164);
    expected.modules[0].visible = false;
    expected.metrics.temperature = Some("saved-sensor".into());
    expected.metrics.temperature_extra[1] = Some("saved-third".into());
    expected.activity_bars.color = [0.2, 0.3, 0.4, 0.5];
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 12.into();
    wire.as_object_mut().unwrap().remove("graph_width");
    let original = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(loaded.graph_width, 360);
    assert_eq!(fs::read(f.path()).unwrap(), original);
    store.save(&loaded).unwrap();
    assert_eq!(
        Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
        expected
    );
    assert_eq!(Settings::parse(b"theme=Ocean").unwrap().graph_width, 360);
}
#[test]
fn width_round_trips_in_both_layouts_independently_of_source_color_order_and_height() {
    for width in [100, 240, 360, 1000, 1200] {
        let mut settings = Settings {
            graph_width: width,
            ..Default::default()
        };
        settings.modules[1].height = Some(88);
        settings.modules[1].colors.series[0] = Some([1., 0., 0., 0.5]);
        settings.move_module(Module::Memory, 5);
        settings.metrics.cpu = Some(2);
        for layout in [Layout::Vertical, Layout::Horizontal] {
            settings.layout = layout;
            assert_eq!(
                Settings::parse(&serde_json::to_vec(&settings).unwrap()).unwrap(),
                settings
            );
        }
        let imported = legacy::parse(
            b"[Modules]\nshow_cpu=true\n[Window]\nwidth=777\n",
            &settings,
        )
        .unwrap();
        assert_eq!(imported.settings.graph_width, width);
        assert!(imported.skipped.contains(&"[Window] width".into()));
        assert_eq!(imported.settings.metrics, settings.metrics);
    }
}
#[test]
fn malformed_widths_refuse_the_whole_file_and_preserve_recovery_protection() {
    for invalid in [
        serde_json::json!(0),
        serde_json::json!(99),
        serde_json::json!(1201),
        serde_json::json!(-1),
        serde_json::json!(100.5),
        serde_json::json!(null),
        serde_json::json!(true),
        serde_json::json!("360"),
        serde_json::json!(4294967296u64),
    ] {
        let f = Fixture::new();
        let mut wire = serde_json::to_value(Settings::default()).unwrap();
        wire["graph_width"] = invalid;
        let original = serde_json::to_vec(&wire).unwrap();
        fs::write(f.path(), &original).unwrap();
        let (mut store, fallback, error) = Store::open(Some(f.path()));
        assert!(error.is_some());
        assert!(store.save(&fallback).is_err());
        assert_eq!(fs::read(f.path()).unwrap(), original);
    }
}
