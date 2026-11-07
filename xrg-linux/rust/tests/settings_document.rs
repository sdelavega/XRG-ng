// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! The unified settings document as the Linux app stores it: opened from
//! the configuration root, migrated once from the legacy `settings.conf`,
//! written only through the shared core's C ABI, atomically and privately.
//!
//! The shared core stays the only validator: nothing here re-checks a
//! value the core accepted or refused. These tests pin the store's file
//! behaviour — paths, one-time migration, atomic 0600 writes, protection
//! of malformed files, read-only directories and unknown-key survival.
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::Duration,
};
use xrg_ng_linux::settings::{
    self, Module, Settings, StockSettings, Store, ThemeChoice, Writer, document,
};

static NEXT: AtomicU64 = AtomicU64::new(0);

/// One disposable configuration root, removed with everything written into it.
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-settings-document-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn root(&self) -> &Path {
        &self.0
    }
    /// The legacy GLib-era file the migration reads once: `<root>/xrg-ng/settings.conf`.
    fn conf(&self) -> PathBuf {
        self.0.join("xrg-ng/settings.conf")
    }
    /// The unified document the store owns: `<root>/xrg-ng/settings.json`.
    fn json(&self) -> PathBuf {
        self.0.join("xrg-ng/settings.json")
    }
    fn write_conf(&self, bytes: &[u8]) {
        fs::create_dir_all(self.conf().parent().unwrap()).unwrap();
        fs::write(self.conf(), bytes).unwrap();
    }
    fn write_json(&self, bytes: &[u8]) {
        fs::create_dir_all(self.json().parent().unwrap()).unwrap();
        fs::write(self.json(), bytes).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        // Restore the owner's permissions on every directory the tests made
        // read-only — the root and the nested `xrg-ng` — before removal, and
        // never panic from `Drop`: a failed test must unwind, not abort the
        // whole binary and leak every remaining fixture.
        for directory in [self.0.as_path(), &self.0.join("xrg-ng")] {
            if let Ok(metadata) = fs::metadata(directory) {
                let mut permissions = metadata.permissions();
                permissions.set_mode(0o700);
                let _ = fs::set_permissions(directory, permissions);
            }
        }
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// A version-40 settings file with a value in nearly every field family, so
/// migrations and saves have something to lose when they go wrong. The
/// Stocks settings ride along (ruling R2) even though 0.2.2 never stored
/// them: they prove the migration leaves them at the catalog defaults.
fn custom_settings() -> Settings {
    let mut settings = Settings::default();
    settings.stocks.symbols = "MSFT".into();
    settings.stocks.timeframe = 6;
    settings.metrics.history_minutes.insert(Module::Network, 4);
    settings.metrics.history_samples.insert(Module::Gpu, 900);
    settings.graph_height = 140;
    settings.graph_width = 260;
    settings.window_opacity = 0.625;
    settings.network_min_scale = 2048;
    settings.layout = settings::Layout::Horizontal;
    settings.temperature_units = xrg_ng_linux::temperature::Units::Fahrenheit;
    settings.metrics.cpu = Some(3);
    settings.metrics.disk = Some("nvme0n1".into());
    settings.metrics.temperature = Some("coretemp-isa-0000".into());
    settings.processes.filter = "worker".into();
    settings.processes.limit = 25;
    settings.ai.enabled = [true, false, true, false];
    settings.ai.history_samples = 1440;
    settings.weather.station = "KSEA".into();
    settings.modules[0].visible = false;
    settings.move_module(Module::Tpu, -9);
    settings
}

/// The settings a migration of `settings` produces: every field the legacy
/// file carried, with the Stocks settings at their shared defaults, because
/// no Linux version before 0.2.3 ever stored them.
fn migrated(settings: &Settings) -> Settings {
    let mut result = settings.clone();
    result.stocks = StockSettings::default();
    result
}

/// The Linux view of the document with every setting at its catalog default:
/// the settings a fresh configuration starts from, as only the core renders
/// them (the catalog's defaults, not the legacy Rust model's).
fn default_view() -> Settings {
    let document =
        match document::load(br#"{"format": "xrg-ng-settings", "version": 1, "settings": {}}"#) {
            document::Loaded::Ok { document, .. } => document,
            document::Loaded::Unreadable { .. } => unreachable!("the core loads its own defaults"),
        };
    document::linux_view(&document).unwrap()
}

/// The historical settings file for one version, shaped exactly as the
/// per-version tests in `tests/settings.rs` shape their wires: the fields
/// the version predates are absent, and the module list matches the era.
fn historical(version: u32) -> (Vec<u8>, Settings) {
    let mut settings = custom_settings();
    // Graph heights arrived after the versions that never had them.
    if version < 34 {
        settings.modules[0].height = None;
    }
    let mut wire = serde_json::to_value(&settings).unwrap();
    wire["version"] = version.into();
    {
        let modules = wire["modules"].as_array_mut().unwrap();
        // Version 15 added Weather to the saved set; version 14 checked for
        // exactly the twelve graphs before it, and so did every older file.
        if version < 15 {
            modules.retain(|m| m["id"] != "weather");
        }
    }
    // The absent fields each version predates, in the same order the
    // historical tests remove them.
    if version < 29 {
        wire["ai"]
            .as_object_mut()
            .unwrap()
            .remove("history_samples");
    }
    if version < 30 {
        wire["ai"]
            .as_object_mut()
            .unwrap()
            .remove("history_minutes");
    }
    {
        let object = wire.as_object_mut().unwrap();
        if version < 3 {
            object.remove("ai");
        }
        if version < 4 {
            object.remove("weather");
        }
        if version < 15 {
            object.remove("ai_show_model_breakdown");
        }
        if version < 16 {
            object.remove("sampling_interval_ms");
        }
        if version < 17 {
            object.remove("window_opacity");
        }
        if version < 18 {
            object.remove("window_size");
        }
        if version < 19 {
            object.remove("network_min_scale");
        }
        if version < 24 {
            object.remove("window_collapse");
        }
        let metrics = object.get_mut("metrics").unwrap().as_object_mut().unwrap();
        if version < 26 {
            metrics.remove("history_samples");
        }
        if version < 29 {
            metrics.remove("fan");
        }
        if version < 31 {
            metrics.remove("cpu_history_minutes");
        }
        if version < 32 {
            metrics.remove("history_minutes");
        }
        if version < 20 {
            metrics.remove("xe_pmu");
        }
    }
    let bytes = serde_json::to_vec(&wire).unwrap();
    let mut expected = Settings::parse(&bytes).unwrap();
    // Stocks are new in 0.2.3: no historical file carried them, so the
    // migration leaves them at the shared catalog defaults.
    expected.stocks = StockSettings::default();
    (bytes, expected)
}

#[test]
fn first_launch_migrates_conf_once() {
    let f = Fixture::new();
    let (conf, expected) = historical(40);
    f.write_conf(&conf);
    let store = Store::open(f.root());
    assert!(store.load_problem().is_none(), "{:?}", store.load_problem());
    assert_eq!(store.settings(), &expected);
    // The legacy file is read once and left byte-identical; nothing else
    // in the configuration tree appears besides the new document.
    assert_eq!(fs::read(f.conf()).unwrap(), conf);
    let written = fs::read(f.json()).unwrap();
    assert_eq!(
        document::load(&written),
        document::Loaded::Ok {
            document: written.clone(),
            diagnostics: Vec::new()
        }
    );
    // A second open reads the document and rewrites nothing.
    let modified = fs::metadata(f.json()).unwrap().modified().unwrap();
    thread::sleep(Duration::from_millis(50));
    let reopened = Store::open(f.root());
    assert!(reopened.load_problem().is_none());
    assert_eq!(reopened.settings(), &expected);
    assert_eq!(fs::read(f.json()).unwrap(), written);
    assert_eq!(
        fs::metadata(f.json()).unwrap().modified().unwrap(),
        modified,
        "the second open rewrote the settings document"
    );
    assert_eq!(fs::read(f.conf()).unwrap(), conf);
}

#[test]
fn versions_10_to_40_all_migrate() {
    for version in 10..=40 {
        let f = Fixture::new();
        let (conf, expected) = historical(version);
        f.write_conf(&conf);
        let store = Store::open(f.root());
        assert!(
            store.load_problem().is_none(),
            "version {version}: {:?}",
            store.load_problem()
        );
        // The resulting document's Linux view equals today's upgraded Settings.
        assert_eq!(
            store.settings(),
            &expected,
            "version {version} did not migrate to today's settings"
        );
        assert_eq!(fs::read(f.conf()).unwrap(), conf, "version {version}");
        let written = fs::read(f.json()).unwrap();
        // The written file's own Linux view is the settings the store shows.
        assert_eq!(
            document::linux_view(&written).unwrap(),
            expected,
            "version {version}: the file is not the document's own view"
        );
    }
}

#[test]
fn set_is_atomic_and_0600() {
    let f = Fixture::new();
    let mut store = Store::open(f.root());
    let before = custom_settings();
    store.save(&before).unwrap();
    let baseline = fs::read(f.json()).unwrap();
    store
        .set("general.window.opacity", serde_json::json!(0.75))
        .unwrap();
    let written = fs::read(f.json()).unwrap();
    assert_ne!(written, baseline);
    assert_eq!(
        fs::metadata(f.json()).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // Atomic: no temporary files survive the rename, and the file on disk is
    // exactly the canonical document the core returned.
    assert_eq!(
        fs::read_dir(f.json().parent().unwrap())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with(".xrg-ng-"))
            .count(),
        0
    );
    assert_eq!(
        document::load(&written),
        document::Loaded::Ok {
            document: written.clone(),
            diagnostics: Vec::new()
        }
    );
    let mut reloaded = migrated(&before);
    reloaded.window_opacity = 0.75;
    assert_eq!(store.settings(), &reloaded);
    // The store's own document is the file's document.
    let reopened = Store::open(f.root());
    assert_eq!(reopened.settings(), &reloaded);
}

#[test]
fn invalid_set_is_not_saved() {
    let f = Fixture::new();
    let mut store = Store::open(f.root());
    let baseline = custom_settings();
    store.save(&baseline).unwrap();
    let saved = fs::read(f.json()).unwrap();
    let view = store.settings().clone();
    // Wrong shape, out of range, unknown id and unmet dependency: each is
    // refused, and neither the file nor the in-memory view changes.
    for (id, value, expected) in [
        (
            "general.window.opacity",
            serde_json::json!("dark"),
            document::SetError::WrongType,
        ),
        (
            "general.window.opacity",
            serde_json::json!(0.05),
            document::SetError::OutOfRange { min: 0.1, max: 1.0 },
        ),
        (
            "graphs.default_height",
            serde_json::json!(63),
            document::SetError::OutOfRange {
                min: 64.0,
                max: 240.0,
            },
        ),
        (
            "nope.nope",
            serde_json::json!(true),
            document::SetError::UnknownId,
        ),
        (
            "stocks.symbols",
            serde_json::json!(5),
            document::SetError::WrongType,
        ),
    ] {
        assert_eq!(
            store.set(id, value),
            Err(expected),
            "the core accepted {id}"
        );
        assert_eq!(fs::read(f.json()).unwrap(), saved);
        assert_eq!(store.settings(), &view);
    }
    // A refused request is not a document problem: the next valid set saves.
    store.set("stocks.timeframe", serde_json::json!(3)).unwrap();
    let mut changed = view;
    changed.stocks.timeframe = 3;
    assert_eq!(store.settings(), &changed);
    assert_eq!(Store::open(f.root()).settings(), &changed);
}

#[test]
fn malformed_json_is_not_overwritten() {
    let original = b"{not a settings document at all".to_vec();
    let f = Fixture::new();
    f.write_json(&original);
    let mut store = Store::open(f.root());
    assert!(store.load_problem().is_some(), "the malformed file loaded");
    assert_eq!(store.settings(), &default_view());
    // Nothing is written while the unreadable file stands: not on open, not on set.
    assert_eq!(fs::read(f.json()).unwrap(), original);
    assert!(
        store
            .set("general.window.opacity", serde_json::json!(0.5))
            .is_err()
    );
    assert_eq!(fs::read(f.json()).unwrap(), original);
    // The user's explicit replacement is the only way past the problem.
    store.replace_unreadable().unwrap();
    assert!(store.load_problem().is_none());
    let written = fs::read(f.json()).unwrap();
    assert_ne!(written, original);
    assert_eq!(store.settings(), &default_view());
    store
        .set("graphs.default_height", serde_json::json!(96))
        .unwrap();
    let mut changed = default_view();
    changed.graph_height = 96;
    assert_eq!(Store::open(f.root()).settings(), &changed);
}

#[test]
fn read_only_config_dir_reports_and_runs() {
    // root ignores directory permissions, so the write failure this test
    // pins cannot be produced as root; run it only as a normal user.
    if unsafe { libc::getuid() } == 0 {
        eprintln!("SKIPPED read_only_config_dir_reports_and_runs: running as root");
        return;
    }
    let f = Fixture::new();
    let (conf, expected) = historical(40);
    f.write_conf(&conf);
    let mut permissions = fs::metadata(f.0.join("xrg-ng")).unwrap().permissions();
    permissions.set_mode(0o555);
    fs::set_permissions(f.0.join("xrg-ng"), permissions).unwrap();
    let mut store = Store::open(f.root());
    // The app keeps running on the in-memory settings the migration produced,
    // and reports the write problem instead of failing or retrying it.
    assert_eq!(store.settings(), &expected);
    let problem = store
        .load_problem()
        .expect("the read-only directory is reported");
    assert!(problem.contains("settings.json"), "{problem}");
    // The legacy file is still untouched and no document appeared.
    assert_eq!(fs::read(f.conf()).unwrap(), conf);
    assert!(!f.json().exists());
    // A set is applied in memory only when it can also be written; here it cannot.
    assert!(
        store
            .set("general.window.opacity", serde_json::json!(0.5))
            .is_err()
    );
    assert_eq!(fs::read(f.conf()).unwrap(), conf);
    assert!(!f.json().exists());
    // Removing the write block lets the pending state be saved by the next set.
    let mut permissions = fs::metadata(f.0.join("xrg-ng")).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(f.0.join("xrg-ng"), permissions).unwrap();
    store
        .set("general.window.opacity", serde_json::json!(0.5))
        .unwrap();
    let mut changed = expected;
    changed.window_opacity = 0.5;
    assert_eq!(Store::open(f.root()).settings(), &changed);
}

#[test]
fn read_only_document_reports_and_runs() {
    // A readable document the owner cannot write, inside a writable
    // directory: POSIX rename would replace it regardless, so the store must
    // refuse on its own — the file is never rewritten, the problem names the
    // path, and the loaded settings keep running in memory. The check is the
    // file's own mode, so this pin holds for every uid, root included.
    let f = Fixture::new();
    let mut store = Store::open(f.root());
    let original = custom_settings();
    store.save(&original).unwrap();
    let expected = store.settings().clone();
    let bytes = fs::read(f.json()).unwrap();
    let mut permissions = fs::metadata(f.json()).unwrap().permissions();
    permissions.set_mode(0o444);
    fs::set_permissions(f.json(), permissions).unwrap();
    let mut store = Store::open(f.root());
    // The readable file still decides the settings; only the problem appears.
    assert_eq!(store.settings(), &expected);
    let problem = store
        .load_problem()
        .expect("the read-only document is reported");
    assert!(problem.contains("settings.json"), "{problem}");
    // Neither a set nor a whole-view save replaces the file or the view.
    assert!(
        store
            .set("general.window.opacity", serde_json::json!(0.5))
            .is_err()
    );
    let mut edited = expected.clone();
    edited.graph_height = 120;
    assert!(store.save(&edited).is_err());
    assert_eq!(fs::read(f.json()).unwrap(), bytes);
    assert_eq!(store.settings(), &expected);
    // Restoring the owner's write access lets the next set through.
    let mut permissions = fs::metadata(f.json()).unwrap().permissions();
    permissions.set_mode(0o600);
    fs::set_permissions(f.json(), permissions).unwrap();
    store
        .set("general.window.opacity", serde_json::json!(0.5))
        .unwrap();
    assert!(store.load_problem().is_none());
    let mut changed = expected;
    changed.window_opacity = 0.5;
    assert_eq!(Store::open(f.root()).settings(), &changed);
}

#[test]
fn unknown_keys_from_macos_survive() {
    let f = Fixture::new();
    let macos = br#"{
  "format": "xrg-ng-settings",
  "settings": {
    "experiments.alpha.flag": true,
    "general.window.border_width": 12,
    "general.window.level": "floating",
    "graphs.default_height": 120
  },
  "toplevel.extra": "kept",
  "version": 1
}
"#
    .to_vec();
    f.write_json(&macos);
    let mut store = Store::open(f.root());
    assert!(store.load_problem().is_none());
    let mut expected = default_view();
    expected.graph_height = 120;
    assert_eq!(store.settings(), &expected);
    // A Linux change preserves every macOS-side and unknown key byte-for-byte.
    store
        .set("general.window.opacity", serde_json::json!(0.5))
        .unwrap();
    let saved: serde_json::Value = serde_json::from_slice(&fs::read(f.json()).unwrap()).unwrap();
    assert_eq!(saved["settings"]["general.window.border_width"], 12);
    assert_eq!(saved["settings"]["general.window.level"], "floating");
    assert_eq!(saved["settings"]["experiments.alpha.flag"], true);
    assert_eq!(saved["toplevel.extra"], "kept");
    // And the whole round trip through Linux loads them back unchanged.
    let reopened = Store::open(f.root());
    assert!(reopened.load_problem().is_none());
    let round: serde_json::Value = serde_json::from_slice(&fs::read(f.json()).unwrap()).unwrap();
    assert_eq!(round["settings"]["general.window.border_width"], 12);
    assert_eq!(round["settings"]["experiments.alpha.flag"], true);
    assert_eq!(round["toplevel.extra"], "kept");
    let mut reloaded = expected;
    reloaded.window_opacity = 0.5;
    assert_eq!(reopened.settings(), &reloaded);
    // A section reset also leaves them alone.
    let mut reopened = Store::open(f.root());
    reopened.reset_section("graphs").unwrap();
    let reset: serde_json::Value = serde_json::from_slice(&fs::read(f.json()).unwrap()).unwrap();
    assert_eq!(reset["settings"]["general.window.border_width"], 12);
    assert_eq!(reset["settings"]["experiments.alpha.flag"], true);
    assert_eq!(reset["toplevel.extra"], "kept");
    assert!(reset["settings"].get("graphs.default_height").is_none());
    let mut reset_view = reloaded;
    reset_view.graph_height = 90;
    assert_eq!(reopened.settings(), &reset_view);
}

