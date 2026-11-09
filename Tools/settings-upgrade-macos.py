#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Prove settings survive 0.2.2 -> 0.2.3 -> 0.2.2 on macOS.

The check seeds a *disposable* NSUserDefaults domain (a renamed bundle id,
``com.sdelavega.xrg.upgradecheck.<uuid>``) from a 0.2.2 defaults export, runs
the 0.2.3 shared-core migration over that exact domain and compares the
resulting settings document with the hand-derived oracle, then asserts the
0.2.2 defaults are byte-identical afterwards (the downgrade). Disposable app
copies of both versions are made using the repo's renamed-CFBundleIdentifier
pattern (Tools/smoke-macos.py / Tools/packaged-smoke-macos.py) and launched as
a bounded proof of life.

SAFETY (absolute): the real production defaults domain ``com.sdelavega.xrg``,
its ~/Library/Preferences plist, and the real ~/Library/Application
Support/XRG-ng/settings.json are NEVER read, written, exported, deleted or
launched against. Every target id is generated in a private UUID namespace and
the script refuses to run if any equals the production id. Ruling R11 routes
non-production bundle ids to Application Support/XRG-ng-Private/<id>/; the
0.2.3 document is written there and that folder, the disposable domain and its
plist are removed at the end, even on failure.

The seed plist is an argument (default: the Task 4 fixture), so the coordinator
can run the identical machinery against a real 0.2.2 preferences export (ruling
R9) without code changes. Prints SETTINGS_UPGRADE_MACOS_OK on success.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True

PRODUCTION_ID = "com.sdelavega.xrg"
UPGRADE_PREFIX = "com.sdelavega.xrg.upgradecheck."
OK_LINE = "SETTINGS_UPGRADE_MACOS_OK"
TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent
FIXTURES = REPO / "Shared/Tests/Fixtures/settings"
LSREGISTER = ("/System/Library/Frameworks/CoreServices.framework/Frameworks/"
              "LaunchServices.framework/Support/lsregister")


class DocumentMismatch(RuntimeError):
    """The 0.2.3 document differs from the pinned oracle (ruling R21).

    Never resolve this by editing the fixture: a legitimate difference since
    Task 12 (Stocks mapped in the shared core) must be reported, not papered
    over. The main() error path prints this message verbatim.
    """


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


def cleanup(domain, home, run=None):
    """Delete the disposable domain, its plist and its private settings folder.

    The safety gate runs before any subprocess, so a production id aborts with
    no side effects. Best-effort: cleanup never masks the original failure.
    """
    assert_safe_ids([domain])
    run = run or subprocess.run
    try:
        run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.SubprocessError):
        pass
    for path in private_paths(home, domain):
        try:
            if path.is_symlink() or path.is_file():
                path.unlink(missing_ok=True)
            elif path.is_dir():
                shutil.rmtree(path)
        except OSError:
            pass


