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


def app_document_with_all_sizes(base_document, overrides=None, drop=(), geometry=None):
    """A LAUNCHED-APP-style document: the pure-migration oracle's settings PLUS
    ALL 26 explicit layout size keys set to their EXPECTED values DERIVED from
    the app's own layout rules + a geometry + seed (fix round 4). Fix round 5:
    ``geometry`` is the INDEPENDENTLY MEASURED geometry (measured_geometry());
    ``None`` keeps the deterministic unit-test reference so all pre-round-5
    tests remain valid. Since fix round 3 load_app_document REQUIRES all 26
    present and valid, and fix round 4 additionally requires CORRECT (derived)
    values, not just any in-range number."""
    obj = json.loads(base_document)
    for key, (expected, _tol) in upgrade.expected_layout_sizes(geometry).items():
        obj["settings"][key] = expected
    for key in drop:
        obj["settings"].pop(key, None)
    if overrides:
        obj["settings"].update(overrides)
    return json.dumps(obj)


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
        diagnostics, raw_document = upgrade.parse_expected(EXPECTED)
        self.diagnostics = diagnostics
        # load_app_document now validates ALL 26 explicit layout size keys, so
        # these tests use an app-style document that carries all of them.
        self.document = app_document_with_all_sizes(raw_document)
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


# --------------------------------------------------------------------------
# Fix round 3, finding 2: the downgrade reference is captured BEFORE 0.2.3 and
# a value changed by the 0.2.3 step MUST fail the compare (phase order).
# --------------------------------------------------------------------------

class DowngradeComparisonTests(unittest.TestCase):
    def _domain_bytes(self, changes=None):
        domain = plistlib.loads(SEED.read_bytes())
        if changes:
            domain.update(changes)
        return plistlib.dumps(domain, fmt=plistlib.FMT_XML)

    def test_reference_is_captured_before_the_upgrade_in_phase_order(self):
        phases = upgrade.DOWNGRADE_PHASES
        self.assertLess(phases.index("0.2.2-normalise"), phases.index("capture-reference"))
        self.assertLess(phases.index("capture-reference"), phases.index("0.2.3-upgrade"),
                        "the downgrade reference MUST be captured before 0.2.3 ever runs")
        self.assertLess(phases.index("0.2.3-upgrade"), phases.index("0.2.2-downgrade"))
        self.assertLess(phases.index("0.2.2-downgrade"), phases.index("compare-to-reference"))

    def test_value_changed_by_the_upgrade_step_fails_the_compare(self):
        # Reference captured BEFORE 0.2.3 (clean); 0.2.3 changes a persistent
        # mapped preference that 0.2.2 preserves, so it shows up in the final
        # 0.2.2 defaults. The compare MUST fail (the old order would pass).
        reference = self._domain_bytes()
        final = self._domain_bytes({"showCPUGraph": False})
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_defaults_unchanged(reference, final)
        self.assertIn("round trip", str(caught.exception).lower())

    def test_a_changed_graph_size_also_fails_the_compare(self):
        reference = self._domain_bytes()
        final = self._domain_bytes({"XRGModule_CPU_width": 999.0})
        with self.assertRaises(RuntimeError):
            upgrade.assert_defaults_unchanged(reference, final)

    def test_unchanged_defaults_pass_the_compare(self):
        reference = self._domain_bytes()
        self.assertIsNone(upgrade.assert_defaults_unchanged(reference, reference))

    def test_only_volatile_appkit_state_is_ignored(self):
        reference = self._domain_bytes()
        final = self._domain_bytes({"NSWindow Frame XRG2": "1 2 3 4",
                                    "unminimizedFrame": "{{1,2},{3,4}}"})
        self.assertIsNone(upgrade.assert_defaults_unchanged(reference, final))

    def test_old_post_upgrade_reference_would_hide_the_damage(self):
        # WHY the reorder matters: if the reference is ALSO captured after 0.2.3
        # (both snapshots carry the damage), the compare passes and misses it.
        damaged = self._domain_bytes({"showCPUGraph": False})
        self.assertIsNone(upgrade.assert_defaults_unchanged(damaged, damaged))


# --------------------------------------------------------------------------
# Fix round 3, finding 2: the EXPLICIT 26 size keys must be present and valid,
# consistent with the controlled geometry; missing/corrupted entries fail.
# --------------------------------------------------------------------------