#[test]
fn ordinary_saves_never_reset_stocks_or_unknown_keys() {
    // A whole-view save owns only the entries a Linux view can derive: a
    // migration of the view names no Stocks entry (they ride along, ruling
    // R2), no macOS-only key and nothing unknown. Whatever the document
    // already holds there must survive `set` → an unrelated save → a Writer
    // flush → reopen, byte for byte.
    let f = Fixture::new();
    let macos = br#"{
  "format": "xrg-ng-settings",
  "settings": {
    "experiments.alpha.flag": true,
    "general.window.border_width": 12,
    "graphs.refresh": 5
  },
  "version": 1
}
"#
    .to_vec();
    f.write_json(&macos);
    let mut store = Store::open(f.root());
    assert!(store.load_problem().is_none());
    // Nondefault Stocks values, stored through the core's own set path.
    store
        .set("stocks.symbols", serde_json::json!("MSFT"))
        .unwrap();
    store.set("stocks.timeframe", serde_json::json!(6)).unwrap();
    let expected = store.settings().clone();
    assert_eq!(expected.stocks.symbols, "MSFT");
    // An unrelated whole-view save: the path the preferences editor and the
    // window-resize flush take. It must carry the change and touch nothing
    // the view does not derive.
    let mut edited = expected.clone();
    edited.window_opacity = 0.75;
    store.save(&edited).unwrap();
    // A Writer flush of an unchanged view is the same save path again.
    let store = Store::open(f.root());
    let writer = Writer::start(store);
    writer.queue(1, edited.clone());
    drop(writer);
    // Reopen: the Stocks values and every key the view cannot name survived
    // both saves, and the unrelated change did land.
    let reopened = Store::open(f.root());
    assert!(reopened.load_problem().is_none());
    assert_eq!(reopened.settings(), &edited);
    assert_eq!(reopened.settings().stocks.symbols, "MSFT");
    assert_eq!(reopened.settings().stocks.timeframe, 6);
    let saved: serde_json::Value = serde_json::from_slice(&fs::read(f.json()).unwrap()).unwrap();
    assert_eq!(saved["settings"]["stocks.symbols"], "MSFT");
    assert_eq!(saved["settings"]["stocks.timeframe"], 6);
    assert_eq!(saved["settings"]["experiments.alpha.flag"], true);
    assert_eq!(saved["settings"]["general.window.border_width"], 12);
    assert_eq!(saved["settings"]["graphs.refresh"], 5);
}

