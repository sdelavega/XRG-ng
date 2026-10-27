// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    ffi::OsStr,
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    settings::{self, Module, Settings, Store, ThemeChoice, ThemeDocument, Writer},
    shared,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "xrg-settings-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
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
fn document() -> ThemeDocument {
    ThemeDocument::new(&shared::themes()[2])
}
#[test]
fn legacy_preset_settings_upgrade_only_when_saved() {
    for theme in shared::themes() {
        let f = Fixture::new();
        let original = format!("theme={}\n", theme.name);
        fs::write(f.path(), &original).unwrap();
        let (mut store, mut settings, error) = Store::open(Some(f.path()));
        assert!(error.is_none());
        assert_eq!(
            settings.theme,
            ThemeChoice::Builtin {
                name: theme.name.clone()
            }
        );
        assert_eq!(fs::read_to_string(f.path()).unwrap(), original);
        settings.modules[0].visible = false;
        settings.move_module(Module::Tpu, -9);
        settings.graph_height = 132;
        store.save(&settings).unwrap();
        let (_, loaded, error) = Store::open(Some(f.path()));
        assert!(error.is_none());
        assert_eq!(loaded, settings);
        assert_eq!(loaded.modules[0].id, Module::Tpu);
        assert!(
            !loaded
                .modules
                .iter()
                .find(|m| m.id == Module::Cpu)
                .unwrap()
                .visible
        );
    }
}
#[test]
fn settings_require_supported_versions_bounds_and_exact_module_identity_set() {
    let mut value = Settings::default();
    value.modules[0].id = Module::Memory;
    assert!(value.validate().is_err());
    value = Settings::default();
    value.modules.pop();
    assert!(value.validate().is_err());
    value = Settings::default();
    value.version = 2;
    assert!(value.validate().is_err());
    value = Settings::default();
    for height in [0, 63, 241, u32::MAX] {
        value.graph_height = height;
        assert!(value.validate().is_err());
    }
    for height in [64, 100, 240] {
        value.graph_height = height;
        assert!(value.validate().is_ok());
    }
    for text in [
        "",
        "theme=missing",
        "theme=Ocean\nother=value",
        "[]",
        "{broken",
        "{\"version\":2}",
    ] {
        assert!(Settings::parse(text.as_bytes()).is_err(), "accepted {text}");
    }
}
#[test]
fn custom_palette_round_trips_without_external_file_or_float_precision_loss() {
    let f = Fixture::new();
    let mut theme = document();
    theme.name = "Custom Ocean".into();
    theme.colors[0] = [
        0.12345678912345678,
        0.9999999999999999,
        0.000000000000000123456,
        0.4123456789123456,
    ];
    theme.save(&f.0.join("theme.json")).unwrap();
    let imported = ThemeDocument::load(&f.0.join("theme.json")).unwrap();
    assert_eq!(imported, theme);
    let (mut store, mut settings, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    settings.theme = ThemeChoice::Custom {
        theme: Box::new(imported),
    };
    store.save(&settings).unwrap();
    fs::remove_file(f.0.join("theme.json")).unwrap();
    let (_, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, settings);
    assert_eq!(ThemeDocument::new(&loaded.theme.palette().unwrap()), theme);
}
#[test]
fn all_preset_colors_and_alpha_export_without_changing_shared_presets() {
    for palette in shared::themes() {
        let doc = ThemeDocument::new(&palette);
        let decoded = ThemeDocument::parse(&serde_json::to_vec(&doc).unwrap()).unwrap();
        assert_eq!(decoded.colors, palette.colors);
        assert_eq!(decoded.palette().unwrap().name, palette.name);
    }
    assert_eq!(shared::themes().len(), 6);
}
#[test]
fn theme_schema_rejects_bad_versions_names_colors_and_shape() {
    let base = document();
    for name in [
        "".into(),
        " leading".into(),
        "trailing ".into(),
        "a\nb".into(),
        "x".repeat(81),
    ] {
        let mut value = base.clone();
        value.name = name;
        assert!(value.validate().is_err());
    }
    let mut value = base.clone();
    value.name = "🌊".repeat(80);
    assert!(value.validate().is_ok());
    for bad in [-0.01, 1.01, f64::NAN, f64::INFINITY] {
        let mut value = base.clone();
        value.colors[2][1] = bad;
        assert!(value.validate().is_err());
    }
    for text in [
        "{}",
        "{\"format\":\"xrg-ng-theme\",\"version\":1,\"name\":\"test\",\"colors\":[]}",
    ] {
        assert!(ThemeDocument::parse(text.as_bytes()).is_err());
    }
    let mut value = base.clone();
    value.version = 2;
    assert!(value.validate().is_err());
    value.version = 1;
    value.format = "other-app".into();
    assert!(value.validate().is_err());
    assert!(ThemeDocument::parse(&vec![b' '; 128 * 1024 + 1]).is_err());
}
#[test]
fn unreadable_corrupt_and_future_settings_remain_protected() {
    for original in [
        b"{broken".to_vec(),
        vec![0xff],
        b"{\"version\":999}".to_vec(),
        b"[Colors]\nbackground=#fff".to_vec(),
    ] {
        let f = Fixture::new();
        fs::write(f.path(), &original).unwrap();
        let (mut store, settings, error) = Store::open(Some(f.path()));
        assert!(error.is_some());
        assert_eq!(settings, Settings::default());
        assert!(store.save(&settings).is_err());
        assert_eq!(fs::read(f.path()).unwrap(), original);
    }
}
#[test]
fn external_edits_are_never_silently_overwritten() {
    let f = Fixture::new();
    fs::write(f.path(), "theme=Ocean\n").unwrap();
    let (mut store, settings, _) = Store::open(Some(f.path()));
    fs::write(f.path(), "theme=Paper\n").unwrap();
    assert!(
        store
            .save(&settings)
            .unwrap_err()
            .contains("changed on disk")
    );
    assert_eq!(fs::read_to_string(f.path()).unwrap(), "theme=Paper\n");
}
#[test]
fn default_creation_is_private_atomic_and_keeps_legacy_c_settings_separate() {
    let f = Fixture::new();
    let path = f.0.join("xrg-ng/settings.conf");
    fs::create_dir(f.0.join("xrg-linux")).unwrap();
    fs::write(f.0.join("xrg-linux/settings.conf"), "legacy sentinel").unwrap();
    let (mut store, settings, error) = Store::open(Some(path.clone()));
    assert!(error.is_none());
    assert!(!path.exists());
    store.save(&settings).unwrap();
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        Settings::parse(&fs::read(&path).unwrap()).unwrap(),
        settings
    );
    assert_eq!(
        fs::read_to_string(f.0.join("xrg-linux/settings.conf")).unwrap(),
        "legacy sentinel"
    );
    assert_eq!(fs::read_dir(path.parent().unwrap()).unwrap().count(), 1);
}
#[test]
fn all_hidden_and_module_moves_keep_a_valid_stable_layout() {
    let mut value = Settings::default();
    value.move_module(Module::Cpu, -1);
    assert_eq!(value.modules[0].id, Module::Cpu);
    value.move_module(Module::Tpu, -9);
    assert_eq!(
        value.modules.iter().map(|m| m.id).collect::<Vec<_>>(),
        std::iter::once(Module::Tpu)
            .chain(Module::ALL.into_iter().filter(|m| *m != Module::Tpu))
            .collect::<Vec<_>>()
    );
    for module in &mut value.modules {
        module.visible = false;
    }
    assert!(value.validate().is_ok());
    assert_eq!(
        Settings::parse(&serde_json::to_vec(&value).unwrap()).unwrap(),
        value
    );
}
#[test]
fn xdg_paths_are_absolute_and_do_not_need_environment_mutation() {
    assert_eq!(
        settings::path_from(Some(OsStr::new("/config")), Some(OsStr::new("/home/test"))),
        Some(PathBuf::from("/config/xrg-ng/settings.conf"))
    );
    assert_eq!(
        settings::path_from(Some(OsStr::new("relative")), Some(OsStr::new("/home/test"))),
        Some(PathBuf::from("/home/test/.config/xrg-ng/settings.conf"))
    );
    assert!(settings::path_from(None, None).is_none());
    assert!(
        settings::path_from(Some(OsStr::new("relative")), Some(OsStr::new("relative"))).is_none()
    );
}
#[test]
fn invalid_exports_and_nonregular_destinations_preserve_existing_contents() {
    let f = Fixture::new();
    fs::write(f.0.join("theme.json"), "sentinel").unwrap();
    let mut doc = document();
    doc.colors[0][0] = f64::NAN;
    assert!(doc.save(&f.0.join("theme.json")).is_err());
    assert_eq!(
        fs::read_to_string(f.0.join("theme.json")).unwrap(),
        "sentinel"
    );
    fs::create_dir(f.0.join("directory")).unwrap();
    assert!(document().save(&f.0.join("directory")).is_err());
    assert!(f.0.join("directory").is_dir());
    std::os::unix::fs::symlink(f.0.join("theme.json"), f.path()).unwrap();
    let (mut store, settings, error) = Store::open(Some(f.path()));
    assert!(error.is_some());
    assert!(store.save(&settings).is_err());
    assert!(document().save(&f.path()).is_err());
    assert_eq!(
        fs::read_to_string(f.0.join("theme.json")).unwrap(),
        "sentinel"
    );
}
#[test]
fn bounded_theme_reads_reject_special_and_oversized_files() {
    let f = Fixture::new();
    let fifo = f.0.join("fifo");
    let path = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    assert!(ThemeDocument::load(&fifo).is_err());
    fs::write(f.0.join("large"), vec![b' '; 128 * 1024 + 1]).unwrap();
    assert!(ThemeDocument::load(&f.0.join("large")).is_err());
}
#[test]
fn save_worker_flushes_the_latest_revision_on_shutdown() {
    let f = Fixture::new();
    let (store, _, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    let writer = Writer::start(store);
    let mut expected = Settings::default();
    for revision in 1..=500 {
        expected.graph_height = 64 + (revision as u32 % 177);
        expected.modules[0].visible = revision % 2 == 0;
        writer.queue(revision, expected.clone());
    }
    drop(writer);
    let (_, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
}
#[test]
fn save_worker_reports_persistence_failure_without_destroying_source() {
    let f = Fixture::new();
    fs::write(f.path(), "{broken").unwrap();
    let (store, settings, error) = Store::open(Some(f.path()));
    assert!(error.is_some());
    let writer = Writer::start(store);
    let output = writer.latest.clone();
    writer.queue(42, settings);
    drop(writer);
    let (revision, result) = output.lock().unwrap().take().unwrap();
    assert_eq!(revision, 42);
    assert!(result.is_err());
    assert_eq!(fs::read_to_string(f.path()).unwrap(), "{broken");
}
#[test]
fn module_indices_match_the_sampler_contract_after_ui_reordering() {
    let f = Fixture::new();
    let mut sampler = xrg_ng_linux::engine::Sampler::with_sources(
        xrg_ng_linux::collectors::LinuxSources::with_roots(f.0.join("proc"), &f.0),
    );
    let snapshot = sampler.sample();
    assert_eq!(snapshot.panels.len(), Module::ALL.len());
    for id in Module::ALL {
        assert_eq!(
            snapshot.panels[id.index()].title,
            id.title().split(" · ").next().unwrap()
        );
    }
}
