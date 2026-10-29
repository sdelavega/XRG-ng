#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Native RPM/ALPM install tests and FUSE-free AppImage execution tests."""
import argparse
import json
import os
from pathlib import Path
import platform
import pwd
import re
import select
import shutil
import subprocess
import sys
import tarfile
import tempfile
from linux_bundle import digest


def require(value, message):
    if not value:
        raise RuntimeError(message)


def pacman_test_config(original, destination):
    text = original.read_text()
    # Official minimal Arch containers omit documentation. Extend only active
    # NoExtract lists with package-specific negative matches; retain every
    # other option, repository and signature policy byte for byte.
    text = re.sub(r"(?m)^(\s*NoExtract\s*=.*)$",
                  r"\1 !usr/share/doc/xrg-ng !usr/share/doc/xrg-ng/*", text)
    destination.write_text(text)
    return destination


def gui(binary, extra):
    read, write = os.pipe()
    display = subprocess.Popen(["Xvfb", "-displayfd", str(write), "-screen", "0", "1280x1400x24",
                                "-nolisten", "tcp", "-ac"], pass_fds=(write,), stdout=subprocess.DEVNULL)
    os.close(write)
    try:
        require(select.select([read], [], [], 15)[0], "Xvfb did not start")
        number = os.read(read, 64).decode().strip()
        require(number.isdecimal(), "Invalid Xvfb display")
        env = dict(os.environ, DISPLAY=f":{number}")
        result = subprocess.run(["dbus-run-session", "--", binary, *extra, "--smoke-test"], env=env, timeout=60)
        require(result.returncode == 0, "Native GUI smoke failed")
    finally:
        os.close(read)
        display.terminate()
        display.wait(timeout=10)


