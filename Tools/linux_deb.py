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

ARCHITECTURES = {"x86_64": ("amd64", 62), "aarch64": ("arm64", 183)}
APP_ID = "com.sdelavega.xrg-ng"
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


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inventory(bundle):
    files = {}
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f"Native package input must contain regular files/directories: {path}")
        if path.is_file() and path != bundle / "manifest.json":
            files[str(path.relative_to(bundle))] = digest(path)
    return files


def validate(bundle, allow_dirty):
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError("Native package input must be a regular bundle directory")
    files = inventory(bundle)
    manifest = json.loads((bundle / "manifest.json").read_text())
    if not isinstance(manifest, dict) or manifest.get("format") != "xrg-ng-linux-preview" or manifest.get("files") != files:
        raise ValueError("Native package input does not match the preview manifest")
    if type(manifest.get("dirty")) is not bool or (manifest["dirty"] and not allow_dirty):
        raise ValueError("Native CI packages require a clean source snapshot")
    if not isinstance(manifest.get("version"), str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", manifest["version"]):
        raise ValueError("Native previews require an x.y.z application version")
    if not isinstance(manifest.get("revision"), str) or not re.fullmatch(r"[0-9a-f]{40}(?:[0-9a-f]{24})?", manifest["revision"]):
        raise ValueError("Invalid source revision")
    if not isinstance(manifest.get("architecture"), str) or manifest["architecture"] not in ARCHITECTURES:
        raise ValueError("Unsupported native package architecture")
    libraries = manifest.get("bundled_libraries")
    if (not isinstance(libraries, list) or not all(isinstance(n, str) and Path(n).name == n for n in libraries)
            or len(libraries) != len(set(libraries)) or "libXRGSharedCore.so" not in libraries
            or "libswiftCore.so" not in libraries
            or sorted(files.keys() & {f"lib/{n}" for n in libraries}) != sorted(f"lib/{n}" for n in libraries)
            or {p.name for p in (bundle / "lib").iterdir()} != set(libraries)):
        raise ValueError("Private runtime inventory mismatch")
    system = manifest.get("system_libraries")
    if not isinstance(system, list) or not all(isinstance(n, str) for n in system) or "libc.so.6" not in system:
        raise ValueError("Invalid system runtime inventory")
    required = ["xrg-ng-linux", "bin/xrg-ng-linux", "source.tar.gz", "README.md",
                f"share/applications/{APP_ID}.desktop",
                f"share/icons/hicolor/scalable/apps/{APP_ID}.svg",
                "share/doc/xrg-ng/LICENSE", "share/doc/xrg-ng/COPYRIGHT",
                "share/doc/xrg-ng/THIRD_PARTY_NOTICES.md",
                "share/doc/xrg-ng/licenses/Swift-toolchain-LICENSE.txt"]
    if any(name not in files for name in required):
        raise ValueError("Native package is missing required payload/source/notices")
    expected = ARCHITECTURES[manifest["architecture"]][1]
    for path in [bundle / "bin/xrg-ng-linux", *(bundle / "lib").iterdir()]:
        with path.open("rb") as stream:
            header = stream.read(20)
        if (len(header) != 20 or header[:6] != b"\x7fELF\x02\x01"
                or struct.unpack("<H", header[18:20])[0] != expected):
            raise ValueError(f"ELF architecture mismatch: {path}")
    return manifest


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
    if package.exists() or checksum.exists():
        raise ValueError(f"Output already exists: {package}")
    with tempfile.TemporaryDirectory(prefix="xrg-deb-") as temporary:
        stage = Path(temporary) / "root"
        private = stage / "usr/lib/xrg-ng"
        private.mkdir(parents=True)
        stage.chmod(0o755)
        for name in ["bin", "lib"]:
            shutil.copytree(bundle / name, private / name)
        shutil.copy2(bundle / "xrg-ng-linux", private / "xrg-ng-linux")
        launcher = stage / "usr/bin/xrg-ng-linux"
        launcher.parent.mkdir(parents=True)
        launcher.symlink_to("../lib/xrg-ng/xrg-ng-linux")
        docs = stage / "usr/share/doc/xrg-ng"
        shutil.copytree(bundle / "share/doc/xrg-ng", docs)
        for source, name in [("source.tar.gz", "source.tar.gz"), ("manifest.json", "bundle-manifest.json"),
                             ("README.md", "README.preview")]:
            shutil.copy2(bundle / source, docs / name)
        shutil.copy2(docs / "COPYRIGHT", docs / "copyright")
        for name in [f"applications/{APP_ID}.desktop", f"icons/hicolor/scalable/apps/{APP_ID}.svg"]:
            dest = stage / "usr/share" / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(bundle / "share" / name, dest)
        desktop = stage / f"usr/share/applications/{APP_ID}.desktop"
        desktop.write_text(desktop.read_text().replace("Exec=xrg-ng-linux\n", "Exec=/usr/bin/xrg-ng-linux\n"))
        subprocess.run(["desktop-file-validate", str(desktop)], check=True)
        (docs / "native-package.json").write_text(json.dumps({
            "format": "xrg-ng-linux-deb", "version": deb_version, "architecture": arch,
            "revision": manifest["revision"], "dirty": manifest["dirty"], "source_epoch": epoch,
            "bundle_manifest_sha256": digest(bundle / "manifest.json"),
            "source_archive_sha256": digest(bundle / "source.tar.gz"),
        }, indent=2) + "\n")
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
