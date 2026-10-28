#!/usr/bin/env python3
"""Exercise the shipped entry point and unchanged nibs in a protected app copy."""
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import struct
import stat
import subprocess
import sys
import tempfile
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("xrg_smoke_support", Path(__file__).with_name("smoke-macos.py"))
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
command = support.command
PRIVATE_PREFIX = "com.sdelavega.XRG-ng.PackagedSmoke."


def private_home_paths(home, domain):
    if not domain.startswith(PRIVATE_PREFIX):
        raise RuntimeError("Refusing cleanup outside the packaged-smoke namespace")
    suffix = domain[len(PRIVATE_PREFIX):]
    try:
        if str(uuid.UUID(suffix)) != suffix:
            raise ValueError("Noncanonical UUID")
    except ValueError as error:
        raise RuntimeError("Refusing cleanup without a generated UUID") from error
    paths = []
    for identifier in {domain, domain.lower()}:
        paths.extend([home / "Library/Preferences" / (identifier + ".plist"),
                      home / "Library/Caches" / identifier,
                      home / "Library/Saved Application State" / (identifier + ".savedState"),
                      home / "Library/HTTPStorages" / identifier])
    return paths


def remove_private_artifacts(home, domain):
    for path in private_home_paths(home, domain):
        if path.is_symlink() or path.is_file():
            path.unlink(missing_ok=True)
        elif path.is_dir():
            shutil.rmtree(path)
    if any(path.exists() or path.is_symlink() for path in private_home_paths(home, domain)):
        raise RuntimeError("Private home artifact cleanup was incomplete")


def text_sections(path):
    """Signatures/load commands may change; executable instructions/constants must not."""
    data = path.read_bytes()
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        slices = [(struct.unpack_from(">IIIII", data, 8 + i * 20)[2:4]) for i in range(count)]
    elif data[:4] == b"\xca\xfe\xba\xbf":
        count = struct.unpack_from(">I", data, 4)[0]
        slices = [(struct.unpack_from(">IIQQII", data, 8 + i * 32)[2:4]) for i in range(count)]
    else:
        slices = [(0, len(data))]
    result = {}
    for base, size in slices:
        if data[base:base + 4] != b"\xcf\xfa\xed\xfe":
            raise RuntimeError("Expected a 64-bit little-endian Mach-O slice")
        header = struct.unpack_from("<IIIIIIII", data, base)
        cursor = base + 32
        entry = False
        for _ in range(header[4]):
            cmd, length = struct.unpack_from("<II", data, cursor)
            if length < 8 or cursor + length > base + size:
                raise RuntimeError("Invalid Mach-O load command")
            if cmd == 0x19 and data[cursor + 8:cursor + 24].rstrip(b"\0") == b"__RESTRICT":
                raise RuntimeError("Restricted Mach-O images cannot be tested with this instrumentation")
            if cmd == 0x80000028:
                result[f"{header[1]}:{header[2]}:LC_MAIN"] = hashlib.sha256(data[cursor:cursor + length]).hexdigest()
                entry = True
            if cmd == 0x19 and data[cursor + 8:cursor + 24].rstrip(b"\0") == b"__TEXT":
                sections = struct.unpack_from("<I", data, cursor + 64)[0]
                for index in range(sections):
                    section = cursor + 72 + index * 80
                    name = data[section:section + 16].rstrip(b"\0").decode("ascii")
                    _, length_bytes, offset = struct.unpack_from("<QQI", data, section + 32)
                    payload = data[base + offset:base + offset + length_bytes]
                    if len(payload) != length_bytes:
                        raise RuntimeError("Truncated Mach-O text section")
                    result[f"{header[1]}:{header[2]}:{name}"] = hashlib.sha256(payload).hexdigest()
            cursor += length
        if not entry:
            raise RuntimeError("Missing shipping entry-point command")
    if not result:
        raise RuntimeError("Executable has no text sections")
    return result


