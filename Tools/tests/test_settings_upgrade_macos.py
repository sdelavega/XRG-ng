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
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid
from pathlib import Path

sys.dont_write_bytecode = True

TOOLS = Path(__file__).resolve().parents[1]
REPO = TOOLS.parent
SCRIPT = TOOLS / "settings-upgrade-macos.py"
FIXTURES = REPO / "Shared/Tests/Fixtures/settings"
EXPECTED = FIXTURES / "macos-0.2.2-expected.json"
SEED = FIXTURES / "macos-0.2.2-defaults.plist"

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
            self.assertTrue(any(str(p).endswith("XRG-ng-Private/" + domain) for p in paths))
        finally:
            shutil.rmtree(home, ignore_errors=True)

    def test_private_paths_refuse_production(self):
        with self.assertRaises(RuntimeError):
            upgrade.private_paths(Path("/tmp"), upgrade.PRODUCTION_ID)

    def test_app_document_path_is_the_r11_private_store(self):
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-home-"))
        try:
            path = upgrade.app_document_path(home, domain)
            self.assertEqual(path, home / "Library/Application Support/XRG-ng-Private" / domain / "settings.json")
            self.assertIn(path.parent, upgrade.private_paths(home, domain))
        finally:
            shutil.rmtree(home, ignore_errors=True)


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


# --------------------------------------------------------------------------
# Finding 1: the document must come from the supplied app's own store, and an
# app that does not migrate must fail the check.
# --------------------------------------------------------------------------

class AppDocumentTests(unittest.TestCase):
    def setUp(self):
        self.diagnostics, self.document = upgrade.parse_expected(EXPECTED)
        self.tmp = Path(tempfile.mkdtemp(prefix="xrg-upgrade-appdoc-"))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_non_migrating_app_fails(self):
        # An app whose store wrote NO document -> the check must fail rather
        # than fabricating one from a probe.
        with self.assertRaises(RuntimeError) as caught:
            upgrade.load_app_document(self.tmp / "settings.json", [],
                                      self.diagnostics, self.document)
        self.assertIn("does not migrate", str(caught.exception))

    def test_wrong_app_document_fails(self):
        path = self.tmp / "settings.json"
        path.write_text(self.document.replace('"ai.tracking.enabled": true',
                                             '"ai.tracking.enabled": false'))
        with self.assertRaises(upgrade.DocumentMismatch):
            upgrade.load_app_document(path, [], self.diagnostics, self.document)

    def test_correct_app_document_passes(self):
        path = self.tmp / "settings.json"
        path.write_text(self.document)
        self.assertEqual(upgrade.load_app_document(path, [], self.diagnostics, self.document),
                         self.document)

    def test_app_binary_symbol_gate_rejects_a_gutted_app(self):
        # A supplied app with no document backend must not be able to pass.
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_app_document_backend("_main\n_OBJC_CLASS_$_XRGAppDelegate\n")
        self.assertIn("never migrates", str(caught.exception))

    def test_app_binary_symbol_gate_accepts_a_document_backed_app(self):
        symbols = ("_$s7XRGCore16XRGSettingsStoreC\n"
                   "_$s7XRGCore21XRGSettingsMigrationC\n"
                   "_$s7XRGCore14XRGGraphWindowC\n")
        self.assertIsNone(upgrade.assert_app_document_backend(symbols))


# --------------------------------------------------------------------------
# Finding 1: the app's gated startup migration (R25) and the app-written doc.
# --------------------------------------------------------------------------

