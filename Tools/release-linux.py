#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Collect a successful native Linux candidate, sign it locally, verify every asset."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "sdelavega/XRG-ng"
RUNNERS = {"x86_64": "ubuntu-24.04", "aarch64": "ubuntu-24.04-arm"}
JOBS = {f"{r} {suffix}" for r in RUNNERS.values()
        for suffix in ["debug", "release", "clean runtime install", "rpm install", "arch install"]}
spec = importlib.util.spec_from_file_location("release_signing", ROOT / "Tools/release-signing.py")
signing = importlib.util.module_from_spec(spec); spec.loader.exec_module(signing)


def output(*command):
    return subprocess.check_output(list(map(str, command)), cwd=ROOT, text=True).strip()


def require(value, message):
    if not value:
        raise RuntimeError(message)


def payloads(version, arch):
    deb_arch = {"x86_64": "amd64", "aarch64": "arm64"}[arch]
    return {f"xrg-ng-{version}-linux-{arch}.tar.gz", f"xrg-ng_{version}-1_{deb_arch}.deb",
            f"xrg-ng-{version}-1.{arch}.rpm", f"xrg-ng-{version}-1-{arch}.pkg.tar.zst",
            f"XRG-ng-{version}-{arch}.AppImage"}


def checksum_name(name):
    return name.removesuffix(".tar.gz") + ".sha256" if name.endswith(".tar.gz") else name + ".sha256"


def validate_run(run, jobs, revision):
    require(run["status"] == "completed" and run["conclusion"] == "success", "Candidate CI did not succeed")
    require(run["head_sha"] == revision and run["head_repository"]["full_name"] == REPOSITORY,
            "Candidate source does not match this checkout/repository")
    require(run["event"] == "workflow_dispatch" and run["path"] == ".github/workflows/linux.yml",
            "Expected a manually dispatched Linux release candidate")
    require({j["name"] for j in jobs} == JOBS and all(j["conclusion"] == "success" for j in jobs),
            "All ten native build, desktop and installation jobs must pass")


def validate_artifact(folder, version, arch, revision):
    names = payloads(version, arch)
    expected = names | {checksum_name(n) for n in names}
    require({p.name for p in folder.iterdir()} == expected, "Unexpected candidate artifact inventory")
    require(all(p.is_file() and not p.is_symlink() for p in folder.iterdir()), "Non-regular candidate artifact")
    for name in names:
        require((folder / checksum_name(name)).read_text().split() == [signing.digest(folder / name), name],
                f"Candidate checksum mismatch: {name}")
    archive = folder / f"xrg-ng-{version}-linux-{arch}.tar.gz"
    with tarfile.open(archive) as source:
        members = source.getmembers()
        require(len(members) < 5000 and sum(m.size for m in members) < 2_000_000_000, "Oversized archive")
        matches = [m for m in members if m.name.endswith("/manifest.json")]
        require(len(matches) == 1 and matches[0].isfile() and matches[0].size < 2_000_000, "Missing/ambiguous manifest")
        manifest = json.load(source.extractfile(matches[0]))
    require(manifest.get("channel") == "release" and manifest["dirty"] is False,
            "Candidate must have clean release metadata")
    require((manifest["version"], manifest["architecture"], manifest["revision"]) == (version, arch, revision),
            "Candidate application version/architecture/source mismatch")
    return manifest


def collect(run_id, destination):
    require(not destination.exists() and not destination.is_symlink(), "Use a new release output directory")
    require(not output("git", "status", "--porcelain", "--untracked-files=normal"), "Commit sources before collecting")
    revision = output("git", "rev-parse", "HEAD")
    version = tomllib.loads((ROOT / "xrg-linux/rust/Cargo.toml").read_text())["package"]["version"]
    api = f"repos/{REPOSITORY}/actions/runs/{run_id}"
    run = json.loads(output("gh", "api", api))
    jobs = json.loads(output("gh", "api", api + "/jobs?per_page=100"))["jobs"]
    validate_run(run, jobs, revision)
    with tempfile.TemporaryDirectory(prefix="xrg-release-inputs-") as temporary:
        incoming = Path(temporary)
        manifests = {}
        original_hashes = {}
        for arch, runner in RUNNERS.items():
            folder = incoming / arch
            subprocess.run(["gh", "run", "download", str(run_id), "--repo", REPOSITORY,
                            "--name", f"linux-{runner}-preview", "--dir", str(folder)], check=True)
            manifests[arch] = validate_artifact(folder, version, arch, revision)
            original_hashes.update({n: signing.digest(folder / n) for n in payloads(version, arch)})
        destination.mkdir(parents=True)
        for folder in incoming.iterdir():
            for path in folder.iterdir():
                shutil.copy2(path, destination / path.name)
    # Only RPM headers change after CI. Validate their payload digests and native
    # signatures; retain the original downloaded hashes for provenance.
    signing.sign_rpms(destination)
    for name in ["xrg-ng-release.asc", "fingerprint.txt"]:
        shutil.copyfile(ROOT / "signing" / name, destination / name)
    metadata = dict(format="xrg-ng-linux-release-v1", version=version, revision=revision,
                    workflow_run=run["html_url"], workflow_run_id=run_id, workflow_run_attempt=run["run_attempt"],
                    validated_jobs=sorted(JOBS), original_ci_sha256=original_hashes,
                    rpm_signing="OpenPGP V4 header signature; unchanged payload digest",
                    signing_primary_fingerprint=(ROOT / "signing/fingerprint.txt").read_text().strip(),
                    architectures=sorted(manifests), channel="release")
    (destination / "release-metadata.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
    (destination / "SHA256SUMS").write_text("".join(f"{signing.digest(p)}  {p.name}\n" for p in sorted(destination.iterdir())))
    signing.sign(destination)
    print(f"LINUX_RELEASE_READY version={version} revision={revision} run={run_id} directory={destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        collect(args.run_id, args.output.resolve())
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Linux release: {error}\n")
