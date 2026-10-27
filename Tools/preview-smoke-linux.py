#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Exercise the preview on a runtime-only Linux system, under an unprivileged UID."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command, env, log, success=True, timeout=60):
    result = subprocess.run(list(map(str, command)), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write_text(result.stdout)
    require((result.returncode == 0) == success, f"Unexpected exit {result.returncode}: {command}\n{result.stdout[-4000:]}")
    return result.stdout


def desktop_launch(path):
    # Exercise the desktop environment's actual Exec parser, including field codes.
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
    app = Gio.DesktopAppInfo.new_from_filename(str(path))
    require(app is not None, "GIO rejected the installed desktop entry")
    children = []
    def spawned(_app, pid, _data):
        children.append(pid)
    app.launch_uris_as_manager([], None, GLib.SpawnFlags.DO_NOT_REAP_CHILD,
                               None, None, spawned, None)
    require(len(children) == 1, "Desktop entry did not start one application")
    _, status = os.waitpid(children[0], 0)
    require(os.waitstatus_to_exitcode(status) == 0, f"Desktop launch exited with status {status}")


def decode_icon(path):
    # Use the runtime image's real SVG loader without requiring GTK development
    # tools or the optional GdkPixbuf introspection package.
    library = ctypes.CDLL("libgdk_pixbuf-2.0.so.0")
    library.gdk_pixbuf_new_from_file.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
    library.gdk_pixbuf_new_from_file.restype = ctypes.c_void_p
    pixbuf = library.gdk_pixbuf_new_from_file(os.fsencode(path), None)
    require(pixbuf is not None, f"Runtime cannot decode icon: {path}")
    objects = ctypes.CDLL("libgobject-2.0.so.0")
    objects.g_object_unref.argtypes = [ctypes.c_void_p]
    objects.g_object_unref(pixbuf)


def smoke(args):
    require(platform.system() == "Linux", "This smoke check requires Linux")
    require(os.getuid() != 0, "Run this check as an unprivileged user")
    if not args.allow_toolchain:
        require(not any(shutil.which(t) for t in ["swift", "swiftc", "rustc", "cargo"]), "A build toolchain is on PATH")
        require(not Path("/usr/lib/swift").exists() and not Path("/usr/local/swift").exists(), "Swift is installed in the runtime image")
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=True)
    archive = args.archive.resolve()
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    expected = archive.with_suffix("").with_suffix(".sha256").read_text().split()
    require(expected == [digest, archive.name], "Archive checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="xrg-preview-") as temporary:
        work = Path(temporary)
        env = {k: v for k, v in os.environ.items() if not k.startswith("LD_")}
        env.update(HOME=str(work / "home"), XDG_CONFIG_HOME=str(work / "config"),
                   XDG_DATA_HOME=str(work / "data"), XDG_CACHE_HOME=str(work / "cache"),
                   GSK_RENDERER="cairo")
        Path(env["HOME"]).mkdir()
        config = Path(env["XDG_CONFIG_HOME"])
        for name in ["xrg-ng", "xrg-linux"]:
            (config / name).mkdir(parents=True)
            (config / name / "settings.conf").write_text("preserve this user's settings\n")
        with tarfile.open(archive) as source:
            members = source.getmembers()
            require(len(members) < 5000 and sum(m.size for m in members) < 2_000_000_000, "Oversized archive")
            require(all(m.isfile() or m.isdir() for m in members), "Archive contains links or special files")
            source.extractall(work / "extracted", filter="data")
        roots = list((work / "extracted").iterdir())
        require(len(roots) == 1, "Archive must contain one application directory")
        bundle = roots[0]
        manifest = json.loads((bundle / "manifest.json").read_text())
        require(manifest["architecture"] == platform.machine(), "Package architecture mismatch")
        require(args.allow_dirty or not manifest["dirty"], "CI package must have a clean source snapshot")
        require((bundle / "source.tar.gz").is_file(), "Corresponding source missing")
        require((bundle / "share/doc/xrg-ng/licenses/Swift-toolchain-LICENSE.txt").is_file(), "Swift license missing")
        require((bundle / "share/doc/xrg-ng/licenses/swift-6.4.1/ICU-76.1.txt").is_file(), "ICU notices missing")
        shutil.copy2(bundle / "manifest.json", results / "manifest.json")
        # Relocate before any launch; the CI build and toolchains are absent here.
        moved = work / 'relocated preview $cash % "quotes"'
        bundle.rename(moved)
        bundle = moved
        linked = run(["ldd", bundle / "bin/xrg-ng-linux"], env, results / "ldd.log")
        require("not found" not in linked, "Package has unresolved system dependencies")
        for name in manifest["bundled_libraries"]:
            line = next((line for line in linked.splitlines() if line.strip().startswith(name + " =>")), "")
            resolved = re.search(r"=> (/.+?) \(0x[0-9a-f]+\)", line)
            require(resolved is not None and Path(resolved[1]).resolve() == bundle / "lib" / name,
                    f"Private runtime not used: {name}")
        version = run([bundle / "xrg-ng-linux", "--version"], env, results / "version.log")
        require(version.strip() == f"XRG-ng {manifest['version']}", "Version mismatch")
        run([bundle / "xrg-ng-linux", "--headless", "--samples", "3"], env, results / "headless.log")
        prefix = work / 'installed preview $cash % "quotes"'
        # Refuse unrelated integration files before creating an app installation.
        icon = prefix / "share/icons/hicolor/scalable/apps/com.sdelavega.xrg-ng.svg"
        icon.parent.mkdir(parents=True)
        icon.write_text("unrelated icon")
        run([bundle / "install.sh", "--prefix", prefix], env, results / "collision.log", success=False)
        require(icon.read_text() == "unrelated icon" and not (prefix / "lib/xrg-ng").exists(), "Collision changed existing files")
        icon.unlink()
        legacy = prefix / "bin/xrg-linux"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("legacy application")
        run([bundle / "install.sh", "--prefix", prefix], env, results / "install.log")
        installed = prefix / "lib/xrg-ng"
        launcher = prefix / "bin/xrg-ng-linux"
        run([launcher, "--version"], env, results / "installed-version.log")
        desktop = prefix / "share/applications/com.sdelavega.xrg-ng.desktop"
        run(["desktop-file-validate", desktop], env, results / "desktop-validate.log")
        decode_icon(icon)
        decode_icon(Path("/usr/share/icons/Adwaita/symbolic/categories/preferences-system-symbolic.svg"))
        # Keep Exec quoting exactly as installed; add only the application's smoke flag.
        test_desktop = results / "desktop-smoke.desktop"
        test_desktop.write_text(re.sub(r"^Exec=(.*)$", r"Exec=\1 --smoke-test", desktop.read_text(), flags=re.M))
        gui_env = dict(env, XRG_SMOKE_IMAGE=str(results / "installed-gtk.png"),
                       XRG_SMOKE_PREFS_IMAGE=str(results / "installed-preferences.png"),
                       XRG_SMOKE_PROCESS_IMAGE=str(results / "installed-processes.png"),
                       XRG_SMOKE_AI_IMAGE=str(results / "installed-ai.png"),
                       XRG_SMOKE_AI_SOURCES_IMAGE=str(results / "installed-ai-sources.png"),
                       XRG_SMOKE_WEATHER_IMAGE=str(results / "installed-weather.png"),
                       XRG_SMOKE_MENU_IMAGE=str(results / "installed-menu.png"),
                       XRG_SMOKE_DETAILS_IMAGE=str(results / "installed-details.png"),
                       XRG_SMOKE_IMPORT_IMAGE=str(results / "installed-import.png"),
                       XRG_SMOKE_LAYOUT_IMAGE=str(results / "installed-layout.png"),
                       XRG_SMOKE_NPU_IMAGE=str(results / "installed-npu.png"))
        gtk = run(["dbus-run-session", "--", "xvfb-run", "-a", "--server-args=-screen 0 1280x1400x24",
                   sys.executable, Path(__file__).resolve(), "--desktop", test_desktop], gui_env, results / "desktop-launch.log")
        require("GTK_SMOKE_OK" in gtk, "Installed desktop launch did not finish the GTK smoke flow")
        # Upgrade and then exercise refusal paths without losing the installation.
        run([bundle / "install.sh", "--prefix", prefix], env, results / "upgrade.log")
        before = (installed / ".xrg-ng-install.json").read_bytes()
        desktop.parent.chmod(0o555)
        try:
            run([bundle / "install.sh", "--prefix", prefix], env, results / "rollback.log", success=False)
        finally:
            desktop.parent.chmod(0o755)
        require((installed / ".xrg-ng-install.json").read_bytes() == before and launcher.is_symlink(),
                "Failed upgrade did not restore the previous installation")
        extra = installed / "user-added.txt"
        extra.write_text("preserve me")
        run([bundle / "install.sh", "--prefix", prefix], env, results / "changed-install.log", success=False)
        require(extra.read_text() == "preserve me", "Upgrade removed an unowned file")
        extra.unlink()
        original = desktop.read_bytes()
        desktop.write_bytes(original + b"\n# modified\n")
        run([installed / "uninstall.sh", "--prefix", prefix], env, results / "changed-desktop.log", success=False)
        require(installed.exists() and launcher.is_symlink(), "Refused uninstall partially removed the app")
        desktop.write_bytes(original)
        run([installed / "uninstall.sh", "--prefix", prefix], env, results / "uninstall.log")
        require(not installed.exists() and not launcher.is_symlink() and not desktop.exists() and not icon.exists(), "Uninstall left owned files")
        require(legacy.read_text() == "legacy application", "Legacy application changed")
        for name in ["xrg-ng", "xrg-linux"]:
            require((config / name / "settings.conf").read_text() == "preserve this user's settings\n", "Saved preferences changed")
        run([bundle / "install.sh", "--prefix", work / "invalid\nprefix"], env, results / "invalid-prefix.log", success=False)
    (results / "summary.txt").write_text("LINUX_PREVIEW_SMOKE_OK relocation install desktop-launch upgrade uninstall preservation\n")
    print("LINUX_PREVIEW_SMOKE_OK relocation install desktop-launch upgrade uninstall preservation")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--results", type=Path)
    parser.add_argument("--desktop", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--allow-toolchain", action="store_true", help="Local debugging only")
    parser.add_argument("--allow-dirty", action="store_true", help="Local development package only")
    args = parser.parse_args()
    if args.desktop:
        desktop_launch(args.desktop)
    else:
        if not args.archive or not args.results:
            parser.error("--archive and --results are required")
        smoke(args)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Preview smoke: {error}", file=sys.stderr)
        sys.exit(1)
