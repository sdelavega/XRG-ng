#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Prove settings survive 0.2.2 -> 0.2.3 -> 0.2.2 on macOS.

The check seeds a *disposable* NSUserDefaults domain (a renamed bundle id,
``com.sdelavega.xrg.upgradecheck.<uuid>``) from a 0.2.2 defaults export.

THE 0.2.3 DOCUMENT IS WRITTEN BY THE LAUNCHED APP ITSELF (Task 13 fix round 2,
finding 1 / ruling R25). The app has ONE narrowly gated startup path: only a
non-production bundle whose process sets
``XRG_UPGRADE_CHECK_SOURCE_DOMAIN=<disposable domain>`` runs the real
document-backed first-launch migration, over that disposable domain, into the
R11 private store ``~/Library/Application Support/XRG-ng-Private/<id>/``.
So the script starts with no document, seeds the domain, launches the supplied
0.2.3 app WITH that env var, quits it, and validates the document THE APP wrote
against the expected oracle. The framework driver and the shared-core probe are
now ONLY supplementary validation (the driver uses the supplied app's OWN
framework -- no this-checkout fallback). A negative control (--withhold-upgrade-env,
or startup migration disabled) writes NO document and fails while the store
symbols remain.

ORDER: seed (no document) -> launch 0.2.3 (env var) -> validate its document ->
normalise (run 0.2.2 baseline ONCE) -> capture the downgrade reference ->
relaunch 0.2.2 (downgrade) -> compare its defaults byte-for-byte. The baseline
run settles the mapped keys 0.2.2 rewrites on every launch (the 26 graph
width/height keys, docs/settings-inventory.md §339-364), so they are INCLUDED
in the comparison rather than excluded. A probe-only/--skip-launch run NEVER
prints SETTINGS_UPGRADE_MACOS_OK and NEVER claims a relaunch.

POST-DOWNGRADE EXCLUSIONS (finding 2) are ONLY genuinely volatile AppKit window
geometry, each listed by exact key / one prefix whose every key is volatile:
``NSWindow Frame `` (AppKit-autosaved window frames) and ``unminimizedFrame``
(the graph-window restore rectangle). No mapped setting is excluded.

SAFETY (absolute): the real production defaults domain ``com.sdelavega.xrg``,
its ~/Library/Preferences plist, and the real ~/Library/Application
Support/XRG-ng/settings.json are NEVER read, written, exported, deleted or
launched against. Protected --seed/--expected inputs that resolve (realpath,
symlinks followed) to those files are refused before anything is read; a
coordinator-created export copy in scratch is accepted. Every target id is a
generated UUID in a private namespace. Cleanup attempts every step, checks
return codes, verifies the disposable domain/plist/private folder are gone and
reports accumulated failures; the OK line is printed only after cleanup
succeeded (non-zero exit otherwise). Catchable termination signals run all
``finally`` blocks; launched process groups are terminated, reaped and CONFIRMED
gone in a finally BEFORE their storage is deleted (finding 3).

Prints SETTINGS_UPGRADE_MACOS_OK on full success.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

sys.dont_write_bytecode = True

PRODUCTION_ID = "com.sdelavega.xrg"
UPGRADE_PREFIX = "com.sdelavega.xrg.upgradecheck."
# The app's gated startup path reads exactly this variable (R25); its value is
# the disposable source domain. Withholding it is the negative control.
UPGRADE_ENV_KEY = "XRG_UPGRADE_CHECK_SOURCE_DOMAIN"
OK_LINE = "SETTINGS_UPGRADE_MACOS_OK"
PROBE_ONLY_LINE = "SETTINGS_UPGRADE_MACOS_PROBE_ONLY"
TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent
FIXTURES = REPO / "Shared/Tests/Fixtures/settings"
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")
# Termination signals that must run Python's ``finally`` blocks (and therefore
# a launch-level process-group reap + verified cleanup) before the process dies.
SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)

# --------------------------------------------------------------------------
# Post-downgrade exclusions (finding 2): ONLY genuinely volatile AppKit window
# geometry. Every mapped setting (including the 26 XRGModule_* graph width/height
# keys, docs/settings-inventory.md §339-364) is COMPARED. These are not settings:
#   - "NSWindow Frame " prefix: EVERY key under this prefix is an AppKit-
#     autosaved window frame, rewritten with live window geometry each launch
#     (dynamic autosave name) -- genuinely volatile AppKit state, not a setting.
#   - "unminimizedFrame": the graph window's AppKit minimize/restore rectangle,
#     rewritten on every launch -- genuinely volatile AppKit state, not a setting.
# No other prefix or key is excluded. Mapped keys that a launch rewrites are
# NORMALISED by running the 0.2.2 baseline once before capturing the reference.
# --------------------------------------------------------------------------
VOLATILE_PREFIXES = ("NSWindow Frame ",)
VOLATILE_KEYS = frozenset({"unminimizedFrame"})

