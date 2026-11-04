#!/usr/bin/env python3
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Synthetic container fixtures only; no Apple firmware is embedded here."""
import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("smc_inspect", Path(__file__).parents[1] / "smc-firmware-inspect.py")
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)


def der(tag, data):
    size = len(data)
    if size < 128:
        length = bytes([size])
    else:
        value = size.to_bytes((size.bit_length() + 7) // 8, "big")
        length = bytes([128 | len(value)]) + value
    return (bytes([tag]) if isinstance(tag, int) else tag) + length + data


def im4p(payload, kind=b"illb"):
    return der(0x30, der(0x16, b"IM4P") + der(0x16, kind) +
               der(0x16, b"Synthetic fixture") + der(4, payload))


def encoded(page):
    # Deliberately not real LZFSE. Tests inject a decoder, portable to Linux.
    return b"bvx2" + struct.pack("<I", len(page)) + page + b"bvx$"


def fake_decoder(data, limit):
    return data[8:-4]


def firmware():
    image = bytearray(0x4100)
    struct.pack_into("<I", image, 0, 0x14000081)  # image-relative branch to 0x204
    version = b"AppleSMCFirmware_SYNTHETIC-1.fixture.REL\0"
    image[0x4000:0x4000 + len(version)] = version
    table = len(image)
    image += struct.pack("<QIIII8s", 0, 0, 0x1000, 0x1000, 4, b"__TEXT")
    image += struct.pack("<QIIII8s", 0x4000, 0x4000, 0x100, 0x2000, 0, b"__DATA")
    image += struct.pack("<4sIII16s", b"fwsg", 1, table, 2, bytes(16))
    return bytes(image)


def splt(image, pages=None):
    if pages is None:
        pages = [image[i:i + tool.PAGE_BYTES] for i in range(0, len(image), tool.PAGE_BYTES)]
    chunks = [encoded(p) for p in pages]
    return (struct.pack("<4sIQII", b"splt", 0x12345678, 0, tool.PAGE_BYTES, len(chunks)) +
            struct.pack("<" + "I" * len(chunks), *map(len, chunks)) + b"".join(chunks))


def inspect(payload):
    return tool.inspect_im4p(im4p(payload), decoder=fake_decoder)


class InspectorTests(unittest.TestCase):
    def test_reconstruction_excludes_surrounding_llb_and_preserves_provenance(self):
        image = firmware()
        result, info = inspect(b"outer-prefix" + splt(image) + b"outer-suffix")
        self.assertEqual(result, image)
        self.assertEqual(info["smc_sha256"], tool.digest(image))
        self.assertEqual(info["splt_offset"], len(b"outer-prefix"))
        self.assertEqual(info["splt_unknown_word"], 0x12345678)
        self.assertEqual(info["page_count"], 2)
        self.assertEqual(info["pages"][1]["decoded_offset"], 16384)
        self.assertEqual(info["pages"][1]["decoded_bytes"], len(image) - 16384)
        self.assertEqual(info["segments"][1]["zero_fill_bytes"], 0x1f00)

    def test_compressed_outer_payload_uses_same_bounded_decoder(self):
        result, _ = tool.inspect_im4p(im4p(encoded(b"prefix" + splt(firmware()))), decoder=fake_decoder)
        self.assertEqual(result, firmware())

    def test_wrong_component_and_non_im4p_are_rejected(self):
        for data in [im4p(splt(firmware()), b"ibot"), der(4, b"not IM4P"), b""]:
            with self.subTest(data=data[:8]), self.assertRaises(tool.FormatError):
                tool.inspect_im4p(data, decoder=fake_decoder)

    def test_der_truncation_trailing_indefinite_and_nonminimal_lengths_are_rejected(self):
        valid = im4p(splt(firmware()))
        for data in [valid[:-1], valid + b"junk", b"\x30\x80\x00\x00",
                     b"\x30\x81\x00", b"\x30\x82\x00\x80" + bytes(128),
                     der(0x30, b"\x00\x00")]:
            with self.subTest(data=data[:8]), self.assertRaises(tool.FormatError):
                tool.inspect_im4p(data, decoder=fake_decoder)

    def test_optional_private_high_tag_metadata_is_validated(self):
        source = im4p(splt(firmware()))
        _, start, end = tool.tlv(source, 0, len(source))
        metadata = der(b"\xff\x81\x00", der(2, b"\x01"))
        result, _ = tool.inspect_im4p(der(0x30, source[start:end] + metadata), decoder=fake_decoder)
        self.assertEqual(result, firmware())
        for bad in [b"\xff\x80\x1f\x00", b"\xff\x1e\x00", b"\xff\x81"]:
            with self.subTest(bad=bad), self.assertRaises(tool.FormatError):
                tool.inspect_im4p(der(0x30, source[start:end] + bad), decoder=fake_decoder)

    def test_short_intermediate_page_is_not_concatenated(self):
        with self.assertRaisesRegex(tool.FormatError, "Short intermediate"):
            inspect(splt(firmware(), pages=[firmware()[:100], firmware()[100:]]))

    def test_encoded_page_must_fit_declared_bounds(self):
        data = bytearray(splt(firmware()))
        struct.pack_into("<I", data, 24, len(data) + 1)
        with self.assertRaisesRegex(tool.FormatError, "bounds"):
            inspect(bytes(data))
        with self.assertRaises(tool.FormatError):
            inspect(splt(firmware())[:-1])

    def test_page_count_budget_rejects_huge_table_before_decoding(self):
        data = struct.pack("<4sIQII", b"splt", 0, 0, 16384, 0xffffffff)
        with self.assertRaisesRegex(tool.FormatError, "budget"):
            inspect(data)

    def test_zero_pages_and_truncated_length_table_are_rejected(self):
        for count in [0, 2]:
            data = struct.pack("<4sIQII", b"splt", 0, 0, 16384, count)
            with self.subTest(count=count), self.assertRaises(tool.FormatError):
                inspect(data)

    def test_declared_and_actual_page_length_must_match(self):
        data = bytearray(splt(firmware()))
        struct.pack_into("<I", data, 32 + 4, 1)
        with self.assertRaisesRegex(tool.FormatError, "disagrees"):
            inspect(bytes(data))

    def test_decoder_cannot_return_more_than_its_bound(self):
        with self.assertRaisesRegex(tool.FormatError, "bound"):
            tool.inspect_im4p(im4p(splt(firmware())), decoder=lambda data, limit: bytes(limit + 1))

    def test_two_smc_containers_are_ambiguous(self):
        with self.assertRaisesRegex(tool.FormatError, "Ambiguous SMC SPLT"):
            inspect(splt(firmware()) + splt(firmware()))

    def test_multiple_build_strings_are_ambiguous(self):
        image = bytearray(firmware())
        version = b"AppleSMCFirmware_OTHER-1.fixture.REL\0"
        image[0x4050:0x4050 + len(version)] = version
        with self.assertRaisesRegex(tool.FormatError, "build strings"):
            inspect(splt(bytes(image)))

    def test_non_smc_image_is_not_selected(self):
        image = firmware().replace(b"AppleSMCFirmware_", b"OtherXXXFirmware_")
        with self.assertRaisesRegex(tool.FormatError, "found 0"):
            inspect(splt(image))

    def test_fwsg_descriptor_bounds_version_and_memory_ranges_are_checked(self):
        image = firmware()
        table = len(image) - 96
        mutations = [(len(image) - 28, 2), (len(image) - 24, table + 1),
                     (table + 32 + 16, 1), (table + 32 + 8, 0xfffffff0)]
        for offset, value in mutations:
            damaged = bytearray(image)
            struct.pack_into("<I", damaged, offset, value)
            with self.subTest(offset=offset), self.assertRaises(tool.FormatError):
                inspect(splt(bytes(damaged)))

    def test_overlapping_memory_segments_are_rejected(self):
        image = bytearray(firmware())
        table = len(image) - 96
        struct.pack_into("<I", image, table + 16, 0x4001)
        with self.assertRaisesRegex(tool.FormatError, "Overlapping"):
            inspect(splt(bytes(image)))

    def test_analysis_wrapper_preserves_image_and_declared_zero_fill(self):
        image, manifest = inspect(splt(firmware()))
        wrapper = tool.macho_wrapper(image, manifest["segments"])
        self.assertEqual(wrapper[4096:], image)
        magic, cpu = struct.unpack_from("<II", wrapper)
        self.assertEqual((magic, cpu), (0xfeedfacf, 0x100000c))
        # TEXT command is 152B. DATA maps the observed source offset, not a guessed base.
        data_command = struct.unpack_from("<II16sQQQQiiII", wrapper, 32 + 152)
        self.assertEqual(data_command[3:7], (0x4000, 0x2000, 4096 + 0x4000, 0x100))
        self.assertEqual(data_command[9], 2)  # stored DATA and explicit BSS sections

    def test_analysis_wrapper_rejects_unproven_entrypoint(self):
        image, manifest = inspect(splt(firmware()))
        damaged = bytearray(image)
        struct.pack_into("<I", damaged, 0, 0)
        with self.assertRaises(tool.FormatError):
            tool.macho_wrapper(bytes(damaged), manifest["segments"])

    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as root:
            output = Path(root) / "existing"
            output.mkdir()
            marker = output / "keep"
            marker.write_text("unchanged")
            with contextlib.redirect_stderr(io.StringIO()), patch.object(tool, "inspect_im4p") as parse:
                result = tool.main([str(Path(root) / "unused-input"), str(output)])
            self.assertEqual(result, 1)
            parse.assert_not_called()
            self.assertEqual(marker.read_text(), "unchanged")

    def test_cli_writes_only_to_a_new_directory(self):
        with tempfile.TemporaryDirectory() as root:
            source, output = Path(root) / "synthetic.im4p", Path(root) / "new"
            source.write_bytes(im4p(splt(firmware())))
            original = source.read_bytes()
            real_parser = tool.inspect_im4p
            with patch.object(tool, "inspect_im4p", side_effect=lambda data: real_parser(data, fake_decoder)):
                with contextlib.redirect_stdout(io.StringIO()):
                    result = tool.main([str(source), str(output), "--macho"])
            self.assertEqual(result, 0)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual((output / "smc.bin").read_bytes(), firmware())
            self.assertEqual({p.name for p in output.iterdir()}, {"smc.bin", "smc-analysis.macho", "manifest.json"})


if __name__ == "__main__":
    unittest.main()
