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
#[test]
fn cpu_retention_upgrades_without_writes_and_rejects_invalid_edits_transactionally() {
    let f = Fixture::new();
    let mut wire = serde_json::to_value(Settings::default()).unwrap();
    wire["version"] = 25.into();
    wire["sampling_interval_ms"] = 375.into();
    wire["metrics"]
        .as_object_mut()
        .unwrap()
        .remove("cpu_history_samples");
    let original = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded.version, 26);
    assert_eq!(loaded.metrics.cpu_history_samples, 0);
    assert_eq!(loaded.sampling_interval_ms, 375);
    assert_eq!(fs::read(f.path()).unwrap(), original);
    loaded.metrics.cpu_history_samples = 257;
    loaded.sampling_interval_ms = 200;
    store.save(&loaded).unwrap();
    let saved = fs::read(f.path()).unwrap();
    assert_eq!(Settings::parse(&saved).unwrap(), loaded);
    loaded.metrics.cpu_history_samples = 20001;
    assert!(store.save(&loaded).is_err());
    assert_eq!(fs::read(f.path()).unwrap(), saved);
    for invalid in [
        serde_json::json!(-1),
        serde_json::json!(2.5),
        serde_json::json!("300"),
        serde_json::json!(true),
        serde_json::json!(null),
    ] {
        wire["metrics"]["cpu_history_samples"] = invalid;
        assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
    }
}
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
    value.version = 27;
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
            .chain(
                Settings::default_order()
                    .into_iter()
                    .filter(|m| *m != Module::Tpu)
            )
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
fn save_notification_can_consume_success_and_failure_results_without_polling() {
    for broken in [false, true] {
        let f = Fixture::new();
        if broken {
            fs::write(f.path(), "{broken").unwrap();
        }
        let (store, settings, _) = Store::open(Some(f.path()));
        let writer = Writer::start(store);
        let output = writer.latest.clone();
        let (send, receive) = std::sync::mpsc::channel();
        writer.on_publish(move || {
            if let Some(result) = output.lock().unwrap().take() {
                send.send(result).unwrap();
            }
        });
        writer.queue(47, settings);
        let (revision, result) = receive
            .recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
        assert_eq!(revision, 47);
        assert_eq!(result.is_err(), broken);
    }
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

#[test]
fn version_one_json_upgrades_on_save_without_losing_custom_layout_or_colors() {
    let f = Fixture::new();
    let mut expected = Settings {
        graph_height: 136,
        theme: ThemeChoice::Custom {
            theme: Box::new(document()),
        },
        ..Default::default()
    };
    expected.modules[0].visible = false;
    expected.move_module(Module::Tpu, -9);
    for module in &mut expected.modules {
        if matches!(module.id, Module::GpuMemory | Module::Fans) {
            module.visible = false;
            module.style = settings::GraphStyle::Hollow;
        }
    }
    let mut wire = serde_json::to_value(&expected).unwrap();
    let object = wire.as_object_mut().unwrap();
    object
        .get_mut("modules")
        .unwrap()
        .as_array_mut()
        .unwrap()
        .truncate(10);
    object.insert("version".into(), 1.into());
    object.remove("metrics");
    object.remove("processes");
    let original = serde_json::to_vec_pretty(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(fs::read(f.path()).unwrap(), original);
    store.save(&loaded).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&fs::read(f.path()).unwrap()).unwrap()["version"],
        26
    );
}
#[test]
fn metric_targets_and_process_filters_persist_and_validate_as_typed_preferences() {
    use xrg_ng_linux::{
        process::Sort,
        settings::{MetricSelection, ProcessView},
    };
    let f = Fixture::new();
    let (mut store, mut settings, _) = Store::open(Some(f.path()));
    settings.metrics = MetricSelection {
        cpu: Some(404),
        network: Some("missing-interface".into()),
        disk: Some("missing-disk".into()),
        gpu: Some("pci:0000:02:00.0".into()),
        temperature: Some("missing-sensor".into()),
        fan: Some("missing-fan".into()),
        ..Default::default()
    };
    settings.processes = ProcessView {
        sort: Sort::Name,
        uid: Some(1000),
        filter: "worker".into(),
        limit: 20,
    };
    store.save(&settings).unwrap();
    let (_, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, settings);
    for name in ["", "..", "../eth0", "bad\nname"] {
        let invalid = MetricSelection {
            network: Some(name.into()),
            ..Default::default()
        };
        assert!(invalid.validate().is_err());
    }
    assert!(
        MetricSelection {
            cpu: Some(u32::MAX),
            ..Default::default()
        }
        .validate()
        .is_err()
    );
    let mut invalid = settings.clone();
    invalid.processes.limit = 201;
    assert!(invalid.validate().is_err());
    invalid.processes.limit = 20;
    invalid.processes.filter = "bad\nfilter".into();
    assert!(invalid.validate().is_err());
    let mut wire = serde_json::to_value(settings).unwrap();
    wire["processes"]["uid"] = (-1).into();
    assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
}
#[test]
fn snapshot_scope_matching_blocks_only_the_metric_whose_target_changed() {
    use xrg_ng_linux::settings::MetricSelection;
    let old = MetricSelection::default();
    let selected = MetricSelection {
        cpu: Some(2),
        ..Default::default()
    };
    assert!(!old.matches(&selected, Module::Cpu));
    for module in Module::ALL.into_iter().filter(|m| *m != Module::Cpu) {
        assert!(old.matches(&selected, module));
    }
}

