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

XRG uses SoC die temperature channel labels for these 26 keys on `Mac16,11`
only, preserving current, average and adjusted-average roles. The decoded
j773s LLB independently names the exact `0x500400000` register block
`SOC_SubSystem5.SouthBridge.PMS.PMS_DEVC_TOP.MTR_TOP_SOC.MTR`, with eight
channels. This strengthens the die-temperature module identification to a
named SoC block; the special ninth reading also uses that block. It does not
identify physical cores, clusters, GPU sites or a matching named DeviceTree
register node. Ordinals follow firmware stream order. The decoded LLB SHA-256
is `2eefa46853c433e5bfd51581397e1a2819c16d0a7fdc0fa0c6487073303296b8`;
`j773s-mtr-soc-label-proof.json` retains the independently decoded name,
descriptor and address facts.

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

## Resolved j815 PMU die streams and computed maxima

On `Mac17,4`, 21 readable stream keys share an exact HAL object and ADC ID
with canonical temperature sources whose names are published by the native
driver. Provider selection at `0x33c08` joins P-source keys to HAL `0x8f5b0`
and R-source keys to HAL `0x8f630`. The corresponding key-to-ADC methods are
`0xe700` and `0xc280`. Canonical reads through `0x2d308` / `0x9ddc` and stream
reads through `0x10368` call the same provider engineering converter for each
ADC ID. These stream values are Celsius, not raw ADC counts.

| Stream keys | Canonical sources | Published identity |
| --- | --- | --- |
| `TPD0`–`TPD8` | `TP1b`–`TP9b` | PMU die 1–9 |
| `TPD9` | `TPab` | PMU die 10 |
| `TPDA`–`TPDC` | `TPbl`, `TPcl`, `TPdl` | PMU die 11–13 |
| `TRD0`–`TRD6` | `TR1b`–`TR7b` | PMU2 die 1–7 |
| `TRD7` | `TR8l` | PMU2 die 8 |

The application requires the exact model and each exact canonical source's
qualified live PMU die label. Canonical ADC source IDs need not appear in the
ordinary SMC key inventory; their metadata can name a verified stream alias
without fabricating an extra readable key. Other models and missing or
inconsistent source labels retain their existing fallback.

Three j815 keys describe computations rather than individual physical CPU
sensors. `TPDX` takes the maximum of inputs 101–116, including three inputs
outside the thirteen mapped PMU die streams. `TRDX` takes the maximum of
inputs 118 and 120–126; it skips two stream entries. Both use the label
Temperature maximum (selected channels), without claiming a maximum over all
PMU sensors. `TCMb` takes a nonnegative-seeded maximum of 47 floats
(`0xa9e88` through `0xa9f40`). All 47 sources are active transforms of inputs
142–188, applying individual offsets and a `[-20,120]` clamp. Its label is
Adjusted temperature maximum; the previous CPU family fallback was inaccurate.

Ignored `dist/tz-producer-validation/td-source/` retains the original mapping
and inverse decoders, focused instructions, `td-identities.json` and
`tcmb-adjusted-sources.json`. The full Debug gate passed on both hosts with
648 tests per architecture and native / Rosetta packaged smoke checks.
Fresh linked probes verified all 24 M5 names and readable temperature values,
and verified that the aliases/maxima labels do not apply on Havana. Logs and
snapshots are in ignored `dist/pmu-alias-name-validation/`.

## Resolved j815 PMU device streams

Eleven further stream keys share exact HAL/ADC identities with published PMU
device-temperature sources. Both stream mode one and canonical reads call
the same engineering converter with the same reference ADC. The primary
provider's device ADC range is `0x93..0x9a`, with reference `0x92`; the
secondary provider uses `0x8b..0x8f`, with reference `0x8a`.

| Stream key | Published source | Identity |
| --- | --- | --- |
| `Tm0B` | `TP2d` | PMU device 2 |
| `TIOP` | `TP3d` | PMU device 3 |
| `TW0P` | `TP4d` | PMU device 4 |
| `TPMP` | `TP5d` | PMU device 5 |
| `T5SP` | `TP6d` | PMU device 6 |
| `TCHP` | `TP7d` | PMU device 7 |
| `TMVR` | `TP8d` | PMU device 8 |
| `TH0T` | `TR2d` | PMU2 device 2 |
| `TSDD` | `TR3d` | PMU2 device 3 |
| `TSCD` | `TR4d` | PMU2 device 4 |
| `TPSP` | `TR5d` | PMU2 device 5 |

These names require `Mac17,4` and each exact qualified live source label.
The generic CPU, memory and drive interpretations of `TCHP`, `TMVR` and
`TH0T` are therefore incorrect on this model. If the required metadata is
unavailable, these verified aliases use a generic fallback instead of those
misleading families. Source metadata does not add keys to the inventory.

`TRD8` and `TRD9` are bound to the same PMU2 HAL as the other F1TD channels
and use its temperature converter. They are labeled Power management 2
temperature channel 9 and 10. These numbers identify stream descriptor
positions; no accepted canonical die/device key maps to their ADC IDs
`0x52` / `0x53`, so they are not labeled PMU2 die 9/10 or given board locations.

Ignored `dist/tz-producer-validation/td-source/tv-identities.json` retains
the eleven exact device aliases. The SL streams were checked separately:
their 42 destinations contain current/voltage values and do not intersect
the temperature-key map. No temperature labels are inferred for them.

This batch passed the full Debug gate on both hosts: 650 tests per
architecture, universal builds and native / Rosetta packaged smoke checks.
Linked native probes verified all 37 combined M5 stream/maximum names with
readable values, the other-model fallback on Havana, and all 38 Havana
Neural Engine / SoC die names. Ignored `dist/pmu-device-name-validation/`
retains gate logs and snapshots.

## Resolved j815 serial monitors and further maxima

Four keys come from two separate register temperature-monitor objects, not
from the similarly spelled SoC/PMU families. Object `0x8ea20` uses controller
argument two and address `0x90`; registers zero and one feed `TDBP` and `TDeL`.
Object `0x8ea50` uses controller three and address `0x98`; its first two
registers feed `Ts0P` and `Ts1P`. The successful producer at `0x10900` decodes
signed big-endian samples and publishes engineering temperatures through the
common writer, using divisors 128 and 256 respectively. Read/init failures
publish invalid status instead of a new value.