class LayoutSizeTests(unittest.TestCase):
    def _document(self, overrides=None, drop=()):
        _, base = upgrade.parse_expected(EXPECTED)
        return app_document_with_all_sizes(base, overrides=overrides, drop=drop)

    def test_explicit_list_is_exactly_26_keys(self):
        self.assertEqual(len(upgrade.LAYOUT_SIZE_KEYS), 26)
        self.assertIsInstance(upgrade.LAYOUT_SIZE_KEYS, frozenset)
        for gid in upgrade.GRAPH_IDS:
            self.assertIn(f"graphs.{gid}.size_width", upgrade.LAYOUT_SIZE_KEYS)
            self.assertIn(f"graphs.{gid}.size_height", upgrade.LAYOUT_SIZE_KEYS)
        self.assertNotIn("graphs.something.size_width", upgrade.LAYOUT_SIZE_KEYS)

    def test_all_26_present_and_valid_passes(self):
        self.assertEqual(len(upgrade.assert_layout_sizes(self._document())), 26)

    def test_missing_size_key_fails(self):
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(self._document(drop=("graphs.cpu.size_width",)))
        self.assertIn("missing", str(caught.exception).lower())

    def test_corrupted_size_values_fail(self):
        for bad in (None, "oops", True, -1.0, -50, float("nan"), float("inf"), 999999.0):
            with self.subTest(bad=bad):
                with self.assertRaises(RuntimeError) as caught:
                    upgrade.assert_layout_sizes(self._document(
                        overrides={"graphs.cpu.size_width": bad}))
                self.assertIn("corrupted", str(caught.exception).lower())

    def test_value_exceeding_controlled_geometry_fails(self):
        bound = upgrade.SIZE_UPPER_BOUND
        with self.assertRaises(RuntimeError):
            upgrade.assert_layout_sizes(self._document(
                overrides={"graphs.memory.size_height": float(bound) + 1}))

    def test_projection_keeps_a_non_listed_size_like_key(self):
        # The old regex dropped ANY graphs.*.size_* key; the explicit list must
        # NOT silently drop a key outside the 26.
        _, base = upgrade.parse_expected(EXPECTED)
        obj = json.loads(base)
        obj["settings"]["graphs.not_a_real_graph.size_width"] = 123.0
        self.assertNotEqual(upgrade.project_layout_sizes(json.dumps(obj)),
                            upgrade.project_layout_sizes(base))

    def test_load_app_document_requires_all_26_size_keys(self):
        # A document byte-exact to the oracle but lacking the 26 size keys must
        # now FAIL (the old projection alone would have accepted it).
        _, base = upgrade.parse_expected(EXPECTED)
        tmp = Path(tempfile.mkdtemp(prefix="xrg-upgrade-sizes-"))
        try:
            path = tmp / "settings.json"
            path.write_text(base)  # only the 3 seeded size keys
            with self.assertRaises(RuntimeError) as caught:
                upgrade.load_app_document(path, [], [], base)
            self.assertIn("missing", str(caught.exception).lower())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# Fix round 3, finding 3: caller-level proof that storage deletion is GATED on
# confirmed process-group termination (cleanup NOT invoked when reaping fails).
# --------------------------------------------------------------------------

class ReapGatingTests(unittest.TestCase):
    def test_cleanup_is_not_invoked_when_reaping_fails(self):
        calls = {"cleanup": 0, "unregister": 0}
        reported = []
        domain = upgrade.domain_for(upgrade.make_token())
        home = Path(tempfile.mkdtemp(prefix="xrg-upgrade-reap-"))
        self.addCleanup(shutil.rmtree, home, ignore_errors=True)

        def failing_reap(pending):
            raise RuntimeError("process group 123 could not be confirmed gone")

        def forbidden_cleanup(d, h):
            calls["cleanup"] += 1
            return []

        with self.assertRaises(RuntimeError) as caught:
            upgrade.reap_and_cleanup(
                [object()], domain, home, (Path("/tmp/XRG-ng.app"),),
                reap=failing_reap, cleanup_fn=forbidden_cleanup,
                unregister=lambda app: calls.__setitem__(
                    "unregister", calls["unregister"] + 1),
                report=lambda retained, d: reported.extend(retained))
        self.assertEqual(calls["cleanup"], 0,
                         "storage MUST NOT be deleted when reaping fails")
        self.assertEqual(calls["unregister"], 0)
        self.assertIn("NOT deleted", str(caught.exception))
        self.assertIn("could not confirm", str(caught.exception))
        self.assertTrue(reported, "retained disposable paths must be printed")

    def test_cleanup_runs_only_after_confirmed_reaping(self):
        domain = upgrade.domain_for(upgrade.make_token())
        cleaned = []
        unregistered = []
        result = upgrade.reap_and_cleanup(
            [], domain, Path("/tmp"), (Path("/tmp/XRG-ng.app"),),
            reap=lambda pending: None,
            cleanup_fn=lambda d, h: cleaned.append((d, h)) or [],
            unregister=lambda app: unregistered.append(app),
            report=lambda retained, d: None)
        self.assertEqual(result, [])
        self.assertTrue(cleaned, "cleanup must run after confirmed termination")
        self.assertTrue(unregistered)

    def test_reap_failure_fails_loudly_with_no_success_marker(self):
        # The caller raises (non-zero exit); ok_after_cleanup is never reached,
        # so no SETTINGS_UPGRADE_MACOS_OK line is ever printed.
        domain = upgrade.domain_for(upgrade.make_token())
        with self.assertRaises(RuntimeError) as caught:
            upgrade.reap_and_cleanup(
                [object()], domain, Path("/tmp"), (),
                reap=lambda p: (_ for _ in ()).throw(RuntimeError("survivor")),
                cleanup_fn=lambda d, h: [],
                unregister=lambda app: None,
                report=lambda retained, d: None)
        self.assertNotIn(upgrade.OK_LINE, str(caught.exception))


# --------------------------------------------------------------------------
# Fix round 3, R26: the document rewrite measurement is observational only and
# NEVER gates success (never raises on a difference).
# --------------------------------------------------------------------------