class UpgradeCheckStartupScriptTests(unittest.TestCase):
    def test_upgrade_check_env_sets_the_r25_variable(self):
        domain = upgrade.domain_for(upgrade.make_token())
        self.assertEqual(upgrade.upgrade_check_env(domain),
                         {upgrade.UPGRADE_ENV_KEY: domain})
        self.assertEqual(upgrade.UPGRADE_ENV_KEY, "XRG_UPGRADE_CHECK_SOURCE_DOMAIN")

    def test_upgrade_check_env_withheld_is_empty(self):
        # Negative control: withholding the env var writes no document.
        domain = upgrade.domain_for(upgrade.make_token())
        self.assertEqual(upgrade.upgrade_check_env(domain, enabled=False), {})

    def test_upgrade_check_env_refuses_unsafe_ids(self):
        for bad in (upgrade.PRODUCTION_ID, "com.example.other", ""):
            with self.subTest(bad=bad), self.assertRaises(RuntimeError):
                upgrade.upgrade_check_env(bad)

    def test_project_layout_sizes_removes_runtime_size_settings(self):
        _, document = upgrade.parse_expected(EXPECTED)
        obj = json.loads(document)
        obj["settings"]["graphs.cpu.size_width"] = 999.0       # changed
        obj["settings"]["graphs.fans.size_height"] = 123.0      # added
        churned = json.dumps(obj)
        self.assertEqual(upgrade.project_layout_sizes(churned),
                         upgrade.project_layout_sizes(document))

    def test_project_layout_sizes_keeps_non_layout_settings(self):
        _, document = upgrade.parse_expected(EXPECTED)
        obj = json.loads(document)
        obj["settings"]["general.window.title"] = "CORRUPTED"
        self.assertNotEqual(upgrade.project_layout_sizes(json.dumps(obj)),
                            upgrade.project_layout_sizes(document))

    def test_compare_app_document_normalises_layout_sizes(self):
        diagnostics, document = upgrade.parse_expected(EXPECTED)
        obj = json.loads(document)
        obj["settings"]["graphs.cpu.size_width"] = 999.0
        self.assertIsNone(upgrade.compare_app_document(
            diagnostics, document, [], json.dumps(obj)))

    def test_compare_app_document_detects_a_migrated_setting_change(self):
        diagnostics, document = upgrade.parse_expected(EXPECTED)
        obj = json.loads(document)
        obj["settings"]["general.window.title"] = "CORRUPTED"
        with self.assertRaises(upgrade.DocumentMismatch):
            upgrade.compare_app_document(diagnostics, document, [], json.dumps(obj))

    def test_resolve_driver_framework_fails_without_the_app_framework(self):
        # Finding 1: NO this-checkout fallback -- a supplied app with no usable
        # sibling XRGCore.framework must FAIL, not rebuild from this checkout.
        tmp = Path(tempfile.mkdtemp(prefix="xrg-upgrade-framework-"))
        try:
            fake_app = tmp / "XRG-ng.app"
            (fake_app / "Contents/MacOS").mkdir(parents=True)
            (fake_app / "Contents/MacOS/XRG-ng").write_text("")
            with self.assertRaises(RuntimeError) as caught:
                upgrade.resolve_driver_framework(fake_app)
            self.assertIn("no testable XRGCore.framework", str(caught.exception))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# Finding 2: ordering, the byte comparison and the probe-only marker.
# --------------------------------------------------------------------------

