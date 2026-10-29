#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Local OpenPGP identity and release signing; secrets stay outside the checkout."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
STATE = Path.home() / ".local/share/xrg-ng-release"
SERVICE = "com.sdelavega.xrg-ng.release-signing"
ACCOUNT = "OpenPGP-release-v1"


def secret():
    result = subprocess.run(["security", "find-generic-password", "-s", SERVICE, "-a", ACCOUNT, "-w"], capture_output=True)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError("Release passphrase is unavailable in the login Keychain")
    return result.stdout.strip() + b"\n"


def gpg(home, *args, password=None):
    command = ["gpg", "--homedir", str(home), "--batch"]
    if password is not None:
        command += ["--pinentry-mode", "loopback", "--passphrase-fd", "0"]
    result = subprocess.run([*command, *map(str, args)], input=password, capture_output=True)
    if result.returncode:
        # No process input, Keychain output or secret material in error logs.
        raise RuntimeError(f"GnuPG operation failed (exit {result.returncode})")
    return result.stdout


def initialise():
    if (STATE / "identity.json").exists():
        raise RuntimeError("A release identity already exists; preserving it")
    home = STATE / "gnupg"
    if home.exists():
        raise RuntimeError("A signing keyring already exists; inspect it before resuming")
    STATE.mkdir(parents=True, exist_ok=True, mode=0o700)
    STATE.chmod(0o700)
    home.mkdir(mode=0o700)
    # Create a high-entropy protected credential in the login Keychain when
    # provisioning a new identity. Interactive security input avoids argv/env.
    probe = subprocess.run(["security", "find-generic-password", "-s", SERVICE, "-a", ACCOUNT], capture_output=True)
    if probe.returncode:
        value = secrets.token_urlsafe(48)
        command = f"add-generic-password -s {SERVICE} -a {ACCOUNT} -w {value}\n"
        subprocess.run(["security", "-i"], input=command.encode(), capture_output=True)
        if not secrets.compare_digest(secret().strip(), value.encode()):
            raise RuntimeError("Keychain credential provisioning failed")
    password = secret()
    gpg(home, "--quick-generate-key", "XRG-ng Release Signing <sdelavega@users.noreply.github.com>",
        "ed25519", "cert", "2y", password=password)
    listing = gpg(home, "--with-colons", "--list-secret-keys").decode()
    primary = next(line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:"))
    gpg(home, "--quick-add-key", primary, "ed25519", "sign", "1y", password=password)
    listing = gpg(home, "--with-colons", "--list-secret-keys").decode()
    fingerprints = [line.split(":")[9] for line in listing.splitlines() if line.startswith("fpr:")]
    public = gpg(home, "--armor", "--export", primary)
    destination = ROOT / "signing"
    destination.mkdir(exist_ok=True)
    (destination / "xrg-ng-release.asc").write_bytes(public)
    (destination / "fingerprint.txt").write_text(primary + "\n")
    identity = dict(primary_fingerprint=primary, signing_fingerprint=fingerprints[-1],
                    gnupg_home=str(home), keychain_service=SERVICE, keychain_account=ACCOUNT)
    (STATE / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    (STATE / "identity.json").chmod(0o600)
    print(f"Release identity created: {primary}")
    print(f"Protected local keyring: {home}")


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def sign_rpms(directory):
    """Add native RPM header signatures before computing final checksums."""
    identity = json.loads((STATE / "identity.json").read_text())
    if identity["primary_fingerprint"] != (ROOT / "signing/fingerprint.txt").read_text().strip():
        raise RuntimeError("Local identity differs from the pinned release identity")
    packages = sorted(directory.glob("*.rpm"))
    if not packages or any(p.is_symlink() or not p.is_file() for p in packages):
        raise RuntimeError("Expected regular RPM inputs")
    # Prime only the dedicated signing subkey in its own agent. No credential
    # enters RPM's macro definitions, process arguments or the environment.
    with tempfile.TemporaryDirectory(prefix="xrg-rpm-sign-", dir="/tmp") as temporary:
        work = Path(temporary); probe = work / "probe"; probe.write_bytes(b"XRG-ng RPM signing")
        gpg(identity["gnupg_home"], "--local-user", identity["signing_fingerprint"] + "!",
            "--detach-sign", "--output", work / "probe.sig", probe, password=secret())
        database = work / "rpmdb"
        rpm = ["rpm", "--dbpath", str(database)]
        subprocess.run([*rpm, "--initdb"], check=True, capture_output=True)
        subprocess.run([*rpm, "--import", ROOT / "signing/xrg-ng-release.asc"], check=True, capture_output=True)
        for package in packages:
            query = ["rpm", "-qp", "--queryformat", "%{PAYLOADDIGEST}", str(package)]
            before = subprocess.check_output(query, stderr=subprocess.DEVNULL)
            subprocess.run(["rpmsign", "--addsign", "--define", f"__gpg {shutil.which('gpg')}",
                            "--define", f"_gpg_path {identity['gnupg_home']}",
                            "--define", f"_openpgp_sign_id {identity['signing_fingerprint']}!",
                            "--define", f"_gpg_name {identity['signing_fingerprint']}!",
                            "--define", "_gpg_digest_algo SHA256", "--define", "_gpg_sign_cmd_extra_args --batch",
                            str(package)], check=True, capture_output=True)
            if subprocess.check_output(query, stderr=subprocess.DEVNULL) != before:
                raise RuntimeError("RPM payload changed while signing")
            # An isolated database contains exactly our pinned public key.
            result = subprocess.run([*rpm, "--checksig", "--verbose", package], check=True,
                                    capture_output=True, text=True)
            if "signature" not in result.stdout.lower() or "NOT OK" in result.stdout:
                raise RuntimeError("Native RPM signature was not verified")
            Path(str(package) + ".sha256").write_text(f"{digest(package)}  {package.name}\n")
    print("NATIVE_RPM_SIGNATURES_OK")


def sign(directory):
    identity = json.loads((STATE / "identity.json").read_text())
    expected = (ROOT / "signing/fingerprint.txt").read_text().strip()
    if identity["primary_fingerprint"] != expected:
        raise RuntimeError("Local identity differs from the pinned release identity")
    manifest = directory / "SHA256SUMS"
    rows = manifest.read_text().splitlines()
    if not rows:
        raise RuntimeError("Empty release manifest")
    names = set()
    for row in rows:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.+~\-]+)", row)
        if not match or match[2] in names:
            raise RuntimeError("Invalid checksum manifest entry")
        names.add(match[2])
        path = directory / match[2]
        if path.is_symlink() or not path.is_file() or digest(path) != match[1]:
            raise RuntimeError(f"Release payload checksum mismatch: {match[2]}")
    for path in [*(directory / name for name in names), manifest]:
        signature = Path(str(path) + (".sig" if path.name.endswith(".pkg.tar.zst") else ".asc"))
        if signature.exists() or signature.is_symlink():
            raise RuntimeError(f"Signature already exists: {signature.name}")
    password = secret()
    for path in [*(directory / row.split("  ", 1)[1] for row in rows), manifest]:
        signature = Path(str(path) + (".sig" if path.name.endswith(".pkg.tar.zst") else ".asc"))
        if signature.exists() or signature.is_symlink():
            raise RuntimeError(f"Signature already exists: {signature.name}")
        options = [] if path.name.endswith(".pkg.tar.zst") else ["--armor"]
        gpg(identity["gnupg_home"], "--local-user", identity["signing_fingerprint"] + "!",
            "--digest-algo", "SHA256", *options, "--detach-sign", "--output", signature, path, password=password)
    verify(directory)
    print("RELEASE_SIGNATURES_OK")


