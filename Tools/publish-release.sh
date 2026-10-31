#!/bin/bash
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Publish one verified XRG-ng release: verify both release directories,
# then (only with --execute) create the signed tag, the GitHub release
# draft, the appcast commit and the Homebrew tap cask commit.
#
# Usage: bash Tools/publish-release.sh VERSION MAC_RELEASE_DIR LINUX_RELEASE_DIR [--execute]
#
# The default is a dry run that prints every command it would run.
# --execute additionally requires typing the version to confirm and
# XRG_TAP_DIR (the local Homebrew tap checkout) to be set. Pushing the
# tag/main, pushing the tap and un-drafting the release stay manual.
set -euo pipefail

if [[ $# != 3 && $# != 4 ]]; then
    echo "Usage: bash Tools/publish-release.sh VERSION MAC_RELEASE_DIR LINUX_RELEASE_DIR [--execute]" >&2
    exit 2
fi
version="$1"
mac_dir="$2"
linux_dir="$3"
execute=false
if [[ $# == 4 ]]; then
    [[ "$4" == "--execute" ]] || { echo "Unexpected argument: $4" >&2; exit 2; }
    execute=true
fi

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a numeric release version" >&2; exit 2; }
[[ -d "$mac_dir" && -d "$linux_dir" ]] || { echo "Release directories not found" >&2; exit 1; }
mac_dir=$(cd "$mac_dir" && pwd)
linux_dir=$(cd "$linux_dir" && pwd)
cd "$(dirname "$0")/.."

echo "Publishing XRG-ng $version"
echo "macOS release: $mac_dir"
echo "Linux release: $linux_dir"

# Verification steps always run, including in a dry run.
python3 Tools/check-version.py --expect "$version"
[[ "$(cat latest_version.txt)" == "$version" ]] || { echo "Update latest_version.txt first" >&2; exit 1; }
[[ -f "releases/$version.md" ]] || { echo "Missing releases/$version.md release notes" >&2; exit 1; }

branch=$(git branch --show-current)
[[ "$branch" == "main" ]] || { echo "Publish only from main, currently on '$branch'" >&2; exit 1; }

# Only the appcast update produced by Tools/release-macos.sh may be pending.
unexpected=$(git status --porcelain | grep -v ' docs/appcast\.xml$' || true)
[[ -z "$unexpected" ]] || { echo "Commit source changes before publishing (only the docs/appcast.xml update may be pending):" >&2; echo "$unexpected" >&2; exit 1; }

head=$(git rev-parse HEAD)
git fetch --quiet origin main
origin_main=$(git rev-parse --verify origin/main) || { echo "origin/main not found" >&2; exit 1; }
[[ "$origin_main" == "$head" ]] || { echo "origin/main ($origin_main) does not match HEAD ($head); push main first" >&2; exit 1; }

python3 - "$mac_dir/release-build.json" "$linux_dir/release-metadata.json" "$head" <<'PYMETADATA'
import json
import sys
from pathlib import Path

mac, linux, head = sys.argv[1:4]
for label, path, key in (("macOS", mac, "sourceCommit"), ("Linux", linux, "revision")):
    try:
        revision = json.loads(Path(path).read_text(encoding="utf-8"))[key]
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f"PUBLISH_REFUSED unreadable {label} release metadata ({path}): {error}")
    if revision != head:
        sys.exit(f"PUBLISH_REFUSED the {label} release was built from {revision}, "
                 "not this checkout ({head})")
print("Verified both release directories were built from this exact checkout")
PYMETADATA

stem="XRG-ng-${version}-macOS-universal"
for name in "$stem.dmg" "$stem.zip" SHA256SUMS.txt release-build.json verified-build.txt appcast-item.xml; do
    [[ -f "$mac_dir/$name" ]] || { echo "macOS release missing $name" >&2; exit 1; }
done
[[ -f "$linux_dir/release-metadata.json" && -f "$linux_dir/SHA256SUMS" ]] || { echo "Linux release incomplete" >&2; exit 1; }

verify_sums() {
    local dir="$1" sums="$2" expected name actual
    [[ -s "$dir/$sums" ]] || { echo "Empty or missing $dir/$sums" >&2; return 1; }
    while read -r expected name; do
        [[ -f "$dir/$name" ]] || { echo "checksum file missing: $dir/$name" >&2; return 1; }
        actual=$(shasum -a 256 "$dir/$name" | cut -d' ' -f1)
        [[ "$actual" == "$expected" ]] || { echo "checksum mismatch: $name (expected $expected, got $actual)" >&2; return 1; }
    done < "$dir/$sums"
}
verify_sums "$mac_dir" SHA256SUMS.txt || exit 1
verify_sums "$linux_dir" SHA256SUMS || exit 1

dmg_sha256=$(awk -v name="$stem.dmg" '$2 == name {print $1}' "$mac_dir/SHA256SUMS.txt")
[[ ${#dmg_sha256} == 64 ]] || { echo "No $stem.dmg entry in macOS SHA256SUMS.txt" >&2; exit 1; }
echo "Verified release checksums; DMG sha256: $dmg_sha256"

run() {
    if $execute; then "$@"; else echo "DRY: $*"; fi
}

if $execute; then
    [[ -n "${XRG_TAP_DIR:-}" ]] || { echo "--execute requires XRG_TAP_DIR (the local Homebrew tap checkout)" >&2; exit 1; }
    read -r -p "Type $version to confirm publishing: " confirmation
    [[ "$confirmation" == "$version" ]] || { echo "Aborted" >&2; exit 1; }
fi

echo "Creating the signed release tag"
run git tag -s "v$version" -m "XRG-ng $version"

echo "Creating the GitHub release draft"
mac_assets=("$mac_dir/$stem.dmg" "$mac_dir/$stem.zip" "$mac_dir/SHA256SUMS.txt"
            "$mac_dir/release-build.json" "$mac_dir/verified-build.txt" "$mac_dir/appcast-item.xml")
linux_assets=()
while read -r _ name; do
    linux_assets+=("$linux_dir/$name")
done < "$linux_dir/SHA256SUMS"
run gh release create "v$version" --draft --title "XRG-ng $version" \
    --notes-file "releases/$version.md" "${mac_assets[@]}" "${linux_assets[@]}"

echo "Committing the updated appcast"
if git status --porcelain -- docs/appcast.xml | grep -q .; then
    run git add docs/appcast.xml
    run git commit -m "Publish appcast for XRG-ng $version"
else
    echo "docs/appcast.xml unchanged; nothing to commit"
fi

echo "Writing the Homebrew cask into the tap"
if $execute; then
    python3 Tools/cask.py --version "$version" --sha256 "$dmg_sha256" \
        --output "$XRG_TAP_DIR/Casks/xrg-ng.rb"
    (cd "$XRG_TAP_DIR" && git add Casks/xrg-ng.rb && git commit -m "xrg-ng $version")
else
    echo "DRY: python3 Tools/cask.py --version $version --sha256 $dmg_sha256 --output \"\$XRG_TAP_DIR\"/Casks/xrg-ng.rb"
    echo "DRY: (cd \"\$XRG_TAP_DIR\" && git add Casks/xrg-ng.rb && git commit -m \"xrg-ng $version\")"
fi

cat <<EOF
Remaining manual steps (this script never runs them):
  git push origin main "v$version"
  verify the draft, then: gh release edit "v$version" --draft=false
  push the tap commit: (cd "\${XRG_TAP_DIR:-<tap directory>}" && git push)
EOF
if $execute; then echo "PASS: XRG-ng $version published (tag, release draft, appcast and tap commits done; pushes stay manual)"; else echo "PASS: XRG-ng $version verified in dry run (no tag, release, or commits created)"; fi