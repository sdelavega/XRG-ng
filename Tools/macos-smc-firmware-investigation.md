# SMC firmware investigation checkpoint

Investigated 2026-11-04 for the MacBook Air M5 (`j815ap`) and Havana Mac mini
M4 Pro (`j773sap`). This resolves firmware acquisition and reconstruction, and
partially resolves key-to-input lookup and establishes the configured j815
Ts/Ta provider path. The j773s trace identifies twelve Ta keys as six
Neural Engine thermal channels and their adjusted readings, plus 26 Ts keys
as nine die-temperature channels with separate current and averaged outputs.
The j815 identities remain under investigation.

## Resolved j773s Neural Engine channels

Havana's current PMP device metadata names range 29 `ANE-TO-SMC`, with start
`0x2a4` and count eight. The j773s SMC channel-14 record at `0x74da8` has
the exact same start and count. Its configured transport base is
`0x5003c0000`; the initialized read callback at `0x5ec0` reads 16-byte
entries from that window. The main polling path at `0x2b19c` reads six
entries from channel 14, differences their counters and publishes the results
under numeric source IDs `0x2001` through `0x2006`. The counter decoder at
`0x4a270` computes `(high32(delta) / 64) / low32(delta)`, with status,
zero-delta and upper-bound handling.

The source table at `0x72458` joins each source ID to two distinct sensor
inputs: the raw reading and a reading with a fixed `8.199999809265137` degree
offset. Independently decoded SMC key leaves join those inputs to these keys:

| Stream ordinal | Raw key | Adjusted key |
| --- | --- | --- |
| 1 | `Ta00` | `Ta01` |
| 2 | `Ta04` | `Ta05` |
| 3 | `Ta08` | `Ta09` |
| 4 | `Ta0K` | `Ta0L` |
| 5 | `Ta0O` | `Ta0P` |
| 6 | `Ta0R` | `Ta0S` |

XRG labels these as Neural Engine temperature channels on the validated
`Mac16,11` model only. Ordinals describe stream order; neither core numbers
nor physical locations are established. Adjusted keys remain separate
readings and retain their raw key identities. No rule is inferred for the
entire Ta family or other Mac models. Native Havana enumeration has 1,728
keys but provides no `RBr ` value, so this mapping does not depend on the
optional legacy branch catalogue.

The SMC source SHA-256 is
`07ae163c3b86cf565dc2cca7057f1c3266dc395895521a8820e473ea0bf4dc55`.
Ignored `dist/havana-smc-artifact-discovery/` retains scoped live metadata,
the original cross-link decoder, `verify_j773s_ane_bridge.py`, its passing
`j773s-ane-provider-proof.json` output and focused LLVM disassembly. This
establishes a named provider route, not exclusive ownership: a separate
generic incoming-message route can also update numeric source IDs. The
firmware's physical sensor sites and executing bytes were not read back.

The application change passed `Tools/ci-macos.sh Debug` on both hosts:
644 tests on each architecture, universal builds, isolated AppKit smoke and
native / Rosetta packaged entry-point checks. A fresh linked native probe
confirmed all twelve labels on Havana and the existing six generic Ta labels
on the M5. Havana's six raw readings were zero and all six adjusted readings
were `8.199999809265137`; these idle values confirm the paired offsets, not
temperature accuracy under load. Logs and scoped name/value snapshots are in
ignored `dist/ane-sensor-name-validation/`.

## Resolved j773s die-temperature channels

The j773s producer at `0xbc50` dispatches kind one through pointer
`0x65160` to configuration table `0x66c08`. It reads eight MTR die-temperature
channels at base `0x500400000`, with three distinct output roles per channel.
The calibration helper at `0xbb68` references the original module name
`platform/t6041/device_mtr_die_temps.cpp`. A ninth channel uses kind four,
configuration `0x796b8`, at the same base.

| Channel | Current | Average | Adjusted average |
| --- | --- | --- | --- |
| 1 | `Ts02` | `Ts00` | `Ts01` |
| 2 | `Ts06` | `Ts04` | `Ts05` |
| 3 | `Ts0A` | `Ts08` | `Ts09` |
| 4 | `Ts0E` | `Ts0C` | `Ts0D` |
| 5 | `Ts0I` | `Ts0G` | `Ts0H` |
| 6 | `Ts0M` | `Ts0K` | `Ts0L` |
| 7 | `Ts0R` | `Ts0O` | `Ts0Q` |
| 8 | `Ts0W` | `Ts0T` | `Ts0U` |
| 9 | `Tsx1` | `Tsx0` | — |

The current output comes from the separately decoded hardware sample at
runtime record+`0x20`. Helper `0x48724` computes the averaged value from
a signed counter ratio divided by 64, applies a 130°C cap and stores it at
record+`0x1c`. The two kind-one average outputs apply separate calibration
expressions: `average - c2` and `average + c0 - c2`. The stored coefficients
are zero for these channels, and all eight paired averages agreed in fresh
native reads. Current and averaged readings remain independent: one native
sample reported 61.90625°C current and 60.41609191894531°C average on channel
one. No minimum/maximum semantics or averaging interval is inferred.

