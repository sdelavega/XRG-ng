#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2;; esac
output=$(mktemp -d "${TMPDIR:-/tmp}/xrg-linux-ci.XXXXXX")
echo "Linux results: $output"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "results=$output" >> "$GITHUB_OUTPUT"; fi
exec > >(tee "$output/validation.log") 2>&1
swift --version
rustc --version
pkg-config --modversion gtk4
# Tests already build the dynamic product. A second build needlessly re-enters
# Swift 6.4.1's planner (which has crashed in libdispatch on hosted x86_64).
# Keep one build, then require and exercise that exact artifact below.
swift test --scratch-path "$output/swift" --configuration "$configuration" --jobs 2
swift_bin=$(swift build --scratch-path "$output/swift" --configuration "$configuration" --show-bin-path)
if [[ ! -f "$swift_bin/libXRGSharedCore.so" ]]; then
    echo "Swift tests did not produce the required shared library: $swift_bin" >&2
    exit 1
fi
cc Tools/SharedABISmoke.c -I Shared/include -L "$swift_bin" -lXRGSharedCore \
    -Wl,-rpath,"$swift_bin" -o "$output/c-abi-smoke"
"$output/c-abi-smoke"
# Rust must exercise the same Swift artifact verified above, without rebuilding it.
export XRG_SHARED_LIB_DIR="$swift_bin"
cargo_options=(--manifest-path xrg-linux/rust/Cargo.toml --locked --all-features)
if [[ "$configuration" == release ]]; then cargo_options+=(--release); fi
cargo fmt --manifest-path xrg-linux/rust/Cargo.toml --check
cargo clippy "${cargo_options[@]}" --all-targets -- -D warnings
cargo test "${cargo_options[@]}"
cargo run "${cargo_options[@]}" -- --headless --samples 3
# A real GTK main loop, Cairo drawing and live worker snapshots under X11.
# This does not establish Wayland/compositor or hardware-specific behavior.
XRG_SMOKE_IMAGE="$output/gtk-smoke.png" XRG_SMOKE_PREFS_IMAGE="$output/preferences-smoke.png" XRG_SMOKE_PROCESS_IMAGE="$output/processes-smoke.png" XRG_SMOKE_AI_IMAGE="$output/ai-smoke.png" XRG_SMOKE_AI_SOURCES_IMAGE="$output/ai-sources-smoke.png" XRG_SMOKE_WEATHER_IMAGE="$output/weather-smoke.png" XRG_SMOKE_MENU_IMAGE="$output/menu-smoke.png" XRG_SMOKE_DETAILS_IMAGE="$output/details-smoke.png" XRG_SMOKE_IMPORT_IMAGE="$output/import-smoke.png" XRG_SMOKE_LAYOUT_IMAGE="$output/layout-smoke.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    cargo_target=$(cargo metadata --manifest-path xrg-linux/rust/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
    echo "binary=$cargo_target/$configuration/xrg-ng-linux" >> "$GITHUB_OUTPUT"
    echo "swift_library=$swift_bin/libXRGSharedCore.so" >> "$GITHUB_OUTPUT"
fi
