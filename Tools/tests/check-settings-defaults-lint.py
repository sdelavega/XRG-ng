#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Fail if any app source file reads or writes a defaults key the catalog maps.

The shared settings document is the source of truth for every catalog setting
(XRG-ng 0.2.3 spec §2/§4): no source file outside the audited adapters may
touch the legacy NSUserDefaults key a setting came from.

This lint builds the defaults-key set the catalog maps (each entry's
`legacy.macos` pointer, reduced the way the migration reduces it: the two JSON
blobs are inventoried as paths into the blob, so the key is the pointer's
first component) and scans the application sources for every UserDefaults
get/set/remove that names one of those keys:

* a string literal names its key directly;
* a string constant declared in the scanned sources (`static let name =
  "key"`) is resolved, so `forKey: XRGTheme.nameKey` is checked like the
  literal it hides;
* any other key expression — an interpolation, a computed or passed-in key,
  or a dictionary form (`register(defaults:)`, `setValuesForKeys(_:)`) —
  cannot be checked textually and fails outside the allowlist of audited
  adapter files.

The audited adapters are the macOS settings store, the migration, and the
files whose legacy-backend branches must keep writing an injected suite
exactly as 0.2.2 did: the typed settings' theme branch, the graph window's
and the preferences controller's suite registrations, and the monitor-source
blob decode the fixture tests still exercise.

Keys the catalog deliberately does not map — Sparkle's `SU*` state, AppKit
window frames, `unminimizedFrame`, internal latches, recorded usage data
(docs/settings-inventory.md, spec Non-goals) — are not in the set, so the files
that keep them in NSUserDefaults stay clean. Only UserDefaults accessors are
matched; Codable's, dictionaries' and key-value coding's `forKey:` arguments
use other method names.

Test sources and fixtures are out of scope: they exercise the legacy domain on
purpose. Scanned are the application sources: XRGCore, Controllers, and the
other app source directories, plus the shared bridge.