def main_menu(app):
    nib = app / "Contents/Resources/MainMenu.nib"
    if nib.is_file():
        return {nib.name: hashlib.sha256(nib.read_bytes()).hexdigest()}
    values = {str(p.relative_to(nib)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in nib.rglob("*") if p.is_file()}
    if not values:
        raise RuntimeError("Missing packaged MainMenu nib")
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="Freshly built XRG-ng.app")
    parser.add_argument("--results", type=Path)
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), default=platform.machine(),
                        help="Executable slice to run (defaults to the runner architecture); x86_64 on ARM requires Rosetta")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.results.resolve() if args.results else Path(tempfile.mkdtemp(prefix="xrg-packaged-smoke-")).resolve()
    if args.results:
        output.mkdir(parents=True, exist_ok=False)
    print(f"Packaged smoke artifacts: {output}", flush=True)
    if not Path("/usr/bin/sandbox-exec").is_file():
        raise RuntimeError("sandbox-exec is required; refusing an unprotected launch")
    source = args.app.resolve()
    original_info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if original_info.get("NSMainNibFile") != "MainMenu" or original_info.get("CFBundleExecutable") != "XRG-ng":
        raise RuntimeError("Expected the shipping XRG-ng executable/MainMenu configuration")
    original_text = text_sections(source / "Contents/MacOS/XRG-ng")
    original_menu = main_menu(source)
    architecture = args.architecture
    slices = subprocess.run(["xcrun", "lipo", "-archs", str(source / "Contents/MacOS/XRG-ng")],
                            check=True, capture_output=True, text=True).stdout.split()
    if architecture not in slices or not set(slices).issubset({"arm64", "x86_64"}):
        raise RuntimeError("App must contain the requested supported architecture")
    arm_host = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True)
    if arm_host.returncode or arm_host.stdout.strip() not in ("0", "1"):
        raise RuntimeError("Cannot determine the host's ARM capability")
    translated = architecture == "x86_64" and arm_host.stdout.strip() == "1"
    command(["/usr/bin/arch", "-" + architecture, "/usr/bin/true"], output / "architecture-availability.log", cwd=root, timeout=10)
    app = output / "XRG-ng.app"
    shutil.copytree(source, app, symlinks=True)
    domain = PRIVATE_PREFIX + str(uuid.uuid4())
    home = Path.home().resolve()
    if any(path.exists() or path.is_symlink() for path in private_home_paths(home, domain)):
        raise RuntimeError("Disposable namespace already exists; refusing to reuse it")
    info = dict(original_info, CFBundleIdentifier=domain)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    library = output / "PackagedSmoke.dylib"
    target = architecture + "-apple-macos26.0"
    command(["xcrun", "clang", "-target", target, "-fobjc-arc", "-c", "Tools/PackagedSmoke/Safety.m", "-o", str(output / "Safety.o")], output / "compile-safety.log", cwd=root)
    command(["xcrun", "swiftc", "-swift-version", "5", "-target", target, "-emit-library", "-module-name", "XRGPackagedSmoke",
             "-import-objc-header", "Tools/PackagedSmoke/Safety.h",
             "-framework", "AppKit", "Tools/PackagedSmoke/Observe.swift", str(output / "Safety.o"), "-o", str(library)], output / "compile-observer.log", cwd=root)
    probe = output / "Probe.app/Contents"
    (probe / "MacOS").mkdir(parents=True)
    (probe / "Info.plist").write_bytes(plistlib.dumps(dict(info, CFBundleExecutable="Probe")))
    # Match the app's slice set so the harmless probe tests the same loader selection.
    probe_archs = [flag for slice_name in slices for flag in ("-arch", slice_name)]
    command(["xcrun", "clang", *probe_archs, "-mmacosx-version-min=26.0", "-fobjc-arc", "-framework", "AppKit", "Tools/PackagedSmoke/Probe.m", "-o", str(probe / "MacOS/Probe")], output / "compile-probe.log", cwd=root)
    probe_slices = subprocess.run(["xcrun", "lipo", "-archs", str(probe / "MacOS/Probe")],
                                 check=True, capture_output=True, text=True).stdout.split()
    if set(probe_slices) != set(slices):
        raise RuntimeError("Preflight executable must match the app's architecture set")
    for name, path in (("library", library), ("probe", probe.parent), ("app", app)):
        command(["codesign", "--force", "--sign", "-", str(path)], output / f"sign-{name}.log", cwd=root)
    # Preflight and app must have the same dynamic-loader eligibility. Never try a protected image.
    for name, path in (("probe", probe.parent), ("app", app)):
        command(["codesign", "--display", "--verbose=2", str(path)], output / f"signature-{name}.log", cwd=root)
        match = re.search(r"flags=0x([0-9a-fA-F]+)", (output / f"signature-{name}.log").read_text())
        if not match or int(match.group(1), 16) != 2:
            raise RuntimeError("Expected a plain ad-hoc signature for both protected test copies")
    if (app / "Contents/MacOS/XRG-ng").stat().st_mode & (stat.S_ISUID | stat.S_ISGID):
        raise RuntimeError("Refusing a privileged executable")
    if text_sections(app / "Contents/MacOS/XRG-ng") != original_text or main_menu(app) != original_menu:
        raise RuntimeError("Signing changed executable text or the original MainMenu resources")
    seed = {"packagedSmokeMarker": domain, "checkForUpdates": False, "isDockIconHidden": True,
            "showWeatherGraph": False, "showStockGraph": False, "showAITokenGraph": False,
            "aiTokensTrackingEnabled": False, "showSensorWindow": False, "graphRefresh": 0.25,
            "windowTitle": "Packaged XRG smoke", "icao": "", "stockSymbols": ""}
    for key in ("showCPUGraph", "showGPUGraph", "showNPUGraph", "showMemoryGraph", "showBatteryGraph", "showTemperatureGraph", "showNetworkGraph", "showDiskGraph"):
        seed[key] = True
    (output / "seed.plist").write_bytes(plistlib.dumps(seed))
    preferences = home / "Library/Preferences" / (domain + ".plist")
    # Preference lookup needs parent-directory metadata, but not directory contents.
    private_paths = [preferences, preferences.with_name(preferences.name.lower())]
    def exclusions(paths):
        return " ".join("(require-not (literal " + json.dumps(str(path)) + "))" for path in paths)
    metadata_paths = private_paths + [home, home / "Library", home / "Library/Preferences", home / "Library/Preferences/ByHost"]
    profile = f'''(version 1)(allow default)(deny network*)
(deny file-read-data (require-all (subpath {json.dumps(str(home))}) {exclusions(private_paths)}))
(deny file-read-metadata (require-all (subpath {json.dumps(str(home))}) {exclusions(metadata_paths)}))'''
    (output / "sandbox.sb").write_text(profile)
    sentinel = tempfile.NamedTemporaryFile(prefix="xrg-packaged-smoke-", dir=home / "Library/Caches", delete=False)
    sentinel.write(b"Disposable sandbox sentinel"); sentinel.close()
    environment = os.environ.copy()
    environment.update(XRG_PACKAGED_SMOKE_DOMAIN=domain, XRG_PACKAGED_SMOKE_ROOT=str(output),
                       XRG_PACKAGED_SMOKE_RESULTS=str(output), XRG_PACKAGED_SMOKE_FORBIDDEN_FILE=sentinel.name,
                       XRG_PACKAGED_SMOKE_ARCH=architecture, XRG_PACKAGED_SMOKE_TRANSLATED=str(int(translated)))
    def launch(binary, log, phase):
        environment["XRG_PACKAGED_SMOKE_PHASE"] = phase
        # env sets DYLD only after the platform-signed sandbox launcher has started.
        command(["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/arch", "-" + architecture,
                 "/usr/bin/env", "DYLD_INSERT_LIBRARIES=" + str(library), str(binary)],
                output / log, cwd=output, env=environment, timeout=60)
    imported = False
    try:
        command(["/usr/bin/defaults", "import", domain, str(output / "seed.plist")], output / "seed-preferences.log", cwd=output)
        imported = True
        (output / "preference-location.json").write_text(json.dumps({"exactFileExists": preferences.exists(),
            "lowercaseFileExists": preferences.with_name(preferences.name.lower()).exists()}, indent=2))
        command(["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/defaults", "read", domain, "packagedSmokeMarker"],
                output / "preflight-preferences.log", cwd=output, timeout=10)
        launch(probe / "MacOS/Probe", "preflight.log", "probe")
        preflight = json.loads((output / "preflight.json").read_text())
        if (preflight != {"architecture": architecture, "translated": translated, "guardChecksPassed": True}
                or preflight["translated"] is not translated or preflight["guardChecksPassed"] is not True):
            raise RuntimeError("Preflight architecture/translation status was not verified")
        reports = []
        for orientation in ("vertical", "horizontal"):
            seed["graphOrientationVertical"] = orientation == "vertical"
            seed["windowIsMinimized"] = False
            (output / "seed.plist").write_bytes(plistlib.dumps(seed))
            command(["/usr/bin/defaults", "import", domain, str(output / "seed.plist")], output / f"preferences-{orientation}.log", cwd=output)
            environment["XRG_PACKAGED_SMOKE_CASE"] = orientation
            for phase in ("seed", "restore"):
                launch(app / "Contents/MacOS/XRG-ng", f"{phase}-{orientation}.log", phase)
                report = json.loads((output / f"{phase}-{orientation}.json").read_text())
                if (report["architecture"] != architecture or report["translated"] is not translated or
                    report["phase"] != phase or report["orientation"] != orientation or report["moduleCount"] != 11 or not all(report[key] for key in
                        ("mainMenuConnected", "productionClassImages", "shippingPriority", "runtimeTimersAdvanced",
                         "preferencesNibLoaded", "sensorsNibLoaded", "windowsHidden", "timersStopped", "appKitTerminationCallback"))):
                    raise RuntimeError("Packaged app verification failed")
                reports.append(report)
        if len({report["pid"] for report in reports}) != 4:
            raise RuntimeError("Expected distinct packaged-app processes")
        if text_sections(app / "Contents/MacOS/XRG-ng") != original_text or main_menu(app) != original_menu:
            raise RuntimeError("Packaged code/resources changed during verification")
        if text_sections(source / "Contents/MacOS/XRG-ng") != original_text or main_menu(source) != original_menu:
            raise RuntimeError("Original build products changed during verification")
        (output / "identity.json").write_text(json.dumps({"architecture": architecture, "translated": translated,
                                                        "textSectionsUnchanged": True, "mainMenuUnchanged": True,
                                                        "originalBuildUnchanged": True, "textAndEntryHashes": original_text,
                                                        "mainMenuHashes": original_menu}, indent=2))
    finally:
        Path(sentinel.name).unlink(missing_ok=True)
        try:
            if imported:
                command(["/usr/bin/defaults", "delete", domain], output / "cleanup.log", cwd=output, timeout=10)
        finally:
            remove_private_artifacts(home, domain)
        (output / "cleanup.json").write_text(json.dumps({"privatePreferencesRemoved": True,
            "privateHomeArtifactsRemoved": True, "sentinelRemoved": not Path(sentinel.name).exists()}, indent=2))
    print(f"PASS: {architecture} (translated={translated}), shipped entry point and original nibs, private preferences removed, network and home-data guards verified", flush=True)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda number, _: sys.exit(128 + number))
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Packaged smoke failed: {error}", file=sys.stderr)
        sys.exit(1)