# The 26 graphs.*.size_width/height settings the launched 0.2.3 app recomputes
# on layout and writes into settings.json on every launch (XRGModule resize
# feedback, docs/settings-inventory.md §339-364). They are runtime window
# geometry, not the seeded 0.2.2 values, so they are projected out ONLY when
# comparing the APP's document with the pure-migration oracle. They ARE compared
# (included, after normalisation) in the post-downgrade domain comparison.
LAYOUT_SIZE_KEY = re.compile(r"^graphs\..*\.size_(width|height)$")


class DocumentMismatch(RuntimeError):
    """The 0.2.3 document differs from the pinned oracle (ruling R21).

    Never resolve this by editing the fixture: a legitimate difference since
    Task 12 (Stocks mapped in the shared core) must be reported, not papered
    over. The main() error path prints this message verbatim.
    """


class Interrupted(Exception):
    """A catchable termination signal; raised so every ``finally`` runs."""

    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"SETTINGS_UPGRADE_MACOS: interrupted by signal {signum}")


# --------------------------------------------------------------------------
# Pure, side-effect-free helpers (unit tested).
# --------------------------------------------------------------------------

def make_token():
    return str(uuid.uuid4())


def domain_for(token):
    return UPGRADE_PREFIX + token


def assert_safe_ids(ids):
    """Refuse to run if any target bundle id could reach the production domain."""
    if not ids:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: no target bundle ids")
    for ident in ids:
        if not isinstance(ident, str) or ident == PRODUCTION_ID or not ident.startswith(UPGRADE_PREFIX):
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: refusing unsafe target id {ident!r}")
        suffix = ident[len(UPGRADE_PREFIX):]
        try:
            if str(uuid.UUID(suffix)) != suffix:
                raise ValueError
        except ValueError as error:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: target id has no generated UUID: {ident!r}") from error


def private_paths(home, domain):
    """Everything a renamed bundle id can create in the user's Library.

    Only ever called for a private, generated UUID domain, so cleanup can never
    touch the production plist or the production settings store.
    """
    assert_safe_ids([domain])
    home = Path(home)
    library = home / "Library"
    paths = []
    for ident in {domain, domain.lower()}:
        paths.extend([
            library / "Preferences" / (ident + ".plist"),
            library / "Caches" / ident,
            library / "Saved Application State" / (ident + ".savedState"),
            library / "HTTPStorages" / ident,
            library / "Application Support" / "XRG-ng-Private" / ident,
        ])
    return paths


def protected_paths(home):
    """The two real production files no input may resolve to."""
    home = Path(home)
    return [
        home / "Library/Preferences/com.sdelavega.xrg.plist",
        home / "Library/Application Support/XRG-ng/settings.json",
    ]


def assert_safe_inputs(seed, expected, home):
    """Refuse protected --seed/--expected inputs BEFORE anything is read.

    ``os.path.realpath`` follows symlinks, so a scratch alias pointing at the
    production plist is refused too. A coordinator-created export copy in
    scratch has a different realpath and is accepted (ruling R9).
    """
    protected = {os.path.realpath(str(path)).lower() for path in protected_paths(home)}
    for label, path in (("--seed", seed), ("--expected", expected)):
        resolved = os.path.realpath(str(path)).lower()
        if resolved in protected:
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: refusing protected {label} input: {path} "
                f"resolves to a production preferences/settings file")


def app_document_path(home, domain):
    """The app's R11 document store for a renamed (non-production) bundle id."""
    assert_safe_ids([domain])
    return (Path(home) / "Library/Application Support/XRG-ng-Private" / domain / "settings.json")


def assert_app_document_backend(symbols):
    """Tie the check to the supplied app binary (finding 1, negative control).

    A supplied app whose main executable does not contain the document store
    must not be able to pass. The negative control keeps these symbols but
    disables startup migration, so it fails later for lack of a document.
    """
    if "XRGSettingsStore" not in symbols or "XRGSettingsMigration" not in symbols:
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: the supplied 0.2.3 app has no XRGSettingsStore "
            "document backend / XRGSettingsMigration; an app that never migrates must fail")


def upgrade_check_env(domain, enabled=True):
    """The env var gating the app's startup migration (R25).

    Withholding it (negative control) leaves a renamed bundle on the legacy
    path: it writes NO document, so the check fails while the app still HAS the
    store symbols (the nm gate still passes).
    """
    assert_safe_ids([domain])
    return {UPGRADE_ENV_KEY: domain} if enabled else {}


def default_seed_path(root=REPO):
    return Path(root) / "Shared/Tests/Fixtures/settings/macos-0.2.2-defaults.plist"


def default_expected_path(root=REPO):
    return Path(root) / "Shared/Tests/Fixtures/settings/macos-0.2.2-expected.json"