class R26MeasurementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="xrg-upgrade-r26-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def _write(self, settings):
        path = self.tmp / "settings.json"
        path.write_text(json.dumps({"format": "xrg-ng-settings", "version": 1,
                                    "settings": settings}))
        return path

    def test_identical_document_reports_not_rewritten(self):
        path = self._write({"graphs.cpu.size_width": 100})
        before = path.read_bytes()
        result = upgrade.measure_document_rewrite(path, before)
        self.assertTrue(result["byteIdentical"])
        self.assertFalse(result["documentRewritten"])
        self.assertEqual(result["changedKeys"], [])

    def test_changed_document_reports_which_keys(self):
        path = self._write({"graphs.cpu.size_width": 100, "general.x": 1})
        before = path.read_bytes()
        self._write({"graphs.cpu.size_width": 200, "general.x": 1})
        result = upgrade.measure_document_rewrite(path, before)
        self.assertTrue(result["documentRewritten"])
        self.assertEqual(result["changedKeys"], ["graphs.cpu.size_width"])

    def test_measurement_never_raises_on_a_difference_or_removal(self):
        path = self._write({"a": 1})
        before = path.read_bytes()
        path.unlink()  # document removed entirely
        result = upgrade.measure_document_rewrite(path, before)
        self.assertFalse(result["documentPresentAfterRelaunch"])
        self.assertTrue(result["documentRewritten"])


# --------------------------------------------------------------------------
# Fix round 4, finding 2a: 0.2.2 baseline normalisation MUST CONVERGE (two
# consecutive identical settings snapshots) within the bounded attempts. An
# exhausted A->B->C baseline must FAIL -- never claim a normalised downgrade
# reference, never set downgrade_normalised, never print the OK line.
# --------------------------------------------------------------------------

class NormalisationConvergenceTests(unittest.TestCase):
    def _capture_from(self, sequence):
        it = iter(sequence)
        calls = []

        def capture():
            raw = next(it)
            calls.append(raw)
            return raw

        return capture, calls

    def test_convergence_on_first_two_identical_returns_settled_reference(self):
        capture, calls = self._capture_from([b"A", b"A", b"C"])
        result = upgrade.normalise_until_converged(capture, 3, snapshot=lambda r: r)
        self.assertEqual(result, b"A")
        self.assertEqual(calls, [b"A", b"A"],
                         "must stop as soon as two consecutive snapshots match")

    def test_convergence_after_a_cold_then_warm_launch(self):
        # The real 0.2.2 sequence (measured): A = cold 21.18, B = warm
        # 157.4545..., B again. Two consecutive identical snapshots appear on
        # attempts 2 and 3, so the reference is captured from the settled state.
        capture, calls = self._capture_from([b"A", b"B", b"B"])
        result = upgrade.normalise_until_converged(capture, 3, snapshot=lambda r: r)
        self.assertEqual(result, b"B")
        self.assertEqual(len(calls), 3)

    def test_exhaustion_a_b_c_fails(self):
        # A->B->C NEVER produces two consecutive identical snapshots: the
        # bounded loop must FAIL loudly rather than claim convergence.
        capture, calls = self._capture_from([b"A", b"B", b"C"])
        with self.assertRaises(upgrade.NormalisationDidNotConverge) as caught:
            upgrade.normalise_until_converged(capture, 3, snapshot=lambda r: r)
        self.assertIn("did not converge", str(caught.exception).lower())
        self.assertIn("two consecutive", str(caught.exception).lower())
        self.assertEqual(len(calls), 3, "all bounded attempts were consumed")

    def test_normalisation_did_not_converge_is_a_runtime_error(self):
        # main() catches RuntimeError -> non-zero exit, no OK line.
        self.assertTrue(issubclass(upgrade.NormalisationDidNotConverge, RuntimeError))

    def test_exhaustion_never_captures_reference_nor_claims_normalised(self):
        # Mirror main()'s [1]+[2] gate exactly: the reference is written and
        # downgrade_normalised is set ONLY after normalise_until_converged
        # RETURNS. On exhaustion the exception propagates, so neither happens.
        written = []
        downgrade_normalised = False
        reference_raw = None
        capture, _ = self._capture_from([b"A", b"B", b"C"])
        try:
            reference_raw = upgrade.normalise_until_converged(
                capture, 3, snapshot=lambda r: r)
            written.append(reference_raw)     # [2] capture-reference
            downgrade_normalised = True        # ONLY on demonstrated convergence
        except upgrade.NormalisationDidNotConverge:
            pass
        self.assertIsNone(reference_raw)
        self.assertEqual(written, [], "no downgrade reference on exhaustion")
        self.assertFalse(downgrade_normalised,
                         "never claim a normalised baseline on exhaustion")

    def test_default_attempt_bound_is_three(self):
        self.assertEqual(upgrade.MAX_NORMALISE_ATTEMPTS, 3)
        # A single attempt can never show two consecutive snapshots -> fails.
        with self.assertRaises(upgrade.NormalisationDidNotConverge):
            upgrade.normalise_until_converged(lambda: b"A", 1, snapshot=lambda r: r)

    def test_uses_the_injected_snapshot_function(self):
        # Two DIFFERENT raw exports that the injected snapshot canonicalises to
        # the SAME bytes must converge: the loop compares SNAPSHOTS, not raw.
        capture, _ = self._capture_from([b"raw-1", b"raw-2"])
        result = upgrade.normalise_until_converged(capture, 3,
                                                   snapshot=lambda r: b"stable")
        self.assertEqual(result, b"raw-2")

    def test_summary_reports_the_converged_flag(self):
        domain = "com.sdelavega.xrg.upgradecheck." + str(uuid.uuid4())
        full = upgrade.summary_fields(
            domain, SEED, EXPECTED, Path("/tmp/settings.json"), [],
            launched=True, launches=[], defaults_byte_identical=True,
            supplementary_probe_matches=True, downgrade_normalised=True,
            baseline_converged=True)
        self.assertTrue(full["downgradeBaselineConverged"])
        self.assertTrue(full["downgradeBaselineNormalised"])
        probe_only = upgrade.summary_fields(
            domain, SEED, EXPECTED, Path("/tmp/settings.json"), [],
            launched=False, launches=[], defaults_byte_identical=None,
            supplementary_probe_matches=True)
        self.assertFalse(probe_only["downgradeBaselineConverged"])
        self.assertFalse(probe_only["downgradeBaselineNormalised"])


