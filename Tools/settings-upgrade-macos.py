#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Prove settings survive 0.2.2 -> 0.2.3 -> 0.2.2 on macOS.

The check seeds a *disposable* NSUserDefaults domain (a renamed bundle id,
``com.sdelavega.xrg.upgradecheck.<uuid>``) from a 0.2.2 defaults export. The
**0.2.3 document is produced by the supplied 0.2.3 app itself**: a driver
compiled with ``@testable import XRGCore`` against the app's OWN
``XRGCore.framework`` (the framework built alongside ``--app``) constructs the
app's ``XRGSettingsStore`` document backend, runs its real first-launch
migration over the seeded domain, and writes ``settings.json`` into the R11
private namespace ``~/Library/Application Support/XRG-ng-Private/<id>/``.
That document -- not a separately built shared-core probe -- is compared with
the hand-derived oracle. The source-built ``XRGSharedCore`` probe is kept only
as *supplementary* core validation (its document and diagnostics must agree
with the app's).

ORDER (review fix 2): capture baseline defaults -> produce/compare the 0.2.3
document -> launch the 0.2.3 renamed app copy -> quit -> relaunch the 0.2.2
renamed app copy -> quit -> wait for writes to settle -> compare 0.2.2's
defaults byte-for-byte. A probe-only/--skip-launch run NEVER prints
SETTINGS_UPGRADE_MACOS_OK and NEVER claims a relaunch.

SAFETY (absolute): the real production defaults domain ``com.sdelavega.xrg``,
its ~/Library/Preferences plist, and the real ~/Library/Application
Support/XRG-ng/settings.json are NEVER read, written, exported, deleted or
launched against. Protected --seed/--expected inputs that resolve (realpath,
symlinks followed) to those files are refused before anything is read; a
coordinator-created export copy in scratch is accepted. Every target id is a
generated UUID in a private namespace. Cleanup attempts every step, checks
return codes, verifies the disposable domain/plist/private folder are gone and
reports accumulated failures; the OK line is printed only after cleanup
succeeds (non-zero exit otherwise). Catchable termination signals run all
``finally`` blocks, and launched process groups are terminated and reaped in a
launch-level finally before their storage is deleted.

Prints SETTINGS_UPGRADE_MACOS_OK on full success.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import plistlib
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

# Keys AppKit / XRG legitimately rewrite on every launch -- window restore
# frames, graph-module layout feedback, Sparkle state and recorded AI usage
# (docs/settings-inventory.md, XRGSettingsStore.excludedLegacyKeys). They are
# *not* stable across launches, so the downgrade byte comparison projects them
# out; every other (settings) key is compared byte-for-byte. The graph-module
# size keys are still verified through the 0.2.3 document comparison.
VOLATILE_PREFIXES = ("SU", "NSWindow Frame ", "XRGModule_")
VOLATILE_KEYS = frozenset({
    "unminimizedFrame", "tempLocationsAutoconfigured",
    "aiTokensDailyUnclassifiedTokens", "aiTokensDailyPromptTokens",
    "aiTokensDailyCompletionTokens",
    "aiTokensDailyModelUnclassifiedTokens", "aiTokensDailyModelPromptTokens",
    "aiTokensDailyModelCompletionTokens",
    "aiTokensDailyProviderUnclassifiedTokens", "aiTokensDailyProviderPromptTokens",
    "aiTokensDailyProviderCompletionTokens",
    "aiTokensDailyDate", "aiTokensLastNotifyDate",
    "packagedSmokeMarker",
})


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
    """Tie the check to the supplied app binary (review fix 1).

    A supplied app whose main executable does not contain the document store
    must not be able to pass: its own framework could not produce the document.
    """
    if "XRGSettingsStore" not in symbols or "XRGSettingsMigration" not in symbols:
        raise RuntimeError(
            "SETTINGS_UPGRADE_MACOS: the supplied 0.2.3 app has no XRGSettingsStore "
            "document backend / XRGSettingsMigration; an app that never migrates must fail")


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


def compare_documents(expected_diagnostics, expected_document, actual_diagnostics, actual_document):
    """Compare the produced 0.2.3 document with the pinned Task 4 oracle."""
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


def load_app_document(document_path, actual_diagnostics, expected_diagnostics, expected_document):
    """Read the document the SUPPLIED APP produced and compare it.

    If the app did not migrate (no document at its R11 store), this fails --
    the check never fabricates the document itself (review fix 1).
    """
    document_path = Path(document_path)
    if not document_path.is_file():
        raise RuntimeError(
            f"SETTINGS_UPGRADE_MACOS: the supplied 0.2.3 app produced no migrated "
            f"settings document at {document_path}; an app that does not migrate must fail")
    document = document_path.read_bytes().decode("utf-8")
    compare_documents(expected_diagnostics, expected_document, actual_diagnostics, document)
    return document


def defaults_snapshot(exported_bytes):
    """Canonical bytes of a defaults domain's SETTINGS keys.

    AppKit rewrites window frames, graph-module layout feedback, Sparkle state
    and recorded AI usage on every launch (docs/settings-inventory.md). Those
    keys are projected out so the downgrade comparison is stable; every other
    key -- all real settings -- is compared byte-for-byte, so a settings value
    corrupted by either launch still fails the assertion.
    """
    domain = plistlib.loads(exported_bytes)
    stable = {key: value for key, value in domain.items()
              if key not in VOLATILE_KEYS and not key.startswith(VOLATILE_PREFIXES)}
    return plistlib.dumps(stable, fmt=plistlib.FMT_BINARY, sort_keys=True)


def success_marker(launched):
    """A probe-only run must never emit the OK line (review fix 2)."""
    return OK_LINE if launched else PROBE_ONLY_LINE


def ok_after_cleanup(cleanup_failures, launched):
    """Emit success only after cleanup succeeded (review fix 4).

    A failed cleanup raises (non-zero exit) and NEVER returns the OK line.
    """
    if cleanup_failures:
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: cleanup failed; " + "; ".join(cleanup_failures))
    return success_marker(launched)


def summary_fields(domain, seed, expected, document_path, diagnostics,
                   launched, launches, defaults_byte_identical,
                   supplementary_probe_matches):
    """Only a full (launched) run may claim a 0.2.2 relaunch (review fix 2)."""
    return {
        "domain": domain, "seed": str(seed), "expected": str(expected),
        "documentSource": "supplied 0.2.3 app XRGSettingsStore (R11 private store)",
        "documentPath": str(document_path),
        "documentMatchesExpected": True, "diagnostics": diagnostics,
        "defaultsByteIdentical": defaults_byte_identical,
        "supplementaryProbeMatches": supplementary_probe_matches,
        "launched": launched,
        "baselineRelaunched": launched,
        "launches": launches,
    }


# --------------------------------------------------------------------------
# Signals and process groups (review fix 3).
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


def terminate_and_reap(processes, killpg=None):
    """Terminate (process group) and reap every launched app that is still alive."""
    killpg = killpg or os.killpg
    for process in processes:
        if process.poll() is not None:
            continue
        try:
            killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, OSError):
            pass
    for process in processes:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                killpg(process.pid, signal.SIGKILL)
            except (ProcessLookupError, OSError):
                pass
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass


