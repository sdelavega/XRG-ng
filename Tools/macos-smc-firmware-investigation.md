# SMC firmware investigation checkpoint

Investigated 2026-11-04 for the MacBook Air M5 (`j815ap`) and Havana Mac mini
M4 Pro (`j773sap`). This resolves firmware acquisition and reconstruction, and
partially resolves key-to-input lookup. It does not establish new physical
sensor labels.

## Source identity

The preserved local restore bundles contain second-stage iBoot. SMC is embedded
in the first-stage image; see the [Asahi firmware overview](https://asahilinux.org/docs/platform/introduction/#firmware-overview).
The separate local `iBootData` payloads did not establish an SMC image.

Bounded HTTP range requests retrieved the ZIP directory, primary BuildManifest
and two LLB components from Apple's
[UniversalMac 27.2 / 26B123 restore archive](https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw).
The range requests downloaded 4,716,605 bytes from the 25.6 GB archive. Each
component's SHA-384 matches the corresponding board identity's `Digest` in that
manifest. This is a digest and
provenance check, not independent verification of Apple's signatures.

| Component | SHA-256 |
| --- | --- |
| `Firmware/all_flash/LLB.j815.RELEASE.im4p` | `c6d81f8ae466ad8bde54f7e60200c0ab0c0029db8c581913c6b869a56c41c555` |
| `Firmware/all_flash/LLB.j773s.RELEASE.im4p` | `570d67841e56b5805ba03df86fe013db2af0784a9cf85014b8c7d76ac0292e10` |

These are board-specific images from **26B123**. The M5 currently runs **26C5035r**;
matching its key inventory does not prove that it is running these firmware
bytes. Havana runs 26B123, but its active first-stage firmware bytes were not
read back or compared either.

## Reconstruction and reusable inspector

Each decoded LLB contains an explicit `splt` header, 16-KiB page size, page count
and compressed-length table. Decode the exact spans in table order, not arbitrary
compression-marker matches. All intermediate pages are full-sized; the last can
be shorter. Both reconstructed images end in coherent `fwsg` version-1 TEXT/DATA
segment records with bounded file ranges and declared zero-fill memory.

| Board | Pages | Image bytes | Firmware build | Image SHA-256 |
| --- | ---: | ---: | --- | --- |
| j815 | 38 | 612,832 | `AppleSMCFirmware_H17_6-7372.41.4.j815.REL` | `7986e427cd01c4611541add2496b9dd978059769dbcaf7e0a0c302e0b6c19947` |
| j773s | 32 | 515,008 | `AppleSMCFirmware_H16_5-7372.41.4.j773s.REL` | `07ae163c3b86cf565dc2cca7057f1c3266dc395895521a8820e473ea0bf4dc55` |

The original offline inspector accepts an explicit LLB file and a new output
directory. It uses macOS system LZFSE decoding, checks parser/decompression
bounds and ambiguity, and emits the raw image and a provenance manifest:

```sh
python3 Tools/smc-firmware-inspect.py /path/LLB.j815.RELEASE.im4p dist/smc-j815 --macho
python3 -m unittest discover -s Tools/tests -p 'test_smc_firmware_inspect.py'
```

`--macho` adds a synthetic analysis container with the observed FWSG TEXT/DATA/BSS
layout. Addresses are relative to the image. Its header is not Apple firmware;
no runtime address or code/constant split inside TEXT is inferred. The SPLT
unknown word remains uninterpreted. The tool neither downloads nor executes
firmware and refuses an existing output directory.

Twenty synthetic parser/CLI tests passed, including malformed lengths, nesting,
page boundaries, ambiguous images, segment overlap and output preservation.
Both real components also reconstructed to the independently verified hashes
above. No Apple binary, string catalogue or firmware pages are committed.

## Verified j815 key and input structure

Hopper and an independent bounds-checked decoder identify a compressed key trie
rooted at image-relative `0x6164a`. Independent enumeration and direct lookup
agree for all 2,431 keys. The temperature-key inventory is 148: 129 `flt `,
12 `ioft`, and seven `si32` entries. The 129 float keys exactly match the earlier
raw M5 runtime inventory, including key names, not just count.

The float and integer leaves point into DATA zero-fill memory; the `ioft` leaves
point to code handlers. These are value/handler references, not physical labels.
For 113 temperature keys, state and pointer tables establish direct group-one
input links:

| Key | Group-one input | Value buffer | Additional numeric descriptor |
| --- | ---: | --- | --- |
| `Ts00` | 134 | `0xa8528` | None established |
| `Ta00` | 142 | `0xa8548` | None established |
| `Tz11` | 197 | `0xa8624` | `0x470` |

All 207 group-one state records have checked pointer pairs. Group-two and
group-three pairs were inspected separately and did not directly match these
temperature leaf payloads. Numeric export IDs do not establish provider names.
The current PMP's 25 long thermal labels are absent as literals in this image;
that bounded result neither proves nor rules out a computed registration bridge.

Useful retained Hopper evidence includes lookup `ev_32ccfa8a5781d59f6c8db4feb9b1a58a0f09f11b69ea0027302883c792372c19`,
lookup assembly `ev_f18305c2987d8b9f43048e7dcebcd0c7f7a38235bdaa7b10e19b0475d85c5b78`,
and input-pair reads `ev_492c1b85b8b99b57f04b25e5ce3c1d1b7aa4d72ee5c48b45649bd2e9bae1aa00`.
Outlined helpers, unresolved indirect calls and inferred function boundaries
limit the decompiler. Raw instructions and independent table checks support
the structural findings; large expanded pseudocode is not a physical mapping.

The j773s trie was independently decoded and directly checked too: 1,728 unique
keys rooted at `0x4c7e0`, including 273 temperature keys (270 `flt ` and three
`ioft`). A fresh native-transport probe on Havana exactly matches both the
complete 273-key inventory and the 270 float-key set, with no differences.
The j815 input-buffer indices above do not establish j773s input mappings.

## Remaining boundary and evidence

The next specific task is to trace the provider/registration path that populates
group-one inputs 134, 142 and 197, then establish an explicit source identity.
Do not strip PMP label suffixes, assign physical locations from table order,
or generalize a mapping to a different board/build without evidence.

Ignored local artifacts are under `dist/smc-firmware-discovery/`,
`dist/havana-smc-artifact-discovery/` and `dist/smc-container-tool-validation/`:
range manifests, input/derived hashes, independent reconstruction and trie
decoders, selected runtime metadata, table crosslinks and retained REA snapshots.
Both root-owned Hopper sessions were closed with snapshots. No firmware was
executed or flashed, and no device power state was changed for this investigation.