# --------------------------------------------------------------------------
# Fix round 4, finding 2b: assert_layout_sizes must check CORRECTNESS (expected
# values DERIVED from the app's own layout rules + seed), not just a valid range.
# The old [0, SIZE_UPPER_BOUND] check accepted all-zero sizes, a CPU override
# changed 140->900, and hidden graphs with nonzero sizes.
# --------------------------------------------------------------------------

class SizeCorrectnessTests(unittest.TestCase):
    def _document(self, overrides=None, drop=()):
        _, base = upgrade.parse_expected(EXPECTED)
        return app_document_with_all_sizes(base, overrides=overrides, drop=drop)

    def _observed_document(self):
        # The REAL Release-run values (measured from the launched 0.2.3 app):
        # width 157.45454545454547 (11 displayed), height 672 (10 displayed),
        # 140 (cpu), and 0 (the 2 hidden graphs). Used ONLY as test INPUT that
        # must be ACCEPTED -- the oracle is DERIVED, never copied from these.
        _, base = upgrade.parse_expected(EXPECTED)
        obj = json.loads(base)
        hidden = {"gpu", "weather"}
        for gid in upgrade.GRAPH_IDS:
            for dim in ("width", "height"):
                key = f"graphs.{gid}.size_{dim}"
                if gid in hidden:
                    obj["settings"][key] = 0
                elif gid == "cpu" and dim == "height":
                    obj["settings"][key] = 140
                elif dim == "width":
                    obj["settings"][key] = 157.45454545454547
                else:
                    obj["settings"][key] = 672
        return json.dumps(obj)

    def test_real_run_values_pass(self):
        self.assertEqual(len(upgrade.assert_layout_sizes(self._observed_document())), 26)

    def test_all_zero_sizes_fail(self):
        # All 26 = 0 are finite in-range numbers: the OLD range check accepted
        # them. The correctness check must FAIL (a WRONG, not CORRUPTED, value).
        zeros = {k: 0 for k in upgrade.LAYOUT_SIZE_KEYS}
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(self._document(overrides=zeros))
        self.assertIn("wrong", str(caught.exception).lower())

    def test_cpu_override_140_to_900_fails(self):
        # 900 is BELOW SIZE_UPPER_BOUND (964), so the range check passes; only
        # the CORRECTNESS check can reject a corrupted CPU height override.
        self.assertLess(900, upgrade.SIZE_UPPER_BOUND)
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(self._document(
                overrides={"graphs.cpu.size_height": 900}))
        self.assertIn("wrong", str(caught.exception).lower())

    def test_hidden_graph_nonzero_size_fails(self):
        # Hidden graphs are EXPECTED to be exactly 0 (windowChanged applies
        # NSSize.zero; XRGModule.dimension/saveSize store 0). Even a small
        # 0.4 pt nonzero hidden size must FAIL (tight tolerance).
        for key in ("graphs.gpu.size_width", "graphs.gpu.size_height",
                    "graphs.weather.size_width", "graphs.weather.size_height"):
            for bad in (157.45454545454547, 672, 0.4):
                with self.subTest(key=key, bad=bad):
                    with self.assertRaises(RuntimeError) as caught:
                        upgrade.assert_layout_sizes(self._document(
                            overrides={key: bad}))
                    self.assertIn("wrong", str(caught.exception).lower())

    def test_derivation_matches_the_app_layout_rules(self):
        d = upgrade.layout_size_derivation()
        self.assertEqual(d["displayedCount"], 11)
        self.assertEqual(d["contentWidth"], 1767)
        self.assertEqual(d["contentHeight"], 672)
        self.assertAlmostEqual(d["unit"], 1732 / 11, places=9)
        self.assertEqual(d["cpuHeight"], 140)
        expected = upgrade.expected_layout_sizes()
        self.assertEqual(set(expected), set(upgrade.LAYOUT_SIZE_KEYS))
        self.assertAlmostEqual(expected["graphs.cpu.size_width"][0], 1732 / 11, places=9)
        self.assertEqual(expected["graphs.cpu.size_height"][0], 140)
        self.assertEqual(expected["graphs.memory.size_height"][0], 672)
        self.assertEqual(expected["graphs.gpu.size_width"][0], 0.0)
        self.assertEqual(expected["graphs.weather.size_height"][0], 0.0)

    def test_expected_values_are_computed_not_hardcoded(self):
        # A wider controlled launch window yields a larger shared width: the
        # expectation is DERIVED from the geometry, not a fixed observed value.
        wider = dict(upgrade.CONTROLLED_GEOMETRY)
        wider["expandedWindowWidth"] += 110
        self.assertGreater(upgrade.layout_size_derivation(wider)["unit"],
                           upgrade.layout_size_derivation()["unit"])

    def test_tolerances_are_positive_and_tight(self):
        self.assertGreater(upgrade.SIZE_TOLERANCE, 0)
        self.assertLessEqual(upgrade.SIZE_TOLERANCE, 1.0)
        self.assertLess(upgrade.HIDDEN_SIZE_TOLERANCE, 1e-3)

    def test_load_app_document_rejects_a_wrong_size(self):
        # The full gate (load_app_document -> assert_layout_sizes) must reject a
        # wrong-but-in-range value before any oracle comparison.
        _, base = upgrade.parse_expected(EXPECTED)
        tmp = Path(tempfile.mkdtemp(prefix="xrg-upgrade-wrongsize-"))
        try:
            path = tmp / "settings.json"
            path.write_text(self._document(
                overrides={"graphs.cpu.size_height": 900}))
            with self.assertRaises(RuntimeError) as caught:
                upgrade.load_app_document(path, [], [], base)
            self.assertIn("wrong", str(caught.exception).lower())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_geometry_constants_match_the_seed(self):
        # Every seed-derived input of the derivation is pinned to the ACTUAL
        # seed plist, so the oracle cannot drift from the controlled launch.
        seed = plistlib.loads(SEED.read_bytes())
        g = upgrade.CONTROLLED_GEOMETRY
        self.assertEqual(g["windowWidth"], seed["windowWidth"])
        self.assertEqual(g["windowHeight"], seed["windowHeight"])
        self.assertEqual(g["borderWidth"], seed["borderWidth"])
        self.assertEqual(g["orientation"], "horizontal")
        self.assertIs(seed["graphOrientationVertical"], False)
        self.assertIs(seed["showGPUGraph"], False)
        self.assertIs(seed["showWeatherGraph"], False)
        self.assertEqual(set(g["hiddenGraphs"]), {"gpu", "weather"})
        pres = json.loads(seed["graphPresentationV1"])
        self.assertEqual(g["heightOverrides"]["cpu"], pres["overrides"]["cpu"]["height"])
        font = plistlib.loads(seed["graphFont"])
        self.assertEqual(font["$objects"][1]["NSSize"], 11.0)
        self.assertEqual(font["$objects"][2], "Menlo-Regular")