# --------------------------------------------------------------------------
# Cleanup (review fix 4): attempt every step, check return codes, verify gone.
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
# Supplementary shared-core probe (review fix 1: demoted to a cross-check).
# Built from the XRGSharedCore Swift package: independent core validation that
# its fromMacDefaults agrees with the supplied app's own document.
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
# The supplied 0.2.3 app's OWN document store (review fix 1, primary).
# A driver compiled with @testable import XRGCore against the app's framework
# runs XRGSettingsStore's real first-launch migration into the R11 namespace.
# --------------------------------------------------------------------------

APP_DRIVER_SWIFT = r'''// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
import Foundation
import AppKit
@testable import XRGCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("app-document-driver: " + message + "\n").utf8))
    exit(1)
}

@main
enum AppDocumentDriver {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count == 4 else { fail("usage: DRIVER seed.plist <bundle-id> diagnostics.json") }
        let seedURL = URL(fileURLWithPath: args[1])
        let identifier = args[2]
        let diagnosticsURL = URL(fileURLWithPath: args[3])
        guard let data = try? Data(contentsOf: seedURL),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let seed = object as? [String: Any] else { fail("cannot read seed defaults plist") }
        guard identifier.contains("com.sdelavega.xrg.upgradecheck.") else {
            fail("refusing a non-private bundle identifier")
        }
        guard let catalog = try? XRGSettingsCatalog.load() else { fail("settings catalog is missing") }
        // The supplied app's OWN document store at its OWN R11 private path.
        let fileURL = XRGSettingsStore.sharedDocumentURL(bundleIdentifier: identifier)
        guard fileURL.path.contains("/XRG-ng-Private/" + identifier + "/settings.json") else {
            fail("store path is not the R11 private namespace: \(fileURL.path)")
        }
        guard let defaults = UserDefaults(suiteName: identifier) else { fail("no defaults suite") }
        // First launch of 0.2.3: migrate the 0.2.2 domain ONCE into the document.
        let store = XRGSettingsStore(fileURL: fileURL, defaults: defaults,
                                     catalog: catalog, legacyDomain: seed)
        if let problem = store.loadProblem { fail("store load problem: \(problem.problem)") }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            fail("app store wrote no settings.json")
        }
        // Diagnostics from the app's own core, for the comparison.
        let (_, diagnostics) = XRGSettingsMigration.fromMacDefaults(seed, catalog: catalog)
        let report: [[String: String]] = diagnostics.map { ["id": $0.id ?? "document", "problem": $0.problem] }
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: diagnosticsURL)
        } catch { fail("cannot write diagnostics: \(error)") }
        print("APP_DOCUMENT_OK " + fileURL.path)
    }
}
'''


