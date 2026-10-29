# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Native packaging refusals and an actual dpkg archive built from a tiny fixture."""
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import linux_deb as deb


class NativePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xrg-deb-unit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.bundle = self.root / "bundle"
        self.bundle.mkdir()
        arch = platform.machine() if platform.machine() in deb.ARCHITECTURES else "aarch64"
        self.manifest = dict(format="xrg-ng-linux-preview", version="0.1.0", revision="a" * 40,
                             dirty=False, architecture=arch,
                             bundled_libraries=["libXRGSharedCore.so", "libswiftCore.so"],
                             system_libraries=["libc.so.6", "libm.so.6", "libgcc_s.so.1", "libstdc++.so.6"])
        files = ["xrg-ng-linux", "source.tar.gz", "README.md", "share/doc/xrg-ng/LICENSE",
                 "share/doc/xrg-ng/COPYRIGHT", "share/doc/xrg-ng/THIRD_PARTY_NOTICES.md",
                 "share/doc/xrg-ng/licenses/Swift-toolchain-LICENSE.txt",
                 f"share/icons/hicolor/scalable/apps/{deb.APP_ID}.svg"]
        for name in files:
            self.put(name, b"fixture\n")
        self.put(f"share/applications/{deb.APP_ID}.desktop", b"[Desktop Entry]\nType=Application\nName=Fixture\nExec=xrg-ng-linux\n")
        header = bytearray(20)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = struct.pack("<H", deb.ARCHITECTURES[arch][1])
        for name in ["bin/xrg-ng-linux", *[f"lib/{n}" for n in self.manifest["bundled_libraries"]]]:
            self.put(name, header)
        self.seal()

    def put(self, name, value):
        path = self.bundle / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value)

    def seal(self):
        self.manifest["files"] = deb.inventory(self.bundle)
        (self.bundle / "manifest.json").write_text(json.dumps(self.manifest))

    def test_tampered_and_unlisted_payloads_are_rejected(self):
        self.put("README.md", b"changed")
        with self.assertRaisesRegex(ValueError, "manifest"):
            deb.validate(self.bundle, False)
        self.seal()
        self.put("unlisted", b"new")
        with self.assertRaisesRegex(ValueError, "manifest"):
            deb.validate(self.bundle, False)

    def test_links_and_special_files_are_rejected_before_reading_them(self):
        path = self.bundle / "escape"
        path.symlink_to(self.root / "unrelated")
        with self.assertRaisesRegex(ValueError, "regular files"):
            deb.validate(self.bundle, False)
        path.unlink()
        os.mkfifo(path)
        with self.assertRaisesRegex(ValueError, "regular files"):
            deb.validate(self.bundle, False)

    def test_missing_source_and_notices_cannot_be_hidden_by_rehashing(self):
        for name in ["source.tar.gz", "share/doc/xrg-ng/LICENSE", "share/doc/xrg-ng/licenses/Swift-toolchain-LICENSE.txt"]:
            path = self.bundle / name
            original = path.read_bytes()
            path.unlink()
            self.seal()
            with self.assertRaisesRegex(ValueError, "required"):
                deb.validate(self.bundle, False)
            path.write_bytes(original)
        self.seal()

    def test_wrong_elf_architecture_is_rejected_even_with_matching_hashes(self):
        path = self.bundle / "lib/libswiftCore.so"
        value = bytearray(path.read_bytes())
        value[18:20] = b"\0\0"
        path.write_bytes(value)
        self.seal()
        with self.assertRaisesRegex(ValueError, "ELF architecture"):
            deb.validate(self.bundle, False)

    def test_dirty_snapshots_require_an_explicit_development_override(self):
        self.manifest["dirty"] = True
        self.seal()
        with self.assertRaisesRegex(ValueError, "clean source"):
            deb.validate(self.bundle, False)
        self.assertTrue(deb.validate(self.bundle, True)["dirty"])
        self.assertIn(".dirty-1", deb.version(self.manifest, 1700000000, 1))

    def test_invalid_control_metadata_never_reaches_dpkg(self):
        original = dict(self.manifest)
        for key, value in [("version", "0.1.0\nDepends: fake"), ("version", 1),
                           ("revision", "x" * 40), ("architecture", ["arm64"]), ("dirty", "false"),
                           ("bundled_libraries", [None]), ("system_libraries", [None])]:
            with self.subTest(key=key, value=value):
                self.manifest = dict(original, **{key: value})
                self.seal()
                with patch.object(deb.subprocess, "check_output") as process:
                    with self.assertRaises(ValueError):
                        deb.validate(self.bundle, True)
                    process.assert_not_called()

    def test_new_system_library_requires_an_explicit_dependency_mapping(self):
        self.manifest["system_libraries"].append("libnew.so.1")
        with patch.object(deb.subprocess, "check_output") as process:
            with self.assertRaisesRegex(ValueError, "Unmapped"):
                deb.dependencies(self.manifest)
            process.assert_not_called()

    def test_invalid_epoch_and_packaging_revision_are_rejected(self):
        for epoch in [-1, True, "1", 2**40]:
            with self.subTest(epoch=epoch), self.assertRaises(ValueError):
                deb.version(self.manifest, epoch, 1)
        for revision in [0, -1, True, "1", 1000000]:
            with self.subTest(revision=revision), self.assertRaises(ValueError):
                deb.version(self.manifest, 1700000000, revision)

    def test_bundle_timestamp_must_match_native_version_provenance(self):
        self.manifest["source_epoch"] = 1700000000
        self.seal()
        with patch.object(deb.subprocess, "check_output") as process:
            with self.assertRaisesRegex(ValueError, "timestamp"):
                deb.build_deb(self.bundle, self.root / "out", 1700000001)
            process.assert_not_called()

    @unittest.skipUnless(platform.system() == "Linux" and shutil.which("dpkg-deb") and shutil.which("desktop-file-validate"), "Requires Ubuntu packaging tools")
    def test_native_archive_paths_ownership_reproducibility_and_version_order(self):
        first, checksum = deb.build_deb(self.bundle, self.root / "first", 1700000000)
        second, _ = deb.build_deb(self.bundle, self.root / "second", 1700000000)
        self.assertEqual(first.read_bytes(), second.read_bytes())
        self.assertEqual(checksum.read_text().split(), [hashlib.sha256(first.read_bytes()).hexdigest(), first.name])
        original = first.read_bytes()
        with self.assertRaisesRegex(ValueError, "already exists"):
            deb.build_deb(self.bundle, self.root / "first", 1700000000)
        self.assertEqual(first.read_bytes(), original)
        data = subprocess.check_output(["dpkg-deb", "--fsys-tarfile", first])
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            members = archive.getmembers()
        self.assertTrue(all(m.uid == m.gid == 0 for m in members))
        self.assertTrue(all(m.name == "." or m.name.startswith("./usr") for m in members))
        launcher = next(m for m in members if m.name == "./usr/bin/xrg-ng-linux")
        self.assertTrue(launcher.issym())
        self.assertEqual(launcher.linkname, "../lib/xrg-ng/xrg-ng-linux")
        self.assertIn("./usr/share/doc/xrg-ng/source.tar.gz", [m.name for m in members])
        for newer, older in [(deb.version(self.manifest, 1700000001, 1), deb.version(self.manifest, 1700000000, 99)),
                             (deb.version(self.manifest, 1700000000, 2), deb.version(self.manifest, 1700000000, 1)),
                             ("0.1.0", deb.version(self.manifest, 1700000000, 1))]:
            subprocess.run(["dpkg", "--compare-versions", newer, "gt", older], check=True)


if __name__ == "__main__":
    unittest.main()
