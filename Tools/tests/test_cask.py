# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Verify the Homebrew cask renderer and the publish script's preflight.

``publish-release.sh`` runs against throwaway repositories with a local bare
origin and PATH-shimmed ``git``/``gh`` spies that record every call, so every
refusal is proven to happen before any tag, release or commit and no test
ever touches the real checkout, its remote or the Homebrew tap. The expected
public asset inventories mirror what ``Tools/release-linux.py`` and
``Tools/release-signing.py`` produce.

Every fixture signs with a throwaway OpenPGP key generated in the test's own
``GNUPGHOME`` — recorded in the fixture repo's ``signing/fingerprint.txt`` and
offered through ``XRG_RELEASE_GNUPGHOME`` — so the real release keyring and
the user's default keyring are never read or written.

The shims also simulate the remote release phase: ``git ls-remote`` answers
refs/tags queries from a ``remote-tags`` file when it exists (the pushed
annotated tag), and ``gh release create`` fails unless that file carries the
tag — mirroring the real GitHub CLI's ``--verify-tag`` rejection of a tag
that was never pushed.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
PUBLISH = TOOLS / "publish-release.sh"
REPO_ROOT = TOOLS.parent

# Standing rule: every artifact this suite creates stays under the task's
# build root in $TMPDIR.
WORK_ROOT = Path(tempfile.gettempdir()) / "xrg-0.2.1-final2"

_spec = importlib.util.spec_from_file_location("cask", TOOLS / "cask.py")
cask = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cask)
_spec = importlib.util.spec_from_file_location("appcast", TOOLS / "appcast.py")
appcast = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(appcast)

VERSION = "0.2.1"
BUILD = "2"
SHA256 = "3bab9b8c40df6b0443fe653cc99f2a1999fec2856b7af9ce9485795f8bb72f97"
APCAST_URL = "https://sdelavega.github.io/XRG-ng/appcast.xml"

EXPECTED_FIELDS = [
    'cask "xrg-ng"',
    f'version "{VERSION}"',
    f'sha256 "{SHA256}"',
    "url \"https://github.com/sdelavega/XRG-ng/releases/download/"
    "v#{version}/XRG-ng-#{version}-macOS-universal.dmg\"",
    'name "XRG-ng"',
    'desc "Real-time system resource monitor with floating graphs"',
    'homepage "https://github.com/sdelavega/XRG-ng"',
    f'url "{APCAST_URL}"',
    "strategy :sparkle",
    "auto_updates true",
    "depends_on macos: :tahoe",
    'app "XRG-ng.app"',
    '"~/Library/Caches/com.sdelavega.xrg"',
    '"~/Library/HTTPStorages/com.sdelavega.xrg"',
    '"~/Library/Preferences/com.sdelavega.xrg.plist"',
]


def linux_payloads(version):
    """The ten payloads Tools/release-linux.py collects, both architectures."""
    names = []
    for arch, deb_arch in (("x86_64", "amd64"), ("aarch64", "arm64")):
        names += [
            f"xrg-ng-{version}-linux-{arch}.tar.gz",
            f"xrg-ng_{version}-1_{deb_arch}.deb",
            f"xrg-ng-{version}-1.{arch}.rpm",
            f"xrg-ng-{version}-1-{arch}.pkg.tar.zst",
            f"XRG-ng-{version}-{arch}.AppImage",
        ]
    return names


def linux_signature(name):
    """The detached-signature file name Tools/release-signing.py creates."""
    return name + (".sig" if name.endswith(".pkg.tar.zst") else ".asc")


def linux_public_assets(version):
    """The Linux files the release draft carries; everything else stays local."""
    payloads = linux_payloads(version)
    return sorted(payloads + [linux_signature(n) for n in payloads]
                  + ["SHA256SUMS", "SHA256SUMS.asc", "release-metadata.json"])


def mac_public_assets(version):
    """The macOS files the release draft carries (RELEASING.md: ZIP, DMG,
    checksums and build metadata; the appcast itself is published from
    docs/appcast.xml via GitHub Pages)."""
    stem = f"XRG-ng-{version}-macOS-universal"
    return [f"{stem}.dmg", f"{stem}.zip", "SHA256SUMS.txt", "release-build.json"]


class RenderCaskTests(unittest.TestCase):
    def test_render_cask_fields(self):
        rendered = cask.render_cask(VERSION, SHA256)
        for field in EXPECTED_FIELDS:
            self.assertIn(field, rendered)
        self.assertIn(f"livecheck do\n    url \"{APCAST_URL}\"", rendered)
        self.assertNotIn("raw/main", rendered)

    def test_rejects_non_hex_sha(self):
        for bad in ["a" * 63, "z" * 64, "g" * 64, "0" * 63 + "g", "",
                    SHA256.upper() + "0"]:
            with self.assertRaises(ValueError):
                cask.render_cask(VERSION, bad)


