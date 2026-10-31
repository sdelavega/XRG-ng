#!/usr/bin/env python3
"""Run fixture-backed AppKit startup twice using a disposable preference domain."""
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
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
import uuid


def command(arguments, log, *, cwd, timeout=600, env=None):
    with log.open("w") as stream:
        process = subprocess.Popen(arguments, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True, env=env)
        try:
            result = process.wait(timeout=timeout)
        except BaseException as error:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            if isinstance(error, subprocess.TimeoutExpired):
                raise RuntimeError(f"Timed out after {timeout}s; see {log}") from error
            raise
        if result:
            raise RuntimeError(f"Command failed with status {result}; see {log}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Debug")
    parser.add_argument("--products", type=Path, help="Reuse freshly built test products (used by CI)")
    parser.add_argument("--results", type=Path, help="A new directory for smoke artifacts")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.results
    if output:
        output = output.resolve()
        output.mkdir(parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix=f"xrg-smoke-{args.configuration}-"))
    print(f"Smoke artifacts: {output}", flush=True)
    command([sys.executable, "Tools/extract_sensor_nib_fixture.py", str(output / "SmokeSensors.xib")],
            output / "fixture.log", cwd=root)
    if (output / "SmokeSensors.xib").read_bytes() != (root / "XRGTests/Fixtures/SmokeSensors.xib").read_bytes():
        raise RuntimeError("Smoke sensor fixture is stale; regenerate it with Tools/extract_sensor_nib_fixture.py")
    products = args.products.resolve() if args.products else output / "DerivedData/Build/Products" / args.configuration
    if not args.products:
        command(["xcodebuild", "-project", "XRG-ng.xcodeproj", "-scheme", "XRGTests",
                 "-configuration", args.configuration, "-destination", "platform=macOS",
                 "-derivedDataPath", str(output / "DerivedData"), "CODE_SIGNING_ALLOWED=NO",
                 "ENABLE_TESTABILITY=YES", "build-for-testing"], output / "build.log", cwd=root)
    fixture_resources = products / "XRGTests.xctest/Contents/Resources"
    framework = products / "XRGCore.framework"
    # XRGCore carries the Sparkle-backed updater, so the smoke app must bundle
    # the same dynamic framework the shipped app embeds, or dyld cannot load it.
    sparkle = products / "Sparkle.framework"
    if not framework.is_dir() or not sparkle.is_dir() or not fixture_resources.is_dir():
        raise RuntimeError("Missing test framework or resources; build XRGTests with ENABLE_TESTABILITY=YES")
    domain = "com.sdelavega.XRG-ng.Smoke." + str(uuid.uuid4())
    app = output / "XRGSmoke.app"
    contents = app / "Contents"
    for folder in ("MacOS", "Frameworks", "Resources"):
        (contents / folder).mkdir(parents=True)
    shutil.copytree(framework, contents / "Frameworks/XRGCore.framework", symlinks=True)
    shutil.copytree(sparkle, contents / "Frameworks/Sparkle.framework", symlinks=True)
    for name in ("Preferences.nib", "SmokeSensors.nib", "PreferencesOutletKeys.plist"):
        source, destination = fixture_resources / name, contents / "Resources" / name
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            shutil.copy2(source, destination)
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump({"CFBundleIdentifier": domain, "CFBundleName": "XRGSmoke",
                       "CFBundleExecutable": "XRGSmoke", "CFBundlePackageType": "APPL",
                       "CFBundleVersion": "1", "NSPrincipalClass": "NSApplication",
                       "LSMinimumSystemVersion": "26.0", "LSUIElement": True}, stream)
    binary = contents / "MacOS/XRGSmoke"
    optimization = ["-O", "-whole-module-optimization"] if args.configuration == "Release" else ["-Onone", "-g", "-DDEBUG"]
    command(["xcrun", "swiftc", "-swift-version", "5", "-module-name", "XRGSmoke",
             *optimization,
             "-target", platform.machine() + "-apple-macos26.0", "-F", str(products),
             "-framework", "XRGCore", "-framework", "Sparkle", "-framework", "AppKit",
             "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
             "Controllers/XRGAppDelegate.swift", "XRGTests/XRGApplicationSmokeScene.swift",
             "Tools/SmokeApp/main.swift", "-o", str(binary)], output / "compile.log", cwd=root)
    command(["codesign", "--force", "--sign", "-", str(contents / "Frameworks/XRGCore.framework")],
            output / "sign-framework.log", cwd=root)
    command(["codesign", "--force", "--sign", "-", str(contents / "Frameworks/Sparkle.framework")],
            output / "sign-sparkle.log", cwd=root)
    command(["codesign", "--force", "--sign", "-", str(app)], output / "sign-app.log", cwd=root)
    passed = False
    try:
        reports = []
        for phase in ("seed", "restore"):
            environment = os.environ.copy()
            environment.update(XRG_SMOKE_DOMAIN=domain, XRG_SMOKE_PHASE=phase, XRG_SMOKE_RESULTS=str(output))
            command([str(binary)], output / f"{phase}.log", cwd=output, timeout=30, env=environment)
            report = json.loads((output / f"{phase}.json").read_text())
            if not (report["phase"] == phase and report["appKitLaunchNotification"]
                    and report["moduleCount"] == 13 and report["budget"] == 1337
                    and report["collapsed"] and report["shutdownTimersInvalidated"]
                    and sorted(report["nibs"]) == ["Preferences", "Sensors"] and not report["failures"]):
                raise RuntimeError(f"Unexpected smoke results: {report}")
            if not (output / f"{phase}.png").is_file():
                raise RuntimeError(f"Missing offscreen rendering for {phase}")
            reports.append(report)
        if reports[0]["pid"] == reports[1]["pid"]:
            raise RuntimeError("Restore did not run in a distinct process")
        passed = True
    finally:
        # The domain is generated here, never supplied by the caller or reused from the user's app.
        cleanup = subprocess.run(["/usr/bin/defaults", "delete", domain], stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, timeout=10)
        if cleanup.returncode:
            if passed:
                raise RuntimeError(f"Failed to remove private preferences for {domain}")
            print(f"Private preference cleanup returned {cleanup.returncode} for {domain}", file=sys.stderr)
    print("PASS: two AppKit processes, thirteen registered fixture-backed panels (two optional), private preferences restored and removed, timers stopped", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda number, _: sys.exit(128 + number))
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
