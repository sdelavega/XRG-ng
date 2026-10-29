#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Require a GTK/GSK/Cairo/GLib-free resolved Cargo dependency graph."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
metadata = json.loads(subprocess.check_output([
    "cargo", "metadata", "--manifest-path", str(root / "xrg-linux/rust/Cargo.toml"),
    "--locked", "--all-features", "--format-version", "1",
], text=True))
forbidden = ("gtk", "gdk", "gsk", "cairo", "glib", "gobject", "gio", "pango", "graphene")
found = sorted(p["name"] for p in metadata["packages"] if p["name"].startswith(forbidden))
if found:
    raise SystemExit(f"Forbidden frontend dependencies: {', '.join(found)}")
print("LINUX_UI_DEPS_OK no GTK/GSK/Cairo/GLib crates")