def parse_expected(path):
    data = json.loads(Path(path).read_text())
    if not isinstance(data, dict) or not isinstance(data.get("diagnostics"), list) \
            or not isinstance(data.get("document"), str):
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: invalid expected-document file: {path}")
    return data["diagnostics"], data["document"]


def _normalise_diagnostics(diagnostics):
    result = []
    for item in diagnostics or []:
        if isinstance(item, dict):
            result.append((str(item.get("id") or "document"), str(item.get("problem") or "")))
        else:
            result.append((str(item), ""))
    return sorted(result)


def project_layout_sizes(document_text):
    """Canonical document bytes with the 26 runtime layout size settings removed.

    The LAUNCHED 0.2.3 app recomputes graph geometry on layout and writes the
    ``graphs.*.size_width/height`` settings into settings.json on EVERY launch
    (XRGModule resize feedback, docs/settings-inventory.md §339-364). Those are
    live window geometry, not the seeded 0.2.2 values, so a byte-exact equality
    with the pure-migration oracle is impossible. They are projected out ONLY
    here so every OTHER (migrated) setting can be validated byte-for-byte; the
    26 size keys are still compared, included, after normalisation in the
    post-downgrade domain comparison (finding 2).
    """
    obj = json.loads(document_text)
    if not isinstance(obj, dict) or not isinstance(obj.get("settings"), dict):
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: the app document is not a settings document")
    canonical = dict(obj)
    canonical["settings"] = {k: v for k, v in obj["settings"].items()
                             if not LAYOUT_SIZE_KEY.match(k)}
    return json.dumps(canonical, sort_keys=True, separators=(",", ":"))


def compare_documents(expected_diagnostics, expected_document, actual_diagnostics, actual_document):
    """Byte-exact comparison of a PURE migration with the Task 4 oracle.

    Used for the supplementary framework driver / shared-core probe, which
    reproduce the pure migration (no layout). The LAUNCHED APP's document uses
    ``compare_app_document`` (layout-size projection) instead.
    """
    if _normalise_diagnostics(actual_diagnostics) != _normalise_diagnostics(expected_diagnostics):
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: migration diagnostics differ from the "
            "expected fixture; report this instead of editing the fixture")
    if actual_document != expected_document:
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: the 0.2.3 document differs from "
            "macos-0.2.2-expected.json. A catalog/migration change since Task 4 "
            "(e.g. Stocks mapped in the shared core, ruling R21) may be legitimate: "
            "STOP and report it rather than editing the fixture to pass")


def compare_app_document(expected_diagnostics, expected_document, actual_diagnostics, app_document):
    """Compare the document the LAUNCHED APP wrote with the pinned oracle.

    All migrated (non-layout) settings must match byte-for-byte; the 26 runtime
    layout size settings are normalised out (see project_layout_sizes).
    """
    if _normalise_diagnostics(actual_diagnostics) != _normalise_diagnostics(expected_diagnostics):
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: migration diagnostics differ from the "
            "expected fixture; report this instead of editing the fixture")
    if project_layout_sizes(app_document) != project_layout_sizes(expected_document):
        raise DocumentMismatch(
            "SETTINGS_UPGRADE_MACOS_MISMATCH: the 0.2.3 document the app wrote "
            "differs from macos-0.2.2-expected.json. A catalog/migration change "
            "since Task 4 (e.g. Stocks mapped in the shared core, ruling R21) may "
            "be legitimate: STOP and report it rather than editing the fixture to pass")


def load_app_document(document_path, actual_diagnostics, expected_diagnostics, expected_document):
    """Read the document the LAUNCHED APP produced and compare it.

    If the app did not migrate -- no document at its R11 store, as when the env
    var is withheld -- this FAILS. The check never fabricates the document
    itself; this is the negative-control gate (finding 1).
    """
    document_path = Path(document_path)
    if not document_path.is_file():
        raise RuntimeError(
            f"SETTINGS_UPGRADE_MACOS: the launched 0.2.3 app produced no migrated "
            f"settings document at {document_path}; startup migration did not run -- "
            f"an app that does not migrate must fail")
    document = document_path.read_bytes().decode("utf-8")
    compare_app_document(expected_diagnostics, expected_document, actual_diagnostics, document)
    return document


def defaults_snapshot(exported_bytes):
    """Canonical bytes of a defaults domain's SETTINGS keys.

    ONLY the genuinely volatile AppKit window geometry in VOLATILE_KEYS /
    VOLATILE_PREFIXES is projected out (each documented with a reason above).
    Every other key -- all real settings, including the 26 XRGModule_* graph
    width/height keys -- is compared byte-for-byte. Mapped keys a launch
    rewrites are handled by the 0.2.2 baseline normalisation run, NOT exclusion.
    """
    domain = plistlib.loads(exported_bytes)
    stable = {key: value for key, value in domain.items()
              if key not in VOLATILE_KEYS and not key.startswith(VOLATILE_PREFIXES)}
    return plistlib.dumps(stable, fmt=plistlib.FMT_BINARY, sort_keys=True)


