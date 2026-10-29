# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Shared verified payload and provenance for Linux distribution formats."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess

ARCHITECTURES = {"x86_64": ("amd64", 62), "aarch64": ("arm64", 183)}
APP_ID = "com.sdelavega.xrg-ng"

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


def stage_payload(bundle, stage, manifest, epoch, kind, package_version, arch):
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
        "format": kind, "version": package_version, "architecture": arch,
        "revision": manifest["revision"], "dirty": manifest["dirty"], "source_epoch": epoch,
        "bundle_manifest_sha256": digest(bundle / "manifest.json"),
        "source_archive_sha256": digest(bundle / "source.tar.gz"),
    }, indent=2) + "\n")