def smoke(args):
    require(args.disposable_system and os.getuid() == 0 and Path("/.dockerenv").exists(), "Use a disposable Docker container")
    require(not any(shutil.which(n) for n in ["swift", "swiftc", "rustc", "cargo"]), "Application toolchains must be absent")
    user = pwd.getpwnam(args.user)
    require(user.pw_uid != 0, "Application must run as an ordinary user")
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=True)
    os.chown(results, user.pw_uid, user.pw_gid)
    package = args.package.resolve()
    require(Path(str(package) + ".sha256").read_text().split() == [digest(package), package.name], "Package checksum mismatch")

    def run(command, name, *, cwd=None, timeout=240):
        result = subprocess.run(list(map(str, command)), text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, cwd=cwd, timeout=timeout)
        (results / name).write_text(result.stdout)
        require(result.returncode == 0, f"Exit {result.returncode}: {command}\n{result.stdout[-3000:]}")
        return result.stdout

    with tempfile.TemporaryDirectory(prefix="xrg-format-smoke-") as temporary:
        work = Path(temporary)
        os.chown(work, user.pw_uid, user.pw_gid)
        environment = {"HOME": str(work / "home"), "XDG_CONFIG_HOME": str(work / "config"),
                       "XDG_DATA_HOME": str(work / "data"), "XDG_CACHE_HOME": str(work / "cache"),
                       "LANG": "C.UTF-8", "PATH": "/usr/local/bin:/usr/bin:/bin", "LIBGL_ALWAYS_SOFTWARE": "1"}
        for name in ["HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"]:
            p = Path(environment[name]); p.mkdir(); os.chown(p, user.pw_uid, user.pw_gid)
        saved = []
        for name in ["xrg-ng", "xrg-linux"]:
            p = Path(environment["XDG_CONFIG_HOME"]) / name / "settings.conf"
            p.parent.mkdir(); p.write_text("preserve this user's settings\n")
            os.chown(p.parent, user.pw_uid, user.pw_gid); os.chown(p, user.pw_uid, user.pw_gid)
            saved.append((p, p.read_bytes()))
        legacy = Path(environment["HOME"]) / "legacy-xrg"
        legacy.write_text("legacy installation sentinel\n"); saved.append((legacy, legacy.read_bytes()))

        def app(command, name, extra=None):
            env = dict(environment, **(extra or {}))
            return run(["runuser", "-u", args.user, "--", "env", "-i",
                        *(f"{k}={v}" for k, v in env.items()), *map(str, command)], name, cwd=work, timeout=100)

        native = args.format != "appimage"
        if native:
            for p in ["/usr/lib/xrg-ng", "/usr/bin/xrg-ng-linux", "/usr/share/doc/xrg-ng"]:
                require(not Path(p).exists() and not Path(p).is_symlink(), f"Pre-existing package path: {p}")
            if args.format == "rpm":
                require(subprocess.run(["rpm", "-q", "xrg-ng"], capture_output=True).returncode != 0, "Pre-existing RPM")
                scripts = run(["rpm", "-qp", "--scripts", package], "scripts.log")
                require(not scripts.strip(), "Unexpected RPM install scripts")
                # Fedora's minimal image defaults to tsflags=nodocs. Retain
                # this package's source/notices for complete verification.
                run(["dnf", "--setopt=tsflags=", "install", "-y", package], "install.log")
                verify = ["rpm", "-V", "xrg-ng"]
            else:
                require(subprocess.run(["pacman", "-Q", "xrg-ng"], capture_output=True).returncode != 0, "Pre-existing ALPM package")
                config = pacman_test_config(Path("/etc/pacman.conf"), work / "pacman.conf")
                run(["pacman", "--config", config, "--disable-sandbox", "-U", "--noconfirm", package], "install.log")
                verify = ["pacman", "-Qkk", "xrg-ng"]
            root = Path("/")
            binary = Path("/usr/bin/xrg-ng-linux")
            extra_args = []
        else:
            image = work / 'relocated XRG $cash %.AppImage'
            shutil.copy2(package, image); image.chmod(0o755); os.chown(image, user.pw_uid, user.pw_gid)
            app([image, "--appimage-extract"], "extract.log")
            root = work / "squashfs-root"
            require((root / "AppRun").is_file() and (root / ".DirIcon").is_symlink(), "Incomplete AppDir")
            binary, extra_args = image, ["--appimage-extract-and-run"]
            require((root / "usr/share/doc/xrg-ng/appimage-runtime-source.tar.gz").is_file(), "Runtime source/notices missing")
            app([image, "--appimage-version"], "runtime-version.log")

        try:
            docs = root / "usr/share/doc/xrg-ng"
            manifest = json.loads((docs / "bundle-manifest.json").read_text())
            meta = json.loads((docs / "native-package.json").read_text())
            require(not meta["dirty"] and meta["revision"] == manifest["revision"]
                    and manifest["architecture"] == platform.machine(), "Source/architecture mismatch")
            require(digest(docs / "source.tar.gz") == meta["source_archive_sha256"]
                    and digest(docs / "bundle-manifest.json") == meta["bundle_manifest_sha256"], "Provenance hash mismatch")
            # Verify that wrapping preserved every runtime and license byte from
            # the tested bundle, independently of each package manager's hashes.
            for name, expected in manifest["files"].items():
                if name.startswith(("bin/", "lib/")) or name == "xrg-ng-linux":
                    installed = root / "usr/lib/xrg-ng" / name
                elif name.startswith("share/doc/xrg-ng/"):
                    installed = root / "usr" / name
                else:
                    continue
                require(installed.is_file() and digest(installed) == expected, f"Wrapped payload changed: {name}")
            shutil.copy2(docs / "native-package.json", results / "native-package.json")
            require(app([binary, *extra_args, "--version"], "version.log").strip() == f"XRG-ng {manifest['version']}", "Application version mismatch")
            app([binary, *extra_args, "--headless", "--samples", "3"], "headless.log")
            for picker in [False, True]:
                extra = {"XRG_SMOKE_FILE_PICKER": "1", "XRG_SMOKE_FILE_PICKER_IMAGE": str(results / "file-picker.png")} if picker else {"XRG_SMOKE_IMAGE": str(results / "dashboard.png")}
                text = app(["python3", Path(__file__).resolve(), "--gui", binary, *extra_args],
                           "chooser.log" if picker else "gui.log", extra)
                require(("EGUI_FILE_PICKER_SMOKE_OK" if picker else "EGUI_SMOKE_OK") in text, "GUI gate did not complete")
            if native:
                run(verify, "verify.log")
                require(args.archive is not None, "An archive is required for the packaging-only upgrade fixture")
                archive = args.archive.resolve()
                require(archive.with_suffix("").with_suffix(".sha256").read_text().split() == [digest(archive), archive.name], "Fixture archive checksum mismatch")
                with tarfile.open(archive) as source:
                    require(all(m.isfile() or m.isdir() for m in source.getmembers()), "Unsafe fixture archive")
                    source.extractall(work / "bundle", filter="data")
                bundle = next((work / "bundle").iterdir())
                from linux_formats import build_rpm, build_arch
                if args.format == "rpm":
                    # Added only after proving the runtime-only initial install.
                    run(["dnf", "install", "-y", "rpm-build"], "upgrade-tools.log")
                    upgraded, _ = build_rpm(bundle, work / "upgrade", manifest["source_epoch"], revision=2)
                    run(["dnf", "--setopt=tsflags=", "install", "-y", upgraded], "upgrade.log")
                    release = run(["rpm", "-q", "--queryformat", "%{RELEASE}", "xrg-ng"], "upgrade-version.log").strip()
                    require(release == "2" or release.endswith(".2"), "RPM upgrade did not apply")
                    run(verify, "upgraded-verify.log")
                    run(["dnf", "remove", "-y", "xrg-ng"], "remove.log")
                else:
                    upgraded, _ = build_arch(bundle, work / "upgrade", manifest["source_epoch"], revision=2)
                    comparison = int(run(["vercmp", manifest["version"], meta["version"].rsplit("-", 1)[0]], "version-order.log").strip())
                    require(comparison == 0 if manifest.get("channel") == "release" else comparison > 0,
                            "Unexpected Arch release/preview version ordering")
                    run(["pacman", "--config", config, "--disable-sandbox", "-U", "--noconfirm", upgraded], "upgrade.log")
                    require(run(["pacman", "-Q", "xrg-ng"], "upgrade-version.log").strip().endswith("-2"), "ALPM upgrade did not apply")
                    run(verify, "upgraded-verify.log")
                    run(["pacman", "-R", "--noconfirm", "xrg-ng"], "remove.log")
                for p in ["/usr/bin/xrg-ng-linux", "/usr/lib/xrg-ng", "/usr/share/doc/xrg-ng",
                          "/usr/share/applications/com.sdelavega.xrg-ng.desktop",
                          "/usr/share/icons/hicolor/scalable/apps/com.sdelavega.xrg-ng.svg"]:
                    require(not Path(p).exists() and not Path(p).is_symlink(), f"Removal left payload: {p}")
            for path, content in saved:
                require(path.read_bytes() == content, f"User data changed: {path}")
        finally:
            if native:
                subprocess.run(["rpm", "-e", "xrg-ng"] if args.format == "rpm" else ["pacman", "-R", "--noconfirm", "xrg-ng"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    message = f"LINUX_FORMAT_SMOKE_OK format={args.format} unprivileged-launch gui chooser preservation"
    (results / "summary.txt").write_text(message + "\n")
    print(message)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--gui":
        gui(sys.argv[2], sys.argv[3:])
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument("--format", choices=["rpm", "arch", "appimage"], required=True)
        parser.add_argument("--package", type=Path, required=True)
        parser.add_argument("--archive", type=Path)
        parser.add_argument("--results", type=Path, required=True)
        parser.add_argument("--user", default="xrg-preview")
        parser.add_argument("--disposable-system", action="store_true")
        try:
            smoke(parser.parse_args())
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            parser.exit(1, f"Format smoke: {error}\n")
