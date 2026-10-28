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
# A long saved interval must wake on Apply, with its own unchanged smoke deadline.
XRG_SMOKE_SAMPLING=1 XRG_SMOKE_SAMPLING_PREFS_IMAGE="$output/sampling-preferences.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
# Display-only AI choices must preserve cached totals, sources and rate history.
XRG_SMOKE_AI_VIEW=1 GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
# Dedicated theme conversion gate, with its own unchanged smoke deadline.
XRG_SMOKE_XTF_THEME=1 GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
# Default compact dashboard, with live Linux readings and honest absent-hardware states.
for theme in Classic Midnight; do
    XRG_SMOKE_STYLE="$theme" XRG_SMOKE_IMAGE="$output/compact-$theme.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
        cargo run "${cargo_options[@]}" -- --smoke-test
done

# A real GTK main loop, Cairo drawing and live worker snapshots under X11.
# This does not establish Wayland/compositor or hardware-specific behavior.
XRG_SMOKE_IMAGE="$output/gtk-smoke.png" XRG_SMOKE_PREFS_IMAGE="$output/preferences-smoke.png" XRG_SMOKE_PROCESS_IMAGE="$output/processes-smoke.png" XRG_SMOKE_AI_IMAGE="$output/ai-smoke.png" XRG_SMOKE_AI_SOURCES_IMAGE="$output/ai-sources-smoke.png" XRG_SMOKE_WEATHER_IMAGE="$output/weather-smoke.png" XRG_SMOKE_MENU_IMAGE="$output/menu-smoke.png" XRG_SMOKE_DETAILS_IMAGE="$output/details-smoke.png" XRG_SMOKE_IMPORT_IMAGE="$output/import-smoke.png" XRG_SMOKE_LAYOUT_IMAGE="$output/layout-smoke.png" XRG_SMOKE_NPU_IMAGE="$output/npu-smoke.png" XRG_SMOKE_SENSOR_SOURCES_IMAGE="$output/sensor-sources-smoke.png" XRG_SMOKE_MEMORY_IMAGE="$output/memory-smoke.png" XRG_SMOKE_CPU_IMAGE="$output/cpu-smoke.png" XRG_SMOKE_STYLES_IMAGE="$output/styles-smoke.png" XRG_SMOKE_GRAPH_COLORS_IMAGE="$output/graph-colors-smoke.png" XRG_SMOKE_GRAPH_COLORS_PREFS_IMAGE="$output/graph-colors-preferences-smoke.png" XRG_SMOKE_HEIGHTS_VERTICAL_IMAGE="$output/heights-vertical-smoke.png" XRG_SMOKE_HEIGHTS_HORIZONTAL_IMAGE="$output/heights-horizontal-smoke.png" XRG_SMOKE_HEIGHTS_PREFS_IMAGE="$output/heights-preferences-smoke.png" XRG_SMOKE_BARS_LIVE_IMAGE="$output/bars-live-smoke.png" XRG_SMOKE_BARS_PREFS_IMAGE="$output/bars-preferences-smoke.png" XRG_SMOKE_BARS_IMAGE="$output/bars-smoke.png" XRG_SMOKE_MULTI_SENSORS_IMAGE="$output/multi-sensors-smoke.png" XRG_SMOKE_WIDTHS_VERTICAL_IMAGE="$output/widths-vertical-smoke.png" XRG_SMOKE_WIDTHS_HORIZONTAL_IMAGE="$output/widths-horizontal-smoke.png" XRG_SMOKE_WIDTHS_PREFS_IMAGE="$output/widths-preferences-smoke.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
# Independent process-action gate; signals target only disposable smoke children.
XRG_SMOKE_PROCESS_ACTIONS=1 XRG_SMOKE_PROCESS_MENU_IMAGE="$output/process-actions-menu.png" XRG_SMOKE_PROCESS_CONFIRM_IMAGE="$output/process-actions-confirm.png" XRG_SMOKE_PROCESS_CONTROLS_IMAGE="$output/process-actions-controls.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    cargo_target=$(cargo metadata --manifest-path xrg-linux/rust/Cargo.toml --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')
    echo "binary=$cargo_target/$configuration/xrg-ng-linux" >> "$GITHUB_OUTPUT"
    echo "swift_library=$swift_bin/libXRGSharedCore.so" >> "$GITHUB_OUTPUT"
fi
XRG_SMOKE_WEATHER_GRAPH=1 XRG_SMOKE_WEATHER_GRAPH_IMAGE="$output/weather-graph.png" XRG_SMOKE_WEATHER_STALE_IMAGE="$output/weather-stale.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
# Separate read-only inspector gate, consuming copied reports; no process signals.
G_DEBUG=fatal-criticals XRG_SMOKE_PROCESS_DETAILS=1 XRG_SMOKE_PROCESS_DETAILS_IMAGE="$output/process-details.png" XRG_SMOKE_PROCESS_DETAILS_STALE_IMAGE="$output/process-details-stale.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a --server-args="-screen 0 1280x1400x24" \
    cargo run "${cargo_options[@]}" -- --smoke-test