On `Mac17,4`, these are Temperature monitor 1 channel 1/2 and Temperature
monitor 2 channel 1/2. Monitor ordinals follow the two producer objects in
address order, and channel ordinals follow their register maps. Exact chip
models, local/remote roles and board placements are not established. Disabled
register slots are not promoted to sensors. Original source-bound evidence
and protocol-family references are retained in ignored
`dist/tz-producer-validation/other-source/`.

Six more computed fields have verified maximum operations:

| Key | Exact inputs | Label |
| --- | --- | --- |
| `TVDA` | adjusted parameters 204–209 | Adjusted temperature maximum |
| `TVDG` | adjusted parameters 210–232, from the Tg family | GPU temperature maximum (adjusted) |
| `TVDP` | adjusted parameters 233–246, from the Tp family | CPU temperature maximum (adjusted) |
| `TVDE` | adjusted parameters 247–250, from the Te family | CPU efficiency temperature maximum (adjusted) |
| `TVD0` | maxima `TVDA`, `TVDG`, `TVDP`, `TVDE` | Adjusted temperature maximum |
| `TVV0` | direct transforms of `TPDX` and `TRDX` | Temperature maximum (selected channels) |

These labels use the existing validated temperature families without assigning
core numbers or interpreting the unidentified Ta source as ANE. `TVD0` and
the nonnegative-seeded `TCMb` retain separate keys and values. The original
`verify_j815_tv_max.py` reproducer and `j815-tv-max-proof.json` retain the
direct publication calls, source descriptors and maximum algorithm.

The full Debug gate passed on both hosts with 652 tests per architecture,
universal builds and native / Rosetta packaged smoke checks. Native probes
verified all 47 combined M5 names with readable values, and verified that
these model-specific names do not apply to Havana. Ignored
`dist/monitor-maximum-name-validation/` retains logs and snapshots.

## Resolved j815 copied PMU channel and categorical selector

`TH0x` is a direct copy of `TH0T`: `0x30914..0x30928` reads sensor
group one input 7 and writes its unchanged value to input 11 through
`0x3da54` / `0x3d988`. It therefore uses the same live `TR2d` PMU2 device 2
label, with its distinct raw key retained. This is a producer trace, not a
conclusion drawn from equal readings.

`TVMD` is consumed as a discrete thermal-control selector. Eight verified
lookup consumers match it against rows `[0, 1, 2, 3]`; their outputs include
different policy thresholds. This categorical use does not establish its
assignment routine or exhaust every possible value. On `Mac17,4`, it is
labeled **Thermal control selector** and excluded from Celsius readings.
The exclusion is exact to this model/key; zero-valued temperature readings
remain visible. The floating-point wire format and `T` prefix alone are
insufficient to classify a key as temperature.

Ignored `dist/tz-producer-validation/other-source/model-source-units.json`
and `dist/havana-smc-artifact-discovery/j815-tvmd-consumer-proof.json`
retain the source/sink namespace joins and lookup contracts. The other TV
models have verified computation graphs, but their complete upstream unit
contracts and physical origins remain open. In particular, `0x3a948`
source descriptors refer to sensor group/input indices, whereas its sink
can refer to generic float parameters. Those numeric namespaces must not
be joined by equal index alone.

Both hosts passed the full Debug gate: 634 Swift tests plus 19 XCTest tests
per architecture, universal builds, isolated AppKit checks and packaged smoke
checks. Native probes verified all 48 selected M5 names and the selector's
exclusion (147 temperature keys), while Havana retained its 273 temperature
keys. Logs and snapshots are retained under ignored
`dist/selector-alias-name-validation/`.

## Resolved j815 thermal computation roles

Nine further `TV` labels describe verified computations rather than physical
sensor sites. Six affine-model objects published by `0x613c`, in object order
`0x908f8..0x90970`, produce `TVS1`, `TVS0`, `TVA0`, `TVAC`, `TVN0`, `TVN1`.
They are labeled **Fixed thermal model 1** through **6**. These ordinals are
model identities, not component or sensor positions. Their upstream filters
consume PMU device inputs, battery-provider channels, `TAOL`, and ANS telemetry;
the two final models also consume a sum of power-model inputs.

`TVMR` is the weighted scalar result of the adaptive computation at
`0x3b0d4..0x3b3ec`, labeled **Adaptive thermal model**. Its seven `iaw*`
outputs are coefficients, not seven temperatures. `TVmS` clamps that result
against selected bounds and the outer interval 0..200, labeled **Bounded
thermal model output**. `TVNS` takes the maximum of `TVN0` and `TVN1`, labeled
**Thermal model maximum**. None of these names assigns a physical location.
The labels distinguish calculations from direct sensor readings; they do
not close the remaining sender-side unit contracts or change value decoding.

The storage source has a positive transport identity: `ans_to_smc` registers
callback `0x2eeec`; its class-four messages enter queue `0xa4a38`; worker
`0x2f2b8` dispatches subtype 14 to `0x2f5d8`. That handler writes two six-byte
records to `0xa43d0`, selected by payload bit 45. The reader at `0x30980`
extracts signed bits 30..44 divided by four, exposing `SDN0` and `SDN3`.
This identifies the asynchronous ANS transport. The later current-build
synchronous path and NAND-engine/SMART unit join are documented below;
individual SDN-to-HID sensor equality remains unproved.

`TAOL` reads its float from the `zEAO` host-input blob at `0xa3578 + 4`, through
object `0x8e478` and record `0x89454`. This positive packet join does not identify
the host writer or a physical ambient-light temperature sensor. Neither
similar spelling nor a matching instantaneous reading establishes that source.

The ordinary command-`0x11` write path supplies a concrete input interface:
`zEAO`'s `0xc0` flags pass the permission gate, its size must match 32 bytes,
and the accepted request is byte-copied into that exact backing buffer at
`0x2b980..0x2b98c`. The initial M5 label was **Sensor input**, replacing the unverified Ambient
family claim. The later current-build AOP proof below identifies the actual
`als-temp` writer and refines that label; the input-interface proof remains
independent of the upstream unit contract.
Ignored `dist/aon-source-routing-validation/taol-role/` retains the native
write-gate/copy proof and passing `verify_taol_write_role.py` reproducer.
The input-role label passed both hosts' full Debug gates with 659 tests per
architecture, universal builds and native / Rosetta packaged checks. Native
probes verified 58 selected M5 labels and 79 selected M4 labels. Logs and
snapshots are retained under ignored `dist/taol-role-name-validation/`.

