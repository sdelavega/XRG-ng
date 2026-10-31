#!/bin/bash
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Publish one verified XRG-ng release in two resumable phases. First every
# check runs: both release directories' complete public asset inventories,
# both checksum manifests, the unified build number across the project, the
# macOS release metadata and the appcast item, and the Homebrew tap
# checkout. Then --execute performs the local phase only: create (or reuse)
# the release-key-signed annotated tag and commit the pending appcast and
# the tap cask. --create-draft performs the remote phase only, after the tag
# was pushed: it creates the GitHub release draft with `gh release create
# --verify-tag`, or skips creation when a matching draft already exists.
# Every --execute step is idempotent, so a rerun after a failure resumes
# where it stopped.
#
# The release tag is signed by the XRG-ng release OpenPGP key whose primary
# fingerprint signing/fingerprint.txt records, using the release keyring
# "${XRG_RELEASE_GNUPGHOME:-$HOME/.local/share/xrg-ng-release/gnupg}":
# --execute requires that key's secret half in the keyring before any side
# effect, and a tag (existing or just created) counts as signed only when
# git verify-tag succeeds there and reports a VALIDSIG naming exactly that
# primary fingerprint -- anything else fails closed.
#
# No check writes to git: origin's refs are compared with HEAD through the
# read-only `git ls-remote` (never a fetch). The script never pushes
# anything, never un-drafts a release, and never calls gh outside
# --create-draft.
#
# Usage: bash Tools/publish-release.sh VERSION MAC_RELEASE_DIR LINUX_RELEASE_DIR [--execute | --create-draft]
#
# The default is a dry run that prints every command both phases would run.
# --execute and --create-draft each require typing the version to confirm;
# --execute additionally requires XRG_TAP_DIR (the local Homebrew tap
# checkout) to be a git work tree with a clean index and worktree.
# Pushing the tag and main, un-drafting the release and pushing the tap
# stay manual.
set -euo pipefail

