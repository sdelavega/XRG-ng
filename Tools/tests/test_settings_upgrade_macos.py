#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Unit tests for Tools/settings-upgrade-macos.py (the 0.2.2 -> 0.2.3 ->
0.2.2 macOS upgrade/downgrade check).

These tests exercise only pure, side-effect-free helpers: they never read the
real com.sdelavega.xrg defaults domain, never launch an app, and never touch
~/Library. The script has a hyphen in its name, so it is loaded by path (the
same technique Tools/packaged-smoke-macos.py uses for smoke-macos.py).
"""
import importlib.util
import json
import plistlib
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

sys.dont_write_bytecode = True

TOOLS = Path(__file__).resolve().parents[1]
REPO = TOOLS.parent
SCRIPT = TOOLS / "settings-upgrade-macos.py"
FIXTURES = REPO / "Shared/Tests/Fixtures/settings"
EXPECTED = FIXTURES / "macos-0.2.2-expected.json"

spec = importlib.util.spec_from_file_location("xrg_settings_upgrade_macos", SCRIPT)
upgrade = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(upgrade)


class SafetyTests(unittest.TestCase):
    def test_generated_domain_is_private_namespaced_uuid(self):
        token = upgrade.make_token()
        self.assertEqual(str(uuid.UUID(token)), token)
        domain = upgrade.domain_for(token)
        self.assertTrue(domain.startswith(upgrade.UPGRADE_PREFIX))
        self.assertNotEqual(domain, upgrade.PRODUCTION_ID)
        # A valid, generated domain passes the safety gate.
        upgrade.assert_safe_ids([domain])

    def test_safety_refuses_production_id(self):
        with self.assertRaises(RuntimeError):
            upgrade.assert_safe_ids([upgrade.PRODUCTION_ID])

    def test_safety_refuses_production_among_many(self):
        domain = upgrade.domain_for(upgrade.make_token())
        with self.assertRaises(RuntimeError):
            upgrade.assert_safe_ids([domain, upgrade.PRODUCTION_ID])

    def test_safety_refuses_foreign_or_non_namespaced_ids(self):
        for bad in ("com.example.other", "com.sdelavega.xrg.upgradecheck.NOT-A-UUID",
                    "com.sdelavega.xrg.other." + str(uuid.uuid4()), ""):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                upgrade.assert_safe_ids([bad])

    def test_safety_refuses_empty_list(self):
        with self.assertRaises(RuntimeError):
            upgrade.assert_safe_ids([])

    def test_private_paths_stay_in_the_disposable_namespace(self):
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-home-"))
        try:
            paths = upgrade.private_paths(home, domain)
            self.assertTrue(paths)
            for path in paths:
                self.assertTrue(str(path).startswith(str(home)), path)
                self.assertNotIn("XRG-ng/", str(path) + "/")  # never the production store
                self.assertNotEqual(path.name, "com.sdelavega.xrg.plist")
            # The R11 private settings folder is included for cleanup.
            self.assertTrue(any(str(p).endswith("XRG-ng-Private/" + domain) for p in paths))
        finally:
            import shutil
            shutil.rmtree(home, ignore_errors=True)

    def test_private_paths_refuse_production(self):
        with self.assertRaises(RuntimeError):
            upgrade.private_paths(Path("/tmp"), upgrade.PRODUCTION_ID)


class FixtureTests(unittest.TestCase):
    def test_default_paths_resolve_to_real_fixtures(self):
        self.assertTrue(upgrade.default_seed_path().is_file())
        self.assertTrue(upgrade.default_expected_path().is_file())

    def test_parse_expected_shape(self):
        diagnostics, document = upgrade.parse_expected(EXPECTED)
        self.assertEqual(diagnostics, [])
        self.assertIn('"format": "xrg-ng-settings"', document)
        parsed = json.loads(document)
        self.assertEqual(parsed["version"], 1)
        self.assertIn("graphs.stock.visible", parsed["settings"])

    def test_parse_expected_rejects_wrong_shape(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as stream:
            json.dump({"diagnostics": [], "no_document": 1}, stream)
            temporary = Path(stream.name)
        try:
            with self.assertRaises(RuntimeError):
                upgrade.parse_expected(temporary)
        finally:
            temporary.unlink()


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.diagnostics, self.document = upgrade.parse_expected(EXPECTED)

    def test_green_exact_document_and_diagnostics(self):
        # The migration probe emits the canonical bytes and an empty diagnostic
        # list; this is what a correct 0.2.2 -> 0.2.3 migration looks like.
        self.assertIsNone(upgrade.compare_documents(
            self.diagnostics, self.document, [], self.document))

    def test_red_tampered_document(self):
        tampered = self.document.replace('"ai.tracking.enabled": true',
                                         '"ai.tracking.enabled": false')
        with self.assertRaises(upgrade.DocumentMismatch) as caught:
            upgrade.compare_documents(self.diagnostics, self.document, [], tampered)
        self.assertIn("MISMATCH", str(caught.exception))
        self.assertIn("fixture", str(caught.exception).lower())

    def test_red_unexpected_diagnostics(self):
        with self.assertRaises(upgrade.DocumentMismatch):
            upgrade.compare_documents(
                self.diagnostics, self.document,
                [{"id": "graphs.stock.visible", "problem": "invalid-value"}],
                self.document)

    def test_red_missing_document(self):
        with self.assertRaises(upgrade.DocumentMismatch):
            upgrade.compare_documents(self.diagnostics, self.document, [], "")


class CleanupTests(unittest.TestCase):
    def test_cleanup_refuses_production_before_any_subprocess(self):
        calls = []

        def forbidden_run(argv, **kwargs):
            calls.append(argv)
            raise AssertionError("must not run any command for production id")

        with self.assertRaises(RuntimeError):
            upgrade.cleanup(upgrade.PRODUCTION_ID, Path("/tmp"), run=forbidden_run)
        self.assertEqual(calls, [])

    def test_cleanup_deletes_domain_and_removes_private_files(self):
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-home-"))
        prefs = home / "Library/Preferences" / (domain + ".plist")
        prefs.parent.mkdir(parents=True, exist_ok=True)
        prefs.write_bytes(plistlib.dumps({"marker": domain}))
        support = home / "Library/Application Support/XRG-ng-Private" / domain
        support.mkdir(parents=True, exist_ok=True)
        (support / "settings.json").write_text("{}")
        calls = []

        def recorded_run(argv, **kwargs):
            calls.append(list(argv))
            class Result:
                returncode = 0
            return Result()

        try:
            upgrade.cleanup(domain, home, run=recorded_run)
            self.assertTrue(any("delete" in c and domain in c for c in calls), calls)
            self.assertFalse(prefs.exists())
            self.assertFalse(support.exists())
        finally:
            import shutil
            shutil.rmtree(home, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()