Usage: check-settings-defaults-lint.py [--quiet] [--root DIR]
Exits 0 when clean, 1 with one line per violation otherwise.
"""

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = "Shared/Settings/settings-catalog.json"

# The application sources this lint covers; XRGTests and Shared/Tests are
# deliberately not scanned (they exercise the legacy domain on purpose).
SCANNED_DIRECTORIES = ["XRGCore", "Controllers", "Graph Views", "Data Miners",
                       "Resources", "Shared/Bridge"]
# The audited adapter files (see the module docstring).
ALLOWED = {
    Path("XRGCore/XRGSettingsStore.swift"),
    Path("Shared/Sources/XRGSharedCore/XRGSettingsMigration.swift"),
    Path("XRGCore/XRGSettings.swift"),
    Path("XRGCore/XRGGraphWindow.swift"),
    Path("XRGCore/XRGPrefController.swift"),
    Path("XRGCore/XRGMonitorSource.swift"),
}

BLOB_PREFIXES = ("graphPresentationV1", "processInspectorV1")

# The UserDefaults accessors that name a key through `forKey:`. Codable
# decoders, dictionaries and key-value coding use other method names.
USERDEFAULTS_METHODS = (
    "object", "string", "stringArray", "array", "dictionary", "data",
    "bool", "integer", "float", "double", "url",
    "set", "setObject", "setInteger", "setFloat", "setDouble", "setBool",
    "setData", "removeObject",
)
# Dictionary forms: their keys cannot be inspected textually.
DICTIONARY_FORMS = ("register", "setValuesForKeys")

STRING = re.compile(r'^"((?:[^"\\]|\\.)*)"$')
DOTTED_NAME = re.compile(r"^[A-Za-z_]\w*(\.[A-Za-z_]\w*)+$")
DECLARED_CONSTANT = re.compile(r'static\s+(?:let|var)\s+(\w+)\s*(?::\s*[^=\n]+)?=\s*"((?:[^"\\]|\\.)*)"')


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


def scanned_files(root):
    files = []
    for directory in SCANNED_DIRECTORIES:
        base = root / directory
        if not base.is_dir():
            continue
        files.extend(path for path in base.rglob("*")
                     if path.suffix in (".swift", ".m") and path.is_file())
    return files


def declared_constants(files):
    """The string constants the scanned sources declare: name -> literals."""
    constants = {}
    for path in files:
        for name, literal in DECLARED_CONSTANT.findall(path.read_text(errors="replace")):
            constants.setdefault(name, set()).add(literal)
    return constants


def key_uses(text):
    """Every UserDefaults key expression in the text: (expression, line)."""
    uses = []
    for match in re.finditer(r"\.\s*(\w+)\s*\(", text):
        if match.group(1) not in USERDEFAULTS_METHODS:
            continue
        # The argument span, up to the matching closing parenthesis.
        depth, index = 1, match.end()
        while index < len(text) and depth:
            character = text[index]
            if character == "(":
                depth += 1
            elif character == ")":
                depth -= 1
            index += 1
        arguments = text[match.end():index - 1]
        for named in re.finditer(r"forKey\s*:\s*", arguments):
            start = named.end()
            depth, position = 0, start
            while position < len(arguments):
                character = arguments[position]
                if character in "([":
                    depth += 1
                elif character in ")]":
                    depth -= 1
                elif character == "," and depth == 0:
                    break
                position += 1
            expression = arguments[start:position].strip()
            line = text.count("\n", 0, match.start()) + 1
            uses.append((expression, line))
    return uses


def dictionary_uses(text):
    """Every UserDefaults dictionary form in the text: (method, line)."""
    uses = []
    for match in re.finditer(r"\.\s*(\w+)\s*\(", text):
        if match.group(1) not in DICTIONARY_FORMS:
            continue
        line = text.count("\n", 0, match.start()) + 1
        uses.append((match.group(1), line))
    return uses


def resolve(expression, constants):
    """The key an expression names, None when it cannot be resolved."""
    if "\\(" in expression:  # string interpolation
        return None
    literal = STRING.match(expression)
    if literal:
        return literal.group(1)
    if DOTTED_NAME.match(expression):
        # A qualified name (`XRGTheme.nameKey`): resolve its constant. Bare
        # names are not resolved — a parameter or local can share a constant's
        # name without naming it.
        literals = constants.get(expression.rsplit(".", 1)[1])
        if literals and len(literals) == 1:
            return next(iter(literals))
    return None


def violations(root):
    catalog = json.loads((root / CATALOG).read_text())
    keys = mapped_keys(catalog)
    files = scanned_files(root)
    constants = declared_constants(files)
    found = []
    for path in files:
        relative = path.relative_to(root)
        if relative in ALLOWED:
            continue
        text = path.read_text(errors="replace")
        for expression, line in key_uses(text):
            key = resolve(expression, constants)
            if key is not None:
                if key in keys:
                    found.append((relative, line,
                                   f"legacy defaults key {key!r} must go through XRGSettingsStore"))
            else:
                found.append((relative, line,
                              f"non-literal defaults key ({expression}) must go through XRGSettingsStore; "
                              "only the audited adapter files may use one"))
        for method, line in dictionary_uses(text):
            found.append((relative, line,
                          f"UserDefaults dictionary form ({method}) must go through XRGSettingsStore; "
                          "only the audited adapter files may use one"))
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--quiet", action="store_true", help="print nothing when clean")
    parser.add_argument("--root", type=Path, default=ROOT,
                        help="scan this tree instead of the repository (used by the lint's own tests)")
    arguments = parser.parse_args()

    found = violations(arguments.root)
    if found:
        for path, line, message in found:
            print(f"{path}:{line}: {message}")
        print(f"{len(found)} violation(s); the settings document owns every catalog key",
              file=sys.stderr)
        return 1
    if not arguments.quiet:
        print("Settings defaults lint clean: every catalog key goes through the store.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
