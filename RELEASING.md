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
together, in two resumable phases. `Tools/release-macos.sh` has already
updated `docs/appcast.xml` in the working tree; that update is committed by
publishing's local phase, nothing else may be pending:

```sh
# 1. dry run: every check, no side effect
XRG_TAP_DIR=/absolute/path/to/homebrew-tap \
  bash Tools/publish-release.sh X.Y.Z /absolute/mac/release /absolute/linux/release
# 2. local phase: signed tag, appcast commit, tap cask commit (idempotent)
XRG_TAP_DIR=/absolute/path/to/homebrew-tap \
  bash Tools/publish-release.sh X.Y.Z /absolute/mac/release /absolute/linux/release --execute
```

The default is a dry run that prints every command both phases would run.
`--execute` and `--create-draft` each require typing the version to confirm;
`--execute` additionally requires a set `XRG_TAP_DIR`. Every check runs before
any side effect, and no check writes to git — `origin`'s refs are compared
with `HEAD` using the read-only `git ls-remote`, never a fetch. The script
refuses the publish unless:

- the unified version agrees (`Tools/check-version.py --expect`),
  `latest_version.txt` and `releases/X.Y.Z.md` are in place and the branch
  is `main`;
- the working tree is clean except at most `docs/appcast.xml`, and only
  with the unstaged-modified porcelain status (` M`): staged, deleted,
  conflicted or additional dirt is refused. A pending appcast must parse
  and carry the item whose `sparkle:version` is this release's build with
  exactly the enclosure length and `sparkle:edSignature` recorded in the
  macOS release directory's `appcast-item.xml`;
- `origin`'s `main` is `HEAD`, or differs by exactly one unpushed local
  commit — the appcast publish commit `--execute` wrote (main is pushed
  only in the final manual step); the release directories' metadata must
  record that same release commit (`sourceCommit`/`revision`: `HEAD`, or
  the existing release tag's commit when resuming);
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
  worktree, checked before any side effect.

`--execute` performs the local phase only, and every step is idempotent so a
rerun after a failure resumes where it stopped (a rerun after the appcast
commit additionally requires `main` to be pushed, per the origin check):

1. the signed annotated `vX.Y.Z` tag: when `vX.Y.Z` already exists locally it
   is reused only if it is a signed annotated tag (`git verify-tag`, or a
   tag object carrying a signature) pointing at the recorded release commit
   (at most one local commit behind `HEAD`: the appcast commit); a tag
   pointing anywhere else or an unsigned tag refuses the publish. Otherwise
   it is created with `git tag -s vX.Y.Z -m "XRG-ng X.Y.Z"`;
2. the appcast commit: skipped when `docs/appcast.xml` is already committed
   with this release's item; otherwise `docs/appcast.xml` alone is committed
   from `main`;
3. the tap commit: skipped when `Casks/xrg-ng.rb` in the tap's `HEAD` already
   equals what `Tools/cask.py` renders for this release; otherwise the cask
   is written via `Tools/cask.py --version V --sha256 HEX --output
   $XRG_TAP_DIR/Casks/xrg-ng.rb` (the sha256 is the release DMG's digest)
   and committed, only that path, in the tap.

`--execute` never calls `gh release create`. After the tag is pushed
manually, `--create-draft` performs the remote phase: it requires the local
signed tag to exist and `git ls-remote origin refs/tags/vX.Y.Z` (peeled for
annotated tags) to resolve to the same commit. The origin-main check
tolerates exactly one unpushed local commit there — the appcast publish
commit `--execute` wrote — since `main` is pushed only in manual step 4.
It then runs `gh release create
vX.Y.Z --draft --verify-tag --title "XRG-ng X.Y.Z" --notes-file
releases/X.Y.Z.md` with the public assets. When `gh release view vX.Y.Z`
already shows a release, it is reused only if its asset names equal the
expected inventory; any mismatch refuses the publish.

The cask uses the public Sparkle appcast
(`https://sdelavega.github.io/XRG-ng/appcast.xml`) for livecheck, matching
the app's update feed.

The script then prints the manual steps it never runs, in this order:

1. `git push origin vX.Y.Z` — the tag only;
2. `bash Tools/publish-release.sh X.Y.Z <mac> <linux> --create-draft`;
3. verify the draft, then `gh release edit vX.Y.Z --draft=false`;
4. `git push origin main` — the appcast goes live only after the release
   assets are live;
5. push the tap commit.