# --------------------------------------------------------------------------
# 0.2.3 migration probe: compiled against the built XRGSharedCore module.
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
    try FileManager.default.createDirectory(at: documentURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try document.serialized().write(to: documentURL)
    let report: [[String: String]] = diagnostics.map { ["id": $0.id ?? "document", "problem": $0.problem] }
    let bytes = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try bytes.write(to: diagnosticsURL)
} catch { fail("cannot write probe results: \(error)") }
print("PROBE_OK")
'''


def _require_products(products):
    if not (products / "XRGSharedCore.swiftmodule").exists() \
            or not (products / "libXRGSharedCore.dylib").is_file():
        raise RuntimeError(
            f"SETTINGS_UPGRADE_MACOS: --products lacks XRGSharedCore.swiftmodule / "
            f"libXRGSharedCore.dylib: {products}")


def build_products(root, results, provided=None):
    if provided:
        products = Path(provided).resolve()
        _require_products(products)
        return products
    scratch = results / "swift"
    base = ["swift", "build", "--package-path", str(root), "--scratch-path", str(scratch),
            "--product", "XRGSharedCore"]
    subprocess.run(base, check=True, stdout=subprocess.DEVNULL)
    bin_path = subprocess.check_output(base + ["--show-bin-path"], text=True).strip()
    products = Path(bin_path)
    _require_products(products)
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


def launch_copy(app, domain, results, timeout):
    """Bounded proof of life: a resident app still running at timeout is a pass."""
    assert_safe_ids([domain])
    binary = app / "Contents/MacOS/XRG-ng"
    log = results / f"launch-{app.parent.name}.log"
    with log.open("wb") as stream:
        process = subprocess.Popen([str(binary)], stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True, cwd=str(app.parent),
                                   env=os.environ.copy())
        try:
            status = process.wait(timeout=timeout)
            if status != 0:
                raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: renamed app exited {status}; see {log}")
            return {"app": app.parent.name, "log": log.name, "resident": False, "outcome": "exited-clean"}
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            # A resident monitoring app still running at the timeout is the
            # genuine launch signal; it was terminated cleanly here.
            return {"app": app.parent.name, "log": log.name, "resident": True, "outcome": "resident"}


def _unregister(app):
    if app.exists():
        try:
            subprocess.run([LSREGISTER, "-u", str(app)], stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.SubprocessError):
            pass


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Freshly built 0.2.3 XRG-ng.app")
    parser.add_argument("--baseline", type=Path, required=True, help="0.2.2 XRG-ng.app (tag v0.2.2)")
    parser.add_argument("--seed", type=Path, default=None,
                        help="0.2.2 defaults plist (default: the Task 4 fixture; R9 real-prefs run passes its own)")
    parser.add_argument("--expected", type=Path, default=None,
                        help="expected document JSON (default: the Task 4 fixture)")
    parser.add_argument("--products", type=Path, default=None,
                        help="dir with XRGSharedCore.swiftmodule + libXRGSharedCore.dylib (built otherwise)")
    parser.add_argument("--results", type=Path, default=None, help="artifacts directory (scratch)")
    parser.add_argument("--launch-timeout", type=float, default=6.0,
                        help="seconds each renamed app is allowed to start (default 6)")
    parser.add_argument("--skip-launch", action="store_true",
                        help="skip the bounded proof-of-life launches (deterministic core only)")
    args = parser.parse_args(argv)

    # SAFETY gate first: nothing touches the machine until the ids are proven safe.
    token = make_token()
    domain = domain_for(token)
    assert_safe_ids([domain])

    seed = (args.seed or default_seed_path()).resolve()
    expected_path = (args.expected or default_expected_path()).resolve()
    if not seed.is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: missing seed plist: {seed}")
    if not expected_path.is_file():
        raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: missing expected document: {expected_path}")
    results = (args.results.resolve() if args.results
               else Path(tempfile.mkdtemp(prefix="xrg-settings-upgrade-")).resolve())
    results.mkdir(parents=True, exist_ok=True)
    print(f"Settings upgrade artifacts: {results}", flush=True)

    home = Path.home().resolve()
    for path in private_paths(home, domain):
        if path.exists() or path.is_symlink():
            raise RuntimeError(f"SETTINGS_UPGRADE_MACOS: disposable namespace already exists: {path}")

    new_copy = results / "0.2.3" / "XRG-ng.app"
    old_copy = results / "0.2.2" / "XRG-ng.app"
    try:
        # 1. A disposable renamed-bundle-id copy of each app version.
        make_renamed_copy(args.app, domain, new_copy)
        make_renamed_copy(args.baseline, domain, old_copy)

        # 2. Seed the disposable defaults domain from the 0.2.2 export.
        subprocess.run(["/usr/bin/defaults", "import", domain, str(seed)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        seeded = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], check=True,
                                capture_output=True).stdout
        (results / "seeded.plist").write_bytes(seeded)

        # 3. The 0.2.3 shared core migrates that exact domain into its document,
        #    written at the R11 private settings path for the renamed bundle.
        products = build_products(REPO, results, args.products)
        probe = compile_probe(products, results)
        support = home / "Library/Application Support/XRG-ng-Private" / domain
        document_path = support / "settings.json"
        diagnostics_path = results / "diagnostics.json"
        run_probe(probe, products, results / "seeded.plist", document_path, diagnostics_path)
        document = document_path.read_bytes().decode("utf-8")
        diagnostics = json.loads(diagnostics_path.read_text())

        # 4. Compare against the hand-derived oracle (R21: never edit the fixture).
        expected_diagnostics, expected_document = parse_expected(expected_path)
        compare_documents(expected_diagnostics, expected_document, diagnostics, document)
        (results / "0.2.3-document.json").write_text(document)

        # 5. Downgrade: the 0.2.2 defaults must be byte-identical after 0.2.3.
        after = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], check=True,
                               capture_output=True).stdout
        if after != seeded:
            raise RuntimeError("SETTINGS_UPGRADE_MACOS: 0.2.3 migration changed the 0.2.2 defaults domain")

        # 6. Bounded proof of life for both renamed app copies (done last, after
        #    the byte-identity assertion, so a resident app's own writes cannot
        #    affect the downgrade result). The 0.2.2 copy is relaunched here.
        launches = []
        if not args.skip_launch:
            launches.append(launch_copy(new_copy, domain, results, args.launch_timeout))
            launches.append(launch_copy(old_copy, domain, results, args.launch_timeout))
            if not all(launch["resident"] for launch in launches):
                raise RuntimeError(
                    "SETTINGS_UPGRADE_MACOS: a renamed app did not stay resident (no genuine AppKit launch)")

        (results / "summary.json").write_text(json.dumps({
            "domain": domain, "seed": str(seed), "expected": str(expected_path),
            "documentMatchesExpected": True, "diagnostics": diagnostics,
            "defaultsByteIdentical": True, "launched": not args.skip_launch,
            "baselineRelaunched": True, "launches": launches,
        }, indent=2) + "\n")
        print(OK_LINE, flush=True)
    finally:
        # Delete the disposable domain, its plist and its private settings folder,
        # even on failure. Unregister the copies too (best effort, never fatal).
        try:
            cleanup(domain, home)
        finally:
            _unregister(new_copy)
            _unregister(old_copy)
        # Surface the mismatch message verbatim (the report must see it, not a fix).
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f"Settings upgrade failed: {error}", file=sys.stderr)
        sys.exit(1)
