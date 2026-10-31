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

# Re-signs Sparkle's nested components inside-out after the archived app is
# copied out and verifies every component. Sparkle documents that signing or
# copying the framework alone leaves its nested XPC services and helpers
# (ad-hoc signed in the distribution) untouched; archive-and-export re-signs
# them, so this pipeline does the equivalent explicitly. Order, as documented:
# XPCServices/*.xpc, Autoupdate, Updater.app, then the framework, then the app
# with its entitlements.
# Usage: sign_sparkle_components APP IDENTITY TEAM ENTITLEMENTS LOG
# IDENTITY "-" exercises the function ad-hoc (no secure timestamp is embedded).
# TEAM is the TeamIdentifier every component must carry ("" for ad-hoc).
sign_sparkle_components() {
    local app="$1" identity="$2" team="$3" entitlements="$4" log="$5"
    local framework="$app/Contents/Frameworks/Sparkle.framework"
    local version_dir component
    version_dir=$(cd "$framework/Versions" && for component in *; do
        [[ -d "$component" && ! -L "$component" ]] && { echo "$component"; break; }
    done)
    [[ -n "$version_dir" ]] || { echo "Sparkle.framework has no version directory" >&2; return 2; }
    local sign_args=(--force --options runtime --sign "$identity" --timestamp)
    for component in "$framework/Versions/$version_dir/XPCServices"/*.xpc; do
        [[ -e "$component" ]] || continue
        echo "codesign ${sign_args[*]} $component" >> "$log"
        codesign "${sign_args[@]}" "$component" >> "$log" 2>&1
    done
    for component in "$framework/Versions/$version_dir/Autoupdate" \
                     "$framework/Versions/$version_dir/Updater.app" \
                     "$framework"; do
        echo "codesign ${sign_args[*]} $component" >> "$log"
        codesign "${sign_args[@]}" "$component" >> "$log" 2>&1
    done
    echo "codesign ${sign_args[*]} --entitlements $entitlements $app" >> "$log"
    codesign "${sign_args[@]}" --entitlements "$entitlements" "$app" >> "$log" 2>&1
    python3 - "$app" "$team" >> "$log" <<'PY'
import plistlib
import re
import subprocess
import sys
from pathlib import Path

app, team = Path(sys.argv[1]), sys.argv[2]
framework = app / 'Contents/Frameworks/Sparkle.framework'
version_dir = next(p for p in (framework / 'Versions').iterdir() if p.is_dir() and not p.is_symlink())
components = sorted((version_dir / 'XPCServices').glob('*.xpc'))
components += [version_dir / 'Autoupdate', version_dir / 'Updater.app', framework, app]
for component in components:
    assert component.exists(), f'missing nested component {component}'
    subprocess.run(['codesign', '--verify', '--strict', str(component)], check=True, capture_output=True)
    display = subprocess.run(['codesign', '--display', '--verbose=4', str(component)],
                             check=True, capture_output=True, text=True)
    details = display.stdout + display.stderr
    match = re.search(r'TeamIdentifier=(.*)', details)
    found = match.group(1).strip() if match else ''
    if found.lower() == 'not set':
        found = ''
    assert found == team, f'{component.name}: TeamIdentifier {found!r} != {team!r}'
    flags = re.search(r'flags=0x([0-9a-fA-F]+)', details)
    assert flags and int(flags.group(1), 16) & 0x10000, f'{component.name}: hardened runtime flag missing'
    entitlement_data = subprocess.run(['codesign', '--display', '--entitlements', ':-', str(component)],
                                      check=True, capture_output=True).stdout
    entitlements = plistlib.loads(entitlement_data) if entitlement_data.strip() else {}
    assert not any(entitlements.values()), f'{component.name}: unexpected entitlements {sorted(entitlements)}'
    print(f'verified {component.name}: team={team or "(ad-hoc)"} hardened-runtime=yes entitlements=none')
PY
    echo "Sparkle components re-signed inside-out and verified (TeamIdentifier $team)"
}

echo "Building and signing universal archive"
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$output/XRG-ng.xcarchive" \
    -derivedDataPath "$output/DerivedData" ONLY_ACTIVE_ARCH=NO 'ARCHS=arm64 x86_64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM=N5PUFD82GV \
    CODE_SIGN_ENTITLEMENTS=XRG.entitlements ENABLE_HARDENED_RUNTIME=YES \
    ENABLE_RESOURCE_ACCESS_LOCATION=NO archive > "$output/archive.log" 2>&1

app="$output/XRG-ng.app"
ditto "$output/XRG-ng.xcarchive/Products/Applications/XRG-ng.app" "$app"
sign_sparkle_components "$app" "$identity" "N5PUFD82GV" "XRG.entitlements" "$output/sparkle-signing.log"
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
# Sparkle ships inside the app and must be signed with the same Developer ID team.
sparkle = app / 'Contents/Frameworks/Sparkle.framework'
assert (sparkle / 'Versions/Current/Sparkle').is_file(), 'Sparkle.framework missing'
sparkle_signature = subprocess.run(['codesign', '--display', '--verbose=2', str(sparkle)],
                                   check=True, capture_output=True, text=True).stderr
sparkle_team = re.search(r'TeamIdentifier=(\S+)', sparkle_signature)
assert sparkle_team is not None and sparkle_team.group(1) == 'N5PUFD82GV', 'Sparkle.framework team mismatch'
assert info.get('SUPublicEDKey'), 'SUPublicEDKey missing or empty'
print('Verified version, build, bundle, deployment floor, both slices, Developer ID, hardened runtime, minimal entitlements and Sparkle update signing')
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

echo "Generating Sparkle appcast item"
sign_update="$output/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
[[ -x "$sign_update" ]] || { echo "sign_update missing (resolve Sparkle in DerivedData first): $sign_update" >&2; exit 1; }
echo "\"$sign_update\" --account XRG-ng \"$output/$stem.dmg\"" > "$output/sign_update.log"
"$sign_update" --account XRG-ng "$output/$stem.dmg" | tee -a "$output/sign_update.log"
IFS=$'\t' read -r ed_signature dmg_length < <(python3 - "$output/sign_update.log" <<'PY'
import re
import sys
text = open(sys.argv[1], encoding="utf-8").read()
match = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', text)
assert match, f"unparsed sign_update output: {text!r}"
print(match.group(1) + "\t" + match.group(2))
PY
)
[[ -n "$ed_signature" && -n "$dmg_length" ]] || { echo "Failed to parse sign_update output" >&2; exit 1; }
printf 'sparkle:edSignature=%s\nlength=%s\n' "$ed_signature" "$dmg_length" > "$output/ed-signature.txt"
build=$(< "$output/verified-build.txt")
# Reuse the verified build recorded during packaging: never re-read the project here.
python3 Tools/appcast.py --appcast docs/appcast.xml --item-out "$output/appcast-item.xml" \
    --version "$version" --build "$build" \
    --url "https://github.com/sdelavega/XRG-ng/releases/download/v${version}/${stem}.dmg" \
    --length "$dmg_length" --ed-signature "$ed_signature" \
    --notes-url "https://github.com/sdelavega/XRG-ng/releases/tag/v${version}" \
    --min-system 26.0
echo "PASS: appcast item generated (docs/appcast.xml is updated in the working tree only, never committed by this script)"
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