if [[ $# != 3 && $# != 4 ]]; then
    echo "Usage: bash Tools/publish-release.sh VERSION MAC_RELEASE_DIR LINUX_RELEASE_DIR [--execute | --create-draft]" >&2
    exit 2
fi
version="$1"
mac_dir="$2"
linux_dir="$3"
execute=false
create_draft=false
if [[ $# == 4 ]]; then
    case "$4" in
        --execute) execute=true;;
        --create-draft) create_draft=true;;
        *) echo "Unexpected argument: $4" >&2; exit 2;;
    esac
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

# The unified project build number (Tools/check-version.py, read_build) is
# the third value every side effect requires to agree (Important 3).
if ! project_build=$(python3 Tools/check-version.py --expect "$version" \
        | sed -n 's/^VERSION_OK .* build \(.*\)$/\1/p'); then
    echo "Could not read the unified project build number" >&2
    exit 1
fi
[[ -n "$project_build" ]] || { echo "The project records no build number" >&2; exit 1; }

branch=$(git branch --show-current)
[[ "$branch" == "main" ]] || { echo "Publish only from main, currently on '$branch'" >&2; exit 1; }

# Exactly one dirty path is tolerated: the docs/appcast.xml update written by
# Tools/release-macos.sh, still unstaged (porcelain " M"). Staged, deleted,
# conflicted, untracked or additional dirt refuses the publish. The dirty
# status only decides whether publishing commits the appcast; the feed
# itself is always validated (R3 and Important 2).
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

# Release-key signing: the tag must be signed by the XRG-ng release OpenPGP
# key, whose primary fingerprint signing/fingerprint.txt records, in the
# release keyring. --execute signs, so it needs the secret key there before
# any side effect; --create-draft and the dry run only verify the existing
# tag and need just the public key.
if ! release_key=$(cat signing/fingerprint.txt 2>/dev/null); then
    echo "signing/fingerprint.txt is missing; it must hold the release key's primary fingerprint" >&2
    exit 1
fi
release_key=$(printf '%s' "$release_key" | tr -d '[:space:]' | tr 'a-f' 'A-F')
[[ "$release_key" =~ ^[0-9A-F]{40}$ ]] || {
    echo "signing/fingerprint.txt must hold the release key's 40-hex-digit primary fingerprint" >&2
    exit 1
}
release_gnupg="${XRG_RELEASE_GNUPGHOME:-$HOME/.local/share/xrg-ng-release/gnupg}"
if $execute; then
    gpg --homedir "$release_gnupg" --batch --list-secret-keys "$release_key" >/dev/null 2>&1 || {
        echo "REFUSED: the XRG-ng release secret key $release_key is not available in the release keyring $release_gnupg (set XRG_RELEASE_GNUPGHOME to override it)" >&2
        exit 1
    }
fi

head=$(git rev-parse HEAD)
tag="v$version"
# An existing local tag is reused only when it is a signed annotated tag
# pointing at this release's commit (R11): HEAD, or -- after the appcast
# commit -- the recorded release commit plus exactly that one commit.
existing_tag_kind() {
    git rev-parse -q --verify "$tag^{commit}" >/dev/null 2>&1 || return 1
    git cat-file -t "$tag" 2>/dev/null || true
}

# A tag counts as signed only when the release keyring verifies its
# signature against the XRG-ng release key: git verify-tag must succeed and
# its raw GnuPG status output must carry a VALIDSIG line whose last field
# (the primary key fingerprint) is exactly the release key. There is no
# textual fallback: an unsigned tag, or one signed by any other key, fails
# closed.
verify_release_tag() {
    local status
    if ! status=$(GNUPGHOME="$release_gnupg" git -c gpg.format=openpgp verify-tag --raw "$tag" 2>&1); then
        echo "REFUSED: $tag is not signed with a verifiable OpenPGP signature (git verify-tag failed; expected the XRG-ng release key $release_key from the keyring $release_gnupg)" >&2
        return 1
    fi
    if ! printf '%s\n' "$status" | awk -v key="$release_key" '
            $1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == key { found = 1 }
            END { exit(found ? 0 : 1) }'; then
        echo "REFUSED: $tag is not signed by the XRG-ng release key $release_key (the signature was made by a different key)" >&2
        return 1
    fi
}

validate_existing_tag() {
    if [[ "$(existing_tag_kind)" != "tag" ]]; then
        echo "REFUSED: v$version already exists but is not an annotated tag; delete it or inspect it manually" >&2
        return 1
    fi
    verify_release_tag || return 1
    local tag_commit extra
    tag_commit=$(git rev-parse "$tag^{commit}")
    if [[ "$tag_commit" != "$head" ]]; then
        extra=$(git log --format=%s "$tag_commit..$head")
        if [[ "$extra" != "Publish appcast for XRG-ng $version" ]]; then
            echo "REFUSED: the existing v$version points at $tag_commit, not HEAD ($head)" >&2
            return 1
        fi
    fi
}

# The commit both release directories must have been built from: HEAD, or
# the existing validated release tag's commit when resuming.
release_commit="$head"
if existing_tag_kind >/dev/null; then
    validate_existing_tag || exit 1
    release_commit=$(git rev-parse "$tag^{commit}")
fi
# Read-only remote comparison; a fetch would mutate remote-tracking refs.
if ! remote_main=$(git ls-remote origin refs/heads/main | awk '{print $1}'); then
    echo "Could not query origin's refs/heads/main with git ls-remote" >&2
    exit 1
fi
[[ -n "$remote_main" ]] || { echo "origin has no refs/heads/main to compare with HEAD" >&2; exit 1; }
# The local phase can run while --execute's appcast commit is still unpushed
# (main is pushed only in manual step 4): tolerate exactly one unpushed local
# commit, the appcast publish commit -- never anything else.
if [[ "$remote_main" != "$head" ]]; then
    extra=$(git log --format=%s "$remote_main..$head")
    [[ "$extra" == "Publish appcast for XRG-ng $version" ]] || {
        echo "origin's main ($remote_main) does not match HEAD ($head); push main first" >&2
        exit 1
    }
fi

# Validate the complete public asset inventories, both checksum manifests,
# the build numbers and the appcast feed before anything is created. The
# ASSET lines list exactly the files the release draft carries; anything
# else in the release directories is ignored and never uploaded.
preflight=$(python3 - "$version" "$mac_dir" "$linux_dir" "$release_commit" "$appcast_pending" "$project_build" <<'PYVERIFY'
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

version, mac_dir, linux_dir, release_commit, appcast_pending, project_build = sys.argv[1:7]
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
if mac_build.get("version") != version or mac_build.get("sourceCommit") != release_commit:
    refuse(f"the macOS release was built from {mac_build.get('sourceCommit')} "
           f"(version {mac_build.get('version')}), not this checkout "
           f"({release_commit}) of {version}")
mac_build_number = mac_build.get("build")
mac_build_number = mac_build_number.strip() \
    if isinstance(mac_build_number, str) and mac_build_number.strip() else None

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
if linux_build.get("version") != version or linux_build.get("revision") != release_commit:
    refuse(f"the Linux release was built from {linux_build.get('revision')} "
           f"(version {linux_build.get('version')}), not this checkout "
           f"({release_commit}) of {version}")

# The appcast feed must always carry this release's Sparkle item (Important
# 2): it parses, holds the item whose sparkle:version is the project build,
# and that item's enclosure length and sparkle:edSignature match the item
# the macOS release recorded in appcast-item.xml. The three build numbers
# must agree before any side effect (Important 3): the project build, the
# macOS release metadata build and the appcast item's sparkle:version.
item_file = checked_file(mac_dir, "appcast-item.xml", "macOS")
if mac_build_number is None:
    refuse(f"the macOS release metadata does not record the build number "
           f"(project build {project_build})")
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
    refuse(f"the docs/appcast.xml feed does not parse: {error}")
if channel is None:
    refuse("the docs/appcast.xml feed has no channel")
feed_builds = []
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
    if value is not None:
        feed_builds.append(value)
        if value == project_build:
            pending = element
if pending is None:
    refuse(f"the docs/appcast.xml feed carries no item for build {project_build} "
           f"(macOS release metadata build {mac_build_number}; feed builds: "
           f"{', '.join(feed_builds) if feed_builds else 'none'})")
enclosure = pending.find("enclosure")
if enclosure is None or enclosure.get("length") != expected_length \
        or enclosure.get(f"{{{SPARKLE_NS}}}edSignature") != expected_signature:
    refuse("the docs/appcast.xml item does not match the release appcast item "
           "(enclosure length or sparkle:edSignature)")
if mac_build_number != project_build:
    refuse(f"the build numbers disagree: project build {project_build}, "
           f"macOS release metadata build {mac_build_number}, "
           f"appcast item build {project_build}")
note(f"Appcast feed verified: it carries this release's Sparkle item for build {project_build}")

note(f"Verified the macOS public asset inventory ({len(mac_assets)} assets) and checksums")
note(f"Verified the Linux public asset inventory ({len(linux_assets)} assets) and checksums")
note(f"Verified both release directories were built from release commit {release_commit}")

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
elif $create_draft; then
    read -r -p "Type $version to confirm creating the GitHub release draft: " confirmation
    [[ "$confirmation" == "$version" ]] || { echo "Aborted" >&2; exit 1; }
fi

run() {
    if $execute; then "$@"; else echo "DRY: $*"; fi
}

do_local_phase() {
    echo "Creating (or reusing) the release-key-signed tag"
    if existing_tag_kind >/dev/null; then
        validate_existing_tag || exit 1
        echo "Reusing the existing signed annotated tag $tag at HEAD"
    else
        run env GNUPGHOME="$release_gnupg" git -c gpg.format=openpgp tag -s -u "$release_key" "$tag" -m "XRG-ng $version"
        if $execute; then
            verify_release_tag || exit 1
        fi
    fi

    echo "Committing the updated appcast"
    if $appcast_pending; then
        run git add docs/appcast.xml
        run git commit -m "Publish appcast for XRG-ng $version" -- docs/appcast.xml
    else
        echo "docs/appcast.xml is already committed with this release's item; nothing to commit"
    fi

    echo "Writing the Homebrew cask into the tap"
    if $execute; then
        expected_cask=$(mktemp "${TMPDIR:-/tmp}/xrg-publish-cask.XXXXXX")
        python3 Tools/cask.py --version "$version" --sha256 "$dmg_sha256" \
            --output "$expected_cask" >/dev/null
        tap_cask="$XRG_TAP_DIR/Casks/xrg-ng.rb"
        if git -C "$XRG_TAP_DIR" show HEAD:Casks/xrg-ng.rb > "$expected_cask.in_head" 2>/dev/null \
                && cmp -s "$expected_cask" "$expected_cask.in_head"; then
            echo "The tap's committed Casks/xrg-ng.rb already matches this release; nothing to commit"
        else
            python3 Tools/cask.py --version "$version" --sha256 "$dmg_sha256" \
                --output "$tap_cask" >/dev/null
            (cd "$XRG_TAP_DIR" && git add Casks/xrg-ng.rb \
                && git commit -m "xrg-ng $version" -- Casks/xrg-ng.rb)
        fi
        rm -f "$expected_cask" "$expected_cask.in_head"
    else
        echo "DRY: python3 Tools/cask.py --version $version --sha256 $dmg_sha256 --output \"\$XRG_TAP_DIR\"/Casks/xrg-ng.rb"
        echo "DRY: (cd \"\$XRG_TAP_DIR\" && git add Casks/xrg-ng.rb && git commit -m \"xrg-ng $version\" -- Casks/xrg-ng.rb)"
    fi
}

draft_manual_steps() {
    cat <<EOF
Remaining manual steps (this script never runs them):
  git push origin "$tag"                          # the tag only
  bash Tools/publish-release.sh "$version" "$mac_dir" "$linux_dir" --create-draft
  verify the draft, then: gh release edit "$tag" --draft=false
  git push origin main                            # the appcast goes live only after the assets
  push the tap commit: (cd "\${XRG_TAP_DIR:-<tap directory>}" && git push)
EOF
}

after_draft_steps() {
    cat <<EOF
Remaining manual steps (this script never runs them):
  verify the draft, then: gh release edit "$tag" --draft=false
  git push origin main                            # the appcast goes live only after the assets
  push the tap commit: (cd "\${XRG_TAP_DIR:-<tap directory>}" && git push)
EOF
}

do_draft_phase() {
    echo "Creating the GitHub release draft with the public asset inventory"
    if $create_draft; then
        # The local signed tag must exist and match HEAD before the remote
        # phase; --create-draft never creates it.
        if ! existing_tag_kind >/dev/null; then
            echo "REFUSED: no local $tag; run the local phase first (bash Tools/publish-release.sh $version ... --execute)" >&2
            exit 1
        fi
        validate_existing_tag || exit 1
        # Read-only remote comparison; the pushed tag must resolve (peeled
        # for annotated tags) to the same commit as the local tag.
        if ! remote_tags=$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}"); then
            echo "Could not query origin's refs/tags/$tag with git ls-remote" >&2
            exit 1
        fi
        remote_tag_commit=""
        remote_tag_object=""
        while read -r sha ref; do
            [[ -n "$sha" ]] || continue
            case "$ref" in
                "refs/tags/$tag^{}") remote_tag_commit=$sha;;
                "refs/tags/$tag") remote_tag_object=$sha;;
            esac
        done <<< "$remote_tags"
        [[ -n "$remote_tag_object" ]] || { echo "REFUSED: origin has no refs/tags/$tag; push the tag first" >&2; exit 1; }
        [[ -n "$remote_tag_commit" ]] || remote_tag_commit=$remote_tag_object
        local_tag_commit=$(git rev-parse "$tag^{commit}")
        if [[ "$remote_tag_commit" != "$local_tag_commit" ]]; then
            echo "REFUSED: origin's $tag resolves to $remote_tag_commit, not the local tag's $local_tag_commit" >&2
            exit 1
        fi
        # An existing release is reused only when its asset names equal the
        # expected public inventory; a mismatch refuses the publish.
        expected_names=$(printf '%s\n' "${assets[@]}" | sed 's|.*/||' | sort)
        if existing_names=$(gh release view "$tag" --json assets --jq '.assets[].name' 2>/dev/null); then
            if [[ "$(printf '%s\n' "$existing_names" | sort)" == "$expected_names" ]]; then
                echo "A GitHub release for $tag already exists with the matching asset inventory; skipping creation"
            else
                echo "REFUSED: the existing GitHub release for $tag carries different assets" >&2
                exit 1
            fi
        else
            gh release create "$tag" --draft --verify-tag \
                --title "XRG-ng $version" --notes-file "releases/$version.md" "${assets[@]}"
        fi
    else
        echo "DRY: gh release create $tag --draft --verify-tag --title XRG-ng $version --notes-file releases/$version.md ${assets[*]}"
    fi
}

if $create_draft; then
    do_draft_phase
    after_draft_steps
    echo "PASS: XRG-ng $version draft phase complete (the draft exists; pushes, un-drafting and the tap push stay manual)"
elif $execute; then
    do_local_phase
    draft_manual_steps
    echo "PASS: XRG-ng $version local phase complete (signed tag, appcast and tap commits done; --create-draft after pushing the tag)"
else
    do_local_phase
    do_draft_phase
    draft_manual_steps
    echo "PASS: XRG-ng $version verified in dry run (no tag, release, or commits created)"
fi