#[test]
fn version_two_preserves_selection_filters_and_all_hidden_layout_with_new_graphs_hidden() {
    let mut old = Settings {
        version: 2,
        ..Default::default()
    };
    old.modules.truncate(10);
    for module in &mut old.modules {
        module.visible = false;
    }
    old.metrics.gpu = Some("saved-offline-gpu".into());
    old.processes.uid = Some(1000);
    old.processes.filter = "worker".into();
    let migrated = Settings::parse(&serde_json::to_vec(&old).unwrap()).unwrap();
    assert_eq!(migrated.version, 26);
    assert_eq!(migrated.modules.len(), 13);
    assert!(migrated.modules.iter().all(|m| !m.visible));
    assert_eq!(migrated.metrics, old.metrics);
    assert_eq!(migrated.processes, old.processes);
    assert_eq!(&migrated.modules[..10], &old.modules);
    old.modules.pop();
    assert!(Settings::parse(&serde_json::to_vec(&old).unwrap()).is_err());
}
#[test]
fn original_module_indices_remain_stable_and_vram_tracks_the_gpu_selector() {
    let original = [
        Module::Cpu,
        Module::Memory,
        Module::Network,
        Module::Disk,
        Module::Battery,
        Module::Temperature,
        Module::Gpu,
        Module::Ai,
        Module::Processes,
        Module::Tpu,
    ];
    for (index, module) in original.into_iter().enumerate() {
        assert_eq!(module.index(), index);
    }
    assert_eq!(Module::GpuMemory.index(), 10);
    assert_eq!(Module::Fans.index(), 11);
    let before = xrg_ng_linux::settings::MetricSelection::default();
    let after = xrg_ng_linux::settings::MetricSelection {
        gpu: Some("gpu2".into()),
        ..Default::default()
    };
    assert!(!before.matches(&after, Module::GpuMemory));
    assert!(before.matches(&after, Module::Fans));
}

#[test]
fn version_three_ai_defaults_upgrade_without_writes_and_custom_sources_round_trip() {
    let f = Fixture::new();
    let original = Settings::default();
    let mut wire = serde_json::to_value(&original).unwrap();
    wire["version"] = 3.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    wire.as_object_mut().unwrap().remove("ai");
    let bytes = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, original);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.ai.enabled = [false, true, false, true];
    loaded.ai.claude_logs = Some("/offline/custom projects".into());
    loaded.ai.ollama_url = "http://[::1]:11434/local".into();
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
}

