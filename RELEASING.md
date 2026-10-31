# XRG-ng releases

Every platform ships the same version: the Xcode project (all six targets),
`latest_version.txt` and `xrg-linux/rust/Cargo.toml` (with its lockfile) must
agree, and the shared Xcode build number is bumped for each release. Verify the
whole agreement with `python3 Tools/check-version.py --expect X.Y.Z` before
building anything. One GitHub release per version, tagged `vX.Y.Z`, carries the
macOS and the Linux assets together. Publishing that release marks it as
Latest: `--latest` is now the default, so do not pass `--latest=false` for a
regular version.

# Linux side

1. Run packaging/signature unit tests and Rust formatting/tests. Commit and push
   the sources. Dispatch Linux CI with release package naming:
   `gh workflow run linux.yml --ref main -f release_candidate=true`.
2. All ten build/desktop/runtime jobs must succeed on that exact commit. The
   workflow also builds the frozen 0.2.0 application in a separate target directory
   and tests a real 0.2.0-to-0.2.1 archive upgrade with custom preferences, in
   addition to native packaging revision upgrades.
3. On the signing Mac, install GnuPG and RPM tools, and use the dedicated protected
   identity described in [signing/README.md](signing/README.md). First-time setup
   uses `python3 Tools/release-signing.py init`; it refuses to replace an identity.
   Do not create a new identity for each release.
4. Collect the candidate into a new directory:

```sh
python3 Tools/release-linux.py --run-id SUCCESSFUL_RUN_ID --output /absolute/new/release
python3 Tools/release-signing.py verify /absolute/new/release
```

The collector requires a clean matching checkout and a successful manually
dispatched Linux workflow with all ten required jobs. It verifies the exact
ten-package inventory, original checksums and clean release manifests. It signs
RPM headers locally, checks unchanged payload digests with an isolated RPM key
database, updates their checksums, then signs all assets and SHA256SUMS. Arch
packages receive binary `.sig` files. Metadata preserves the original CI hashes
and source/run identity. Only public keys, signatures and artifacts leave the Mac.

Create a signed annotated `vX.Y.Z` tag at that exact commit using the dedicated
signing subkey and keyring. Upload the directory's public inventory to the single
`vX.Y.Z` GitHub draft — the same draft that carries the macOS assets — with the
corresponding release notes: every payload, `SHA256SUMS`, `SHA256SUMS.asc`,
every payload's detached signature (`.sig` for the Arch packages) and
`release-metadata.json`. The per-payload `.sha256` sidecars, the public key,
the fingerprint and their signatures stay local. Download the draft assets into
a fresh directory and verify the payloads against `SHA256SUMS` and their
detached signatures with the pinned public key before publishing. Never upload
the private keyring, passphrase, revocation certificate, scratch files or test
keys. This procedure signs standalone packages; repository metadata signing is
a separate future task.

# macOS side

Before distributing a binary, confirm the applicable distribution permissions
described in THIRD_PARTY_NOTICES.md. Preserve the original notices in the app.

1. The unified version bump above covers the app/framework/test marketing
   versions in the Xcode project, `latest_version.txt` and the Cargo manifest;
   0.2.1 ships as build 2.
2. Run `bash Tools/ci-macos.sh Release`. Both native and Rosetta suites and packaged
   checks must pass on an ARM host. Commit the release sources before packaging.
3. Use a valid Developer ID Application identity and an existing notarytool
   Keychain profile. Never put credentials or private keys into this repository.

```sh
bash Tools/release-macos.sh X.Y.Z SIGNING_IDENTITY_HASH NOTARY_KEYCHAIN_PROFILE \
  /absolute/path/to/a/new/release-directory
```

The script archives a universal Release app with hardened runtime, verifies the
cross-platform version agreement, the project build number and the app's
metadata/signature/entitlements, notarizes and staples the app, creates ZIP and
signed DMG packages, notarizes/staples the DMG, and checks Gatekeeper acceptance.
It produces SHA256SUMS.txt and release-build.json identifying the source commit and
build. The packaging process does not install or launch the monitoring app.

