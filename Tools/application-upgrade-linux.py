#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Upgrade actual desktop application versions using their production installers.

0.2.2 -> 0.2.3 -> 0.2.2: seed a real version-40 settings.conf, run the frozen
0.2.2 application (its effective settings are the downgrade baseline), upgrade
to 0.2.3 (which migrates settings.conf into the shared settings.json exactly
once, leaving settings.conf byte-identical), then run 0.2.2 again and prove its
effective settings are unchanged. The seeded v40 file and the hand-derived
expected document are the Task 4 conformance fixtures.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile

BASELINE = "9a4b401063335417ba89fa22643eb430b10a0e8e"  # v0.2.2 (Linux 0.2.2)
ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Shared/Tests/Fixtures/settings"


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fixtures():
    """The hand-derived v40 seed and its canonical migrated document."""
    seed = (FIXTURES / "linux-v40.json").read_bytes()
    expected = json.loads((FIXTURES / "linux-v40-expected.json").read_text())
    require(isinstance(expected.get("diagnostics"), list) and expected["diagnostics"] == [],
            "v40 fixture reports migration diagnostics")
    require(isinstance(expected.get("document"), str) and expected["document"],
            "v40 fixture has no expected document")
    return seed, expected["document"].encode()


def smoke(args):
    require(platform.system() == "Linux" and os.getuid() != 0, "Run as an ordinary Linux user")
    seed, expected_document = fixtures()
    results = args.results.resolve(); results.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="xrg-application-upgrade-") as temporary:
        work = Path(temporary)
        bundles = []
        for label, archive in [("old", args.baseline.resolve()), ("new", args.current.resolve())]:
            checksum = archive.with_suffix("").with_suffix(".sha256").read_text().split()
            require(checksum == [digest(archive), archive.name], f"{label} archive checksum mismatch")
            with tarfile.open(archive) as source:
                members = source.getmembers()
                require(len(members) < 5000 and sum(m.size for m in members) < 2_000_000_000
                        and all(m.isfile() or m.isdir() for m in members), "Unsafe archive")
                source.extractall(work / label, filter="data")
            root = next((work / label).iterdir())
            manifest = json.loads((root / "manifest.json").read_text())
            require(not manifest["dirty"] and manifest["architecture"] == platform.machine(), "Invalid source/architecture")
            bundles.append((root, manifest))
        old, new = bundles
        require(old[1]["revision"] == BASELINE and old[1]["version"] == "0.2.2", "Wrong frozen 0.2.2 baseline")
        require(new[1]["revision"] != BASELINE, "Expected the current (0.2.3) application build")
        require(digest(old[0] / "bin/xrg-ng-linux") != digest(new[0] / "bin/xrg-ng-linux"), "Application bytes did not change")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("LD_", "DYLD_"))}
        env.update(HOME=str(work / "home"), XDG_CONFIG_HOME=str(work / "config"),
                   XDG_DATA_HOME=str(work / "data"), XDG_CACHE_HOME=str(work / "cache"), LIBGL_ALWAYS_SOFTWARE="1")
        Path(env["HOME"]).mkdir()
        config_dir = Path(env["XDG_CONFIG_HOME"]) / "xrg-ng"
        config_dir.mkdir(parents=True)
        config = config_dir / "settings.conf"            # the 0.2.2 legacy file
        document = config_dir / "settings.json"          # the 0.2.3 shared document
        config.write_bytes(seed)
        prefix = work / 'upgrade installation $cash % spaces'
        installed = prefix / "bin/xrg-ng-linux"

        def run(command, name):
            result = subprocess.run(list(map(str, command)), env=env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=90)
            (results / name).write_text(result.stdout + result.stderr)
            require(result.returncode == 0, f"{name} failed: {result.stderr[-2000:]}")
            require("Preferences unavailable" not in result.stderr and "Preferences invalid" not in result.stderr,
                    "Application rejected the upgrade preferences")
            return result.stdout

        def install(root, label):
            run([root / "install.sh", "--prefix", prefix], f"{label}-install.log")
            run([installed, "--version"], f"{label}-version.log")

        # 1. Frozen 0.2.2: read the seeded v40 settings.conf, record its effective
        #    settings as the downgrade baseline. Nothing may rewrite settings.conf.
        install(old[0], "old-0.2.2")
        run([installed, "--headless", "--samples", "2"], "old-headless.log")
        baseline_effective = json.loads(run([installed, "--check-settings"], "old-effective-settings.json"))
        require(config.read_bytes() == seed, "0.2.2 changed settings.conf")
        require(not document.exists(), "0.2.2 unexpectedly created a settings document")

        # 2. Upgrade to 0.2.3: the shared core migrates settings.conf into
        #    settings.json once, leaving the legacy file byte-identical.
        install(new[0], "new-0.2.3")
        run([installed, "--headless", "--samples", "2"], "new-headless.log")
        require(config.read_bytes() == seed, "Installing/starting 0.2.3 changed settings.conf")
        require(document.is_file(), "0.2.3 did not migrate settings.conf into settings.json")
        actual_document = document.read_bytes()
        require(actual_document == expected_document,
                "Migrated settings.json differs from the expected document")
        (results / "settings.json").write_bytes(actual_document)

        # 3. Downgrade: re-install and run 0.2.2 again; it must still read its
        #    own, untouched settings.conf and produce the same effective settings.
        install(old[0], "old-0.2.2-again")
        downgrade_effective = json.loads(run([installed, "--check-settings"], "old-effective-settings-again.json"))
        require(downgrade_effective == baseline_effective,
                "0.2.2 effective settings changed after the 0.2.3 upgrade")
        require(config.read_bytes() == seed, "0.2.2 changed settings.conf on the downgrade")

        run([prefix / "lib/xrg-ng/uninstall.sh", "--prefix", prefix], "uninstall.log")
        require(config.read_bytes() == seed, "Uninstall changed preferences")
        (results / "versions.json").write_text(json.dumps({"baseline": old[1]["version"], "baseline_revision": BASELINE,
                                                          "current": new[1]["version"], "current_revision": new[1]["revision"]}, indent=2) + "\n")
    message = ("APPLICATION_UPGRADE_OK 0.2.2-to-0.2.3 "
               "settings-json-matches-expected settings-conf-unchanged effective-preferences-preserved")
    (results / "summary.txt").write_text(message + "\n"); print(message)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--current", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    try:
        smoke(parser.parse_args())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Application upgrade: {error}\n")