class PublishScriptTests(unittest.TestCase):
    """Dry-run, --execute and --create-draft scenarios against throwaway repos.

    ``git`` and ``gh`` are PATH-shimmed: git forwards to the real git while
    recording every call (answering refs/tags ls-remote queries from the
    ``remote-tags`` file when it exists), gh records and simulates the GitHub
    release phase: ``release create`` fails unless the remote-tags file shows
    the pushed tag, ``release view`` emits the ``gh-release`` JSON document
    (isDraft, assets with names and sizes) that ``write_gh_release`` writes.
    Tests assert from the spy log that refusals happen before any tag,
    commit, fetch or release call. Fixture tags are signed with the
    throwaway OpenPGP release key of ``make_release_key``.
    """

    def setUp(self):
        WORK_ROOT.mkdir(parents=True, exist_ok=True)
        self.root = Path(tempfile.mkdtemp(prefix="xrg-publish-test-",
                                          dir=WORK_ROOT))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.repo = self.root / "repo"
        self.mac = self.root / "mac-release"
        self.linux = self.root / "linux-release"
        self.origin = self.root / "origin.git"
        self.tap = self.root / "homebrew-tap"
        self.log = self.root / "spy.log"
        self.shims = self.root / "shims"
        self.remote_tags = self.root / "remote-tags"
        self.gh_release = self.root / "gh-release"
        # The throwaway OpenPGP keyring every gpg/git call in the fixture
        # and in the script under test must use; make_release_key creates
        # it at a short path because gpg-agent sockets cannot live as deep
        # as the per-test fixture root (Unix socket path limits). The real
        # release keyring and the user's default keyring are never touched.
        self.gnupg = None
        self.gnupg_homes = []

    def tearDown(self):
        # Kill any gpg-agent/keyboxd started for a test keyring, then remove
        # the keyrings created outside the fixture root; the setUp cleanup
        # removes the fixture root itself afterwards.
        gpgconf = shutil.which("gpgconf")
        if gpgconf is not None:
            for home in self.gnupg_homes:
                subprocess.run([gpgconf, "--homedir", str(home),
                                "--kill", "all"],
                               check=False, capture_output=True)
        for home in self.gnupg_homes:
            shutil.rmtree(home, ignore_errors=True)

    def git(self, *arguments, cwd=None):
        return subprocess.run(["git", *arguments], cwd=cwd or self.repo,
                              check=True, capture_output=True, text=True)

    def git_signed(self, *arguments, cwd=None):
        """git with the test's throwaway OpenPGP keyring (GNUPGHOME), for
        fixture tag signing; the same keyring the script under test resolves
        through XRG_RELEASE_GNUPGHOME."""
        env = dict(os.environ)
        env["GNUPGHOME"] = str(self.gnupg)
        return subprocess.run(["git", *arguments], cwd=cwd or self.repo,
                              check=True, capture_output=True, text=True,
                              env=env)

    def secret_key_fingerprints(self):
        listing = subprocess.run(
            [shutil.which("gpg"), "--homedir", str(self.gnupg), "--batch",
             "--list-secret-keys", "--with-colons"],
            check=True, capture_output=True, text=True).stdout
        return {line.split(":")[9] for line in listing.splitlines()
                if line.startswith("fpr:")}

    def generate_key(self, user_id):
        """One throwaway OpenPGP signing key in the test's own keyring; the
        real release keyring and the default keyring are never touched."""
        before = self.secret_key_fingerprints()
        subprocess.run(
            [shutil.which("gpg"), "--homedir", str(self.gnupg), "--batch",
             "--passphrase", "", "--quick-generate-key", user_id,
             "ed25519", "sign", "never"],
            check=True, capture_output=True, text=True)
        new = sorted(self.secret_key_fingerprints() - before)
        self.assertEqual(len(new), 1,
                         "expected exactly one new secret key fingerprint")
        return new[0]

    def make_release_key(self):
        """The throwaway XRG-ng release key whose primary fingerprint the
        fixture repo's signing/fingerprint.txt records. gpg-agent's sockets
        cannot live as deep as the per-test fixture root (Unix socket path
        limits), so the keyring gets a short sibling directory directly
        under WORK_ROOT (mkdtemp creates it private)."""
        self.gnupg = Path(tempfile.mkdtemp(prefix="g-", dir=WORK_ROOT))
        self.gnupg_homes.append(self.gnupg)
        self.release_key = self.generate_key("XRG test <test@example.invalid>")

    def make_shims(self):
        self.shims.mkdir()
        (self.shims / "git").write_text(
            "#!/bin/sh\n"
            f"log={shlex.quote(str(self.log))}\n"
            f"real={shlex.quote(shutil.which('git'))}\n"
            f"remote_tags={shlex.quote(str(self.remote_tags))}\n"
            "{ printf 'git\\t'; printf '%s\\t' \"$@\"; printf '\\n'; } >> \"$log\"\n"
            "# A refs/tags ls-remote is answered from the remote-tags file\n"
            "# (the simulated pushed tag) when that file exists.\n"
            "if [ \"$1\" = ls-remote ] && [ -f \"$remote_tags\" ]; then\n"
            "    tags=false\n"
            "    for argument in \"$@\"; do\n"
            "        case \"$argument\" in refs/tags/*) tags=true;; esac\n"
            "    done\n"
            "    if [ \"$tags\" = true ]; then cat \"$remote_tags\"; exit 0; fi\n"
            "fi\n"
            "exec \"$real\" \"$@\"\n")
        (self.shims / "gh").write_text(
            "#!/bin/sh\n"
            f"log={shlex.quote(str(self.log))}\n"
            f"remote_tags={shlex.quote(str(self.remote_tags))}\n"
            f"release_assets={shlex.quote(str(self.gh_release))}\n"
            "{ printf 'gh\\t'; printf '%s\\t' \"$@\"; printf '\\n'; } >> \"$log\"\n"
            "case \"$1 $2\" in\n"
            "    'release create')\n"
            "        tag=$3\n"
            "        if [ -f \"$remote_tags\" ] && grep -q \"refs/tags/$tag\" \"$remote_tags\"; then\n"
            "            exit 0\n"
            "        fi\n"
            "        echo \"gh: refusing to create a release for the unpushed tag $tag\" >&2\n"
            "        exit 1;;\n"
            "    'release view')\n"
            "        # emit the gh-release JSON document (isDraft, assets)\n"
            "        if [ -f \"$release_assets\" ]; then cat \"$release_assets\"; exit 0; fi\n"
            "        exit 1;;\n"
            "esac\n"
            "exit 0\n")
        os.chmod(self.shims / "git", 0o755)
        os.chmod(self.shims / "gh", 0o755)

    def spy_calls(self):
        if not self.log.exists():
            return []
        return [line.split("\t")[:-1]
                for line in self.log.read_text(encoding="utf-8").splitlines()]

    def tag_calls(self):
        """git tag invocations, including those behind -c config prefixes."""
        calls = []
        for call in self.spy_calls():
            if call[0] != "git":
                continue
            rest = call[1:]
            while rest and rest[0].startswith("-c"):
                rest = rest[2:]
            if rest and rest[0] == "tag":
                calls.append(call)
        return calls

    def mutating_calls(self):
        """Spy calls that create tags/commits/releases or fetch remote state."""
        calls = []
        for call in self.spy_calls():
            if call[0] == "gh":
                if call[1:3] == ["release", "create"]:
                    calls.append(call)
                continue
            if call[0] != "git":
                continue
            rest = call[1:]
            while rest and rest[0].startswith("-c"):
                rest = rest[2:]
            if rest and rest[0] in ("tag", "commit", "fetch"):
                calls.append(call)
        return calls

    def write_repo_sources(self):
        self.repo.mkdir(parents=True)
        (self.repo / "latest_version.txt").write_text(f"{VERSION}\n")
        project = self.repo / "XRG-ng.xcodeproj" / "project.pbxproj"
        project.parent.mkdir(parents=True)
        project.write_text("\t\t\tMARKETING_VERSION = 0.2.1;\n"
                           "\t\t\tCURRENT_PROJECT_VERSION = 2;\n")
        manifest = self.repo / "xrg-linux" / "rust" / "Cargo.toml"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(f'[package]\nname = "xrg-ng"\nversion = "{VERSION}"\n')
        signing = self.repo / "signing"
        signing.mkdir()
        (signing / "fingerprint.txt").write_text(f"{self.release_key}\n")
        appcast = self.repo / "docs" / "appcast.xml"
        appcast.parent.mkdir(parents=True)
        shutil.copyfile(REPO_ROOT / "docs" / "appcast.xml", appcast)
        notes = self.repo / "releases" / f"{VERSION}.md"
        notes.parent.mkdir(parents=True)
        notes.write_text(f"# XRG-ng {VERSION}\n")
        tools = self.repo / "Tools"
        tools.mkdir()
        for name in ("publish-release.sh", "check-version.py", "cask.py"):
            shutil.copyfile(TOOLS / name, tools / name)

    def commit_repo(self):
        self.git("init", "--initial-branch=main", ".")
        self.git("config", "user.name", "XRG test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo,
                              check=True, capture_output=True,
                              text=True).stdout.strip()
        self.git("clone", "--bare", str(self.repo), str(self.origin),
                 cwd=self.root)
        self.git("remote", "add", "origin", str(self.origin))
        return head

    def write_release_dirs(self, head):
        stem = f"XRG-ng-{VERSION}-macOS-universal"
        self.mac.mkdir(parents=True)
        mac_files = {f"{stem}.dmg": b"universal disk image fixture",
                     f"{stem}.zip": b"universal zip fixture"}
        for name, content in mac_files.items():
            (self.mac / name).write_bytes(content)
        (self.mac / "SHA256SUMS.txt").write_text("".join(
            f"{hashlib.sha256((self.mac / name).read_bytes()).hexdigest()}  {name}\n"
            for name in sorted(mac_files)))
        (self.mac / "release-build.json").write_text(json.dumps(
            {"version": VERSION, "build": BUILD, "sourceCommit": head}) + "\n")
        # Local-only macOS outputs: present in a real release dir, never assets.
        (self.mac / "verified-build.txt").write_text(f"{BUILD}\n")
        (self.mac / "appcast-item.xml").write_text("<item/>\n")

        self.linux.mkdir(parents=True)
        (self.linux / "release-metadata.json").write_text(json.dumps(
            {"format": "xrg-ng-linux-release-v1", "version": VERSION,
             "revision": head}) + "\n")
        payloads = linux_payloads(VERSION)
        for index, name in enumerate(payloads):
            (self.linux / name).write_bytes(f"linux payload {index}".encode())
        # Private files a real release directory also holds; never uploaded.
        (self.linux / "fingerprint.txt").write_text("fingerprint fixture\n")
        sidecar = "xrg-ng-" + VERSION + "-linux-x86_64.tar.gz.sha256"
        (self.linux / sidecar).write_text("sidecar fixture\n")
        covered = sorted(payloads
                         + ["release-metadata.json", "fingerprint.txt", sidecar])
        (self.linux / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256((self.linux / name).read_bytes()).hexdigest()}  {name}\n"
            for name in covered))
        for name in ["SHA256SUMS"] + payloads:
            (self.linux / linux_signature(name)).write_bytes(
                b"detached signature fixture\n")

    def make_tap(self):
        self.tap.mkdir()
        self.git("init", "--initial-branch=main", ".", cwd=self.tap)
        self.git("config", "user.name", "XRG test", cwd=self.tap)
        self.git("config", "user.email", "test@example.invalid", cwd=self.tap)
        (self.tap / "README.md").write_text("fixture tap\n")
        self.git("add", ".", cwd=self.tap)
        self.git("commit", "-m", "tap fixture", cwd=self.tap)

    def make_pending_appcast(self):
        """Reproduce Tools/release-macos.sh's pending docs/appcast.xml update."""
        item = appcast.AppcastItem(
            version=VERSION, build=BUILD,
            url=f"https://github.com/sdelavega/XRG-ng/releases/download/"
                f"v{VERSION}/XRG-ng-{VERSION}-macOS-universal.dmg",
            length="27", ed_signature="fixture-ed-signature",
            notes_url=f"https://github.com/sdelavega/XRG-ng/releases/tag/v{VERSION}",
            min_system="26.0", pub_date="Fri, 30 Oct 2026 12:00:00 +0000")
        appcast_path = self.repo / "docs" / "appcast.xml"
        updated = appcast.upsert_item(
            appcast_path.read_text(encoding="utf-8"), item)
        appcast_path.write_text(updated, encoding="utf-8")
        index = updated.find("<item")
        indent = appcast._line_indent(updated, index)
        standalone = appcast.render_item(item, indent,
                                         appcast._newline_of(updated))
        (self.mac / "appcast-item.xml").write_text(standalone + "\n",
                                                  encoding="utf-8")
        return updated

    def build_fixture(self, pending_appcast=True):
        self.make_shims()
        self.make_release_key()
        self.write_repo_sources()
        head = self.commit_repo()
        self.write_release_dirs(head)
        self.make_tap()
        if pending_appcast:
            self.make_pending_appcast()
        return head

    def publish(self, execute=False, create_draft=False, tap=True,
                confirm=None, tap_path=None, gnupg=None):
        env = dict(os.environ)
        env["PATH"] = f"{self.shims}{os.pathsep}{env['PATH']}"
        keyring = Path(gnupg) if gnupg is not None else self.gnupg
        if keyring not in self.gnupg_homes:
            self.gnupg_homes.append(keyring)
        # The script resolves the release keyring from XRG_RELEASE_GNUPGHOME;
        # GNUPGHOME keeps every other gpg call inside a test keyring too, so
        # neither the real release keyring nor ~/.gnupg is ever consulted.
        env["XRG_RELEASE_GNUPGHOME"] = str(keyring)
        env["GNUPGHOME"] = str(keyring)
        if tap_path is not None:
            env["XRG_TAP_DIR"] = str(tap_path)
        elif tap:
            env["XRG_TAP_DIR"] = str(self.tap)
        else:
            env.pop("XRG_TAP_DIR", None)
        arguments = ["bash", str(self.repo / "Tools" / "publish-release.sh"),
                      VERSION, str(self.mac), str(self.linux)]
        if execute:
            arguments.append("--execute")
        elif create_draft:
            arguments.append("--create-draft")
        side_effecting = execute or create_draft
        return subprocess.run(arguments, capture_output=True, text=True,
                              env=env,
                              input=confirm if confirm is not None
                              else (f"{VERSION}\n" if side_effecting else ""),
                              cwd=self.root)

    def tags(self):
        return self.git("tag", "-l").stdout.split()

    def assert_no_side_effects(self, result):
        self.assertEqual(self.mutating_calls(), [],
                         "a tag, commit, fetch or release call happened")
        self.assertEqual(self.tags(), [])

    def assert_refused_before_side_effects(self, result, message):
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn(message, combined)
        self.assertEqual(self.mutating_calls(), [],
                         "a tag, commit, fetch or release happened before "
                         "the refusal")
        self.assertEqual(self.tags(), [])
        self.assertFalse((self.tap / "Casks" / "xrg-ng.rb").exists())

    def main_commits(self, message_prefix, cwd=None):
        listing = subprocess.run(["git", "log", "--format=%s"],
                                  cwd=cwd or self.repo, check=True,
                                  capture_output=True, text=True).stdout
        return [subject for subject in listing.splitlines()
                if subject.startswith(message_prefix)]

    def write_gh_release(self, draft=True, wrong_size=False,
                         foreign_names=False):
        """The gh-release JSON document the shim's `release view` emits: the
        release's draft flag and the recorded assets' names and sizes, by
        default exactly the local public inventory."""
        if foreign_names:
            assets = [{"name": "XRG-ng-0.0.1-macOS-universal.dmg",
                       "size": 123}]
        else:
            assets = []
            for directory, names in ((self.mac, mac_public_assets(VERSION)),
                                     (self.linux, linux_public_assets(VERSION))):
                for name in names:
                    size = (directory / name).stat().st_size
                    assets.append({"name": name,
                                   "size": size + 1 if wrong_size else size})
        self.gh_release.write_text(
            json.dumps({"isDraft": draft, "assets": assets}) + "\n",
            encoding="utf-8")

    def simulate_pushed_tag(self, commit=None):
        """Write the remote-tags file the ls-remote/gh shims read: the pushed
        annotated tag vVERSION, optionally resolving to another commit."""
        tag_object = subprocess.run(["git", "rev-parse", f"v{VERSION}"],
                                    cwd=self.repo, check=True,
                                    capture_output=True, text=True).stdout.strip()
        tag_commit = subprocess.run(["git", "rev-parse", f"v{VERSION}^{{}}"],
                                    cwd=self.repo, check=True,
                                    capture_output=True, text=True).stdout.strip()
        if commit is not None:
            tag_commit = commit
        self.remote_tags.write_text(
            f"{tag_commit}\trefs/tags/v{VERSION}^{{}}\n"
            f"{tag_object}\trefs/tags/v{VERSION}\n", encoding="utf-8")

    # --- Dry runs ---

    def test_dry_run_prints_planned_steps_without_side_effects(self):
        self.build_fixture()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        combined = result.stdout + result.stderr
        for planned in ["gpg.format=openpgp", "tag -s", self.release_key,
                        "gh release create", f"v{VERSION}",
                        "--create-draft", "cask.py"]:
            self.assertIn(planned, combined)
        for asset in (mac_public_assets(VERSION) + linux_public_assets(VERSION)):
            self.assertIn(asset, combined)
        for private in ["verified-build.txt", "appcast-item.xml",
                        "fingerprint.txt",
                        "xrg-ng-0.2.1-linux-x86_64.tar.gz.sha256"]:
            self.assertNotIn(private, combined)
        self.assertIn("XRG_TAP_DIR", combined)
        self.assert_no_side_effects(result)

    def test_publish_dry_run_refuses_dirty_tree(self):
        self.build_fixture()
        (self.repo / "uncommitted.txt").write_text("dirty\n")
        result = self.publish()
        self.assert_refused_before_side_effects(result,
                                                "Commit source changes")

    def test_publish_dry_run_refuses_checksum_mismatch(self):
        self.build_fixture()
        dmg = next(p for p in self.mac.iterdir() if p.suffix == ".dmg")
        dmg.write_bytes(b"tampered universal disk image")
        result = self.publish()
        self.assert_refused_before_side_effects(result, "checksum")

    # --- Pre-publication refusals (spy-proven to precede any side effect) ---

    def test_execute_refuses_dirty_source_tree(self):
        self.build_fixture()
        with open(self.repo / "releases" / f"{VERSION}.md", "a") as notes:
            notes.write("more notes\n")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "Commit source changes")

    def test_execute_refuses_staged_appcast(self):
        self.build_fixture()
        self.git("add", "docs/appcast.xml")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "Commit source changes")

    def test_refuses_clean_tree_with_no_matching_appcast_item(self):
        # Important 2: a clean checkout whose committed feed carries no item
        # for this release must refuse, not skip feed validation.
        self.build_fixture()
        self.git("checkout", "--", "docs/appcast.xml")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "carries no item for build")

    def test_execute_refuses_pending_appcast_mismatch(self):
        self.build_fixture()
        appcast_path = self.repo / "docs" / "appcast.xml"
        appcast_path.write_text(appcast_path.read_text(
            encoding="utf-8").replace("fixture-ed-signature",
                                      "tampered-signature"),
            encoding="utf-8")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "appcast")

    def test_execute_refuses_unparseable_pending_appcast(self):
        self.build_fixture()
        (self.repo / "docs" / "appcast.xml").write_text("not xml <oops\n")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "appcast")

    def test_execute_refuses_origin_divergence(self):
        head = self.build_fixture(pending_appcast=False)
        self.git("commit", "--allow-empty", "-m", "origin only")
        self.git("push", "origin", "main")
        self.git("reset", "--hard", head)
        result = self.publish(execute=True)
        self.assert_refused_before_side_effects(result, "does not match HEAD")
        self.assertEqual([call for call in self.spy_calls()
                          if call[:2] == ["git", "fetch"]], [],
                         "the remote check must be a read-only ls-remote")

    def test_execute_refuses_foreign_mac_metadata(self):
        self.build_fixture()
        (self.mac / "release-build.json").write_text(json.dumps(
            {"version": VERSION, "build": BUILD,
             "sourceCommit": "a" * 40}) + "\n")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "not this checkout")

    def test_execute_refuses_foreign_linux_metadata(self):
        self.build_fixture()
        (self.linux / "release-metadata.json").write_text(json.dumps(
            {"version": VERSION, "revision": "b" * 40}) + "\n")
        # Keep the manifest entry consistent so the metadata check is reached
        # (the real producer also lists release-metadata.json in SHA256SUMS).
        manifest = self.linux / "SHA256SUMS"
        rows = [f"{hashlib.sha256((self.linux / 'release-metadata.json').read_bytes()).hexdigest()}  release-metadata.json\n"
                if row.endswith("  release-metadata.json") else row + "\n"
                for row in manifest.read_text().splitlines()]
        manifest.write_text("".join(rows))
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "not this checkout")

    # --- Important 3: the three build numbers must agree before side effects ---

    def test_refuses_metadata_build_mismatch(self):
        self.build_fixture()
        (self.mac / "release-build.json").write_text(json.dumps(
            {"version": VERSION, "build": "3", "sourceCommit":
             json.loads((self.mac / "release-build.json").read_text())["sourceCommit"]}) + "\n")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("the build numbers disagree", combined)
        self.assertIn(f"project build {BUILD}", combined)
        self.assertIn("macOS release metadata build 3", combined)
        self.assertIn(f"appcast item build {BUILD}", combined)
        self.assert_no_side_effects(result)

    def test_refuses_appcast_build_mismatch(self):
        self.build_fixture()
        appcast_path = self.repo / "docs" / "appcast.xml"
        appcast_path.write_text(appcast_path.read_text(
            encoding="utf-8").replace(
            f'<sparkle:version>{BUILD}</sparkle:version>',
            '<sparkle:version>3</sparkle:version>'),
            encoding="utf-8")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("carries no item for build", combined)
        self.assertIn(f"build {BUILD}", combined)
        self.assertIn("feed builds: 3", combined)
        self.assert_no_side_effects(result)

    def test_refuses_missing_metadata_build(self):
        self.build_fixture()
        metadata = json.loads((self.mac / "release-build.json").read_text())
        del metadata["build"]
        (self.mac / "release-build.json").write_text(
            json.dumps(metadata) + "\n")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("does not record the build number", combined)
        self.assertIn(f"project build {BUILD}", combined)
        self.assert_no_side_effects(result)

    def test_refuses_conflicting_project_build(self):
        self.build_fixture()
        project = self.repo / "XRG-ng.xcodeproj" / "project.pbxproj"
        project.write_text(project.read_text() +
                          "\t\t\tCURRENT_PROJECT_VERSION = 3;\n")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("conflicting CURRENT_PROJECT_VERSION", combined)
        self.assert_no_side_effects(result)

    # --- More --execute refusals ---

    def test_execute_refuses_linux_checksum_mismatch(self):
        self.build_fixture()
        deb = self.linux / f"xrg-ng_{VERSION}-1_amd64.deb"
        deb.write_bytes(deb.read_bytes() + b"tampered")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "checksum")

    def test_execute_refuses_manifest_gap(self):
        self.build_fixture()
        deb = f"xrg-ng_{VERSION}-1_amd64.deb"
        rows = [row for row in (self.linux / "SHA256SUMS").read_text().splitlines()
                if not row.endswith(f"  {deb}")]
        (self.linux / "SHA256SUMS").write_text("\n".join(rows) + "\n")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "does not cover")

    def test_execute_refuses_malformed_manifest_line(self):
        self.build_fixture()
        with open(self.linux / "SHA256SUMS", "a") as manifest:
            manifest.write(f"{'0' * 64}  ../outside.txt\n")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "malformed")

    def test_execute_refuses_duplicate_manifest_entry(self):
        self.build_fixture()
        manifest = self.linux / "SHA256SUMS"
        first = manifest.read_text().splitlines()[0]
        with open(manifest, "a") as stream:
            stream.write(first + "\n")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "duplicate")

    def test_execute_refuses_symlinked_asset(self):
        self.build_fixture()
        deb = self.linux / f"xrg-ng_{VERSION}-1_amd64.deb"
        tarball = self.linux / f"xrg-ng-{VERSION}-linux-x86_64.tar.gz"
        deb.unlink()
        deb.symlink_to(tarball)
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "symlink")

    def test_execute_refuses_missing_public_asset(self):
        self.build_fixture()
        (self.linux / f"xrg-ng_{VERSION}-1_amd64.deb.asc").unlink()
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "missing the asset")

    def test_execute_refuses_dirty_tap(self):
        self.build_fixture()
        (self.tap / "README.md").write_text("dirty tap\n")
        self.assert_refused_before_side_effects(
            self.publish(execute=True), "tap checkout")

    def test_execute_refuses_tap_outside_a_git_work_tree(self):
        self.build_fixture()
        outside = self.root / "not-a-repo"
        outside.mkdir()
        self.assert_refused_before_side_effects(
            self.publish(execute=True, tap_path=outside),
            "not a git work tree")

    def test_execute_requires_tap_and_confirmation(self):
        self.build_fixture()
        self.assert_refused_before_side_effects(
            self.publish(execute=True, tap=False),
            "--execute requires XRG_TAP_DIR")
        self.assert_refused_before_side_effects(
            self.publish(execute=True, confirm="nope\n"), "Aborted")

    def test_create_draft_requires_confirmation(self):
        self.build_fixture()
        self.assert_refused_before_side_effects(
            self.publish(create_draft=True, confirm="nope\n"), "Aborted")

    def test_execute_refuses_existing_tag_at_another_commit(self):
        self.build_fixture()
        self.git("commit", "--allow-empty", "-m", "newer head")
        self.git("push", "origin", "main")
        self.git_signed("tag", "-s", "-u", self.release_key, f"v{VERSION}",
                        "-m", f"XRG-ng {VERSION}", "HEAD~1")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("points at", combined)
        self.assertEqual(self.mutating_calls(), [],
                         "no commit happened before the refusal")
        self.assertFalse((self.tap / "Casks" / "xrg-ng.rb").exists())

    def test_execute_refuses_tag_resume_commit_touching_other_files(self):
        # A commit titled "Publish appcast for XRG-ng $VERSION" that also
        # changes anything beyond docs/appcast.xml must not resume the tag:
        # the check is ancestry plus the changed-path set, never the subject.
        self.build_fixture()
        self.git_signed("tag", "-s", "-u", self.release_key, f"v{VERSION}",
                        "-m", f"XRG-ng {VERSION}")
        (self.repo / "extra.txt").write_text("sneaky change\n")
        self.git("add", "docs/appcast.xml", "extra.txt")
        self.git("commit", "-m", f"Publish appcast for XRG-ng {VERSION}")
        self.git("push", "origin", "main")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("neither HEAD", combined)
        self.assertIn("only changed path is docs/appcast.xml", combined)
        self.assertEqual(self.mutating_calls(), [],
                         "no commit happened before the refusal")
        self.assertEqual(len(self.main_commits("xrg-ng 0.2.1",
                                                cwd=self.tap)), 0)

    def test_execute_refuses_origin_resume_commit_touching_other_files(self):
        # Same structural rule for origin/main versus HEAD: the unpushed
        # commit may change docs/appcast.xml only, whatever its subject.
        self.build_fixture()
        (self.repo / "extra.txt").write_text("sneaky change\n")
        self.git("add", "docs/appcast.xml", "extra.txt")
        self.git("commit", "-m", f"Publish appcast for XRG-ng {VERSION}")
        result = self.publish(execute=True)
        self.assert_refused_before_side_effects(result,
                                                 "does not match HEAD")

    def test_execute_refuses_unsigned_existing_tag(self):
        self.build_fixture()
        self.git("tag", "-a", f"v{VERSION}", "-m", f"XRG-ng {VERSION}")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("not signed", combined)
        self.assertEqual(self.mutating_calls(), [],
                         "no commit happened before the refusal")
        self.assertFalse((self.tap / "Casks" / "xrg-ng.rb").exists())

    def test_execute_refuses_tag_signed_by_a_different_key(self):
        # A tag signed by another OpenPGP key present in the same keyring
        # verifies cryptographically; only the VALIDSIG fingerprint check
        # names the wrong key.
        self.build_fixture()
        other_key = self.generate_key("XRG other <other@example.invalid>")
        self.git_signed("tag", "-s", "-u", other_key, f"v{VERSION}",
                        "-m", f"XRG-ng {VERSION}")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("not signed by the XRG-ng release key", combined)
        self.assertIn(self.release_key, combined)
        self.assertEqual(self.mutating_calls(), [],
                         "no commit happened before the refusal")
        self.assertEqual(len(self.main_commits("Publish appcast")), 0)
        self.assertFalse((self.tap / "Casks" / "xrg-ng.rb").exists())

    def test_execute_refuses_signature_text_without_real_signature(self):
        # An annotated tag whose message merely contains signature-looking
        # text carries no signature; the publish must fail closed on it.
        self.build_fixture()
        self.git("tag", "-a", f"v{VERSION}",
                 "-m", "-----BEGIN PGP SIGNATURE-----\nnot a real signature\n"
                       "-----END PGP SIGNATURE-----")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("not signed", combined)
        self.assertEqual(self.mutating_calls(), [],
                         "no commit happened before the refusal")
        self.assertFalse((self.tap / "Casks" / "xrg-ng.rb").exists())

    def test_execute_refuses_missing_release_secret_key(self):
        # --execute must preflight the release secret key and refuse before
        # any side effect when the keyring does not hold it.
        self.build_fixture()
        empty_keyring = Path(tempfile.mkdtemp(prefix="g-", dir=WORK_ROOT))
        result = self.publish(execute=True, gnupg=empty_keyring)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("not available in the release keyring", combined)
        self.assertIn(str(empty_keyring), combined,
                      "the refusal must name the keyring path")
        self.assertIn(self.release_key, combined)
        self.assertEqual(self.mutating_calls(), [],
                         "no tag, commit or release happened before the refusal")
        self.assertEqual(self.tags(), [])
        self.assertFalse((self.tap / "Casks" / "xrg-ng.rb").exists())

    # --- --execute happy paths ---

    def test_execute_publishes_tag_and_commits_without_gh(self):
        head = self.build_fixture()
        result = self.publish(execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        combined = result.stdout + result.stderr
        self.assertIn("PASS: XRG-ng 0.2.1 local phase complete", combined)
        calls = self.spy_calls()
        self.assertEqual([call for call in calls
                          if call[:2] == ["git", "fetch"]], [],
                         "no fetch anywhere; the remote check is ls-remote")
        self.assertEqual([call for call in calls if call[0] == "gh"], [],
                         "--execute is the local phase only; no gh call")
        self.assertEqual(self.tag_calls(), [
            ["git", "-c", "gpg.format=openpgp", "tag", "-s", "-u",
             self.release_key, f"v{VERSION}", "-m", f"XRG-ng {VERSION}"]])
        commits = [call for call in calls if call[:2] == ["git", "commit"]]
        self.assertEqual(commits, [
            ["git", "commit", "-m", f"Publish appcast for XRG-ng {VERSION}",
             "--", "docs/appcast.xml"],
            ["git", "commit", "-m", f"xrg-ng {VERSION}", "--",
             "Casks/xrg-ng.rb"]])
        self.assertEqual(self.tags(), [f"v{VERSION}"])
        self.assertNotEqual(subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=self.repo, check=True,
            capture_output=True, text=True).stdout.strip(), head)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        tap_files = self.git("show", "--name-only", "--format=", "HEAD",
                             cwd=self.tap).stdout.split()
        self.assertEqual(tap_files, ["Casks/xrg-ng.rb"])
        self.assertEqual(self.git("status", "--porcelain",
                                  cwd=self.tap).stdout, "")
        dmg = next(p for p in self.mac.iterdir() if p.suffix == ".dmg")
        cask = (self.tap / "Casks" / "xrg-ng.rb").read_text(encoding="utf-8")
        self.assertIn(f'sha256 "{hashlib.sha256(dmg.read_bytes()).hexdigest()}"',
                      cask)
        self.assertIn(f'url "{APCAST_URL}"', cask)

    def test_execute_publishes_committed_appcast_without_appcast_commit(self):
        # A clean tree whose committed feed already carries this release's
        # item publishes with no appcast commit (Important 2: dirty status
        # only decides the commit). The tag exists and the appcast commit
        # is the one unpushed local commit -- a resume state.
        self.build_fixture()
        self.git_signed("tag", "-s", "-u", self.release_key, f"v{VERSION}",
                        "-m", f"XRG-ng {VERSION}")
        self.git("add", "docs/appcast.xml")
        self.git("commit", "-m", f"Publish appcast for XRG-ng {VERSION}")
        self.git("push", "origin", "main")
        appcast_commits = len(self.main_commits("Publish appcast"))
        self.assertEqual(appcast_commits, 1)
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("already committed with this release's item", combined)
        self.assertEqual(len(self.main_commits("Publish appcast")), appcast_commits,
                         "no second appcast commit was created")
        self.assertEqual(self.tags(), [f"v{VERSION}"])

    def test_execute_resumes_after_partial_failure_without_duplicates(self):
        # The tag already exists (a previous run stopped after tagging);
        # the rerun must reuse it and still commit appcast and tap cask.
        self.build_fixture()
        self.git_signed("tag", "-s", "-u", self.release_key, f"v{VERSION}",
                        "-m", f"XRG-ng {VERSION}")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("Reusing the existing signed annotated tag", combined)
        self.assertEqual(self.tags(), [f"v{VERSION}"])
        self.assertEqual(len(self.main_commits("Publish appcast")), 1)
        self.assertEqual(len(self.main_commits("xrg-ng 0.2.1",
                                               cwd=self.tap)), 1)
        # A full second local-phase run changes nothing (every step
        # idempotent); main was pushed after the appcast commit.
        self.git("push", "origin", "main")
        self.log.unlink()
        rerun = self.publish(execute=True)
        rerun_combined = rerun.stdout + rerun.stderr
        self.assertEqual(rerun.returncode, 0, rerun_combined)
        self.assertIn("Reusing the existing signed annotated tag", rerun_combined)
        self.assertIn("nothing to commit", rerun_combined)
        self.assertIn("already matches this release", rerun_combined)
        self.assertEqual(self.tags(), [f"v{VERSION}"])
        self.assertEqual(len(self.main_commits("Publish appcast")), 1)
        self.assertEqual(len(self.main_commits("xrg-ng 0.2.1",
                                               cwd=self.tap)), 1)
        self.assertEqual(self.tag_calls(), [],
                         "no duplicate tag was created")

    def test_execute_skips_second_appcast_commit_after_later_valid_edit(self):
        # The appcast commit decision must look at the committed feed, not
        # only at dirt: after a successful run, a later valid edit of
        # docs/appcast.xml (still carrying this release's item) must not
        # produce a second appcast commit.
        self.build_fixture()
        self.assertEqual(self.publish(execute=True).returncode, 0)
        self.git("push", "origin", "main")
        appcast_path = self.repo / "docs" / "appcast.xml"
        appcast_path.write_text(appcast_path.read_text(
            encoding="utf-8").replace("<title>XRG-ng</title>",
                                     "<title>XRG-ng</title>"
                                     "<!-- later valid edit -->"),
            encoding="utf-8")
        result = self.publish(execute=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("already committed with this release's item", combined)
        self.assertEqual(len(self.main_commits("Publish appcast")), 1,
                         "a later valid edit must not create a second "
                         "appcast commit")

    # --- --create-draft phase ---

    def test_create_draft_refused_when_remote_tag_missing(self):
        self.build_fixture()
        result = self.publish(execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        # The tag exists locally only; --create-draft must refuse before gh.
        draft = self.publish(create_draft=True)
        combined = draft.stdout + draft.stderr
        self.assertEqual(draft.returncode, 1, combined)
        self.assertIn("origin has no refs/tags", combined)
        self.assertEqual([call for call in self.spy_calls()
                          if call[0] == "gh"], [],
                         "no gh call happened before the refusal")

    def test_create_draft_refused_when_remote_tag_at_another_commit(self):
        self.build_fixture()
        result = self.publish(execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.simulate_pushed_tag(commit="c" * 40)
        draft = self.publish(create_draft=True)
        combined = draft.stdout + draft.stderr
        self.assertEqual(draft.returncode, 1, combined)
        self.assertIn("resolves to", combined)
        self.assertEqual([call for call in self.spy_calls()
                          if call[0] == "gh"], [],
                         "no gh call happened before the refusal")

    def test_create_draft_refused_without_a_local_tag(self):
        self.build_fixture()
        draft = self.publish(create_draft=True)
        combined = draft.stdout + draft.stderr
        self.assertEqual(draft.returncode, 1, combined)
        self.assertIn("no local", combined)
        self.assertEqual([call for call in self.spy_calls()
                          if call[0] == "gh"], [],
                         "no gh call happened before the refusal")

    def test_create_draft_recovers_after_gh_rejects_unpushed_tag(self):
        # The real GitHub CLI rejects a release for a tag missing from the
        # remote (this also holds for drafts); the gh shim reproduces that.
        # The rerun after the push resumes without side effects.
        self.build_fixture()
        self.assertEqual(self.publish(execute=True).returncode, 0)
        # Push the tag to the bare fixture origin for real, but the pushed
        # tag is still invisible to the gh shim until the remote-tags file
        # (the file the ls-remote shim reads) exists.
        self.git("push", "origin", f"v{VERSION}")
        failed = self.publish(create_draft=True)
        combined = failed.stdout + failed.stderr
        self.assertNotEqual(failed.returncode, 0, combined)
        self.assertIn("unpushed tag", combined)
        self.assertEqual(len([call for call in self.spy_calls()
                              if call[:3] == ["gh", "release", "create"]]), 1)
        # Simulate the push for the shims and rerun: the draft is created.
        self.simulate_pushed_tag()
        result = self.publish(create_draft=True)
        rerun_combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, rerun_combined)
        self.assertIn("PASS: XRG-ng 0.2.1 draft phase complete", rerun_combined)
        self.assertEqual(len([call for call in self.spy_calls()
                              if call[:3] == ["gh", "release", "create"]]), 2)

    def test_create_draft_creates_the_draft_with_the_public_assets(self):
        self.build_fixture()
        self.assertEqual(self.publish(execute=True).returncode, 0)
        self.simulate_pushed_tag()
        result = self.publish(create_draft=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("PASS: XRG-ng 0.2.1 draft phase complete", combined)
        self.assertIn("gh release edit", combined)
        self.assertEqual([call for call in self.spy_calls()
                          if call[:2] == ["git", "fetch"]], [])
        releases = [call for call in self.spy_calls()
                    if call[:3] == ["gh", "release", "create"]]
        self.assertEqual(len(releases), 1, self.spy_calls())
        arguments = releases[0][1:]
        self.assertEqual(arguments[:9],
                         ["release", "create", f"v{VERSION}", "--draft",
                          "--verify-tag", "--title", f"XRG-ng {VERSION}",
                          "--notes-file", f"releases/{VERSION}.md"][:9])
        expected_assets = {str(self.mac / name)
                           for name in mac_public_assets(VERSION)}
        expected_assets |= {str(self.linux / name)
                            for name in linux_public_assets(VERSION)}
        self.assertEqual(set(arguments[9:]), expected_assets)

    def test_create_draft_reuses_existing_draft_with_matching_assets(self):
        self.build_fixture()
        self.assertEqual(self.publish(execute=True).returncode, 0)
        self.simulate_pushed_tag()
        self.write_gh_release()
        result = self.publish(create_draft=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, combined)
        self.assertIn("matching asset inventory (names and sizes)", combined)
        self.assertIn(["gh", "release", "view", f"v{VERSION}", "--json",
                       "isDraft,assets"], self.spy_calls())
        self.assertEqual([call for call in self.spy_calls()
                          if call[:3] == ["gh", "release", "create"]], [],
                         "an existing matching draft must not be recreated")

    def test_create_draft_refuses_existing_release_with_other_assets(self):
        self.build_fixture()
        self.assertEqual(self.publish(execute=True).returncode, 0)
        self.simulate_pushed_tag()
        self.write_gh_release(foreign_names=True)
        result = self.publish(create_draft=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("not this release's draft", combined)
        self.assertEqual([call for call in self.spy_calls()
                          if call[:3] == ["gh", "release", "create"]], [],
                         "a mismatched existing release must not be recreated")

    def test_create_draft_refuses_published_release(self):
        # A published (non-draft) release for this tag must never be reused
        # or recreated, even when its assets match exactly.
        self.build_fixture()
        self.assertEqual(self.publish(execute=True).returncode, 0)
        self.simulate_pushed_tag()
        self.write_gh_release(draft=False)
        result = self.publish(create_draft=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("already published", combined)
        self.assertEqual([call for call in self.spy_calls()
                          if call[:3] == ["gh", "release", "create"]], [],
                         "a published release must not be recreated")

    def test_create_draft_refuses_draft_with_matching_names_but_wrong_sizes(self):
        # Asset names alone cannot tell two builds of the same version
        # apart; every asset's size must equal the local file's size.
        self.build_fixture()
        self.assertEqual(self.publish(execute=True).returncode, 0)
        self.simulate_pushed_tag()
        self.write_gh_release(wrong_size=True)
        result = self.publish(create_draft=True)
        combined = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, combined)
        self.assertIn("names or sizes differ", combined)
        self.assertEqual([call for call in self.spy_calls()
                          if call[:3] == ["gh", "release", "create"]], [],
                         "a same-named but different build must not be "
                         "reused or recreated")


if __name__ == "__main__":
    unittest.main()