def success_marker(launched):
    """A probe-only run must never emit the OK line (finding 2)."""
    return OK_LINE if launched else PROBE_ONLY_LINE


def ok_after_cleanup(cleanup_failures, launched):
    """Emit success only after cleanup succeeded (finding 3 / fix-1 finding 4).

    A failed cleanup or an unreaped process group raises (non-zero exit) and
    NEVER returns the OK line.
    """
    if cleanup_failures:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: cleanup failed; " + "; ".join(cleanup_failures))
    return success_marker(launched)


def summary_fields(domain, seed, expected, document_path, diagnostics,
                   launched, launches, defaults_byte_identical,
                   supplementary_probe_matches, supplementary_driver_matches=False,
                   downgrade_normalised=False, layout_size_settings_normalised=False):
    """Only a full (launched) run may claim a 0.2.2 relaunch (finding 2)."""
    return {
        "domain": domain, "seed": str(seed), "expected": str(expected),
        "documentSource": "launched 0.2.3 app startup migration (R25 gated path, R11 private store)",
        "documentPath": str(document_path),
        "documentMatchesExpected": True, "diagnostics": diagnostics,
        "layoutSizeSettingsNormalised": layout_size_settings_normalised,
        "defaultsByteIdentical": defaults_byte_identical,
        "downgradeBaselineNormalised": downgrade_normalised,
        "supplementaryDriverMatches": supplementary_driver_matches,
        "supplementaryProbeMatches": supplementary_probe_matches,
        "launched": launched,
        "baselineRelaunched": launched,
        "launches": launches,
    }


# --------------------------------------------------------------------------
# Signals and process groups (fix-1 finding 3, fix-round-2 finding 3).
# --------------------------------------------------------------------------

def _signal_handler(signum, frame):
    # Restore the default handler so a repeated signal terminates immediately,
    # then raise so Python unwinds through every ``finally`` block.
    signal.signal(signum, signal.SIG_DFL)
    raise Interrupted(signum)


def install_signal_handlers(signals=SIGNALS):
    """Make catchable termination signals run cleanup instead of killing us."""
    installed = []
    for sig in signals:
        signal.signal(sig, _signal_handler)
        installed.append(sig)
    return installed


def _default_group_alive(pgid):
    """Whether any member of the given process group still exists."""
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # group exists; we simply cannot signal it


def terminate_and_reap(processes, killpg=None, group_alive=None, sleep=None):
    """Terminate (whole process group) and reap every launched app.

    Fix-round-2 finding 3:
      * signal the WHOLE group for EVERY process, even when the leader has
        already exited (a stubborn child can keep the group alive);
      * escalate to SIGKILL for a leader that will not exit;
      * ACCOUNT FOR SURVIVING GROUP MEMBERS: after the leaders are reaped,
        verify each group is CONFIRMED gone before storage is deleted;
      * FAIL LOUDLY (raise, no success) if any group cannot be confirmed gone or
        any signal/wait fails -- never swallow kill errors or a wait timeout.
    All side-effecting operations are injectable for unit tests.
    """
    killpg = killpg or os.killpg
    group_alive = group_alive or _default_group_alive
    sleep = sleep or time.sleep
    failures = []

    def signal_group(pgid, sig):
        try:
            killpg(pgid, sig)
        except ProcessLookupError:
            pass  # group already gone: nothing to signal
        except OSError as error:
            failures.append(f"could not signal process group {pgid} with signal {sig}: {error}")

    # 1. Signal the whole group for EVERY process. poll() is deliberately NOT
    #    consulted: a leader may have exited while children survive.
    for process in processes:
        signal_group(process.pid, signal.SIGTERM)

    # 2. Reap the leaders; escalate to SIGKILL for one that will not exit.
    for process in processes:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            signal_group(process.pid, signal.SIGKILL)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                failures.append(f"leader {process.pid} did not exit after SIGKILL")

    # 3. Account for surviving group members (children that outlived the
    #    leader) BEFORE storage is deleted. Escalate and re-check.
    for process in processes:
        if group_alive(process.pid):
            signal_group(process.pid, signal.SIGKILL)
            for _ in range(5):
                if not group_alive(process.pid):
                    break
                sleep(0.1)
            if group_alive(process.pid):
                failures.append(f"process group {process.pid} could not be confirmed gone")

    if failures:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: " + "; ".join(failures))


# --------------------------------------------------------------------------
# Cleanup (fix-1 finding 4): attempt every step, check return codes, verify gone.
# Returns a list of accumulated failure strings (empty on success).
# --------------------------------------------------------------------------

