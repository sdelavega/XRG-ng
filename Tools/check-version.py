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


def _single_value(values, name, setting):
    """Return the one distinct value of a build setting across all targets."""
    if not values:
        raise ValueError(f"{name}: no {setting} entries")
    if len(set(values)) > 1:
        raise ValueError(f"{name}: conflicting {setting} values: " + ", ".join(sorted(set(values))))
    return values[0]


def read_versions(root: Path) -> dict[str, str]:
    """Map every version source (repository-relative path) to its version.

    Raises ValueError when one source carries conflicting versions itself.
    """
    root = Path(root)
    project = (root / XCODE_PROJECT).read_text(encoding="utf-8")
    return {
        XCODE_PROJECT: _single_value(_build_settings(project, "MARKETING_VERSION"),
                                     XCODE_PROJECT, "MARKETING_VERSION"),
        LATEST_VERSION: (root / LATEST_VERSION).read_text(encoding="utf-8").strip(),
        CARGO_MANIFEST: tomllib.loads((root / CARGO_MANIFEST).read_text(encoding="utf-8"))
        ["package"]["version"],
    }


def read_build(root: Path) -> str:
    """Return the build number shared by every target in the Xcode project."""
    project = (Path(root) / XCODE_PROJECT).read_text(encoding="utf-8")
    return _single_value(_build_settings(project, "CURRENT_PROJECT_VERSION"),
                         XCODE_PROJECT, "CURRENT_PROJECT_VERSION")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expect", metavar="X.Y.Z",
                        help="require this exact version in every source")
    arguments = parser.parse_args(argv)
    root = Path.cwd()
    try:
        versions = read_versions(root)
        build = read_build(root)
    except (OSError, ValueError, KeyError) as error:
        print(f"VERSION_CHECK_FAILED {error}")
        return 1
    expected = arguments.expect or Counter(versions.values()).most_common(1)[0][0]
    disagreements = [(name, version) for name, version in versions.items() if version != expected]
    if disagreements:
        for name, version in disagreements:
            print(f"VERSION_CHECK_FAILED {name} carries {version}, expected {expected}")
        return 1
    print(f"VERSION_OK {expected} build {build}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
