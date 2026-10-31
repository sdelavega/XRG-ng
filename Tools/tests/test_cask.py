# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Verify the Homebrew cask renderer and the publish script's preflight.

``publish-release.sh`` runs against throwaway repositories with a local bare
origin and PATH-shimmed ``git``/``gh`` spies that record every call, so every
refusal is proven to happen before any tag, release or commit and no test
ever touches the real checkout, its remote or the Homebrew tap. The expected
public asset inventories mirror what ``Tools/release-linux.py`` and
``Tools/release-signing.py`` produce.
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
WORK_ROOT = Path(tempfile.gettempdir()) / "xrg-0.2.1-task-4"

_spec = importlib.util.spec_from_file_location("cask", TOOLS / "cask.py")
cask = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cask)
_spec = importlib.util.spec_from_file_location("appcast", TOOLS / "appcast.py")
appcast = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(appcast)

VERSION = "0.2.1"
BUILD = "2"
SHA256 = "3bab9b8c40df6b0443fe653cc99f2a1999fec2856b7af9ce9485795f8bb72f97"
APPCAST_URL = "https://sdelavega.github.io/XRG-ng/appcast.xml"

EXPECTED_FIELDS = [
    'cask "xrg-ng"',
    f'version "{VERSION}"',
    f'sha256 "{SHA256}"',
    "url \"https://github.com/sdelavega/XRG-ng/releases/download/"
    "v#{version}/XRG-ng-#{version}-macOS-universal.dmg\"",
    'name "XRG-ng"',
    'desc "Real-time system resource monitor with floating graphs"',
    'homepage "https://github.com/sdelavega/XRG-ng"',
    f'url "{APPCAST_URL}"',
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
        self.assertIn(f"livecheck do\n    url \"{APPCAST_URL}\"", rendered)
        self.assertNotIn("raw/main", rendered)

    def test_rejects_non_hex_sha(self):
        for bad in ["a" * 63, "z" * 64, "g" * 64, "0" * 63 + "g", "",
                    SHA256.upper() + "0"]:
            with self.assertRaises(ValueError):
                cask.render_cask(VERSION, bad)


class PublishScriptTests(unittest.TestCase):
    """Dry-run and --execute publish scenarios against throwaway repos.

    ``git`` and ``gh`` are PATH-shimmed: git forwards to the real git while
    recording every call, gh only records. Tests assert from the spy log that
    refusals happen before any tag, commit, fetch or release call.
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

    def git(self, *arguments, cwd=None):
        return subprocess.run(["git", *arguments], cwd=cwd or self.repo,
                              check=True, capture_output=True, text=True)

    def make_shims(self):
        self.shims.mkdir()
        (self.shims / "git").write_text(
            "#!/bin/sh\n"
            f"log={shlex.quote(str(self.log))}\n"
            f"real={shlex.quote(shutil.which('git'))}\n"
            "{ printf 'git\\t'; printf '%s\\t' \"$@\"; printf '\\n'; } >> \"$log\"\n"
            "exec \"$real\" \"$@\"\n")
        (self.shims / "gh").write_text(
            "#!/bin/sh\n"
            f"log={shlex.quote(str(self.log))}\n"
            "{ printf 'gh\\t'; printf '%s\\t' \"$@\"; printf '\\n'; } >> \"$log\"\n"
            "exit 0\n")
        os.chmod(self.shims / "git", 0o755)
        os.chmod(self.shims / "gh", 0o755)

    def spy_calls(self):
        if not self.log.exists():
            return []
        return [line.split("\t")[:-1]
                for line in self.log.read_text(encoding="utf-8").splitlines()]

    def mutating_calls(self):
        """Spy calls that create tags/commits/releases or fetch remote state."""
        return [call for call in self.spy_calls()
                if (call[0] == "git" and call[1] in ("tag", "commit", "fetch"))
                or call[0] == "gh"]

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
        subprocess.run([shutil.which("ssh-keygen"), "-q", "-t", "ed25519",
                        "-N", "", "-f", str(self.root / "ssh-signing-key")],
                       check=True, capture_output=True)
        self.git("init", "--initial-branch=main", ".")
        self.git("config", "user.name", "XRG test")
        self.git("config", "user.email", "test@example.invalid")
        # SSH signing lets --execute create the signed tag without GnuPG.
        self.git("config", "gpg.format", "ssh")
        self.git("config", "user.signingkey", str(self.root / "ssh-signing-key"))
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
        self.write_repo_sources()
        head = self.commit_repo()
        self.write_release_dirs(head)
        self.make_tap()
        if pending_appcast:
            self.make_pending_appcast()
        return head

    def publish(self, execute=False, tap=True, confirm=None, tap_path=None):
        env = dict(os.environ)
        env["PATH"] = f"{self.shims}{os.pathsep}{env['PATH']}"
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
        return subprocess.run(arguments, capture_output=True, text=True,
                              env=env,
                              input=confirm if confirm is not None
                              else (f"{VERSION}\n" if execute else ""),
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

    # --- Dry runs ---

    def test_dry_run_prints_planned_steps_without_side_effects(self):
        self.build_fixture()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        combined = result.stdout + result.stderr
        for planned in ["git tag -s", "gh release create", f"v{VERSION}",
                        "cask.py"]:
            self.assertIn(planned, combined)
        for asset in (mac_public_assets(VERSION) + linux_public_assets(VERSION)):
            self.assertIn(asset, combined)
        for private in ["verified-build.txt", "appcast-item.xml",
                        "fingerprint.txt",
                        "xrg-ng-0.2.1-linux-x86_64.tar.gz.sha256"]:
            self.assertNotIn(private, combined)
        self.assertIn("XRG_TAP_DIR", combined)
        self.assert_no_side_effects(result)

    def test_dry_run_skips_appcast_commit_on_clean_tree(self):
        self.build_fixture(pending_appcast=False)
        # Local-only outputs are not required when no appcast update pends.
        (self.mac / "verified-build.txt").unlink()
        (self.mac / "appcast-item.xml").unlink()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("docs/appcast.xml unchanged; nothing to commit",
                      result.stdout + result.stderr)
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

    # --- --execute refusals (spy-proven to precede any side effect) ---

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

    # --- --execute happy path ---

    def test_execute_publishes_tag_draft_and_commits(self):
        head = self.build_fixture()
        result = self.publish(execute=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        combined = result.stdout + result.stderr
        self.assertIn(f"PASS: XRG-ng {VERSION} published", combined)
        calls = self.spy_calls()
        self.assertEqual([call for call in calls
                          if call[:2] == ["git", "fetch"]], [],
                         "no fetch anywhere; the remote check is ls-remote")
        tags = [call for call in calls if call[:2] == ["git", "tag"]]
        self.assertEqual(tags, [["git", "tag", "-s", f"v{VERSION}",
                                 "-m", f"XRG-ng {VERSION}"]])
        releases = [call for call in calls if call[0] == "gh"]
        self.assertEqual(len(releases), 1, calls)
        arguments = releases[0][1:]
        self.assertEqual(arguments[:8],
                         ["release", "create", f"v{VERSION}", "--draft",
                          "--title", f"XRG-ng {VERSION}", "--notes-file",
                          f"releases/{VERSION}.md"])
        expected_assets = {str(self.mac / name)
                           for name in mac_public_assets(VERSION)}
        expected_assets |= {str(self.linux / name)
                            for name in linux_public_assets(VERSION)}
        self.assertEqual(len(arguments) - 8, len(expected_assets))
        self.assertEqual(set(arguments[8:]), expected_assets)
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
        self.assertIn(f'url "{APPCAST_URL}"', cask)


if __name__ == "__main__":
    unittest.main()