def cleanup(domain, home, run=None):
    assert_safe_ids([domain])  # safety gate BEFORE any subprocess
    run = run or subprocess.run
    failures = []
    try:
        deleted = run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL, timeout=10)
        if getattr(deleted, "returncode", 0) != 0:
            failures.append(f"defaults delete {domain} returned {getattr(deleted, 'returncode', 0)}")
    except (OSError, subprocess.SubprocessError) as error:
        failures.append(f"defaults delete {domain} raised: {error}")
    for path in private_paths(home, domain):
        try:
            if path.is_symlink() or path.is_file():
                path.unlink(missing_ok=True)
            elif path.is_dir():
                shutil.rmtree(path)
        except OSError as error:
            failures.append(f"could not remove {path}: {error}")
    for path in private_paths(home, domain):
        if path.exists() or path.is_symlink():
            failures.append(f"disposable path still present: {path}")
    # Verify the domain itself is gone (cfprefsd), not just its plist file.
    try:
        check = run(["/usr/bin/defaults", "read", domain], stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL, timeout=10)
        if getattr(check, "returncode", 1) == 0:
            failures.append(f"disposable defaults domain still registered: {domain}")
    except (OSError, subprocess.SubprocessError) as error:
        failures.append(f"could not verify domain removal: {error}")
    return failures


# --------------------------------------------------------------------------
# Supplementary shared-core probe (independent pure migration over the seed).
# --------------------------------------------------------------------------

PROBE_SWIFT = r'''import Foundation
import XRGSharedCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("settings-upgrade-probe: " + message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: PROBE seed.plist document.json diagnostics.json") }
let seedURL = URL(fileURLWithPath: args[1])
let documentURL = URL(fileURLWithPath: args[2])
let diagnosticsURL = URL(fileURLWithPath: args[3])
guard let plistData = try? Data(contentsOf: seedURL),
      let object = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
      let defaults = object as? [String: Any] else { fail("cannot read seed defaults plist") }
guard let catalog = try? XRGSettingsCatalog.load() else { fail("settings catalog is missing") }
let (document, diagnostics) = XRGSettingsMigration.fromMacDefaults(defaults, catalog: catalog)
do {
    try document.serialized().write(to: documentURL)
    let report: [[String: String]] = diagnostics.map { ["id": $0.id ?? "document", "problem": $0.problem] }
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try bytes.write(to: diagnosticsURL)
} catch { fail("cannot write probe results: \(error)") }
print("PROBE_OK")
'''


def _require_probe_products(products):
    if not (products / "XRGSharedCore.swiftmodule").exists() \
            or not (products / "libXRGSharedCore.dylib").is_file():
        raise RuntimeError(
            f"SETTINGS_UPGRADE_MACOS: --products lacks XRGSharedCore.swiftmodule / "
            f"libXRGSharedCore.dylib: {products}")


def build_probe_products(root, results, provided=None):
    if provided:
        products = Path(provided).resolve()
        _require_probe_products(products)
        return products
    scratch = results / "swift"
    base = ["swift", "build", "--package-path", str(root), "--scratch-path", str(scratch),
            "--product", "XRGSharedCore"]
    subprocess.run(base, check=True, stdout=subprocess.DEVNULL)
    bin_path = subprocess.check_output(base + ["--show-bin-path"], text=True).strip()
    products = Path(bin_path)
    _require_probe_products(products)
    return products


def compile_probe(products, results):
    source = results / "MigrationProbe.swift"
    source.write_text(PROBE_SWIFT)
    executable = results / "MigrationProbe"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-I", str(products),
                    "-L", str(products), "-lXRGSharedCore", str(source), "-o", str(executable)],
                   check=True)
    return executable


def run_probe(executable, products, seed, document_path, diagnostics_path):
    env = os.environ.copy()
    existing = env.get("DYLD_LIBRARY_PATH")
    env["DYLD_LIBRARY_PATH"] = str(products) + (os.pathsep + existing if existing else "")
    subprocess.run([str(executable), str(seed), str(document_path), str(diagnostics_path)],
                   check=True, env=env)


# --------------------------------------------------------------------------
# Supplementary framework driver: the SUPPLIED APP's OWN XRGCore.framework
# reproduces the pure migration over the seed. NO this-checkout fallback.
# --------------------------------------------------------------------------

APP_DRIVER_SWIFT = r'''// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
@testable import XRGCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("app-document-driver: " + message + "\n").utf8))
    exit(1)
}

@main
enum AppDocumentDriver {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 3 else { fail("usage: DRIVER seed.plist <output-document.json>") }
        let seedURL = URL(fileURLWithPath: args[1])
        let documentURL = URL(fileURLWithPath: args[2])
        guard let data = try? Data(contentsOf: seedURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let seed = object as? [String: Any] else { fail("cannot read seed defaults plist") }
        guard let catalog = try? XRGSettingsCatalog.load() else { fail("settings catalog is missing") }
        guard let defaults = UserDefaults(suiteName: "com.sdelavega.xrg.upgradecheck.driver") else {
            fail("no defaults suite")
        }
        // The supplied app's OWN document store, over a disposable suite,
        // writing the PURE migration of the seed into a scratch document.
        let store = XRGSettingsStore(fileURL: documentURL, defaults: defaults,
                                     catalog: catalog, legacyDomain: seed)
        if let problem = store.loadProblem { fail("store load problem: \(problem.problem)") }
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            fail("app store wrote no settings.json")
        }
        print("APP_DOCUMENT_OK " + documentURL.path)
    }
}
'''


