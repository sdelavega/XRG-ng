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
- **Traffic / No bus**: positive / absent ANE fabric bandwidth-bin reports in a
  valid interval. A narrow secondary-color band plots their rate with an observed
  scale. These are sampling reports, not bytes, inferences or compute occupancy;
  the band never becomes a capacity percentage. Background traffic can appear.
- **Last detected activity**: end of a positive residency interval, observed
  fabric-traffic interval, or an energy interval when the other signals are
  unavailable, with the evidence source.
  It is an observation time, not the exact start/end of an inference request.

The traffic path subscribes only to **PMP/PMP0/PMP1 → SOC-NI Util BW**, State-format
`SOC-NI<digits> ANE UP` channels with `events` units and numeric `GB/s` bucket labels.
It uses one provider group, validates unique identities and monotonic counters,
and applies IOReport's sample delta before counting positive-bandwidth buckets.
Zero-bin residency is excluded if supplied. Unknown layouts, resets and stale
samples are unavailable. Absence of reports is not proof of idle: internal work,
sampling gaps or firmware behavior can hide traffic.

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

## M4 Pro comparison and observed ANE execution

A second physical machine, **Mac mini M4 Pro (14 CPU / 20 GPU cores)**, was checked
over SSH on the same macOS **27.2 / 26B118** build. It exposes a 16-core `h16g` ANE
endpoint with firmware loaded; the M5 exposes `h17`. The M5 registry entry advertises
an Exclave proxy; the M4 Pro entry does not. This observation alone does not establish
the implementation of either entire stack.

The M4 Pro's `powermetrics` SHA-256 is
`caf6482dd136d2117541587d1df8f18857706dba3dd81c22c176b3e80fd774b3`, identical to the
local artifact already analyzed with Ghidra. Its dedicated ANE residency channel
is also absent. The tempting `SoC Stats / Cluster Power States / PACC1_ANE` entry
reports `INACT` / `ACT` and stayed at 100% ACT before, during and after the tests,
including CPU-only inference. It is not accepted as a dedicated ANE utilization
counter. The collector also rejects `ANEXL` and generic DCS bandwidth histograms;
those can retain a nonzero floor after warmup.

To separate planned placement from observed dispatch, an owned test executable
loaded Apple's public MobileNetV2 FP16 sample with either `.cpuOnly` or
`.cpuAndNeuralEngine`, mutated its image buffer between predictions, warmed up,
then ran for 12 seconds. A process-local Objective-C observer wrapped only its
own `_ANEClient` `evaluateWithModel:options:request:qos:error:` and
`doEvaluateDirectWithModel:options:request:qos:error:` calls, forwarding arguments
and return values unchanged. No other application was injected or modified.

| Machine / configuration | Predictions | Successful evaluate calls | Successful direct calls |
| --- | ---: | ---: | ---: |
| M4 Pro, CPU only | 1,782 | 0 | 0 |
| M4 Pro, CPU + ANE allowed | 22,112 | 22,112 | 22,112 |
| M5, CPU + ANE allowed | 19,665 | 19,665 | 19,665 |

The evaluate and direct wrappers are nested: the columns must **not** be summed
as inference counts. Core ML's plan placed 170 layers on CPU in the CPU-only run;
with ANE allowed it preferred ANE for 100 layers and returned no mapping for 70.
[Compute plans describe placement and estimated cost](https://developer.apple.com/documentation/coreml/mlcomputeplan-85vdw?language=objc),
not runtime load. The observer establishes successful dispatch through Apple's
ANE client path; it is not a system-wide hardware occupancy measurement.
Request performance statistics did not expose positive hardware timing with these
default options. Privileged `powermetrics` was not run because noninteractive
sudo required a password; these findings do not establish what privileged tracing
could reveal.

ANE energy stayed unchanged during those runs. In contrast, `SOC-NI4 ANE UP` on
the M4 Pro and `SOC-NI3 ANE UP` on the M5 responded strongly during the ANE workloads.
The CPU-only M4 Pro control produced no positive ANE-UP bucket reports. Small
background counts can remain before/after ANE work, so the band retains rate
information rather than treating any report as full utilization. An IOReport
update count and separate firmware clock were readable, but no defensible
denominator for turning these histograms into compute-utilization percent was
established. XRG-ng does not normalize them to an observed peak as a percentage.

The actual production reader was then sampled 22 times on each machine around
another controlled ANE run. Both emitted positive traffic intervals while watts
remained zero and the direct active percentage remained unavailable. This validates
the traffic fallback on those two configurations. It does not validate all chips,
macOS 26 behavior, per-process attribution or arithmetic-unit occupancy. Fixture
tests cover strict channel selection, zero bins, malformed/overflowing counters,
source replacement, overlapping intervals and the separate marker presentation.

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
watts, active percentage, traffic presence, positive-bin report count and traffic
interval length (JSON `null` means unavailable). It accepts 2–120
samples and does not load a model, inspect other processes or alter settings.
Report the chip, macOS version and what workload ran; a Core ML configuration
alone is insufficient proof of ANE placement. Do not treat a zero counter as
proof that a workload ran elsewhere.
