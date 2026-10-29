# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import tarfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "release-signing.py"
spec = importlib.util.spec_from_file_location("release_signing", path)
signing = importlib.util.module_from_spec(spec); spec.loader.exec_module(signing)
spec = importlib.util.spec_from_file_location("release_linux", path.with_name("release-linux.py"))
release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)


class CandidateTests(unittest.TestCase):
    def test_candidate_payload_checksums_and_release_metadata_are_required(self):
        with tempfile.TemporaryDirectory(prefix="xrg-candidate-test-") as temporary:
            folder = Path(temporary); arch = "aarch64"; revision = "a" * 40
            names = release.payloads("0.2.0", arch)
            archive = folder / "xrg-ng-0.2.0-linux-aarch64.tar.gz"
            def create(channel="release"):
                manifest = dict(channel=channel, version="0.2.0", architecture=arch, revision=revision, dirty=False)
                body = json.dumps(manifest).encode()
                with tarfile.open(archive, "w:gz") as out:
                    member = tarfile.TarInfo("bundle/manifest.json"); member.size = len(body)
                    out.addfile(member, io.BytesIO(body))
                for name in names:
                    path = folder / name
                    if path != archive: path.write_bytes(b"fixture")
                    (folder / release.checksum_name(name)).write_text(f"{signing.digest(path)}  {name}\n")
            create()
            release.validate_artifact(folder, "0.2.0", arch, revision)
            with self.assertRaises(RuntimeError): release.validate_artifact(folder, "0.2.0", arch, "b" * 40)
            (folder / "xrg-ng_0.2.0-1_arm64.deb").write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "checksum"): release.validate_artifact(folder, "0.2.0", arch, revision)
            create("preview")
            with self.assertRaisesRegex(RuntimeError, "release metadata"): release.validate_artifact(folder, "0.2.0", arch, revision)

    def test_requires_successful_complete_candidate_from_the_exact_source(self):
        run = dict(status="completed", conclusion="success", head_sha="a" * 40,
                   head_repository={"full_name": release.REPOSITORY}, event="workflow_dispatch",
                   path=".github/workflows/linux.yml")
        jobs = [dict(name=n, conclusion="success") for n in release.JOBS]
        release.validate_run(run, jobs, "a" * 40)
        with self.assertRaises(RuntimeError): release.validate_run(run, jobs, "b" * 40)
        with self.assertRaises(RuntimeError): release.validate_run(run, jobs[:-1], "a" * 40)
        jobs[0]["conclusion"] = "skipped"
        with self.assertRaises(RuntimeError): release.validate_run(run, jobs, "a" * 40)

    def test_release_inventory_covers_all_five_formats_per_architecture(self):
        for arch, deb in [("x86_64", "amd64"), ("aarch64", "arm64")]:
            names = release.payloads("0.2.0", arch)
            self.assertEqual(len(names), 5)
            self.assertIn(f"xrg-ng_0.2.0-1_{deb}.deb", names)
            self.assertTrue(all("preview" not in n for n in names))
            self.assertEqual(release.checksum_name(f"xrg-ng-0.2.0-linux-{arch}.tar.gz"),
                             f"xrg-ng-0.2.0-linux-{arch}.sha256")


class ManifestTests(unittest.TestCase):
    def test_malformed_manifest_is_rejected_before_requesting_a_secret(self):
        with tempfile.TemporaryDirectory(prefix="xrg-release-manifest-") as temporary:
            root = Path(temporary); (root / "signing").mkdir()
            (root / "signing/fingerprint.txt").write_text("A" * 40)
            state = root / "state"; state.mkdir()
            (state / "identity.json").write_text(json.dumps({"primary_fingerprint": "A" * 40}))
            folder = root / "release"; folder.mkdir()
            for text in ["", "0" * 64 + "  ../escape\n", "not a checksum\n"]:
                (folder / "SHA256SUMS").write_text(text)
                with patch.object(signing, "ROOT", root), patch.object(signing, "STATE", state), patch.object(signing, "secret") as secret:
                    with self.assertRaises(RuntimeError): signing.sign(folder)
                    secret.assert_not_called()


