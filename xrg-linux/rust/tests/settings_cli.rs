// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{
    fs,
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
};

static NEXT: AtomicU64 = AtomicU64::new(0);

#[test]
fn settings_diagnostic_reports_effective_values_without_rewriting_files() {
    let root = std::env::temp_dir().join(format!(
        "xrg-settings-cli-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir(&root).unwrap();
    let file = root.join("xrg-ng/settings.conf");
    let run = || {
        Command::new(env!("CARGO_BIN_EXE_xrg-ng-linux"))
            .arg("--check-settings")
            .env("XDG_CONFIG_HOME", &root)
            .output()
            .unwrap()
    };
    let defaults = run();
    assert!(defaults.status.success());
    let mut settings: serde_json::Value = serde_json::from_slice(&defaults.stdout).unwrap();
    assert!(!file.exists());
    settings["graph_width"] = 210.into();
    settings["sampling_interval_ms"] = 250.into();
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let original = serde_json::to_vec_pretty(&settings).unwrap();
    fs::write(&file, &original).unwrap();
    let valid = run();
    assert!(
        valid.status.success(),
        "{}",
        String::from_utf8_lossy(&valid.stderr)
    );
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&valid.stdout).unwrap(),
        settings
    );
    assert_eq!(fs::read(&file).unwrap(), original);
    fs::write(&file, b"{broken").unwrap();
    let invalid = run();
    assert!(!invalid.status.success());
    assert!(invalid.stdout.is_empty());
    assert!(String::from_utf8_lossy(&invalid.stderr).contains("Preferences invalid"));
    assert_eq!(fs::read(&file).unwrap(), b"{broken");
    fs::remove_dir_all(root).unwrap();
}
