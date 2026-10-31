#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Upsert one Sparkle appcast item for an XRG-ng release.

Run from the repository root:

    python3 Tools/appcast.py --appcast docs/appcast.xml --version V \
        --build B --url URL --length N --ed-signature SIG \
        --notes-url URL --min-system 26.0 [--pub-date RFC822]

The item is keyed on ``sparkle:version`` (the build number): an existing
item with the same build is replaced in place and every other item is
spliced through byte-identically (existing items are never re-serialized,
so comments, attribute order and whitespace survive). A new item is
inserted as the first ``<item>`` in the channel, above every older
release. ``--pub-date`` defaults to the current UTC time in RFC 822
format. ``--item-out PATH`` optionally also writes the standalone item
XML, which the release script stores next to the DMG as
``appcast-item.xml``.
"""
import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
import re
import sys
from xml.etree import ElementTree
from xml.sax.saxutils import escape

ITEM_SPAN = re.compile(r"<item\b.*?</item\s*>", re.DOTALL)
ITEM_VERSION = re.compile(r'sparkle:version="([^"\n]*)"', re.DOTALL)


@dataclass
class AppcastItem:
    """One release item: build keys the upsert, version is the marketing version."""
    version: str
    build: str
    url: str
    length: int
    ed_signature: str
    notes_url: str
    min_system: str
    pub_date: str | None = None

    def __post_init__(self):
        self.length = int(self.length)


def _attr(value):
    return escape(str(value), {'"': "&quot;", "\n": "&#10;"})


def _default_pub_date():
    return format_datetime(datetime.now(timezone.utc))


def _validate(item):
    if not item.ed_signature:
        raise ValueError("ed_signature must not be empty")
    if item.length <= 0:
        raise ValueError(f"length must be positive, got {item.length}")
    if not item.build:
        raise ValueError("build must not be empty")
    if not item.version:
        raise ValueError("version must not be empty")
    if not item.url:
        raise ValueError("url must not be empty")


def render_item(item, indent="        "):
    """Return the item XML with the given indentation, as a text splice."""
    _validate(item)
    pub_date = item.pub_date or _default_pub_date()
    nested = indent + "    "
    return "\n".join([
        f'<item sparkle:version="{_attr(item.build)}"'
        f' sparkle:shortVersionString="{_attr(item.version)}"'
        f' sparkle:minimumSystemVersion="{_attr(item.min_system)}">',
        f"{nested}<title>XRG-ng {escape(str(item.version))}</title>",
        f"{nested}<pubDate>{escape(str(pub_date))}</pubDate>",
        f"{nested}<sparkle:releaseNotesLink>{_attr(item.notes_url)}"
        "</sparkle:releaseNotesLink>",
        f'{nested}<enclosure url="{_attr(item.url)}" length="{_attr(item.length)}"'
        f' type="application/octet-stream"'
        f' sparkle:edSignature="{_attr(item.ed_signature)}"/>',
        f"{indent}</item>",
    ])


def _line_indent(xml, index):
    """Return the whitespace run between the last newline before ``index``."""
    start = xml.rfind("\n", 0, index) + 1
    prefix = xml[start:index]
    return prefix if prefix.strip() == "" else ""


def _channel_close(xml):
    close = xml.find("</channel>")
    if close < 0:
        raise ValueError("appcast has no <channel>")
    return close


def upsert_item(xml: str, item: AppcastItem) -> str:
    """Return ``xml`` with ``item`` upserted, keyed on ``sparkle:version``.

    Existing items are spliced as raw text: an item carrying the same
    build is replaced in place, every other item stays byte-identical,
    and a new item becomes the first ``<item>`` in the channel.
    """
    _validate(item)
    close = _channel_close(xml)
    rendered = None
    for match in ITEM_SPAN.finditer(xml):
        if match.start() > close:
            break
        if ITEM_VERSION.search(match.group(0)).group(1) == item.build:
            indent = _line_indent(xml, match.start())
            return xml[:match.start()] + render_item(item, indent) + xml[match.end():]
    # No item carries this build: insert above the first item, or just
    # before </channel> in an empty channel, as the newest release.
    spans = [match for match in ITEM_SPAN.finditer(xml) if match.start() <= close]
    if spans:
        first = spans[0]
        indent = _line_indent(xml, first.start())
        block = render_item(item, indent) + "\n" + indent
        return xml[:first.start()] + block + xml[first.start():]
    indent = _line_indent(xml, close)
    if not indent:
        indent = "    "
    return xml[:close] + render_item(item, indent) + "\n" + indent + xml[close:]


def _parse_date(value):
    if value is None:
        return _default_pub_date()
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--appcast", required=True, metavar="PATH",
                        help="working-tree appcast.xml to update")
    parser.add_argument("--item-out", metavar="PATH",
                        help="also write the standalone item XML here")
    parser.add_argument("--version", required=True, help="marketing version")
    parser.add_argument("--build", required=True, help="build (sparkle:version)")
    parser.add_argument("--url", required=True, help="enclosure URL")
    parser.add_argument("--length", required=True,
                        help="enclosure length in bytes")
    parser.add_argument("--ed-signature", required=True,
                        help="Sparkle ed25519 signature of the DMG")
    parser.add_argument("--notes-url", required=True,
                        help="release notes URL for the item")
    parser.add_argument("--min-system", required=True,
                        help="sparkle:minimumSystemVersion")
    parser.add_argument("--pub-date", metavar="RFC822",
                        help="pubDate (default: current UTC time)")
    arguments = parser.parse_args(argv)

    item = AppcastItem(version=arguments.version, build=arguments.build,
                       url=arguments.url, length=arguments.length,
                       ed_signature=arguments.ed_signature,
                       notes_url=arguments.notes_url,
                       min_system=arguments.min_system,
                       pub_date=_parse_date(arguments.pub_date))
    path = Path(arguments.appcast)
    try:
        xml = path.read_text(encoding="utf-8")
        ElementTree.fromstring(xml)  # refuse to splice a malformed appcast
        updated = upsert_item(xml, item)
        ElementTree.fromstring(updated)  # the splice must stay well-formed
    except (OSError, ValueError, ElementTree.ParseError) as error:
        print(f"APPCAST_UPDATE_FAILED {path}: {error}", file=sys.stderr)
        return 1
    path.write_text(updated, encoding="utf-8")
    if arguments.item_out:
        indent = _line_indent(updated, updated.find("<item"))
        Path(arguments.item_out).write_text(
            render_item(item, indent) + "\n", encoding="utf-8")
    print(f"APPCAST_OK {item.build} -> {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())