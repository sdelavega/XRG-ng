# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Aether7b token generation: generated files must be current and complete."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

TOOLS = Path(__file__).resolve().parents[1]
ROOT = TOOLS.parent
GENERATOR = TOOLS / "aether7b-tokens.py"
TOKENS = ROOT / "Shared/Design/aether7b.tokens.json"
SWIFT = ROOT / "XRGCore/XRGAether7b.swift"
RUST = ROOT / "xrg-linux/rust/src/ui/aether7b.rs"

_spec = importlib.util.spec_from_file_location("aether7b_tokens", GENERATOR)
aether7b_tokens = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(aether7b_tokens)


def snake_case(name):
    return "".join(
        ("_" if index and ch.isupper() else "") + ch.lower()
        for index, ch in enumerate(name)
    )


class Aether7bTokenTests(unittest.TestCase):
    def test_generated_files_are_current(self):
        result = subprocess.run(
            [sys.executable, str(GENERATOR), "--check"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.returncode, 0, "generated tokens are stale:\n" + result.stdout
        )

    def test_dark_and_light_text_main(self):
        swift = SWIFT.read_text()
        self.assertIn("#E6F0F8", swift, "dark textMain missing from Swift tokens")
        self.assertIn("#13294B", swift, "light textMain missing from Swift tokens")
        rust = RUST.read_text()
        self.assertIn("#E6F0F8", rust, "dark textMain missing from Rust tokens")
        self.assertIn("#13294B", rust, "light textMain missing from Rust tokens")

    def test_no_unknown_roles(self):
        swift = SWIFT.read_text()
        rust = RUST.read_text()
        tokens = __import__("json").loads(TOKENS.read_text())["color"]
        covered = {
            path: swift_name for swift_name, path in aether7b_tokens.ADAPTIVE_ROLES
        }
        covered.update(
            {f"brand.{name}": name for name in aether7b_tokens.BRAND_ROLES}
        )
        for group, entries in tokens.items():
            if group == "$type":
                continue
            for name in entries:
                if name.startswith("$"):
                    continue
                path = f"{group}.{name}"
                self.assertIn(
                    path, covered, f"{path} has no role mapping; a token would be lost"
                )
                self.assertIn(covered[path], swift, f"{path} missing from Swift")
                self.assertIn(
                    snake_case(covered[path]), rust, f"{path} missing from Rust"
                )


if __name__ == "__main__":
    unittest.main()