#[test]
fn version_four_keeps_ai_and_layout_and_adds_opt_in_weather_without_writing() {
    let f = Fixture::new();
    let mut old = Settings::default();
    old.ai.enabled = [false; 4];
    old.modules[0].visible = false;
    let mut wire = serde_json::to_value(&old).unwrap();
    wire["version"] = 4.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    wire.as_object_mut().unwrap().remove("weather");
    let bytes = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, old);
    assert!(!loaded.weather.enabled);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.weather = xrg_ng_linux::weather::Preferences {
        enabled: true,
        station: "KSEA".into(),
        units: xrg_ng_linux::weather::Units::Us,
        refresh_minutes: 5,
        ..Default::default()
    };
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
}

#[test]
fn version_five_adds_display_defaults_without_writes_and_new_choices_persist() {
    use xrg_ng_linux::{settings::Layout, temperature::Units};
    let f = Fixture::new();
    let mut expected = Settings::default();
    expected.move_module(Module::Fans, -11);
    expected.modules[0].visible = false;
    expected.graph_height = 180;
    expected.metrics.cpu = Some(3);
    expected.ai.enabled = [false; 4];
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 5.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    for field in ["layout", "temperature_units"] {
        wire.as_object_mut().unwrap().remove(field);
    }
    let bytes = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.layout = Layout::Horizontal;
    loaded.temperature_units = Units::Fahrenheit;
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
    for (field, value) in [("layout", "diagonal"), ("temperature_units", "kelvin")] {
        let mut invalid = serde_json::to_value(&loaded).unwrap();
        invalid[field] = value.into();
        assert!(Settings::parse(&serde_json::to_vec(&invalid).unwrap()).is_err());
    }
}

#[test]
fn version_six_preserves_choices_and_adds_default_sensor_sources_without_writing() {
    let f = Fixture::new();
    let mut expected = Settings::default();
    expected.metrics.cpu = Some(2);
    expected.metrics.disk = Some("sda".into());
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 6.into();
    wire["modules"]
        .as_array_mut()
        .unwrap()
        .retain(|m| m["id"] != "weather");
    wire["metrics"]
        .as_object_mut()
        .unwrap()
        .remove("temperature");
    wire["metrics"].as_object_mut().unwrap().remove("fan");
    let original = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(fs::read(f.path()).unwrap(), original);
    store.save(&loaded).unwrap();
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&fs::read(f.path()).unwrap()).unwrap()["version"],
        26
    );
}

