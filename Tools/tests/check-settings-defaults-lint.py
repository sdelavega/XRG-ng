#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Fail if any app source file reads or writes a defaults key the catalog maps.

The shared settings document is the source of truth for every catalog setting
(XRG-ng 0.2.3 spec §2/§4): no source file outside the macOS settings store and
the migration may touch the legacy NSUserDefaults key a setting came from.
This lint builds the defaults-key set the catalog maps (each entry's
`legacy.macos` pointer, reduced the way the migration reduces it: the two JSON
blobs are inventoried as paths into the blob, so the key is the pointer's first
component) and flags every Swift or Objective-C file whose text names one of
those keys as a `forKey:` literal.

Keys the catalog deliberately does not map — Sparkle's `SU*` state, AppKit
window frames, `unminimizedFrame`, internal latches, recorded usage data
(docs/settings-inventory.md, spec Non-goals) — are not in the set, so the files
that keep them in NSUserDefaults stay clean.

Test sources and fixtures are out of scope: they exercise the legacy domain on
purpose. Scanned are the application sources: XRGCore, Controllers, and the
other app source directories, plus the shared bridge — everything but
`XRGCore/XRGSettingsStore.swift` (the store itself) and
`Shared/Sources/XRGSharedCore/XRGSettingsMigration.swift` (the migration).

Usage: check-settings-defaults-lint.py [--quiet]
Exits 0 when clean, 1 with one line per violation otherwise.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Shared/Settings/settings-catalog.json"

# The application sources this lint covers; XRGTests and Shared/Tests are
# deliberately not scanned (they exercise the legacy domain on purpose).
SCANNED_DIRECTORIES = ["XRGCore", "Controllers", "Graph Views", "Data Miners",
                       "Resources", "Shared/Bridge"]
ALLOWED = {
    Path("XRGCore/XRGSettingsStore.swift"),
    Path("Shared/Sources/XRGSharedCore/XRGSettingsMigration.swift"),
}

BLOB_PREFIXES = ("graphPresentationV1", "processInspectorV1")


def mapped_keys(catalog):
    """The defaults keys the catalog maps, reduced as the migration reduces them."""
    keys = set()
    for entry in catalog:
        pointer = (entry.get("legacy") or {}).get("macos")
        if not pointer:
            continue
        if any(pointer.startswith(prefix + ".") for prefix in BLOB_PREFIXES):
            keys.add(pointer.split(".", 1)[0])
        else:
            keys.add(pointer)
    return keys


def scanned_files():
    files = []
    for directory in SCANNED_DIRECTORIES:
        base = ROOT / directory
        if not base.is_dir():
            continue
        files.extend(path for path in base.rglob("*")
                     if path.suffix in (".swift", ".m") and path.is_file())
    return [path for path in files
            if path.relative_to(ROOT) not in ALLOWED]


FOR_KEY = re.compile(r'forKey\s*:\s*"([^"]*)"')


def violations():
    catalog = json.loads(CATALOG.read_text())
    keys = mapped_keys(catalog)
    found = []
    for path in scanned_files():
        text = path.read_text(errors="replace")
        touched = sorted({key for key in FOR_KEY.findall(text) if key in keys})
        for key in touched:
            found.append((path.relative_to(ROOT), key))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="print nothing when clean")
    arguments = parser.parse_args()

    found = violations()
    if found:
        for path, key in found:
            print(f"{path}: legacy defaults key {key!r} must go through XRGSettingsStore")
        print(f"{len(found)} violation(s); the settings document owns every catalog key",
              file=sys.stderr)
        return 1
    if not arguments.quiet:
        print("Settings defaults lint clean: every catalog key goes through the store.")
    return 0


if __name__ == "__main__":
    sys.exit(main())