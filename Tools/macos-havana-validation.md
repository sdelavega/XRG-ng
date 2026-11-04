# Havana M4 Pro validation

Validated 2026-11-04 over SSH as `sdelavega@Havana`, using an isolated temporary
source copy. The existing checkout and installed app were not used for testing.

| Host | Hardware | macOS | Xcode |
| --- | --- | --- | --- |
| Havana | Mac mini M4 Pro, `Mac16,11` | 27.2 / `26B123` | 27.2 / `27B48` |
| Local comparison | MacBook Air M5 | 27.3 / `26C5035r` | 27.3 |

## Battery correction

Havana publishes an `AppleSmartBattery` power source with `BatteryInstalled=false`,
zero normalized capacities, external power connected and charging false. Counting
that service as a battery produced “On Hold” with unavailable capacity fields.

Commit `48cc92e` excludes explicitly absent batteries from the miner's sample.
Records without an installation flag retain legacy behavior, and installed
batteries at zero charge remain valid. The regression reproduced four failed
expectations before the fix, including contamination of a mixed battery sample.

The actual corrected reader reports zero batteries on Havana, and the panel
shows “No Battery Found”. The local M5 still reports one installed battery with
a valid raw pair: 5,357 mAh current and maximum in the final check. Havana's
desktop hardware cannot validate real laptop capacity measurements.

A follow-up checks read failure and recovery using a real sample from each
machine, with an injected failure in a separate miner. The M5 transitions from
its charged 5,357 mAh reading to “Battery unavailable” and back. Havana transitions
from “No Battery Found” to “Battery unavailable” and back. Failed polls retire
the current status and insert gaps in both power histories; cached capacities
remain available to compatibility accessors. Recovery with the same nonzero
installed-battery count retains the history and gap. This is fault injection,
not an induced physical battery or IOKit failure.

An observed installed-battery count change now clears both power histories;
the sample-count history previously retained the old group's values and peaks
after the time-window history had cleared them. An absent battery group leaves
missing history, while an installed battery reporting zero watts retains a real
zero sample. Count changes are tested with fixtures, not physical battery removal,
and do not identify a replacement that leaves the count unchanged.

## Sensor inventory and presentation

The final live M4 Pro sample contained 270 raw SMC temperature entries and 173
valid sensor rows. All 173 appeared in the normal picker, including the HID
storage channel and `Fan 1 · F0Ac`. There were 101 generic “Temperature sensor”
labels; their physical locations remain unidentified.

The native Sensors nib fitted its longest name (260.96 points) into a 265-point
name column. Its final window width was 458 points. The copied report retained
friendly names and raw IDs. Counts and temperatures are observations from one
sample, not fixed inventories or idle-temperature claims.

## Controlled NPU comparison

The read-only production diagnostic ran alongside an owned Core ML test process
using Apple's [MobileNetV2 FP16 model](https://ml-assets.apple.com/coreml/models/Image/ImageClassification/MobileNetV2/MobileNetV2FP16.mlmodel).
The downloaded model's SHA-256 was
`c76832208ff4c936365f0f2609f7b77f7f1a6caf62b0b429056d5ad7e48635ad`.
Each configuration warmed up before a marked 12-second workload, with a changing
image buffer and separate pre/post observations.

Only the test process's own `_ANEClient` methods were wrapped. Their argument
and return types were checked before forwarding unchanged calls. Successful
`evaluateWithModel:options:request:qos:error:` and
`doEvaluateDirectWithModel:options:request:qos:error:` returns were counted.
These nested counters must not be summed.

| Configuration | Predictions | Successful evaluate calls | Successful direct calls | Fully contained traffic intervals |
| --- | ---: | ---: | ---: | --- |
| CPU only | 1,894 | 0 | 0 | 11 quiet, zero positive-bin reports |
| CPU and ANE allowed | 19,767 | 19,767 | 19,767 | 11 positive, 4,233–4,431 reports each |

Both configurations left direct active percentage unavailable and reported zero
watts in every contained interval. This validates responsive traffic fallback
and a CPU-only control on this build. It establishes successful ANE dispatch,
not system-wide hardware occupancy or a conversion of reports to utilization.

## Gates and retained evidence

`bash Tools/ci-macos.sh Debug` passed on both hosts after the battery correction:
643 tests per architecture, universal app checks, AppKit restoration, and native
and Rosetta packaged app smoke checks. The isolated private preferences were
removed by successful probes; no installed-app preferences were used.

Local ignored artifacts are under `dist/havana-m4-pro-validation/`: host metadata,
probe sources, source/record hashes, sensor inventory and report, inspected native
UI images, workload phase markers, telemetry records, and separate local/remote
gate logs and summaries. The remote gate's result bundles and smoke artifacts
were also copied locally.

Failure/recovery probes, inspected images and both hosts' gate results from the
follow-up are under `dist/battery-availability-validation/`.
The count-boundary regression, current-host probes and both hosts' latest gate
results are under `dist/battery-count-history-validation/`.

Physical sleep/wake, macOS 26, other chips and direct NPU compute utilization
remain outside this validation. See [NPU telemetry semantics](macos-npu-telemetry.md)
and [sensor identification limits](macos-sensor-identification.md).
