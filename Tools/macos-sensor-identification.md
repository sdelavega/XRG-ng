# Sensor identification investigation

Checked 2026-11-04 on a MacBook Air (15-inch, M5), macOS 27.3 / 26C5035r.

## Implemented result

Use branch-specific system descriptions when available, with the driver's exact
`RBr ` value selecting the branch. Retain the original sensor key in the label
and as the persisted identity. Reject unreadable/malformed metadata and ambiguous
matches. Never use a different model's description to fill a missing branch.

The runtime parser reads only its own process's mapped `libSMC` data using
`mach_vm_read_overwrite`. It resolves one named exported data symbol; it does not
search memory for replacement tables, dereference unvalidated pointers, open a
new device client or execute an Apple diagnostic. The table walk is capped at
256 records, individual tables at 10,000 entries, and reads at 2,720,000 bytes.
The older exported ABI has 48-byte branch records and 272-byte description
records; a different layout disables this optional source. Rejected metadata
never suppresses otherwise valid sensor readings.

Universal physical-position guesses were removed. Runtime catalogue observations
show `Tm0P` means charger proximity on `m87`, and `TG0H` means northbridge
proximity there. Calling them mainboard and GPU heatsink on every model is
incorrect. Apple Silicon CPU/GPU families also do not apply to Intel by default.

## Observations and limits

- The local inventory from the preceding pass contained 170 SMC/HID channel names.
- `AccumulatorPlatformStructLookupArray` is exported by the installed
  `/usr/lib/libSMC.dylib` in the dyld shared cache. A bounded read observed 56
  branch records, from `m87` through `J92`, followed by a non-record boundary.
  There is no `J815` M5 branch. This catalogue does not identify the remaining M5
  channels. Its descriptions are read at runtime, not copied into this project.
- IORegistry's PMP `temp-sensor` table has 25 56-byte records on this host. Its
  `soc-device` table pairs device 6 with `ANE0`, device 4 with `PACC0`, device 3
  with `EACC0`, and device 5 with `AGX`. Some temperature records carry labels such
  as `Ta000i`, `Tp000i` and `Te007i`. These are six-character names, while XRG's
  SMC keys have four characters. No verified transformation or explicit alias to
  `Ta00`, `Ta04`, `Ts00` or `Tz11` was established. Do not strip suffixes or
  manufacture an alias from their shared prefix.
- Driver HID products and LocationID values give explicit names for PMU,
  storage and battery services. Multiple battery services share one product
  string. The follow-up now disambiguates those products with validated LocationIDs;
  see [the naming and selection rules](macos-sensor-names.md).
- Published catalogues disagree about `TPD*`, `TRDX`, `TPMP`, `TPSP` and `TDBP`.
  Neither an M2 temperature-correlation experiment nor a model-independent
  catalogue establishes those physical assignments on M5. They remain unresolved.

## Binary evidence

Hopper was used through REA, with static analysis only. Neither executable was
launched. Complete local evidence snapshots are retained under
`dist/sensor-identification-validation/` (ignored validation artifacts).

| Artifact | SHA-256 | Relevant evidence |
| --- | --- | --- |
| `/usr/libexec/smcDiagnose` | `4a9407619f8ed0dc2401b538e92010f7cb1b847d90b198a3fc93f023d268e180` | `ev_fe31118d264bed875387750216ef5ca822498ce11478a465ce8be908ea8e17cc`, `ev_c0befefa997af0a2ccf640a7399c9220846bfabb196c0089cafb11f04c249f95`: inspected key-data methods and diagnostic strings; no model-specific description table established by those bounded searches. |
| `/usr/libexec/thermalmonitord` | `dc2202ac7092044a9d59c037784a97d2dce21cc01f382f302d2748dc66609ef3` | `ev_3fb5d1b46d47e3d37ede887667f775df023d3a4c31060ddff6deaff966eb6cac`: `-[HidSensors loadProductTemperatureParameters:]` reads `4CharCode`, `matchName` and synthesized/shadow sensor metadata from a configuration array. `ev_893e9f83e471cc2c65b860551ff15863797d26aa31cd492db8a1c9f1527f9706`: startup chooses embedded product configurations. Neither observation proves aliases for the unresolved M5 keys. |

Static pseudocode is not original source or evidence of runtime execution. A
local independent decoder inspected selected embedded thermal configurations;
they did not establish the missing compact-key descriptions.

## Primary references

- [VirtualSMC description-table inspection](https://github.com/acidanthera/VirtualSMC/blob/master/Tools/smcread/smcread.c#L499-L560)
  documents the exported library table's old layout. Its unbounded memory-search
  fallback is not used by XRG.
- [iSMC catalogue](https://github.com/dkorunic/iSMC/blob/master/smc/sensors.go)
  and [MacMonitor M2 research](https://github.com/ryyansafar/MacMonitor/blob/main/SENSORS.md)
  supply conflicting hypotheses, not verified M5 mappings.
- [Stats sensor definitions](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)
  distinguish chip generations; their core numbering is not generalized here.

To resolve the remaining channels, obtain a model-specific explicit description
or a verified firmware/driver key transformation. Controlled temperature
correlation can guide that investigation but cannot by itself identify a sensor's
physical location or justify changing its metric meaning.

## Follow-up: exact-board firmware and HID identities

The local restore kernel cache was decoded with the system LZFSE decoder. Owned
standalone copies of its AppleSMC and ApplePMP fileset entries preserve VM
addresses and segment bytes, with relocated Mach-O file offsets. Kernel-collection
chained fixups were not materialized; indirect/static-reference coverage is
therefore incomplete. No driver was loaded or altered.

Hopper's AppleSMC `_createSensor` observation
`ev_f3bba0fe6ceca9897c18b8781f089b686a4b573234842a6f2b81f133d1366c84`
shows that PMU products are constructed from source keys and that gas-gauge
sources share the text `gas gauge battery`. Live IORegistry independently pairs
that product with six distinct LocationIDs: `TG0B`, `TG0C`, `TG0H`, `TG0V`, `TG1B`
and `TG2B`. The preceding last-write-wins dictionary lost five of those channels.
The new implementation uses those driver identities without borrowing any
firmware code or assigning unverified physical positions to the IDs.

The exact-board `t8142pmp.im4p` payload is an uncompressed Mach-O inside IMG4.
Its SHA-256 is `58d790f2a5e0d8a12acff79ca37934e63f2fb71492d896bbacd39fde495405c4`.
Hopper evidence `ev_50a0b6ca9f67e6fccd8bd4325f2530097b8df436af544fd357c64b1a20307dc2`
shows its `temp-sensor` consumer reading 56-byte records, copying their long
labels and resolving their device IDs against 124-byte `soc-device` records.
That path did not establish a translation to the compact SMC keys. The live PMP
report legend likewise did not supply an explicit thermal-label bridge.

The local board's iBoot payload was decoded and checked for embedded LZFSE SMC
firmware; no such stream or `AppleSMCFirmware` marker was found in that payload.
This is a bounded negative result, not proof that the machine has no SMC firmware.
The device tree names its SMC firmware `t8142smc`. A subsequent first-stage LLB
investigation recovered board-specific j815 and j773s SMC images from Apple's
26B123 restore archive, validated their page containers, and decoded the j815
key trie. See [the firmware checkpoint](macos-smc-firmware-investigation.md) for
the reusable inspector, provenance, input-buffer links and remaining provider
boundary. These structural links have not yet established physical labels.

Extraction scripts, source/derived hashes, scoped report-channel metadata and
REA snapshots are retained under `dist/sensor-firmware-validation/`. No Apple
binary or catalogue is committed to the repository.
