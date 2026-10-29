# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
import io
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import unittest
from unittest.mock import patch
import linux_formats as formats
import test_linux_deb as fixtures


class FormatTests(unittest.TestCase):
    setUp = fixtures.NativePackageTests.setUp
    put = fixtures.NativePackageTests.put
    seal = fixtures.NativePackageTests.seal

    def test_release_versions_and_metadata_are_distinct_from_previews(self):
        self.manifest.update(channel="release", version="0.2.0")
        self.seal()
        manifest = formats.prepare(self.bundle, 1700000000, 1, False)
        self.assertEqual(formats.deb_version(manifest, 1700000000, 1), "0.2.0-1")
        self.assertEqual(formats.deb_version(manifest, 1700000000, 2), "0.2.0-2")
        self.manifest["dirty"] = True
        self.seal()
        with self.assertRaisesRegex(ValueError, "[Rr]elease"):
            formats.prepare(self.bundle, 1700000000, 1, True)

    def test_unknown_or_non_scalar_channel_is_rejected(self):
        for channel in ["nightly", ["release"]]:
            self.manifest["channel"] = channel
            self.seal()
            with self.assertRaises(ValueError):
                formats.prepare(self.bundle, 1700000000, 1, False)

    def test_arch_container_doc_override_preserves_signature_and_repository_settings(self):
        spec = importlib.util.spec_from_file_location("format_smoke", Path(formats.__file__).with_name("formats-smoke-linux.py"))
        smoke = importlib.util.module_from_spec(spec); spec.loader.exec_module(smoke)
        source = self.root / "original.conf"
        text = "[options]\nSigLevel = Required DatabaseOptional\nNoExtract = usr/share/doc/* usr/share/man/*\n#NoExtract = keep-comment\n[core]\nInclude = /etc/pacman.d/mirrorlist\n"
        source.write_text(text)
        target = smoke.pacman_test_config(source, self.root / "test.conf")
        expected = text.replace("NoExtract = usr/share/doc/* usr/share/man/*", "NoExtract = usr/share/doc/* usr/share/man/* !usr/share/doc/xrg-ng !usr/share/doc/xrg-ng/*")
        self.assertEqual(target.read_text(), expected)
        self.assertEqual(source.read_text(), text)

    def test_wrong_timestamp_and_unmapped_system_libraries_are_rejected(self):
        self.manifest["source_epoch"] = 1700000000
        self.seal()
        with self.assertRaisesRegex(ValueError, "timestamp"):
            formats.prepare(self.bundle, 1700000001, 1, False)
        self.manifest["system_libraries"].append("libunknown.so.1")
        self.seal()
        with self.assertRaisesRegex(ValueError, "Unmapped"):
            formats.prepare(self.bundle, 1700000000, 1, False)

    def test_foreign_architecture_cannot_be_labeled_as_native(self):
        with patch.object(formats.platform, "machine", return_value="unsupported"):
            with self.assertRaisesRegex(ValueError, "matching native"):
                formats.prepare(self.bundle, 1700000000, 1, False)

    def test_broken_output_links_are_not_followed_or_replaced(self):
        output = self.root / "out"; output.mkdir()
        missing = self.root / "unrelated"
        link = output / "package.sha256"; link.symlink_to(missing)
        with self.assertRaisesRegex(ValueError, "already exists"):
            formats.destination(output, "package")
        self.assertTrue(link.is_symlink()); self.assertFalse(missing.exists())

    def test_runtime_download_refuses_unpinned_bytes(self):
        inputs = self.root / "Tools/appimage-runtime"; inputs.mkdir(parents=True)
        (inputs / "runtime").write_bytes(b"wrong runtime")
        with patch.object(formats, "ROOT", self.root):
            with self.assertRaisesRegex(ValueError, "checksum"):
                formats.download(dict(file="runtime", url="https://example.invalid/runtime", sha256="0" * 64), self.root / "runtime")

    @unittest.skipUnless(shutil.which("rpmbuild"), "Requires RPM packaging tools")
    def test_rpm_contains_sources_and_does_not_export_private_swift_libraries(self):
        package, _ = formats.build_rpm(self.bundle, self.root / "rpm", 1700000000)
        self.assertEqual(subprocess.check_output(["rpm", "-qp", "--queryformat", "%{ARCH}", package], text=True), self.manifest["architecture"])
        provided = subprocess.check_output(["rpm", "-qp", "--provides", package], text=True)
        self.assertIn("xrg-ng", provided); self.assertNotIn("libswift", provided)
        scripts = subprocess.check_output(["rpm", "-qp", "--scripts", package], text=True)
        self.assertFalse(scripts.strip())
        files = subprocess.check_output(["rpm", "-qpl", package], text=True)
        self.assertIn("/usr/share/doc/xrg-ng/source.tar.gz", files)
        self.assertNotIn("/etc/", files); self.assertNotIn("/home/", files)

    @unittest.skipUnless(shutil.which("bsdtar") and shutil.which("zstd"), "Requires ALPM archive tools")
    def test_arch_archive_has_native_metadata_integrity_tree_and_root_ownership(self):
        package, _ = formats.build_arch(self.bundle, self.root / "arch", 1700000000)
        info = subprocess.check_output(["bsdtar", "-xOf", package, ".PKGINFO"], text=True)
        self.assertIn(f"arch = {self.manifest['architecture']}\n", info)
        self.assertIn("depend = glibc>=2.39\n", info)
        listing = subprocess.check_output(["bsdtar", "-tf", package], text=True)
        self.assertIn(".MTREE", listing); self.assertNotIn(".INSTALL", listing)
        self.assertIn("usr/share/doc/xrg-ng/source.tar.gz", listing)
        verbose = subprocess.check_output(["bsdtar", "-tvf", package], text=True)
        self.assertNotIn("/etc/", verbose)

    @unittest.skipUnless(shutil.which("mksquashfs") and shutil.which("unsquashfs"), "Requires SquashFS tools")
    def test_appimage_layout_and_source_are_behind_a_type2_runtime_header(self):
        header = bytearray((self.bundle / "bin/xrg-ng-linux").read_bytes())
        header[8:11] = b"AI\x02"

        def fixture_download(item, target):
            target.write_bytes(header if target.name == "runtime" else b"source fixture")

        with patch.object(formats, "download", side_effect=fixture_download):
            package, checksum = formats.build_appimage(self.bundle, self.root / "appimage", 1700000000)
        self.assertEqual(package.read_bytes()[:20], header)
        self.assertTrue(package.stat().st_mode & 0o111)
        self.assertTrue(checksum.is_file())
        tree = self.root / "extract"
        subprocess.run(["unsquashfs", "-o", str(len(header)), "-d", tree, package], check=True, stdout=subprocess.DEVNULL)
        self.assertTrue((tree / "AppRun").stat().st_mode & 0o111)
        self.assertTrue((tree / ".DirIcon").is_symlink())
        docs = tree / "usr/share/doc/xrg-ng"
        self.assertTrue((docs / "source.tar.gz").is_file())
        with tarfile.open(docs / "appimage-runtime-source.tar.gz") as sources:
            self.assertIn("appimage-runtime-source/type2-runtime.tar.gz", sources.getnames())
        self.assertEqual(json.loads((docs / "native-package.json").read_text())["format"], "xrg-ng-linux-appimage")