class OrderingTests(unittest.TestCase):
    def test_probe_only_never_emits_the_ok_line(self):
        self.assertNotEqual(upgrade.success_marker(False), upgrade.OK_LINE)
        self.assertEqual(upgrade.success_marker(True), upgrade.OK_LINE)
        self.assertNotIn("OK", upgrade.success_marker(False))

    def test_probe_only_never_claims_a_relaunch(self):
        record = upgrade.summary_fields(
            "com.sdelavega.xrg.upgradecheck." + str(uuid.uuid4()),
            SEED, EXPECTED, Path("/tmp/settings.json"), [],
            launched=False, launches=[], defaults_byte_identical=None,
            supplementary_probe_matches=True)
        self.assertFalse(record["launched"])
        self.assertFalse(record["baselineRelaunched"])
        self.assertIsNone(record["defaultsByteIdentical"])

    def test_full_run_claims_only_its_real_relaunch(self):
        launches = [{"app": "0.2.3", "resident": True}, {"app": "0.2.2", "resident": True}]
        record = upgrade.summary_fields(
            "com.sdelavega.xrg.upgradecheck." + str(uuid.uuid4()),
            SEED, EXPECTED, Path("/tmp/settings.json"), [],
            launched=True, launches=launches, defaults_byte_identical=True,
            supplementary_probe_matches=True)
        self.assertTrue(record["launched"])
        self.assertTrue(record["baselineRelaunched"])
        self.assertTrue(record["defaultsByteIdentical"])

    def _domain_bytes(self, changes=None):
        domain = plistlib.loads(SEED.read_bytes())
        if changes:
            domain.update(changes)
        return plistlib.dumps(domain, fmt=plistlib.FMT_XML)

    def test_snapshot_catches_a_changed_cpu_width(self):
        # Finding 2: XRGModule_CPU_width maps to graphs.cpu.size_width
        # (docs/settings-inventory.md §339). It is a MAPPED SETTING, not
        # volatile AppKit state: a changed CPU width MUST fail the comparison.
        baseline = upgrade.defaults_snapshot(self._domain_bytes())
        corrupted = upgrade.defaults_snapshot(self._domain_bytes({
            "XRGModule_CPU_width": 42.0,
        }))
        self.assertNotEqual(baseline, corrupted)

    def test_snapshot_catches_a_changed_graph_height(self):
        # Every one of the 26 XRGModule_* width/height keys must be compared.
        baseline = upgrade.defaults_snapshot(self._domain_bytes())
        corrupted = upgrade.defaults_snapshot(self._domain_bytes({
            "XRGModule_Memory_height": 999.0,
        }))
        self.assertNotEqual(baseline, corrupted)

    def test_snapshot_ignores_only_volatile_appkit_window_state(self):
        # ONLY genuinely volatile AppKit window geometry is projected out.
        baseline = upgrade.defaults_snapshot(self._domain_bytes())
        churned = upgrade.defaults_snapshot(self._domain_bytes({
            "NSWindow Frame xrg_window": "999 0 25 684 0 0 1920 1205 ",
            "unminimizedFrame": "{{1, 2}, {3, 4}}",
        }))
        self.assertEqual(baseline, churned)

    def test_snapshot_catches_a_formerly_excluded_non_appkit_key(self):
        # SU*/aiTokens*/tempLocationsAutoconfigured/packagedSmokeMarker are NOT
        # AppKit state and are no longer excluded; a change must be detected.
        baseline = upgrade.defaults_snapshot(self._domain_bytes())
        for key in ("SUHasLaunchedBefore", "aiTokensDailyPromptTokens",
                    "tempLocationsAutoconfigured", "packagedSmokeMarker"):
            with self.subTest(key=key):
                corrupted = upgrade.defaults_snapshot(self._domain_bytes({key: "changed"}))
                self.assertNotEqual(baseline, corrupted)

    def test_exclusion_list_is_narrow(self):
        # No XRGModule_/SU/aiTokens prefix exclusions: only AppKit window state.
        self.assertEqual(upgrade.VOLATILE_PREFIXES, ("NSWindow Frame ",))
        self.assertEqual(upgrade.VOLATILE_KEYS, frozenset({"unminimizedFrame"}))

    def test_snapshot_catches_corruption_of_a_real_setting(self):
        baseline = upgrade.defaults_snapshot(self._domain_bytes())
        corrupted = upgrade.defaults_snapshot(self._domain_bytes({
            "aiTokensDailyBudget": 1,  # a mapped setting, not excluded state
        }))
        self.assertNotEqual(baseline, corrupted)

    def test_snapshot_is_deterministic(self):
        first = upgrade.defaults_snapshot(self._domain_bytes())
        second = upgrade.defaults_snapshot(self._domain_bytes())
        self.assertEqual(first, second)


# --------------------------------------------------------------------------
# Finding 3: catchable signals and process-group termination/reaping.
# --------------------------------------------------------------------------