Review the notarization results and verify both packages after extracting/mounting
them. Publish the ZIP, DMG, checksums and build metadata on the same `vX.Y.Z`
release that carries the Linux assets. Keep build directories, certificates,
notarization credentials and temporary submission archives out of Git and GitHub
release assets. Retain the archive/dSYMs locally for diagnostics.

# Publishing

`Tools/publish-release.sh` verifies and publishes both release directories
together. `Tools/release-macos.sh` has already updated `docs/appcast.xml` in
the working tree; that update is committed by publishing, nothing else may be
pending:

```sh
XRG_TAP_DIR=/absolute/path/to/homebrew-tap \
  bash Tools/publish-release.sh X.Y.Z /absolute/mac/release /absolute/linux/release
```

The default is a dry run that prints every command it would run. `--execute`
requires typing the version to confirm and a set `XRG_TAP_DIR`. Every check
runs before any side effect (tag, release, commit), and no check writes to
git — `origin`'s `main` is compared with `HEAD` using the read-only
`git ls-remote`, never a fetch. The script refuses the publish unless:

- the unified version agrees (`Tools/check-version.py --expect`),
  `latest_version.txt` and `releases/X.Y.Z.md` are in place and the branch
  is `main`;
- the working tree is clean except at most `docs/appcast.xml`, and only
  with the unstaged-modified porcelain status (` M`): staged, deleted,
  conflicted or additional dirt is refused. A pending appcast must parse
  and carry the item whose `sparkle:version` is this release's build with
  exactly the enclosure length and `sparkle:edSignature` recorded in the
  macOS release directory's `appcast-item.xml`;
- `origin`'s `main` is exactly `HEAD`, which is the `sourceCommit`/`revision`
  recorded in both release directories' metadata;
- both release directories hold the complete public asset inventory, every
  asset a regular file (never a symlink) with a safe basename contained in
  its release directory. macOS publishes exactly the DMG, the ZIP,
  `SHA256SUMS.txt` and `release-build.json`. Linux publishes every payload
  of both architectures (tarball, `.deb`, `.rpm`, `.pkg.tar.zst`,
  AppImage), `SHA256SUMS`, `SHA256SUMS.asc`, every payload's detached
  signature (`.asc`, or `.sig` for the Arch packages) and
  `release-metadata.json`. Anything else found in the release directories —
  per-payload `.sha256` sidecars, the public key, the fingerprint,
  `verified-build.txt`, `appcast-item.xml` — is never uploaded; the public
  appcast is the committed `docs/appcast.xml` served by GitHub Pages;
- each checksum manifest line is well formed and unique, every payload is
  covered by its manifest, and every listed digest matches the file
  (`SHA256SUMS.txt` covers the DMG and ZIP; Linux `SHA256SUMS` covers every
  payload and `release-metadata.json`);
- with `--execute`, `XRG_TAP_DIR` is a git work tree with a clean index and
  worktree, checked before the tag.

It then creates the signed annotated `vX.Y.Z` tag
(`git tag -s vX.Y.Z -m "XRG-ng X.Y.Z"`), a `gh release` draft carrying the
public assets listed above plus `releases/X.Y.Z.md`, commits the pending
`docs/appcast.xml` (only that path, only from `main`), and writes the
Homebrew cask via `Tools/cask.py` into `$XRG_TAP_DIR/Casks/xrg-ng.rb`,
committing only that path in the tap.

Generate the cask alone with `python3 Tools/cask.py --version V --sha256 HEX
--output Casks/xrg-ng.rb` (the sha256 is the release DMG's digest). It uses
the public Sparkle appcast (`https://sdelavega.github.io/XRG-ng/appcast.xml`)
for livecheck, matching the app's update feed.

Pushing the tag and `main`, pushing the tap commit, and un-drafting the
release (`gh release edit vX.Y.Z --draft=false`) are printed as manual
commands; the script never runs them.
