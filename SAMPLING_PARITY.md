# Sampling and lifecycle parity

Source review: 2026-10-30. Implemented corrections cover Mac Battery elapsed-time
gating, monitoring timer delivery during AppKit event tracking, and collection and
buffer retention for hidden core/Battery graphs, and live GPU snapshot workers.
Linux comparison is read-only.
Actual system sleep/resume remains unverified.

| Area | macOS | Linux | Follow-up |
| --- | --- | --- | --- |
| Normal target | Main-run-loop timer; supported UI target 200 ms–10 s, legacy values retained | Wakeable worker timer; target 200 ms–10 s | Preserve valid legacy settings and collector baselines |
| Interval edit | Recreates the normal timer | Retimes from last sample start; identical intervals retain backoff | Choose and test a common phase policy |
| Menus and dragging | Window-managed normal/fast, slow and AI timers use common modes | System worker runs independently of UI event tracking | Real scheduled mode fixtures cover delivery; collector latency still needs hardware measurement |
| Slow collection | GPU/NPU use background collection; other collector-specific gates can still defer main-thread updates | Worker skips missed deadlines and backs off after overruns | Keep one completed observation per collection, no catch-up backlog |
| Battery gate | Now measures >10 real continuous-clock seconds after the last completed poll | Battery observes each normal worker sample | Cadence still differs intentionally in this pass; changing the target cannot manufacture elapsed time |
| Temperature gate | Five-second source gate, separate from faster graph redraws | Sensor observation on the normal worker | Compare freshness and source costs before changing cadence |
| Collapsed window | Displayed modules keep collection; geometry changes do not stop timers | Worker keeps collection | Preserve collapse/hover behavior |
| Hidden graph | CPU/Memory/Network/Disk normal sampling and elapsed-gated Battery polling continue hidden; other modules keep existing eligibility and AI remains separate | System sampler builds the system panels independently of UI visibility | Core collection aligned; audit optional hardware separately, preserving opt-in policy |
| AI | Separate nominal five-second cadence; visibility/tracking eligibility and suspend/cancellation paths | Separate controlled worker and provider/accounting preferences | Preserve cancellation, stale-publication and accounting-baseline contracts |
| System wake | Workspace notification sets a wake flag; CPU already uses a continuous clock; Battery now also uses one | System cadence uses Instant; no dedicated wake message in the inspected system timer | Audit per-collector rebase/freshness rather than assuming a wake flag handles every source |
| Global system pause | No all-collectors Pause/Resume gate in the inspected graph scheduler | Timer messages are Wake/Stop, with no global Pause state | Specify accounting, histories, pending operations and counter rebaseline behavior before adding a control |

Process SIGSTOP/SIGCONT actions and AI lifecycle controls are distinct from pausing
system monitoring. A collapsed window is also distinct from hidden graph selection.

## First implementation: Battery elapsed time

The old Mac Battery view advanced a synthetic counter by the configured graph
refresh duration on each callback. Repeated callbacks could poll too early; delayed
callbacks could leave readings stale. The gate now uses mach_continuous_time, as
already used for native CPU timing. Sleep advances this clock, so the next delivered
callback after a long gap can refresh once. Poll completion starts the next cooldown;
a slow source or a long gap cannot create a catch-up collection burst. The original
strict >10-second threshold remains, and invalid graph intervals still suppress
normal polling. Animation continues separately. Invalid clocks are ignored; a
backward clock is rebased conservatively without an immediate read.

Window/retention actions never touch the clock or collector. Battery charge/status,
current bars, raw counter policy, source identity limits and graph reset semantics
remain unchanged. Completion wall timestamps remain separate from cadence timing.

Rendering fixtures now inject ideally spaced clocks. A separate regression holds
time fixed across hundreds of callbacks and interval edits, checks the exact
threshold, simulated long gaps, invalid/backward clocks and slow-read completion
backoff. No real system sleep was triggered on the user's machine.

## Monitoring during event tracking

Window-managed timers now all register in common run-loop modes. Normal, fast and
five-/thirty-minute callbacks can continue while AppKit tracks menus/drags or runs
modal panels, matching AI's existing delivery policy. Refresh-interval replacement
uses the same registration path; weak ownership and shutdown invalidation remain.
The regression runs actual scheduled timers in default, event-tracking and modal
modes, forces their deadlines without manually firing them, checks delivery and AI
deduplication, replaces the graph timer, and verifies cleanup invalidates timers.
The original code fails the tracking/modal delivery and replacement assertions.

