#!/bin/bash
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

if [[ $# != 4 ]]; then
    echo "Usage: bash Tools/release-macos.sh VERSION SIGNING_IDENTITY NOTARY_PROFILE NEW_OUTPUT_DIRECTORY" >&2
    exit 2
fi
version="$1"
identity="$2"
notary_profile="$3"
output="$4"
cd "$(dirname "$0")/.."
python3 Tools/check-macos-sensor-license.py
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a numeric release version" >&2; exit 2; }
python3 Tools/check-version.py --expect "$version"
[[ "$(cat latest_version.txt)" == "$version" ]] || { echo "Update latest_version.txt first" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit source changes before building a release" >&2; exit 1; }
[[ "$output" == /* && ! -e "$output" ]] || { echo "Use a new absolute output directory" >&2; exit 1; }
mkdir -p "$output"
source_commit=$(git rev-parse HEAD)
echo "Release artifacts: $output"
echo "Source commit: $source_commit"

echo "Building and signing universal archive"
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$output/XRG-ng.xcarchive" \
    -derivedDataPath "$output/DerivedData" ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM=N5PUFD82GV \
    CODE_SIGN_ENTITLEMENTS=XRG.entitlements ENABLE_HARDENED_RUNTIME=YES \
    ENABLE_RESOURCE_ACCESS_LOCATION=NO archive > "$output/archive.log" 2>&1

app="$output/XRG-ng.app"
ditto "$output/XRG-ng.xcarchive/Products/Applications/XRG-ng.app" "$app"
codesign --verify --deep --strict --verbose=2 "$app" > "$output/signature-verify.log" 2>&1
codesign --display --verbose=4 "$app" > "$output/signature.log" 2>&1
codesign --display --entitlements :- "$app" > "$output/entitlements.plist" 2> "$output/entitlements.log"
python3 - "$app" "$version" "$output" <<'PY'
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

app, version, output = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
spec = importlib.util.spec_from_file_location("check_version", "Tools/check-version.py")
check_version = importlib.util.module_from_spec(spec); spec.loader.exec_module(check_version)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == version
assert info['CFBundleVersion'] == check_version.read_build(Path(".")), info['CFBundleVersion']
# Retain the verified artifact build so release-build.json always describes
# the shipped app, even if the project changes during packaging/notarization.
(output / 'verified-build.txt').write_text(f"{info['CFBundleVersion']}\n")
assert info['CFBundleIdentifier'] == 'com.sdelavega.xrg'
assert info['LSMinimumSystemVersion'] == '26.0'
slices = subprocess.run(['xcrun', 'lipo', '-archs', str(app / 'Contents/MacOS/XRG-ng')], check=True, capture_output=True, text=True).stdout.split()
assert set(slices) == {'arm64', 'x86_64'}
signature = (output / 'signature.log').read_text()
assert 'Authority=Developer ID Application: Stephen de la Vega (N5PUFD82GV)' in signature
assert 'TeamIdentifier=N5PUFD82GV' in signature and 'Timestamp=' in signature
flags = re.search(r'flags=0x([0-9a-fA-F]+)', signature)
assert flags and int(flags.group(1), 16) & 0x10000
entitlement_data = (output / 'entitlements.plist').read_bytes()
entitlements = plistlib.loads(entitlement_data) if entitlement_data.strip() else {}
assert not any(entitlements.values()), entitlements.keys()
assert not (app / 'Contents/Resources/APSL.txt').exists()
assert not (app / 'Contents/Resources/SMCSensorNames.plist').exists()
for name in ('LICENSE', 'COPYRIGHT', 'THIRD_PARTY_NOTICES.md', 'Credits.html'):
    assert (app / 'Contents/Resources' / name).is_file(), name
print('Verified version, build, bundle, deployment floor, both slices, Developer ID, hardened runtime and minimal entitlements')
PY

echo "Notarizing signed app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/notarize.zip"
xcrun notarytool submit "$output/notarize.zip" --keychain-profile "$notary_profile" \
    --wait --timeout 10m --output-format json > "$output/app-notarization.json"
python3 - "$output/app-notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result.get('status') == 'Accepted', result
print('App notarization accepted:', result['id'])
PY
xcrun stapler staple "$app" > "$output/app-staple.log" 2>&1
xcrun stapler validate "$app" >> "$output/app-staple.log" 2>&1
spctl --assess --type execute --verbose=4 "$app" > "$output/app-gatekeeper.log" 2>&1
codesign --verify --deep --strict "$app" >> "$output/signature-verify.log" 2>&1

echo "Packaging ZIP and disk image"
stem="XRG-ng-${version}-macOS-universal"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/$stem.zip"
mkdir "$output/DMG"
ditto "$app" "$output/DMG/XRG-ng.app"
ln -s /Applications "$output/DMG/Applications"
hdiutil create -volname "XRG-ng $version" -srcfolder "$output/DMG" -format UDZO \
    "$output/$stem.dmg" > "$output/dmg-create.log" 2>&1
codesign --sign "$identity" --timestamp "$output/$stem.dmg" > "$output/dmg-sign.log" 2>&1

echo "Notarizing disk image"
xcrun notarytool submit "$output/$stem.dmg" --keychain-profile "$notary_profile" \
    --wait --timeout 10m --output-format json > "$output/dmg-notarization.json"
python3 - "$output/dmg-notarization.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
assert result.get('status') == 'Accepted', result
print('Disk image notarization accepted:', result['id'])
PY
xcrun stapler staple "$output/$stem.dmg" > "$output/dmg-staple.log" 2>&1
xcrun stapler validate "$output/$stem.dmg" >> "$output/dmg-staple.log" 2>&1
codesign --verify --strict "$output/$stem.dmg" >> "$output/dmg-sign.log" 2>&1
spctl --assess --type open --context context:primary-signature --verbose=4 \
    "$output/$stem.dmg" > "$output/dmg-gatekeeper.log" 2>&1
(
    cd "$output"
    shasum -a 256 "$stem.zip" "$stem.dmg" > SHA256SUMS.txt
)
python3 - "$output" "$version" "$source_commit" <<'PY'
import json
from pathlib import Path
import sys
output, version, commit = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
build = (output / 'verified-build.txt').read_text().strip()
(output / 'release-build.json').write_text(json.dumps({'version': version, 'build': build, 'sourceCommit': commit,
    'architectures': ['arm64', 'x86_64'], 'minimumMacOS': '26.0', 'developerID': 'N5PUFD82GV',
    'appNotarized': True, 'dmgNotarized': True, 'ticketsStapled': True, 'gatekeeperAccepted': True}, indent=2) + '\n')
PY
echo "PASS: signed, notarized universal release with stapled tickets and checksums"
