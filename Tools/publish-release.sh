#!/bin/bash
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Publish one verified XRG-ng release: validate both release directories'
# complete public asset inventories, both checksum manifests, the pending
# appcast and the Homebrew tap checkout, then (only with --execute) create
# the signed tag, the GitHub release draft, the appcast commit and the tap
# cask commit. Every check runs before any of those side effects, and no
# check writes to git: origin's main is compared with HEAD through the
# read-only `git ls-remote` (never a fetch).
#
# Usage: bash Tools/publish-release.sh VERSION MAC_RELEASE_DIR LINUX_RELEASE_DIR [--execute]
#
# The default is a dry run that prints every command it would run.
# --execute additionally requires typing the version to confirm and
# XRG_TAP_DIR (the local Homebrew tap checkout) to be a git work tree with a
# clean index and worktree. Pushing the tag/main, pushing the tap and
# un-drafting the release stay manual.
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

# Exactly one dirty path is tolerated: the docs/appcast.xml update written by
# Tools/release-macos.sh, still unstaged (porcelain " M"). Staged, deleted,
# conflicted, untracked or additional dirt refuses the publish.
appcast_pending=false
dirty=$(git status --porcelain)
if [[ -n "$dirty" ]]; then
    if [[ "$dirty" == " M docs/appcast.xml" ]]; then
        appcast_pending=true
    else
        echo "Commit source changes before publishing (only the docs/appcast.xml update may be pending):" >&2
        echo "$dirty" >&2
        exit 1
    fi
fi

head=$(git rev-parse HEAD)
# Read-only remote comparison; a fetch would mutate remote-tracking refs.
if ! remote_main=$(git ls-remote origin refs/heads/main | awk '{print $1}'); then
    echo "Could not query origin's refs/heads/main with git ls-remote" >&2
    exit 1
fi
[[ -n "$remote_main" ]] || { echo "origin has no refs/heads/main to compare with HEAD" >&2; exit 1; }
[[ "$remote_main" == "$head" ]] || { echo "origin's main ($remote_main) does not match HEAD ($head); push main first" >&2; exit 1; }

# Validate the complete public asset inventories and both checksum manifests
# before anything is created. The ASSET lines list exactly the files the
# release draft carries; anything else in the release directories is ignored
# and never uploaded.
preflight=$(python3 - "$version" "$mac_dir" "$linux_dir" "$head" "$appcast_pending" <<'PYVERIFY'
import hashlib
import json
from pathlib import Path
import re
import sys
from xml.etree import ElementTree

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
# The exact basename charset the release manifest producer allows.
SAFE_NAME = re.compile(r"[A-Za-z0-9_.+~\-]+")
MANIFEST_ROW = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9_.+~\-]+)")

version, mac_dir, linux_dir, head, appcast_pending = sys.argv[1:6]
mac_dir, linux_dir = Path(mac_dir), Path(linux_dir)
appcast_pending = appcast_pending == "true"


def refuse(message):
    sys.exit(f"PUBLISH_REFUSED {message}")


def note(message):
    print(message, file=sys.stderr)


def checked_file(directory, name, label):
    """One expected release asset: safe basename, regular file, contained."""
    if not SAFE_NAME.fullmatch(name):
        refuse(f"unsafe asset basename in the {label} release directory: {name!r}")
    path = directory / name
    if path.is_symlink():
        refuse(f"{label} asset is a symlink, not a regular file: {name}")
    if not path.is_file():
        refuse(f"{label} release directory is missing the asset: {name}")
    if path.resolve().parent != directory.resolve():
        refuse(f"{label} asset is not contained in its release directory: {name}")
    return path


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def verify_manifest(directory, manifest_name, payloads, label):
    """Every manifest line well-formed and unique; every payload covered;
    every listed digest matching a regular contained file."""
    manifest = checked_file(directory, manifest_name, label)
    rows = manifest.read_text(encoding="utf-8").splitlines()
    if not rows:
        refuse(f"empty {label} checksum manifest: {manifest_name}")
    covered = {}
    for row in rows:
        match = MANIFEST_ROW.fullmatch(row)
        if not match:
            refuse(f"malformed {label} checksum manifest line: {row!r}")
        expected, name = match.groups()
        if name in covered:
            refuse(f"duplicate {label} checksum manifest entry: {name}")
        actual = digest(checked_file(directory, name, label))
        if actual != expected:
            refuse(f"checksum mismatch in {label}: {name} (expected {expected}, got {actual})")
        covered[name] = expected
    missing = [name for name in payloads if name not in covered]
    if missing:
        refuse(f"the {label} checksum manifest does not cover: {', '.join(missing)}")
    return covered


def read_json(path, label):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        refuse(f"unreadable {label} ({path}): {error}")


