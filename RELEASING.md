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
   workflow also builds the frozen 0.2.2 application (tag `v0.2.2`, commit
   `9a4b401`) in a separate target directory and tests a real
   0.2.2 → 0.2.3 → 0.2.2 upgrade/downgrade with custom preferences: it migrates
   a seeded version-40 `settings.conf` into the shared `settings.json`, checks
   that document against the Task 4 conformance oracle, verifies `settings.conf`
   stays byte-identical, then runs 0.2.2 again and confirms its effective
   settings are unchanged. See "Upgrade and downgrade checks" below.
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
   0.2.2 ships as build 3.
2. Run `bash Tools/ci-macos.sh Release`. Both native and Rosetta suites and packaged
   checks must pass on an ARM host, along with the macOS settings upgrade/downgrade
   check described below. Commit the release sources before packaging.
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

# Upgrade and downgrade checks

Both checks prove settings survive 0.2.2 → 0.2.3 → 0.2.2 before a release is
signed. Old data is deliberately left in place so a user can downgrade.

- **macOS — `Tools/settings-upgrade-macos.py`.** It takes `--app` (the built
  0.2.3 app) and `--baseline` (the 0.2.2 app built from tag `v0.2.2`), plus
  optional `--seed`, `--expected`, `--products`, `--results`. It seeds a
  disposable preferences domain
  (`com.sdelavega.xrg.upgradecheck.<uuid>`) from
  `Shared/Tests/Fixtures/settings/macos-0.2.2-defaults.plist`, makes a
  renamed-CFBundleIdentifier copy of each app (the packaged-smoke pattern), runs
  the 0.2.3 shared-core migration over that domain and compares the document
  with `Shared/Tests/Fixtures/settings/macos-0.2.2-expected.json`, then asserts
  the 0.2.2 defaults are byte-identical (the downgrade). It prints
  `SETTINGS_UPGRADE_MACOS_OK`. The 0.2.3 document is written to the R11 private
  store `~/Library/Application Support/XRG-ng-Private/<id>/settings.json`; the
  domain, its plist and that folder are removed at the end, even on failure.
  The real `com.sdelavega.xrg` domain, its plist and the real
  `~/Library/Application Support/XRG-ng/settings.json` are never read, written,
  exported, deleted or launched against — the script refuses if any target id
  equals `com.sdelavega.xrg`. The seed plist is an argument so the check can be
  run once against a real 0.2.2 preferences export (which is never committed);
  if the 0.2.3 document ever legitimately differs from the oracle (e.g. a
  catalog change), report it — do not edit the fixture to pass.
- **Linux — `Tools/application-upgrade-linux.py`.** CI's `preview-install` job
  runs it against the frozen 0.2.2 baseline archive and the current 0.2.3
  archive (real installers). It seeds a version-40 `settings.conf` from
  `Shared/Tests/Fixtures/settings/linux-v40.json`, upgrades, asserts
  `settings.json` equals `Shared/Tests/Fixtures/settings/linux-v40-expected.json`
  and `settings.conf` is unchanged, then reinstalls/runs 0.2.2 and asserts its
  effective settings are unchanged. It prints
  `APPLICATION_UPGRADE_OK 0.2.2-to-0.2.3 ...`. The frozen baseline is built by
  `Tools/build-upgrade-baseline.sh` (checked by
  `Tools/tests/check-baseline-isolation.sh`) from commit `9a4b401` (`v0.2.2`).

Both are wired into CI: the Linux check in `.github/workflows/linux.yml`
(`preview-install`), the macOS check (Release matrix) in
`.github/workflows/macos.yml`. Locally, run the macOS check on a Release build of
HEAD with the 0.2.2 app built from tag `v0.2.2`, and the Linux check in the
`xrg-ng-linux-validation:latest` container as described by the standing rules.

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
  conflicted or additional dirt is refused. The appcast feed itself is
  always validated, whether dirty or already committed: it must parse and
  carry the item whose `sparkle:version` is this release's build with
  exactly the enclosure length and `sparkle:edSignature` recorded in the
  macOS release directory's `appcast-item.xml`. The dirty status only
  decides whether the local phase commits the appcast;
