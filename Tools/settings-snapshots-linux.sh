#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
#
# Renders the Linux Aether7b settings window's every section, light and
# dark, to PNGs (0.2.3 spec §9: snapshots do not gate CI). Runs the app's
# own --smoke-test harness under Xvfb with software GL inside the ARM64
# validation container, through the same capture machinery the CI gate
# proves there. The window renders in the smoke harness's disposable
# configuration root; the user's own settings document is never touched.
#
# Usage (from the repository root, inside the container image):
#   bash Tools/settings-snapshots-linux.sh OUTPUT_DIR
#
# OUTPUT_DIR receives 16 PNGs: <section>-<light|dark>.png.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 OUTPUT_DIR" >&2
    exit 2
fi
output="$1"
mkdir -p "$output"
configuration="${XRG_SNAPSHOT_CONFIGURATION:-debug}"
case "$configuration" in debug|release) ;; *) echo "XRG_SNAPSHOT_CONFIGURATION must be debug or release" >&2; exit 2;; esac
cargo_options=(--manifest-path xrg-linux/rust/Cargo.toml --locked --all-features)
if [[ "$configuration" == release ]]; then cargo_options+=(--release); fi
# The smoke harness's own deadline (20 seconds) bounds each theme's walk.
# The screen must fit the tallest section's auto-fitted capture window.
for theme in light dark; do
    XRG_SETTINGS_THEME="$theme" \
    XRG_SMOKE_SETTINGS_SNAPSHOT_DIR="$output" \
    XRG_SMOKE_PREFS_IMAGE="$output/prefs-$theme.png" \
    LIBGL_ALWAYS_SOFTWARE=1 dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x8200x24" \
        cargo run "${cargo_options[@]}" -- --smoke-test
done
count=$(find "$output" -name '*.png' | wc -l)
echo "PASS: $count settings snapshots under $output (expecting 16 + 2 prefs)"
if [[ "$count" -lt 16 ]]; then
    echo "Expected at least 16 section snapshots" >&2
    exit 1
fi
