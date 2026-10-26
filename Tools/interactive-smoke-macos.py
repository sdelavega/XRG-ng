#!/usr/bin/env python3
"""Prepare, verify and clean a disposable app for a manual macOS UI check."""
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("packaged_smoke", Path(__file__).with_name("packaged-smoke-macos.py"))
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)


def running(app):
    executable = str(app / "Contents/MacOS/XRG-ng")
    result = subprocess.run(["/bin/ps", "-axo", "pid=,comm="], check=True, capture_output=True, text=True)
    return [int(parts[0]) for line in result.stdout.splitlines()
            if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == executable]


def identity(app):
    return {"textAndEntryHashes": support.text_sections(app / "Contents/MacOS/XRG-ng"),
            "mainMenuHashes": support.main_menu(app)}


def load(output):
    state = json.loads((output / "session.json").read_text())
    app = output / "XRG-ng.app"
    domain = state["domain"]
    support.private_home_paths(Path.home().resolve(), domain)  # Enforce the UUID namespace before cleanup.
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleIdentifier"] != domain or info["CFBundleExecutable"] != "XRG-ng":
        raise RuntimeError("Session bundle identity changed")
    if identity(app) != state["identity"]:
        raise RuntimeError("Disposable app code/MainMenu changed")
    return state, app, domain


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "verify", "cleanup"))
    parser.add_argument("--results", type=Path, required=True, help="A new directory for prepare; the same directory afterward")
    parser.add_argument("--app", type=Path, help="Freshly built shipping app (prepare only)")
    parser.add_argument("--expect", type=Path, help="JSON object containing expected saved preferences (verify only)")
    args = parser.parse_args()
    output = args.results.resolve()
    home = Path.home().resolve()
    if args.action == "prepare":
        if not args.app:
            parser.error("prepare requires --app")
        source = args.app.resolve()
        info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleExecutable") != "XRG-ng" or info.get("NSMainNibFile") != "MainMenu":
            raise RuntimeError("Expected a built shipping XRG-ng app")
        baseline = identity(source)
        domain = support.PRIVATE_PREFIX + str(uuid.uuid4())
        if any(p.exists() or p.is_symlink() for p in support.private_home_paths(home, domain)):
            raise RuntimeError("Disposable preference namespace already exists")
        output.mkdir(parents=True, exist_ok=False)
        app = output / "XRG-ng.app"
        shutil.copytree(source, app, symlinks=True)
        info["CFBundleIdentifier"] = domain
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        support.command(["codesign", "--force", "--sign", "-", str(app)], output / "sign.log", cwd=output)
        if identity(app) != baseline:
            raise RuntimeError("Signing changed code/MainMenu")
        seed = {"checkForUpdates": False, "isDockIconHidden": False, "showSensorWindow": False,
                "showWeatherGraph": False, "showStockGraph": False, "showAITokenGraph": False,
                "aiTokensTrackingEnabled": False, "graphOrientationVertical": True,
                "windowIsMinimized": False, "windowTitle": "XRG-ng UI check", "icao": "", "stockSymbols": ""}
        for key in ("showCPUGraph", "showGPUGraph", "showMemoryGraph", "showBatteryGraph",
                    "showTemperatureGraph", "showNetworkGraph", "showDiskGraph"):
            seed[key] = True
        (output / "seed.plist").write_bytes(plistlib.dumps(seed))
        (output / "session.json").write_text(json.dumps({"domain": domain, "identity": baseline}, indent=2))
        try:
            support.command(["/usr/bin/defaults", "import", domain, str(output / "seed.plist")], output / "seed.log", cwd=output)
        except BaseException:
            support.remove_private_artifacts(home, domain)
            raise
        print(f"Launch this bundle using native app control: {app}\nPrivate bundle ID: {domain}")
        print("This interactive copy has no injected hooks or network/home-read sandbox. Keep provider tracking disabled.")
        return
    _, app, domain = load(output)
    if running(app):
        raise RuntimeError("Quit the disposable app normally before verification or cleanup")
    if args.action == "verify":
        if not args.expect:
            parser.error("verify requires --expect")
        expected = json.loads(args.expect.read_text())
        if not isinstance(expected, dict) or not expected:
            raise RuntimeError("Expected a nonempty JSON preference object")
        result = subprocess.run(["/usr/bin/defaults", "export", domain, "-"], check=True, capture_output=True)
        actual = plistlib.loads(result.stdout)
        if any(actual.get(key) != value for key, value in expected.items()):
            raise RuntimeError("Saved preferences do not match the UI check expectations")
        (output / "verification.json").write_text(json.dumps({"savedPreferencesMatch": True,
            "textAndEntryUnchanged": True, "mainMenuUnchanged": True, "appExited": True,
            "verifiedPreferenceKeys": sorted(expected)}, indent=2))
        print("PASS: saved preferences match; app exited; code and MainMenu unchanged")
    else:
        register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        try:
            try:
                support.command([register, "-u", str(app)], output / "unregister.log", cwd=output, timeout=10)
            finally:
                subprocess.run(["/usr/bin/defaults", "delete", domain], check=True, capture_output=True, timeout=10)
        finally:
            support.remove_private_artifacts(home, domain)
        (output / "cleanup.json").write_text(json.dumps({"privateHomeArtifactsRemoved": True,
            "launchRegistrationRemoved": True, "appExited": True}, indent=2))
        print("PASS: disposable launch registration and private home artifacts removed")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Interactive smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
