// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    ffi::OsStr,
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    legacy,
    settings::{Module, Settings, Store, ThemeChoice},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "xrg-legacy-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn source(&self) -> PathBuf {
        self.0.join("legacy.conf")
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn rich_base() -> Settings {
    let mut base = Settings::default();
    base.move_module(Module::Tpu, -9);
    base.modules
        .iter_mut()
        .find(|m| m.id == Module::Fans)
        .unwrap()
        .visible = false;
    base.graph_height = 168;
    base.metrics.cpu = Some(2);
    base.processes.filter = "mine".into();
    base.ai.enabled = [false, true, false, true];
    base.weather.enabled = true;
    base.weather.station = "KJFK".into();
    base.validate().unwrap();
    base
}

#[test]
fn display_only_imports_map_legacy_enums_and_reject_invalid_values_atomically() {
    use xrg_ng_linux::{settings::Layout, temperature::Units};
    let base = rich_base();
    let report = legacy::parse(
        b"[Display]\nlayout_orientation=1\n[Temperature]\nunits=1\n",
        &base,
    )
    .unwrap();
    let mut expected = base.clone();
    expected.layout = Layout::Horizontal;
    expected.temperature_units = Units::Fahrenheit;
    assert_eq!(report.settings, expected);
    assert_eq!(report.imported.len(), 2);
    assert!(report.skipped.is_empty());
    let report = legacy::parse(
        b"[Display]\nlayout_orientation=0\n[Temperature]\nunits=0\n",
        &expected,
    )
    .unwrap();
    assert_eq!(report.settings, base);
    for value in ["2", "-1", "vertical", "1.0", "", "true"] {
        for (group, key) in [("Display", "layout_orientation"), ("Temperature", "units")] {
            let bytes = format!("[Modules]\nshow_cpu=false\n[{group}]\n{key}={value}");
            assert!(legacy::parse(bytes.as_bytes(), &base).is_err());
        }
    }
    assert_eq!(base, rich_base());
    let report = legacy::parse(b"[Display]\nlayout_orientation=0\n", &expected).unwrap();
    assert_eq!(report.settings.temperature_units, Units::Fahrenheit);
}
#[test]
fn imports_visibility_and_global_colors_without_changing_other_choices() {
    let base = rich_base();
    let data=b"[Modules]\nshow_cpu=false\nshow_gpu=true\nshow_weather=true\n[Colors]\ngraph_fg1=rgba(0,128,255,0.375)\nborder=#1234\n[Appearance]\ntheme=Ocean\n[Window]\nopacity=0.8\n[GraphStyles]\ncpu_style=2\n[AIToken]\nclaude_cap=123456\n";
    let report = legacy::parse(data, &base).unwrap();
    let mut expected = base.clone();
    expected
        .modules
        .iter_mut()
        .find(|m| m.id == Module::Cpu)
        .unwrap()
        .visible = false;
    expected.theme = report.settings.theme.clone();
    assert_eq!(report.settings, expected);
    let palette = report.settings.theme.palette().unwrap();
    assert_eq!(palette.name, "Imported Linux · Ocean");
    assert_eq!(palette.colors[2], [0., 128. / 255., 1., 0.375]);
    assert_eq!(
        palette.colors[5],
        [17. / 255., 34. / 255., 51. / 255., 68. / 255.]
    );
    assert_eq!(palette.colors[0], base.theme.palette().unwrap().colors[0]);
    assert_eq!(report.imported.len(), 5);
    assert!(report.skipped.contains(&"[Modules] show_weather".into()));
    assert!(
        report
            .summary()
            .contains("VRAM and Fans keep their current visibility")
    );
}
#[test]
fn all_ten_legacy_graph_flags_match_by_identity_and_missing_fields_stay_unchanged() {
    let base = rich_base();
    let data=b"[Modules]\nshow_cpu=false\nshow_memory=false\nshow_network=false\nshow_disk=false\nshow_gpu=false\nshow_temperature=false\nshow_battery=false\nshow_aitoken=false\nshow_process=false\nshow_tpu=false\n";
    let report = legacy::parse(data, &base).unwrap();
    assert!(
        report
            .settings
            .modules
            .iter()
            .filter(|m| !matches!(m.id, Module::Fans | Module::GpuMemory))
            .all(|m| !m.visible)
    );
    assert_eq!(
        report
            .settings
            .modules
            .iter()
            .map(|m| m.id)
            .collect::<Vec<_>>(),
        base.modules.iter().map(|m| m.id).collect::<Vec<_>>()
    );
    assert_eq!(report.settings.theme, base.theme);
    for module in [Module::Fans, Module::GpuMemory] {
        assert_eq!(
            report
                .settings
                .modules
                .iter()
                .find(|m| m.id == module)
                .unwrap(),
            base.modules.iter().find(|m| m.id == module).unwrap()
        );
    }
}
#[test]
fn does_not_guess_a_palette_from_legacy_names_or_enable_services() {
    let base = Settings::default();
    let report=legacy::parse(b"[Modules]\nshow_aitoken=false\nshow_weather=true\n[Appearance]\ntheme=Midnight\n[AIToken]\njsonl_path=/private/source\notel_endpoint=http://remote.example\n",&base).unwrap();
    assert_eq!(report.settings.theme, base.theme);
    assert_eq!(report.settings.ai, base.ai);
    assert_eq!(report.settings.weather, base.weather);
    assert!(
        !report.summary().contains("remote.example")
            && !report.summary().contains("/private/source")
    );
}
#[test]
fn glib_group_merging_last_key_wins_comments_escapes_and_crlf() {
    let data=b"\xef\xbb\xbf# header\r\n[Modules]\r\nshow_cpu=false\r\n[Modules]\r\nshow_cpu = true\r\n[Colors]\r\ntext=rgb(0,0,0)\r\n[Appearance]\r\ntheme=\\sOld\\sTheme\r\n";
    let report = legacy::parse(data, &Settings::default()).unwrap();
    assert_eq!(report.repeated_keys, 1);
    assert!(report.settings.modules[0].visible);
    assert_eq!(
        report.settings.theme.palette().unwrap().name,
        "Imported Linux · Old Theme"
    );
    assert!(report.summary().contains("last value wins"));
    assert!(legacy::parse(b"[modules]\nshow_cpu=false", &Settings::default()).is_err());
}
#[test]
fn preserves_black_zero_alpha_and_all_seven_color_positions() {
    let data=b"[Colors]\nbackground=rgba(0,0,0,0)\ngraph_bg=rgb(1,2,3)\ngraph_fg1=#abc\ngraph_fg2=#abcdef\ngraph_fg3=#12345678\nborder=#1234\ntext=rgba(255,254,253,0.999)";
    let c = legacy::parse(data, &Settings::default())
        .unwrap()
        .settings
        .theme
        .palette()
        .unwrap()
        .colors;
    assert_eq!(c[0], [0.; 4]);
    assert_eq!(c[1], [1. / 255., 2. / 255., 3. / 255., 1.]);
    assert_eq!(c[2], [170. / 255., 187. / 255., 204. / 255., 1.]);
    assert_eq!(c[3], [171. / 255., 205. / 255., 239. / 255., 1.]);
    assert_eq!(c[4], [18. / 255., 52. / 255., 86. / 255., 120. / 255.]);
    assert_eq!(c[6], [1., 254. / 255., 253. / 255., 0.999]);
}
#[test]
fn malformed_recognized_values_fail_the_whole_import_and_leave_base_intact() {
    let base = rich_base();
    let before = base.clone();
    for bad in ["True", "1", "true #comment", "", "yes"] {
        assert!(
            legacy::parse(
                format!("[Modules]\nshow_gpu=false\nshow_cpu={bad}").as_bytes(),
                &base
            )
            .is_err()
        );
    }
    for bad in [
        "rgba(0,0,0,NaN)",
        "rgba(0,0,0,1.01)",
        "rgb(-1,0,0)",
        "rgb(256,0,0)",
        "rgba(0,0,0)",
        "#☃☃",
        "#12",
        "red",
        "rgba(0,0,0,inf)",
        "rgb(1,2,3)\\q",
    ] {
        assert!(
            legacy::parse(
                format!("[Modules]\nshow_cpu=false\n[Colors]\ntext={bad}").as_bytes(),
                &base
            )
            .is_err(),
            "{bad}"
        );
    }
    for bad in [
        b"[Modules\nshow_cpu=false".as_slice(),
        b"show_cpu=false",
        b";not a GLib comment\n[Modules]\nshow_cpu=false",
        b"[Modules]\n=1",
        b"[Modules]\nshow_cpu=false\0",
        &[0xff],
        b"{}",
    ] {
        assert!(legacy::parse(bad, &base).is_err());
    }
    assert_eq!(base, before);
}
#[test]
fn bounded_input_names_lines_and_entry_count_do_not_publish_partial_imports() {
    let base = Settings::default();
    for data in [
        vec![b'x'; 131073],
        format!("[Modules]\nshow_cpu=true\n{}", "\n".repeat(4097)).into_bytes(),
        format!("[Modules]\nshow_cpu=true\n{}=0", "x".repeat(129)).into_bytes(),
        format!(
            "[Modules]\nshow_cpu=true\n[Other]\nvalue={}",
            "x".repeat(8193)
        )
        .into_bytes(),
        format!(
            "[Modules]\nshow_cpu=true\n[Other]\n{}",
            (0..1025)
                .map(|n| format!("key{n}=value\n"))
                .collect::<String>()
        )
        .into_bytes(),
    ] {
        assert!(legacy::parse(&data, &base).is_err());
    }
    assert!(
        legacy::parse(b"[Window]\nwidth=600", &base)
            .unwrap_err()
            .contains("No supported")
    );
}
#[test]
fn source_is_read_only_imported_copy_saves_only_to_new_store() {
    let f = Fixture::new();
    let data = b"[Modules]\nshow_cpu=false\n[Colors]\ntext=rgb(1,2,3)\n";
    fs::write(f.source(), data).unwrap();
    let source = fs::read(f.source()).unwrap();
    let new_path = f.0.join("new/settings.conf");
    let (mut store, base, error) = Store::open(Some(new_path.clone()));
    assert!(error.is_none());
    let import = legacy::load(&f.source(), &base).unwrap();
    assert!(!new_path.exists());
    assert_eq!(fs::read(f.source()).unwrap(), source);
    store.save(&import.settings).unwrap();
    assert_eq!(fs::read(f.source()).unwrap(), source);
    let (_, loaded, error) = Store::open(Some(new_path));
    assert!(error.is_none());
    assert_eq!(loaded, import.settings);
    assert!(Settings::parse(data).is_err());
}
#[test]
fn symlink_fifo_directory_missing_and_oversized_sources_are_rejected() {
    let f = Fixture::new();
    fs::write(f.source(), b"[Modules]\nshow_cpu=false").unwrap();
    let base = Settings::default();
    std::os::unix::fs::symlink(f.source(), f.0.join("link")).unwrap();
    assert!(legacy::load(&f.0.join("link"), &base).is_err());
    assert!(legacy::load(&f.0, &base).is_err());
    assert!(legacy::load(&f.0.join("missing"), &base).is_err());
    let fifo = f.0.join("fifo");
    let raw = std::ffi::CString::new(fifo.as_os_str().as_encoded_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(raw.as_ptr(), 0o600) }, 0);
    assert!(legacy::load(&fifo, &base).is_err());
    fs::File::create(f.source())
        .unwrap()
        .set_len(131073)
        .unwrap();
    assert!(legacy::load(&f.source(), &base).is_err());
}
#[test]
fn legacy_path_is_separate_and_follows_xdg_and_home_without_probing() {
    assert_eq!(
        legacy::path_from(Some(OsStr::new("/custom")), Some(OsStr::new("/home/me"))),
        Some(PathBuf::from("/custom/xrg-linux/settings.conf"))
    );
    assert_eq!(
        legacy::path_from(Some(OsStr::new("relative")), Some(OsStr::new("/home/me"))),
        Some(PathBuf::from("/home/me/.config/xrg-linux/settings.conf"))
    );
    assert_eq!(legacy::path_from(None, None), None);
}
#[test]
fn invalid_drafts_are_not_replaced_and_long_theme_labels_fit_new_format() {
    let base = Settings {
        graph_height: 0,
        ..Settings::default()
    };
    assert!(
        legacy::parse(b"[Modules]\nshow_cpu=false", &base)
            .unwrap_err()
            .contains("current Preferences draft")
    );
    let data = format!(
        "[Colors]\ntext=#fff\n[Appearance]\ntheme={} rest",
        "x".repeat(62)
    );
    let import = legacy::parse(data.as_bytes(), &Settings::default()).unwrap();
    import.settings.validate().unwrap();
    assert!(
        import
            .settings
            .theme
            .palette()
            .unwrap()
            .name
            .chars()
            .count()
            <= 80
    );
    assert!(matches!(import.settings.theme, ThemeChoice::Custom { .. }));
}