Ignored proof artifacts include `tv-fixed-model-producers.json` and
`tv-model-initializer-proof.json` under `dist/aon-source-routing-validation/`,
the clamp and maximum proofs under `dist/havana-smc-artifact-discovery/`, and
`ANS_SDN_PRODUCER.md` / `ans-sdn-producer-route.json` under
`dist/tz-producer-validation/other-source/`.

## Resolved j773s categorical controls and computed maxima

The M4 proof is independent of the M5 table. An active call at `0x29250`
uses object `0x7b6a0` / configuration `0x6ab58` to map `TVmd` (generic float
parameter 304) through an eight-point step table to `TVMD` (parameter 13).
The input grid is 0..7 and outputs are `[0, 2, 3, 2, 1, 1, 1, 1]`.
The producer selects a table entry rather than interpolating. `TVMD` is
therefore labeled **Thermal control selector**; the case-sensitive `TVmd`
input is labeled **Thermal control input**. Both are excluded from Celsius
readings on `Mac16,11`. The input's assignment producer remains unresolved.

`TVD0` takes the maximum of 45 transformed inputs through object `0x78c68`
and routine `0x3ae0`. All 45 transforms have zero additive offset and no clamp:
32 CPU-family channels, seven GPU-family channels and six adjusted ANE
channels. `TCMb` and `TCMz`, group-one inputs 314 and 315 respectively, each
take a nonnegative-seeded maximum over a separate set of 66 inputs. Those
sets also include SoC and additional channels. They are not CPU-only maxima,
and neither should be described as equivalent to the smaller `TVD0` set.
All three receive **Temperature maximum (selected channels)** labels, with
raw keys distinguishing the computations.

The hash-checked reproducer and exact source sets are retained under ignored
`dist/havana-smc-artifact-discovery/m4-computed/`: `verify_computed_roles.py`,
`computed-role-proof.json` and `FINDINGS.md`.

## Resolved j773s PMU streams

Three exact named streams, `L1TD`, `F1TD` and `F2TD`, bind distinct PMU HAL
objects `0x77428`, `0x774a8` and `0x77528`. Their 16-entry maps publish
`TPD0..TPDE` / `TPDG`, `TRD0..TRDE` / `TRDG`, and `TTD0..TTDE` / `TTDG`.
The `F` suffix in each family is skipped by these maps; it must not receive
an extrapolated PMU label. ADC selectors identify die channels 1..15 and 17
in the logical ADC-ID namespace. Sixteen consecutive packed fields map to
selectors `0x4d..0x5b` and `0x5d`; selector `0x5c` explicitly returns `-22`
without conversion output. This does not imply seventeen physical captures.
The separate `PMU tcal` key `TP0Z` uses selector `0x92`. No source edge from
the unmapped `F` inputs to `0x5c` is inferred.
The shared PMU engineering-temperature converter produces signed 16.16 values
before conversion to float.

These public keys point to the second value backing in group two, not group
one. Their producer accumulates value × 1000 and weight 1000; the periodic
flush divides accumulated numerator by denominator and writes that backing.
All 48 individual labels therefore include **(average)**, without claiming
an averaging interval. This is distinct from M5's current-value aliases.

The first fourteen primary stream channels select exactly the same HAL and
ADC IDs as live published `TP1b..TPab`, `TPbl..TPel`, and use those PMU die
labels with the average suffix. The remaining channels use **Power management
stream N die channel M (average)**. Stream ordinals identify firmware provider
instances; they do not assign package positions. `Ta0p` and `Tm0p` select the
primary published `TP3d` and `TP5d` device channels. `Tm1p` selects stream
three's device channel two, with no invented primary published alias.

`TPDX`, `TRDX`, `TTDX` each take the latest maximum over seventeen current
group-two inputs in their family, including the skipped `F` input. Their
writer replaces the accumulator and sets denominator one, so these maxima
are not temporal averages. They use **Temperature maximum (selected channels)**
labels. The missing `F` producer remains a limitation of those source sets.

Ignored `dist/aon-source-routing-validation/m4-pmu/` retains the passing
`verify_m4_pmu_aliases.py` hash-checked reproducer, `m4-pmu-alias-proof.json`,
original assembly excerpts and `FINDINGS.md`.

The combined model-role / M4 PMU checkpoint passed the full Debug gate on
both hosts with 656 tests per architecture, universal builds and native /
Rosetta packaged smoke checks. Native probes verified all 57 selected names
on each host, with 147 M5 temperature keys and 271 M4 temperature keys after
the categorical exclusions. Evidence is retained under ignored
`dist/model-m4-pmu-name-validation/`. The
[identity status ledger](macos-sensor-identity-status.md) records the remaining
source and unit boundaries separately from these demonstrated roles.

The subsequent complete device-stream decode covers all eighteen selected
group-one inputs 0..17. Seven primary inputs join live published device names:
`TMIA` → `TP1d`, `Ta0p` → `TP3d`, `TMIB` → `TP4d`, `Tm0p` → `TP5d`,
`TH0p` → `TP6d`, `TUVR` → `TP7d`, `TPMP` → `TP8d`.
Stream two's device channels 1..7 are `TPCP`, `TW0P`, `TPSP`, `TNwC`,
`TUVS`, `TPSD`, `TMVR`; stream three's channels 1..4 are `TIED`, `Tm1p`,
`TSCE`, `TSCW`. These are current engineering temperatures from the exact
owning HAL and reference-ratio thermistor converter. They receive no average
suffix. The stream-qualified labels replace misleading generic component
families without inventing published canonical identities for other providers.

## Resolved j773s fixed-model roles

Four active objects `0x79bc8`, `0x79be0`, `0x79bf8`, `0x79c10` publish
`TVS0`, `TVS1`, `TVA0`, `TVN0` through fixed affine routine `0x4c74`.
They are labeled **Fixed thermal model 1** through **4**, in this board's
object order. These are different formulas and source vectors from the M5
models; a shared raw key does not establish an identical computation.
The labels describe calculation roles, with physical placement and unproved
upstream unit contracts remaining separate questions.

For example, `TVS0` uses intercept 4.92 and coefficients
`[-1.65, 2.17, -0.75, 0.19, 0.8]` over the filtered generic float parameters
`ft03`, `ft04`, `ft07`, `ft01`, `ft00`. `TVS1` uses the same feature vector
with different coefficients and intercept. `TVA0` and `TVN0` use separate
five- and three-feature vectors. These source IDs belong to the generic float
parameter namespace, not hardware input indices.

`verify_fixed_models.py` and `verify_model_features.py` under ignored
`dist/havana-smc-artifact-discovery/m4-computed/` independently verify the
active producers, coefficient vectors, filters and known source transforms.
The remaining feature contracts include `fc0T`'s assignment and a group-three
`PH2R` source; no temperature-only feature vector is claimed.

