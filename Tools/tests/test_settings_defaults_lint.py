#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Negative and positive fixtures for the settings defaults lint.

The lint must catch every form a source file can use to pass a mapped
defaults key to UserDefaults: a string literal, a string constant declared
in the scanned sources, an interpolation, and the dictionary forms
(`register(defaults:)`, `setValuesForKeys(_:)`). Only the audited adapter
files may use a non-literal key or a dictionary form at all.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
LINT = TOOLS / "check-settings-defaults-lint.py"

# A minimal catalog: the lint only reads each entry's legacy.macos pointer.
CATALOG = """[
  {"id": "test.window.title", "section": "general", "control": "text",
   "default": "", "platforms": ["macos"], "legacy": {"macos": "windowTitle"}},
  {"id": "test.graph.cpu.visible", "section": "graphs", "control": "toggle",
   "default": true, "platforms": ["macos"], "legacy": {"macos": "graphPresentationV1.overrides.cpu.visible"}}
]
"""


class SettingsDefaultsLintTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="xrg-settings-lint-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, relative, text):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def lint(self):
        return subprocess.run([sys.executable, str(LINT), "--root", str(self.root)],
                              capture_output=True, text=True)

    def test_literal_mapped_key_is_flagged(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/One.swift", 'let x = defaults.set(true, forKey: "windowTitle")\n')
        result = self.lint()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("XRGCore/One.swift", result.stdout)
        self.assertIn("windowTitle", result.stdout)

    def test_constant_resolving_to_a_mapped_key_is_flagged(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/Two.swift",
                   'enum Keys { static let titleKey = "windowTitle" }\n'
                   'let x = defaults.set(true, forKey: Keys.titleKey)\n')
        result = self.lint()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("XRGCore/Two.swift", result.stdout)
        self.assertIn("windowTitle", result.stdout)

    def test_interpolated_key_is_flagged(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/Three.swift",
                   'let x = defaults.set(true, forKey: "graphPresentationV1_\\(name)")\n')
        result = self.lint()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("XRGCore/Three.swift", result.stdout)
        self.assertIn("non-literal", result.stdout)

    def test_register_dictionary_form_is_flagged(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/Four.swift", 'defaults.register(defaults: ["windowTitle": "x"])\n')
        result = self.lint()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("XRGCore/Four.swift", result.stdout)
        self.assertIn("register", result.stdout)

    def test_set_values_for_keys_form_is_flagged(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/Five.swift", 'defaults.setValuesForKeys(["windowTitle": "x"])\n')
        result = self.lint()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("XRGCore/Five.swift", result.stdout)
        self.assertIn("setValuesForKeys", result.stdout)

    def test_unmapped_keys_stay_clean(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/Six.swift",
                   'let a = defaults.set(true, forKey: "SUEnableAutomaticChecks")\n'
                   'let b = defaults.set(true, forKey: "unminimizedFrame")\n'
                   'let c = defaults.removeObject(forKey: "NSWindow Frame XRGGraph")\n')
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_constant_for_an_unmapped_key_stays_clean(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/Seven.swift",
                   'enum Keys { static let sparkleKey = "SUScheduledCheckInterval" }\n'
                   'let x = defaults.set(86400, forKey: Keys.sparkleKey)\n')
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_audited_adapter_files_are_exempt(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        self.write("XRGCore/XRGSettingsStore.swift",
                   'let a = defaults.set(true, forKey: "windowTitle")\n'
                   'defaults.register(defaults: ["windowTitle": "x"])\n')
        self.write("XRGCore/XRGSettings.swift",
                   'let a = defaults.set(true, forKey: Keys.title)\n')
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_non_defaults_for_key_uses_stay_clean(self):
        self.write("Shared/Settings/settings-catalog.json", CATALOG)
        # Codable decoders, dictionary helpers and key-value coding use
        # forKey too; none of them is a UserDefaults call.
        self.write("XRGCore/Eight.swift",
                   'let a = container.decode(Int.self, forKey: .version)\n'
                   'let b = found.removeValue(forKey: key)\n'
                   'let c = settings?.value(forKey: "backgroundColor")\n'
                   'let d = settings.setValue(0.5, forKey: "backgroundTransparency")\n')
        result = self.lint()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