def _framework_is_testable(framework):
    return framework.is_dir() and any(framework.rglob("*.private.swiftinterface"))


def resolve_driver_framework(app):
    """The supplied 0.2.3 app's OWN XRGCore.framework (built alongside it).

    Finding 1: NO this-checkout framework fallback. If the supplied app's
    framework cannot be used, the check FAILS.
    """
    products = app.resolve().parent
    framework = products / "XRGCore.framework"
    if not _framework_is_testable(framework):
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: the supplied 0.2.3 app has no testable "
            "XRGCore.framework alongside it; refusing any fallback (the supplied "
            "app's framework cannot be used)")
    return products


def compile_app_driver(products, results):
    source = results / "AppDocumentDriver.swift"
    source.write_text(APP_DRIVER_SWIFT)
    executable = results / "AppDocumentDriver"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
                    "-F", str(products), "-framework", "XRGCore", "-framework", "AppKit",
                    "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", str(products),
                    str(source), "-o", str(executable)], check=True)
    return executable


def run_app_driver(executable, products, seed, document_path):
    env = os.environ.copy()
    existing = env.get("DYLD_FRAMEWORK_PATH")
    env["DYLD_FRAMEWORK_PATH"] = str(products) + (os.pathsep + existing if existing else "")
    result = subprocess.run([str(executable), str(seed), str(document_path)],
                            check=True, capture_output=True, text=True, env=env)
    line = result.stdout.strip().splitlines()[-1] if result.stdout.strip() else ""
    if not line.startswith("APP_DOCUMENT_OK "):
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: app document driver did not report OK: {result.stdout!r}")
    return Path(line[len("APP_DOCUMENT_OK "):])


# --------------------------------------------------------------------------
# Renamed-copy launch pattern (mirrors Tools/packaged-smoke-macos.py).
# --------------------------------------------------------------------------

