# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""RPM, ALPM and type-2 AppImage wrappers for the verified Linux payload."""
import gzip
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
from linux_bundle import APP_ID, digest, validate, stage_payload
from linux_deb import SYSTEM_PACKAGES, version as deb_version

ROOT = Path(__file__).resolve().parent.parent
RPM_DEPENDS = ["glibc >= 2.39", "libgcc >= 14.2", "libstdc++ >= 14.2", "mesa-libGL", "mesa-libEGL",
               "mesa-dri-drivers", "libxkbcommon", "libxkbcommon-x11", "libwayland-client",
               "libwayland-cursor", "libwayland-egl", "libX11", "libXcursor", "libXi", "libXrandr",
               "curl", "ca-certificates"]
ARCH_DEPENDS = ["glibc>=2.39", "gcc-libs>=14.2", "libglvnd", "mesa", "libxkbcommon",
                "libxkbcommon-x11", "wayland", "libx11", "libxcursor", "libxi", "libxrandr",
                "curl", "ca-certificates"]


def prepare(bundle, epoch, revision, allow_dirty):
    manifest = validate(bundle, allow_dirty)
    deb_version(manifest, epoch, revision)  # shared metadata/range checks
    if manifest["architecture"] != platform.machine():
        raise ValueError("Package on the matching native architecture")
    if "source_epoch" in manifest and (type(manifest["source_epoch"]) is not int or manifest["source_epoch"] != epoch):
        raise ValueError("Source commit timestamp does not match the bundle")
    unknown = set(manifest["system_libraries"]) - SYSTEM_PACKAGES.keys()
    if unknown:
        raise ValueError(f"Unmapped system libraries: {sorted(unknown)}")
    return manifest


def label(manifest, epoch):
    return f"{epoch}.g{manifest['revision'][:12]}" + (".dirty" if manifest["dirty"] else "")


def normalise(stage, epoch):
    stage.chmod(0o755)
    private = stage / "usr/lib/xrg-ng"
    for path in stage.rglob("*"):
        if not path.is_symlink():
            path.chmod(0o755 if path.is_dir() or path.is_relative_to(private) else 0o644)
        os.utime(path, (epoch, epoch), follow_symlinks=False)


def destination(output, name):
    output.mkdir(parents=True, exist_ok=True)
    path = output / name
    checksum = Path(str(path) + ".sha256")
    if path.exists() or path.is_symlink() or checksum.exists() or checksum.is_symlink():
        raise ValueError(f"Output already exists: {path}")
    return path


def publish(prepared, path):
    shutil.move(prepared, path)
    checksum = Path(str(path) + ".sha256")
    checksum.write_text(f"{digest(path)}  {path.name}\n")
    return path, checksum


def build_rpm(bundle, output, epoch, *, revision=1, allow_dirty=False):
    manifest = prepare(bundle, epoch, revision, allow_dirty)
    arch = manifest["architecture"]
    release = f"0.preview.{label(manifest, epoch)}.{revision}"
    full = f"{manifest['version']}-{release}"
    path = destination(output, f"xrg-ng-{full}.{arch}.rpm")
    with tempfile.TemporaryDirectory(prefix="xrg-rpm-") as temporary:
        top = Path(temporary)
        stage = top / "payload"
        stage_payload(bundle, stage, manifest, epoch, "xrg-ng-linux-rpm", full, arch)
        normalise(stage, epoch)
        spec = top / "xrg-ng.spec"
        spec.write_text(
            f"Name: xrg-ng\nVersion: {manifest['version']}\nRelease: {release}\n"
            "Summary: System resource monitor (Linux preview)\nLicense: GPL-3.0-or-later\n"
            "URL: https://github.com/sdelavega/XRG-ng\n"
            f"BuildArch: {arch}\nAutoReqProv: no\nRequires: {', '.join(RPM_DEPENDS)}\n"
            "%global debug_package %{nil}\n%global __os_install_post %{nil}\n"
            "%description\nRust/Swift and egui monitor with private Swift runtime, source and notices.\n"
            f"%install\nmkdir -p %{{buildroot}}\ncp -a {stage}/usr %{{buildroot}}/\n"
            "%files\n%defattr(-,root,root,-)\n/usr/bin/xrg-ng-linux\n/usr/lib/xrg-ng\n"
            "/usr/share/doc/xrg-ng\n/usr/share/applications/com.sdelavega.xrg-ng.desktop\n"
            "/usr/share/icons/hicolor/scalable/apps/com.sdelavega.xrg-ng.svg\n")
        env = dict(os.environ, SOURCE_DATE_EPOCH=str(epoch))
        subprocess.run(["rpmbuild", "-bb", "--target", arch, "--define", f"_topdir {top}",
                        "--define", "_build_id_links none", "--define", "use_source_date_epoch_as_buildtime 1",
                        "--define", "clamp_mtime_to_source_date_epoch 1", str(spec)], check=True, env=env)
        made = list((top / "RPMS").rglob("*.rpm"))
        if len(made) != 1:
            raise ValueError("Expected exactly one RPM")
        return publish(made[0], path)


