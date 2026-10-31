#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Check that every XRG-ng platform carries one unified version and build number.

Run from the repository root. Exits zero and prints ``VERSION_OK X.Y.Z build N``
when the Xcode project (every target), latest_version.txt and the Linux Cargo
manifest all carry the same version and every Xcode target carries the same
build number; otherwise exits one and lists each disagreeing file.
"""
import argparse
from collections import Counter
from pathlib import Path
import re
import sys
import tomllib

XCODE_PROJECT = "XRG-ng.xcodeproj/project.pbxproj"
LATEST_VERSION = "latest_version.txt"
CARGO_MANIFEST = "xrg-linux/rust/Cargo.toml"


def _build_settings(text, setting):
    """Return every value of one build setting, in project.pbxproj order."""
    return [value.strip().strip('"') for value in
            re.findall(rf"{setting}\s*=\s*([^;]+);", text)]


def _setting_result(values, name, setting):
    """Return (value, error): the unified setting, or why it is unusable."""
    if not values:
        return None, f"{name}: no {setting} entries"
    if len(set(values)) > 1:
        return None, f"{name}: conflicting {setting} values: " + ", ".join(sorted(set(values)))
    return values[0], None


def _single_value(values, name, setting):
    """Return the one distinct value of a build setting across all targets."""
    value, error = _setting_result(values, name, setting)
    if error is not None:
        raise ValueError(error)
    return value


def _project_text(root):
    return (Path(root) / XCODE_PROJECT).read_text(encoding="utf-8")


def read_versions(root: Path) -> dict[str, str]:
    """Map every version source (repository-relative path) to its version.

    Raises ValueError when one source carries conflicting versions itself.
    """
    root = Path(root)
    project = _project_text(root)
    return {
        XCODE_PROJECT: _single_value(_build_settings(project, "MARKETING_VERSION"),
                                     XCODE_PROJECT, "MARKETING_VERSION"),
        LATEST_VERSION: (root / LATEST_VERSION).read_text(encoding="utf-8").strip(),
        CARGO_MANIFEST: tomllib.loads((root / CARGO_MANIFEST).read_text(encoding="utf-8"))
        ["package"]["version"],
    }


def read_build(root: Path) -> str:
    """Return the build number shared by every target in the Xcode project."""
    return _single_value(_build_settings(_project_text(root), "CURRENT_PROJECT_VERSION"),
                         XCODE_PROJECT, "CURRENT_PROJECT_VERSION")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expect", metavar="X.Y.Z",
                        help="require this exact version in every source")
    arguments = parser.parse_args(argv)
    root = Path.cwd()
    failures = []
    versions = {}

    # Diagnose every source independently so one broken or conflicting source
    # cannot suppress the other files' mismatch diagnostics.
    build = None
    try:
        project = _project_text(root)
    except OSError as error:
        failures.append(f"{XCODE_PROJECT}: {error}")
    else:
        version, error = _setting_result(_build_settings(project, "MARKETING_VERSION"),
                                        XCODE_PROJECT, "MARKETING_VERSION")
        if error is None:
            versions[XCODE_PROJECT] = version
        else:
            failures.append(error)
        build, error = _setting_result(_build_settings(project, "CURRENT_PROJECT_VERSION"),
                                       XCODE_PROJECT, "CURRENT_PROJECT_VERSION")
        if error is not None:
            failures.append(error)

    try:
        versions[LATEST_VERSION] = (root / LATEST_VERSION).read_text(encoding="utf-8").strip()
    except OSError as error:
        failures.append(f"{LATEST_VERSION}: {error}")

    try:
        versions[CARGO_MANIFEST] = tomllib.loads(
            (root / CARGO_MANIFEST).read_text(encoding="utf-8"))["package"]["version"]
    except (OSError, ValueError, KeyError) as error:
        failures.append(f"{CARGO_MANIFEST}: {error}")

    if versions:
        expected = arguments.expect or Counter(versions.values()).most_common(1)[0][0]
        failures.extend(f"{name} carries {version}, expected {expected}"
                        for name, version in versions.items() if version != expected)

    if failures:
        for failure in failures:
            print(f"VERSION_CHECK_FAILED {failure}")
        return 1
    print(f"VERSION_OK {expected} build {build}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
