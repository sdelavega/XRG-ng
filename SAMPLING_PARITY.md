# Sampling and lifecycle parity

Source review: 2026-10-30. This pass changes the Mac Battery elapsed-time gate;
Linux comparison is read-only. Actual system sleep/resume remains unverified.

| Area | macOS | Linux | Follow-up |
| --- | --- | --- | --- |
| Normal target | Main-run-loop timer; supported UI target 200 ms–10 s, legacy values retained | Wakeable worker timer; target 200 ms–10 s | Preserve valid legacy settings and collector baselines |
| Interval edit | Recreates the normal timer | Retimes from last sample start; identical intervals retain backoff | Choose and test a common phase policy |
| Menus and dragging | Normal/fast timers use default run-loop mode; AI uses common modes | System worker runs independently of UI event tracking | Align supported collection behavior without introducing UI stalls |
| Slow collection | Collector-specific gates; main thread can defer normal updates | Worker skips missed deadlines and backs off after overruns | Keep one completed observation per collection, no catch-up backlog |
| Battery gate | Now measures >10 real continuous-clock seconds after the last completed poll | Battery observes each normal worker sample | Cadence still differs intentionally in this pass; changing the target cannot manufacture elapsed time |
| Temperature gate | Five-second source gate, separate from faster graph redraws | Sensor observation on the normal worker | Compare freshness and source costs before changing cadence |
| Collapsed window | Displayed modules keep collection; geometry changes do not stop timers | Worker keeps collection | Preserve collapse/hover behavior |
| Hidden graph | Module manager normally excludes hidden modules, with always-update exceptions and separate AI eligibility | System sampler builds the system panels independently of UI visibility | Define whether hidden system histories should continue, respecting opt-in hardware policy |
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

## Next work

1. Test normal collection during event tracking, then address the default/common
   run-loop difference while measuring UI responsiveness of native collectors.
2. Define hidden-system-graph collection and any explicit Pause/Resume policy;
   distinguish display freezing from stopping collection/accounting.
3. Audit wake/long-gap handling and interval-edit phase behavior for counter-based
   sources, with source-specific rebaselines and preserved transfer/accounting totals.

Evidence paths: XRGCore/XRGGraphWindow.swift (`timer`, `initTimers`, wake handling),
XRGCore/XRGModuleManager.swift (`graphUpdate`, `fastUpdate`),
XRGCore/XRGBatteryView.swift (`prepare`, `graphUpdate`),
XRGCore/XRGTemperatureState.swift (`shouldUpdate`),
XRGCore/XRGAITokenView.swift (`graphUpdate`, `suspendCollection`),
xrg-linux/rust/src/sampling.rs (`Schedule`, `Control`, `Timer`),
xrg-linux/rust/src/engine.rs (`Sampler::sample`, worker loop).
