#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && "$1" == /* ]] || { echo 'Use an absolute output directory' >&2; exit 2; }
output="$1"
baseline=9f70a52c6182a6bbab38947501c97d0e64834d2f
scratch=$(mktemp -d "${TMPDIR:-/tmp}/xrg-upgrade-baseline.XXXXXX")
cleanup() {
    git worktree remove --force "$scratch/source" 2>/dev/null || true
    rm -rf -- "$scratch"
}
trap cleanup EXIT
git fetch --no-tags --depth=1 origin "$baseline"
git worktree add --detach "$scratch/source" "$baseline"
# Separate targets protect the already-tested current desktop executable.
env -u XRG_SHARED_LIB_DIR CARGO_TARGET_DIR="$scratch/target" \
    cargo build --manifest-path "$scratch/source/xrg-linux/rust/Cargo.toml" \
    --locked --release --features egui-ui
library=$(find "$scratch/target/release/build" -path '*/out/swift/*' -name libXRGSharedCore.so -type f)
[[ -n "$library" && "$(printf '%s\n' "$library" | wc -l)" -eq 1 ]] || { echo 'Expected one baseline Swift library' >&2; exit 1; }
env -u XRG_SHARED_LIB_DIR CARGO_TARGET_DIR="$scratch/target" GITHUB_OUTPUT= \
    python3 "$scratch/source/Tools/package-linux.py" \
    --binary "$scratch/target/release/xrg-ng-linux" --swift-library "$library" --output "$output"
echo "APPLICATION_BASELINE_OK version=0.1.0 revision=$baseline"