def make_renamed_copy(source, domain, destination):
    source = Path(source).resolve()
    info_path = source / "Contents/Info.plist"
    if not info_path.is_file() or not (source / "Contents/MacOS/XRG-ng").is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: not a built XRG-ng.app: {source}")
    assert_safe_ids([domain])
    shutil.copytree(source, destination, symlinks=True)
    info = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
    info["CFBundleIdentifier"] = domain
    (destination / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(destination)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    written = plistlib.loads((destination / "Contents/Info.plist").read_bytes())
    if written.get("CFBundleIdentifier") != domain:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: renamed copy lost its private bundle id")
    return destination


def launch_one(app, domain, results, timeout, processes, extra_env=None, phase="app"):
    """Bounded proof of life; a resident app still running at timeout is a pass.

    The process is left running here and terminated/reaped by launch-level
    finally (``launch_phase`` / ``main``), so an interruption cannot leave it.
    ``extra_env`` carries the gating variable for the 0.2.3 upgrade launch.
    """
    assert_safe_ids([domain])
    binary = app / "Contents/MacOS/XRG-ng"
    log = results / f"launch-{phase}.log"
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    with log.open("wb") as stream:
        process = subprocess.Popen([str(binary)], stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True, cwd=str(app.parent), env=env)
        processes.append(process)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return {"phase": phase, "app": app.parent.name, "log": log.name,
                    "resident": True, "outcome": "resident"}
        if status != 0:
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: {phase} renamed app exited {status}; see {log}")
        return {"phase": phase, "app": app.parent.name, "log": log.name,
                "resident": False, "outcome": "exited-clean"}


def launch_phase(app, domain, results, timeout, processes, reaped, extra_env=None, phase="app"):
    """Launch one renamed app, prove residency, then quit/reap its whole group.

    On success the pid is marked reaped so the top-level finally does not
    re-signal a freed pid; on a reap failure it stays pending and is retried.
    """
    record = launch_one(app, domain, results, timeout, processes, extra_env, phase)
    process = processes[-1]
    terminate_and_reap([process])  # finding 3: may raise (no success)
    reaped.add(process.pid)
    return record


def assert_all_resident(launches):
    if not all(launch["resident"] for launch in launches):
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: a renamed app did not stay resident (no genuine AppKit launch)")


def settle(seconds):
    """Let cfprefsd flush app writes before captures/comparisons."""
    time.sleep(seconds)


def _nm_symbols(app):
    binary = app / "Contents/MacOS/XRG-ng"
    return subprocess.run(["xcrun", "nm", "-arch", platform.machine(), "-j", str(binary)],
                          check=True, capture_output=True, text=True).stdout


def _unregister(app):
    if app.exists():
        try:
            subprocess.run([LSREGISTER, "-u", str(app)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.SubprocessError):
            pass


def seed_domain(domain, seed):
    subprocess.run(["/usr/bin/defaults", "import", domain, str(seed)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def export_domain(domain):
    return subprocess.run(["/usr/bin/defaults", "export", domain, "-"], check=True,
                          capture_output=True).stdout


# --------------------------------------------------------------------------
# Supplementary validation shared by full and probe-only runs.
# --------------------------------------------------------------------------

def run_supplementary(app, results, seed, products, expected_diagnostics, expected_document):
    """Framework driver + shared-core probe: independent PURE migrations.

    Both must reproduce the oracle byte-exact (R21). The driver uses ONLY the
    supplied app's framework (no fallback). Returns (driver_document,
    probe_diagnostics).
    """
    framework = resolve_driver_framework(app)
    driver = compile_app_driver(framework, results)
    driver_doc_path = results / "driver-document.json"
    written = run_app_driver(driver, framework, seed, driver_doc_path)
    driver_document = written.read_bytes().decode("utf-8")
    if driver_document != expected_document:
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: the supplied app's framework driver does not "
            "reproduce macos-0.2.2-expected.json (STOP and report, do not edit the fixture)")

    probe_products = build_probe_products(REPO, results, products)
    probe = compile_probe(probe_products, results)
    probe_doc_path = results / "probe-document.json"
    probe_diag_path = results / "probe-diagnostics.json"
    run_probe(probe, probe_products, seed, probe_doc_path, probe_diag_path)
    probe_document = probe_doc_path.read_bytes().decode("utf-8")
    probe_diagnostics = json.loads(probe_diag_path.read_text())
    compare_documents(expected_diagnostics, expected_document, probe_diagnostics, probe_document)
    return driver_document, probe_diagnostics


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Freshly built 0.2.3 XRG-ng.app")
    parser.add_argument("--baseline", type=Path, required=True, help="0.2.2 XRG-ng.app (tag v0.2.2)")
    parser.add_argument("--seed", type=Path, default=None,
                        help="0.2.2 defaults plist (default: the Task 4 fixture; R9 real-prefs run passes its own)")
    parser.add_argument("--expected", type=Path, default=None,
                        help="expected document JSON (default: the Task 4 fixture)")
    parser.add_argument("--products", type=Path, default=None,
                        help="dir with XRGSharedCore.swiftmodule + libXRGSharedCore.dylib (supplementary probe)")
    parser.add_argument("--results", type=Path, default=None, help="artifacts directory (scratch)")
    parser.add_argument("--launch-timeout", type=float, default=6.0,
                        help="seconds each renamed app is allowed to start (default 6)")
    parser.add_argument("--settle-timeout", type=float, default=1.5,
                        help="seconds to let app preference writes settle (default 1.5)")
    parser.add_argument("--skip-launch", action="store_true",
                        help="supplementary-only validation: NO app launches, NO relaunch claim, NO OK line")
    parser.add_argument("--withhold-upgrade-env", action="store_true",
                        help="NEGATIVE CONTROL: do not pass the startup-migration env var; the check MUST fail")
    args = parser.parse_args(argv)
    if args.settle_timeout < 0 or args.launch_timeout <= 0:
        parser.error("timeouts must be positive")

    install_signal_handlers()

    # SAFETY gate first: nothing touches the machine until the ids are proven safe.
    token = make_token()
    domain = domain_for(token)
    assert_safe_ids([domain])

    home = Path.home().resolve()
    seed = (args.seed or default_seed_path()).resolve()
    expected_path = (args.expected or default_expected_path()).resolve()
    # Fix-1 finding 5: refuse protected inputs BEFORE reading anything.
    assert_safe_inputs(seed, expected_path, home)

    app = args.app.resolve()
    baseline_app = args.baseline.resolve()
    # Finding 1: the supplied app must still HAVE the store symbols (the
    # negative control keeps them but writes no document).
    assert_app_document_backend(_nm_symbols(app))

    if not seed.is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: missing seed plist: {seed}")
    if not expected_path.is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: missing expected document: {expected_path}")
    for candidate in (app, baseline_app):
        if not (candidate / "Contents/MacOS/XRG-ng").is_file():
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: not a built XRG-ng.app: {candidate}")
    expected_diagnostics, expected_document = parse_expected(expected_path)

    results = (args.results.resolve() if args.results
               else Path(tempfile.mkdtemp(prefix="xrg-settings-upgrade-")).resolve())
    results.mkdir(parents=True, exist_ok=True)
    print(f"Settings upgrade artifacts: {results}", flush=True)

    for path in private_paths(home, domain):
        if path.exists() or path.is_symlink():
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: disposable namespace already exists: {path}")

    new_copy = results / "0.2.3" / "XRG-ng.app"
    old_copy = results / "0.2.2" / "XRG-ng.app"
    document_path = app_document_path(home, domain)
    cleanup_failures = []
    processes = []
    reaped = set()
    launches = []
    defaults_byte_identical = None
    driver_diagnostics = []
    supplementary_driver_matches = False
    supplementary_probe_matches = False
    downgrade_normalised = False
    layout_size_settings_normalised = False
    try:
        # Finding 1: "starts with no document".
        if document_path.exists():
            raise RuntimeError(
                f"SETTINGS_UPGRADE_MACOS: a document already exists at the app's "
                f"R11 private store {document_path}; the app must start with none")

        # 1. Seed the disposable domain.
        seed_domain(domain, seed)
        (results / "seed-defaults.plist").write_bytes(export_domain(domain))

        # 2. Supplementary PURE migrations (driver over the supplied app's
        #    framework, probe over the shared core). Both must equal the oracle.
        _, probe_diagnostics = run_supplementary(
            app, results, seed, args.products, expected_diagnostics, expected_document)
        driver_diagnostics = probe_diagnostics
        supplementary_driver_matches = True
        supplementary_probe_matches = True

        if args.skip_launch:
            # Probe-only: NO launches, NO app document, NO relaunch, NO OK line.
            pass
        else:
            make_renamed_copy(app, domain, new_copy)
            make_renamed_copy(baseline_app, domain, old_copy)
            env_for_upgrade = upgrade_check_env(domain, enabled=not args.withhold_upgrade_env)

            # 3. Launch the 0.2.3 app WITH the env var -> it migrates the seeded
            #    domain into its OWN R11 document. (Negative control withholds
            #    the env var: no document -> the check fails below.)
            launches.append(launch_phase(new_copy, domain, results, args.launch_timeout,
                                         processes, reaped, env_for_upgrade, "0.2.3-upgrade"))
            settle(args.settle_timeout)

            # 4. Validate the document THE APP wrote (negative-control gate).
            document = load_app_document(document_path, driver_diagnostics,
                                         expected_diagnostics, expected_document)
            (results / "0.2.3-document.json").write_text(document)
            layout_size_settings_normalised = True

            # 5. Finding 2 NORMALISATION: run the 0.2.2 baseline ONCE before
            #    capturing the reference, so keys 0.2.2 rewrites on every launch
            #    (the 26 mapped XRGModule_* sizes) are settled, not excluded.
            launches.append(launch_phase(old_copy, domain, results, args.launch_timeout,
                                         processes, reaped, None, "0.2.2-baseline"))
            settle(args.settle_timeout)
            reference_raw = export_domain(domain)
            (results / "reference-defaults.plist").write_bytes(reference_raw)
            reference = defaults_snapshot(reference_raw)
            downgrade_normalised = True

            # 6. Downgrade: relaunch 0.2.2, quit, settle, compare byte-for-byte.
            launches.append(launch_phase(old_copy, domain, results, args.launch_timeout,
                                         processes, reaped, None, "0.2.2-downgrade"))
            settle(args.settle_timeout)
            final_raw = export_domain(domain)
            (results / "downgraded-defaults.plist").write_bytes(final_raw)
            if defaults_snapshot(final_raw) != reference:
                raise RuntimeError(
                    "SETTINGS_UPGRADE_MACOS: 0.2.2 defaults changed after the "
                    "0.2.3 -> 0.2.2 round trip (settings were corrupted or migrated in place)")
            defaults_byte_identical = True

            assert_all_resident(launches)

        (results / "summary.json").write_text(json.dumps(summary_fields(
            domain, seed, expected_path, document_path, driver_diagnostics,
            not args.skip_launch, launches, defaults_byte_identical,
            supplementary_probe_matches, supplementary_driver_matches,
            downgrade_normalised, layout_size_settings_normalised), indent=2) + "\n")
    finally:
        # Finding 3: reap ALL launched process groups and CONFIRM they are gone
        # BEFORE any storage is deleted. A failure here raises (no success) but
        # the nested finally still unregisters and cleans up every artifact.
        pending = [process for process in processes if process.pid not in reaped]
        try:
            terminate_and_reap(pending)
        finally:
            try:
                _unregister(new_copy)
                _unregister(old_copy)
            finally:
                cleanup_failures = cleanup(domain, home)
            for failure in cleanup_failures:
                print(f"cleanup failure: {failure}", file=sys.stderr)

    # The OK line is printed ONLY after reaping + cleanup succeeded.
    print(ok_after_cleanup(cleanup_failures, not args.skip_launch), flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Interrupted as error:
        print(f"Settings upgrade failed: {error}", file=sys.stderr)
        sys.exit(128 + error.signum)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError,
            json.JSONDecodeError, plistlib.InvalidFileException) as error:
        print(f"Settings upgrade failed: {error}", file=sys.stderr)
        sys.exit(1)