# --------------------------------------------------------------------------
# Fix round 5, finding 2b: expected sizes must be DERIVED FROM INDEPENDENTLY
# MEASURED geometry (the launched app's window frame + the seed font metric),
# NOT from this host's hardcoded expandedWindowWidth=1779 / titleHeight=13,
# and NOT from the 26 size values under validation. RED: the pre-round-5 script
# has no measured_geometry / measurement helpers and its only geometry is the
# host-specific CONTROLLED_GEOMETRY.
# --------------------------------------------------------------------------

class MeasuredGeometryHelpersTests(unittest.TestCase):
    @staticmethod
    def _domain_bytes(frames, sizes=None):
        dom = dict(frames)
        if sizes:
            dom.update(sizes)
        return plistlib.dumps(dom, fmt=plistlib.FMT_BINARY)

    def test_parse_frame_rect(self):
        self.assertEqual(upgrade.parse_frame_rect("{{216, 136}, {280, 684}}"), (280.0, 684.0))
        self.assertEqual(upgrade.parse_frame_rect("{{152,54},{1779,684}}"), (1779.0, 684.0))
        self.assertEqual(upgrade.parse_frame_rect("{{0,0},{1779.5,684.5}}"), (1779.5, 684.5))
        self.assertIsNone(upgrade.parse_frame_rect("not a rect"))
        self.assertIsNone(upgrade.parse_frame_rect(123))

    def test_window_frame_from_domain_reads_app_written_frame_keys(self):
        # The frame comes from AppKit window-frame keys the app writes (NOT one
        # of the 26 graphs.*.size_* keys); the widest (expanded) frame wins.
        raw = self._domain_bytes({
            "unminimizedFrame": "{{152,54},{1779,684}}",
            "NSWindow Frame XRG": "{{216,136},{280,684}}",
        })
        w, h, key = upgrade.window_frame_from_domain(raw)
        self.assertEqual((w, h), (1779.0, 684.0))
        self.assertIn(key, ("unminimizedFrame", "NSWindow Frame XRG"))

    def test_window_frame_measurement_is_independent_of_the_26_size_keys(self):
        # A domain holding ONLY the 26 size-like keys (and NO app-written window
        # frame key) yields NO measurement: the frame MUST NOT be inferred from
        # the very sizes under validation ("do not infer the inputs from the 26
        # sizes being validated").
        only_sizes = {k: 157.45454545454547 for k in upgrade.LAYOUT_SIZE_KEYS}
        only_sizes.update({"XRGModule_CPU_width": 157.45, "XRGModule_CPU_height": 140})
        self.assertIsNone(upgrade.window_frame_from_domain(
            self._domain_bytes({}, sizes=only_sizes)))

    def test_window_frame_from_domain_absent_when_no_frame_key(self):
        self.assertIsNone(upgrade.window_frame_from_domain(
            self._domain_bytes({}, sizes={"windowWidth": 280})))

    def test_measured_geometry_uses_only_the_measured_inputs(self):
        g = upgrade.measured_geometry(2000.0, 900.0, 19.0)
        self.assertEqual(g["expandedWindowWidth"], 2000.0)
        self.assertEqual(g["windowHeight"], 900.0)
        self.assertEqual(g["textRectHeight"], 19.0)
        # Portable seed/code constants are preserved, not host-measured.
        self.assertEqual(g["borderWidth"], 6)
        self.assertEqual(g["moduleSeparatorWidth"], 2)
        self.assertEqual(g["minHeight"], 30)

    def test_measured_geometry_rejects_nonpositive_or_nonfinite_inputs(self):
        for bad in (0, -1, float("nan"), float("inf"), "x", None):
            with self.subTest(bad=bad):
                for args in ((bad, 684, 13), (1779, bad, 13), (1779, 684, bad)):
                    with self.assertRaises(RuntimeError):
                        upgrade.measured_geometry(*args)

    def test_font_descriptor_from_seed(self):
        self.assertEqual(upgrade.font_descriptor_from_seed(SEED), ("Menlo-Regular", 11.0))

    def test_size_upper_bound_scales_with_the_measured_frame(self):
        # A tall/wide alternate-host window must not spuriously fail the
        # secondary range gate: the bound scales with the MEASURED frame.
        g = upgrade.measured_geometry(2500.0, 1200.0, 13.0)
        self.assertGreaterEqual(upgrade.size_upper_bound(g), 2500.0)

    def test_frames_consistent(self):
        self.assertTrue(upgrade.frames_consistent((1779, 684), (1779, 684)))
        self.assertTrue(upgrade.frames_consistent((1779, 684), (3558, 1368)))  # Retina 2x
        self.assertFalse(upgrade.frames_consistent((1779, 684), (500, 300)))
        self.assertIsNone(upgrade.frames_consistent((1779, 684), None))


