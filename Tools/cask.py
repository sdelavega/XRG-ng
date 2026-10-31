#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Render the Homebrew cask for an XRG-ng release.

Run from the repository root:

    python3 Tools/cask.py --version V --sha256 HEX --output PATH

``--output`` is the cask file to write; an existing directory gets the
cask as ``Casks/xrg-ng.rb`` inside it. The sha256 is the digest of the
release DMG, taken from the macOS release directory's checksums.
"""
import argparse
from pathlib import Path
import re
import sys

CASK_NAME = "Casks/xrg-ng.rb"
# The public Sparkle appcast served from GitHub Pages; the app's update feed
# and the cask's livecheck read the same URL.
APPCAST_URL = "https://sdelavega.github.io/XRG-ng/appcast.xml"

CASK_TEMPLATE = '''cask "xrg-ng" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/sdelavega/XRG-ng/releases/download/v#{{version}}/XRG-ng-#{{version}}-macOS-universal.dmg"
  name "XRG-ng"
  desc "Real-time system resource monitor with floating graphs"
  homepage "https://github.com/sdelavega/XRG-ng"

  livecheck do
    url "{appcast}"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: :tahoe

  app "XRG-ng.app"

  zap trash: [
    "~/Library/Caches/com.sdelavega.xrg",
    "~/Library/HTTPStorages/com.sdelavega.xrg",
    "~/Library/Preferences/com.sdelavega.xrg.plist",
  ]
end
'''

SHA256_RE = re.compile(r"\A[0-9a-fA-F]{64}\Z")
VERSION_RE = re.compile(r"\A[0-9]+\.[0-9]+\.[0-9]+\Z")


def render_cask(version: str, sha256: str) -> str:
    """Return the complete xrg-ng cask for one released version.

    Raises ValueError for anything but a numeric X.Y.Z version or a
    64-character hexadecimal sha256.
    """
    if not VERSION_RE.match(version or ""):
        raise ValueError(f"version must be numeric X.Y.Z, got {version!r}")
    if not SHA256_RE.match(sha256 or ""):
        raise ValueError("sha256 must be 64 hexadecimal characters, got "
                          f"{len(sha256 or '')}: {sha256!r}")
    return CASK_TEMPLATE.format(version=version, sha256=sha256.lower(),
                                 appcast=APPCAST_URL)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--version", required=True, metavar="X.Y.Z",
                        help="released version")
    parser.add_argument("--sha256", required=True, metavar="HEX",
                        help="sha256 of the release DMG")
    parser.add_argument("--output", required=True, metavar="PATH",
                        help="cask file to write (or a directory)")
    arguments = parser.parse_args(argv)
    try:
        rendered = render_cask(arguments.version, arguments.sha256)
    except ValueError as error:
        print(f"CASK_REFUSED {error}", file=sys.stderr)
        return 1
    output = Path(arguments.output)
    if output.is_dir():
        (output / "Casks").mkdir(exist_ok=True)
        output = output / CASK_NAME
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(rendered, encoding="utf-8")
    print(f"CASK_OK {arguments.version} -> {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())