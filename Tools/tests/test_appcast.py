# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
"""Verify the Sparkle appcast upserter against minimal channel fixtures."""
import importlib.util
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

TOOLS = Path(__file__).resolve().parents[1]
APPCAST = TOOLS / "appcast.py"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"

_spec = importlib.util.spec_from_file_location("appcast", APPCAST)
appcast = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(appcast)

CHANNEL = """<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>XRG-ng</title>
        <link>https://github.com/sdelavega/XRG-ng</link>
        <description>XRG-ng release feed</description>
    </channel>
</rss>
"""

ITEM = {
    "version": "0.2.1",
    "build": "2",
    "url": ("https://github.com/sdelavega/XRG-ng/releases/download/v0.2.1/"
            "XRG-ng-0.2.1-macOS-universal.dmg"),
    "length": 4096,
    "ed_signature": "aGFzaGVkLWVkMjU1MTk=",
    "notes_url": "https://github.com/sdelavega/XRG-ng/releases/tag/v0.2.1",
    "min_system": "26.0",
}


def make_item(**overrides):
    values = dict(ITEM)
    values.update(overrides)
    return appcast.AppcastItem(**values)


def item_spans(feed):
    """Return each <item>...</item> span in the feed, in document order."""
    return [match.group(0) for match in
            re.finditer(r"<item\b.*?</item\s*>", feed, re.DOTALL)]


def with_build_one_item(feed):
    """Return a feed that additionally carries an older build 1 item."""
    older = (
        '        <item sparkle:version="1" sparkle:shortVersionString="0.2.0"'
        ' sparkle:minimumSystemVersion="26.0">\n'
        "            <title>XRG-ng 0.2.0</title>\n"
        "            <pubDate>Thu, 29 Oct 2026 00:00:00 +0000</pubDate>\n"
        "            <sparkle:releaseNotesLink>"
        "https://github.com/sdelavega/XRG-ng/releases/tag/v0.2.0"
        "</sparkle:releaseNotesLink>\n"
        '            <enclosure url="https://example.com/old.dmg" length="2048"'
        ' type="application/octet-stream" sparkle:edSignature="b2xkLXNpZ25hdHVyZQ=="/>'
        "\n        </item>\n"
    )
    return feed.replace("    </channel>", older + "    </channel>")


class AppcastTest(unittest.TestCase):
    def upsert(self, xml, item=None):
        return appcast.upsert_item(xml, item or make_item())

    def items(self, xml):
        return ET.fromstring(xml).findall(".//item")

    def test_insert_into_empty_channel(self):
        result = self.upsert(CHANNEL)
        items = self.items(result)
        self.assertEqual(len(items), 1)
        item = items[0]
        self.assertEqual(item.get(f"{{{SPARKLE_NS}}}version"), "2")
        self.assertEqual(item.get(f"{{{SPARKLE_NS}}}shortVersionString"), "0.2.1")
        self.assertEqual(item.get(f"{{{SPARKLE_NS}}}minimumSystemVersion"), "26.0")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("length"), "4096")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(f"{{{SPARKLE_NS}}}edSignature"),
                         ITEM["ed_signature"])
        self.assertEqual(enclosure.get("url"), ITEM["url"])
        self.assertEqual(item.find("sparkle:releaseNotesLink").text
                         if item.find("sparkle:releaseNotesLink") is not None
                         else item.find(f"{{{SPARKLE_NS}}}releaseNotesLink").text,
                         ITEM["notes_url"])

    def test_upsert_same_build_replaces(self):
        feed = with_build_one_item(self.upsert(CHANNEL, make_item(
            ed_signature="b2xkLWJ1aWxkLTI=", length=2048)))
        spans_before = item_spans(feed)
        result = self.upsert(feed)
        spans_after = item_spans(result)
        self.assertEqual(len(spans_after), 2)
        build_one = [s for s in spans_after if 'sparkle:version="1"' in s]
        self.assertEqual(build_one, [s for s in spans_before
                                     if 'sparkle:version="1"' in s])
        updated = [s for s in spans_after if 'sparkle:version="2"' in s]
        self.assertEqual(len(updated), 1)
        self.assertIn(ITEM["ed_signature"], updated[0])
        self.assertNotIn("b2xkLWJ1aWxkLTI=", updated[0])
        self.assertIn('length="4096"', updated[0])
        items = self.items(result)
        self.assertEqual(len(items), 2)

    def test_new_item_is_first(self):
        feed = with_build_one_item(CHANNEL)
        result = self.upsert(feed)
        items = self.items(result)
        self.assertEqual(items[0].get(f"{{{SPARKLE_NS}}}version"), "2")
        self.assertEqual(items[1].get(f"{{{SPARKLE_NS}}}version"), "1")
        first = re.search(r"<item\b.*?</item\s*>", result, re.DOTALL)
        self.assertEqual(first.group(0), item_spans(result)[0])
        self.assertIn(ITEM["ed_signature"], first.group(0))

    def test_rejects_bad_signature_or_length(self):
        temporary = tempfile.TemporaryDirectory(prefix="xrg-appcast-")
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "appcast.xml"
        path.write_text(CHANNEL, encoding="utf-8")
        before = path.read_bytes()
        with self.assertRaises(ValueError):
            self.upsert(CHANNEL, make_item(ed_signature=""))
        with self.assertRaises(ValueError):
            self.upsert(CHANNEL, make_item(length=0))
        with self.assertRaises(ValueError):
            self.upsert(CHANNEL, make_item(length=-1))
        result = subprocess.run(
            [sys.executable, str(APPCAST), "--appcast", str(path),
             "--version", ITEM["version"], "--build", ITEM["build"],
             "--url", ITEM["url"], "--length", "0",
             "--ed-signature", ITEM["ed_signature"],
             "--notes-url", ITEM["notes_url"],
             "--min-system", ITEM["min_system"]],
            text=True, capture_output=True, timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(path.read_bytes(), before)

    def test_output_parses_with_sparkle_namespace(self):
        result = self.upsert(CHANNEL, make_item(pub_date="Fri, 30 Oct 2026 00:00:00 +0000"))
        root = ET.fromstring(result)  # must not raise
        enclosure = root.find(".//enclosure")
        self.assertEqual(
            enclosure.get(f"{{{SPARKLE_NS}}}edSignature"), ITEM["ed_signature"])
        item = root.find(".//item")
        self.assertEqual(item.get(f"{{{SPARKLE_NS}}}version"), "2")
        self.assertEqual(item.findtext("pubDate"),
                         "Fri, 30 Oct 2026 00:00:00 +0000")

    def test_cli_upserts_file(self):
        temporary = tempfile.TemporaryDirectory(prefix="xrg-appcast-")
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "appcast.xml"
        path.write_text(CHANNEL, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(APPCAST), "--appcast", str(path),
             "--version", ITEM["version"], "--build", ITEM["build"],
             "--url", ITEM["url"], "--length", str(ITEM["length"]),
             "--ed-signature", ITEM["ed_signature"],
             "--notes-url", ITEM["notes_url"],
             "--min-system", ITEM["min_system"],
             "--pub-date", "Fri, 30 Oct 2026 01:02:03 +0000"],
            text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        items = self.items(path.read_text(encoding="utf-8"))
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0].findtext("pubDate"),
                         "Fri, 30 Oct 2026 01:02:03 +0000")


if __name__ == "__main__":
    unittest.main()