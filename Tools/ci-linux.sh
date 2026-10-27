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
swift test --scratch-path "$output/swift" --configuration "$configuration"
swift build --scratch-path "$output/swift" --configuration "$configuration" --product XRGSharedCore
swift_bin=$(swift build --scratch-path "$output/swift" --configuration "$configuration" --show-bin-path)
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
XRG_SMOKE_IMAGE="$output/gtk-smoke.png" GSK_RENDERER=cairo dbus-run-session -- xvfb-run -a \
    cargo run "${cargo_options[@]}" -- --smoke-test