@unittest.skipUnless(shutil.which("gpg"), "Requires GnuPG")
class SignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # macOS's per-user TMPDIR can exceed gpg-agent's Unix socket limit.
        cls.temporary = tempfile.TemporaryDirectory(prefix="xrg-test-signatures-", dir="/tmp")
        cls.root = Path(cls.temporary.name); cls.home = cls.root / "gnupg"; cls.home.mkdir(mode=0o700)
        signing.gpg(cls.home, "--pinentry-mode", "loopback", "--passphrase", "", "--quick-generate-key",
                    "XRG automated test key", "ed25519", "cert", "1d")
        listing = signing.gpg(cls.home, "--with-colons", "--list-secret-keys").decode()
        cls.primary = next(l.split(":")[9] for l in listing.splitlines() if l.startswith("fpr:"))
        signing.gpg(cls.home, "--pinentry-mode", "loopback", "--passphrase", "", "--quick-add-key", cls.primary, "ed25519", "sign", "1d")
        listing = signing.gpg(cls.home, "--with-colons", "--list-secret-keys").decode()
        cls.subkey = [l.split(":")[9] for l in listing.splitlines() if l.startswith("fpr:")][-1]
        cls.repo = cls.root / "repo"; (cls.repo / "signing").mkdir(parents=True)
        (cls.repo / "signing/fingerprint.txt").write_text(cls.primary + "\n")
        (cls.repo / "signing/xrg-ng-release.asc").write_bytes(signing.gpg(cls.home, "--armor", "--export", cls.primary))
        cls.state = cls.root / "state"; cls.state.mkdir()
        (cls.state / "identity.json").write_text(json.dumps(dict(primary_fingerprint=cls.primary,
                                                               signing_fingerprint=cls.subkey, gnupg_home=str(cls.home))))

    @classmethod
    def tearDownClass(cls):
        subprocess.run(["gpgconf", "--homedir", cls.home, "--kill", "gpg-agent"], capture_output=True)
        cls.temporary.cleanup()

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="payload-", dir=self.root))
        for name in ["artifact.AppImage", "artifact.pkg.tar.zst"]:
            (self.directory / name).write_bytes(b"synthetic payload")
        (self.directory / "SHA256SUMS").write_text("".join(
            f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in sorted(self.directory.iterdir())))
        self.addCleanup(shutil.rmtree, self.directory)

    def sign(self):
        with patch.object(signing, "ROOT", self.repo), patch.object(signing, "STATE", self.state), patch.object(signing, "secret", return_value=b"\n"):
            signing.sign(self.directory)

    def test_signatures_verify_with_only_the_pinned_public_key(self):
        self.sign()
        self.assertTrue((self.directory / "artifact.pkg.tar.zst.sig").is_file())
        self.assertTrue((self.directory / "artifact.AppImage.asc").is_file())
        with patch.object(signing, "ROOT", self.repo): signing.verify(self.directory)

    @unittest.skipUnless(shutil.which("rpmbuild") and shutil.which("rpmsign"), "Requires RPM signing tools")
    def test_native_rpm_header_signature_preserves_payload(self):
        import test_linux_deb as fixtures
        import linux_formats
        fixture = fixtures.NativePackageTests(); fixture.setUp()
        try:
            package, _ = linux_formats.build_rpm(fixture.bundle, fixture.root / "rpm", 1700000000)
            output = self.root / "native-rpm"; output.mkdir()
            self.addCleanup(shutil.rmtree, output)
            target = output / package.name; shutil.copyfile(package, target)
            before = signing.digest(target)
            with patch.object(signing, "ROOT", self.repo), patch.object(signing, "STATE", self.state), patch.object(signing, "secret", return_value=b"\n"):
                signing.sign_rpms(output)
            self.assertNotEqual(signing.digest(target), before)
            self.assertEqual(Path(str(target) + ".sha256").read_text().split(), [signing.digest(target), target.name])
        finally:
            fixture.doCleanups()

    def test_changed_payload_and_unlisted_files_are_rejected(self):
        self.sign(); path = self.directory / "artifact.AppImage"; before = path.read_bytes(); path.write_bytes(b"tampered")
        with patch.object(signing, "ROOT", self.repo):
            with self.assertRaisesRegex(RuntimeError, "checksum"): signing.verify(self.directory)
            path.write_bytes(before); (self.directory / "unlisted.deb").write_bytes(b"extra")
            with self.assertRaisesRegex(RuntimeError, "Unlisted"): signing.verify(self.directory)

    def test_different_primary_identity_is_rejected(self):
        self.sign()
        (self.repo / "signing/fingerprint.txt").write_text("B" * 40 + "\n")
        try:
            with patch.object(signing, "ROOT", self.repo):
                with self.assertRaisesRegex(RuntimeError, "pinned"): signing.verify(self.directory)
        finally:
            (self.repo / "signing/fingerprint.txt").write_text(self.primary + "\n")
