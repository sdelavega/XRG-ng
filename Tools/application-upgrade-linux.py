#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Upgrade actual desktop application versions using their production installers."""
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

BASELINE = "50ca1e54f44ed66608b069cc5483dde7f057d281"


def require(value, message):
    if not value:
        raise RuntimeError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def fixture():
    names = ["weather", "cpu", "gpu", "tpu", "memory", "battery", "temperature",
             "network", "disk", "ai", "processes", "gpu_memory", "fans"]
    return dict(version=21, theme={"kind": "custom", "theme": {
        "format": "xrg-ng-theme", "version": 1, "name": "Upgrade preserved theme",
        "colors": [[0.01 * n, 0.123456789, 0.6, 0.95] for n in range(7)]}},
        modules=[dict(id=name, visible=name not in {"weather", "gpu_memory", "fans"}, style="dot",
                      colors={"background": [0.125, 0.25, 0.375, 0.875], "series": [None, None, None]},
                      **({"height": 124} if name == "cpu" else {})) for name in names],
        graph_height=132, graph_width=210, sampling_interval_ms=250, window_opacity=0.85,
        network_min_scale=1000000, ai_show_model_breakdown=False,
        ai={"enabled": [False] * 4, "ollama": False, "claude_source": "logs",
            "codex_logs": "/tmp/xrg-upgrade-provider-data", "metrics_url": "http://127.0.0.1:8891/metrics"},
        weather={"enabled": False, "station": "KJFK", "refresh_minutes": 30})


def subset(expected, actual):
    if isinstance(expected, dict):
        return isinstance(actual, dict) and all(k in actual and subset(v, actual[k]) for k, v in expected.items())
    if isinstance(expected, list):
        return isinstance(actual, list) and len(expected) == len(actual) and all(subset(a, b) for a, b in zip(expected, actual))
    return expected == actual


def smoke(args):
    require(platform.system() == "Linux" and os.getuid() != 0, "Run as an ordinary Linux user")
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
        require(old[1]["revision"] == BASELINE and old[1]["version"] == "0.2.0", "Wrong frozen baseline")
        require(new[1]["version"] == "0.2.1" and new[1]["revision"] != BASELINE, "Expected application 0.2.1")
        require(digest(old[0] / "bin/xrg-ng-linux") != digest(new[0] / "bin/xrg-ng-linux"), "Application bytes did not change")
        env = {k: v for k, v in os.environ.items() if not k.startswith(("LD_", "DYLD_"))}
        env.update(HOME=str(work / "home"), XDG_CONFIG_HOME=str(work / "config"),
                   XDG_DATA_HOME=str(work / "data"), XDG_CACHE_HOME=str(work / "cache"), LIBGL_ALWAYS_SOFTWARE="1")
        Path(env["HOME"]).mkdir()
        config = Path(env["XDG_CONFIG_HOME"]) / "xrg-ng/settings.conf"
        config.parent.mkdir(parents=True)
        expected = fixture(); original = (json.dumps(expected, indent=2) + "\n").encode(); config.write_bytes(original)
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

        for label, (root, manifest) in [("old", old), ("new", new)]:
            run([root / "install.sh", "--prefix", prefix], f"{label}-install.log")
            require(run([installed, "--version"], f"{label}-version.log").strip() == f"XRG-ng {manifest['version']}", "Version mismatch")
            run([installed, "--headless", "--samples", "2"], f"{label}-headless.log")
            require(config.read_bytes() == original, "Installing/starting an application changed settings")
        parsed = json.loads(run([installed, "--check-settings"], "new-effective-settings.json"))
        # The schema marker advances when the new application migrates the file; every user value must survive.
        require(isinstance(parsed.get("version"), int) and parsed["version"] >= expected["version"],
                "Settings schema version regressed during application upgrade")
        require(subset({k: v for k, v in expected.items() if k != "version"}, parsed),
                "Effective settings changed during application upgrade")
        run([prefix / "lib/xrg-ng/uninstall.sh", "--prefix", prefix], "uninstall.log")
        require(config.read_bytes() == original, "Uninstall changed preferences")
        (results / "versions.json").write_text(json.dumps({"baseline": old[1]["version"], "baseline_revision": BASELINE,
                                                         "current": new[1]["version"], "current_revision": new[1]["revision"]}, indent=2) + "\n")
    message = "APPLICATION_UPGRADE_OK 0.2.0-to-0.2.1 distinct-binaries effective-preferences-preserved"
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
