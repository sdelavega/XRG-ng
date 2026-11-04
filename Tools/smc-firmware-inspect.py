#!/usr/bin/env python3
"""Inspect an explicit Apple Silicon LLB IM4P offline; never execute firmware.

Supports the SPLT/FWSG layouts observed in j815/j773s build 26B123. Outputs
original SMC bytes and provenance, optionally a synthetic Mach-O for analysis.
It does not authenticate Apple signatures or identify physical sensors.
"""
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

MAX_BYTES = 64 * 1024 * 1024
PAGE_BYTES = 16384
MAGICS = (b"bvx2", b"bvxn", b"bvx-")


class FormatError(ValueError):
    pass


def digest(data):
    return hashlib.sha256(data).hexdigest()


def tlv(data, offset, limit):
    if offset + 2 > limit:
        raise FormatError("Truncated DER header")
    tag = data[offset]
    if tag == 0:
        raise FormatError("DER end-of-contents marker is forbidden")
    cursor = offset + 1
    if tag & 31 == 31:
        number = 0
        for index in range(10):
            if cursor >= limit:
                raise FormatError("Truncated high-tag DER header")
            part = data[cursor]
            cursor += 1
            if index == 0 and part & 127 == 0:
                raise FormatError("Nonminimal high-tag DER header")
            number = (number << 7) | (part & 127)
            if not part & 128:
                break
        else:
            raise FormatError("DER tag number limit exceeded")
        if number < 31:
            raise FormatError("Nonminimal high-tag DER header")
    if cursor >= limit:
        raise FormatError("Truncated DER length")
    length = data[cursor]
    start = cursor + 1
    if length & 128:
        count = length & 127
        if not 1 <= count <= 8 or start + count > limit:
            raise FormatError("Invalid DER length")
        if data[start] == 0:
            raise FormatError("Nonminimal DER length")
        length = int.from_bytes(data[start:start + count], "big")
        start += count
        if length < 128:
            raise FormatError("Nonminimal DER length")
    end = start + length
    if end > limit:
        raise FormatError("DER field exceeds its container")
    return tag, start, end


def check_der(data, start, end, depth=0):
    if depth > 16:
        raise FormatError("DER nesting limit exceeded")
    while start < end:
        tag, lo, hi = tlv(data, start, end)
        if tag & 32:
            check_der(data, lo, hi, depth + 1)
        start = hi


def im4p_payload(data):
    if len(data) > MAX_BYTES:
        raise FormatError("Input size limit exceeded")
    tag, start, end = tlv(data, 0, len(data))
    if tag != 0x30 or end != len(data):
        raise FormatError("Expected one complete IM4P DER sequence")
    check_der(data, start, end)
    fields = []
    while start < end:
        tag, lo, hi = tlv(data, start, end)
        fields.append((tag, lo, hi))
        start = hi
    if len(fields) < 4 or [x[0] for x in fields[:4]] != [0x16, 0x16, 0x16, 4]:
        raise FormatError("Unsupported IM4P fields")
    values = [data[lo:hi] for _, lo, hi in fields[:4]]
    if values[0] != b"IM4P" or values[1] != b"illb":
        raise FormatError("Input must be an LLB IM4P (illb)")
    try:
        description = values[2].decode("ascii")
    except UnicodeDecodeError as error:
        raise FormatError("Non-ASCII IM4P description") from error
    return values[3], {"type": "illb", "description": description,
                       "payload_offset": fields[3][1], "payload_bytes": len(values[3])}


def decode_lzfse(encoded, limit):
    if sys.platform != "darwin":
        raise FormatError("LZFSE decoding requires macOS system libcompression")
    lib = ctypes.CDLL("/usr/lib/libcompression.dylib")
    decode = lib.compression_decode_buffer
    decode.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
                       ctypes.c_size_t, ctypes.c_void_p, ctypes.c_int]
    decode.restype = ctypes.c_size_t
    source = ctypes.create_string_buffer(encoded)
    target = ctypes.create_string_buffer(limit + 1)
    length = decode(target, len(target), source, len(encoded), None, 0x801)
    if not 0 < length <= limit:
        raise FormatError("LZFSE decoding failed or exceeded its bound")
    return target.raw[:length]


def bounded_decode(encoded, limit, decoder):
    if encoded[:4] not in MAGICS or not encoded.endswith(b"bvx$"):
        raise FormatError("Unsupported or incomplete LZFSE stream")
    decoded = decoder(encoded, limit)
    if not 0 < len(decoded) <= limit:
        raise FormatError("Decoded size exceeds its bound")
    return decoded


