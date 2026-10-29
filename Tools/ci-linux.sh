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
pkg-config --modversion xkbcommon
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
# Fail if the new frontend acquires GTK/GSK/Cairo/GLib through a helper crate.
python3 Tools/check-linux-ui-deps.py
python3 Tools/check-linux-retirement.py
# Native OpenGL painting using Mesa under X11. This does not establish Wayland,
# physical GPU behavior or screen-reader interoperability.
for theme in Classic Midnight; do
    XRG_SMOKE_STYLE="$theme" XRG_SMOKE_IMAGE="$output/compact-$theme.png" LIBGL_ALWAYS_SOFTWARE=1 dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
        cargo run "${cargo_options[@]}" -- --smoke-test
done
XRG_SMOKE_IMAGE="$output/egui-smoke.png" XRG_SMOKE_PREFS_IMAGE="$output/preferences-smoke.png" XRG_SMOKE_LAYOUT_IMAGE="$output/layout-smoke.png" LIBGL_ALWAYS_SOFTWARE=1 dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
# Independent chooser gate: original XTF load, JSON export, replacement review,
# cancelled drafts and legacy import through the production async UI path.
XRG_SMOKE_FILE_PICKER=1 XRG_SMOKE_FILE_PICKER_IMAGE="$output/file-picker.png" XRG_SMOKE_FILE_REPLACE_IMAGE="$output/file-replace.png" LIBGL_ALWAYS_SOFTWARE=1 dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
# Release desktop validation uses actual managed X11 and nested Wayland windows.
# Results are software-renderer costs, not hardware/power measurements.
if [[ "$configuration" == release ]]; then
    cargo build "${cargo_options[@]}" --example desktop_preferences
    desktop_target=$(cargo metadata --manifest-path xrg-linux/rust/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
    for backend in x11 wayland; do
        dbus-run-session -- xvfb-run -a --server-args="-screen 0 1600x1200x24" \
            python3 Tools/desktop-check-linux.py \
            --binary "$desktop_target/release/xrg-ng-linux" \
            --fixture "$desktop_target/release/examples/desktop_preferences" \
            --backend "$backend" --output "$output/desktop-$backend"
    done
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    cargo_target=$(cargo metadata --manifest-path xrg-linux/rust/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
    echo "binary=$cargo_target/$configuration/xrg-ng-linux" >> "$GITHUB_OUTPUT"
    echo "swift_library=$swift_bin/libXRGSharedCore.so" >> "$GITHUB_OUTPUT"
fi