- the unified project build number (`Tools/check-version.py`), the macOS
  release metadata's `build` (`release-build.json`) and the appcast item's
  `sparkle:version` are all present and equal;
- `origin`'s `main` is `HEAD`, or differs by exactly one unpushed local
  commit whose first parent is `origin`'s tip and whose only changed path is
  `docs/appcast.xml` (`git diff --name-only`) — structurally the appcast
  publish commit `--execute` wrote, never merely a commit with its subject
  (`main` is pushed only in the final manual step); the release
  directories' metadata must record that same release commit
  (`sourceCommit`/`revision`: `HEAD`, or the existing release tag's commit
  when resuming);
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
- with `--execute`, the XRG-ng release secret key — the primary fingerprint
  `signing/fingerprint.txt` records — is available in the release keyring
  (`XRG_RELEASE_GNUPGHOME`, default
  `$HOME/.local/share/xrg-ng-release/gnupg`), checked with
  `gpg --list-secret-keys` before any side effect; `--create-draft` requires
  origin's tag to be the same tag object as the local one, and verifies
  the pushed tag with that keyring's public key only;
- with `--execute`, `XRG_TAP_DIR` is a git work tree with a clean index and
  worktree, checked before any side effect.

`--execute` performs the local phase only, and every step is idempotent so a
rerun after a failure resumes where it stopped:

1. the signed annotated `vX.Y.Z` tag: it is signed by the XRG-ng release
   OpenPGP key — the primary fingerprint `signing/fingerprint.txt` records —
   using the release keyring (`XRG_RELEASE_GNUPGHOME`, default
   `$HOME/.local/share/xrg-ng-release/gnupg`): `GNUPGHOME` is set only for
   the `git -c gpg.format=openpgp tag -s -u <fingerprint> vX.Y.Z` call.
   When `vX.Y.Z` already exists locally it is reused only if it is an
   annotated tag whose signature verifies against exactly that release key
   there — `GNUPGHOME=<keyring> git -c gpg.format=openpgp verify-tag --raw
   vX.Y.Z` must succeed and report a `[GNUPG:] VALIDSIG` line naming that
   exact primary fingerprint; an unsigned tag, or one signed by any other
   key, refuses the publish — and it points at the recorded release commit:
   `HEAD`, or exactly one commit behind whose first parent is the tag commit
   and whose only changed path (`git diff --name-only`) is `docs/appcast.xml`
   (never merely a commit with the appcast commit's subject). Otherwise it
   is created with the command above and verified the same way immediately;
2. the appcast commit: skipped when the `docs/appcast.xml` committed at
   `HEAD` already carries this release's item — so a later valid edit of an
   already-published item never creates a second appcast commit; otherwise
   the pending `docs/appcast.xml` alone is committed from `main`;
3. the tap commit: skipped when `Casks/xrg-ng.rb` in the tap's `HEAD` already
   equals what `Tools/cask.py` renders for this release; otherwise the cask
   is written via `Tools/cask.py --version V --sha256 HEX --output
   $XRG_TAP_DIR/Casks/xrg-ng.rb` (the sha256 is the release DMG's digest)
   and committed, only that path, in the tap.

`--execute` never calls `gh release create`. After the tag is pushed
manually, `--create-draft` performs the remote phase: it requires the local
release-key-signed tag to exist and `git ls-remote origin refs/tags/vX.Y.Z`
(peeled for annotated tags) to resolve to the same commit. The origin-main
check tolerates exactly one unpushed local commit there — structurally the
appcast publish commit `--execute` wrote, as above — since `main` is pushed
only in manual step 4. It then runs `gh release create
vX.Y.Z --draft --verify-tag --title "XRG-ng X.Y.Z" --notes-file
releases/X.Y.Z.md` with the public assets. When `gh release view vX.Y.Z
--json isDraft,assets` already shows a release, it is reused only when the
release is still a draft, its asset names are exactly the expected public
inventory and every asset's size equals the local file's (names alone cannot
tell two builds of the same version apart); a published release refuses
with "already published", and any other disagreement refuses the publish.

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
