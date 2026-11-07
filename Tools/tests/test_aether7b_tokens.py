# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Aether7b token generation: generated files must be current and complete."""
import copy
import hashlib
import importlib.util
import json
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

# SHA-256 of the upstream tokens/aether7b.tokens.json at aether7b commit
# 3bc86b3 (v1.1), so this test never needs the external repo.
UPSTREAM_SHA256 = "23c1bd0fa77f3e53799c75c336d11020ed05680b94366340ac06d1597583caa4"

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

    def test_vendored_tokens_are_upstream_bytes(self):
        """The vendored JSON must be the upstream file plus only the $source line."""
        vendored = TOKENS.read_bytes()
        stripped = b"".join(
            line
            for line in vendored.splitlines(keepends=True)
            if b'"$source"' not in line
        )
        self.assertEqual(
            hashlib.sha256(stripped).hexdigest(),
            UPSTREAM_SHA256,
            "vendored token file drifted from upstream 3bc86b3",
        )

    def test_value_tokens_propagate_to_outputs(self):
        """Radii, durations and easing must come from the token file, not the code."""
        tokens = json.loads(TOKENS.read_text())
        baseline_swift = aether7b_tokens.generate_swift(tokens)
        baseline_rust = aether7b_tokens.generate_rust(tokens)
        probes = [
            (
                lambda t: t["radius"].update(
                    {"sm": {"$value": {"value": 7, "unit": "px"}}}
                ),
                ["public static let sm: CGFloat = 7"],
                ["RADIUS_SM: f32 = 7.0"],
            ),
            (
                lambda t: t["radius"].update(
                    {"md": {"$value": {"value": 9, "unit": "px"}}}
                ),
                ["public static let md: CGFloat = 9"],
                ["RADIUS_MD: f32 = 9.0"],
            ),
            (
                lambda t: t["radius"].update(
                    {"lg": {"$value": {"value": 14, "unit": "px"}}}
                ),
                ["public static let lg: CGFloat = 14"],
                ["RADIUS_LG: f32 = 14.0"],
            ),
            (
                lambda t: t["motion"]["duration"].update(
                    {"fast": {"$value": {"value": 150, "unit": "ms"}}}
                ),
                ["public static let fast: TimeInterval = 0.150"],
                ["MOTION_FAST: Duration = Duration::from_millis(150);"],
            ),
            (
                lambda t: t["motion"]["duration"].update(
                    {"base": {"$value": {"value": 210, "unit": "ms"}}}
                ),
                ["public static let base: TimeInterval = 0.210"],
                ["MOTION_BASE: Duration = Duration::from_millis(210);"],
            ),
            (
                lambda t: t["motion"]["duration"].update(
                    {"slow": {"$value": {"value": 330, "unit": "ms"}}}
                ),
                ["public static let slow: TimeInterval = 0.330"],
                ["MOTION_SLOW: Duration = Duration::from_millis(330);"],
            ),
            (
                lambda t: t["motion"]["easing"].update(
                    {"standard": {"$value": [0.5, 0, 0.5, 1]}}
                ),
                ["public static let ease: [CGFloat] = [0.5, 0.0, 0.5, 1.0]"],
                ["pub const EASE: [f32; 4] = [0.5, 0.0, 0.5, 1.0];"],
            ),
        ]
        original = copy.deepcopy(tokens)
        for mutate, swift_literals, rust_literals in probes:
            with self.subTest(mutate=mutate):
                mutate(tokens)
                swift = aether7b_tokens.generate_swift(tokens)
                rust = aether7b_tokens.generate_rust(tokens)
                self.assertNotEqual(
                    swift, baseline_swift, "Swift output ignored a token change"
                )
                self.assertNotEqual(
                    rust, baseline_rust, "Rust output ignored a token change"
                )
                for literal in swift_literals:
                    self.assertIn(literal, swift)
                for literal in rust_literals:
                    self.assertIn(literal, rust)
                tokens.clear()
                tokens.update(copy.deepcopy(original))

    def test_check_rejects_crlf_copy(self):
        """A CRLF rewrite of a generated file must fail --check byte for byte."""
        for path in (SWIFT, RUST):
            original = path.read_bytes()
            try:
                path.write_bytes(original.replace(b"\n", b"\r\n"))
                result = subprocess.run(
                    [sys.executable, str(GENERATOR), "--check"],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    result.returncode,
                    1,
                    f"--check accepted a CRLF copy of {path.name}",
                )
            finally:
                path.write_bytes(original)

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