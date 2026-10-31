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


def element_item(build, version, signature, length):
    """A standard Sparkle 2 item: version metadata as child elements."""
    return (
        "        <item>\n"
        f"            <title>XRG-ng {version}</title>\n"
        "            <pubDate>Thu, 29 Oct 2026 00:00:00 +0000</pubDate>\n"
        f"            <sparkle:version>{build}</sparkle:version>\n"
        f"            <sparkle:shortVersionString>{version}"
        "</sparkle:shortVersionString>\n"
        "            <sparkle:minimumSystemVersion>26.0"
        "</sparkle:minimumSystemVersion>\n"
        "            <sparkle:releaseNotesLink>"
        f"https://github.com/sdelavega/XRG-ng/releases/tag/v{version}"
        "</sparkle:releaseNotesLink>\n"
        f'            <enclosure url="https://example.com/xrg-{build}.dmg"'
        f' length="{length}" type="application/octet-stream"'
        f' sparkle:edSignature="{signature}"/>\n'
        "        </item>\n"
    )


def with_item(feed, item_xml):
    return feed.replace("    </channel>", item_xml + "    </channel>")


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
        # Sparkle 2 metadata lives in child elements, not attributes.
        self.assertIsNone(item.get(f"{{{SPARKLE_NS}}}version"))
        self.assertEqual(item.findtext("title"), "XRG-ng 0.2.1")
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}version"), "2")
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}shortVersionString"),
                         "0.2.1")
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion"),
                         "26.0")
        self.assertTrue(item.findtext("pubDate"))
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("length"), "4096")
        self.assertEqual(enclosure.get("type"), "application/octet-stream")
        self.assertEqual(enclosure.get(f"{{{SPARKLE_NS}}}edSignature"),
                         ITEM["ed_signature"])
        self.assertEqual(enclosure.get("url"), ITEM["url"])
        self.assertEqual(
            item.findtext(f"{{{SPARKLE_NS}}}releaseNotesLink"),
            ITEM["notes_url"])

    def test_upsert_same_build_replaces(self):
        feed = with_item(CHANNEL, element_item(
            "2", "0.2.1", "b2xkLWJ1aWxkLTI=", 2048))
        feed = with_item(feed, element_item("1", "0.2.0", "b2xkLXNpZw==", 1024))
        spans_before = item_spans(feed)
        result = self.upsert(feed)
        spans_after = item_spans(result)
        self.assertEqual(len(spans_after), 2)
        # The unrelated standard element-form item stays byte-identical.
        self.assertEqual(
            [s for s in spans_after if "<sparkle:version>1</sparkle:version>" in s],
            [s for s in spans_before
             if "<sparkle:version>1</sparkle:version>" in s])
        # The matching build-2 item is replaced in place.
        updated = [s for s in spans_after
                   if "<sparkle:version>2</sparkle:version>" in s]
        self.assertEqual(len(updated), 1)
        self.assertIn(ITEM["ed_signature"], updated[0])
        self.assertNotIn("b2xkLWJ1aWxkLTI=", updated[0])
        self.assertIn('length="4096"', updated[0])
        items = self.items(result)
        self.assertEqual(len(items), 2)
        self.assertEqual(items[0].findtext(f"{{{SPARKLE_NS}}}version"), "2")
        self.assertEqual(items[1].findtext(f"{{{SPARKLE_NS}}}version"), "1")

    def test_new_item_is_first(self):
        feed = with_item(CHANNEL, element_item("1", "0.2.0", "b2xkLXNpZw==", 1024))
        result = self.upsert(feed)
        items = self.items(result)
        self.assertEqual(items[0].findtext(f"{{{SPARKLE_NS}}}version"), "2")
        self.assertEqual(items[1].findtext(f"{{{SPARKLE_NS}}}version"), "1")
        first = re.search(r"<item\b.*?</item\s*>", result, re.DOTALL)
        self.assertEqual(first.group(0), item_spans(result)[0])
        self.assertIn(ITEM["ed_signature"], first.group(0))

    def test_upsert_replaces_legacy_attribute_item(self):
        legacy = (
            '        <item sparkle:version="1"'
            ' sparkle:shortVersionString="0.2.0"'
            ' sparkle:minimumSystemVersion="26.0">\n'
            "            <title>XRG-ng 0.2.0</title>\n"
            "            <pubDate>Thu, 29 Oct 2026 00:00:00 +0000</pubDate>\n"
            "            <sparkle:releaseNotesLink>"
            "https://github.com/sdelavega/XRG-ng/releases/tag/v0.2.0"
            "</sparkle:releaseNotesLink>\n"
            '            <enclosure url="https://example.com/old.dmg"'
            ' length="2048" type="application/octet-stream"'
            ' sparkle:edSignature="b2xkLXNpZ25hdHVyZQ=="/>\n'
            "        </item>\n"
        )
        feed = with_item(CHANNEL, legacy)
        # A new build leaves the legacy item untouched.
        result = self.upsert(feed)
        self.assertEqual(len(item_spans(result)), 2)
        self.assertIn(legacy, result)
        # The legacy item's build is still identified from the attribute.
        replaced = self.upsert(feed, make_item(build="1"))
        self.assertEqual(len(item_spans(replaced)), 1)
        item = self.items(replaced)[0]
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}version"), "1")
        self.assertEqual(
            item.find("enclosure").get(f"{{{SPARKLE_NS}}}edSignature"),
            ITEM["ed_signature"])

    def test_item_without_version_is_preserved(self):
        unversioned = (
            "        <item>\n"
            "            <title>XRG-ng unknown</title>\n"
            '            <enclosure url="https://example.com/unknown.dmg"'
            ' length="1" type="application/octet-stream"'
            ' sparkle:edSignature="dW5rbm93bg=="/>\n'
            "        </item>\n"
        )
        feed = with_item(CHANNEL, unversioned)
        result = self.upsert(feed)
        self.assertEqual(len(item_spans(result)), 2)
        # The unversioned item is preserved untouched.
        self.assertIn(unversioned, result)
        items = self.items(result)
        self.assertEqual(items[0].findtext(f"{{{SPARKLE_NS}}}version"), "2")

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
        result = self.upsert(
            CHANNEL, make_item(pub_date="Fri, 30 Oct 2026 00:00:00 +0000"))
        root = ET.fromstring(result)  # must not raise
        enclosure = root.find(".//enclosure")
        self.assertEqual(
            enclosure.get(f"{{{SPARKLE_NS}}}edSignature"), ITEM["ed_signature"])
        item = root.find(".//item")
        self.assertEqual(item.findtext(f"{{{SPARKLE_NS}}}version"), "2")
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

    def test_cli_preserves_crlf_bytes(self):
        temporary = tempfile.TemporaryDirectory(prefix="xrg-appcast-")
        self.addCleanup(temporary.cleanup)
        crlf_item = element_item("1", "0.2.0", "b2xkLXNpZw==", 1024)
        crlf_item = crlf_item.replace("\n", "\r\n")
        feed = with_item(CHANNEL, element_item(
            "1", "0.2.0", "b2xkLXNpZw==", 1024)).replace("\n", "\r\n")
        self.assertIn(crlf_item, feed)
        path = Path(temporary.name) / "appcast.xml"
        path.write_bytes(feed.encode("utf-8"))
        result = subprocess.run(
            [sys.executable, str(APPCAST), "--appcast", str(path),
             "--version", ITEM["version"], "--build", ITEM["build"],
             "--url", ITEM["url"], "--length", str(ITEM["length"]),
             "--ed-signature", ITEM["ed_signature"],
             "--notes-url", ITEM["notes_url"],
             "--min-system", ITEM["min_system"]],
            text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stderr)
        raw = path.read_bytes()
        # The unrelated CRLF item stays byte-identical.
        self.assertIn(crlf_item.encode("utf-8"), raw)
        # The new item follows the file's CRLF convention.
        self.assertIn(b"<sparkle:version>2</sparkle:version>\r\n", raw)
        self.assertNotIn(b"<sparkle:version>2</sparkle:version>\r\n\n", raw)
        parsed = ET.fromstring(raw.decode("utf-8"))
        self.assertEqual(
            [i.findtext(f"{{{SPARKLE_NS}}}version")
             for i in parsed.findall(".//item")],
            ["2", "1"])


if __name__ == "__main__":
    unittest.main()