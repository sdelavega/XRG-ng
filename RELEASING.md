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
signing subkey and keyring. Upload the complete verified directory to the single
`vX.Y.Z` GitHub draft — the same draft that carries the macOS assets — with the
corresponding release notes. Download the draft assets into a fresh directory and
run the public-key verification again before publishing. Never upload the private
keyring, passphrase, revocation certificate, scratch files or test keys. This
procedure signs standalone packages; repository metadata signing is a separate
future task.

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