XRG uses Die temperature channel labels for these 26 keys on `Mac16,11`
only, preserving current, average and adjusted-average roles. The trace names
the MTR die-temperature provider but does not identify physical cores,
clusters, GPU sites or a matching named DeviceTree register node. Ordinals
follow firmware stream order.

Ignored `dist/havana-smc-artifact-discovery/` retains
`verify_j773s_ts_roles.py`, its passing `j773s-ts-role-proof.json`, focused
assembly and `havana-ts-native-check.json`. An earlier provisional kind-one
table address `0x66608` was a jump-table interpretation error; the corrected
dispatch and all 26 key-to-role links are checked by the reproducer.

The die-label application change passed the full Debug gate on both Macs,
including 645 tests per architecture and the native / Rosetta packaged smoke
checks. A freshly linked native probe confirmed all 38 combined Ta/Ts names
on Havana and retained generic names for the 14 matching keys on the M5.
Ignored `dist/die-sensor-name-validation/` retains both gate logs and native
name/value snapshots.

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

## Verified j815 Ts/Ta provider path

The configured polling path at image-relative `0x30608..0x30650` calls
`0x3aab0` with objects `0x8e1f0` (Ts) and `0x8e210` (Ta), subject to runtime
enable flags. Each object supplies an input manager, a 12-byte-record map and
a numeric source ID. Successful reads decode signed 15-bit values with six
fractional bits and write the mapped group-one inputs through `0x3d988`.

| Key | Input | Source ID / canonical FourCC | PTD start | Register / 16-bit slot |
| --- | ---: | --- | --- | --- |
| `Ts00` | 134 | `0x73307661` / `s0va` | `0x150` | 0 / 0 |
| `Ta00` | 142 | `0x61307661` / `a0va` | `0x152` | 0 / 0 |
| `Ta04` | 143 | `0x61307661` / `a0va` | `0x152` | 0 / 1 |

These are integer FourCCs: their stored little-endian bytes are `av0s` and
`av0a`. Neither spelling establishes a physical component name.

Initialization at `0x6f08..0x6f28` registers the source table at `0x90610`
with provider `0x8f078`, operation 20 and a runtime record count. Vtable
method `0x4c420` stores and sorts the records. Read method `0x4c590` selects
mode one, then `0x4cb74` looks up the source through `0x4ca5c`, checks the
requested range and loads the first 64 bits of each 16-byte slot. The stored
base is `0x38c840000`; the slot formula is
`base + 0x20000 + (ptd_start + requested_offset) * 16`.
The calculated first values for `Ts00`, `Ta00` and `Ta04` are therefore
`0x38c861500`, `0x38c861520` and `0x38c861522`. These are static calculations;
no register was read to validate an executing path.

The current M5 DeviceTree's `/Root/device-tree/arm-io/aon-ptd` provides a
1,056-byte `ptd_data_table`: 88 unique 12-byte records, SHA-256
`76336fd0ae6b26630fff6f91ff0833620494c9084d03707749f890f5a55a002f`.
ApplePTD publishes the decoded fields in `ptd-data-table-dict`. Independent
decoding of **all 88 records** agrees with those fields:

| Offset | Bytes | Published field |
| --- | ---: | --- |
| 0 | 4 | `ptd_id` |
| 4 | 2 | `ptd_vers` |
| 6 | 2 | `ptd_start` |
| 8 | 1 | `ptd_size` |
| 9 | 1 | `ptd_irq_num` |
| 10 | 1 | `ptd_entry_irq` |
| 11 | 1 | `ptd_features` |

All **20 records** in the SMC table at `0x90610` occur byte-for-byte in this
live 88-record table. In particular, `s0va` has start `0x150`, size 2, and
`a0va` has start `0x152`, size 3. This explicitly connects the configured
Ts/Ta reader to the ApplePTD registry. The records contain no physical
location, component label or named unit field. The DeviceTree register base
`0x17c840000` differs from the SMC object's base; their address-space
translation has not been established.

The original source maps, registration call, backend instructions, input
pointer pairs and key leaves were checked independently of Hopper's
decompiler. See ignored `J815_TS_TA_PRODUCERS.md`,
`j815-ts-ta-provider-chain.json`, `J815_PTD_REGISTRY.md` and
`j815-ptd-registry-comparison.json` under
`dist/havana-smc-artifact-discovery/`. The comparison concerns a 20-record
subset, not equality of the entire live table and the following firmware
bytes.

## Remaining boundary and evidence

The Ts/Ta provider/registration path is established through opaque PTD source
IDs. Its connection to named physical components remains unresolved. The
producer of group-one input 197 (`Tz11`) is also unresolved; numeric descriptor
`0x470` and references in consumer tables do not establish who writes it.

