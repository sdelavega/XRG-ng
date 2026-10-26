#!/bin/bash
set -euo pipefail

configuration="${1:-Debug}"
case "$configuration" in
    Debug|Release) ;;
    *) echo "Usage: $0 [Debug|Release]" >&2; exit 2 ;;
esac

cd "$(dirname "$0")/.."
# A unique directory lets local reruns preserve earlier logs and result bundles.
output=$(mktemp -d "${TMPDIR:-/tmp}/xrg-ci-${configuration}.XXXXXX")
echo "Build logs and test results: $output"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "results=$output" >> "$GITHUB_OUTPUT"
fi

diagnostics_pid=""
finish_ci() {
    ci_status=$?
    trap - EXIT
    if [[ -n "$diagnostics_pid" ]]; then
        kill "$diagnostics_pid" 2>/dev/null || true
        wait "$diagnostics_pid" 2>/dev/null || true
    fi
    exit "$ci_status"
}
trap finish_ci EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
phase() {
    echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" | tee "$output/phase.log"
}
phase "Universal $configuration app build"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    bash Tools/ci-macos-diagnostics.sh "$output" &
    diagnostics_pid=$!
fi

xcodebuild -version
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng \
    -configuration "$configuration" -destination 'generic/platform=macOS' \
    -derivedDataPath "$output/DerivedData" \
    CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
    build 2>&1 | tee "$output/build.log"

phase "Product architectures, deployment target and notices"
# Verify the shipped executable retains both supported architectures and floor.
app="$output/DerivedData/Build/Products/$configuration/XRG-ng.app"
architectures=$(xcrun lipo -archs "$app/Contents/MacOS/XRG-ng")
for required in arm64 x86_64; do
    [[ " $architectures " == *" $required "* ]] || { echo "Missing architecture: $required" >&2; exit 1; }
done
minimum=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist")
[[ "$minimum" == "26.0" ]] || { echo "Unexpected minimum macOS: $minimum" >&2; exit 1; }

# Product metadata and notices must agree with the renamed app.
python3 - "$app" <<'PYMETADATA'
from pathlib import Path
import plistlib
import sys

app = Path(sys.argv[1])
with (app / "Contents/Info.plist").open("rb") as source:
    info = plistlib.load(source)
assert info["CFBundleName"] == "XRG-ng"
assert info["CFBundleDisplayName"] == "XRG-ng"
assert info["CFBundleExecutable"] == "XRG-ng"
for name in ("Mike Piatek-Jimenez", "Marc Shade", "Stephen de la Vega"):
    assert name in info["NSHumanReadableCopyright"], name
resources = app / "Contents/Resources"
assert "Version 3, 29 June 2007" in (resources / "LICENSE").read_text()
for name in ("COPYRIGHT", "THIRD_PARTY_NOTICES.md", "APSL.txt", "Credits.html"):
    assert (resources / name).is_file(), name
print("Verified XRG-ng metadata, copyright and bundled license notices")
PYMETADATA

phase "Required runtime classes in both architectures"
# Nib-only and dynamically discovered classes must survive archive extraction.
python3 - "$app/Contents/MacOS/XRG-ng" <<'PYCLASSES'
import subprocess
import sys

required = {"_main"} | {"_OBJC_CLASS_$_" + name for name in
            ("XRGAppDelegate", "XRGAITokensNotifications", "XRGSensorViewController", "XRGFlippedView",
             "XRGTemperatureMiner", "XRGTemperatureHardwareReader", "SMCSensorGroup", "SMCSensorSeries", "SMCSensors", "XRGSMCTransport", "SMCInterface", "XRGSMCInterface", "XRGSMCPacketTransport", "XRGAppleSiliconSensorMiner", "XRGAppleHIDTransport",
             "XRGGraphRenderer", "XRGGraphLabels", "XRGGenericView", "XRGStringUtilities", "XRGNonInteractableTextField", "XRGGPUView", "XRGMemoryView", "XRGNetView", "XRGBatteryView", "XRGCPUView", "XRGTemperatureView", "XRGStockView", "XRGDiskView", "XRGDiskMiner", "XRGAITokenView", "XRGBackgroundView", "XRGWeatherView", "XRGGraphWindow", "XRGPrefController")}
# Internal Swift classes can have local symbols in optimized builds.
for architecture in ("arm64", "x86_64"):
    symbols = set(subprocess.check_output(
        ["xcrun", "nm", "-arch", architecture, "-j", sys.argv[1]], text=True).splitlines())
    missing = required - symbols
    if missing:
        raise SystemExit(f"Missing required runtime classes in {architecture}: " + ", ".join(sorted(missing)))
print("Verified required runtime classes in arm64 and x86_64")
PYCLASSES

phase "$configuration test build and execution"
xcodebuild -project XRG-ng.xcodeproj -scheme XRGTests \
    -configuration "$configuration" -destination 'platform=macOS' \
    -derivedDataPath "$output/DerivedData" -resultBundlePath "$output/Tests.xcresult" \
    CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
    test 2>&1 | tee "$output/tests.log"

phase "Test result validation"
# A scheme that accidentally loses its tests must not produce a green CI run.
xcrun xcresulttool get test-results summary --path "$output/Tests.xcresult" > "$output/summary.json"
python3 - "$output/summary.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    summary = json.load(source)
passed = summary.get("passedTests", 0)
failed = summary.get("failedTests", 0)
if passed < 1 or failed != 0:
    raise SystemExit(f"Expected passing tests; passed={passed}, failed={failed}")
print(f"Verified {passed} passing tests, {failed} failures")
PY
phase "Isolated AppKit launch and restore smoke check"
python3 Tools/smoke-macos.py --configuration "$configuration" \
    --products "$output/DerivedData/Build/Products/$configuration" --results "$output/Smoke"
phase "Packaged entry point and original nib check"
python3 Tools/packaged-smoke-macos.py --app "$app" --results "$output/PackagedSmoke"
phase "Validation complete"
