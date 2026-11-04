# macOS sensor identity evidence

Names describe a demonstrated provider or computation role. Raw SMC keys remain
the persisted identity. A friendly label does not imply that a physical site,
core number or sender-side unit contract has been recovered.

The detailed [firmware investigation](macos-smc-firmware-investigation.md) and
[PTD investigation](macos-pmp-bank-investigation.md) retain the positive joins,
artifact hashes, addresses and bounded exclusions. Proprietary input images and
derived binary evidence remain in ignored `dist/` directories.

The latest native probes leave 26 readable generically labeled fields on M5
and 17 on M4. The tables below account for those fields and also retain unit
questions for named computations. A full identity resolution is not claimed.

## Remaining M5 boundaries

| Keys / inputs | Demonstrated identity | Remaining edge |
| --- | --- | --- |
| `Ta00`, `Ta04`, `Ta08`, `Ta0K`, `Ta0O`, `Ta0R` | Six mapped channels of the `a0va` AON PTD source | Named physical publisher to AON destination `0x152` |
| `Ts00`, `Ts04`, `Ts08`, `Ts0C`, `Ts0G`, `Ts0K`, `Ts0O`, `Ts0R` | Eight mapped channels of the `s0va` AON PTD source | Named physical publisher to AON destination `0x150` |
| `TPDD`, `TPDE`, `TPDF` | Registered group-one inputs 114–116 | Actual producer and physical source |
| `Tz11`–`Tz18`, `Tz1j` | Registered group-one inputs 197–205 | Actual producer and physical source |
| `SDN0`, `SDN3` | Two fields received from `ans_to_smc`, message subtype 14 | Sender-side unit and field semantics; SMART/HID equivalence unproved |
| `TAOL` | Sensor input: float at offset four in writable packet `zEAO` | Actual writer, physical source and unit contract |
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

## Firmware acquisition boundary

The inspected j815 SMC image comes from Apple's 26B123 restore archive; the
local M5 runs 26C5035r. The local selected restore tree contains current iBoot,
PMP and other components, but no matching j815 LLB was found in the bounded
firmware/preboot locations. The two local MacSoftwareUpdate catalogs contained
no assets, and the attempted official metadata endpoint returned HTTP 403.
That is an acquisition limit, not proof that a matching image cannot exist.
No full restore archive, raw flash read, firmware execution or device-state
change was used to bridge it.

## Remaining M4 boundaries

| Keys / inputs | Demonstrated identity | Remaining edge |
| --- | --- | --- |
| `TPDF`, `TRDF`, `TTDF` | Group-two inputs omitted by the selected PMU stream maps but included in their maxima | Actual producers; no extrapolated die label |
| `TfC0`–`TfC4` | Sample averages from PTD packets `p0t1`, `g0t1`, `p1t1`, `g1t1`, `s0t1`, respectively | Named physical owners and packet-field meaning; a measured value versus limit is not established |
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
listed above. In particular, the similar ANS query-response record uses a
different wire class/subtype from the exact SDN receiver.

The current OS shared-cache scan found no `zEAO` writer candidate across 84
system cache/support files (7.23 GB), using checked ASCII, UTF16 and split
instruction patterns. This is a bounded negative search on 26C5035r; dynamic
key construction and writers outside that cache remain open. It does not
identify the writer or justify an ambient-light temperature label.

The fast-die timing lead has also been followed through its output guard.
Its implementation can publish packed temperature sum/count records to the
PMP plane, but all 25 current M5 and all ten current M4 source records have
output selector zero. The native code skips accumulation/publication for those
records. This conditional capability therefore does not identify the current
AON or `TfC` producers.

Current AOP/AOP2 bundles were reconstructed from explicit component metadata.
The AOP reference to `0x38c840000` is an MMIO permission range, and its SMC
service supports generic key requests with runtime-provided keys. Neither is
a concrete `a0va`, `s0va` or `zEAO` publication. PMC, MSR and TMU candidate
images were inspected with their exact build/provenance boundaries; none
provided a positive routing join in the bounded checks.

For M4 `Tz`, the selected normal writer families are now classified across
MTR, cache, protocol, PMU, fallback and outlined calls. Fixed-reference checks
find the known state/pair/key-descriptor references, with no identified value
writer. Runtime-loaded/indexed pointers, private configuration and bulk memory
operations remain outside that closure. This still does not justify calling
these inputs unavailable, unassigned or reserved.

## Evidence needed to close these boundaries

An exact named producer-to-destination configuration or packet contract can
close a physical/unit identity. A matching source string, channel count,
instantaneous value, table position, sibling-board map, or workload correlation
alone cannot. New matching-build firmware or the missing sender-side component
should be checked against the retained hypotheses before repeating completed
negative searches.
