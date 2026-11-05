# macOS sensor identity evidence

Names describe a demonstrated provider or computation role. Raw SMC keys remain
the persisted identity. A friendly label does not imply that a physical site,
core number or sender-side unit contract has been recovered.

The detailed [firmware investigation](macos-smc-firmware-investigation.md) and
[PTD investigation](macos-pmp-bank-investigation.md) retain the positive joins,
artifact hashes, addresses and bounded exclusions. Proprietary input images and
derived binary evidence remain in ignored `dist/` directories.

The latest native probes leave 26 readable generically labeled fields on M5
and 12 on M4. The five M4 `TfC` readings now have verified filtered-maximum sample-average
role labels. The tables below account for generic fields and also retain unit
questions for named computations. A full identity resolution is not claimed.

## Remaining M5 boundaries

| Keys / inputs | Demonstrated identity | Remaining edge |
| --- | --- | --- |
| `Ta00`, `Ta04`, `Ta08`, `Ta0K`, `Ta0O`, `Ta0R` | Six mapped channels of the `a0va` AON PTD source | Named physical publisher to AON destination `0x152` |
| `Ts00`, `Ts04`, `Ts08`, `Ts0C`, `Ts0G`, `Ts0K`, `Ts0O`, `Ts0R` | Eight mapped channels of the `s0va` AON PTD source | Named physical publisher to AON destination `0x150` |
| `TPDD`, `TPDE`, `TPDF` | Registered group-one inputs 114–116 | Actual producer and physical source |
| `Tz11`–`Tz18`, `Tz1j` | Registered group-one inputs 197–205 | Actual producer and physical source |
| `SDN0`, `SDN3` | Logical MSP0/MSP1 storage temperature channels, signed quarter-degrees Celsius | Exact physical sensor sites; host HID reports the aggregate composite |
| `TAOL` | Ambient light sensor temperature: exact AOP `als-temp` provider through `zEAO` slot zero | Independent upstream unit contract; exact transducer placement |
| `TB1T`, `TB2T` | Battery provider command `0x6c`, two tenths-scaled fields | Sender-side unit contract for those fields |

The named ANE0/SNE MTR hardware has the same noncontiguous channel layout as
`a0va`. That is a useful lead, not the missing routing edge. Current installed
PMP preserves the inspected ANE0 consumer functions and configuration, but this
does not establish equivalence of the entire image or its AON publisher.

The twelve unexplained group-one inputs share initial status zero, descriptor
flags and nonnull backing with active inputs. Successful updates also use
status zero. Static registration therefore cannot distinguish unavailable
channels from real zero readings. They must not be hidden as unavailable or
called reserved merely because a bounded writer search found no producer.

The fixed/adaptive `TV` computation roles are identified independently of these
remaining source contracts. Their labels do not turn model outputs into direct
physical sensor measurements. `TVMD` is a categorical selector, excluded from
Celsius readings on the validated M5 model.

## Firmware acquisition and build checks

Matching-build M5 firmware is now available from Apple's 27.3 / 26C5035r
restore archive. Bounded ZIP range requests retrieved the j815 LLB and t8142
ANS components; both match the exact board/chip BuildManifest SHA-384 digests.
The extracted SMC reports `AppleSMCFirmware_H17_6-7372.60.63.j815.REL`.

All 2,431 SMC key records, 148 temperature-key records and 291 group-input
associations match the earlier 26B123 inventory. Addresses changed, including
an eight-byte shift in temperature backings; producer checks independently rederive the selected PMU and serial-monitor
bindings, 47 adjustments, seven maxima, six fixed models, adaptive-model
bindings, eight categorical consumers, TAOL and the TH0x copy. They preserve
those logical bindings, rather than inferring them from inventory equality. Current LLB MTR
configuration checks also preserve all seven named hardware records and the
617 MTR / five DPE operations after pointer normalization. They still do not
supply the missing AON publication edge.

These are archive/build provenance checks. Active first-stage firmware bytes
were not read back. No firmware execution or device-state change was used.

## Remaining M4 boundaries

| Keys / inputs | Demonstrated identity | Remaining edge |
| --- | --- | --- |
| `TPDF`, `TRDF`, `TTDF` | Group-two inputs omitted by the selected PMU stream maps but included in their maxima | Actual producers; no extrapolated die label |
| `TfC0`–`TfC4` | Power management temperature maximum 1–5 (filtered average): two thermal captures, low-pass filter, then sample mean; exact Abbey parent and downstream target configured | Downstream transducer/package site; no CPU/GPU inference |
| `Tz11`–`Tz18`, `Tz1j` | Separate j773s group-one inputs | Actual producers and physical sources; no M5 producer assumption |

The M4 `TVmd` input is demonstrably consumed as a categorical control, but its
assignment producer is not identified. Its separate step-map output `TVMD`
has a proven normal categorical producer. Both controls are excluded from
Celsius readings on the validated M4 model.
The four remaining `TV` computation roles are fixed affine models, now named
by role. Their identities as computations do not establish physical sensor
sites or resolve every upstream feature's sender-side unit contract.

