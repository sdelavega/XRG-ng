#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Prevent an obsolete Linux application/build path from returning to the checkout."""
from pathlib import Path
root = Path(__file__).resolve().parent.parent
retired = ["xrg-linux/src", "xrg-linux/CMakeLists.txt", "xrg-linux/rust/legacy-gtk",
           "xrg-linux/data/com.gaucho.xrg-linux.desktop"]
def has_retired_content(path):
    if path.is_symlink() or path.is_file():
        return True
    if path.is_dir():
        # Finder metadata is not application source; preserve ignored user files.
        return any(p.is_symlink() or p.is_file() and p.name != ".DS_Store"
                   for p in path.rglob("*"))
    return False
remaining = [p for p in retired if has_retired_content(root / p)]
if remaining:
    raise SystemExit(f"Retired Linux paths returned: {remaining}")
for name in ["xrg-linux/rust/Cargo.toml", "xrg-linux/preview/com.sdelavega.xrg-ng.desktop",
             "xrg-linux/preview/com.sdelavega.xrg-ng.svg", "Shared/include/xrg_shared.h",
             "Tools/SharedABISmoke.c"]:
    if not (root / name).is_file():
        raise SystemExit(f"Required active asset missing: {name}")
print("LINUX_RETIREMENT_OK active Rust/Swift build and assets only")
