#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# == 1 && "$1" == /* ]] || { echo 'Use an absolute output directory' >&2; exit 2; }
output="$1"
baseline=50ca1e54f44ed66608b069cc5483dde7f057d281
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
python3 - "$output" <<'PY'
import hashlib
from pathlib import Path
import sys
root = Path(sys.argv[1])
archives = list(root.glob("*.tar.gz"))
assert len(archives) == 1, "Expected exactly one baseline archive"
archive = archives[0]
checksum = archive.with_suffix("").with_suffix(".sha256")
with archive.open("rb") as stream:
    expected = hashlib.file_digest(stream, "sha256").hexdigest()
assert checksum.read_text().split() == [expected, archive.name], "Baseline checksum mismatch"
assert {p.name for p in root.iterdir()} == {archive.name, checksum.name}, "Unexpected baseline files"
PY
echo "APPLICATION_BASELINE_OK version=0.2.0 revision=$baseline"