def fwsg_segments(image):
    if len(image) < 32:
        raise FormatError("Missing FWSG trailer")
    magic, version, table, count = struct.unpack_from("<4sIII", image, len(image) - 32)
    if magic != b"fwsg" or version != 1 or count != 2:
        raise FormatError("Unsupported FWSG layout")
    if table + count * 32 != len(image) - 32:
        raise FormatError("FWSG descriptor bounds do not match the trailer")
    segments = []
    for index in range(count):
        vm, offset, size, memory, flags, raw_name = struct.unpack_from(
            "<QIIII8s", image, table + index * 32)
        try:
            name = raw_name.rstrip(b"\0").decode("ascii")
        except UnicodeDecodeError as error:
            raise FormatError("Invalid FWSG segment name") from error
        if vm != offset or not size or offset + size > table or memory < size:
            raise FormatError("Invalid FWSG file/memory range")
        if vm + memory > MAX_BYTES:
            raise FormatError("FWSG memory range exceeds its bound")
        segments.append({"name": name, "vm_address": vm, "file_offset": offset,
                         "file_size": size, "memory_size": memory, "flags": flags,
                         "zero_fill_start": vm + size, "zero_fill_bytes": memory - size})
    if [s["name"] for s in segments] != ["__TEXT", "__DATA"] or segments[0]["vm_address"] != 0:
        raise FormatError("Unsupported FWSG segment identities")
    if [s["flags"] for s in segments] != [4, 0]:
        raise FormatError("Unsupported FWSG segment flags")
    for kind in ("file", "memory"):
        left, right = segments
        start = "file_offset" if kind == "file" else "vm_address"
        size = "file_size" if kind == "file" else "memory_size"
        if left[start] + left[size] > right[start]:
            raise FormatError("Overlapping FWSG segments")
    return segments, {"version": version, "descriptor_offset": table,
                      "trailer_reserved_hex": image[-16:].hex()}


def inspect_splt(llb, offset, decoder):
    _, unknown, reserved, page_size, count = struct.unpack_from("<4sIQII", llb, offset)
    if reserved != 0 or page_size != PAGE_BYTES or not 1 <= count <= MAX_BYTES // PAGE_BYTES:
        raise FormatError("Unsupported SPLT header")
    cursor = offset + 24 + 4 * count
    if cursor > len(llb):
        raise FormatError("Truncated SPLT length table")
    lengths = struct.unpack_from("<" + "I" * count, llb, offset + 24)
    pages, chunks, decoded_offset = [], [], 0
    for index, length in enumerate(lengths):
        if length < 12 or cursor + length > len(llb):
            raise FormatError("Invalid SPLT encoded page bounds")
        encoded = llb[cursor:cursor + length]
        # Only this single-block page form has been validated for SPLT.
        if encoded[:4] != b"bvx2":
            raise FormatError("Unsupported SPLT page encoding")
        page = bounded_decode(encoded, page_size, decoder)
        if len(page) != struct.unpack_from("<I", encoded, 4)[0]:
            raise FormatError("SPLT page decoded length disagrees with its header")
        if index != count - 1 and len(page) != page_size:
            raise FormatError("Short intermediate SPLT page")
        chunks.append(page)
        pages.append({"index": index, "encoded_offset": cursor, "encoded_bytes": length,
                      "decoded_offset": decoded_offset, "decoded_bytes": len(page),
                      "sha256": digest(page)})
        decoded_offset += len(page)
        cursor += length
    image = b"".join(chunks)
    versions = re.findall(rb"AppleSMCFirmware_[A-Za-z0-9_.-]{1,160}\x00", image)
    if not versions:
        return None
    if len(versions) != 1:
        raise FormatError("Ambiguous SMC firmware build strings")
    segments, fwsg = fwsg_segments(image)
    return image, {"splt_offset": offset, "splt_unknown_word": unknown,
                   "page_size": page_size, "page_count": count, "encoded_end": cursor,
                   "pages": pages, "firmware_version": versions[0][:-1].decode("ascii"),
                   "segments": segments, "fwsg": fwsg}


