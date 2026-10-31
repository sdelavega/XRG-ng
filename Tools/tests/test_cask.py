# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Verify the Homebrew cask renderer and the publish script's preconditions.

Only dry runs are exercised here: ``publish-release.sh`` is run against a
throwaway repository with a local bare origin, so no tag, release or tap
commit is ever created outside the test fixture. ``--execute`` requires
``XRG_TAP_DIR`` and interactive confirmation and is never exercised by tests.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
PUBLISH = TOOLS / "publish-release.sh"

_spec = importlib.util.spec_from_file_location("cask", TOOLS / "cask.py")
cask = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cask)

VERSION = "0.2.1"
SHA256 = "3bab9b8c40df6b0443fe653cc99f2a1999fec2856b7af9ce9485795f8bb72f97"

EXPECTED_FIELDS = [
    'cask "xrg-ng"',
    f'version "{VERSION}"',
    f'sha256 "{SHA256}"',
    "url \"https://github.com/sdelavega/XRG-ng/releases/download/"
    "v#{version}/XRG-ng-#{version}-macOS-universal.dmg\"",
    'name "XRG-ng"',
    'desc "Real-time system resource monitor with floating graphs"',
    'homepage "https://github.com/sdelavega/XRG-ng"',
    "strategy :sparkle",
    "auto_updates true",
    "depends_on macos: :tahoe",
    'app "XRG-ng.app"',
    '"~/Library/Caches/com.sdelavega.xrg"',
    '"~/Library/HTTPStorages/com.sdelavega.xrg"',
    '"~/Library/Preferences/com.sdelavega.xrg.plist"',
]


class RenderCaskTests(unittest.TestCase):
    def test_render_cask_fields(self):
        rendered = cask.render_cask(VERSION, SHA256)
        for field in EXPECTED_FIELDS:
            self.assertIn(field, rendered)

    def test_rejects_non_hex_sha(self):
        for bad in ["a" * 63, "z" * 64, "g" * 64, "0" * 63 + "g", "",
                    SHA256.upper() + "0"]:
            with self.assertRaises(ValueError):
                cask.render_cask(VERSION, bad)


class PublishDryRunTests(unittest.TestCase):
    """Dry-run publish scenarios against a throwaway repository."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="xrg-publish-test-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.repo = self.root / "repo"
        self.mac = self.root / "mac-release"
        self.linux = self.root / "linux-release"
        self.origin = self.root / "origin.git"

    def git(self, *arguments, cwd=None):
        return subprocess.run(["git", *arguments], cwd=cwd or self.repo,
                              check=True, capture_output=True, text=True)

    def write_repo_sources(self):
        stem = f"XRG-ng-{VERSION}-macOS-universal"
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
        appcast.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<rss/>\n')
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
                              check=True, capture_output=True, text=True).stdout.strip()
        self.git("clone", "--bare", str(self.repo), str(self.origin), cwd=self.root)
        self.git("remote", "add", "origin", str(self.origin))
        self.git("fetch", "--quiet", "origin", "main")
        return head

    def write_release_dirs(self, head):
        stem = f"XRG-ng-{VERSION}-macOS-universal"
        dmg = self.mac / f"{stem}.dmg"
        self.mac.mkdir(parents=True)
        dmg.write_bytes(b"universal disk image fixture")
        (self.mac / f"{stem}.zip").write_bytes(b"universal zip fixture")
        sums = "".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n"
                        for p in sorted(self.mac.iterdir()))
        (self.mac / "SHA256SUMS.txt").write_text(sums)
        (self.mac / "release-build.json").write_text(
            json.dumps({"version": VERSION, "build": "2", "sourceCommit": head}) + "\n")
        (self.mac / "verified-build.txt").write_text("2\n")
        (self.mac / "appcast-item.xml").write_text("<item/>\n")

        self.linux.mkdir(parents=True)
        deb = self.linux / f"xrg-ng_{VERSION}-1_amd64.deb"
        deb.write_bytes(b"linux package fixture")
        (self.linux / "release-metadata.json").write_text(
            json.dumps({"revision": head, "version": VERSION}) + "\n")
        (self.linux / "SHA256SUMS").write_text(
            f"{hashlib.sha256(deb.read_bytes()).hexdigest()}  {deb.name}\n")

    def make_fixture(self):
        self.write_repo_sources()
        head = self.commit_repo()
        self.write_release_dirs(head)
        return head

    def publish(self):
        return subprocess.run(
            ["bash", str(self.repo / "Tools" / "publish-release.sh"),
             VERSION, str(self.mac), str(self.linux)],
            capture_output=True, text=True)

    def tags(self):
        return self.git("tag", "-l").stdout.split()

    def test_dry_run_prints_planned_steps_without_side_effects(self):
        self.make_fixture()
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        combined = result.stdout + result.stderr
        for planned in ["git tag -s", "gh release create", f"v{VERSION}",
                        "cask.py"]:
            self.assertIn(planned, combined)
        self.assertEqual(self.tags(), [])  # no tag created
        self.assertIn("XRG_TAP_DIR", combined)  # printed, not required

    def test_publish_dry_run_refuses_dirty_tree(self):
        self.make_fixture()
        (self.repo / "uncommitted.txt").write_text("dirty\n")
        result = self.publish()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Commit source changes", result.stdout + result.stderr)
        self.assertEqual(self.tags(), [])  # no tag created

    def test_publish_dry_run_refuses_checksum_mismatch(self):
        self.make_fixture()
        dmg = next(p for p in self.mac.iterdir() if p.suffix == ".dmg")
        dmg.write_bytes(b"tampered universal disk image")
        result = self.publish()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("checksum", (result.stdout + result.stderr).lower())
        self.assertEqual(self.tags(), [])  # no tag created


if __name__ == "__main__":
    unittest.main()