# macOS publishes exactly the DMG, ZIP, checksum manifest and build metadata
# (RELEASING.md); verified-build.txt and appcast-item.xml stay local.
stem = f"XRG-ng-{version}-macOS-universal"
mac_assets = [f"{stem}.dmg", f"{stem}.zip", "SHA256SUMS.txt", "release-build.json"]
for name in mac_assets:
    checked_file(mac_dir, name, "macOS")
mac_manifest = verify_manifest(mac_dir, "SHA256SUMS.txt",
                               [f"{stem}.dmg", f"{stem}.zip"], "macOS")
mac_build = read_json(mac_dir / "release-build.json", "macOS release metadata")
if mac_build.get("version") != version or mac_build.get("sourceCommit") != head:
    refuse(f"the macOS release was built from {mac_build.get('sourceCommit')} "
           f"(version {mac_build.get('version')}), not this checkout ({head}) "
           f"of {version}")

# Linux publishes the payloads, SHA256SUMS(+.asc), every payload signature
# and release-metadata.json, exactly as Tools/release-linux.py and
# Tools/release-signing.py produce them; sidecar checksums, the public key
# and the fingerprint stay local.
payloads = []
for arch, deb_arch in (("x86_64", "amd64"), ("aarch64", "arm64")):
    payloads += [f"xrg-ng-{version}-linux-{arch}.tar.gz",
                 f"xrg-ng_{version}-1_{deb_arch}.deb",
                 f"xrg-ng-{version}-1.{arch}.rpm",
                 f"xrg-ng-{version}-1-{arch}.pkg.tar.zst",
                 f"XRG-ng-{version}-{arch}.AppImage"]


def signature(name):
    return name + (".sig" if name.endswith(".pkg.tar.zst") else ".asc")


linux_assets = sorted(payloads + [signature(n) for n in payloads]
                      + ["SHA256SUMS", "SHA256SUMS.asc", "release-metadata.json"])
for name in linux_assets:
    checked_file(linux_dir, name, "Linux")
verify_manifest(linux_dir, "SHA256SUMS",
                payloads + ["release-metadata.json"], "Linux")
linux_build = read_json(linux_dir / "release-metadata.json", "Linux release metadata")
if linux_build.get("version") != version or linux_build.get("revision") != head:
    refuse(f"the Linux release was built from {linux_build.get('revision')} "
           f"(version {linux_build.get('version')}), not this checkout ({head}) "
           f"of {version}")

# The pending appcast must be exactly this release's Sparkle item: it parses,
# carries the item whose sparkle:version is the release build, and that
# item's enclosure length and sparkle:edSignature match the item the macOS
# release recorded in appcast-item.xml.
if appcast_pending:
    item_file = checked_file(mac_dir, "appcast-item.xml", "macOS")
    build = mac_build.get("build")
    if not isinstance(build, str) or not build.strip():
        refuse("the macOS release metadata does not record the build number")
    item_text = item_file.read_text(encoding="utf-8").strip()
    item_text = re.sub(r"^<\?xml[^>]*\?>", "", item_text).strip()
    try:
        item_root = ElementTree.fromstring(
            f'<root xmlns:sparkle="{SPARKLE_NS}">{item_text}</root>')
    except ElementTree.ParseError as error:
        refuse(f"the macOS appcast-item.xml does not parse: {error}")
    items = item_root.findall("item")
    if len(items) != 1:
        refuse("the macOS appcast-item.xml must hold exactly one item")
    item_enclosure = items[0].find("enclosure")
    if item_enclosure is None:
        refuse("the macOS appcast-item.xml item has no enclosure")
    expected_length = item_enclosure.get("length")
    expected_signature = item_enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    if expected_length is None or expected_signature is None:
        refuse("the macOS appcast-item.xml enclosure lacks length or sparkle:edSignature")
    try:
        channel = ElementTree.parse("docs/appcast.xml").getroot().find("channel")
    except ElementTree.ParseError as error:
        refuse(f"the pending docs/appcast.xml does not parse: {error}")
    if channel is None:
        refuse("the pending docs/appcast.xml has no channel")
    pending = None
    for element in channel.findall("item"):
        candidate = element.find(f"{{{SPARKLE_NS}}}version")
        value = candidate.text.strip() if candidate is not None and candidate.text else None
        if value is None:
            value = element.get(f"{{{SPARKLE_NS}}}version")
            if value is None:
                nested = element.find("enclosure")
                if nested is not None:
                    value = nested.get(f"{{{SPARKLE_NS}}}version")
        if value == build.strip():
            pending = element
            break
    if pending is None:
        refuse(f"the pending docs/appcast.xml carries no item for build {build.strip()}")
    enclosure = pending.find("enclosure")
    if enclosure is None or enclosure.get("length") != expected_length \
            or enclosure.get(f"{{{SPARKLE_NS}}}edSignature") != expected_signature:
        refuse("the pending docs/appcast.xml item does not match the release "
               "appcast item (enclosure length or sparkle:edSignature)")
    note("Pending docs/appcast.xml verified: it carries this release's Sparkle item")