A bounded follow-up acquired `Firmware/pmp/t8142pmp.im4p` from the same
26B123 restore archive. Its SHA-256 is
`081d5ec0cf30429d8c5cf8fa39e9c8494a110160178c3c6b16ce08f84f613fd2`;
the decoded Mach-O is
`6c669ae08e0a58db7f0c10795ba2edda23c59196ee08e1636fd6f3938ebc6fa5`.
This keeps the two static firmware analyses on one restore build, while the
live M5 metadata remains from 26C5035r.

PMP's `temp-sensor` consumer at `0x100a788` resolves each record's device ID
against 124-byte `soc-device` records. The selected live metadata names device
6 `ANE0`, device 4 `PACC0`, device 3 `EACC0`, and device 5 `AGX`. However,
this establishes meanings for the long PMP labels, not for four-character
SMC keys. Type-eight temperature records call `0x10237a8` with the resolved
device object and bank. That method registers callback `0x1023904` through
the device's provider object. The callback obtains a bank selector from
runtime-built per-bank configuration; it does not directly supply the SMC
source ID or the `0x150`/`0x152` PTD starts.

The [subsequent bank-configuration trace](macos-pmp-bank-investigation.md)
resolves this selector and virtual call through a mask/unmask-style control
path. It does not assign a temperature output slot; the earlier callback
construction lead is closed. Static named-device configurations were also
located, with runtime mutation still possible.

The live `ptd-range` record named `SOC-DEV-PKT` starts at `0xa8` and spans
`0x180` entries, containing both starts. Membership in that interval does
not connect either source ID to ANE or another component. The remaining
boundary is the origin/layout of the packet data containing those PTD starts.
The scoped
callback/accessor checks are retained in ignored `PMP_PTD_BOUNDARY.md` and
`pmp-soc-thermal-accessor-objdump.txt` under
`dist/havana-smc-artifact-discovery/`.

The current `thermalmonitord` constant-dictionary decoder checked all 4,551
dictionaries without a parse error and found no literal `Ts00`, `Ta00` or
`Tz11`. Computed names and other providers remain possible. This bounded
negative result does not establish that `Tz11` is host-written or virtual.

A further static check rules out the ordinary key-write path as its producer
in this j815 image. `Tz11` and all eight other `Tz1*` leaves have metadata
flags `0xc5`. The command-`0x11` write branch at `0x2b71c..0x2b72c` requires
`(flags & 0x41) == 0x40`; these leaves fail that condition. No write command
was sent to a device. This excludes that standard path, not private
interfaces, internal firmware writes or a different firmware image.
The input-buffer read maps inspected at objects `0x8e478`, `0x8e4a0` and
`0x8e4c8` populate group-one inputs 97 through 100, not `Tz11` input 197.
Its numeric export record `0x470` is also insufficient: the traced routines
use that record array for selection/statistics, which does not establish
the producer of its underlying value pointer.

The subsequent j815 writer audit enumerated direct calls to the common writer
and its wrappers, decoded their static destination maps and reconstructed six
BSS-backed map initializers. None of those destinations is group-one input
197. Alternate backing-pair writer APIs use groups two and three, with no
static alias to `Tz11`'s backing address. The apparent full-backing-range
route at `0x3f5d8` is a diagnostic key-selection reader.

Typed descriptor ownership also distinguishes two uses of the number 197.
Object `0x868f0`, invoked at `0x3bc18`, consumes sensor input 197 and writes
float parameter 165 (`0xa9dec`). Object `0x86cf0`, invoked at `0x3adc4`,
consumes group-two input 50 and writes float parameter 197 (`0xa9e6c`).
That latter parameter is not `Tz11`'s backing address `0xa8624`.
Ignored `dist/tz-producer-validation/` retains the reproducible writer audit,
constructor decoder and `typed-tz197-reference-ownership.json`.
These bounded exclusions do not establish that the channel is reserved:
runtime descriptor changes, indirect computation and other processor or
private interfaces remain outside the demonstrated direct writer paths.

Independent static checks of all nine `Tz1*` leaf flags and the standard
write-gate instructions passed; they are retained in
`dist/smc-ptd-driver-validation/source-boundary-checks.json`.
The [packet/host-driver follow-up](macos-pmp-bank-investigation.md) records
the separate configured PTD windows and variant-dependent ANE thermal path.

Do not strip PMP label suffixes, assign physical locations from table order,
or generalize a mapping to a different board/build without evidence.

Ignored local artifacts are under `dist/smc-firmware-discovery/`,
`dist/havana-smc-artifact-discovery/` and `dist/smc-container-tool-validation/`:
range manifests, input/derived hashes, independent reconstruction and trie
decoders, selected runtime metadata, table crosslinks and retained REA snapshots.
The follow-up also retains `dist/smc-provider-validation/`, including scoped
PTD metadata, matching-build PMP provenance, the thermal constant scan and
`j815-provider-trace.rea.json` / `pmp-provider-trace.rea.json` snapshots.
The independent Ts/Ta pointer/slot checks and 88-record published-field /
20-record firmware-subset checks passed again at this checkpoint.
All root-owned Hopper sessions were closed with snapshots. No firmware was
executed or flashed, and no device power state was changed for this investigation.