def verify(directory):
    expected = (ROOT / "signing/fingerprint.txt").read_text().strip()
    public = ROOT / "signing/xrg-ng-release.asc"
    with tempfile.TemporaryDirectory(prefix="xrg-release-verify-", dir="/tmp") as temporary:
        home = Path(temporary); home.chmod(0o700)
        gpg(home, "--no-autostart", "--import", public)
        manifest = directory / "SHA256SUMS"
        signed = gpg(home, "--no-autostart", "--status-fd", "1", "--verify", Path(str(manifest) + ".asc"), manifest).decode()
        if not any(line.startswith("[GNUPG:] VALIDSIG ") and line.split()[-1] == expected for line in signed.splitlines()):
            raise RuntimeError("Checksum manifest is not signed by the pinned primary identity")
        names = []
        for row in manifest.read_text().splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.+~\-]+)", row)
            if not match or match[2] in names:
                raise RuntimeError("Invalid or duplicate checksum entry")
            names.append(match[2]); path = directory / match[2]
            if path.is_symlink() or not path.is_file() or digest(path) != match[1]:
                raise RuntimeError(f"Release checksum mismatch: {match[2]}")
            signature = Path(str(path) + (".sig" if path.name.endswith(".pkg.tar.zst") else ".asc"))
            status = gpg(home, "--no-autostart", "--status-fd", "1", "--verify", signature, path).decode()
            if not any(line.startswith("[GNUPG:] VALIDSIG ") and line.split()[-1] == expected for line in status.splitlines()):
                raise RuntimeError(f"Wrong signing identity: {path.name}")
        if not names:
            raise RuntimeError("Empty release manifest")
        allowed = {"SHA256SUMS", "SHA256SUMS.asc", *names}
        allowed.update(name + (".sig" if name.endswith(".pkg.tar.zst") else ".asc") for name in names)
        if {p.name for p in directory.iterdir()} != allowed:
            raise RuntimeError("Unlisted files in the release directory")
    print("RELEASE_VERIFY_OK")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["init", "rpm", "sign", "verify"])
    parser.add_argument("directory", type=Path, nargs="?")
    args = parser.parse_args()
    try:
        if args.operation == "init":
            initialise()
        elif args.directory is None:
            parser.error("sign/verify requires a release directory")
        else:
            {"rpm": sign_rpms, "sign": sign, "verify": verify}[args.operation](args.directory.resolve())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Release signing: {error}\n")