def _framework_is_testable(framework):
    return framework.is_dir() and any(framework.rglob("*.private.swiftinterface"))


def resolve_driver_framework(app, results):
    """Prefer the XRGCore.framework built ALONGSIDE the supplied --app.

    If that framework is not testable, build a testable one from the app's own
    XRG-ng.xcodeproj (the XRGCore scheme) into scratch. Either way the driver
    links the app's OWN compiled store, not a rebuilt shared-core package.
    """
    products = app.resolve().parent
    sibling = products / "XRGCore.framework"
    if _framework_is_testable(sibling):
        return products
    scratch = results / "xrgcore"
    subprocess.run(["xcodebuild", "-project", str(REPO / "XRG-ng.xcodeproj"),
                    "-scheme", "XRGCore", "-configuration", "Release",
                    "-destination", "platform=macOS", "-derivedDataPath", str(scratch),
                    "CODE_SIGNING_ALLOWED=NO", "ONLY_ACTIVE_ARCH=YES",
                    "ENABLE_TESTABILITY=YES", "build"], check=True, stdout=subprocess.DEVNULL)
    products = scratch / "Build/Products/Release"
    if not _framework_is_testable(products / "XRGCore.framework"):
        raise RuntimeError("SETTINGS_UPGRADE_MACOS: could not obtain a testable XRGCore.framework")
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


