#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Build an Ubuntu preview .deb from the exact, verified archive payload."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile
from linux_bundle import APP_ID, ARCHITECTURES, digest, inventory, validate, stage_payload

SYSTEM_PACKAGES = {
    "libc.so.6": "libc6", "libm.so.6": "libc6", "libdl.so.2": "libc6",
    "libpthread.so.0": "libc6", "librt.so.1": "libc6",
    "libgcc_s.so.1": "libgcc-s1", "libstdc++.so.6": "libstdc++6",
}
# eframe loads window/graphics libraries dynamically; ELF dependency scanning
# alone cannot discover them. curl is used by the optional weather collector.
RUNTIME_PACKAGES = ["libgl1", "libegl1", "libgl1-mesa-dri", "libxkbcommon0",
                    "libxkbcommon-x11-0", "libwayland-client0", "libwayland-cursor0",
                    "libwayland-egl1", "libx11-6", "libxcursor1", "libxi6", "libxrandr2",
                    "curl", "ca-certificates"]


def version(manifest, epoch, revision):
    if type(epoch) is not int or not 0 <= epoch <= 0xffffffff:
        raise ValueError("Invalid source commit timestamp")
    if type(revision) is not int or not 1 <= revision <= 999999:
        raise ValueError("Debian revision must be between 1 and 999999")
    dirty = ".dirty" if manifest["dirty"] else ""
    return f"{manifest['version']}~preview.{epoch}.g{manifest['revision'][:12]}{dirty}-{revision}"


def dependencies(manifest):
    unknown = set(manifest["system_libraries"]) - SYSTEM_PACKAGES.keys()
    if unknown:
        raise ValueError(f"Unmapped native system libraries: {sorted(unknown)}")
    result = []
    for package in sorted({SYSTEM_PACKAGES[n] for n in manifest["system_libraries"]}):
        value = subprocess.check_output(["dpkg-query", "-W", "-f=${Version}", package], text=True).strip()
        if not re.fullmatch(r"[0-9][A-Za-z0-9.+:~\-]*", value):
            raise ValueError(f"Invalid installed dependency version: {package}")
        result.append(f"{package} (>= {value})")
    return ", ".join(result + RUNTIME_PACKAGES)


def build_deb(bundle, output, epoch, *, revision=1, allow_dirty=False):
    manifest = validate(bundle, allow_dirty)
    if "source_epoch" in manifest and (type(manifest["source_epoch"]) is not int or manifest["source_epoch"] != epoch):
        raise ValueError("Source commit timestamp does not match the bundle")
    arch = ARCHITECTURES[manifest["architecture"]][0]
    if subprocess.check_output(["dpkg", "--print-architecture"], text=True).strip() != arch:
        raise ValueError("Build native Debian packages on the matching architecture")
    release = dict(line.split("=", 1) for line in Path("/etc/os-release").read_text().splitlines() if "=" in line)
    if release.get("ID", "").strip('"') != "ubuntu" or release.get("VERSION_ID", "").strip('"') != "24.04":
        raise ValueError("Native preview packages currently target Ubuntu 24.04")
    deb_version = version(manifest, epoch, revision)
    output.mkdir(parents=True, exist_ok=True)
    package = output / f"xrg-ng_{deb_version}_{arch}.deb"
    checksum = package.with_suffix(".deb.sha256")
    if package.exists() or package.is_symlink() or checksum.exists() or checksum.is_symlink():
        raise ValueError(f"Output already exists: {package}")
    with tempfile.TemporaryDirectory(prefix="xrg-deb-") as temporary:
        stage = Path(temporary) / "root"
        stage_payload(bundle, stage, manifest, epoch, "xrg-ng-linux-deb", deb_version, arch)
        private = stage / "usr/lib/xrg-ng"
        control = stage / "DEBIAN"
        control.mkdir()
        size = int(subprocess.check_output(["du", "-sk", "--exclude=DEBIAN", str(stage)], text=True).split()[0])
        (control / "control").write_text(
            f"Package: xrg-ng\nVersion: {deb_version}\nArchitecture: {arch}\n"
            "Maintainer: Stephen de la Vega <sdelavega@users.noreply.github.com>\n"
            "Section: utils\nPriority: optional\n"
            f"Installed-Size: {size}\nDepends: {dependencies(manifest)}\n"
            "Homepage: https://github.com/sdelavega/XRG-ng\n"
            "Description: system resource monitor (Linux preview)\n"
            " Rust/Swift and egui system graphs, process tools and AI monitoring.\n"
            " Includes its private Swift runtime and corresponding project sources.\n")
        checks = []
        for path in sorted(stage.rglob("*")):
            if path.is_symlink():
                continue
            path.chmod(0o755 if path.is_dir() or path.is_relative_to(private) else 0o644)
            os.utime(path, (epoch, epoch))
            if path.is_file() and not path.is_relative_to(control):
                with path.open("rb") as stream:
                    md5 = hashlib.file_digest(stream, "md5").hexdigest()
                checks.append(f"{md5}  {path.relative_to(stage)}\n")
        (control / "md5sums").write_text("".join(checks))
        (control / "md5sums").chmod(0o644)
        env = dict(os.environ, SOURCE_DATE_EPOCH=str(epoch))
        # No maintainer scripts, root privileges, fakeroot or ldconfig changes.
        prepared = Path(temporary) / "prepared.deb"
        subprocess.run(["dpkg-deb", "--root-owner-group", "--threads-max=2", "-Zxz", "-z3",
                        "--build", str(stage), str(prepared)], env=env, check=True)
        shutil.move(prepared, package)
    checksum.write_text(f"{digest(package)}  {package.name}\n")
    return package, checksum