note(f"Verified the macOS public asset inventory ({len(mac_assets)} assets) and checksums")
note(f"Verified the Linux public asset inventory ({len(linux_assets)} assets) and checksums")
note("Verified both release directories were built from this exact checkout")

print(f"DMG_SHA256 {mac_manifest[f'{stem}.dmg']}")
for name in mac_assets:
    print(f"ASSET {mac_dir / name}")
for name in linux_assets:
    print(f"ASSET {linux_dir / name}")
PYVERIFY
) || exit 1

dmg_sha256=""
assets=()
while IFS= read -r line; do
    case "$line" in
        DMG_SHA256\ *) dmg_sha256=${line#DMG_SHA256 };;
        ASSET\ *) assets+=("${line#ASSET }");;
        *) echo "PUBLISH_REFUSED unexpected preflight output: $line" >&2; exit 1;;
    esac
done <<< "$preflight"
[[ -n "$dmg_sha256" && ${#assets[@]} -gt 0 ]] || { echo "PUBLISH_REFUSED the preflight did not report the asset inventory" >&2; exit 1; }

check_tap() {
    [[ "$(git -C "$XRG_TAP_DIR" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || {
        echo "XRG_TAP_DIR is not a git work tree: $XRG_TAP_DIR" >&2
        return 1
    }
    git -C "$XRG_TAP_DIR" rev-parse --verify --quiet HEAD >/dev/null || {
        echo "The tap checkout has no commits: $XRG_TAP_DIR" >&2
        return 1
    }
    local dirt
    dirt=$(git -C "$XRG_TAP_DIR" status --porcelain) || {
        echo "Could not inspect the tap worktree: $XRG_TAP_DIR" >&2
        return 1
    }
    [[ -z "$dirt" ]] || {
        echo "Commit or clean the tap checkout first (publishing commits only Casks/xrg-ng.rb):" >&2
        echo "$dirt" >&2
        return 1
    }
}

if $execute; then
    [[ -n "${XRG_TAP_DIR:-}" ]] || { echo "--execute requires XRG_TAP_DIR (the local Homebrew tap checkout)" >&2; exit 1; }
elif [[ -z "${XRG_TAP_DIR:-}" ]]; then
    echo "Dry run without XRG_TAP_DIR: the tap checkout is not validated"
fi
if [[ -n "${XRG_TAP_DIR:-}" ]]; then
    check_tap || exit 1
fi

if $execute; then
    read -r -p "Type $version to confirm publishing: " confirmation
    [[ "$confirmation" == "$version" ]] || { echo "Aborted" >&2; exit 1; }
fi

run() {
    if $execute; then "$@"; else echo "DRY: $*"; fi
}

echo "Creating the signed release tag"
run git tag -s "v$version" -m "XRG-ng $version"

echo "Creating the GitHub release draft with the public asset inventory"
run gh release create "v$version" --draft --title "XRG-ng $version" \
    --notes-file "releases/$version.md" "${assets[@]}"

echo "Committing the updated appcast"
if $appcast_pending; then
    run git add docs/appcast.xml
    run git commit -m "Publish appcast for XRG-ng $version" -- docs/appcast.xml
else
    echo "docs/appcast.xml unchanged; nothing to commit"
fi

echo "Writing the Homebrew cask into the tap"
if $execute; then
    python3 Tools/cask.py --version "$version" --sha256 "$dmg_sha256" \
        --output "$XRG_TAP_DIR/Casks/xrg-ng.rb"
    (cd "$XRG_TAP_DIR" && git add Casks/xrg-ng.rb \
        && git commit -m "xrg-ng $version" -- Casks/xrg-ng.rb)
else
    echo "DRY: python3 Tools/cask.py --version $version --sha256 $dmg_sha256 --output \"\$XRG_TAP_DIR\"/Casks/xrg-ng.rb"
    echo "DRY: (cd \"\$XRG_TAP_DIR\" && git add Casks/xrg-ng.rb && git commit -m \"xrg-ng $version\" -- Casks/xrg-ng.rb)"
fi

cat <<EOF
Remaining manual steps (this script never runs them):
  git push origin main "v$version"
  verify the draft, then: gh release edit "v$version" --draft=false
  push the tap commit: (cd "\${XRG_TAP_DIR:-<tap directory>}" && git push)
EOF
if $execute; then echo "PASS: XRG-ng $version published (tag, release draft, appcast and tap commits done; pushes stay manual)"; else echo "PASS: XRG-ng $version verified in dry run (no tag, release, or commits created)"; fi