The complete M4 device/model checkpoint passed both hosts' full Debug gates
with 657 tests per architecture, universal builds and native / Rosetta packaged
checks. Native probes verified 76 selected M4 labels and 57 selected M5 labels.
The remaining readable generic fields number 17 on M4 and 26 on M5; these
are recorded separately from the named computations' unresolved unit contracts.
Ignored `dist/m4-device-model-name-validation/` retains the logs and snapshots.

## Resolved j773s calibrated channels and their maximum

`TH0a` and `TH0b` are two calibrated channels read by a serial-device
transaction at `0x2a050`, not demonstrated Drive/SSD/HDD locations. The
transaction receives six bytes containing three twelve-bit values. One is a
common reference; the other two are scaled by `1651 / reference` and passed
through six piecewise-affine calibration segments at `0x4f828`, via `0xaf20`.
The resulting group-one inputs 18 and 19 are labeled **Calibrated temperature
channel 1** and **2**. This identifies their processing roles without guessing
the chip, thermistor family or mounting location.

`TH0x` is group-one input 20. The exact sequence `0x2bf80..0x2bfb4` reads
inputs 18 and 19 in the group-one namespace, selects the larger, rereads that
source and publishes it unchanged. It is labeled **Temperature maximum
(calibrated channels)**. No explicit source-status filter is present in this
selection. The M5 `TH0x` PMU copy retains its different verified identity.

Ignored `dist/tz-producer-validation/m4-other/th-drive/` retains the independent
hash-checked `inspect_th_roles.py`, exact calibration coefficients, byte decode,
input/backing joins and original instruction excerpts.

Both hosts passed the complete Debug gate with 658 tests per architecture,
universal builds and native / Rosetta packaged checks. Native probes verified
all 79 selected M4 labels and the 57 selected M5 labels, including the distinct
board-specific `TH0x` identities. Ignored
`dist/m4-calibrated-name-validation/` retains the logs and snapshots.

## Resolved j773s telemetry-average roles

The five `TfC` exports point to the second group-two value backings for inputs
71..75. Their exact packet joins are:

| Key | PTD source | Group-two input |
| --- | --- | ---: |
| `TfC0` | `p0t1` | 72 |
| `TfC1` | `g0t1` | 73 |
| `TfC2` | `p1t1` | 71 |
| `TfC3` | `g1t1` | 75 |
| `TfC4` | `s0t1` | 74 |

All five active updater objects select format four, decoding a signed sixteen-bit
field at packet offset two divided by 64. Successful reads contribute that
sample and denominator one through `0x26a8c` / `0x26f6c`. Flush `0x26f24`
divides accumulated numerator by denominator and exports the arithmetic mean;
an empty window exports zero. A disabled flush flag can defer publication.
These are sample averages, without a claimed time weighting or interval.

The later sender-side PMU proof resolves the input meaning. The exact boot
configuration is parsed by the extracted PMU firmware, using each variant's
own schema/handler table. For all five packets, telemetry tag 29's field at
offset two selects tag 9 low-pass record four. That record's source resolves
to tag 3's maximum of two enabled thermal captures. The firmware then converts
signed Q16 to Q6 for telemetry; SMC accumulates the arithmetic sample mean.
The five fields are therefore **filtered thermal maxima followed by sample
averaging**, rather than individual instantaneous sensor readings.

The native boot loader explicitly matches named parent endpoints, independently
of packet prefixes:

| Key | Parent endpoint | Private bus / target |
| --- | --- | --- |
| `TfC0` | `AbbeyF1Priv` | 1 / 1 |
| `TfC1` | `AbbeyF1Priv` | 1 / 4 |
| `TfC2` | `AbbeyL1Priv` | 1 / 2 |
| `TfC3` | `AbbeyF2Priv` | 1 / 5 |
| `TfC4` | `AbbeyF2Priv` | 1 / 3 |

These are named PMU parents and configured private targets, not physical
transducer/package names. The thermal conversion uses integer Q16 coefficients
5240 and -6964969, matching the independently inspected canonical PMU die
conversion family after coefficient quantization. The proof preserves that
quantization and calibration-offset distinction; sample equality is not
claimed. No CPU/GPU source follows from `p`/`g`/`s` prefixes.

Labels **Power management temperature maximum N (filtered average)** follow
`TfC0`..`TfC4` key order. Their ordinal identifies the presentation entry,
without claiming a die, CPU core or native bus address. These refine the
earlier **Telemetry input N (average)** role labels. The separate PMP fast-die
input and disabled output paths still do not establish an alias.
Ignored `dist/aon-source-routing-validation/m4-t1-config/` retains the passing
`inspect_t1_config.py` and `verify_t1_owners.py`, source hashes, original
configuration records and native instruction proofs. Earlier SMC
`collect_tfc_proof.py` evidence remains under `dist/tz-producer-validation/m4-other/`.

The initial sample-average naming checkpoint passed both complete Debug gates
with 660 tests per architecture, universal builds and native / Rosetta packaged
checks. Its native probes verified 84 selected M4 and 58 selected M5 labels.
The remaining readable generic names number twelve on M4 and twenty-six on M5.
Those initial logs remain under ignored `dist/m4-telemetry-average-name-validation/`. The
refined power-management maximum labels also passed both full Debug gates
with 660 tests per architecture and the packaged checks. Updated native probes
verified all 84 selected M4 and 58 selected M5 labels; evidence is under ignored
`dist/m4-pmu-filtered-max-name-validation/`.

## Source identity

The later sender-side acquisition retrieved `Firmware/ansf.t8142.release.im4p`
and `Firmware/rans.t8142.release.im4p` from the same Apple 26B123 archive.
Both match their exact BuildManifest SHA-384 digests and decode to identical
ANS payloads, `AppleStorageFirmwareASP3-241.40.4~1099`, SHA-256
`1b091af7ef7e20541a15fdf0141da78e671ac3f91ce2e00f694f8db4a7d461e3`.
All declared section bytes are present. A derived analysis carrier adds only
1,232 missing bytes of trailing segment alignment; that synthetic padding is
explicitly recorded, rather than treated as recovered source bytes.