class MeasuredGeometrySizeTests(unittest.TestCase):
    """The REQUIRED finding-2b cases, all against an ALTERNATE-HOST geometry
    (a different MEASURED frame width AND title height)."""

    @classmethod
    def setUpClass(cls):
        cls.alt = upgrade.measured_geometry(2000.0, 900.0, 19.0)
        cls.ref = upgrade.CONTROLLED_GEOMETRY

    def _base(self):
        _, base = upgrade.parse_expected(EXPECTED)
        return base

    def _document_for(self, geometry, overrides=None, drop=()):
        return app_document_with_all_sizes(self._base(), overrides=overrides,
                                           drop=drop, geometry=geometry)

    def test_alternate_host_geometry_passes(self):
        # A DIFFERENT measured frame width (2000 vs 1779) and title height
        # (19 vs 13) with CORRECTLY DERIVED sizes PASSES: the oracle is derived
        # from the measured inputs, not from this host's hardcoded values.
        self.assertEqual(len(upgrade.assert_layout_sizes(
            self._document_for(self.alt), geometry=self.alt)), 26)
        d = upgrade.layout_size_derivation(self.alt)
        self.assertAlmostEqual(d["unit"], (2000 - 12 - 19 - 22) / 11, places=9)
        self.assertEqual(d["contentHeight"], 900 - 12)

    def test_all_zero_sizes_fail_with_measured_geometry(self):
        zeros = {k: 0 for k in upgrade.LAYOUT_SIZE_KEYS}
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(self._document_for(self.alt, overrides=zeros),
                                        geometry=self.alt)
        self.assertIn("wrong", str(caught.exception).lower())

    def test_cpu_override_140_to_900_fails_with_measured_geometry(self):
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(self._document_for(
                self.alt, overrides={"graphs.cpu.size_height": 900}), geometry=self.alt)
        self.assertIn("wrong", str(caught.exception).lower())

    def test_hidden_nonzero_size_fails_with_measured_geometry(self):
        for key in ("graphs.gpu.size_width", "graphs.weather.size_height"):
            with self.subTest(key=key):
                with self.assertRaises(RuntimeError) as caught:
                    upgrade.assert_layout_sizes(self._document_for(
                        self.alt, overrides={key: 0.4}), geometry=self.alt)
                self.assertIn("wrong", str(caught.exception).lower())

    def test_sizes_inconsistent_with_measured_frame_fail(self):
        # Sizes correct for ONE measured frame (1779) MUST FAIL when validated
        # against a DIFFERENT measured frame (2000): expected sizes are a
        # function of the measured frame, so a document that does not match the
        # launched app's ACTUAL frame is rejected (not silently accepted).
        doc_for_ref = self._document_for(self.ref)
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(doc_for_ref, geometry=self.alt)
        self.assertIn("wrong", str(caught.exception).lower())

    def test_expected_width_depends_on_measured_frame_and_title_height(self):
        g1 = upgrade.measured_geometry(1779.0, 684.0, 13.0)
        wider = upgrade.measured_geometry(2000.0, 684.0, 13.0)
        taller_title = upgrade.measured_geometry(1779.0, 684.0, 19.0)
        self.assertGreater(upgrade.layout_size_derivation(wider)["unit"],
                           upgrade.layout_size_derivation(g1)["unit"])
        self.assertLess(upgrade.layout_size_derivation(taller_title)["unit"],
                        upgrade.layout_size_derivation(g1)["unit"])

    def test_load_app_document_threads_the_measured_geometry(self):
        # The PRODUCTION gate (load_app_document -> assert_layout_sizes) uses
        # the SUPPLIED measured geometry, never the host-specific default.
        _, base = upgrade.parse_expected(EXPECTED)
        tmp = Path(tempfile.mkdtemp(prefix="xrg-upgrade-measured-"))
        try:
            path = tmp / "settings.json"
            path.write_text(self._document_for(self.alt))
            self.assertTrue(upgrade.load_app_document(
                path, [], [], base, geometry=self.alt))
            with self.assertRaises(RuntimeError) as caught:
                upgrade.load_app_document(path, [], [], base, geometry=self.ref)
            self.assertIn("wrong", str(caught.exception).lower())
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# --------------------------------------------------------------------------
# R9 follow-up: the check must derive expected sizes for BOTH orientations
# from XRGModuleManager.windowChanged, using the orientation read from the
# seeded/normalised domain (NOT hardcoded horizontal, NOT the 26 size keys).
# --------------------------------------------------------------------------