This is a scheduling correction, not a move to a background sampler. Native
collectors still run on the main actor; a slow collector can delay interaction.
Mode fixtures use injected sources, so they establish delivery but do not measure
physical sensor latency or end-to-end responsiveness while a real menu is open.

## Hidden core system graphs

Hiding CPU, Memory, Network, Disk or Battery affects presentation and fast mini-graph
updates; their normal-cadence callbacks continue through the existing module
always-update mechanism. Battery still reads only after >10 continuous-clock seconds
since the previous completed poll; visibility and re-show cannot bypass that gate.
Continuous core collection matches Linux and retains interval history, paging
deltas and session transfer accounting while the graphs are hidden. Battery
visibility is aligned; its native polling interval still differs from Linux.
Re-showing still requests the existing immediate refresh. Detaching a view removes
its module and stops manager-driven collection. Collapsing the window continues
collection as before. Registered core/Battery panels also preserve their last
width-based sample capacity when hidden layout assigns a zero-size frame, including
the immediate refresh before re-layout. Explicit retention counts still apply at
zero width. Meaningful visible widths retain existing resizing behavior. Layout
and accessibility still hide the view; collection is not a reason to expose it.

This is deliberately scoped to core system sources. GPU/NPU/VRAM, temperature,
fans, weather and stock sources keep their current native eligibility;
those policies still differ from Linux. AI retains its independent visibility,
tracking, cancellation and accounting rules. No global Pause/Resume control or new
persisted collection preference is introduced. Hidden native views still update
cached labels and request redraws through existing callbacks; separating collection
from presentation work remains an optimization task.

## Remaining optional-source visibility audit

| Source | Native behavior retained in this pass | Linux comparison / remaining work |
| --- | --- | --- |
| GPU / VRAM | Live GPU snapshots use a coalesced serial worker when GPU or VRAM is visible. Main-actor publication updates GPU history and visible VRAM once per accepted completion; VRAM uses the completion wall timestamp. | System sampler builds both panels each normal cycle; native both-hidden suppression remains intentional pending wider policy alignment. |
| NPU | Displayed normal callbacks request a coalesced serial worker. Construction requests an initial reading; hiding does not cancel an already queued read. | System worker samples NPU independently of panel visibility; define cancellation and rebaseline policy before aligning hidden collection. |
| Temperature / Fans | Temperature batches are five-second gated. Visible Fans uses the shared sensor service's separate fan reader/cache; this does not itself request a temperature batch. | System sampler requests sensor/fan reports each normal cycle. Align optional-source eligibility without broadening access or overriding source selections. |
| Weather / Stocks | Native views have visibility/window-dependent active guards and suspension/cancellation paths. | Audit provider enablement and publication lifecycle separately from local hardware histories. |
| AI | Independent timer and tracking/visibility eligibility; accounting and cancellation remain separate. | Keep provider/accounting controls and stale-publication protections. |

Hidden display is not proof of zero hardware I/O: initialization, shared consumers,
in-flight requests and independent inspector windows can still read a source.
No hardware-control writes or new permission/opt-in behavior are introduced here.

## Native callback latency baseline

`Tools/profile-macos-collectors.py` uses the opt-in module-manager diagnostic hook;
normal app dispatch reads no measurement clock. A private-domain standalone helper
measures normal main-actor callbacks, source calls and cached-label work, with setup
reported separately. It excludes drawing, real menu interaction, NPU async execution
and whole-app responsiveness. Cache/gated hits count as callbacks, not hardware reads.
See `Tools/CollectorProfile/README.md` for reproducible invocation and limitations.

Local Debug baseline, 2026-10-30: Mac17,4 on macOS 27.2, 60 cycles with 0.25-second
delay/target and GPU/sensor paths requested. Both runs use the same physical Apple
silicon machine; x86-64 is Rosetta, not physical Intel. Whole-cycle measurements
include diagnostic overhead. No known temperature channels were reported, so these
runs cannot establish fresh temperature-read latency or hardware coverage.

| Callback / cycle | ARM64 median / p95 / max ms | Rosetta x86-64 median / p95 / max ms |
| --- | --- | --- |
| GPU | 4.074 / 5.044 / 5.155 | 5.253 / 6.372 / 7.318 |
| Network | 1.396 / 1.646 / 2.164 | 1.719 / 2.142 / 2.228 |
| CPU | 1.033 / 1.586 / 1.842 | 1.901 / 2.882 / 3.134 |
| Disk | 1.009 / 1.343 / 1.491 | 1.494 / 2.065 / 2.919 |
| Complete normal cycle | 8.617 / 10.291 / 10.911 | 12.660 / 14.683 / 15.259 |