class SignalTests(unittest.TestCase):
    def setUp(self):
        self.originals = {sig: signal.getsignal(sig) for sig in upgrade.SIGNALS}

    def tearDown(self):
        for sig, handler in self.originals.items():
            signal.signal(sig, handler)

    def test_all_three_termination_signals_are_handled(self):
        self.assertEqual(set(upgrade.SIGNALS),
                         {signal.SIGTERM, signal.SIGINT, signal.SIGHUP})
        installed = upgrade.install_signal_handlers()
        self.assertEqual(set(installed), set(upgrade.SIGNALS))
        for sig in upgrade.SIGNALS:
            self.assertIs(signal.getsignal(sig), upgrade._signal_handler)

    def test_signal_handler_raises_interrupted(self):
        with self.assertRaises(upgrade.Interrupted) as caught:
            upgrade._signal_handler(signal.SIGTERM, None)
        self.assertEqual(caught.exception.signum, signal.SIGTERM)

    def test_terminate_and_reap_terminates_the_group_and_reaps(self):
        killed = []

        def fake_killpg(pid, sig):
            killed.append((pid, sig))

        class FakeProcess:
            def __init__(self, pid):
                self.pid = pid
                self.waited = 0

            def poll(self):
                return None

            def wait(self, timeout=None):
                self.waited += 1
                return 0

        one, two = FakeProcess(111), FakeProcess(222)
        upgrade.terminate_and_reap([one, two], killpg=fake_killpg,
                                   group_alive=lambda pgid: False)
        self.assertIn((111, signal.SIGTERM), killed)
        self.assertIn((222, signal.SIGTERM), killed)
        self.assertEqual(one.waited, 1)
        self.assertEqual(two.waited, 1)

    def test_terminate_and_reap_signals_the_whole_group_even_if_leader_exited(self):
        # Finding 3: a leader that already exited (poll() != None) must STILL
        # have its whole group signalled -- a child may have survived it.
        killed = []

        def fake_killpg(pid, sig):
            killed.append((pid, sig))

        class ExitedLeader:
            pid = 444

            def poll(self):
                return 0  # already exited

            def wait(self, timeout=None):
                return 0

        upgrade.terminate_and_reap([ExitedLeader()], killpg=fake_killpg,
                                   group_alive=lambda pgid: False)
        self.assertIn((444, signal.SIGTERM), killed)

    def test_terminate_and_reap_escalates_to_sigkill_and_fails_loudly(self):
        # A leader that will not exit: SIGKILL is attempted AND the function
        # raises (no success) instead of returning normally.
        killed = []

        def fake_killpg(pid, sig):
            killed.append((pid, sig))

        class Stubborn:
            pid = 333

            def poll(self):
                return None

            def wait(self, timeout=None):
                raise subprocess.TimeoutExpired("app", 5)

        with self.assertRaises(RuntimeError) as caught:
            upgrade.terminate_and_reap([Stubborn()], killpg=fake_killpg,
                                       group_alive=lambda pgid: False,
                                       sleep=lambda _: None)
        self.assertIn("did not exit after SIGKILL", str(caught.exception))
        self.assertIn((333, signal.SIGTERM), killed)
        self.assertIn((333, signal.SIGKILL), killed)

    def test_stubborn_child_survives_the_leader_fails_loudly(self):
        # Finding 3: the leader is reaped (poll/wait succeed) but a stubborn
        # child keeps the process group alive. The function must signal the
        # whole group anyway, escalate to SIGKILL, and FAIL (no success).
        killed = []

        def fake_killpg(pid, sig):
            killed.append((pid, sig))

        class LeaderWithSurvivingChild:
            pid = 555

            def poll(self):
                return 0  # leader exited

            def wait(self, timeout=None):
                return 0  # leader reaped

        with self.assertRaises(RuntimeError) as caught:
            upgrade.terminate_and_reap(
                [LeaderWithSurvivingChild()], killpg=fake_killpg,
                group_alive=lambda pgid: True, sleep=lambda _: None)
        self.assertIn("could not be confirmed gone", str(caught.exception))
        self.assertIn((555, signal.SIGTERM), killed)
        self.assertIn((555, signal.SIGKILL), killed)


# --------------------------------------------------------------------------
# Finding 4: cleanup attempts every step, checks return codes, verifies gone.
# --------------------------------------------------------------------------

