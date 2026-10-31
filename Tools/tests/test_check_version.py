# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Verify the cross-platform version checker against minimal fixture copies."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
CHECK_VERSION = TOOLS / "check-version.py"
XCODE_PROJECT = "XRG-ng.xcodeproj/project.pbxproj"
EXPECTED_SOURCES = {XCODE_PROJECT, "latest_version.txt", "xrg-linux/rust/Cargo.toml"}

_spec = importlib.util.spec_from_file_location("check_version", CHECK_VERSION)
check_version = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_version)


class CheckVersionTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xrg-check-version-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write_fixture(self, *, marketing=("0.2.1",) * 6, builds=("2",) * 6,
                      latest="0.2.1", cargo="0.2.1"):
        """Create the minimal version sources check-version.py reads."""
        project = self.root / XCODE_PROJECT
        project.parent.mkdir(parents=True)
        settings = [f"MARKETING_VERSION = {version};" for version in marketing]
        settings += [f"CURRENT_PROJECT_VERSION = {build};" for build in builds]
        project.write_text("\n".join(settings) + "\n", encoding="utf-8")
        (self.root / "latest_version.txt").write_text(f"{latest}\n", encoding="utf-8")
        manifest = self.root / "xrg-linux" / "rust" / "Cargo.toml"
        manifest.parent.mkdir(parents=True)
        manifest.write_text(f'[package]\nname = "xrg-ng-linux"\nversion = "{cargo}"\n',
                            encoding="utf-8")

    def run_checker(self, *arguments):
        return subprocess.run([sys.executable, str(CHECK_VERSION), *arguments],
                              cwd=self.root, text=True, capture_output=True, timeout=120)

    def test_agreeing_versions_pass(self):
        self.write_fixture()
        result = self.run_checker()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "VERSION_OK 0.2.1 build 2")
        versions = check_version.read_versions(self.root)
        self.assertEqual(set(versions), EXPECTED_SOURCES)
        self.assertEqual(set(versions.values()), {"0.2.1"})
        self.assertEqual(check_version.read_build(self.root), "2")

    def test_cargo_mismatch_reports_file(self):
        self.write_fixture(cargo="0.2.0")
        result = self.run_checker()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("xrg-linux/rust/Cargo.toml", result.stdout)

    def test_one_xcode_target_mismatch_fails(self):
        self.write_fixture(marketing=("0.2.1",) * 5 + ("0.1.0",))
        result = self.run_checker()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(XCODE_PROJECT, result.stdout)

    def test_expect_flag_mismatch_fails(self):
        self.write_fixture()
        result = self.run_checker("--expect", "0.3.0")
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_mixed_build_numbers_fail(self):
        self.write_fixture(builds=("2",) * 3 + ("1",) * 3)
        result = self.run_checker()
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_combined_failures_report_all_files(self):
        """A conflicting Xcode source must not hide other files' mismatches."""
        self.write_fixture(marketing=("0.2.1",) * 5 + ("0.1.0",), cargo="0.2.0")
        result = self.run_checker("--expect", "0.2.1")
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertEqual(result.stdout.count("VERSION_CHECK_FAILED"), 2, result.stdout)
        self.assertIn(f"{XCODE_PROJECT}: conflicting MARKETING_VERSION values: 0.1.0, 0.2.1",
                      result.stdout)
        self.assertIn("xrg-linux/rust/Cargo.toml carries 0.2.0, expected 0.2.1",
                      result.stdout)


if __name__ == "__main__":
    unittest.main()
