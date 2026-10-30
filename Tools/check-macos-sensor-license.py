#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Prevent retired sensor implementations/resources from re-entering current builds."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
retired=["Data Miners/APSL","XRGCore/SMCSensors.swift","XRGCore/XRGSMCInterface.swift","Resources/SMCSensorNames.plist"]
for name in retired:
    if (root/name).exists(): raise SystemExit(f"Retired sensor source/resource present: {name}")
for folder in ["XRGCore","Data Miners"]:
    for p in (root/folder).rglob("*"):
        if p.suffix in [".h",".m",".swift"] and p.is_file():
            text=p.read_text()
            if any(marker in text for marker in ["@APPLE_LICENSE_HEADER_START@","retains APSL","Apple Public Source License"]):
                raise SystemExit(f"Non-GPL sensor implementation marker: {p.relative_to(root)}")
for name in ["XRGCore/XRGSMCReader.swift","XRGCore/XRGSMCSensors.swift","Data Miners/XRGSMCChannel.m","Data Miners/XRGSMCNative.h"]:
    if "SPDX-License-Identifier: GPL-3.0-or-later" not in (root/name).read_text(): raise SystemExit(f"Missing GPL identifier: {name}")
project=(root/"XRG-ng.xcodeproj/project.pbxproj").read_text()
if "APSL" in project or "SMCSensorNames.plist" in project: raise SystemExit("Retired sensor build/resource reference")
print("MAC_SENSOR_LICENSE_GUARD_OK retired sensor sources/resources absent; replacement GPL identifiers present")