def inspect_im4p(data, decoder=decode_lzfse):
    encoded, im4p = im4p_payload(data)
    llb = bounded_decode(encoded, MAX_BYTES, decoder) if encoded[:4] in MAGICS else encoded
    images = []
    offset = 0
    candidates = total_pages = 0
    while True:
        offset = llb.find(b"splt", offset)
        if offset < 0:
            break
        if offset + 24 <= len(llb):
            _, _, reserved, page_size, _ = struct.unpack_from("<4sIQII", llb, offset)
            # Ignore incidental strings; fail closed on malformed supported headers.
            if reserved == 0 and page_size == PAGE_BYTES:
                count = struct.unpack_from("<I", llb, offset + 20)[0]
                candidates += 1
                total_pages += count
                if candidates > 16 or total_pages > MAX_BYTES // PAGE_BYTES:
                    raise FormatError("SPLT candidate/page budget exceeded")
                result = inspect_splt(llb, offset, decoder)
                if result:
                    images.append(result)
                    if len(images) > 1:
                        raise FormatError("Ambiguous SMC SPLT images")
        offset += 4
    if len(images) != 1:
        raise FormatError(f"Expected one SMC SPLT image; found {len(images)}")
    image, details = images[0]
    manifest = {"source_sha256": digest(data), "source_bytes": len(data), "im4p": im4p,
                "decoded_llb_sha256": digest(llb), "decoded_llb_bytes": len(llb),
                "smc_sha256": digest(image), "smc_bytes": len(image), **details,
                "limitations": [
                    "Supports observed SPLT/FWSG layouts; unknown SPLT word is not interpreted or authenticated.",
                    "Hashes preserve provenance; this tool does not verify Apple signatures.",
                    "Segment addresses are image-relative, not observed physical/runtime load addresses.",
                    "Reconstruction does not establish physical sensor meanings or firmware execution."]}
    return image, manifest


def macho_wrapper(image, segments):
    instruction = struct.unpack_from("<I", image)[0]
    if instruction & 0xfc000000 != 0x14000000:
        raise FormatError("Cannot derive an AArch64 entry branch for the analysis wrapper")
    immediate = instruction & 0x3ffffff
    if immediate & 0x2000000:
        immediate -= 0x4000000
    entry = immediate * 4
    if not 0 <= entry < segments[0]["memory_size"]:
        raise FormatError("Entry branch is outside TEXT")
    prefix = 4096
    commands = []
    for segment in segments:
        name = segment["name"].encode("ascii")
        text = name == b"__TEXT"
        sections = [struct.pack("<16s16sQQIIIIIIII", b"__text" if text else b"__data", name,
                                segment["vm_address"], segment["file_size"],
                                prefix + segment["file_offset"], 2, 0, 0,
                                0x80000400 if text else 0, 0, 0, 0)]
        if segment["zero_fill_bytes"]:
            sections.append(struct.pack("<16s16sQQIIIIIIII", b"__bss", name,
                                        segment["zero_fill_start"], segment["zero_fill_bytes"],
                                        0, 2, 0, 0, 1, 0, 0, 0))
        commands.append(struct.pack("<II16sQQQQiiII", 0x19, 72 + 80 * len(sections), name,
                                    segment["vm_address"], segment["memory_size"],
                                    prefix + segment["file_offset"], segment["file_size"],
                                    7, 5 if text else 3, len(sections), 0) + b"".join(sections))
    state = bytearray(272)
    struct.pack_into("<Q", state, 256, entry)
    commands.append(struct.pack("<IIII", 5, 288, 6, 68) + state)
    raw_commands = b"".join(commands)
    header = struct.pack("<IiiIIIII", 0xfeedfacf, 0x100000c, 0, 2,
                         len(commands), len(raw_commands), 0, 0) + raw_commands
    if len(header) > prefix:
        raise FormatError("Analysis header exceeds its reserved prefix")
    return header + bytes(prefix - len(header)) + image


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="LLB IM4P file, not a full IPSW")
    parser.add_argument("output", type=Path, help="new output directory (must not exist)")
    parser.add_argument("--macho", action="store_true", help="also emit a synthetic analysis-only Mach-O")
    args = parser.parse_args(argv)
    try:
        if args.output.exists() or args.output.is_symlink():
            raise FormatError("Output directory already exists")
        with args.input.open("rb") as source:
            data = source.read(MAX_BYTES + 1)
        image, manifest = inspect_im4p(data)
        manifest["source"] = str(args.input.resolve())
        wrapper = macho_wrapper(image, manifest["segments"]) if args.macho else None
        if wrapper is not None:
            manifest["analysis_wrapper"] = {"sha256": digest(wrapper), "image_file_offset": 4096,
                "logical_base": 0, "synthetic_header": True,
                "limitations": "FWSG TEXT/DATA boundaries retained; no code/constant split inferred inside TEXT. Permissions inferred from segment names. Not executable host software."}
        args.output.mkdir()
        for name, content in [("smc.bin", image), ("smc-analysis.macho", wrapper),
                              ("manifest.json", (json.dumps(manifest, indent=2) + "\n").encode())]:
            if content is not None:
                with (args.output / name).open("xb") as destination:
                    destination.write(content)
        print(f"{manifest['firmware_version']}: {len(image)} bytes, SHA-256 {manifest['smc_sha256']}")
        return 0
    except (FormatError, OSError, struct.error) as error:
        print(f"smc-firmware-inspect: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