#[test]
fn sensor_source_validation_and_snapshot_matching_are_scoped_to_their_graphs() {
    use xrg_ng_linux::settings::MetricSelection;
    let before = MetricSelection::default();
    for (after, module) in [
        (
            MetricSelection {
                temperature: Some("sensor".into()),
                ..Default::default()
            },
            Module::Temperature,
        ),
        (
            MetricSelection {
                fan: Some("fan".into()),
                ..Default::default()
            },
            Module::Fans,
        ),
    ] {
        for candidate in Module::ALL {
            assert_eq!(before.matches(&after, candidate), candidate != module);
        }
    }
    for id in [String::new(), "bad\nname".into(), "x".repeat(4097)] {
        assert!(
            MetricSelection {
                temperature: Some(id.clone()),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
        assert!(
            MetricSelection {
                fan: Some(id),
                ..Default::default()
            }
            .validate()
            .is_err()
        );
    }
}

#[test]
fn weather_module_upgrade_preserves_old_graphs_and_sources_without_enabling_requests() {
    let f = Fixture::new();
    let mut settings = Settings::default();
    settings.modules.pop();
    settings.modules.reverse();
    for module in &mut settings.modules {
        module.visible = false;
    }
    settings.graph_width = 440;
    settings.modules[0].height = Some(164);
    settings.weather = xrg_ng_linux::weather::Preferences {
        station: "KSEA".into(),
        ..Default::default()
    };
    settings.version = 14;
    let original = serde_json::to_vec(&settings).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(&loaded.modules[..12], &settings.modules);
    assert_eq!(loaded.weather, settings.weather);
    assert_eq!(loaded.graph_width, 440);
    assert_eq!(loaded.modules[0].height, Some(164));
    assert!(!loaded.module(Module::Weather).visible);
    assert_eq!(fs::read(f.path()).unwrap(), original);
    store.save(&loaded).unwrap();
    assert_eq!(
        Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
        loaded
    );
    settings.modules.pop();
    assert!(Settings::parse(&serde_json::to_vec(&settings).unwrap()).is_err());
}

#[test]
fn previous_settings_keep_model_details_and_new_display_choice_round_trips_without_writes() {
    let f = Fixture::new();
    let mut expected = Settings::default();
    expected.metrics.cpu = Some(2);
    expected.ai.enabled = [true, false, true, false];
    expected.graph_height = 164;
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 15.into();
    wire.as_object_mut()
        .unwrap()
        .remove("ai_show_model_breakdown");
    let original = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(fs::read(f.path()).unwrap(), original);
    expected.ai_show_model_breakdown = false;
    store.save(&expected).unwrap();
    assert_eq!(
        Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
        expected
    );
    for invalid in [
        serde_json::json!(0),
        serde_json::json!("false"),
        serde_json::Value::Null,
    ] {
        wire["ai_show_model_breakdown"] = invalid;
        assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
    }
}

#[test]
fn sampling_target_upgrade_is_read_only_and_invalid_periods_do_not_replace_saved_settings() {
    let f = Fixture::new();
    let mut expected = Settings::default();
    expected.metrics.cpu = Some(2);
    expected.ai_show_model_breakdown = false;
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 16.into();
    wire.as_object_mut().unwrap().remove("sampling_interval_ms");
    let original = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &original).unwrap();
    let (mut store, loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(fs::read(f.path()).unwrap(), original);
    expected.sampling_interval_ms = 375;
    store.save(&expected).unwrap();
    assert_eq!(
        Settings::parse(&fs::read(f.path()).unwrap()).unwrap(),
        expected
    );
    let saved = fs::read(f.path()).unwrap();
    for invalid in [0, 199, 10001, u32::MAX] {
        let mut bad = expected.clone();
        bad.sampling_interval_ms = invalid;
        assert!(store.save(&bad).is_err());
        assert_eq!(fs::read(f.path()).unwrap(), saved);
    }
    for invalid in [
        serde_json::json!(-1),
        serde_json::json!(500.5),
        serde_json::json!("500"),
        serde_json::json!(true),
        serde_json::Value::Null,
    ] {
        wire["sampling_interval_ms"] = invalid;
        assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
    }
}

#[test]
fn version_seventeen_keeps_appearance_and_migrates_opacity_only_on_save() {
    let f = Fixture::new();
    let mut original = Settings {
        graph_width: 380,
        ..Settings::default()
    };
    original.module_mut(Module::Cpu).visible = false;
    original.move_module(Module::Tpu, -2);
    let mut json = serde_json::to_value(&original).unwrap();
    json["version"] = 17.into();
    json.as_object_mut().unwrap().remove("window_opacity");
    let bytes = serde_json::to_vec(&json).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, original);
    assert_eq!(loaded.window_opacity, 1.);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.window_opacity = 0.425;
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
}

#[test]
fn window_opacity_requires_finite_visible_range_and_json_numbers() {
    let mut value = Settings::default();
    for opacity in [0.1, 0.425, 0.9, 1.] {
        value.window_opacity = opacity;
        value.validate().unwrap();
        assert_eq!(
            Settings::parse(&serde_json::to_vec(&value).unwrap()).unwrap(),
            value
        );
    }
    for opacity in [
        0.,
        -1.,
        0.0999,
        1.0001,
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
    ] {
        value.window_opacity = opacity;
        assert!(value.validate().is_err(), "accepted {opacity}");
    }
    let mut json = serde_json::to_value(Settings::default()).unwrap();
    for invalid in [
        serde_json::json!(null),
        serde_json::json!("0.5"),
        serde_json::json!(false),
        serde_json::json!(0.09),
        serde_json::json!(2),
    ] {
        json["window_opacity"] = invalid;
        assert!(Settings::parse(&serde_json::to_vec(&json).unwrap()).is_err());
    }
}

#[test]
fn version_eighteen_retains_automatic_window_sizing_until_explicit_save() {
    use xrg_ng_linux::settings::WindowSize;
    let f = Fixture::new();
    let mut expected = Settings {
        graph_width: 360,
        window_opacity: 0.8,
        ..Settings::default()
    };
    expected.module_mut(Module::Memory).height = Some(160);
    expected.move_module(Module::Tpu, -2);
    let mut json = serde_json::to_value(&expected).unwrap();
    json["version"] = 18.into();
    json.as_object_mut().unwrap().remove("window_size");
    let bytes = serde_json::to_vec(&json).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(loaded.window_size, None);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.window_size = Some(WindowSize {
        width: 640,
        height: 520,
    });
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
    assert_eq!(reopened.graph_width, 360);
    assert_eq!(reopened.module(Module::Memory).height, Some(160));
}

#[test]
fn explicit_window_sizes_require_two_bounded_integer_dimensions() {
    use xrg_ng_linux::settings::WindowSize;
    for (width, height) in [(100, 100), (8192, 8192), (600, 450)] {
        let settings = Settings {
            window_size: Some(WindowSize { width, height }),
            ..Settings::default()
        };
        settings.validate().unwrap();
        assert_eq!(
            Settings::parse(&serde_json::to_vec(&settings).unwrap()).unwrap(),
            settings
        );
    }
    for bad in [0, 99, 8193, u32::MAX] {
        for (width, height) in [(bad, 450), (600, bad)] {
            let settings = Settings {
                window_size: Some(WindowSize { width, height }),
                ..Settings::default()
            };
            assert!(settings.validate().is_err());
        }
    }
    let mut wire = serde_json::to_value(Settings::default()).unwrap();
    for bad in [
        serde_json::json!({"width":600}),
        serde_json::json!({"height":450}),
        serde_json::json!({"width":600.5,"height":450}),
        serde_json::json!({"width":-600,"height":450}),
        serde_json::json!({"width":"600","height":450}),
        serde_json::json!({"width":600,"height":450,"x":0}),
        serde_json::json!([600, 450]),
        serde_json::json!(true),
    ] {
        wire["window_size"] = bad;
        assert!(
            Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err(),
            "accepted {wire}"
        );
    }
    wire["window_size"] = serde_json::Value::Null;
    assert_eq!(
        Settings::parse(&serde_json::to_vec(&wire).unwrap())
            .unwrap()
            .window_size,
        None
    );
}

#[test]
fn window_size_rejects_duplicate_dimensions() {
    use xrg_ng_linux::settings::WindowSize;
    for text in [
        r#"{"width":600,"height":450,"width":700}"#,
        r#"{"width":600,"height":450,"height":500}"#,
    ] {
        assert!(serde_json::from_str::<WindowSize>(text).is_err());
    }
}

#[test]
fn version_nineteen_network_scale_migrates_without_a_write_or_other_changes() {
    let f = Fixture::new();
    let expected = Settings {
        graph_width: 360,
        window_opacity: 0.8,
        ..Settings::default()
    };
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 19.into();
    wire.as_object_mut().unwrap().remove("network_min_scale");
    let bytes = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(loaded.network_min_scale, 0);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.network_min_scale = 4096;
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
    let imported = xrg_ng_linux::legacy::parse(
        b"[Modules]\nshow_cpu=true\n[Network]\nminimum_scale=1024\n",
        &loaded,
    )
    .unwrap();
    assert_eq!(imported.settings, loaded);
    assert_eq!(imported.skipped, ["[Network] minimum_scale"]);
}

#[test]
fn invalid_network_floors_do_not_replace_saved_preferences() {
    use xrg_ng_linux::settings::network_scale::MAX;
    let f = Fixture::new();
    let value = Settings {
        network_min_scale: MAX,
        ..Settings::default()
    };
    let (mut store, _, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    store.save(&value).unwrap();
    let original = fs::read(f.path()).unwrap();
    let mut invalid = value.clone();
    invalid.network_min_scale = MAX + 1;
    assert!(invalid.validate().is_err());
    assert!(store.save(&invalid).is_err());
    assert_eq!(fs::read(f.path()).unwrap(), original);
    for bad in [
        serde_json::json!(-1),
        serde_json::json!(1.5),
        serde_json::json!("1024"),
        serde_json::json!(true),
        serde_json::json!(null),
        serde_json::json!(MAX + 1),
    ] {
        let mut wire = serde_json::to_value(&value).unwrap();
        wire["network_min_scale"] = bad;
        assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
    }
}

#[test]
fn version_twenty_migrates_with_xe_pmu_disabled_and_rejects_non_boolean_policies() {
    let f = Fixture::new();
    let expected = Settings::default();
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 20.into();
    wire["metrics"].as_object_mut().unwrap().remove("xe_pmu");
    let bytes = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert!(!loaded.metrics.xe_pmu);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.metrics.xe_pmu = true;
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
    let report = xrg_ng_linux::legacy::parse(b"[Modules]\nshow_cpu=true\n", &loaded).unwrap();
    assert!(report.settings.metrics.xe_pmu);
    for bad in [
        serde_json::json!(null),
        serde_json::json!(1),
        serde_json::json!("true"),
    ] {
        let mut wire = serde_json::to_value(&loaded).unwrap();
        wire["metrics"]["xe_pmu"] = bad;
        assert!(Settings::parse(&serde_json::to_vec(&wire).unwrap()).is_err());
    }
}
#[test]
fn xe_policy_invalidates_only_gpu_activity_snapshots() {
    let old = xrg_ng_linux::settings::MetricSelection::default();
    let mut next = old.clone();
    next.xe_pmu = true;
    for module in Module::ALL {
        assert_eq!(old.matches(&next, module), module != Module::Gpu);
    }
}

#[test]
fn version_twenty_four_preserves_expanded_size_and_defaults_to_no_collapse() {
    use xrg_ng_linux::settings::{CollapseAnchor, WindowCollapse, WindowSize};
    let f = Fixture::new();
    let expected = Settings {
        window_size: Some(WindowSize {
            width: 360,
            height: 720,
        }),
        ..Default::default()
    };
    let mut wire = serde_json::to_value(&expected).unwrap();
    wire["version"] = 24.into();
    wire.as_object_mut().unwrap().remove("window_collapse");
    let bytes = serde_json::to_vec(&wire).unwrap();
    fs::write(f.path(), &bytes).unwrap();
    let (mut store, mut loaded, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(loaded, expected);
    assert_eq!(fs::read(f.path()).unwrap(), bytes);
    loaded.window_collapse = WindowCollapse {
        collapsed: true,
        expand_on_hover: true,
        anchor: CollapseAnchor::End,
    };
    store.save(&loaded).unwrap();
    let (_, reopened, error) = Store::open(Some(f.path()));
    assert!(error.is_none());
    assert_eq!(reopened, loaded);
    assert_eq!(reopened.window_size, expected.window_size);
}
#[test]
fn invalid_collapse_settings_are_preserved_on_disk() {
    for bad in [
        serde_json::json!(null),
        serde_json::json!(true),
        serde_json::json!({"collapsed":1}),
        serde_json::json!({"expand_on_hover":"true"}),
        serde_json::json!({"anchor":"middle"}),
        serde_json::json!({"unexpected":false}),
    ] {
        let f = Fixture::new();
        let mut wire = serde_json::to_value(Settings::default()).unwrap();
        wire["window_collapse"] = bad;
        let bytes = serde_json::to_vec(&wire).unwrap();
        fs::write(f.path(), &bytes).unwrap();
        let (mut store, _, error) = Store::open(Some(f.path()));
        assert!(error.is_some());
        assert!(store.save(&Settings::default()).is_err());
        assert_eq!(fs::read(f.path()).unwrap(), bytes);
    }
}
