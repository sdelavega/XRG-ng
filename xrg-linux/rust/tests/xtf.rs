// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use plist::{Dictionary, Uid, Value};
use std::{
    fs,
    io::Cursor,
    path::Path,
    sync::atomic::{AtomicU64, Ordering},
};
use xrg_ng_linux::{
    settings::{Settings, ThemeChoice, ThemeDocument},
    shared,
};
const CLASSIC: &[u8] = include_bytes!("../../../XRGTests/Fixtures/ClassicTheme.xtf");
const SRGB: &[u8] = include_bytes!("fixtures/ModernSRGB.xtf");
const SRGB_COLORS: [[f64; 4]; 7] = [
    [0., 0., 0., 0.75],
    [1., 1., 1., 0.4],
    [0.2, 0.4, 0.8, 0.5],
    [1., 0., 0., 0.6],
    [0., 1., 0., 0.7],
    [0., 0., 1., 0.8],
    [0.5, 0.5, 0.5, 0.9],
];
static NEXT: AtomicU64 = AtomicU64::new(0);
fn fixture() -> Value {
    Value::from_reader(Cursor::new(CLASSIC)).unwrap()
}
fn xml(v: &Value) -> Vec<u8> {
    let mut out = Vec::new();
    v.to_writer_xml(&mut out).unwrap();
    out
}
fn archive(v: &mut Value, edit: impl FnOnce(&mut Vec<Value>)) {
    let data = v.as_dictionary().unwrap()["graphFG1Color"]
        .as_data()
        .unwrap();
    let mut a = Value::from_reader(Cursor::new(data)).unwrap();
    edit(
        a.as_dictionary_mut()
            .unwrap()
            .get_mut("$objects")
            .unwrap()
            .as_array_mut()
            .unwrap(),
    );
    let mut data = Vec::new();
    a.to_writer_binary(&mut data).unwrap();
    v.as_dictionary_mut()
        .unwrap()
        .insert("graphFG1Color".into(), Value::Data(data));
}
#[test]
fn original_classic_xtf_matches_the_shared_preset_without_quantizing_alpha() {
    let theme = ThemeDocument::parse(CLASSIC).unwrap();
    let classic = shared::themes()
        .into_iter()
        .find(|t| t.name == "Classic")
        .unwrap();
    for (a, b) in theme
        .colors
        .iter()
        .flatten()
        .zip(classic.colors.iter().flatten())
    {
        assert!((a - b).abs() < 0.000001, "{a} versus {b}");
    }
    assert_eq!(theme.colors[0][3], 0.8999999761581421);
    assert_eq!(theme.name, "Imported macOS");
}
#[test]
fn binary_outer_plist_and_portable_json_preserve_the_converted_palette() {
    let mut binary = Vec::new();
    fixture().to_writer_binary(&mut binary).unwrap();
    let theme = ThemeDocument::parse(&binary).unwrap();
    assert_eq!(theme, ThemeDocument::parse(CLASSIC).unwrap());
    assert_eq!(
        theme,
        ThemeDocument::parse(&serde_json::to_vec(&theme).unwrap()).unwrap()
    );
    let mut settings = Settings::default();
    let before = settings.modules.clone();
    settings.theme = ThemeChoice::Custom {
        theme: Box::new(theme),
    };
    let restored: Settings =
        serde_json::from_slice(&serde_json::to_vec(&settings).unwrap()).unwrap();
    restored.validate().unwrap();
    assert_eq!(restored, settings);
    assert_eq!(restored.modules, before);
}
#[test]
fn separate_transparency_overrides_archived_alpha_and_accepts_numeric_zero() {
    let mut value = fixture();
    value
        .as_dictionary_mut()
        .unwrap()
        .insert("graphFG1Transparency".into(), Value::from(0u64));
    archive(&mut value, |objects| {
        objects[1]
            .as_dictionary_mut()
            .unwrap()
            .insert("NSRGB".into(), Value::Data(b"0.1 0.2 0.3 0.9\0".to_vec()));
    });
    assert_eq!(
        ThemeDocument::parse(&xml(&value)).unwrap().colors[2],
        [0.1, 0.2, 0.3, 0.]
    );
}
#[test]
fn device_grayscale_expands_to_rgb_and_retains_transparency() {
    let mut value = fixture();
    archive(&mut value, |objects| {
        let root = objects[1].as_dictionary_mut().unwrap();
        root.remove("NSRGB");
        root.insert("NSColorSpace".into(), Value::from(4u64));
        root.insert("NSWhite".into(), Value::Data(b"0.25 0.4\0".to_vec()));
    });
    assert_eq!(
        ThemeDocument::parse(&xml(&value)).unwrap().colors[2],
        [0.25, 0.25, 0.25, 1.]
    );
}
#[test]
fn appkit_srgb_uses_original_components_and_separate_alpha() {
    let theme = ThemeDocument::parse(SRGB).unwrap();
    assert_eq!(theme.colors, SRGB_COLORS);
    assert_eq!(
        ThemeDocument::parse(&serde_json::to_vec(&theme).unwrap()).unwrap(),
        theme
    );
    // Optional local evidence from the generator's unmodified AppKit archive.
    // System ICC bytes are not redistributed with the checked-in fixture.
    if let Some(path) = std::env::var_os("XRG_TEST_APPKIT_SRGB") {
        assert_eq!(ThemeDocument::load(Path::new(&path)).unwrap(), theme);
        let mut value = Value::from_reader(Cursor::new(fs::read(path).unwrap())).unwrap();
        archive(&mut value, |objects| {
            let bytes = objects
                .iter_mut()
                .find_map(|value| match value {
                    Value::Data(bytes) => Some(bytes),
                    _ => None,
                })
                .unwrap();
            let index = bytes.len() / 2;
            bytes[index] ^= 1;
        });
        assert!(
            ThemeDocument::parse(&xml(&value))
                .unwrap_err()
                .contains("ICC")
        );
    }
    let mut binary = Vec::new();
    srgb_fixture().to_writer_binary(&mut binary).unwrap();
    assert_eq!(ThemeDocument::parse(&binary).unwrap(), theme);
}
fn srgb_fixture() -> Value {
    Value::from_reader(Cursor::new(SRGB)).unwrap()
}
#[test]
fn srgb_does_not_use_the_calibrated_fallback_or_require_exposure_metadata() {
    let mut value = srgb_fixture();
    archive(&mut value, |objects| {
        let root = objects[1].as_dictionary_mut().unwrap();
        root.remove("NSLinearExposure");
        root.insert("NSRGB".into(), Value::Data(b"-0.1 1.2 0 1\0".to_vec()));
    });
    assert_eq!(
        ThemeDocument::parse(&xml(&value)).unwrap().colors,
        SRGB_COLORS
    );
}
#[test]
fn srgb_rejects_unknown_spaces_profiles_and_space_classes() {
    for edit in 0..5 {
        let mut value = srgb_fixture();
        archive(&mut value, |objects| {
            let index = objects
                .iter()
                .position(|v| v.as_dictionary().is_some_and(|d| d.contains_key("NSID")))
                .unwrap();
            let space = objects[index].as_dictionary_mut().unwrap();
            match edit {
                0 => {
                    space.insert("NSID".into(), Value::from(12u64));
                }
                1 => {
                    space.insert("NSICC".into(), Value::Uid(Uid::new(0)));
                }
                2 => {
                    space.insert("NSICC".into(), Value::Uid(Uid::new(3)));
                    objects[3] = Value::Data(vec![0; 3144]);
                }
                3 => {
                    space.insert("$class".into(), Value::Uid(Uid::new(1)));
                }
                4 => {
                    space.insert("NSSpaceID".into(), Value::from(12u64));
                }
                _ => unreachable!(),
            }
        });
        assert!(ThemeDocument::parse(&xml(&value)).is_err(), "case {edit}");
    }
}
#[test]
fn srgb_rejects_exposure_invalid_components_and_conflicting_fields() {
    for (field, invalid) in [
        ("NSLinearExposure", Value::Data(b"1".to_vec())),
        ("NSLinearExposure", Value::from(0u64)),
        ("NSComponents", Value::Data(b"0.2 NaN 0.8 1".to_vec())),
        ("NSComponents", Value::Data(b"-0.2 0.4 0.8 1".to_vec())),
        ("NSComponents", Value::Data(b"0.2 0.4 1.1 1".to_vec())),
        ("NSComponents", Value::Data(b"0.2 0.4".to_vec())),
        ("NSWhite", Value::Data(b"0.5".to_vec())),
        ("NSColorSpace", Value::from(2u64)),
    ] {
        let mut value = srgb_fixture();
        archive(&mut value, |objects| {
            objects[1]
                .as_dictionary_mut()
                .unwrap()
                .insert(field.into(), invalid);
        });
        assert!(ThemeDocument::parse(&xml(&value)).is_err(), "{field}");
    }
    for field in ["NSComponents", "NSCustomColorSpace"] {
        let mut value = srgb_fixture();
        archive(&mut value, |objects| {
            objects[1].as_dictionary_mut().unwrap().remove(field);
        });
        assert!(ThemeDocument::parse(&xml(&value)).is_err(), "{field}");
    }
}
#[test]
fn boolean_nan_out_of_range_and_missing_transparency_reject_the_entire_theme() {
    for invalid in [
        Value::Boolean(true),
        Value::Real(f64::NAN),
        Value::Real(1.01),
        Value::Real(-0.1),
        Value::from("0.5"),
    ] {
        let mut value = fixture();
        value
            .as_dictionary_mut()
            .unwrap()
            .insert("textTransparency".into(), invalid);
        assert!(
            ThemeDocument::parse(&xml(&value))
                .unwrap_err()
                .contains("transparency")
        );
    }
    let mut value = fixture();
    value
        .as_dictionary_mut()
        .unwrap()
        .remove("textTransparency");
    assert!(ThemeDocument::parse(&xml(&value)).is_err());
}
#[test]
fn malformed_components_and_conflicting_color_models_are_rejected() {
    for invalid in [
        "0.1 0.2",
        "0.1 0.2 0.3 0.4 0.5",
        "NaN 0 0",
        "1.1 0 0",
        "0 0 0\0junk",
    ] {
        let mut value = fixture();
        archive(&mut value, |objects| {
            objects[1]
                .as_dictionary_mut()
                .unwrap()
                .insert("NSRGB".into(), Value::Data(invalid.as_bytes().to_vec()));
        });
        assert!(ThemeDocument::parse(&xml(&value)).is_err(), "{invalid}");
    }
    let mut value = fixture();
    archive(&mut value, |objects| {
        objects[1]
            .as_dictionary_mut()
            .unwrap()
            .insert("NSWhite".into(), Value::Data(b"0.5\0".to_vec()));
    });
    assert!(ThemeDocument::parse(&xml(&value)).is_err());
}
#[test]
fn custom_profiles_pattern_spaces_and_arbitrary_classes_are_never_unarchived() {
    for space in [5u64, 6, 10] {
        let mut value = fixture();
        archive(&mut value, |objects| {
            objects[1]
                .as_dictionary_mut()
                .unwrap()
                .insert("NSColorSpace".into(), Value::from(space));
        });
        assert!(
            ThemeDocument::parse(&xml(&value))
                .unwrap_err()
                .contains("color space")
        );
    }
    let mut value = fixture();
    archive(&mut value, |objects| {
        objects[1]
            .as_dictionary_mut()
            .unwrap()
            .insert("NSCustomColorSpace".into(), Value::Uid(Uid::new(2)));
    });
    assert!(ThemeDocument::parse(&xml(&value)).is_err());
    let mut value = fixture();
    archive(&mut value, |objects| {
        objects[2]
            .as_dictionary_mut()
            .unwrap()
            .insert("$classname".into(), Value::from("OtherClass"));
    });
    assert!(
        ThemeDocument::parse(&xml(&value))
            .unwrap_err()
            .contains("NSColor")
    );
}
#[test]
fn invalid_class_references_and_wrong_archive_envelopes_fail_closed() {
    for uid in [0, 1, u64::MAX] {
        let mut value = fixture();
        archive(&mut value, |objects| {
            objects[1]
                .as_dictionary_mut()
                .unwrap()
                .insert("$class".into(), Value::Uid(Uid::new(uid)));
        });
        assert!(ThemeDocument::parse(&xml(&value)).is_err());
    }
    let mut value = fixture();
    value.as_dictionary_mut().unwrap().insert(
        "graphFG1Color".into(),
        Value::Data(xml(&Value::Dictionary(Dictionary::new()))),
    );
    assert!(ThemeDocument::parse(&xml(&value)).is_err());
}
#[test]
fn duplicate_keys_excess_nesting_and_oversized_themes_are_bounded() {
    let duplicate = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>x</key><integer>1</integer><key>x</key><integer>2</integer></dict></plist>";
    assert!(
        ThemeDocument::parse(duplicate)
            .unwrap_err()
            .contains("Duplicate")
    );
    let mut value = Value::from("leaf");
    for _ in 0..15 {
        value = Value::Array(vec![value]);
    }
    assert!(
        ThemeDocument::parse(&xml(&value))
            .unwrap_err()
            .contains("nesting")
    );
    assert!(
        ThemeDocument::parse(&vec![b' '; 128 * 1024 + 1])
            .unwrap_err()
            .contains("128 KiB")
    );
    assert!(ThemeDocument::parse(b"bplist00broken").is_err());
}
#[test]
fn binary_alias_expansion_and_event_counts_are_bounded() {
    let value = Value::Array(vec![Value::Data(vec![0; 1024]); 300]);
    let mut bytes = Vec::new();
    value.to_writer_binary(&mut bytes).unwrap();
    // The binary writer deduplicates payloads. Expansion still has a hard cap.
    assert!(bytes.len() < 128 * 1024);
    assert!(
        ThemeDocument::parse(&bytes)
            .unwrap_err()
            .contains("payload limit")
    );
    let value = Value::Array(vec![Value::from(0u64); 2050]);
    let mut bytes = Vec::new();
    value.to_writer_binary(&mut bytes).unwrap();
    assert!(
        ThemeDocument::parse(&bytes)
            .unwrap_err()
            .contains("event limit")
    );
}
#[test]
fn loading_and_json_export_leave_the_original_xtf_untouched() {
    let root = std::env::temp_dir().join(format!(
        "xrg-xtf-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&root).unwrap();
    let path = root.join("Classic.xtf");
    fs::write(&path, CLASSIC).unwrap();
    let theme = ThemeDocument::load(&path).unwrap();
    theme.save(&root.join("converted.xrg-theme.json")).unwrap();
    assert_eq!(
        ThemeDocument::load(&root.join("converted.xrg-theme.json")).unwrap(),
        theme
    );
    assert_eq!(fs::read(&path).unwrap(), CLASSIC);
    std::os::unix::fs::symlink(&path, root.join("alias.xtf")).unwrap();
    assert!(ThemeDocument::load(&root.join("alias.xtf")).is_err());
    fs::remove_dir_all(root).unwrap();
}
