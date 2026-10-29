#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Install/upgrade/remove a native preview in a disposable runtime-only container."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import pwd
import re
import shutil
import subprocess
import tarfile
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(command, log, *, env=None, timeout=180):
    result = subprocess.run(list(map(str, command)), text=True, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
    log.write_text(result.stdout)
    require(result.returncode == 0, f"Exit {result.returncode}: {command}\n{result.stdout[-3000:]}")
    return result.stdout


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def smoke(args):
    require(args.disposable_system and platform.system() == "Linux" and os.getuid() == 0
            and Path("/.dockerenv").is_file(), "Use root only inside a disposable Docker runtime container")
    require(not any(shutil.which(t) for t in ["swift", "swiftc", "rustc", "cargo"])
            and not Path("/usr/lib/swift").exists() and not Path("/usr/local/swift").exists(),
            "Build toolchains must be absent")
    user = pwd.getpwnam(args.user)
    require(user.pw_uid != 0, "Application launch must use an unprivileged UID")
    state = subprocess.run(["dpkg-query", "-W", "-f=${Status}", "xrg-ng"], text=True, capture_output=True)
    require(state.returncode != 0 or state.stdout == "unknown ok not-installed", "Container already has xrg-ng package state")
    for name in ["/usr/lib/xrg-ng", "/usr/bin/xrg-ng-linux", "/usr/share/doc/xrg-ng",
                 "/usr/share/applications/com.sdelavega.xrg-ng.desktop",
                 "/usr/share/icons/hicolor/scalable/apps/com.sdelavega.xrg-ng.svg"]:
        require(not Path(name).exists() and not Path(name).is_symlink(), f"Container already has {name}")
    results = args.results.resolve()
    results.mkdir(parents=True, exist_ok=True)
    os.chown(results, user.pw_uid, user.pw_gid)
    package = args.package.resolve()
    require(package.with_suffix(".deb.sha256").read_text().split() == [digest(package), package.name],
            "Native package checksum mismatch")
    fields = {}
    for field in ["Package", "Version", "Architecture", "Depends"]:
        fields[field] = run(["dpkg-deb", "--field", package, field], results / f"control-{field}.log").strip()
    require(fields["Package"] == "xrg-ng", "Unexpected package name")
    require(fields["Architecture"] == {"x86_64": "amd64", "aarch64": "arm64"}[platform.machine()], "Architecture mismatch")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:~preview\.[A-Za-z0-9.]+)?-[0-9]+", fields["Version"]), "Unexpected package version")
    require(not any(name in fields["Depends"] for name in ["swift", "rustc", "cargo", "python", "libgtk", "libglib", "libcairo"]),
            "Unexpected native application dependency")
    # Inspect archive metadata before allowing a system-wide install.
    data = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", package])
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            require(not path.is_absolute() and ".." not in path.parts
                    and (str(path) == "." or path.parts[0] == "usr"), "Payload escapes /usr")
            require(member.uid == member.gid == 0, "Payload is not root-owned")
            require(member.isfile() or member.isdir() or (
                member.issym() and str(path) == "usr/bin/xrg-ng-linux"
                and member.linkname == "../lib/xrg-ng/xrg-ng-linux"), "Unexpected package link/special file")
    del data
    with tempfile.TemporaryDirectory(prefix="xrg-deb-smoke-") as temporary:
        work = Path(temporary)
        os.chown(work, user.pw_uid, user.pw_gid)
        # The package must have no maintainer scripts or system configuration.
        run(["dpkg-deb", "--control", package, work / "control"], results / "control-extract.log")
        require({p.name for p in (work / "control").iterdir()} == {"control", "md5sums"}, "Unexpected maintainer script/configuration")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("LD_", "DYLD_"))}
        paths = {"HOME": work / "home", "XDG_CONFIG_HOME": work / "config",
                 "XDG_DATA_HOME": work / "data", "XDG_CACHE_HOME": work / "cache"}
        for path in paths.values():
            path.mkdir()
            os.chown(path, user.pw_uid, user.pw_gid)
        preserved = []
        for name in ["xrg-ng", "xrg-linux"]:
            path = paths["XDG_CONFIG_HOME"] / name / "settings.conf"
            path.parent.mkdir()
            path.write_text("preserve this user's settings\n")
            os.chown(path.parent, user.pw_uid, user.pw_gid)
            os.chown(path, user.pw_uid, user.pw_gid)
            preserved.append((path, path.read_bytes()))
        # Existing per-user/legacy launchers belong to a different install path.
        shadow = paths["HOME"] / ".local/bin/xrg-ng-linux"
        shadow.parent.mkdir(parents=True)
        shadow.write_text("#!/bin/sh\necho unrelated-user-install\nexit 23\n")
        shadow.chmod(0o755)
        legacy = paths["HOME"] / ".local/bin/xrg-linux"
        legacy.write_text("legacy application\n")
        preserved.extend([(shadow, shadow.read_bytes()), (legacy, legacy.read_bytes())])
        child_env = dict(**{k: str(v) for k, v in paths.items()}, LANG="C.UTF-8",
                         PATH=f"{shadow.parent}:/usr/local/bin:/usr/bin:/bin", LIBGL_ALWAYS_SOFTWARE="1")

        def app(command, name, extra=None):
            settings = dict(child_env, **(extra or {}))
            # runuser resets HOME; set the test environment after changing UID.
            return run(["runuser", "-u", args.user, "--", "env", "-i",
                        *(f"{k}={v}" for k, v in settings.items()), *map(str, command)],
                       results / name, env=env, timeout=90)

        try:
            # Ubuntu's minimal Docker image excludes /usr/share/doc/* by
            # default. Retain this package's source/notices for full verification
            # without changing the container's global dpkg configuration.
            install = ["apt-get", "-o", "DPkg::Options::=--path-include=/usr/share/doc/xrg-ng",
                       "-o", "DPkg::Options::=--path-include=/usr/share/doc/xrg-ng/*",
                       "install", "-y", "--no-install-recommends"]
            run([*install, package], results / "install.log")
            require(not run(["dpkg", "--verify", "xrg-ng"], results / "verify.log").strip(), "Installed package verification failed")
            docs = Path("/usr/share/doc/xrg-ng")
            manifest = json.loads((docs / "bundle-manifest.json").read_text())
            native = json.loads((docs / "native-package.json").read_text())
            require(native["revision"] == manifest["revision"] and not native["dirty"]
                    and native["version"] == fields["Version"]
                    and native["architecture"] == fields["Architecture"]
                    and manifest["architecture"] == platform.machine()
                    and manifest.get("source_epoch", native["source_epoch"]) == native["source_epoch"],
                    "Source provenance mismatch")
            require(native["bundle_manifest_sha256"] == digest(docs / "bundle-manifest.json")
                    and native["source_archive_sha256"] == digest(docs / "source.tar.gz")
                    and manifest["files"]["source.tar.gz"] == digest(docs / "source.tar.gz"), "Source/manifest hashes changed")
            shutil.copy2(docs / "native-package.json", results / "native-package.json")
            require(app(["/usr/bin/xrg-ng-linux", "--version"], "version.log").strip() == f"XRG-ng {manifest['version']}", "Installed version mismatch")
            app(["/usr/bin/xrg-ng-linux", "--headless", "--samples", "3"], "headless.log")
            linked = app(["ldd", "/usr/lib/xrg-ng/bin/xrg-ng-linux"], "ldd.log")
            require("not found" not in linked, "Missing installed runtime dependency")
            for name in manifest["bundled_libraries"]:
                require(re.search(rf"^\s*{re.escape(name)} => /usr/lib/xrg-ng/(?:bin/\.\./)?lib/{re.escape(name)} ", linked, re.M), f"Private runtime not resolved: {name}")
            require(not any(line.strip().startswith(("libgtk-", "libgdk-", "libgsk-", "libglib-", "libgobject-", "libgio-", "libcairo", "libpango")) for line in linked.splitlines()), "Forbidden frontend library")
            desktop = Path("/usr/share/applications/com.sdelavega.xrg-ng.desktop")
            run(["desktop-file-validate", desktop], results / "desktop-validate.log")
            require("Exec=/usr/bin/xrg-ng-linux\n" in desktop.read_text(), "Desktop entry must bypass user PATH shadowing")
            test_desktop = work / "smoke.desktop"
            test_desktop.write_text(desktop.read_text().replace("Exec=/usr/bin/xrg-ng-linux\n", "Exec=/usr/bin/xrg-ng-linux --smoke-test\n"))
            launch = ["dbus-run-session", "--", "xvfb-run", "-a", "--server-args=-screen 0 1280x1400x24",
                      "python3", Path(__file__).with_name("preview-smoke-linux.py").resolve(), "--desktop", test_desktop]
            gui = app(launch, "desktop-launch.log", {"XRG_SMOKE_IMAGE": str(results / "installed-egui.png")})
            require("EGUI_SMOKE_OK" in gui, "Native desktop smoke failed")
            chooser = app(launch, "file-picker.log", {"XRG_SMOKE_FILE_PICKER": "1", "XRG_SMOKE_FILE_PICKER_IMAGE": str(results / "installed-file-picker.png")})
            require("EGUI_FILE_PICKER_SMOKE_OK" in chooser, "Native chooser smoke failed")
            # A control-only higher packaging revision exercises dpkg's upgrade
            # path without pretending the application binary itself changed.
            stage = work / "upgrade"
            run(["dpkg-deb", "--raw-extract", package, stage], results / "upgrade-extract.log")
            control = stage / "DEBIAN/control"
            newer = fields["Version"] + ".test1"
            control.write_text(re.sub(r"^Version: .*", f"Version: {newer}", control.read_text(), flags=re.M))
            run(["dpkg", "--compare-versions", newer, "gt", fields["Version"]], results / "upgrade-order.log")
            upgraded = work / "upgrade.deb"
            run(["dpkg-deb", "--root-owner-group", "--build", stage, upgraded], results / "upgrade-build.log")
            run([*install, upgraded], results / "upgrade.log")
            require(run(["dpkg-query", "-W", "-f=${Version}", "xrg-ng"], results / "upgrade-version.log").strip() == newer, "Upgrade did not apply")
            require(not run(["dpkg", "--verify", "xrg-ng"], results / "upgrade-verify.log").strip(), "Upgraded payload changed")
            app(["/usr/bin/xrg-ng-linux", "--version"], "upgraded-launch.log")
            run(["apt-get", "remove", "-y", "xrg-ng"], results / "remove.log")
            run(["dpkg", "--purge", "xrg-ng"], results / "purge.log")
            for path, content in preserved:
                require(path.read_bytes() == content, f"User/legacy data changed: {path}")
            for name in ["/usr/bin/xrg-ng-linux", "/usr/lib/xrg-ng", "/usr/share/doc/xrg-ng",
                         "/usr/share/applications/com.sdelavega.xrg-ng.desktop",
                         "/usr/share/icons/hicolor/scalable/apps/com.sdelavega.xrg-ng.svg"]:
                require(not Path(name).exists() and not Path(name).is_symlink(), f"Removal left package payload: {name}")
        finally:
            # Only this disposable container's initially absent package is ours.
            subprocess.run(["dpkg", "--purge", "xrg-ng"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    summary = "LINUX_DEB_SMOKE_OK apt-dependencies unprivileged-launch desktop chooser packaging-upgrade remove purge preservation\n"
    (results / "summary.txt").write_text(summary)
    print(summary.strip())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--user", default="xrg-preview")
    parser.add_argument("--disposable-system", action="store_true")
    try:
        smoke(parser.parse_args())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Native package smoke: {error}\n")