def build_arch(bundle, output, epoch, *, revision=1, allow_dirty=False):
    manifest = prepare(bundle, epoch, revision, allow_dirty)
    arch = manifest["architecture"]
    version = f"{manifest['version']}pre.{label(manifest, epoch)}-{revision}"
    path = destination(output, f"xrg-ng-{version}-{arch}.pkg.tar.zst")
    with tempfile.TemporaryDirectory(prefix="xrg-arch-") as temporary:
        stage = Path(temporary) / "root"
        stage_payload(bundle, stage, manifest, epoch, "xrg-ng-linux-arch", version, arch)
        normalise(stage, epoch)
        size = sum(p.stat().st_size for p in stage.rglob("*") if p.is_file() and not p.is_symlink())
        (stage / ".PKGINFO").write_text(
            f"pkgname = xrg-ng\npkgbase = xrg-ng\npkgver = {version}\n"
            "pkgdesc = System resource monitor (Linux preview)\n"
            "url = https://github.com/sdelavega/XRG-ng\n"
            f"builddate = {epoch}\npackager = Stephen de la Vega\nsize = {size}\narch = {arch}\n"
            "license = GPL-3.0-or-later\nxdata = pkgtype=pkg\n" +
            "".join(f"depend = {name}\n" for name in ARCH_DEPENDS))
        os.utime(stage / ".PKGINFO", (epoch, epoch))
        mtree = subprocess.check_output(["bsdtar", "--format=mtree", "--uid", "0", "--gid", "0",
                                        "--options", "!all,use-set,type,uid,gid,mode,time,size,sha256,link",
                                        "-cf", "-", "."], cwd=stage)
        (stage / ".MTREE").write_bytes(gzip.compress(mtree, mtime=epoch))
        prepared = Path(temporary) / "prepared.pkg.tar.zst"
        subprocess.run(["bsdtar", "--zstd", "--options", "zstd:compression-level=6",
                        "--uid", "0", "--gid", "0", "--uname", "root", "--gname", "root",
                        "-cf", str(prepared), ".PKGINFO", ".MTREE", "usr"], cwd=stage, check=True)
        return publish(prepared, path)


def download(item, destination):
    # Vendored inputs keep old builds working when upstream replaces its
    # continuous-release assets. URLs remain recorded for origin/provenance.
    if Path(item["file"]).name != item["file"]:
        raise ValueError("Invalid runtime input filename")
    source = ROOT / "Tools/appimage-runtime" / item["file"]
    if digest(source) != item["sha256"]:
        raise ValueError(f"Pinned AppImage input checksum mismatch: {item['url']}")
    shutil.copyfile(source, destination)


def build_appimage(bundle, output, epoch, *, revision=1, allow_dirty=False):
    manifest = prepare(bundle, epoch, revision, allow_dirty)
    arch = manifest["architecture"]
    version = f"{manifest['version']}-preview.{label(manifest, epoch)}.{revision}"
    path = destination(output, f"XRG-ng-{version}-{arch}.AppImage")
    pins = json.loads((ROOT / "Tools/appimage-runtime.json").read_text())
    with tempfile.TemporaryDirectory(prefix="xrg-appimage-") as temporary:
        work = Path(temporary)
        stage = work / "AppDir"
        stage_payload(bundle, stage, manifest, epoch, "xrg-ng-linux-appimage", version, arch)
        runtime = work / "runtime"
        download(pins["runtimes"][arch], runtime)
        header = runtime.read_bytes()[:20]
        if header[8:11] != b"AI\x02" or int.from_bytes(header[18:20], "little") != {"x86_64": 62, "aarch64": 183}[arch]:
            raise ValueError("Wrong AppImage runtime architecture/type")
        sources = work / "runtime-source"
        sources.mkdir()
        for item in pins["sources"]:
            download(item, sources / item["file"])
        shutil.copy2(ROOT / "Tools/appimage-runtime.json", sources / "inputs.json")
        shutil.copy2(ROOT / "Tools/appimage-runtime-README.md", sources / "README.md")
        docs = stage / "usr/share/doc/xrg-ng"
        with tarfile.open(docs / "appimage-runtime-source.tar.gz", "w:gz") as archive:
            archive.add(sources, arcname="appimage-runtime-source")
        meta = json.loads((docs / "native-package.json").read_text())
        meta["appimage_runtime"] = pins["runtimes"][arch]
        meta["appimage_runtime_source_sha256"] = digest(docs / "appimage-runtime-source.tar.gz")
        (docs / "native-package.json").write_text(json.dumps(meta, indent=2) + "\n")
        (stage / "AppRun").write_text('#!/bin/sh\nset -eu\nhere=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd -P)\nexec "$here/usr/lib/xrg-ng/xrg-ng-linux" "$@"\n')
        desktop = stage / f"{APP_ID}.desktop"
        desktop.write_text((stage / f"usr/share/applications/{APP_ID}.desktop").read_text().replace("Exec=/usr/bin/xrg-ng-linux", "Exec=AppRun"))
        shutil.copy2(stage / f"usr/share/icons/hicolor/scalable/apps/{APP_ID}.svg", stage / f"{APP_ID}.svg")
        (stage / ".DirIcon").symlink_to(f"{APP_ID}.svg")
        normalise(stage, epoch)
        (stage / "AppRun").chmod(0o755)
        subprocess.run(["desktop-file-validate", str(desktop)], check=True)
        squash = work / "payload.squashfs"
        subprocess.run(["mksquashfs", str(stage), str(squash), "-noappend", "-all-root", "-comp", "zstd",
                        "-processors", "2", "-mkfs-time", str(epoch), "-all-time", str(epoch), "-no-progress"], check=True)
        prepared = work / "prepared.AppImage"
        with prepared.open("wb") as target:
            for source in [runtime, squash]:
                with source.open("rb") as stream:
                    shutil.copyfileobj(stream, target)
        prepared.chmod(0o755)
        return publish(prepared, path)
