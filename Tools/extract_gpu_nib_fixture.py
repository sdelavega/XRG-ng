#!/usr/bin/env python3
"""Regenerate the GPU fixture using the shared legacy-panel extractor."""
from pathlib import Path
import sys

sys.dont_write_bytecode = True
from extract_panel_nib_fixture import extract

if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    print(extract('XRGGPUView', root / 'XRGTests/Fixtures/LegacyGPU.nib'))