GPU is the largest measured callback here. This measures the combined callback,
not isolated IOKit duration or a general performance guarantee. That baseline identified GPU snapshot collection as the first worker candidate;
preserve shared GPU/VRAM deduplication,
source identities, failure gaps and completion timestamps. Coalesce work rather
than queueing missed ticks, reject results invalidated by lifecycle/reset changes,
and prove UI delivery stays available with a deliberately stalled fixture reader.
Keep histories/publication on the main actor and append once per completed read.

## GPU snapshot worker

Live GPU construction and polling now enqueue a read-only snapshot on a serial
utility queue. Parsed value snapshots are Sendable; histories, labels and current
values publish on the main actor. Existing injected synchronous sources retain
their fixture/API behavior. A single in-flight request coalesces redraws and graph
ticks without accumulating a queue or automatically replaying missed ticks.

A completion carries its worker-captured wall timestamp and revision. A replaced
GPU view cannot forward its late completion into the window’s new VRAM consumer. Visible
VRAM consumes each accepted revision once; pending/cached callbacks do not invent
observations. GPU and VRAM share the same read. Hiding GPU while VRAM is visible
keeps collection eligible; hiding both, detaching GPU or shutting down invalidates
pending publication. Resuming waits for a fresh read. GPU or VRAM graph reset also
invalidates an older in-flight read. Kernel I/O already running is not interrupted;
its result is discarded. Failure and source-identity policies remain unchanged.
No new permissions, hardware writes or hidden collection policy are introduced.

Deterministic blocked-reader tests verify a real main-run-loop timer still fires,
request coalescing, completion timestamps, failure handling, one VRAM observation
per completion, reset/suspend/resume, both visibility combinations, replacement ownership and
detachment.
The profiling helper now pumps the run loop between cycles and reports GPU completed
read count/pending state. GPU publication occurs outside measured normal callbacks;
a short enqueue is not a measurement of worker execution or total UI cost.

The final worker profiles use the same Debug helper shape, 60 cycles and 0.25-second
delay/target. ARM64 GPU callback median/p95/max was 0.183/0.337/0.379 ms; the measured
normal cycle was 5.224/6.520/6.709 ms. Rosetta GPU callback was
0.447/0.749/0.916 ms; the normal cycle was 7.995/9.666/10.389 ms. Both accepted 61
reads, reported valid GPU counters and ended with no read pending. These callbacks
exclude worker execution and completion publication, unlike the earlier synchronous
callback's combined cost; this is not a total UI/CPU improvement measurement.
Reported GPU entries were one on ARM64 and two under Rosetta (the baseline reported
one); environmental/device membership was not controlled. No known temperature
channels were reported. No physical Intel, release-build, macOS 26 runtime or
real-menu responsiveness claim follows from these local profiles.

## Next work

1. Compare the worker profile with the baseline, then measure real interaction,
   completion-publication cost and unavailable sensor paths separately. Select
   additional synchronous collectors using measured cost and lifecycle contracts.
2. Audit remaining optional-source visibility policies; specify any explicit
   Pause/Resume control, separating display freeze from stopping accounting.
3. Audit wake/long-gap handling and interval-edit phase behavior for counter-based
   sources, with source-specific rebaselines and preserved transfer/accounting totals.

Evidence paths: XRGCore/XRGGraphWindow.swift (`timer`, `initTimers`, wake handling),
XRGCore/XRGModuleManager.swift (`graphUpdate`, `fastUpdate`),
XRGCore/XRGBatteryView.swift (`prepare`, `graphUpdate`),
XRGCore/XRGTemperatureState.swift (`shouldUpdate`),
XRGCore/XRGGPUView.swift (`memoryReadings`),
XRGCore/XRGNPUMiner.swift (`XRGNPUWorker`, `getLatestNPUInfo`),
XRGCore/XRGTemperatureMiner.swift (`fanValues`, `fanGraphReadings`),
XRGCore/XRGAITokenView.swift (`graphUpdate`, `suspendCollection`),
xrg-linux/rust/src/sampling.rs (`Schedule`, `Control`, `Timer`),
xrg-linux/rust/src/engine.rs (`Sampler::sample`, worker loop).