class OrientationFromDomainTests(unittest.TestCase):
    @staticmethod
    def _domain(value):
        return plistlib.dumps({"graphOrientationVertical": value},
                              fmt=plistlib.FMT_BINARY)

    def test_orientation_is_read_from_the_domain(self):
        self.assertEqual(upgrade.orientation_from_domain(self._domain(True)), "vertical")
        self.assertEqual(upgrade.orientation_from_domain(self._domain(False)), "horizontal")
        # A string-typed flag, exactly the form 0.2.2's bool reader accepts
        # (R9-1), must be honoured too.
        self.assertEqual(upgrade.orientation_from_domain(self._domain("YES")), "vertical")
        self.assertEqual(upgrade.orientation_from_domain(self._domain("NO")), "horizontal")
        self.assertEqual(upgrade.orientation_from_domain(self._domain("1")), "vertical")
        self.assertEqual(upgrade.orientation_from_domain(self._domain("0")), "horizontal")
        # Absent key: registered default is YES / vertical
        # (XRGWindowPreferences.swift:41), not horizontal.
        self.assertEqual(upgrade.orientation_from_domain(plistlib.dumps({})), "vertical")
        # Custom helper, not NSString boolValue and not Python float().
        # "Yonder" is not a helper spelling, so it falls back to vertical.
        # "0 1" is not a helper spelling either (float("0 1") would fail or
        # a prefix parse would be false); the registered fallback is vertical.
        self.assertEqual(upgrade.orientation_from_domain(self._domain("Yonder")), "vertical")
        self.assertEqual(upgrade.orientation_from_domain(self._domain("0 1")), "vertical")
        self.assertEqual(upgrade.orientation_from_domain(self._domain("0.5junk")), "vertical")

    def test_orientation_is_independent_of_the_26_size_keys(self):
        dom = {k: 157.45454545454547 for k in upgrade.LAYOUT_SIZE_KEYS}
        dom["graphOrientationVertical"] = True
        self.assertEqual(upgrade.orientation_from_domain(plistlib.dumps(dom)), "vertical")

    def test_collect_measured_geometry_threads_vertical_orientation(self):
        # A VERTICAL expanded frame is TALL and NARROW, while the collapsed
        # frame is wider: the dedicated unminimizedFrame restore rectangle must
        # win, and the orientation must be read from that same domain.
        dom = {
            "unminimizedFrame": "{{0,0},{139,849}}",
            "NSWindow Frame XRG": "{{216,136},{280,684}}",
            "graphOrientationVertical": True,
        }
        exported = plistlib.dumps(dom, fmt=plistlib.FMT_BINARY)
        results = Path(tempfile.mkdtemp(prefix="xrg-orient-"))
        try:
            geom, prov = upgrade.collect_measured_geometry(
                "com.sdelavega.xrg.upgradecheck.fake", SEED, results,
                export=lambda _d: exported,
                measure_font=lambda _name, _size, _results: 13.0)
            self.assertEqual(geom["orientation"], "vertical")
            self.assertEqual(prov["orientation"], "vertical")
            self.assertEqual(geom["expandedWindowWidth"], 139.0)
            self.assertEqual(geom["windowHeight"], 849.0)
        finally:
            shutil.rmtree(results, ignore_errors=True)


class VerticalLayoutTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A VERTICAL measured frame: tall and narrow (XRGModuleManager defaults
        # to graphOrientationVertical = true). 139x849 frame, titleHeight 13.
        cls.vert = upgrade.measured_geometry(139.0, 849.0, 13.0, orientation="vertical")
        cls.vert2 = upgrade.measured_geometry(160.0, 1000.0, 13.0, orientation="vertical")
        cls.horiz = upgrade.CONTROLLED_GEOMETRY

    def _base(self):
        _, base = upgrade.parse_expected(EXPECTED)
        return base

    def _document_for(self, geometry, overrides=None, drop=()):
        return app_document_with_all_sizes(self._base(), overrides=overrides,
                                           drop=drop, geometry=geometry)

    def test_geometry_records_vertical_orientation(self):
        self.assertEqual(self.vert["orientation"], "vertical")
        self.assertEqual(self.horiz["orientation"], "horizontal")

    def test_vertical_derivation_matches_windowChanged(self):
        d = upgrade.layout_size_derivation(self.vert)
        self.assertEqual(d["orientation"], "vertical")
        # windowChanged vertical branch: every displayed graph spans the FULL
        # content width, not the shared horizontal unit.
        self.assertEqual(d["verticalWidth"], 139.0 - 12)
        available = (849.0 - 12) - 13.0 - 2 * 11  # contentHeight - titleHeight - separator*count
        self.assertAlmostEqual(d["available"], available, places=9)
        self.assertAlmostEqual(d["verticalHeights"]["cpu"], 140.0, places=9)
        self.assertAlmostEqual(d["verticalHeights"]["ai"],
                               (available - 140.0) / 10, places=9)
        expected = upgrade.expected_layout_sizes(self.vert)
        self.assertEqual(set(expected), set(upgrade.LAYOUT_SIZE_KEYS))
        self.assertEqual(expected["graphs.ai.size_width"][0], 139.0 - 12)
        self.assertEqual(expected["graphs.cpu.size_height"][0], 140.0)
        self.assertEqual(expected["graphs.gpu.size_width"][0], 0.0)
        self.assertEqual(expected["graphs.weather.size_height"][0], 0.0)

    def test_vertical_correct_sizes_pass(self):
        self.assertEqual(len(upgrade.assert_layout_sizes(
            self._document_for(self.vert), geometry=self.vert)), 26)

    def test_vertical_all_zero_sizes_fail(self):
        zeros = {k: 0 for k in upgrade.LAYOUT_SIZE_KEYS}
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(self._document_for(self.vert, overrides=zeros),
                                        geometry=self.vert)
        self.assertIn("wrong", str(caught.exception).lower())

    def test_vertical_cpu_override_140_to_900_fails(self):
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(self._document_for(
                self.vert, overrides={"graphs.cpu.size_height": 900}), geometry=self.vert)
        self.assertIn("wrong", str(caught.exception).lower())

    def test_vertical_hidden_nonzero_size_fails(self):
        for key in ("graphs.gpu.size_width", "graphs.weather.size_height"):
            with self.subTest(key=key):
                with self.assertRaises(RuntimeError) as caught:
                    upgrade.assert_layout_sizes(self._document_for(
                        self.vert, overrides={key: 0.4}), geometry=self.vert)
                self.assertIn("wrong", str(caught.exception).lower())

    def test_vertical_sizes_inconsistent_with_measured_frame_fail(self):
        # Sizes correct for ONE vertical measured frame MUST FAIL when
        # validated against a DIFFERENT measured frame.
        doc = self._document_for(self.vert)
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(doc, geometry=self.vert2)
        self.assertIn("wrong", str(caught.exception).lower())

    def test_vertical_and_horizontal_expected_sizes_differ(self):
        h = upgrade.expected_layout_sizes(self.horiz)
        v = upgrade.expected_layout_sizes(self.vert)
        self.assertNotEqual(h["graphs.ai.size_width"][0], v["graphs.ai.size_width"][0])
        self.assertNotEqual(h["graphs.ai.size_height"][0], v["graphs.ai.size_height"][0])

    def test_preferred_heights_explain_a_139x849_vertical_gap(self):
        """Coordinator case at 198bd44: 139x849 vertical, unit 127, content
        height 837, only a CPU override of 140 and gpu+weather hidden, expects
        graphs.ai.size_height 66.2. The app wrote 80.8. minHeight is the shared
        line height, so the gap is other preferred heights and the displayed
        set. A layout with several preferred heights (and one more hidden
        graph) expects 80.8; a document still carrying the naive 66.2 fails.
        """
        naive = upgrade.measured_geometry(139.0, 849.0, 13.0, orientation="vertical")
        naive_ai = upgrade.expected_layout_sizes(naive)["graphs.ai.size_height"][0]
        self.assertAlmostEqual(naive_ai, 66.2, places=9)

        displayed = tuple(gid for gid in upgrade.GRAPH_IDS
                          if gid not in ("gpu", "weather", "stock"))
        geom = dict(naive)
        geom["displayedGraphs"] = displayed
        geom["hiddenGraphs"] = ("gpu", "weather", "stock")
        geom["heightOverrides"] = {
            "cpu": 140, "memory": 64, "network": 64, "disk": 64, "battery": 68,
        }
        expected = upgrade.expected_layout_sizes(geom)
        self.assertAlmostEqual(expected["graphs.ai.size_height"][0], 80.8, places=9)
        self.assertAlmostEqual(expected["graphs.cpu.size_height"][0], 140.0, places=9)
        self.assertEqual(expected["graphs.gpu.size_height"][0], 0.0)
        self.assertEqual(expected["graphs.stock.size_width"][0], 0.0)
        self.assertEqual(expected["graphs.ai.size_width"][0], 127.0)

        # The naive 66.2 document is wrong once preferred heights are modeled.
        naive_doc = self._document_for(naive)
        with self.assertRaises(RuntimeError) as caught:
            upgrade.assert_layout_sizes(naive_doc, geometry=geom)
        self.assertIn("wrong", str(caught.exception).lower())

        good = self._document_for(geom)
        self.assertEqual(len(upgrade.assert_layout_sizes(good, geometry=geom)), 26)


if __name__ == "__main__":
    unittest.main()
