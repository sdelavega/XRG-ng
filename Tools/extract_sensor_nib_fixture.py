#!/usr/bin/env python3
"""Keep the production sensor wiring, but suppress presentation and frame autosave."""
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
from pathlib import Path
import argparse
import re
import xml.etree.ElementTree as ET


def extract(destination: Path) -> Path:
    root = Path(__file__).resolve().parents[1]
    source = (root / "Resources/Sensors.xib").read_text()
    windows = list(re.finditer(r"<window\s[^>]*>", source))
    if len(windows) != 1:
        raise ValueError("Expected exactly one production sensor window")
    match = windows[0]
    tag = re.sub(r'\s+(frameAutosaveName|visibleAtLaunch)="[^"]*"', "", match.group())
    tag = tag[:-1] + ' visibleAtLaunch="NO">'
    fixture = source[:match.start()] + tag + source[match.end():]
    ET.fromstring(fixture)
    destination.write_text(fixture)
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    print(extract(parser.parse_args().destination))