The complete selected M4 PMU stream family has now been checked: nine active
objects and all 132 TV/SL/TD mappings reconstructed from native constructor
instructions. None assigns the nine `Tz` inputs or the three omitted PMU `F`
inputs. That closes this selected-map boundary, not all possible runtime
configuration or private writers.

Sender-side ANS and embedded PMU firmware are now available for static analysis;
their hashes and acquisition/extraction proofs are recorded in the firmware
investigation. Their acquisition does not by itself close the packet contracts
listed above. A newly verified synchronous SMC query path accepts the ANS class-three /
subtype-17 response and copies it into the same SDN buffer. The earlier
class-four / subtype-14 audit covered only the asynchronous path and did not
exclude this synchronous producer.

The current ANS query array now has a positive writer: NAND-engine command
`0x7a` supplies the indexed temperature values. Its signed `/4` consumer takes
a maximum, then adds 273 when filling the standard NVMe health log's Kelvin
field. This establishes the engineering Celsius contract by an explicit
producer/consumer conversion. The matching installed MSP responder now traces the selected type-zero
request to a calibrated local ADC temperature provider. Exact active file
selection and transducer placement remain separate boundaries. The composite
maximum is distinct from either individual SDN channel and does not prove
equality with the host's NAND HID reading.

The current OS shared-cache scan found no `zEAO` writer candidate across 84
system cache/support files (7.23 GB), using checked ASCII, UTF16 and split
instruction patterns. This is a bounded negative search on 26C5035r; dynamic
key construction and writers outside that cache were outside its scope. The
later AOP client/configuration proof now identifies the exact `als-temp` writer
and supports the ambient light sensor provider label.

The fast-die timing lead has also been followed through its output guard.
Its implementation can publish packed temperature sum/count records to the
PMP plane, but all 25 current M5 and all ten current M4 source records have
output selector zero. The native code skips accumulation/publication for those
records. This conditional capability therefore does not identify the current
AON or `TfC` producers.

Current AOP/AOP2 bundles were reconstructed from explicit component metadata.
The AOP reference to `0x38c840000` is an MMIO permission range, which does
not establish an AON publication. A later actual-client trace positively joins
`als-temp` to `zEAO` and `TAOL`, superseding the earlier AOP constructor scan
that missed an intervening instruction. PMC, MSR and TMU candidate
images were inspected with their exact build/provenance boundaries; none
provided a positive routing join in the bounded checks.

For M4 `Tz` and the three omitted PMU `F` fields, the fixed selected normal
typed writer graph is now closed across the simple, weighted, packet, cache,
MTR, PMU, counter and delta families. No configured sampling edge reaches
these twelve fields. Selected raw-copy buffers are disjoint from their value
backings, accessors return values/status/indices rather than writable pointers,
and ordinary public writes reject their `0xc5` flags. The additional nine Tz
pointer records are scalar monitor consumers: they read the source and update
their own accumulators. Earlier descriptions of these records as key leaves
were imprecise. The F average flush still writes zero for an empty sample
window; that software value is not a measurement of zero degrees.

This result assumes the supplied constructors/maps and normal typed protocols;
arbitrary memory writes, corruption, patches and configuration outside that
graph are excluded. It does not establish a transducer identity or justify
calling these fields unavailable, unassigned or reserved. The reproducible
closure is retained in `dist/m4-pmuf-source/configured-closure/`.

The official diagnostic assets are now available and checked, superseding the
initial local-DNS acquisition failure. Exact native board/chip selectors choose
M5 profile 5089 and Havana profile 5076. Their temperature descriptions are raw
SMC keys; they provide no remaining AON/TfC/Tz physical map. The paired repair
image also supplies no such catalogue. This is a catalogue boundary, not proof
that uncatalogued inputs are unavailable. See the firmware investigation for
the acquired image hashes and exact profile-selection checks.

The exact restore DeviceTree adds no missing boot-only PMP mapping: all 61 PMP
properties and 36 additional scoped PTD/MMIO/interrupt properties match the
current live tree byte-for-byte. The production ApplePTD user client rejects
initialization and external methods; its retained packet-read helper is not a
callable API. Its alternate SMC path requests `ptdR`, absent from the current
SMC trie. Public registry metadata describes slots, not their samples or
physical sources. No hardware packet-read experiment was performed.

Official iStat Menus 7.50/build 2394 exact-model recipes for Mac17,4 and
Mac16,11, and its global recipe, omit the unresolved target keys. TG Pro
2.104 resources and its supplied-text-file loader add no identity catalogue.
Pinned iSMC correlations do not supply a producer join. These checks justify
no additional labels; proprietary binaries and derived catalogue data remain
outside the repository.

## Evidence needed to close these boundaries

An exact named producer-to-destination configuration or packet contract can
close a physical/unit identity. A matching source string, channel count,
instantaneous value, table position, sibling-board map, or workload correlation
alone cannot. New matching-build firmware or the missing sender-side component
should be checked against the retained hypotheses before repeating completed
negative searches.
