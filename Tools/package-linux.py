#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Package an already-tested native Linux GTK release and its corresponding source."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def machine(path):
    with path.open("rb") as stream:
        header = stream.read(20)
    if len(header) != 20 or header[:6] != b"\x7fELF\x02\x01":
        raise ValueError(f"Expected a little-endian 64-bit ELF file: {path}")
    return {62: "x86_64", 183: "aarch64"}.get(struct.unpack("<H", header[18:20])[0])


def dependencies(path, env):
    output = run("ldd", str(path), env=env)
    if "not found" in output:
        raise ValueError(f"Unresolved libraries for {path}:\n{output}")
    result = {}
    for line in output.splitlines():
        match = re.match(r"\s*(\S+) => (/.+?) \(0x[0-9a-f]+\)", line)
        if match:
            result[match[1]] = Path(match[2]).resolve()
    return result


def make_tar(directory, archive):
    with tarfile.open(archive, "w:gz", compresslevel=6) as output:
        output.add(directory, arcname=directory.name)


def package(args):
    if platform.system() != "Linux" or platform.machine() not in ["x86_64", "aarch64"]:
        raise ValueError("Build natively on x86_64 or aarch64 Linux")
    arch = platform.machine()
    binary, library = args.binary.resolve(), args.swift_library.resolve()
    if library.name != "libXRGSharedCore.so":
        raise ValueError("--swift-library must name the tested libXRGSharedCore.so")
    for path in [binary, library]:
        if machine(path) != arch:
            raise ValueError(f"ELF architecture does not match this host: {path}")
    status = run("git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=all")
    if status and not args.allow_dirty:
        raise ValueError("Package a clean committed checkout, or use --allow-dirty for local development")
    revision = run("git", "-C", str(ROOT), "rev-parse", "HEAD")
    metadata = json.loads(run("cargo", "metadata", "--manifest-path", str(ROOT / "xrg-linux/rust/Cargo.toml"),
                              "--locked", "--all-features", "--format-version", "1"))
    project = next(p for p in metadata["packages"] if p["name"] == "xrg-ng-linux" and p["source"] is None)
    target = json.loads(run("swiftc", "-print-target-info"))
    if target["target"]["arch"] != arch or "6.4.1" not in target["compilerVersion"]:
        raise ValueError("This packaging configuration and runtime notices require native Swift 6.4.1")
    runtime_paths = [Path(p).resolve() for p in target["paths"]["runtimeLibraryPaths"]]
    env = {k: v for k, v in os.environ.items() if k not in ["LD_PRELOAD", "LD_AUDIT", "LD_LIBRARY_PATH"]}
    build_env = dict(env, LD_LIBRARY_PATH=os.pathsep.join(map(str, [library.parent, *runtime_paths])))
    linked = dependencies(binary, build_env)
    if "libgtk-4.so.1" not in linked or linked.get(library.name) != library:
        raise ValueError("The binary must link GTK4 and the exact supplied Swift library")
    linked.update(dependencies(library, build_env))
    bundled = {name: path for name, path in linked.items()
               if path == library or any(path.is_relative_to(p) for p in runtime_paths)}
    if "libswiftCore.so" not in bundled:
        raise ValueError("Swift runtime dependency discovery failed")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    label = f"xrg-ng-{project['version']}-linux-{arch}-preview"
    archive = output / f"{label}.tar.gz"
    checksum = output / f"{label}.sha256"
    if archive.exists() or checksum.exists():
        raise ValueError(f"Output already exists: {archive}")
    with tempfile.TemporaryDirectory(prefix="xrg-package-") as temporary:
        work = Path(temporary)
        bundle = work / label
        (bundle / "bin").mkdir(parents=True)
        (bundle / "lib").mkdir()
        docs = bundle / "share/doc/xrg-ng"
        docs.mkdir(parents=True)
        shutil.copy2(binary, bundle / "bin/xrg-ng-linux")
        run("patchelf", "--set-rpath", "$ORIGIN/../lib", str(bundle / "bin/xrg-ng-linux"))
        for name, path in sorted(bundled.items()):
            if "/" in name or machine(path) != arch:
                raise ValueError(f"Unsupported runtime dependency: {name}")
            dest = bundle / "lib" / name
            shutil.copy2(path, dest)
            run("patchelf", "--set-rpath", "$ORIGIN", str(dest))
        # Verify closure after removing every build/toolchain search path.
        for elf in [bundle / "bin/xrg-ng-linux", *(bundle / "lib").iterdir()]:
            expected = "$ORIGIN/../lib" if elf.parent.name == "bin" else "$ORIGIN"
            if run("patchelf", "--print-rpath", str(elf)) != expected:
                raise ValueError(f"Non-relocatable library path: {elf}")
            for name, path in dependencies(elf, env).items():
                if name in bundled and path.parent != bundle / "lib":
                    raise ValueError(f"Runtime escaped the bundle: {name} => {path}")
        for name in ["install.sh", "uninstall.sh", "integration.py"]:
            shutil.copy2(ROOT / "xrg-linux/preview" / name, bundle / name)
        launcher = bundle / "xrg-ng-linux"
        launcher.write_text((ROOT / "xrg-linux/preview/xrg-ng-linux").read_text().replace("@ARCH@", arch))
        for path in [launcher, bundle / "install.sh", bundle / "uninstall.sh", bundle / "bin/xrg-ng-linux"]:
            path.chmod(0o755)
        desktop = bundle / "share/applications/com.sdelavega.xrg-ng.desktop"
        desktop.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "xrg-linux/preview/com.sdelavega.xrg-ng.desktop", desktop)
        run("desktop-file-validate", str(desktop))
        icon = bundle / "share/icons/hicolor/scalable/apps/com.sdelavega.xrg-ng.svg"
        icon.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "xrg-linux/data/icons/com.gaucho.xrg-linux.svg", icon)
        for name in ["LICENSE", "COPYRIGHT", "THIRD_PARTY_NOTICES.md"]:
            shutil.copy2(ROOT / name, docs / name)
        shutil.copy2(ROOT / "xrg-linux/rust/README.md", docs / "DEVELOPMENT.md")
        shutil.copy2(ROOT / "xrg-linux/preview/README.md", bundle / "README.md")
        notices = docs / "licenses"
        shutil.copytree(ROOT / "xrg-linux/rust/licenses", notices)
        pinned = notices / "swift-6.4.1"
        for item in json.loads((pinned / "sources.json").read_text()):
            if digest(pinned / item["file"]) != item["sha256"]:
                raise ValueError(f"Pinned runtime notice changed: {item['file']}")
        swift_license = Path(target["paths"]["runtimeResourcePath"]).parent.parent / "share/swift/LICENSE.txt"
        shutil.copy2(swift_license, notices / "Swift-toolchain-LICENSE.txt")
        rust_docs = Path(run("rustc", "--print", "sysroot")) / "share/doc/rust"
        shutil.copytree(rust_docs / "licenses", notices / "rust-runtime")
        shutil.copy2(rust_docs / "COPYRIGHT-library.html", notices / "rust-runtime/COPYRIGHT-library.html")
        source = work / "source"
        source.mkdir()
        files = subprocess.check_output(["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        for name in files.decode().split("\0"):
            if not name:
                continue
            original = ROOT / name
            if original.is_symlink() or not original.is_file():
                raise ValueError(f"Source must contain regular files: {name}")
            dest = source / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, dest)
        vendor = source / "vendor"
        config = run("cargo", "vendor", "--locked", "--manifest-path", str(ROOT / "xrg-linux/rust/Cargo.toml"), str(vendor))
        config = config.replace(f'directory = "{vendor}"', 'directory = "vendor"')
        (source / ".cargo").mkdir(exist_ok=True)
        (source / ".cargo/config.toml").write_text(config + "\n")
        # Check the vendored source can resolve without a registry or Cargo cache.
        vendor_env = dict(env, CARGO_HOME=str(work / "empty-cargo-home"))
        run("cargo", "metadata", "--manifest-path", str(source / "xrg-linux/rust/Cargo.toml"),
            "--locked", "--offline", "--all-features", "--format-version", "1",
            cwd=source, env=vendor_env)
        crates = []
        for crate in metadata["packages"]:
            if crate["source"] is None:
                continue
            directory = Path(crate["manifest_path"]).parent
            dest = notices / f"{crate['name']}-{crate['version']}"
            dest.mkdir()
            shutil.copy2(directory / "Cargo.toml", dest / "Cargo.toml")
            for path in directory.rglob("*"):
                relative = path.relative_to(directory)
                if len(relative.parts) <= 3 and path.is_file() and path.name.upper().startswith(
                        ("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT", "UNLICENSE")):
                    copied = dest / relative
                    copied.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(path, copied)
            crates.append({"name": crate["name"], "version": crate["version"], "license": crate["license"], "source": crate["source"]})
        (notices / "cargo-dependencies.json").write_text(json.dumps(crates, indent=2) + "\n")
        make_tar(source, bundle / "source.tar.gz")
        if (run("git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=all") != status
                or run("git", "-C", str(ROOT), "rev-parse", "HEAD") != revision):
            raise ValueError("Checkout changed while creating the package")
        manifest = {
            "format": "xrg-ng-linux-preview", "version": project["version"],
            "architecture": arch, "revision": revision, "dirty": bool(status),
            "swift": target["compilerVersion"], "rust": run("rustc", "--version"),
            "baseline": "Ubuntu 24.04; GTK 4.10+; glibc; system GTK/graphics dependencies",
            "bundled_libraries": sorted(bundled),
            "system_libraries": sorted(set(linked) - set(bundled)),
            "inputs": {"binary_sha256": digest(binary), "swift_library_sha256": digest(library)},
            "files": {str(p.relative_to(bundle)): digest(p) for p in sorted(bundle.rglob("*")) if p.is_file()},
        }
        (bundle / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        make_tar(bundle, archive)
    checksum.write_text(f"{digest(archive)}  {archive.name}\n")
    print(f"LINUX_PACKAGE_OK {archive}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"archive={archive}\nchecksum={checksum}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--swift-library", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=ROOT / "dist/linux")
    parser.add_argument("--allow-dirty", action="store_true", help="Local development only; mark the source snapshot as dirty")
    package(parser.parse_args())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Linux packaging: {error}", file=sys.stderr)
        sys.exit(1)
