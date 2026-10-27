// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
use std::{env, path::PathBuf, process::Command};

fn main() {
    assert_eq!(
        env::var("HOST").unwrap(),
        env::var("TARGET").unwrap(),
        "Build natively: the Swift library must match the Rust target"
    );
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("../..")
        .canonicalize()
        .unwrap();
    // Use a separate scratch directory: host and Linux builds may share a checkout.
    let scratch = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("swift");
    let configuration = if env::var("PROFILE").unwrap() == "release" {
        "release"
    } else {
        "debug"
    };
    let run = |extra: &[&str]| {
        let output = Command::new(env::var_os("SWIFT").unwrap_or_else(|| "swift".into()))
            .args(["build", "--package-path"])
            .arg(&root)
            .arg("--scratch-path")
            .arg(&scratch)
            .args(["--configuration", configuration])
            .args(extra)
            .output()
            .expect("Swift 6.3+ is required; set SWIFT to its executable");
        assert!(
            output.status.success(),
            "Swift build failed:\n{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    };
    run(&["--product", "XRGSharedCore"]);
    let bin = run(&["--show-bin-path"]);
    let bin = bin.trim();
    println!("cargo:rustc-link-search=native={bin}");
    println!("cargo:rustc-link-lib=dylib=XRGSharedCore");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{bin}");
    // This rpath is for local builds. Installed bundles use their own runtime layout.
    println!("cargo:rerun-if-changed={}", root.join("Shared").display());
    println!(
        "cargo:rerun-if-changed={}",
        root.join("Package.swift").display()
    );
    println!("cargo:rerun-if-env-changed=SWIFT");
}