class CleanupTests(unittest.TestCase):
    def _recorded_run(self, delete_rc=0, read_rc=1, calls=None):
        def run(argv, **kwargs):
            if calls is not None:
                calls.append(list(argv))
            class Result:
                returncode = delete_rc if "delete" in argv else read_rc
            return Result()
        return run

    def test_cleanup_refuses_production_before_any_subprocess(self):
        calls = []

        def forbidden_run(argv, **kwargs):
            calls.append(argv)
            raise AssertionError("must not run any command for production id")

        with self.assertRaises(RuntimeError):
            upgrade.cleanup(upgrade.PRODUCTION_ID, Path("/tmp"), run=forbidden_run)
        self.assertEqual(calls, [])

    def test_cleanup_success_returns_no_failures(self):
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-home-"))
        prefs = home / "Library/Preferences" / (domain + ".plist")
        prefs.parent.mkdir(parents=True, exist_ok=True)
        prefs.write_bytes(plistlib.dumps({"marker": domain}))
        support = home / "Library/Application Support/XRG-ng-Private" / domain
        support.mkdir(parents=True, exist_ok=True)
        (support / "settings.json").write_text("{}")
        calls = []
        try:
            failures = upgrade.cleanup(domain, home, run=self._recorded_run(calls=calls))
            self.assertEqual(failures, [])
            self.assertTrue(any("delete" in c and domain in c for c in calls), calls)
            self.assertTrue(any("read" in c and domain in c for c in calls), calls)
            self.assertFalse(prefs.exists())
            self.assertFalse(support.exists())
        finally:
            shutil.rmtree(home, ignore_errors=True)

    def test_cleanup_reports_a_failing_defaults_delete(self):
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-home-"))
        try:
            failures = upgrade.cleanup(domain, home, run=self._recorded_run(delete_rc=7))
            self.assertTrue(any("defaults delete" in f and "7" in f for f in failures), failures)
        finally:
            shutil.rmtree(home, ignore_errors=True)

    def test_cleanup_reports_a_domain_still_registered(self):
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-home-"))
        try:
            failures = upgrade.cleanup(domain, home, run=self._recorded_run(read_rc=0))
            self.assertTrue(any("still registered" in f for f in failures), failures)
        finally:
            shutil.rmtree(home, ignore_errors=True)

    def test_cleanup_accumulates_filesystem_removal_and_verification_failures(self):
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-home-"))
        support = home / "Library/Application Support/XRG-ng-Private" / domain
        support.mkdir(parents=True, exist_ok=True)
        (support / "settings.json").write_text("{}")
        try:
            with mock.patch.object(upgrade.shutil, "rmtree", side_effect=OSError("denied")):
                failures = upgrade.cleanup(domain, home, run=self._recorded_run())
            self.assertTrue(any("could not remove" in f for f in failures), failures)
            self.assertTrue(any("still present" in f for f in failures), failures)
        finally:
            shutil.rmtree(home, ignore_errors=True)

    def test_ok_line_is_suppressed_when_cleanup_failed(self):
        with self.assertRaises(RuntimeError) as caught:
            upgrade.ok_after_cleanup(["defaults delete domain returned 7"], launched=True)
        self.assertIn("cleanup failed", str(caught.exception))
        self.assertNotIn(upgrade.OK_LINE, str(caught.exception))

    def test_ok_line_returns_only_when_cleanup_succeeded(self):
        self.assertEqual(upgrade.ok_after_cleanup([], launched=True), upgrade.OK_LINE)
        self.assertEqual(upgrade.ok_after_cleanup([], launched=False), upgrade.PROBE_ONLY_LINE)


# --------------------------------------------------------------------------
# Finding 5: protected --seed/--expected inputs (including symlink aliases).
# --------------------------------------------------------------------------

class InputSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="xrg-upgrade-inputs-"))
        self.home = self.tmp / "home"
        self.plist = self.home / "Library/Preferences/com.sdelavega.xrg.plist"
        self.settings = self.home / "Library/Application Support/XRG-ng/settings.json"
        self.plist.parent.mkdir(parents=True)
        self.settings.parent.mkdir(parents=True)
        self.plist.write_bytes(plistlib.dumps({"real": "never-read"}))
        self.settings.write_text("{}")
        self.scratch = self.tmp / "scratch"
        self.scratch.mkdir()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def safe(self, seed, expected):
        # Does not read the file: only resolves symlinks/realpath.
        upgrade.assert_safe_inputs(seed, expected, self.home)

    def test_refuses_the_production_plist_as_seed(self):
        with self.assertRaises(RuntimeError) as caught:
            self.safe(self.plist, self.scratch / "expected.json")
        self.assertIn("--seed", str(caught.exception))

    def test_refuses_the_production_settings_file_as_expected(self):
        with self.assertRaises(RuntimeError) as caught:
            self.safe(self.scratch / "seed.plist", self.settings)
        self.assertIn("--expected", str(caught.exception))

    def test_refuses_a_symlink_alias_of_the_production_plist(self):
        alias = self.scratch / "prefs-alias.plist"
        alias.symlink_to(self.plist)
        with self.assertRaises(RuntimeError):
            self.safe(alias, self.scratch / "expected.json")

    def test_refuses_a_symlink_alias_of_the_production_settings_file(self):
        alias = self.scratch / "settings-alias.json"
        alias.symlink_to(self.settings)
        with self.assertRaises(RuntimeError):
            self.safe(self.scratch / "seed.plist", alias)

    def test_accepts_a_coordinator_export_copy_in_scratch(self):
        export = self.scratch / "exported-prefs.plist"
        export.write_bytes(plistlib.dumps({"exported": True}))
        expected = self.scratch / "expected.json"
        expected.write_text("{}")
        self.assertIsNone(self.safe(export, expected))

    def test_accepts_the_default_fixtures(self):
        self.assertIsNone(self.safe(upgrade.default_seed_path(), upgrade.default_expected_path()))


if __name__ == "__main__":
    unittest.main()