def run_app_driver(executable, products, seed, identifier, diagnostics_path):
    env = os.environ.copy()
    existing = env.get("DYLD_FRAMEWORK_PATH")
    env["DYLD_FRAMEWORK_PATH"] = str(products) + (os.pathsep + existing if existing else "")
    result = subprocess.run([str(executable), str(seed), identifier, str(diagnostics_path)],
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


def launch_one(app, domain, results, timeout, processes):
    """Bounded proof of life; a resident app still running at timeout is a pass.

    The process is left running here and terminated/reaped by the launch-level
    finally (``run_launches``), so an interruption can never leave it behind.
    """
    assert_safe_ids([domain])
    binary = app / "Contents/MacOS/XRG-ng"
    log = results / f"launch-{app.parent.name}.log"
    with log.open("wb") as stream:
        process = subprocess.Popen([str(binary)], stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True, cwd=str(app.parent),
                                   env=os.environ.copy())
        processes.append(process)
        try:
            status = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return {"app": app.parent.name, "log": log.name, "resident": True, "outcome": "resident"}
        if status != 0:
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: renamed app exited {status}; see {log}")
        return {"app": app.parent.name, "log": log.name, "resident": False, "outcome": "exited-clean"}


def run_launches(apps, domain, results, timeout):
    """Launch 0.2.3 -> quit -> relaunch 0.2.2 -> quit; reap everything in a finally."""
    processes = []
    launches = []
    try:
        for app in apps:
            launches.append(launch_one(app, domain, results, timeout, processes))
            # "-> quit": terminate and reap this app before the next launch. The
            # finally re-reaps anything still alive (e.g. after an interruption).
            terminate_and_reap(processes[-1:])
        if not all(launch["resident"] for launch in launches):
            raise RuntimeError(
                "SETTINGS_UPGRADE_MACOS: a renamed app did not stay resident (no genuine AppKit launch)")
        return launches
    finally:
        # Launch-level finally: ALWAYS terminate/reap the whole process group
        # before any storage (domain/plist/private folder) is deleted.
        terminate_and_reap(processes)


def settle(seconds):
    """Let cfprefsd flush app writes before the downgrade comparison."""
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
                        help="probe-only core validation: NO app launches, NO relaunch claim, NO OK line")
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
    # Review fix 5: refuse protected inputs BEFORE reading anything.
    assert_safe_inputs(seed, expected_path, home)

    app = args.app.resolve()
    baseline_app = args.baseline.resolve()
    # Review fix 1: tie the check to the supplied app's own document backend.
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
    try:
        # 1. Seed the disposable domain and CAPTURE THE BASELINE (review fix 2).
        seed_domain(domain, seed)
        baseline_raw = export_domain(domain)
        (results / "baseline-defaults.plist").write_bytes(baseline_raw)
        baseline = defaults_snapshot(baseline_raw)

        # 2. The 0.2.3 document comes from the SUPPLIED APP's own store, written
        #    into the R11 private namespace for the renamed bundle id.
        framework = resolve_driver_framework(app, results)
        driver = compile_app_driver(framework, results)
        diagnostics_path = results / "app-diagnostics.json"
        written = run_app_driver(driver, framework, seed, domain, diagnostics_path)
        if written.resolve() != document_path:
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: app wrote its document outside the R11 store: {written}")
        driver_diagnostics = json.loads(diagnostics_path.read_text())
        document = load_app_document(document_path, driver_diagnostics,
                                     expected_diagnostics, expected_document)
        (results / "0.2.3-document.json").write_text(document)

        # 3. Supplementary shared-core probe: independent core validation only.
        #    It must AGREE with the app's document; it is never the source of truth.
        probe_products = build_probe_products(REPO, results, args.products)
        probe = compile_probe(probe_products, results)
        probe_document_path = results / "probe-document.json"
        probe_diagnostics_path = results / "probe-diagnostics.json"
        run_probe(probe, probe_products, seed, probe_document_path, probe_diagnostics_path)
        probe_document = probe_document_path.read_text()
        probe_diagnostics = json.loads(probe_diagnostics_path.read_text())
        if probe_document != document:
            raise RuntimeError(
                "SETTINGS_UPGRADE_MACOS: supplementary shared-core probe disagrees "
                "with the supplied 0.2.3 app's document")
        if _normalise_diagnostics(probe_diagnostics) != _normalise_diagnostics(driver_diagnostics):
            raise RuntimeError("SETTINGS_UPGRADE_MACOS: supplementary probe diagnostics disagree with the app")
        supplementary_probe_matches = True

        # 4. Launch 0.2.3 -> quit -> relaunch 0.2.2 -> quit (review fix 2).
        #    A probe-only run does NONE of this and claims no relaunch.
        launches = []
        defaults_byte_identical = None
        if not args.skip_launch:
            make_renamed_copy(app, domain, new_copy)
            make_renamed_copy(baseline_app, domain, old_copy)
            launches = run_launches([new_copy, old_copy], domain, results, args.launch_timeout)
            # 5. Wait for writes to settle, then compare 0.2.2's defaults.
            settle(args.settle_timeout)
            final_raw = export_domain(domain)
            (results / "downgraded-defaults.plist").write_bytes(final_raw)
            if defaults_snapshot(final_raw) != baseline:
                raise RuntimeError(
                    "SETTINGS_UPGRADE_MACOS: 0.2.2 defaults changed after the "
                    "0.2.3 -> 0.2.2 round trip (settings were corrupted or migrated in place)")
            defaults_byte_identical = True

        (results / "summary.json").write_text(json.dumps(summary_fields(
            domain, seed, expected_path, document_path, driver_diagnostics,
            not args.skip_launch, launches, defaults_byte_identical,
            supplementary_probe_matches), indent=2) + "\n")
    finally:
        # Unregister the copies; then attempt EVERY cleanup step, verify the
        # disposable domain/plist/private folder are gone, and report failures.
        try:
            _unregister(new_copy)
            _unregister(old_copy)
        finally:
            cleanup_failures = cleanup(domain, home)
        for failure in cleanup_failures:
            print(f"cleanup failure: {failure}", file=sys.stderr)

    # Review fix 4: the OK line is printed ONLY after cleanup succeeded.
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