The ANS mailbox dispatcher contains a record with the same fifteen-bit field
positions as the SMC storage reader, but its demonstrated query response has
wire class 3 / subtype 17. The exact SDN receiver requires raw class 4 /
subtype 14. Those headers are not interchangeable. A later current-build audit found
the separate synchronous response path described below; the earlier
asynchronous-only investigation did not cover it.
Acquisition, layout and bounded protocol evidence are retained under ignored
`dist/aon-source-routing-validation/ans-sender/`.

The direct-call audit covers nine wrapper call sites and 37 primitive branch /
call sites, including tail branches and dynamic headers. None demonstrates the
required class 4 / subtype 14 send. The firmware's three Apple-format pointer
chains decode to 1,297 rebases using the SDK ABI; none targets those send
routines or the inspected mailbox region. Computed references, another send
primitive/component, and protocol compatibility remain outside that boundary.

The original ANS `MH_PRELOAD` has no symbol or entry-point commands. A separate
Hopper analysis carrier adds a synthetic thread PC at the independently found
mailbox prologue `0x1f3ad0`, preserving every payload byte and section mapping.
Its `EntryPoint` label is an analysis seed, not the firmware's real boot entry.
The retained dossier is `ans-mailbox-seeded-evidence.json`; native instructions
remain authoritative where Hopper merges paths or loses bit-field semantics.

The j773s LLB also contains two independently bounded PMU firmware resources.
Native pointer/length getters and their paired callers identify file spans
`0x2b1780..0x2b7b74` and `0x2b7b74..0x2bd490`. Both report
`ApplePMUFirmware-743.40.11~951.release`. They contain Thumb code: their reset
vectors and startup routines establish vector VM `0x20002800`, including the
explicit write of that value to the SCB VTOR register `0xe000ed08`.

| PMU resource | Bytes | SHA-256 |
| --- | ---: | --- |
| 1 | 25,588 | `2968499f5b9fc90c991b351193650ea3fda1ee6aaf269ad44393b259ef7147e3` |
| 2 | 22,812 | `85d2ab93a6a8874b4aa31433f06c0298ced8f2173389acd1735a40265791460f` |

The exact component slices, native getter/VTOR proof, synthetic ELF carriers
and independent extraction reproducer are retained under ignored
`dist/tz-producer-validation/m4-other/`. Recovering these resources establishes
neither the active PMU variant nor the physical owner/unit of the `t1` packet
field. The transport indices are shared PTD slots, not PMU register addresses.
All inspection remains static; none of these firmware images was executed.

The additional controller investigations retain their own proof boundaries:

- `dist/aon-source-routing-validation/fastdie-output/` follows the M5 averaging
  timer through signed-Q6 sum/count packing and conditional publication to
  PMP `0x3803d0000`. All 25 current native source selectors are zero, and the
  code skips those outputs. M4's independent scheduled-loop check finds the
  same guard for all ten native records under
  `dist/tz-producer-validation/m4-other/fastdie-output/`.
- `dist/havana-smc-artifact-discovery/aop-aon/` reconstructs current AOP/AOP2
  components from typed bundle metadata. The AON address belongs to a kernel
  MMIO permission range. The application has a generic SMC write-capable
  service, with runtime-supplied keys; no specific sensor publication follows.
  A root-owned Hopper dossier is retained under `dist/aop-service-analysis/`.
- `dist/tz-producer-validation/pmc-aon/` and
  `dist/aon-source-routing-validation/msr-tmu/` retain exact image hashes,
  manifest verification where acquired, native architecture/source identities
  and bounded marker/address checks. Numeric or remapped routes are not
  excluded by those checks.
- `dist/havana-smc-artifact-discovery/m4-computed/tz/` retains the complete
  selected writer-family and fixed/private-reference audits. No value producer
  is identified for inputs 305..313; runtime pointers and bulk writes remain
  separate limitations, rather than evidence of unavailable sensors.

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

## Matching current M5 firmware