#[test]
fn writer_flushes_whole_settings_through_the_document() {
    // The preferences editor still hands the writer whole settings; every
    // save must reach the file as the same document a direct set would.
    let f = Fixture::new();
    let store = Store::open(f.root());
    let writer = Writer::start(store);
    let mut expected = Settings::default();
    for revision in 1..=250 {
        expected.graph_height = 64 + (revision as u32 % 177);
        expected.modules[0].visible = revision % 2 == 0;
        writer.queue(revision, expected.clone());
    }
    drop(writer);
    assert_eq!(Store::open(f.root()).settings(), &expected);
}

/// A preset (INI-era) settings.conf migrates once too, through the same chain.
#[test]
fn preset_conf_migrates_once_and_never_rewrites() {
    let f = Fixture::new();
    f.write_conf(b"theme=Ocean\n");
    let store = Store::open(f.root());
    assert!(store.load_problem().is_none());
    let mut expected = Settings {
        theme: ThemeChoice::Builtin {
            name: "Ocean".into(),
        },
        ..Settings::default()
    };
    expected.activity_bars.visible = false;
    expected.activity_bars.use_series_colors = false;
    for module in &mut expected.modules {
        module.style = settings::GraphStyle::Hollow;
    }
    assert_eq!(store.settings(), &expected);
    assert_eq!(fs::read(f.conf()).unwrap(), b"theme=Ocean\n");
    assert!(f.json().exists());
    let written = fs::read(f.json()).unwrap();
    let reopened = Store::open(f.root());
    assert_eq!(reopened.settings(), &expected);
    assert_eq!(fs::read(f.json()).unwrap(), written);
}
