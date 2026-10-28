# macOS NPU telemetry

XRG-ng targets macOS 26+. Private APIs are intentional and optional. The monitor
does not require elevated privileges, modified system security settings, an
inference model or an ANE device user client.

## Meaning of the readings

- **Active time (%)**: `SoC Stats` / `Cluster Power States`, State-format ANE
  channels, `ACT` residency divided by total residency. The busiest cluster is
  reported; cluster percentages cannot be summed. The graph uses a fixed 100%
  ceiling. This measures software power-state residency, not compute occupancy.
- **Busy / Idle**: positive / zero ACT residency in a valid, nonempty interval.
  A missing, frozen or unrecognized residency sample never becomes “Idle”.
- **Watts**: recognized ANE energy delta divided by elapsed monotonic time.
- **Pwr↑ / n/a%**: residency is unavailable, but energy increased. Activity is
  inferred from energy; no capacity percentage is manufactured from watts.
- **Pwr / n/a%** with zero watts: no energy increase reported, utilization unknown.
- **Last detected activity**: end of the most recent positive residency interval,
  or energy interval when residency is unavailable, with the evidence source.
  It is an observation time, not the exact start/end of an inference request.

The private IOReport library is dynamically loaded. The state path uses
`IOReportCopyChannelsInGroup`, `IOReportCreateSubscription`,
`IOReportCreateSamples`, `IOReportCreateSamplesDelta`,
`IOReportChannelGetFormat`, `IOReportStateGetCount`,
`IOReportStateGetNameForIndex` and `IOReportStateGetResidency`.
Raw states are checked for identity changes, resets and overflow before the
library reduces the interval. Empty denominators, stale samples, duplicates,
unknown names and overlapping intervals are unavailable, not zero activity.

## Investigation and current limits (2026-10-27)

Apple's shipped `/usr/bin/powermetrics` was examined with **Ghidra 12.1** using
an owned arm64e slice. Its `ane_power.c` paths subscribe to SoC performance and
cluster-power states, print `ANE … SW active residency`, and explicitly mark
`hw_resid_counters` false. This supports the software-residency wording above.
The independent [SiliconScope implementation](https://github.com/kennss/SiliconScope/blob/main/Sources/SiliconScopeCore/ANESampler.swift)
also reads ANE ACT cluster residency. XRG's implementation is independently
written, validates inputs strictly and does not block between snapshots.

Exports and runtime method metadata were also inspected for
`AppleNeuralEngine.framework`, `ANEServices.framework` and
`ANEClientSignals.framework`. `_ANEPerformanceStats` exposes hardware execution
times and compute/stall counters associated with an inference **request** and
its performance buffers. The inspected interfaces did not establish an
unprivileged global compute-occupancy counter for arbitrary applications.
`ANEClientSignals` exports signal-sending functions; sending a scheduler hint
is not evidence that a model executed. These interfaces are not used to invent
a system-wide utilization number.

On the available **Apple M5 / macOS 27.2 (26B118)**, all discoverable IOReport
channels were enumerated. ANE energy was subscribable, but no ANE cluster-power
or performance-state residency channel was advertised. `AMC Stats` advertised
ANE byte counters but refused subscription. `PMP` exposed coarse ANE bandwidth
histograms, including a nonzero lowest bucket; those are not compute-occupancy
counters and are not relabeled as utilization.

A synthetic Vision OCR loop and Apple's
[MobileNetV2 FP16 sample model](https://developer.apple.com/machine-learning/models/)
were exercised locally. The latter completed 32,101 predictions in a 20-second
loop configured with `.cpuAndNeuralEngine` after warmup. ANE energy remained
unchanged. Allowing the Neural Engine does not prove Core ML placed the model
there, and these results do not validate under-load ANE telemetry on this M5.
The UI therefore leaves the direct percentage unavailable on this machine.
Active-residency math, independent power failures, idle/busy transitions,
timestamps and compact labels are covered with deterministic fixtures.

Physical testing of every chip and macOS version is not possible for this
project. Support remains best effort; feedback and channel dumps from macOS 26+
machines are welcome, especially paired idle / known ANE workload observations.

## Read-only channel diagnostic

From the repository root:

```sh
swiftc -parse-as-library XRGCore/XRGNPUReader.swift \
  XRGCore/XRGNPUActivityReader.swift Tools/npu-telemetry-macos.swift \
  -o /tmp/xrg-npu-telemetry
/tmp/xrg-npu-telemetry 10
```

The command emits one JSON record per second, including raw ANE energy counters,
watts and active percentage (JSON `null` means unavailable). It accepts 2–120
samples and does not load a model, inspect other processes or alter settings.
Report the chip, macOS version and what workload ran; a Core ML configuration
alone is insufficient proof of ANE placement. Do not treat a zero counter as
proof that a workload ran elsewhere.