Bounded range requests to Apple's
[27.3 / 26C5035r restore archive](https://updates.cdn-apple.com/2026FallSeed/53df7654-4865-4259-8dae-30177b76f104/UniversalMac_27.3_26C5035r_Restore.ipsw)
retrieved the j815 LLB and t8142 ANS images using 4,871,732 transferred bytes.
The BuildManifest explicitly selects Mac17,4 / j815ap, chip `0x8142`, board
`0x26`; both components match its SHA-384 digests for Erase and Upgrade.
The public beta index was a URL lead; the Apple manifest and archive provide
the component provenance.

| Current component | SHA-256 |
| --- | --- |
| `LLB.j815.RELEASE.im4p` | `018a35e04082f8ac40a7423b9eadcf74ca0bf34e820f144451a4411ba10e2677` |
| `ansf.t8142.release.im4p` | `4fff18b32651cf1f37eb386bb18dd270c5828ef1c3084a8c01ec57c0ce4cd780` |
| Extracted SMC | `51762345c0af0dc6cb1776386a766453f7b6908e2bb2f682ec6bb0d79b90716c` |
| Decoded ANS | `9a875928ed657d7e65b7bb0ea73315cb306bd614f43fa76548417fa0ab8b326e` |

The SMC reports `AppleSMCFirmware_H17_6-7372.60.63.j815.REL` and ANS reports
`AppleStorageFirmwareASP3-241.60.3~407`. All 2,431 SMC key records, all 148
T-key records and all 291 group-input associations match the old inventory.
Backing addresses move by eight bytes; code and table relocations are checked
explicitly. Inventory equality alone does not establish producer equivalence. Independent
current-code checks rederive 34 selected PMU descriptors and both serial
monitors, plus 47 adjusted inputs, seven maxima, six fixed models, adaptive
model bindings, eight categorical consumers, TAOL and the TH0x copy. Their
logical bindings match the earlier proofs. The checks normalize explicit
relocations and compare configuration/operations; they do not claim whole-image
equivalence or resolve new upstream units.
The current LLB comparison also preserves seven named MTR hardware records,
617 MTR operations and five DPE operations after dereferencing relocated
pointers. It does not add an AON source-to-destination route.

Ignored `dist/havana-smc-artifact-discovery/current-26C5035r/` retains the
manifest, acquisition/extraction metadata, independent inventory comparisons
and current producer checks. Current ANS evidence resides under
`dist/aon-source-routing-validation/ans-current/`. This acquisition supersedes
the earlier local/preboot acquisition limit. It remains archive evidence;
active first-stage bytes were not read back or compared.

## Current ANS synchronous SDN producer and units

The current SMC at `0x2faa0..0x2fab8` sends query `0x0211` and waits for the
ANS `0x0311` response. Its success/payload guards lead to a six-byte copy at
`0x2faf0/0x2faf4` into `0xa43d8 + 6 * index`. The current group-input reader
extracts signed bits 30..44 divided by four, joining indices 0/1 to inputs
132/133 and exact keys `SDN0`/`SDN3`. The earlier class-four / subtype-14
handler is an additional asynchronous writer, not the only buffer writer.
No header translation is needed for this synchronous route.

The current ANS producer at native prologue `0x196d74` identifies its source
file as `post_nand_eng.c`. Command byte `0x7a` selects enum 43 and case
`0x196fe4`; its normal response path stores into the queried array
`0x6a123c + 2 * sensorIndex` at `0x197a24`. A forced-value path sign-extends a
byte and shifts it left two before writing the same array. The refresh
routine at `0x76f5c` builds that exact command/type/index namespace.

The unit join is separate and positive: `0x77884..0x77894` reads that same
array as signed 16-bit values and divides by four toward zero. The maximum
is saved at `0x6852f4`; `0x1a793c..0x1a7944` loads it, adds 273 and stores a
16-bit value at offset one in the 512-byte NVMe health log. The caller selects
log page two, and the adjacent fields match Apple's packed `NVMeSMARTData`
SDK structure. The standard defines bytes 1–2 as Kelvin composite temperature.
Thus quarter-degrees Celsius for the input array follows from an explicit
conversion into a unit-defined field, rather than a plausible value range.
See [NVM Express 2.0e, section 5.16.1.3 / Figure 212](https://nvmexpress.org/wp-content/uploads/NVM-Express-Base-Specification-2.0e-2024.07.29-Ratified.pdf).

The request ordinal is also the native MSP group namespace: the refresh
routine's `0..<0x6a11d0` loop supplies request offset eight, and the completion
path uses the same ordinal. Independent `MSP%u` registrations iterate that
same count. Cached controller metadata reports `bus-to-msp = [0, 0, 1, 1]`,
corroborating two logical MSP groups across four buses. Thus `SDN0` and `SDN3`
are logical MSP0/MSP1 storage temperature channels. This does not assign a
physical package or die.

This resolves the SDN engineering unit and indexed NAND-engine producer role.
It does not identify physical die/controller placement. The SMART value is an
aggregate maximum, so equality with an individual SDN input or the host NAND
HID sensor is not claimed. `MSP%u` parameter registrations also return that
global maximum and cannot be used as individual-sensor aliases.

Ignored `dist/aon-source-routing-validation/ans-current/` retains three passing
reproducers: `verify_sync_sdn_route.py`, `verify_ans_temperature_writer.py`
and `verify_temperature_unit_contract.py`, with source hashes and native
instruction excerpts. Root-owned Hopper dossiers use explicitly synthetic
analysis entry seeds; native instructions control where merged pseudocode
loses function boundaries.

## Resolved current M5 ambient light sensor source

Matching-build AOP firmware provides the missing `TAOL` writer and source.
The actual client constructor at `0x1118fac..0x1119034` installs configuration
`0x10b7560`: one source record, destination slot zero, type one, exact native
provider name `als-temp`. Initialization resolves that service and registers
callback `0x100b39c`. Its type-one branch reads a signed Q16 event field,
rejects sentinel `0x7fffffff`, and caches the float plus its validity flag.

The client at `0x100b538..0x100b630` constructs a 128-byte SMC service request
with operation kind one, key `zEAO`, size 32 and that cached float in slot zero.
The generic AOP service emits ordinary SMC command `0x11`; the current SMC
reader joins that exact buffer/slot to input 99 and `TAOL`. The M5 label is
therefore **Ambient light sensor temperature**. It describes the demonstrated
provider, without claiming ambient-air temperature or transducer placement.
The independent sender-side Celsius contract remains a separate question;
this naming change does not change value decoding.

The earlier AOP instruction-pattern scan missed the real constructor because
a size-setting instruction separates the two instructions assembling the key.
Its apparent zero result was not a valid exclusion of an AOP writer. This
positive native call/configuration trace supersedes that result. The separate
host shared-cache scan retains only its stated cache scope.

Ignored `dist/taol-aop-client/verify_taol_aop_source.py` reproduces the complete
join, including comparisons against original decoded AOP segment bytes.
Decoded AOP SHA-256 is
`7fc59b50eaf8b5e4306c6034883f82ddda990fa04cfc10328854391ad66beff4`.
The source, validity, constructor and SMC packet proofs are retained alongside
it. No firmware was executed and no sensor data was written during validation. The
label change passed both machines' full Debug gates: 660 tests per architecture,
universal builds, isolated AppKit checks and native/Rosetta packaged-entry
checks. Native probes verified 58 selected M5 labels and 84 selected M4 labels;
logs and snapshots are under ignored `dist/taol-als-source-name-validation/`.

## Resolved current M5 storage composite HID identity

The exact live provider is `AppleEmbeddedNVMeTemperatureSensor`, product
`NAND CH0 temp`, LocationID `TN0n`, below `AppleANS3CGv2Controller` on Mac17,4.
Native initialization stores that product literal; its `copyEvent` directly
calls `AppleEmbeddedNVMeController::GetTemperature` at `0xaef7878`.
That method directly calls `IONVMeController::GetSMARTData`, then reads the
sixteen-bit field at SMART offsets 1–2 and subtracts 273. `GetSMARTData`
constructs log page two with NUMD 127. This is the standard composite
Kelvin field, not a separately selected channel-zero temperature.

Combined with the current ANS health-log producer proof, the host HID is the
maximum-derived composite. Individual `SDN0`/`SDN3` equality is not claimed.
The Mac17,4 label is **Storage composite temperature**. The model guard also
requires `TN0n` for a qualified HID identity; unique products preserve their
legacy product-only identity. Other models, other qualified locations and
other NAND channels retain existing labels. The public Objective-C selector
`humanReadableHIDNameForKey:` remains unchanged; native hardware-model lookup
for that static entry point is cached.

Ignored `dist/storage-hid-composite-identity/verify_storage_composite.py`
checks all 485 retained native instructions against the original kernel,
including exact product bytes, constructor/vtable identity and direct call
chain. This proof uses the current 26C5035r kernel; it is not extrapolated to
Havana's uninspected 26B123 storage driver.

Validation retained under ignored `dist/storage-composite-name-validation/`
includes 660 passing native tests on M5, both 660-test architectures and the
full packaged checks on Havana, and the full 660-test M5 Rosetta retry plus
its packaged check. The initial M5 Rosetta suite timed out in an unrelated
AI log-scanning wait; the complete retry passed without changing tests or
thresholds. Native probes verified 58 selected M5 / 84 selected M4 SMC names
and the live storage HID on both machines, including the unchanged M4 label.
The original failure log and retry result bundle remain retained.

## Matching MSP responder and temperature hardware path

Read-only cached controller metadata reports MSP version `62.10.4.0.7.0`,
TLC 3D G8 / 4p / 1024 type, and a generic `nand-device-desc`. Native
IONVMeFamily code publishes that same descriptor and decodes its low five bits
through `kVendorStrings`; this machine selects Toshiba. Serial numbers, ECIDs
and unique hardware identifiers are excluded from retained metadata.

The installed matching candidate is
`/usr/standalone/firmware/t303/bfh_ofw.t303.ofw.toshiba_tlc_3d_g8_4p_1024gb.bin`,
SHA-256 `892998731a3e7fd229ee268185dbbc21e11e847836fc6a3354e0771f7af83d25`.
Its own native version is `AppleMSP-62.10.4.0.7.0`. Bounded 2 KiB frames carry
16-byte headers and explicit payload lengths/termination. Four grouped images
contain coherent original FWSG tables; the main image's own TEXT/DATA layout
provides a valid analysis carrier. The decoded main-image SHA-256 is
`854f0b6a1c12b5a83fec8954ab62b033eb92ecf6851a1f4713a52ade56fcca08`.
Frame checksums and the exact active file load are not independently verified;
matching installed vendor/type/version is kept distinct from active-byte proof.

The ANS pre-NAND dispatcher translates command `0x7a`, type zero into wire
opcode `0xa6`. The matching MSP image dispatches that opcode through table
`0xb6508` to handler `0x1ad64`. Its selected type-zero branch calls the local
temperature getter: a mapped peripheral initialized from logical address
`0x700c0000` supplies status and a 12-bit ADC field at offset `0x200`. The
getter applies a polynomial; the response rounds its result by sixteen into
the same Q2 Celsius word consumed by ANS. Type one follows a separate
NAND-side command and must not be substituted for the selected type zero.

This identifies a per-MSP calibrated ADC temperature provider for the two
logical storage channels. It does not establish the transducer's internal or
external placement, a NAND die, or a board position. Ignored `ans-current/`
retains `verify_nand_vendor.py`, `inspect_t303_responder.py` and
`verify_msp_temperature_responder.py`, native instruction proofs and original
FWSG metadata. Firmware was inspected statically and never executed.

## Configured host sensor packets and autonomous PMP routes

Current SMC code has three configured generic host packet readers. Fixed maps
join `zEAO` slot zero to input 99 / `TAOL`, `zETM` slots 18 and 27 to inputs
97/98 / `SDTo` and `SDTp`, and `zEPD` slot zero to input 100 / `SDDS`.
Packet headers validate count/version; they do not choose a destination.
Those paths therefore cannot supply `Tz197..205` or the omitted PMU inputs.
`zES0` and `zETD` remain outside this configured reader mechanism; their
writable flags do not identify a producer or consumer. Reproducers are
`inspect_zetm_consumer.py` and `inspect_configured_ze_readers.py` under ignored
`dist/tz-producer-validation/current-command-roles/`.

The current PMP investigation also found a real autonomous hardware packet
publisher. Native SoC-device allocation assigns ANE0 a range starting at
`0x220`; its hardware object's method programs the PTD destination low/high
words into the mapped peripheral described at logical `0x421970000`.
The programmed destination is PMP-relative `0x3803d1100`, with the runtime bus
base retained explicitly. The separate thermal consumer reads PMS-DEVC-PKT
slots `0x22a/0x22b`. Neither route alone identifies AON destination `0x152`.
The forwarding/address-translation edge remains separate from these proven
producer and consumer configurations. Ignored
`current-26C5035r/aon-routing/verify_autonomous_packet_configuration.py`
reproduces the exact selected allocation and hardware register programming.

## Official diagnostic catalogue cross-check

The public Apple diagnostic asset service returned model-specific images after
an HTTPS JSON POST to
`https://diagnostics.apple.com/api/v1/ast2-companion/public/services/assets`.
Requests used only generic `boardID`, `chipID` and `OSVersion` selectors:
M5 `{"boardID":38,"chipID":33090,"OSVersion":"27.3"}` and
M4 `{"boardID":2,"chipID":24640,"OSVersion":"27.2"}`. No serial number,
device ECID or diagnostic session was supplied. An initial GET returned 500;
the model-selector POSTs returned 200. Local DNS resolution failed, so the
requests used independently resolved public DNS records with HTTPS hostname
verification retained. Temporary signed download URL queries were removed
from retained response files after acquisition.

| Returned asset | SHA-256 |
| --- | --- |
| M5 `FieldServiceDiskImageCryptexFizz2_19f7f1ee.dmg` | `19f7f1ee777648deb407f82205b89b824682a111ea7e11004c31640fa1df1dc4` |
| M4 `FieldServiceDiskImageCryptexFizz1_5f9e44dc.dmg` | `5f9e44dc28c2de7417d1495b1c2764bcde49064b7243f3a95528e23b5715e299` |
| Shared `FieldServiceRepairDiskImageCryptexFizz1_e88b0a8c.dmg` | `e88b0a8cd71a2175c70305a6714ec23dfc68e6732f058720f3a5a4db28762712` |

The downloads match declared content lengths and server ETag MD5 values.
That is a transport/content check, not independent Apple signature validation.
Outer and inner disk images were extracted offline as regular files only,
excluding links. No diagnostic executable was run and no volume was mounted.

Native `/chosen` selectors choose the exact resource profiles:

| Host | Chip / board | Product profile | Explicit `TemperatureSensor` identifiers |
| --- | --- | --- | --- |
| `Mac17,4` / `J815` | `0x8142` / `0x26` | 5089 | `TB0T`, `TB1T`, `TB2T`, `TW0P`, `TH0x`, `Ts0P`, `Ts1P`, `TCMb` |
| `Mac16,11` / `J773s` | `0x6040` / `0x02` | 5076 | `TCMb`, `TW0P`, `TH0x` |

Every selected sensor description is its raw key. These catalogues provide
no physical names for the remaining AON, `TfC` or `Tz` inputs. Havana's
`arm-io,t6041` compatibility string must not substitute for its chosen chip ID
`0x6040`: that would incorrectly select profile 5081. Catalogue absence also
does not establish that an input is unavailable or reserved. The shared repair
image supplies no additional thermal mapping.

Ignored `dist/diagnostics-asset-discovery/` retains model requests, sanitized
responses, download hashes, regular-file extraction receipts, selected live
board identities and the passing `inspect_m5_catalogue.py` check of 2,625 files
and 69 profiles. The M4 and repair checks are under
`dist/havana-smc-artifact-discovery/apple-diagnostics/`, including
`inspect_m4_official_catalogue.py` and `inspect_repair_official.py`. The M4
asset contains 2,453 regular files / 59 profiles; the repair image has 832
regular files. The native ACSensor consumer reads `Devices.json`; its retained
Hopper dossier provides a separate check of the catalogue's input role.

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

## Further source-contract checks

The exact current AON consumer contract is now independently checked against
original SMC bytes. The selected `s0va`, `a0va`, `g0va`, `p0va` and `e0va`
objects request 2/3/8/6/3 hardware records and map 8/6/23/14/4 samples.
The provider reads sixteen-byte hardware records but packs only each low
64-bit word into an eight-byte output slot. A map selects one halfword and
converts its signed low fifteen bits directly by `/64`; bit 15 and the high
64-bit word are not assigned meanings by this proof. The selected group-one
path performs no averaging, maximum, filtering or unit offset. Stack bounds
and all map offsets are checked; unused packet lanes are not invented sensors.
All twenty current SMC descriptors match the current LLB and the corresponding
retained live metadata. This proves packet layout and numeric scale, not
physical ownership or Celsius independently. See
`dist/aon-consumer-contract/verify_aon_consumer.py`.

The current LLB's actual boot caller selects AV bank two. Its twenty-row
policy span contains `s0va` and `a0va`, but its separate hardware configuration
has an empty autonomous-publisher vector and count zero. Bank one has two
configured publishers at `0x388acc000` and `0x388adc000`. The generic hardware
programmer does write destination/configuration registers when records exist;
the selected AV bank skips that loop. The `ptdE` SMC exchange returns policy
spans, not the missing physical-source configuration. The matching second
iBoot stage preserves this selected empty vector. These facts close that
constructor family, not every hardware or runtime publisher. Reproducers are
`verify_llb_av_constructor.py`, `verify_ptde_exchange.py` and
`iboot-stage/verify_iboot_stage.py` under
`dist/havana-smc-artifact-discovery/current-26C5035r/aon-routing/`.

The current battery updater reads two separate wire commands: `0x6c` into
battery object offset `0x49`, and `0x6d` into offset `0x4b`. Native provider
and bus dispatch preserve these command bytes and copy each raw two-byte
response without normalization. Getter `0x9010` produces raw/10. This proves
the selected transport, not Celsius versus Kelvin or transducer placement;
neither an SBS `0x08` remap nor a sibling gas-gauge command contract may be
substituted. The exact live generic gauge identifies as bq40z651.
`dist/battery-temperature-contract/verify_battery_transport.py` independently
checks the selected current SMC instructions against original payload bytes.

The j773s configured writer closure now inventories all 33 common/simple and
eight weighted call sites across the full firmware TEXT extent and decodes
their actual destination maps. None samples group-one inputs 305–313 or
group-two inputs 32/50/68. The additional Tz pointer records belong to the
32-byte scalar-monitor table at `0x70268`, not the compact key trie. Records
at `0x71528 + 32*n` have monitor IDs 151–159 and four-byte sources; their
consumers update record-local accumulators, never the source floats. Selected
raw buffers are disjoint and native accessors expose scalar values, status or
indices. The F periodic average export still writes zero on an empty window.
This is a closure of the fixed supplied normal typed graph, excluding
arbitrary writes, patches, corruption and other configuration. It establishes
neither physical identity nor hardware availability. The original-image proof
and native implementation are retained in
`dist/m4-pmuf-source/configured-closure/verify_configured_closure.py`.

The current j815 counterpart independently inventories seventeen common-writer
edges, five convenience-wrapper calls and twenty-two outlined-wrapper calls,
then redecodes every selected map and direct destination. None samples inputs
114–116 (`TPDD/E/F`) or 197–205 (Tz). Weighted writers accept only groups two
and three. These twelve targets are group one, so the M4 empty-average zero
mechanism does not apply: their established default numeric origin is DATA
zero-fill initialization. Their initial metadata matches active inputs. Tz
records in the 121-entry monitor table at `0x89b60` carry diagnostic IDs
112–120 and only read their underlying values into local accumulators. No
actual runtime rebinding route was identified in this fixed normal typed
graph. A selected producer-to-input edge remains necessary before assigning
a physical identity; absence of that edge is not a hardware-absence claim.
See `dist/m5-unmapped-input-closure/verify_current_closure.py`.

The exact j815 restore DeviceTree (`6ad24d4b4ae70d48304e0ce6eb7c1936d26d4cb7a1133c7c3a8de8d7bb023694`)
decodes to 506 nodes. All 61 PMP properties and 36 additional scoped
PTD/MMIO/interrupt properties equal current live metadata. It supplies no
boot-only missing sensor mapping. Normal and RestoreDeviceTree manifest
digests have different IM4P type inputs (`dtre` versus `rdtr`); the proof
preserves the original container and accounts explicitly for this difference.
See `dist/sensor-devicetree-artifacts/verify_devicetree_evidence.py`.

Current ApplePTDUserClient initialization returns false and its external
method returns unsupported. The retained selector helper is therefore not
promoted into a usable packet API. `_ptdRead` only copies sixteen-byte
dashboard records; public twelve-byte registry entries contain identifiers,
versions, starts, sizes and interrupt/features metadata, not samples or units.
The alternate SMC read constructs `ptdR`, which is absent from the current
2,431-key trie. These are static findings, with no user client opened or
IOConnect method invoked. See
`dist/ptd-read-api-investigation/verify_ptd_read_contract.py`.

Official iStat Menus 7.50/build 2394 (archive filename 7.50.2) exact Mac17,4,
Mac16,11 and global recipes contain none of the unresolved target keys.
TG Pro 2.104's `setupSensorsForKeyFilePath:` simply reads a supplied UTF-8
file and splits its lines; Hopper evidence is
`ev_4ad757c0d8797fdf6e1a3fda4bbadd9022a9a20bf2790d6b6243c6da98920ff2`.
Its resources add no missing map. Pinned iSMC dump correlations do not satisfy
the firmware join requirement. No application was installed or executed, and
no decrypted full catalogue was retained. Acquisition hashes and target-only
proofs remain under `dist/sensor-reference-artifacts/`.

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
