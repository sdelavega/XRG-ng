# macOS modernization review — October 2026

## Baseline

XRG is a mixed Swift 6/Objective-C AppKit application with ARC, a separate C/GTK Linux port, and no external Swift package dependencies. The active macOS scheme builds successfully with no issues reported by Xcode. This is compilation evidence, not a runtime or cross-hardware certification.

The checkout's origin is `marc-shade/XRG`; upstream is `mikepj/XRG`. Existing uncommitted changes already update IOKit calls, file panels, signing, bundle identity, versioning, and build settings. These changes were preserved. Objective-C/AppKit remains a viable foundation; a SwiftUI rewrite is a separate product decision.

## Changes in this review

- Theme opening now returns failure immediately for unreadable/empty data and invalid plist roots, avoiding duplicate alerts and false success in those cases.
- The Preferences theme loader checks that the plist root is a dictionary before subscripting it.
- The minimized-window regression tool resolves the preferences domain and executable from the app under test instead of assuming the upstream bundle identifier. Invalid bundles are rejected before preferences are changed.
- Build documentation reflects the current deployment-target setting and explains compilation without a signing identity.
- All three theme import paths now share validation in `XRGSettings`. All seven colors and transparency values are decoded and checked before settings or defaults change. Invalid imports report failure; valid legacy archives remain supported, and saved preference archives use secure coding.
- Appearance panel refreshes reuse the existing Graph Style control instead of adding duplicates and repeatedly enlarging the panel.
- Added a macOS-only `XRGTests` target using Swift Testing. Fifteen cases cover secure and legacy color archives, corrupt and wrong-class archives, missing fields, invalid numeric values, transparency boundaries, unknown keys, and preservation of settings/defaults on failure. All pass on the active Mac destination; the app also builds with no reported warnings.
- Added repository-owned `XRG` and `XRGTests` shared schemes; both include the test bundle. GitHub Actions now has a Debug/Release matrix using Xcode 26.3 on `macos-26`, universal app compilation, isolated tests, read-only repository permissions, pinned action revisions, and retained diagnostics. `Tools/ci-macos.sh` provides the same checks locally and rejects empty test runs.

## Swift migration

The app, core framework, and tests now explicitly require macOS 26.0. Universal builds retain `arm64` and `x86_64`; raising the OS floor does not remove Intel support. CI runs on macOS 26 and checks both executable slices and the bundle's minimum OS.

The app delegate is now Swift 6 with main-actor isolation, preserving the existing AppKit nibs, Objective-C runtime name, outlets, actions, and minimized-window restoration. `XRGSettings`, theme validation, `XRGDataSet`, and `XRGStatsManager` now live in a static Swift 6 `XRGCore` framework shared by the app and tests. Compatibility headers bridge the remaining Objective-C consumers; the original implementations were removed. The ring buffer owns its storage in Swift, uses Accelerate for vector operations, and maintains statistics after reset, resize, and negative division. Statistics updates are locked and readers receive snapshots; the first sample is no longer counted twice. Eleven additional tests bring the suite to 26 cases.

This is an incremental port. Graph/window/preferences controllers, graph rendering, miners, and networking still contain Objective-C. Continue migrating the remaining provider parsers and direct network consumers, then controllers and rendering, and finally hardware access with Intel and Apple silicon validation. The current AppKit interface remains in place. A SwiftUI redesign is a separate decision.

Rust has not been introduced: these migrated components use Apple frameworks directly, and Swift provides owned storage and concurrency checking without an additional FFI/build/distribution layer. Reconsider Rust only for a measured parsing or computation bottleneck that benefits from an isolated portable core.

### Networking and Codex parser follow-up

`XRGURL` is now a Swift 6 adapter using async URLSession requests. Existing weather/update consumers keep their polling interface. State is lock-protected, cancellation and URL replacement invalidate older completions, HTTP failures report errors, and invalid/non-HTTP URLs fail before a request starts. Unused blocking, mutable-buffer, user-agent, and cache-mode APIs were removed after checking repository callers; active requests retain their original ignore-cache policy and 60-second timeout.

Codex JSONL decoding now uses a typed Swift parser called by the existing background scanner. It retains the last cumulative total instead of summing repeated events, rejects invalid numeric types and overflow, handles partial final records and CRLF, and streams with an 8 MiB per-line memory limit. Oversized lines are skipped, and scanning resumes at the next newline. Seventeen new cases bring the suite to 43; fixtures are synthetic and tests do not read personal logs or contact live providers. Stock networking and the legacy custom Claude SQLite reader were migrated in the subsequent stage below.

### Claude and Gemini parser follow-up

Claude and Gemini decoding and token aggregation now run in Swift, with small Objective-C adapters preserving the existing model-price calculations and background scan scheduling. Claude retains input, cache-creation, cache-read, and output accounting. Gemini retains JSONL message models, legacy JSON session-level models, explicit totals, and input-plus-output fallback when a total is zero or missing. Invalid numeric fields and overflowing records are rejected before either totals or cost callbacks change. Missing files consistently return zero totals and costs.

A shared reader bounds Claude/Gemini JSONL lines to 8 MiB and reads in 64 KiB chunks; legacy Gemini JSON documents still load as a whole. Twelve additional synthetic fixture cases bring the suite to 55. This migration preserves the existing repeated-message behavior and pricing estimates; it does not claim to correct duplicate Claude events or cached-token pricing. Those accounting policy changes require separate fixtures and review.

### Hermes and local-provider follow-up

Hermes SQLite access now lives in Swift and publishes an immutable snapshot only after a complete successful query. Connections are read-only and fail promptly on locks; the adapter retains its last sample on failure. The old `immutable=1` URI option was removed because a live Hermes database can change: [SQLite documents that immutable connections skip locking and change detection](https://www.sqlite.org/uri.html). Fixtures verify uncheckpointed WAL reads while the writer remains open, model aggregation, actual-cost precedence (including zero), estimated-cost fallback, missing/locked databases, and SQL overflow. Hermes costs remain provider-reported rather than re-priced.

Ollama and OTel now use the Swift async URLSession helper with a two-second request timeout and three-second resource timeout. The Objective-C adapter polls completed results; it no longer waits on a network semaphore. Ollama retains its five-second request cadence and publishes available/running model arrays through typed Swift decoding. OTel fallback is polled when no file source is selected, and pending requests no longer immediately drop the active strategy. A Swift Prometheus parser correctly reads the value before an optional timestamp, including labels containing whitespace, and rejects nonfinite/negative/overflowing values. The existing broad metric-name matching and downstream cost-estimation policy remain unchanged.

Thirteen additional fixture cases bring the suite to 68. These tests use temporary databases and synthetic responses, not personal Hermes data or live endpoints. Scanner scheduling was migrated in the later stage below; the broader miner remains Objective-C.

### Stock model and legacy Claude database follow-up

`XRGStock` now lives in Swift 6. History and quote requests run concurrently with async URLSession, validate HTTP status and typed JSON responses, and publish once both complete. Locked state and request generations prevent a previous symbol or reset request from overwriting new data. URLComponents encodes symbols as single path segments. Main-queue update notifications and the existing graph polling methods remain available through the compatibility header. Unused public mutation/URL/52-week-price properties were removed after checking repository callers.

Valid quotes display without requiring history, zero changes display as unchanged, and sub-dollar prices no longer become unavailable because of integer truncation. When the quote fails, the most recent pair of closing prices supplies the display fallback. Partial data remains usable; a completed refresh with no usable data reports failure. The Yahoo endpoints are unchanged and have not been tested against the live service.

The legacy custom Claude `sessions(tokens_used, estimated_cost)` database reader now uses Swift with read-only connections. Missing databases are not created, empty aggregates become zero, and lock/schema/overflow failures preserve the caller's previous sample. Fourteen additional fixtures bring the suite to 82. The remaining major migration areas are the AI miner's scan/cache/rate orchestration, hardware miners, and AppKit controllers/rendering.

### Scan scheduling, caching, and rates

Claude, Codex, and Gemini now share a Swift scan-cache implementation with separate provider instances. Each uses a monotonic 30-second start cadence and permits one active scan per generation. Swift tasks own directory enumeration and parsing; the Objective-C miner polls immutable completed snapshots. Reset cancels work, clears caches, and invalidates old publications. The former Objective-C directory loops, modification-date dictionaries, scheduling timestamps, and serial parsing queue were removed.

Cache entries track modification date, size, and inode. Unchanged files reuse parsed totals, deleted files are removed from the aggregate, and files that change while being parsed are retried on the next scan. Enumeration/read/aggregate failures retain the previous complete snapshot; missing provider roots produce an empty snapshot. Metadata comparisons are not content hashes, and the existing parsers still represent some malformed/unreadable input as zero usage. Pricing policies remain in the existing adapters.

Swift rate tracking establishes a baseline from the first completed provider sample, rebases decreased counters, divides positive deltas by monotonic elapsed time, and clamps UInt32 display rates instead of wrapping. Gemini budget events use safe integer deltas independently of rounded graph rates. Cost rates similarly reject invalid/decreasing totals. Because file providers still refresh every 30 seconds, newly observed usage remains batched; these are observation-time rates, not reconstructed per-event timestamps.

Eleven additional fixture cases bring the suite to 93, covering all layouts, reuse, size-only changes, deletions, missing providers, scan failures, changing files, overlapping refreshes, reset cancellation, overflow, elapsed-time normalization, and counter rebasing. Hardware miners and AppKit controllers/rendering remain the next substantial migration areas; the AI miner still contains its Objective-C façade, pricing policy, and graph publication code.

######## Integrated runtime validation

Launched the app with Xcode's debugger on the current Apple silicon Mac. Live inspection found 10 CPU cores, one Apple GPU with memory/utilization readings, active network traffic, 964 process entries, one charged battery, and 154 discovered temperature keys. CPU, memory, and network menus constructed successfully (17, 15, and 26 items). AppKit-rendered window captures confirmed the graph output. Computer Use inspection stalled; debugger-based view rendering was used instead, so physical menu interaction was not verified.

This run exposed missing AppleRaw battery capacity fields on the current machine. The battery miner now falls back to normalized CurrentCapacity/MaxCapacity for charge percentage while showing unavailable raw mAh values as n/a. A second launch visibly confirmed 100% Charged with n/a capacity. One regression test brings the suite to 131. Debug and Release universal builds were repeated after this fix. Local Ollama connection refusals appeared in the console; that service is external to the miner validation.

Intel hardware, battery transitions, hot-plugged GPUs/network interfaces, and full UI interaction remain unverified. Existing dense text overlaps in weather/AI panels were visible and remain a separate layout task. After relaunch, 154 temperature keys were still discovered but the graph showed Select Sensors in Prefs: the automatically selected sensor was not restored. The auto-configuration code marks completion in defaults while setting sensor locations only on the in-memory settings object. Sensor-selection persistence needs a focused follow-up; saved selections were not manually changed during this validation.

## Temperature state and sensor boundary

Temperature/fan models, history ownership, value validation, ordering, decoding, and refresh scheduling now live in Swift `XRGTemperatureState`. The Objective-C miner is reduced to a small adapter for the existing SMC/HID readers, name lookup, known-key filtering, and fan caching. The low-level APSL SMC implementation and private Apple HID entry points remain Objective-C; this stage does not claim a complete sensor transport port.

Temperature refresh uses five seconds of monotonic elapsed time rather than five callbacks, with immediate refresh when unknown-sensor visibility changes. Missing readings are disabled and append zero as before. Nonfinite values are rejected, and fan Data values require exactly one Float before an unaligned read. Fan list and graph decoding now share the same logic, including valid zero RPM. CPU counting uses ProcessInfo instead of allocating Mach processor buffers. The Apple silicon adapter checks client creation, releases the client when service enumeration fails, and validates sensor names.

Five new tests bring the suite to 130, covering cadence, preference changes, temperature limits, missing/recovered readings, fan buffer bounds, ordering, resizing, and reset. Debug and Release universal builds retain both architectures and macOS 26.0. Hardware sensor discovery, fan readings, and private HID availability still require Intel and Apple silicon runtime validation; fixture tests do not establish those behaviors.

## GPU miner

`XRGGPUMiner` now lives in Swift with main-actor publication and Swift-owned histories keyed by accelerator registry ID. Reordering preserves the correct history, removal drops the removed GPU, and replacement starts fresh. IOKit iterators, services, and ancestor references are released on every exit path. PCI metadata is read from the accelerator's actual PCI ancestor instead of pairing unrelated enumeration results. Apple silicon accelerators continue to work without a PCI device.

The parser retains the existing VRAM, system-memory, and GART field families, validates numeric values, preserves legitimate zero readings, and tracks missing memory/utilization explicitly. The mini graph avoids division by zero and reports unavailable memory; a valid zero utilization reading no longer selects CPU-wait mode. Failed registry snapshots retain the previous complete sample. The driver-specific statistics remain best-effort: system-memory allocation on Apple silicon is not a physical VRAM capacity measurement.

Seven new cases bring the suite to 125, covering memory derivation/fallbacks, vendor decoding, missing/invalid values, zero utilization, stable histories, replacement/removal, failed reads, and a live registry scan. Universal Debug and Release builds retain macOS 26.0 and both architectures. Physical multi-GPU/eGPU transitions and Intel runtime behavior still need manual validation. The temperature miner and its low-level sensor adapters remain to migrate.

## Network miner

`XRGNetMiner` now uses Swift-owned interface snapshots and 64-bit `NET_RT_IFLIST2` counters. Routing messages are bounds-checked before reading headers, and buffer sizing retries handle interface churn. Active, non-loopback interfaces are enumerated afresh; vanished interfaces no longer retain stale deltas. New or replaced interfaces establish a baseline, decreased counters rebase independently per direction, and monotonic elapsed time determines bytes per second. Failed reads retain the last successful sample and timestamp.

The graph/menu API is preserved, with immutable interface objects replacing the raw C statistics pointer. The legacy PPP daemon socket query and synthetic ppp0 entry are removed; active PPP interfaces use kernel counters. “All” still sums eligible interfaces, so VPN and underlying physical traffic can both be counted. Since-boot totals now reflect currently selected active kernel counters; they can decrease when an interface disappears or resets. Since-load totals accumulate observed deltas without a one-sample lag and restart when selection changes. Reset Graph clears history and rebases the next rate sample while retaining the session total.

Eight new tests bring the suite to 118, including a live kernel read, 64-bit values, selection, interface churn, counter resets, failures, invalid intervals, saturation, and malformed routing messages. Debug and Release universal builds verify both architectures and the macOS 26 minimum. VPN/PPP transitions and Intel runtime behavior remain hardware validation tasks. GPU and temperature miners remain to migrate.

## Process and battery miners

`XRGProcessMiner` and `XRGBatteryMiner` now live in the Swift core. Process sampling runs off the main actor, coalesces overlapping requests, and publishes complete snapshots on the main actor. The existing `ps` CPU averaging and KiB memory units are preserved. Each live miner refreshes initially, every five seconds, and on menu requests; menus show the last completed snapshot. Failed subprocess reads retain that snapshot. Process memory values are UInt64, and both menus safely handle fewer than ten results.

Battery sampling releases both IOKit services and their iterator, preserves the last complete sample on read failures, distinguishes an unavailable initial reading from no battery, normalizes unknown time estimates, clamps percentages, and saturates integer totals. Existing IOPMPowerSource sensor keys and first-battery status policy are preserved; their availability still depends on hardware.

Seven new tests bring the suite to 110, covering process parsing, sorting, disappearance, failed reads, a live process scan, battery state transitions, units, unknown values, and overflow. Debug and Release universal builds retain macOS 26.0 as the minimum. Physical battery transitions, Intel runtime behavior, and rendered menus still need manual verification. Network, GPU, and temperature miners remain to migrate.

## CPU and memory miners

`XRGCPUMiner` and `XRGMemoryMiner` now live in the Swift core with main-actor isolation matching the AppKit timer callbacks. The CPU miner owns tick snapshots and history arrays in Swift, initializes independent fast/graph baselines, handles UInt32 tick rollover and processor-count changes, and releases Mach allocations using their returned integer-element count. CPU views consume immutable NSNumber arrays instead of a borrowed raw fast-values pointer. The old unused pointer-based sampling API was removed.

The memory miner uses `host_statistics64` and UInt64 counters, preserves the last successful sample on failures, and rebases initial/reset/decreasing counters. Page-count conversion uses the host page size. Its graph view now uses that size for page-fault text and consistent byte units for the swap bar. Existing free/active/inactive/wired categories are preserved; this stage does not redesign the graph around memory pressure or compressed memory.

Ten new cases bring the suite to 103. Fixtures cover tick rollover, core-count changes, independent baselines, resets/failures, 64-bit counters, swap failures, and 4/16 KiB pages. Live CPU and VM readers also passed on the current Mac. Universal Debug/Release compilation verifies both architecture slices; Intel hardware and complete rendered UI behavior remain unverified. Remaining hardware work includes process, battery, network, GPU, and temperature miners.

## Priorities for the next implementation stages

| Priority | Finding | Work needed |
| --- | --- | --- |
| High | The update check and release link still point to `marc-shade/XRG`, while this checkout uses a different bundle ID. | Decide whether to follow that fork's releases or publish an independent release feed. Do not advertise another build as an update accidentally. |
| High | `NSAllowsArbitraryLoads` disables ATS broadly. Local Ollama and OTel HTTP endpoints are configurable. | Define supported local/LAN endpoints, then narrow exceptions and verify those endpoints alongside HTTPS stock/weather/update requests. |
| High | Theme validation now has isolated automated tests and CI configuration; AI aggregation and UI flows still lack coverage. | Add parsing/aggregation fixtures and XCUIAutomation for launch, preferences, theme import, and minimized-window restore. |
| Medium | App launch activates the Dock and reactivates XRG as a workaround for a macOS 10.15 issue. | Reproduce menu activation on supported OS versions before removing the workaround. |
| Medium | AI usage documentation describes provider-wide pricing as accurate. | Distinguish estimates from provider-reported spend and test model-specific rates, cache accounting, log rotation, and duplicate events. |
| Medium | SMC/IOHID sensor access relies on hardware-specific behavior. | Check Intel and multiple Apple Silicon generations, including unavailable sensors and permission failures. |
| Medium | Custom graph views, nib preferences, and bundled help predate the current UI. | Audit VoiceOver, keyboard navigation, contrast, resizing, and current screenshots before a visual redesign. |

## Verification limits

Local verification compiled both Debug and Release universal app builds and passed all 707 test cases through command-line Xcode testing after the preferences-controller migration (390 test functions, with parameterized cases expanded). Earlier command-line test-runner permission errors did not recur in this run. The complete CI script has not been rerun end to end here. The workflow has not yet run on GitHub, and the pinned CI toolchain differs from local Xcode 27.2. XML, YAML, shell syntax, and the result-summary guard were checked locally. These checks do not establish notarization readiness, network service availability, or UI behavior. The window regression tool terminates XRG and temporarily changes its preferences; it was not run against the user's live app as part of this review. Linux was not changed or validated.

### Temperature-selection persistence follow-up

Auto-configuration now writes all selected keys before marking setup complete. Empty discovery retries later, existing named selections remain intact even when their sensors are unavailable, and explicit None choices are saved as empty strings instead of falling back to registered numeric placeholders. The exact legacy 0/1/2 placeholder trio is eligible for repair even with the old completion flag set.

Two isolated-defaults tests bring the suite to 133. A real Xcode launch saved TCHP; after stopping and relaunching, both persisted and active selections remained TCHP and resolved to CPU Proximity. Universal Debug/Release builds pass with macOS 26.0 minimum. The app was left running.

### Weather and AI text layout

Weather now opts into separate measured label/value columns with a gap. Both columns keep logical lines on individual rows and truncate long content. AI text reserves a 30-point strip for its provider legend, whose boxes and letters now sit at the right edge. The shared helper is opt-in, limiting the change to these panels.

Built and launched through Xcode; an AppKit-rendered capture at the current window size verified separated weather text and an unobstructed AI legend with ellipsized long status lines. Universal Debug/Release builds pass. Existing 133 core tests were not rerun for this drawing-only change. Other window sizes and fonts still need broader UI coverage.

### AI token miner Swift migration

The remaining XRGAITokenMiner implementation is now Swift with main-actor ownership of strategy selection, polling state, counters, costs, rates, and graph histories. Swift scan caches still perform background log traversal and parsing. The Objective-C budget observer receives Gemini deltas through a callback installed by the graph view. The obsolete C pricing helpers, duplicate cost calculations, semaphore, and raw-pointer parsing wrappers were removed.

Existing Claude/Gemini model-price matching and Codex 70/30 fallback estimates are preserved as compatibility policy, not represented as current provider prices or billed cost. Cache tokens continue to follow that historical policy. SQLite/OTel-reported costs, including zero, are now retained instead of being overwritten by estimated Claude pricing. OTel readiness requires a completed sample, and strategy transitions rebase rates. Aggregate rates saturate instead of wrapping; reset cancels pending requests and invalidates scan generations.

Four additional tests bring the suite to 137, covering strategy priority, source-reported costs, rate saturation/reset, compatibility pricing with UInt64 extremes, and asynchronous OTel readiness. Live Xcode inspection confirmed the Swift miner populated Claude, Codex, Gemini, and Hermes totals and Ollama status. Universal Debug/Release builds pass for macOS 26 on both architectures. The budget observer and graph view remain Objective-C; Rust is not needed for this stage. Pricing accuracy and provider-schema evolution remain separate follow-up work.

### AI budget observer Swift migration

XRGAITokensObserver now lives in the Swift core. A single lock protects event updates, resets, getters, aggregation, and persistence, replacing the serial queue plus unprotected getters. Existing defaults keys, reset notifications, threshold notification name/payload, and Objective-C selectors are retained. Budget notifications are delivered on the main queue outside the lock. Counters saturate at UInt64.max, and malformed or negative saved values are rejected. Daily rollover now also occurs when daily totals are read, so idle panels do not keep showing yesterday's totals when auto-reset is enabled. Session counters remain independent.

Five isolated-defaults tests bring the suite to 142, covering concurrent events, persistence/reopening, reset notifications, rollover, disabled tracking/auto-reset, invalid saved values, overflow, and threshold notification deduplication. Xcode launch succeeded with the Swift observer; universal Debug and Release builds retain macOS 26.0 and both architecture slices. The graph view remains Objective-C. Tests use a private NotificationCenter and do not send real budget alerts or alter the user's budget settings.

### Graph label resizing and accessibility validation

Shared graph text now clamps collapsed layout rectangles to nonnegative dimensions, guards invalid line heights, and uses empty attributed strings instead of nil in mini mode. The existing noninteractive text-field subclass exposes the complete source reading through accessibilityValue, independently of visual line clipping and truncation. Empty columns are excluded from accessibility; populated columns use the static-text role.

Runtime label checks passed all 36 combinations of 10/18/28-point fonts, 0/80/140/320-point widths, and 0/20/140-point heights. All ten graph panels also passed a negative-size text-rectangle check with their full accessibility reading retained. These exercises call the shared layout helpers; they are not an end-to-end window-resizing test. The original 10-point font was restored, and a normal-size AppKit render was inspected. No preferences were saved by the checks.

Scoped VoiceOver source/runtime-property audit: PASS for retaining full readings in the shared graph labels. This is not a whole-app VoiceOver certification: navigation order, graph context-menu access, preferences, and spoken output still require interactive validation. Full window resizing and large-font visual collision coverage remain follow-up work. Existing 142 core tests were not rerun for this AppKit-only change.

Xcode build/launch and universal Debug/Release builds passed. Both binaries retain arm64 and x86_64 slices and macOS 26.0 minimum. The app was left running.

### Module registration, timer dispatch, and layout Swift migration

`XRGModule` and `XRGModuleManager` now live in the Swift 6 core with main-actor isolation. Compatibility headers preserve the existing Objective-C class names and selectors. The existing graph views and window implement small Swift-defined protocols, so the manager can operate without depending on the Objective-C application target. The manager holds its window weakly and returns array snapshots. Existing module-size preference keys, display order, immediate refresh on showing a graph, hidden-module graph updates, and minimized-window sizing are retained. The original Objective-C implementations were removed from the project.

Registration replaces modules by name without duplicates, preserves registration order for tied display orders, and derives visibility and timer eligibility from the current module state. Timer recipients are captured before callbacks, so a callback can change registration safely. Layout handles an empty display list without dividing by zero and clamps collapsed graph dimensions to zero. Invalid saved dimensions fall back to the existing default sizes. Divider dragging preserves the combined size of adjacent modules, clamps to each minimum, and returns the applied movement. Horizontal divider hit areas now include every preceding separator.

Eleven new isolated-defaults cases bring the suite to 153 passing cases. They cover persistence, invalid dimensions, replacement and ordering, timer eligibility, callback mutation, both layout orientations, multi-divider positions, hidden/empty/collapsed layouts, font changes, minimized sizing, drag bounds, and weak window ownership. Debug and Release universal app builds pass with arm64 and x86_64 slices and a macOS 26.0 minimum. The compiler reports an existing network-miner String conversion deprecation and an App Intents metadata notice; this migration adds no compiler warnings. These are automated AppKit/core checks and compilation evidence; full live-window interaction and Intel runtime behavior remain unverified in this stage. The graph/window/preferences controllers, graph rendering, and low-level SMC/HID sensor boundary remain Objective-C.

### Sensor window controller Swift migration

`XRGSensorViewController` and its `XRGFlippedView` document view now live in the Swift core. Their Objective-C runtime names, nib outlets, Copy action, three sensor columns, temperature-unit conversions, and raw diagnostic export format are preserved. A small data-source protocol supplies settings and readings from the existing temperature miner through the app delegate. The original Objective-C implementations were removed from the project.

The controller refreshes immediately when shown, replaces an existing timer before scheduling another, and invalidates its timer when hidden. Timer callbacks hold the controller weakly and stop if it disappears. Unnamed readings fall back to their sensor key; unavailable current readings and missing statistics show n/a instead of stale or synthetic zero values. Fan readings retain RPM when temperatures use Fahrenheit. The statistics-column width is a lower bound so it can coexist with the nib's header-width constraint. The temperature-units enum now explicitly conforms to Sendable.

Eight new isolated cases bring the suite to 161 passing cases (125 tests including parameterized cases). They cover Celsius/Fahrenheit conversion, RPM, missing statistics, unavailable readings, preference changes, timer replacement/shutdown/ownership, and diagnostic export using a private pasteboard. The actual Sensors.xib is also compiled into the test bundle and instantiated to verify its Swift classes, outlets, Copy target/action, flipped document view, and width constraint. An independent AppKit render of the compiled app nib with synthetic readings confirmed the three columns at the original window size. The user's clipboard and live XRG process were not used for these checks.

The Debug link exposed a static-framework archive issue: a Swift class referenced only by a nib can be omitted from the executable. Both app configurations now link with -ObjC, and the CI script checks for the app delegate, sensor controller, and flipped view runtime classes in each architecture slice. That check passed for the Debug and Release binaries. Both universal builds retain arm64, x86_64, and the macOS 26.0 minimum. No new compiler warnings remain. Full interactive sensor-window use and cross-hardware readings remain unverified in this stage; the main graph/preferences controllers, rendering, and SMC/HID boundary remain Objective-C.

### Temperature miner orchestration Swift migration

`XRGTemperatureMiner` now lives in the main-actor Swift core alongside the existing temperature state. It owns the singleton, SMC/HID sample sequencing, name lookup, known-key filtering, fan cache, graph histories, reset/resize forwarding, and fan classification. Compatibility headers retain the graph-facing Objective-C selectors. The view's one direct SMCSensors dependency now uses the miner's knownTemperatureKeyCount property. Nil fan selections remain valid and return false/zero, matching the prior Objective-C behavior.

`XRGTemperatureHardwareReader` is the small remaining Objective-C exception boundary. SMC construction, temperature/fan reads, HID reads, and metadata queries catch exceptions before returning to Swift. A failed SMC initialization therefore does not prevent HID readings. The low-level APSL SMC code and private HID entry points remain Objective-C. Runtime factory discovery keeps those implementations out of the Swift core; the architecture checks now require both the Swift miner and its reader class in the app executable.

Seven Swift fixture cases and three Objective-C exception tests bring the full Debug suite to 171 passing cases. They cover five-second sampling, preference changes, monotonic fan-cache expiry and rollback, missing/recovered readings, names and ordering, history resize/reset, malformed/duplicate fan data, absent readers, and nil selections. The exception tests link synthetic transports only into the test process, exercise the production reader, and verify calls from Swift without allowing an Objective-C exception to unwind through it. All ten new cases also pass in an optimized Release test run. Release testing exposed disabled @testable access in the prior CI command; test invocations now set ENABLE_TESTABILITY=YES while the app-build invocation keeps its existing settings.

Debug and Release universal app builds pass, retain arm64 and x86_64, and preserve the macOS 26.0 minimum. Runtime-class checks pass in both slices of both builds. A separate probe using the real SMC/HID objects and bundled sensor-name resource discovered 154 enabled sensor keys, nine known SMC temperature keys, and zero fans on the current Apple silicon Mac. Live factory discovery, history allocation/reset, and nil selections passed without loading the app or modifying its settings. Physical fan transitions, Intel behavior, and complete interactive graph/window flows remain unverified. The main graph/preferences controllers and graph rendering remain the next migration areas.

### Shared graph renderer and label layout Swift migration

Shared graph paths, filled/line plots, mini bars, scanlines, grids, retro dots, pixel plots, and glow lines now use Swift XRGGraphRenderer. XRGGraphLabels owns the shared labels, row clipping, mini-mode text, measured columns, and full accessibility readings. XRGNonInteractableTextField and XRGCommon (damping and legacy byte formatting) are also Swift, with compatibility headers retaining their Objective-C APIs. The graph panels still inherit from the Objective-C XRGGenericView; its protected state, nib lifecycle, subclass hooks, and drawing selectors remain as a forwarding layer. Panel-specific rendering and controllers remain to migrate.

Data-set drawing consumes Swift-owned ordered samples directly, removing the renderer's stack allocations. The compatibility raw-buffer entry points copy into owned arrays and normalize ring indexes. Empty or entirely missing line plots now return without indexing before the point buffer; nonfinite readings and invalid ranges/rectangles are rejected. Mini bars handle empty input and clamp to their plot width, while pixel-dot glows are clipped to their plot. Invalid grid spacing and excessive overlay geometry cannot produce unbounded loops. Text frames remain nonnegative, fallback line heights handle invalid settings, full source readings remain accessible when visual text is clipped, and repeated nib setup does not duplicate labels. The existing graphics-context antialiasing policy is preserved by the Objective-C forwarding layer.

Fifty-seven new cases bring the full Debug suite to 228 passing cases (153 tests including parameterized cases). Tests cover independent expected geometry, bitmap rendering, raw/data-set parity, missing/nonfinite readings, reversed/flat ranges, index normalization, mini-bar bounds/series colors, graphics-state restoration, glow alpha, clipping, byte-format boundaries, and damping. Thirty-six font/size cases verify complete accessibility values and safe frames. Objective-C integration tests exercise the actual forwarding base, its selectors, and label lifecycle.

A before/after bitmap probe matched the sampled filled graph, flipped line graph, grid, scanlines, and neon line pixel-for-pixel. It exposed a Swift rectangle-fill compositing difference, which was corrected and covered by an alpha test. Pixel-dot images differ only where the new clipping removes glow outside the plot. AppKit-rendered label columns were inspected at 10-, 18-, and 28-point fonts, including long labels and clipped rows. These synthetic captures and property checks do not establish whole-app interaction or spoken VoiceOver behavior.

Debug and Release universal app builds pass, both architecture slices retain the required runtime classes, and the minimum OS remains macOS 26.0. All 57 new cases passed with Release optimization. The user's running app, settings, and clipboard were not changed by this stage. Remaining Objective-C work includes the graph/window/preferences controllers, individual graph panels, and the low-level SMC/HID transport boundary.

### GPU graph panel Swift migration

XRGGPUView is now a main-actor Swift NSView in the core, using the Swift renderer and label helpers directly. Its Objective-C runtime name, graph module name/order, visibility and size preference keys, timer callbacks, first-click behavior, and mouse forwarding remain available to the existing window and nib. The Objective-C implementation was removed. XRGGraphWindow implements a small hosting protocol; its other graph panels still use the legacy base class.

GPU registration is idempotent, and detaching a panel clears the host reference and removes only that panel's module by identity. The panel holds its module and host weakly. Removing an already-replaced module is a no-op. Full mode gives each GPU its own label group and plot band, fixing the old loop that overwrote every card's text with the last GPU's values. Removal clears the old vendor/usage labels. Mini mode keeps the combined memory summary and per-card bars. Missing memory shows n/a independently of valid utilization (including zero); CPU-wait formatting retains its units and truncation without narrowing large values to Int32. History sizing remains bounded, and drawing uses the current view bounds.

Eleven GPU-panel cases and one module-removal case bring the full Debug suite to 240 passing cases (165 tests including parameterized cases). Coverage includes registration, visibility, font sizing, detachment, replacement identity, narrow/full/mini readings, missing memory, zero utilization, CPU-wait units, multi-GPU bands, removal, failed polls, history bounds, mouse forwarding, and native bitmap rendering. The GPU view also instantiates from a compiled current-format xib fragment and from the repository's actual legacy keyed archive. Tools/extract_gpu_nib_fixture.py reproduces the legacy fixture while removing the unrelated window/menu/connection graph; the archived GPU payload is preserved apart from its detached parent/responder links.

Both universal app builds retain arm64, x86_64, the required GPU runtime class, and a macOS 26.0 minimum. The GPU cases pass with Release optimization. An AppKit preview was inspected for a synthetic two-GPU panel, combined mini mode, and a view decoded from the legacy archive using a live GPU reading. The probe used no module manager or window timers, and did not change the running app, its preferences, or the clipboard. Physical multi-GPU hot-plug, Intel runtime behavior, and complete interactive window/menu flows remain unverified. The main window/preferences controllers and remaining individual graph panels are the next migration areas.

### Memory graph panel Swift migration

XRGMemoryView is now a main-actor Swift NSView using the Swift renderer and label helpers directly. Its runtime name, Memory module name/order, size and visibility keys, paging toggle, category labels, binary-unit formatting, graph reset, preferences action, and mouse forwarding remain available to the existing window. The Objective-C implementation was removed. The window implements a small hosting protocol and forwards the preferences action to the existing RAM panel route. Registration is idempotent, host/module references are weak, and detachment removes only the panel's own module.

The paging stack now uses one maximum for all three existing layers instead of rescaling each layer independently. An all-zero history draws no paging fill. RAM and swap bars use bounded rectangles, avoid UInt64 overflow when summing category totals, clamp inconsistent swap readings, and handle collapsed mini views without negative bar heights. Full text reserves the existing 19-point status strip. The existing free/active/inactive/wired model and shared RAM/swap mini scale are retained. Fault-rate text uses the miner's page size and the configured refresh interval; invalid intervals show n/a, and zero refresh retains the existing omitted-row behavior.

The context menu retains the top-ten memory process list, KiB-based process units and thresholds, reset, and preferences entries. Its actions now target the panel explicitly, so dispatch does not depend on the current first responder. Process refresh remains asynchronous and the menu uses the last completed snapshot, handles fewer than ten results, and caps longer lists at ten. Large counters and process sizes are formatted without narrowing them to Int32; Reset Graph requests an immediate redraw.

Fourteen new cases bring the full Debug suite to 254 passing cases (177 tests including parameterized cases). They cover registration/visibility/detachment, font sizing, complete accessibility readings, preference flags, 4/16 KiB fault-rate units, shared paging scale, bar geometry, extreme counters, zero swap, history bounds, failed reads, reset, process menus and action routing, native bitmaps, mouse forwarding, and decoding both current-format and legacy memory nib fixtures. The legacy extractor is shared with the GPU fixture; the original GPU command remains as a wrapper and reproduces identical bytes. All 14 new cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required memory runtime class, and macOS 26.0 minimum. An AppKit capture was inspected for a synthetic paging stack/status strips, mini mode, and a legacy-archive memory view using a live VM reading. The probe did not install a module manager or graph timers, open preferences, alter the running app, or use the clipboard. Complete interactive window/menu flows and Intel runtime behavior remain unverified. Remaining work includes the main window/preferences controllers and the other individual graph panels.

### Network graph panel Swift migration

XRGNetView is now a main-actor Swift NSView using the Swift graph renderer and labels directly. Its Objective-C runtime name, Network module name/order, visibility and size preferences, normal and fast timer selectors, interface selection, and mouse forwarding remain available to the existing window and nib. The Objective-C implementation was removed. The window implements a small hosting protocol and forwards preferences to the existing Network panel route. Registration is idempotent, host/module references are weak, and detaching an older panel preserves its replacement.

The three graph modes preserve the stacked-total/Tx overlay and the two opposing Rx/Tx directions, their series colors, scale floor, full/mini labels, and configured cumulative totals. Full-size Rx/Tx readings now use accessible text fields instead of immediate string drawing. Strict visual row capacity is preserved while the complete configured reading remains available to accessibility. Graph scales and histories are bounded, and large UInt64 counters no longer narrow through NSInteger before formatting. Compact smoothing retains fractional values. Full mode skips fast polls; returning to compact mode clears and rebases the fast sampler so stale counters cannot become a new compact-mode rate. Reset clears both histories and smoothing while preserving the miner's session byte total.

Context-menu entries use the last completed interface snapshot, retain binary MiB units, and explicitly target the panel. Network Settings opens through NSWorkspace instead of spawning a process, and Network Utility is offered only when the workspace finds it installed. Tests inject these launch operations and never open external applications. The kernel interface-name conversion also uses bounded UTF-8 decoding, removing its deprecated array-to-C-string conversion.

Eighteen new cases bring the full Debug suite to 272 passing cases (190 tests including parameterized cases). They cover registration/visibility/detachment/replacement, font sizing, all graph modes and rate positions, cumulative flags and clipped accessibility text, compact ordering and fractional smoothing, full/mini transitions, interface selection, reset and failed reads, wide counters, menu targets and actions, bounded geometry/history, native bitmaps, mouse forwarding, and native decoding of both current-format and legacy network nib fixtures. The shared extractor reproduces the legacy fixture byte-for-byte. All 18 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required network runtime class in each slice, and macOS 26.0 minimum. An AppKit capture was inspected for three synthetic full graph modes, compact mode, and a legacy-archive panel using a live kernel interface snapshot. This probe used no module manager or graph timers and did not modify the running app, user settings, or clipboard. Complete interactive window/menu flows, VPN/PPP transitions, and Intel runtime behavior remain unverified. Remaining work includes the main window/preferences controllers, other individual graph panels, and the low-level SMC/HID transport boundary.

### Battery graph panel Swift migration

XRGBatteryView is now a main-actor Swift NSView using the Swift battery miner, renderer, and graph labels. The Objective-C implementation was removed. Its runtime name, Battery module name/order, visibility and size preferences, graph-update selector, first-click behavior, and mouse forwarding remain available to the existing window and nib. A small hosting protocol keeps the core independent of the application target. Registration is idempotent, host/module references are weak, and moving or replacing a panel removes only its owned module. Replacing a host's module manager also removes the old registration before creating the new one.

The existing animation ticks and sampling after more than ten configured refresh seconds are retained. The panel obtains an initial sample after allocating its history and does not poll again for repeated nib setup. A fresh power-state change restarts the charging animation immediately. Invalid refresh intervals do not advance the sampling accumulator, and a failed poll retains the last battery snapshot. Dead pixel-timing and unused display-mode/measurement caches were removed.

Percentage and charging fills, the signed power bar, borders, and opposing charge/discharge histories retain their layout and series colors. Histories share one watt scale with the existing 30 W minimum. Geometry uses current bounds, clamps fill fractions, and clips bars for small full-size panels. History allocation is bounded. Capacity strings use Int without narrowing, and normalized percentage-only readings still show n/a for mAh. Charged/hold, remaining-time, estimating, full/compact, and narrow labels retain their wording and abbreviations. Measured columns now prevent capacity-label overlap at narrow widths, while accessibility retains the complete source. The shared column helper accepts centered watt text through a Swift-only overload; its existing Objective-C selector remains unchanged. The no-battery message wraps and clears stale capacity/power labels when a battery disappears or returns.

The Battery Settings menu keeps its existing action selector, explicitly targets the panel, and opens through NSWorkspace instead of launching a subprocess. Its opener is injected in tests. Thirty-seven new battery cases bring the full Debug suite to 309 passing cases (208 tests including parameterized cases). They cover registration/visibility/detachment/replacement/manager changes, font sizing, polling cadence and charging phases, all six power states, failed reads and invalid intervals, raw and normalized capacities, narrow/compact abbreviations, signed bar geometry, shared watt scaling, collapsed layouts, nine font/width combinations, history bounds/reset, menu dispatch, native bitmaps, empty-state recovery, mouse forwarding, and native decoding of both current-format and legacy battery nib fixtures.

Debug and Release universal app builds retain arm64, x86_64, the required battery runtime class in each slice, and macOS 26.0 minimum. The battery and shared-label cases also pass with Release optimization. An AppKit capture was inspected for synthetic discharging/charging/charged/on-hold states, animation, watt histories, compact and narrow layouts, the wrapped empty state, and a legacy-archive panel using a live power-source reading. The probe installed no module manager or graph timers and did not open settings, modify the running app or its preferences, or use the clipboard. Physical battery/power-source transitions, complete interactive window/menu flows, and Intel runtime behavior remain unverified. The main window/preferences controllers, other graph panels, and low-level SMC/HID transport boundary remain to migrate.

### CPU graph panel Swift migration

XRGCPUView is now a main-actor Swift NSView using the existing Swift CPU/process miners, graph renderer, and labels directly. The Objective-C implementation was removed. Its runtime name, CPU module name/order, visibility and size preferences, normal/fast update selectors, first-click behavior, and mouse forwarding remain available to the existing window and nib. The window implements a small hosting protocol and routes preferences to the existing CPU panel. Registration is idempotent, host/module references are weak, and detachment/replacement/manager changes remove only the panel's owned module.

The full graph retains the system/user/nice cumulative layers, separate-color toggle, sorted per-core fast bars in the lower half, fixed 100-percent history scale, and the existing seven-sample history reduction when fast usage is enabled. The current total still sums across cores and can exceed 100 percent; the displayed average remains the mean of per-core history averages. Load and uptime flags, units, abbreviations, and minute padding are preserved. History layering uses owned copies without mutating the miner's series. History lengths are bounded, and many cores in a narrow view cannot create negative-width bars. Unused display-rectangle state, dead width caches, and commented dock-icon experiments were removed.

Compact mode now uses the normal per-core samples when fast usage is disabled, rather than stale fast values that are no longer polled. Enabling fast usage continues to use the miner's independent fast baseline and smoothing. Normal graph updates request uptime and the configured load-average sampling; fast callbacks skip sampling when disabled. Reset clears normal histories and fast values, refreshes labels, and requests a redraw. Measured text columns keep narrow/large-font labels separate while preserving complete accessible readings, including rows clipped from compact views.

The context menu retains the top-ten CPU process snapshot, descending CPU order and PID tie ordering, reset, Activity Monitor, and CPU preferences actions. Entries explicitly target the panel, PIDs are formatted without Int32 narrowing, and Activity Monitor opens through NSWorkspace instead of a subprocess. Process refresh remains asynchronous. Tests inject the opener and never launch an external application.

Twenty-eight new cases bring the full Debug suite to 337 passing cases (224 tests including parameterized cases). They cover registration/visibility/detachment/replacement/manager changes, font sizing, independent normal/fast sampling, CPU flags, cumulative layer values and source ownership, total/per-core average text, load/uptime formatting, compact fallback and preference changes, fast-bar geometry, 1/2/8/128 cores, nine font/width combinations, bounded histories, failed reads, reset and changing core counts, empty/top-ten/tied process menus, menu actions, native bitmaps, mouse forwarding, and native decoding of current-format and legacy CPU nib fixtures. The shared extractor reproduces the legacy fixture byte-for-byte. All 28 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required CPU runtime class in each slice, and macOS 26.0 minimum. An AppKit capture was inspected for separate and combined history colors, sorted two/eight-core fast bars, compact displays with fast sampling enabled/disabled, and a legacy-archive panel using live Mach/load/uptime readings. The probe installed no module manager or graph timers and did not launch Activity Monitor, open preferences, alter the running app or its settings, or use the clipboard. Complete interactive window/menu flows and Intel runtime behavior remain unverified. Remaining work includes the main window/preferences controllers, other individual graph panels, and low-level SMC/HID transport boundary.

### Temperature graph panel Swift migration

XRGTemperatureView is now a main-actor Swift NSView using the existing Swift temperature miner, renderer, graph labels, and statistics manager directly. The Objective-C implementation was removed. Its runtime name, Temperature module name/order, visibility and size preferences, graph-update selector, unknown-sensor class method, first-click behavior, and mouse forwarding remain available to the application and nib. The window implements a small hosting protocol for registration, Temperature preferences, and opening the sensor window. Registration is idempotent, host/module references are weak, and detachment/replacement/manager changes remove only the panel's owned module.

Sensor polling remains subject to the miner's five-second cadence and its unknown-sensor policy: an explicit preference or fewer than ten known temperature keys includes unknown sensors. Default selection preserves the Fan/CPU/GPU/SSD preference order and the settings layer's one-time persistence and legacy-placeholder repair. Defaults are selected from enabled readings, while explicit or temporarily unavailable selections remain intact. Dead location-width caches and unused counters/flags were removed, and history lengths are bounded.

The full display retains shared temperature ranges with ten-percent padding, independent fan ranges, primary fill and secondary/tertiary line colors, header gauges, and borders. Values remain in native units for graph geometry; Fahrenheit conversion applies only to displayed Celsius readings. This corrects gauges that previously mixed converted values with Celsius bounds. Compact temperature gauges now divide by the full upper-minus-lower range, and selected fans are deduplicated by sensor key rather than comparing inconsistent names. Percentage readings use a 0-100 range. Missing/invalid fan maxima skip the associated plot safely, and a disappearing fan retains its RPM classification so its stored history cannot distort the temperature axis.

Full, compact, and menu text share unit formatting. A stopped fan is a valid 0 rpm reading. Missing or nonfinite readings show n/a instead of stale values or zero. Unnamed sensors fall back to their key. Measured columns keep names and values separate at narrow widths and large fonts; complete configured readings remain accessible when visual rows are clipped. Empty and unselected states clear prior value labels. Context menus use cached sensor readings, explicitly target the panel, retain reset/preferences/sensor-window routes, and include unavailable and stopped readings. Reset clears sensor histories and only the Temperature statistics module, retains current readings, and requests a redraw.

Thirty new cases bring the full Debug suite to 367 passing cases (244 tests including parameterized cases). They cover registration/visibility/detachment/replacement/manager changes, font sizing, C/F text and identical native gauge geometry, compact range normalization, fan maxima/deduplication/zero/removal, unavailable and recovered readings, unknown-sensor filtering and threshold changes, polling cadence, default selection and persistence, empty/unselected states, percentage/unnamed/nonfinite readings, scoped statistics reset, bounded history and collapsed geometry, nine font/width combinations, cached menus and action routing, native bitmaps, mouse forwarding, and native decoding of current-format and legacy temperature nib fixtures. The shared extractor reproduces the legacy fixture byte-for-byte. All 30 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required temperature-view runtime class in each slice, and macOS 26.0 minimum. An AppKit capture was inspected for C/F views with matching graph geometry, fan-primary compact mode, unavailable and empty readings, and a legacy-archive panel backed by the real Objective-C SMC/HID reader and bundled sensor names. The live probe discovered 155 sensor keys on this Apple silicon Mac. It used a private defaults suite, no module manager or graph timers, and did not open preferences or the sensor window, modify the running app or its preferences, or use the clipboard. Physical fan transitions, complete interactive window/menu flows, and Intel runtime behavior remain unverified. Remaining work includes the main window/preferences controllers, other individual graph panels, and low-level SMC/HID transport boundary.

### Stock graph panel Swift migration

XRGStockView is now a main-actor Swift NSView using the existing Swift XRGStock transport/model, graph renderer, and labels. The Objective-C implementation was removed. Its runtime name, Stock module name/order, size/visibility preferences, graph and thirty-minute selectors, ticker/reload/rotation methods, menu selectors, first-click behavior, and mouse forwarding remain available to the existing window and nib. A small hosting protocol routes preferences to the existing Stocks panel. Registration is idempotent, host/module references are weak, and detachment/replacement/manager changes remove only the panel's owned module. A private snapshot protocol and factory allow deterministic tests without live finance requests.

The two-second ticker uses a weak capture, is installed once while hosted and displayed, and stops on detachment or the next hidden-panel tick. Outstanding requests are canceled when the panel detaches, its symbols change, or its hidden state is observed; resuming creates fresh requests for canceled stock and index snapshots. Initially hidden panels defer requests, and unhosted nib fixtures start neither requests nor timers. Initial loading starts one request pair per symbol, without the previous reset/reload duplication. The existing refresh every fourth thirty-minute callback and rotation every fifteen two-second ticks are retained. Loading completion no longer advances rotation on every tick. Normal graph callbacks keep preference changes and visibility synchronized.

Symbol parsing preserves comma order, duplicates, index symbols, and Unicode while removing whitespace and uppercasing. Replacing or shrinking the symbol list resets the selected index and cancels old models. DJIA uses the raw ^DJI symbol expected by the existing URL encoder, rather than double-encoding the old pre-escaped string. Its requests and overlay now follow the DJIA toggle. The 1m/3m/6m/1y history windows, primary fill, independently scaled index line, and ten-percent range padding are retained. Invalid time-frame indexes fall back to one year. Owned Swift arrays replace the stack allocations, invalid samples are filtered, and flat ranges use the renderer's existing bounded policy.

Full quote rows use measured columns and separate label groups, retain the selected-symbol highlight without mutating shared settings attributes, and reserve a footer for DJIA and period text. An overflow indicator appears only when it fits between footer values. Complete quote/change/period text remains accessible even when rows are clipped. Compact mode retains the selected symbol and price and uses the model's history fallback for its bar value. Quote-only results remain readable without a history graph. Zero/sub-dollar and unchanged prices no longer disappear through integer tests. Empty, unavailable, and fetching states clear old labels. Graph geometry uses current view bounds, and the compatibility height conversion saturates safely.

Menu entries explicitly target the panel and carry a snapshot of their symbol, so an already-open menu remains valid after symbol-list changes. Detail URLs use HTTPS and URLComponents query encoding. Invalid legacy menu tags are ignored, and browsing uses NSWorkspace instead of a subprocess. Tests inject the opener and do not launch a browser or preferences.

Thirty new cases bring the full Debug suite to 397 passing cases (262 tests including parameterized cases). They cover registration/font sizing/visibility, one timer and weak lifetime, detachment/replacement/manager changes, deferred and resumed requests, symbol parsing and list shrinkage, refresh and rotation cadence, loading completion, DJIA request/encoding/toggle behavior, all four history periods and padded bounds, flat/missing/nonfinite histories, quote-only and fallback data, zero/sub-dollar/unchanged quotes, independent text colors, nine font/width combinations, clipped accessibility values and footer spacing, menu dispatch and stale-menu symbols, native bitmaps, collapsed/nonfinite dimensions, native current/legacy nib decoding, and mouse forwarding. A production XRGStock integration case uses recorded JSON responses. All 30 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required stock runtime class in each slice, and macOS 26.0 minimum. The legacy fixture reproduces byte-for-byte. An AppKit capture was inspected for synthetic quotes and changes, the DJIA overlay, clipped lists, narrow/large-font text, compact and loading modes, and the legacy nib's empty state. The probe used a private defaults suite and created no network requests or timers; the running app, its preferences, browser, and clipboard were not changed. Live finance-service availability, complete interactive window/menu flows, and Intel runtime behavior remain unverified. Remaining Objective-C work includes the weather/disk/AI/background panels, main window/preferences controllers, forwarding base, and low-level SMC/HID transport boundary.

### Disk collector and graph panel Swift migration

XRGDiskView is now a main-actor Swift NSView, and XRGDiskMiner separates IOKit sampling from rendering. The Objective-C implementation and its manual calloc/free/alloca buffers were removed. The panel uses Swift-owned XRGDataSet histories, renderer, and labels. Its runtime name, Disk module name/order, visibility/size preferences, update selectors, read/write text methods, first-click behavior, and mouse forwarding remain available to the existing window and nib. A small hosting protocol routes preferences to the existing Disk panel. Registration is idempotent, host/module references are weak, and detachment/replacement/manager changes remove only the panel's owned module. The compatibility header retains definitions.h because remaining Objective-C weather/background consumers still obtain constants transitively through it.

The miner reads IOBlockStorageDriver statistics using current service matches and registry-entry IDs. Every iterator, service, and retained property is released within its sampling scope. Stable per-device baselines avoid aggregate counter spikes when drives disappear, appear, or reset counters; duplicate IDs are counted once. Normal and fast streams use separate monotonic timestamps and baselines. Rates divide by actual elapsed time rather than the configured normal refresh interval, fixing fast-mode timing and zero-interval division. A failed snapshot retains the prior reading and timestamp so the next successful rate spans the gap. Nonfinite clocks are rejected, equal/rolled-back clocks rebase without a rate, malformed/negative/fractional/Boolean counters are rejected, and unsigned byte sums saturate instead of overflowing.

Session I/O now accumulates actual byte deltas from normal samples, rather than adding bytes-per-second values once per callback. Fast sampling does not double-count it. Reset clears graph histories, current graph rates, and compact smoothing while retaining the session byte total and valid sampling baselines. Histories preserve chronological samples when resized, have a 20,000-sample ceiling, and safely support empty storage. The old five-minute callback remains available, but device discovery happens on every sample and no cached iterator needs periodic replacement. The unused per-frame mount/volume scan was removed.

All three disk modes preserve the total/write overlay and opposing read/write directions, existing series colors, read/write label positions, binary-unit formatting, strict left-column row capacity, and compact ordering. Full graphs use one total-rate maximum with a safe nonzero floor. Compact mode preserves the 1 MiB/s floor and damping, retains fractional rates, skips fast reads in full mode, and rebases the fast sampler when returning to compact mode. Failed fast reads do not damp the previous sample again. The Swift label fields make current read/write values accessible; complete scale/session text remains available when clipped. Columns reserve separate left/right space for narrow views and large fonts. Height conversion saturates safely. Disk Utility and preferences actions explicitly target the panel; Disk Utility opens through NSWorkspace instead of a subprocess, with an injected opener in tests.

Forty-two new cases bring the full Debug suite to 439 passing cases (287 tests including parameterized cases). They cover actual elapsed-time rates, independent streams, byte totals, failures, rollback/equal/nonfinite clocks, drive addition/removal and one-direction counter resets, duplicate IDs, startup recovery, UInt64 saturation, resize/eviction/reset/empty histories, statistics decoding, and live IOKit snapshots. Panel coverage includes registration/visibility/detachment/replacement/manager changes, font sizing, all three modes and read/write positions, compact fractional smoothing/order/floor, full-to-compact rebasing, failed fast polls, reset semantics, strict/clipped accessibility readings, nine font/width combinations, history bounds, collapsed dimensions, menu dispatch, native bitmaps, mouse forwarding, and native decoding of current-format and legacy disk nib fixtures. All 42 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required disk view/miner runtime classes in each slice, and macOS 26.0 minimum. The legacy fixture reproduces byte-for-byte. An AppKit capture was inspected for three synthetic graph modes and compact orderings, plus a legacy-archive panel using live IOKit readings. The probe found seven matching driver objects on this Mac; this is aggregate driver accounting, not a physical-disk throughput benchmark. It installed no module manager or graph timers and did not launch Disk Utility, open preferences, alter the running app or its settings, or use the clipboard. Physical drive hot-plug, complete interactive window/menu flows, and Intel runtime behavior remain unverified. Remaining Objective-C work includes weather/AI/background panels, main window/preferences controllers, the forwarding base, and low-level SMC/HID transport boundary.

### AI token graph panel Swift migration

XRGAITokenView is now a main-actor Swift NSView using the existing Swift token miner, observer, renderer, and graph labels. The Objective-C implementation was removed. Its runtime name, AI Tokens module name/order, size/visibility keys, graph-update selector, menu selectors, first-click behavior, and mouse forwarding remain available to the existing programmatic creation path. The graph window implements a small hosting protocol. Registration is idempotent, host/module references are weak, and detachment/replacement/manager changes remove only the panel's owned module. A private snapshot boundary adapts the production miner and allows tests and previews without reading local AI records or contacting endpoints.

The full graph retains Claude/Codex/Gemini/Ollama/Hermes ordering, the original foreground colors and local-provider blends, the reserved indicator strip, provider legends, and the 1000-token default scale for zero histories. Five owned cumulative datasets are reused across draws without modifying source histories. All layers share the grand-total history maximum. Pixel-grid, scanline, and data-aware pixel styles remain; pixel dots now use all five cumulative provider layers and their matching colors. Compact mode keeps the single total area and no visual text/overlay. Empty or mismatched histories skip plotting while retaining statistics. Histories remain bounded at the existing width-minus-19 sample count, with a minimum graph width of 23 and maximum width of 20,000.

Current rate sums no longer wrap through UInt32, and aggregate token/model totals saturate instead of wrapping UInt64. The current-provider indicator normalizes using the complete sum of provider rates and stays within its strip, including extreme fixtures. Provider legends expose their names and totals through accessible labels. The full source reading remains available when rows are clipped; compact mode exposes it on the view while retaining its existing visual appearance. Legend geometry is clipped for short/narrow views, and empty/reappearing providers replace old legend fields without duplication.

Provider totals, sorted Hermes models with no model-name filter, current-rate preference, observer session/daily counters, daily budget progress, and optional sorted model/provider breakdowns are retained. The token breakdown now includes Ollama alongside the other four providers. Display options use the host's settings instead of a separate global settings object. Gemini deltas still forward to the observer as Gemini/Google through a callback that does not retain the view. Cost estimates remain confined to the Cost Intelligence context menu, with the production miner's existing pricing policy unchanged. The menu includes available provider costs, including Hermes, local-inference status/running models, observer statistics and breakdowns, daily reset, and database-directory opening. Nonfinite cost values are omitted. Menu headers remain disabled, action targets are explicit, reset refreshes the display while preserving session/provider counters, and the opener is injected in tests.

Twenty-eight new cases bring the full Debug suite to 467 passing cases (307 tests including parameterized cases). They cover programmatic registration and visibility, font sizing, detachment/replacement/manager changes, cumulative values/cache identity/source ownership, five provider colors, Hermes ordering and count saturation, totals/rate/budget formatting and flags, wide rate sums and bounded indicator proportions, Gemini forwarding and view lifetime, context-menu costs/status/breakdowns/targets, scoped daily reset, unavailable/empty/mismatched/zero data, legend replacement, nine font/width combinations, complete accessibility readings, compact rendering, bounded sample sizing and collapsed geometry, production-miner adaptation without polling, graph styles, count boundaries, mouse forwarding, and native loading of a compiled current-format fixture. This panel is created programmatically in the app; there is no corresponding legacy MainMenu archive payload to extract. All 28 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required AI-token-view runtime class in each slice, and macOS 26.0 minimum. An AppKit capture was inspected for synthetic five-provider stacks, Hermes detail rows, provider legends/current-rate indicator, pixel rendering, large-font/clipped text, empty-history statistics, and compact mode. The probe used private defaults, an isolated observer, and fixture snapshots; it did not read local AI logs/databases, contact provider endpoints, open the database directory, modify the running app or its preferences, or use the clipboard. Whole-app provider ingestion, interactive menu/VoiceOver behavior, and Intel runtime behavior remain unverified. Remaining Objective-C work includes weather/background panels, the main window/preferences controllers, the forwarding base, and low-level SMC/HID transport boundary; an older unbuilt plural XRGAITokensView prototype also remains in Resources.


### Window background Swift migration

XRGBackgroundView is now a main-actor Swift NSView. Its Objective-C implementation and build reference were removed; the compatibility header imports XRGCore. The existing runtime class name, nib payloads, background outlet, minimize/expand selectors, clicked-minimized latch, mouse forwarding, tracking, menus, and theme-drop entry points remain available. A small hosting protocol routes General preferences and successful theme refreshes through the existing graph window. Host references are weak, setup is idempotent, and detachment cancels pending hostname updates and clears only the owned outlet.

Minimize/restore keeps all four edge anchors, saves expanded dimensions before collapsing, and preserves the fork's recovery from collapsed startup frames and frames stuck at the expanded module minimum. Repair examines both axes, prefers usable saved dimensions, and otherwise uses the existing 600-pixel fallback or a larger module minimum. A deliberately chosen small window remains small when it is above that minimum. Expansion restores the active axis and repairs the cross axis only when it is actually collapsed; usable cross-axis sizes remain intact. Hover expansion retains the double-click latch, and a subsequent double click clears it. Foreground/desktop behavior uses the settings menu index consistently.

Drawing retains the rounded border, panel openings, title colors/transparency, centered text, and horizontal title on the physical left edge. Horizontal drawing rotates only the graphics context; it no longer changes the view's frame, bounds rotation, or module sizes during drawing. Layout notifications track size and orientation, and the graph-window orientation action explicitly requests layout so square windows also reposition their panels without relying on a resize event. Hostname lookup runs asynchronously, publishes on the main actor, ignores superseded/detached results, and does not retain the view while waiting. The title is available as the group's accessibility label.

Theme drops accept one copied file URL with the existing case-sensitive .xtf extension, read under scoped resource access, validate the complete theme before changing settings/defaults, and refresh the palette and modules only on success. Read/parse/validation failures use the existing error action. Context-menu items explicitly target the view. Application activation, alerts, help, About, quit, and ordering prevention are injected in tests, as are hostname lookup and theme reading; tests never invoke those application actions.

Forty-five new cases bring the full Debug suite to 512 passing cases across 324 test functions. Coverage includes all four minimize/restore anchors and idempotence, both-axis collapsed startup recovery with and without saved dimensions, module-minimum traps versus chosen small windows, minimized orientation changes, square-window relayout, nonfinite geometry/history, double clicks and hover latching, level/index mapping and mouse forwarding, setup/detachment/tracking/menu targets, asynchronous hostname cancellation and lifetime, drawing without geometry mutation and transparent panel openings, secure and legacy theme archives read from private files, atomic invalid-theme failures, rejected drag payloads, and native decoding of current-format and actual legacy background nib fixtures. All 45 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the required background runtime class in each slice, and macOS 26.0 minimum. The legacy fixture reproduces byte-for-byte. An isolated AppKit capture was inspected for vertical/horizontal borders and titles, panel openings, larger clipped title text, transparency, and both collapsed layouts. The probe used fixture panels, private defaults, and injected application actions. It did not alter the running XRG app or its preferences, activate its Dock icon, show alerts, quit an application, or use the clipboard. Drag tests used private named pasteboards rather than the general clipboard. Animated whole-app minimize/restore and relaunch behavior, real Dock/help/quit actions, interactive VoiceOver behavior, and Intel runtime behavior remain unverified. The preference-rewriting window regression tool was not run against the user's live app. Remaining Objective-C work includes the weather panel, main window/preferences controllers, forwarding base, and low-level SMC/HID transport boundary; the older unbuilt plural XRGAITokensView prototype also remains in Resources.


### Weather graph panel Swift migration

XRGWeatherView is now a main-actor Swift NSView using the existing Swift renderer, labels, and URL transport. Its Objective-C implementation was removed; the compatibility header retains the weather option constants and imports XRGCore. The runtime class name, Weather module name/order, size/visibility preferences, normal/half-hour update selectors, station/secondary-options selectors, direct METAR input, first-click behavior, and mouse forwarding remain available to the existing window and nib. The graph window implements a small hosting protocol and routes preferences to its existing Weather panel. Registration is idempotent, host/module/manager references are weak, and detachment or manager replacement removes only the view's owned registration.

A separate Swift value parser owns METAR readings and history. It retains the final report, including a response containing only one report; strips HTML without joining adjacent fields; recognizes station/time tokens rather than station names in page headings; validates times and station identifiers; handles NIL/missing/malformed data without unchecked substring ranges; and bounds input to 2 MiB and 2,048 reports. Provider order remains the current-reading/history order, as in the original view; there is no timestamp resampling or interpolation. Detailed format checks were informed by the official Aviation Weather Center METAR description at https://aviationweather.gov/help/data/.

Temperature and dewpoint use Celsius internally, prefer the precise signed remarks group when present, and calculate relative humidity from Celsius rather than the original Fahrenheit inputs. Fractional and mixed-fraction statute-mile visibility, M/P qualifiers, metric visibility, and CAVOK decode explicitly. Wind retains METAR knot values and now labels them kt rather than incorrectly calling them mph; calm, variable wind, gusts, and three-digit speeds are handled. Pressure keeps inches Hg and hPa readings consistently, using the existing conversion factor. Missing readings remain n/a. The unused global POSIX-regex helper and manually allocated history buffers were removed.

The full graph retains the filled temperature history, high/low padding, optional unfilled wind/humidity/visibility/dewpoint/pressure series, chronological plotting, original foreground colors, and existing style overlays. Valid samples determine extrema; missing sentinels cannot stretch the range. Secondary histories use a consistent unit within each series, repairing the original mixed-unit pressure/visibility ranges. Zero ranges have finite plotting bounds. Compact mode retains its station/current-temperature row and range-normalized temperature bar. Full mode retains the eight station/weather rows and preference units. Measured label abbreviations use the actual reserved column width, and complete readings remain accessible when rows or values are clipped. Menu summaries and update/preferences actions remain, with explicit action targets and disabled informational entries.

The two existing endpoints still load concurrently. Each completed payload is considered once, primary wins when both usable results are ready together, the first usable result cancels both requests, and invalid/error results leave a pending fallback available. The panel uses the production URL adapter's request generations to reject late completions after cancellation or station changes. The two-second ticker holds the view weakly, runs only while a displayed hosted panel is fetching, and stops on success, final failure, cancellation, hiding, or detachment. Station changes reset the snapshot and cancel outstanding work. The invalid-data five-minute retry now accumulates fractional refresh seconds instead of truncating them to an integer; nonfinite/nonpositive refresh intervals do not advance it. Wake refreshes remain and clear the window's wake flag. Showing the panel reloads it without issuing requests for unrelated panels.

Seventy new cases bring the full Debug suite to 582 passing cases across 349 test functions. They cover raw/HTML/single/final reports, malformed fields and dates, missing values, precise/signed temperatures, Celsius humidity, fractional/qualified/metric visibility, calm/variable/gust/three-digit wind, pressure conversions, station normalization and input/history limits, module registration/visibility/replacement/manager changes, font sizing, both-source ordering and fallback, final errors, station changes, real URL-adapter cancellation with injected asynchronous transports, fractional retries, wake refreshes, hidden/detached work and timer lifetime, every secondary plot and finite bounds, preference units, explicit menu dispatch, nine font/width combinations and clipped accessibility readings, compact/status/style bitmaps, mouse forwarding, and native decoding of current-format and actual legacy weather nib fixtures. All 70 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the weather runtime class in each slice, and macOS 26.0 minimum. The legacy fixture reproduces byte-for-byte. An AppKit capture was inspected for all six graph choices, both temperature/distance/pressure unit choices, fractional visibility, variable wind, compact valid/fetching/invalid states, missing readings, and larger/clipped text. The preview and tests used private defaults, fixture reports and injected transports; they did not contact weather services, create production graph timers, modify the running app or its preferences, launch external applications, or use the clipboard. Live provider availability/HTML changes, whole-app interactive menus and wake behavior, VoiceOver interaction, and Intel runtime behavior remain unverified. All active leaf graph panels are now Swift. Remaining Objective-C work includes main window/preferences controllers, AI support categories/controllers, the forwarding base, small utility/entry-point code, and the low-level SMC/HID transport boundary; the older unbuilt plural XRGAITokensView prototype also remains in Resources.


### Main graph window Swift migration

XRGGraphWindow is now a main-actor Swift NSWindow in XRGCore. Its Objective-C implementation and source/build references were removed; the existing header imports XRGCore. Its runtime class name, nib window templates, settings/module/panel properties, background outlet, preferences and graph actions, timer callbacks, version-check selectors, drag state, key-window behavior, and background movement remain available to the existing application and Objective-C preferences UI. All 51 original IBAction method names remain. A weak XRGGraphWindowController outlet protocol routes panel preferences, the sensor window, and palette refreshes to the Swift application delegate without making XRGCore depend on the app target. The delegate also starts runtime services after main-nib outlet connection, idempotently with the window's own nib setup.

XRGWindowPreferences owns startup defaults and settings decoding. A golden plist generated by the pre-migration Objective-C getDefaultPrefs implementation, with imperial units and a fixed 1920-by-1080 screen, verifies all 75 default entries, including decoded colors/font, original palette/opacity values, graph flags, sensor placeholders, station key (lowercase icao), and stock/network defaults. Locale and screen-origin inputs are independently testable. Startup decoding accepts existing and secure archives and string/number preferences, retains deliberately empty strings, valid fractional refresh rates, and 64-bit network scales, falls back for malformed archives/types, nonfinite values, and invalid option indices, and does not rewrite saved defaults. Numeric restoration distinguishes exact integer text from a rounded floating-point value beyond Int.max, avoiding saturating NSNumber-to-Int bridges. The font refreshes text attributes and line height. Graph orientation is restored before minimum-size and panel layout calculations.

The window owns normal/fast/five-minute/half-hour timers with their existing intervals and selector dispatch. Creation is idempotent; changing refresh replaces only the graph timer and retains fifth-second rounding with a positive 0.2-second floor for action input. Invalid/nonpositive refresh input cannot create a zero/NaN timer. Weak timer callbacks no longer retain the window; isolated deinitialization invalidates retained timers, and shutdown cleanup stops callbacks and update/weather requests while preserving the saved minimized flag and expanding the frame for restoration. Wake state is per window rather than a global flag. NSWorkspace wake notifications replace the old global IOKit power connection, explicitly deliver on the main queue, and are removed during cleanup/deinitialization. A background-thread notification regression verifies actor delivery. No sleep assertion or power-change veto is installed.

Module toggles, border changes, square/rectangular orientation switches, collapsed orientation round trips, top-edge anchoring, minimum sizes, and immediate orientation persistence retain their behavior. Resizes notify the module manager without relying on an unused window delegate callback. Checkbox, popup, matrix, color/transparency, text, sensor-location, and graph-style actions retain their selectors and use typed controls with valid ranges. Color tags and memory-option tags remain unchanged. Drop-shadow actions now update the graph window itself instead of its usually absent parent. Temperature/network/weather/stock selection actions continue to update the existing Swift views. The application delegate's collapsed-limit calculation now multiplies after conversion to CGFloat, avoiding Int32 multiplication overflow.

Custom window dragging and the existing 20-pixel snapping policy remain, including screen selection by the proposed window center, negative-coordinate monitors, edge alignment, and centered alignment after an edge snap. Geometry is exposed to deterministic tests without moving the user's windows. Close respects the optional window delegate decision, and miniaturization forwards to AppKit. The programmatic AI-token-panel creation path remains idempotent and uses the already migrated Swift panel.

The update checker retains this fork's exact raw-GitHub version endpoint and releases URL. Transport, notice choice, and URL opening are injectable. Completed requests are consumed before presenting the notice so nested event handling cannot display it twice; errors/invalid payloads end the request without a notice. Numeric and beta versions compare without fixed-width integer overflow, reject malformed input, retain component-count ordering, and place a release after all of its beta revisions. More Info, Disable Checking, and Not Yet retain their choices; only disabling persists that preference. Tests make no external update requests, show no alerts, and open no URLs.

Seventy-nine new cases bring the full Debug suite to 661 passing cases across 372 test functions. They cover default parity, locale/screen inputs, settings/archive restoration and malformed preferences, no preference writes during restoration, version/beta boundaries, native window configuration, timer identity/forwarding/replacement/lifetime/cleanup, collapsed and square orientation layouts, module visibility and border actions, delegate routes, AppKit selector dispatch, seven color/transparency tags and all memory tags, popup/matrix/text/sensor actions, saved minimized-state cleanup, per-window wake state and background delivery, custom dragging and multi-screen snapping, current-format and actual legacy window-template decoding plus KVC outlet assignment, and all update-notice outcomes/reentrancy/error handling. All 79 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the graph-window runtime class in each slice, and macOS 26.0 minimum. The fixture extractor now also isolates a window shell, removes its panels/connections and autosave name, and leaves existing panel extraction unchanged; window/background/weather/GPU fixtures reproduce byte-for-byte. An AppKit capture was inspected using the actual Swift window with private defaults and fixture graphs, covering the original palette, orientation via the window action, collapse/expand dimensions and top anchor, and square relayout. It did not start miners, schedule graph sampling, check the live release endpoint, show notices, launch/activate applications, alter the running XRG app or its preferences, or use the clipboard. Whole-app startup/relaunch, native animated dragging/resizing, physical sleep/wake/power-off, live update service responses, full preferences interaction, and Intel runtime behavior remain unverified. Remaining Objective-C work includes preferences/AI support controllers and categories, the forwarding base, utility/entry-point code, and the low-level SMC/HID transport boundary; the older unbuilt plural XRGAITokensView prototype also remains in Resources.


### Preferences controller Swift migration

XRGPrefController is now a main-actor Swift NSObject in XRGCore. Its Objective-C implementation and build references were removed; the compatibility header imports XRGCore. All 80 connected nib outlets and the original 21 action names/selectors remain. The window is exposed as a Swift property with the same Objective-C window getter, and the application delegate now uses that property. A small XRGPreferencesDataSource protocol supplies the graph window without a dependency on the app target. The graph reference remains weak. Toolbar delegation, General/Appearance/CPU/Memory/Temperature/Network/Disk/Weather/Stocks/AI panels, live graph action targets, font selection, color wells, module visibility, and close-time saving remain available.

The controller retains the existing nib layouts and generates Appearance style and AI controls only once. It reuses the existing unconnected AI Tokens checkbox found in the General nib instead of creating an overlapping duplicate. Toolbar identifiers consistently match their panels, including Stocks, and panel changes retain the window's top edge and a minimum 500-point width. The initial General size is captured before assigning the content view so AppKit cannot replace its intended dimensions with the previous content size. Generated AI budget/percentage labels and fields have separate columns and accessible field labels. Existing Cocoa bindings, including the unknown-sensor preference, remain in the nib.

Live controls continue to target the Swift graph window, with typed popup/matrix/checkbox mappings. Window Level now has Normal/Foreground/Background choices at the indices expected by the migrated graph window, with an unselectable header; all three settings round-trip correctly. Sensor menu items carry keys as represented objects, and popup actions forward the selected menu item rather than treating a popup as an NSMenuItem. This preserves choices across duplicate labels and reordered discovery. No-sensor saves preserve existing sensor keys. Interface items likewise carry their identities so selection/save does not depend on a later enumeration's index. Sensor and interface sources are injected in tests; unhosted nib loading does not query either source.

Saving first validates and archives a complete snapshot before the first persistent write. Existing preference names, graph flags, color/alpha pairs, secure font/color archives, pending station/stock/title edits, sensor keys, graph style, and AI options are retained. Invalid scales, refresh values, budgets, or percentages leave the persistent domain unchanged and report through an injected notice. Network scaling uses checked Int multiplication and preserves exact values through Int.max. Opening and saving no longer truncate a byte scale that is not divisible by the selected units. Valid fractional or long refresh intervals expand the slider's displayed range instead of being silently clamped on opening; action rounding writes the same value back to the control and settings. Revert refreshes controls from the current live settings/defaults; it does not undo graph actions already applied live, as the UI continues to use those actions.

The main preferences AI defaults are registered only for missing keys and do not override the graph's registered visibility setting or existing preferences. Generated controls refresh from current defaults without duplication. AI settings retain their existing staged-save behavior and reset notification names. Tests use a private notification center and never reset the running app's counters. The separate Objective-C AI preferences controller remains outside this migration and retains its own existing defaults policy.

Theme import/export retain .xtf property lists with all seven color/transparency pairs. Both operations share one validated theme dictionary builder; export remains independent of unrelated invalid form fields. Import uses the existing complete-theme validator before changing settings/defaults, refreshes wells and graphs only on success, and accepts existing and secure archives. Export writes atomically. URL-scoped access is balanced. File choices, file reads/writes, notices, font-panel presentation, and URL opening have injected boundaries; canceled choices do nothing and delayed completions do not retain the controller. The station-list action now uses NSWorkspace through its injected opener instead of launching a subprocess, retaining the existing URL. Tests do not show file/font dialogs, open URLs, or modify the running app.

Forty-six new cases bring the full Debug suite to 707 passing cases across 390 test functions. They cover current and actual legacy nib loading, all connected outlets and generated-control idempotence, all ten toolbar routes and top anchoring, AppKit action dispatch, all Window Level choices, sensor key identity/None/reordering/absence, 64-bit network scales and overflow/invalid input, exact refresh round trips and action rounding, interface identity, captured preference families and pending text edits, rejection before persistence, AI setup/private reset notifications, font/link injection, theme export/import/private-file failures/atomic invalid themes, unrelated-field export, sheet cancellation and weak completion lifetime, and close/revert behavior. All 46 cases also pass with Release optimization.

Debug and Release universal app builds retain arm64, x86_64, the preferences-controller runtime class in each slice, and macOS 26.0 minimum. The legacy fixture is a byte-for-byte copy of Resources/Preferences.nib/keyedobjects.nib, preserving its original NIBArchive format; the current fixture comes from the designable source with a test owner and no visible window. Native loading validates both formats. An AppKit capture of all ten panels was inspected using private controller defaults and fixture sensor/interface data, including the single AI visibility checkbox, Appearance controls, sensor menus, network fields, and generated AI panel. The probe started no miners or graph timers, showed no system panels/notices, opened no URLs, posted no shared reset notifications, and did not alter the running app or use the clipboard. Full interactive preferences/file/font dialogs, live sensor/interface changes, application restart/persistence with real user settings, dark-appearance rendering, and Intel runtime remain unverified. Remaining Objective-C work includes the standalone AI support controller/categories, the forwarding base, utility/entry-point code, and the low-level SMC/HID transport boundary; the older unbuilt plural XRGAITokensView prototype also remains in Resources.


## XRG-ng name, attribution, and GPLv3 (2026-10-26)

The project is now `XRG-ng.xcodeproj`, with the shared launch scheme and app
product named `XRG-ng`. Internal `XRGCore`/`XRGTests` modules, Objective-C runtime
names, theme formats, bundle identifiers, and preference keys remain stable.
Build scripts and current documentation use the new product name. The Linux
application displays XRG-ng while retaining its `xrg-linux` executable/configuration
paths for compatibility. Git remotes and historical upstream links still identify
their actual repositories.

Project notices credit Mike Piatek-Jimenez / Gaucho Software, LLC (2002–2024),
Marc Shade (2025–2026), and Stephen de la Vega (2026 onward). The ranges follow
Mike's last code contribution on 2024-03-14 and Marc's first fork contribution on
2025-11-08. COPYRIGHT records the respective roles and preserves other contributors'
attribution. App metadata, localized overrides, About credits, and project source
headers carry the updated notices.

LICENSE now contains the unmodified GNU GPL version 3 text, with project notices
specifying GPL-3.0-or-later under the original GPL-2.0-or-later grant. Apple and
CodeExchange source notices remain unchanged. THIRD_PARTY_NOTICES.md documents
the existing APSL/GPL incompatibility in the combined macOS sensor executable;
this change does not establish a distributable GPL-only binary. The app bundles
the GPL text, COPYRIGHT, third-party notices, APSL text, and About credits.

Both universal Debug and Release apps built successfully, retained the required
runtime classes for arm64 and x86_64, and passed all 707 cases across 390 test
functions. The production preferences nib was recompiled from its edited source;
all ten panels were rendered using isolated preferences and fixture hardware data.
The General and Network panels were visually checked, including the shortened
network-bandwidth label. Historical preference fixtures retain the original archive.
Linux branding, attribution, and packaging were updated without a Linux build on
this macOS host.


## Swift AI preferences glue and application entry point (2026-10-26)

The legacy `openAIPreferences:` selector is now implemented in the Swift app
delegate and selects the existing Swift AI preferences panel. Named panel routing
lives in XRGPrefController, including AI and all previous panel names. The separate
Objective-C AI controller had only defaults/reset methods and no nib or controls;
it and its app-delegate category are removed. Reusing the main preferences window
preserves staged edits and avoids the separate controller's conflicting registration
of AI tracking, provider grouping, and graph visibility defaults. The compatibility
category header now imports the Swift app-delegate declaration.

XRGAITokensNotifications provides the three original notification names in Swift.
The preferences controller and token observer use typed Notification.Name values.
Both old Objective-C notification headers map their identifiers to Swift class
properties; the old C global definitions and Objective-C implementation are removed.
An Objective-C bridge test verifies that both headers deliver the unchanged names,
sender, and payload to observers on a private notification center.

`Other Sources/main.swift` replaces main.m. It preserves errno handling, the
original process-priority adjustment, command-line arguments, and AppKit's exit
status. Architecture checks now require the main entry symbol and Swift notification
runtime class in both executable slices.

Universal Debug and Release builds pass, retain arm64/x86_64 and macOS 26.0, and
pass all 711 cases across 393 test functions. Added cases exercise AI panel routing,
window reuse, staged edits/defaults, real reset-button dispatch through the Swift
observer, and the Objective-C notification bridge. All ten existing toolbar cases
also exercise named panel routing. A separate probe compiled the actual Swift app
delegate and invoked openAIPreferences: and showPrefsWithPanel: through AppKit action
dispatch. It verified AI/CPU routing, window reuse, and pending edits using private
defaults and a window subclass that never presents a window; it did not launch the
monitoring app or start miners.

Seven Objective-C implementation files remain in the macOS app build: the five
sensor-boundary files, XRGGenericView.m, and NSStringUtil.m. Unbuilt AI prototypes,
compatibility headers, and historical interface fixtures remain separate cleanup
work. Full monitoring-app startup/relaunch and Intel runtime remain unverified by
this stage; the Linux C/GTK implementation is unchanged.


## Swift generic view and string utilities (2026-10-26)

XRGGenericView is now an open, main-actor Swift NSView in XRGCore. Its Objective-C
implementation and app/test build entries are removed. The runtime name and all
23 original Objective-C method selectors remain available through the compatibility
header. Drawing forwards to the existing Swift renderer and labels, including raw
samples, datasets, ranged/pixel/mini graphs, byte/rate labels, styles, and column text.
Repeated awakening creates one label set. The host and module manager are weak;
attachment follows the current graph window, and detachment or moving into an
ordinary NSWindow clears stale references rather than messaging an incompatible
window as a graph host.

The old protected Objective-C ivars are now properties. Objective-C callers can
instantiate and call the Swift class, while subclasses must be Swift; existing
production panels already inherit NSView directly. The Objective-C bridge tests use
properties, and a Swift subclass test validates every module callback. The older
unbuilt Objective-C AI prototype remains outside the app and still needs removal
or migration before it could be built.

XRGStringUtilities replaces NSStringUtil.m. The NSString stringWithoutXMLTags
selector is preserved by a Swift extension. Complete angle-bracket spans are
removed while incomplete tags, entities, and Unicode text are preserved; scalar
iteration handles combining marks adjoining a bracket without treating them as
part of the bracket character. A large-input case covers repeated tagged readings.
The global override of Foundation's NSString.boolValue is retired. The legacy
rule (only empty, zero, or case-insensitive no are false) is an explicit Swift
helper used for string fallbacks when restoring preferences. Primary preference
strings retain their existing normalized TRUE/FALSE decoding. Objective-C tests
verify the XML selector, explicit legacy helper, and unchanged Foundation behavior.

Universal Debug and Release builds pass with arm64/x86_64, macOS 26.0, and the
required generic-view/string-utility runtime classes. Both configurations pass
751 cases across 403 test functions. Added coverage includes host changes and
detachment, manager lifetime, Swift subclass callbacks, native archive decoding,
Unicode and malformed tag stripping, legacy boolean/fallback semantics, and
Objective-C calls. Existing native bitmap/accessibility tests still pass. Separate
probes against Debug and Release frameworks verify every method selector from the
original generic-view header, its runtime name, and Foundation boolean behavior.

Only five Objective-C implementation files remain compiled into the macOS app:
XRGTemperatureHardwareReader.m, SMCInterface.m, SMCSensors.m, SMCSensorGroup.m, and
XRGAppleSiliconSensorMiner.m. Unbuilt AI prototypes, compatibility/C sensor headers,
and historical interface fixtures remain separate from that count. These checks
do not establish whole-app startup/relaunch or Intel runtime behavior, and the Linux
implementation remains unchanged.


## Swift sensor grouping and Apple silicon collection (2026-10-26)

SMCSensorGroup and SMCSensorSeries now live in Swift in XRGCore; their Objective-C
implementation and build references are removed. Compatibility headers preserve
class names, construction selectors, properties, numeric/lowercase joining, unequal
series filtering, sensor ordering, and the existing description rules. The port
fixes a reproduced bug where a series ending at the final wildcard z was never
flushed, dropping that series. Regression cases include a lone z, concurrent series
ending at z, and numeric ranges joined to the full lowercase alphabet. Literal
patterns and unmatched sensor sets still fail construction.

XRGAppleSiliconSensorMiner now collects service products and temperature values in
Swift through an injected XRGHIDTemperatureTransport protocol. It preserves the
sensorData class selector, nil versus empty results, per-service read order, product
validation, duplicate-name replacement, and raw values for the existing temperature
validation layer. The original source-provenance links remain in the Swift file.
The compatibility header imports the Swift declaration.

Private HID C calls and CF ownership now live in XRGAppleHIDTransport inside the
existing Objective-C hardware reader file. Every native call is protected before
returning to Swift, and event cleanup runs in a finally block. Client creation and
matching failures release the client; missing clients/services/events return safe
nil results. Native type checks reject non-service objects. The production Intel
factory returns nil and has no references to the four private HID entry points;
arm64 retains the original native API bindings and matching/event constants.

Tests substitute C functions using a test-only per-file compiler flag, so they run
the real Objective-C exception/ownership handlers and Swift collector without
querying physical sensors. Existing reader/factory/exception tests remain intact.
Added tests cover native matching and event ABI, nil results, all six native failure
phases, balanced CF ownership even when value extraction throws, malformed products,
missing events, duplicate names, and grouping through an Objective-C caller. A
large inline parameter list initially exceeded the Swift Testing macro type-checker;
a typed static case array resolves it without reducing the test cases.

Universal Debug and Release apps built with arm64/x86_64 and macOS 26.0; runtime
class guards pass for the Swift models/collector and native transport. Both test
configurations pass 776 cases across 414 test functions. Binary inspection confirms
private HID symbols appear only in the arm64 slice. A separate read-only native
probe returned 41 finite raw HID readings, 148 SMC readings, nine known SMC keys,
and no fan entries on this machine. It did not start NSApplication or graph timers,
access preferences, or show UI. Raw readings still pass through the existing Swift
validation policy; this is not a calibration check. Physical fan transitions and
Intel runtime remain unverified.

All seven existing APSL source/header/license files checked before the port are
unchanged. This work ports the first-party GPL adapters and does not resolve the
existing APSL/GPL combined-distribution issue. Only XRGTemperatureHardwareReader.m,
SMCInterface.m, and SMCSensors.m remain in the macOS app's Objective-C Sources phase.
Unbuilt AI prototypes and historical interface resources remain separate cleanup
work. The Linux implementation is unchanged.


## Swift SMC sensor cache and value handling (2026-10-26)

SMCSensors now lives in XRGCore as Swift. Its native Objective-C implementation
and build references are removed, while the compatibility header preserves the
class, construction, properties, naming methods, temperature selector, allValues,
fanValues, and sensorValues APIs. The Swift translation retains the original
CodeExchange APSL 2.0 notice and identifies the 2026 modification; it is explicitly
listed as an APSL derivative in THIRD_PARTY_NOTICES.md. It was not relicensed to GPL.

The model caches known/unknown temperature keys, direct/wildcard names, Intel
marker descriptions, and fan-key groups. Direct names win over wildcards; ambiguous
wildcards now have deterministic lexical precedence. Reassigning the public
mapping retains the old explicit cache-rebuild policy. Temperature reads retain raw
values for the existing Swift validation layer, read known keys before unknown
keys, and skip failed reads. Fan dictionaries retain every available field and
32-bit forced-mode masks, including numeric-string flags. allValues enumerates
fresh keys and preserves the original float-precision strict 15-to-200 bounds;
motion values retain their original seven-key read order. Four-character codes
preserve spaces, reject malformed lengths/wide characters, and skip failed or
invalid native indices. Invalid key counts cannot allocate an unbounded cache.
The unused legacy C wildcard-matching helper is retired.

XRGSMCTransport in the existing Objective-C reader contains interface construction,
key-count/index/value calls, NSError results, and resource-path lookup before Swift
resumes. The reader consumes a small values-provider protocol; its outer metadata
exception tests remain covered with a fixture provider. Native-interface tests now
stub SMCInterface rather than SMCSensors, so the normal factory tests execute the
real Swift model and the bundled descriptions. This adds native failure/recovery
coverage without reading physical sensors. The low-level SMCInterface source,
Apple HID headers, and APSL text remain unchanged in this stage.

Both universal Debug and Release apps build with arm64/x86_64 and macOS 26.0;
runtime guards include SMCSensors and the native SMC transport. Both configurations
pass 805 cases across 427 test functions. Added coverage includes direct/wildcard
precedence, cached names, known/unknown reads, Intel aliases, all fan fields and
forced bits, raw motion/data readings, strict float limits, fresh enumeration,
invalid counts/indices, malformed descriptions, and native exceptions/NSError
rejection. Packaged third-party notices match the updated source notices.

A read-only probe ran the saved pre-port Objective-C model beside the Swift model
against real SMC connections. All nine known keys, 139 unknown keys, known names,
and 148 temperature reading keys matched. The HID path returned 41 readings and
this machine exposed no fan entries. The probe did not start the application or
graph timers, access app preferences, or show UI; it compared keys/names rather
than claiming identical changing physical values or sensor calibration. Physical
fan transitions and Intel runtime remain unverified.

Only SMCInterface.m and XRGTemperatureHardwareReader.m remain compiled Objective-C
in the macOS app. The native reader contains the small SMC/HID exception and ownership
boundaries. Unbuilt prototypes, compatibility headers, and historical interface
resources remain separate cleanup work. Linux is unchanged, and the previously
documented APSL/GPL combined-distribution issue remains unresolved.


## Swift SMC packets, metadata cache, and decoder (2026-10-26)

XRGSMCInterface now owns the SMC wire format, key metadata cache, request/error
handling, value decoding, key-count lookup, and indexed enumeration in Swift.
The translation retains APSL 2.0 and the Apple/CodeExchange source attribution.
THIRD_PARTY_NOTICES.md lists the new derivative and packet-layout header.

The legacy Objective-C SMCInterface public header is unchanged. Its implementation
is now a small facade forwarding to the Swift object, plus the native packet I/O
boundary. Keeping this facade preserves Objective-C's failable default initializer;
the test target compiles the same facade body under a fixture runtime name, while
retaining the existing reader-interface stub and its exception tests. The file is
reduced from 454 to 102 lines. The other compiled Objective-C file remains the
181-line reader/HID boundary. All counts include license notices.

The Swift codec explicitly constructs 80-byte little-endian packets without unsafe
loads. C static assertions verify the kernel struct size and the key-info, result,
command, index, and payload offsets in both architectures. Tests compare Swift
packets with the real C struct. Unsigned/signed integers, flags, raw blobs,
little-endian floats, legacy sp78 sentinel/quantization behavior, and fpe2 arithmetic
retain their existing supported-value results. Zero/oversized payloads and invalid
type sizes are rejected before reading or caching; truncated replies and kernel/SMC
failures cannot produce fabricated readings or poison the metadata cache. Cached
metadata access is protected by a lock. Invalid indices fail with the old zero
sentinel, and NSError outputs retain the NSMachErrorDomain convention.

The native boundary preserves fresh connections per request for wake/reconnect
behavior. It removes the unused persistent connection and releases each matched
IOService object, fixing the previous per-call service-reference leak. Every acquired
connection/service receives cleanup attempts through finally blocks, including after
exceptions and partial failures. Cleanup continues when another cleanup call throws.
The boundary permits only read, key-info, and index commands; malformed packets and
write commands never reach IOKit. Input validation is also inside the exception
handler, before returning to Swift.

Universal Debug and Release apps build and retain the required classes in arm64 and
x86_64, with macOS 26.0. Both configurations pass 837 cases across 439 test functions.
Added coverage includes fixed C/Swift ABI offsets and padding, metadata caching and
recovery, decoder signedness/precision/sentinels, flags/blobs/NaN, error precedence,
invalid sizes/indices, real facade forwarding and nil-on-open-failure, native kernel
failures, short replies, all cleanup paths, exceptions during cleanup/validation,
and read-only command enforcement. A test fixture's access level was corrected after
the first test compile; all cases remain in the successful reruns. Packaged license
notices and required runtime symbols match the updated sources.

A read-only probe linked a saved pre-port Objective-C interface/model beside the
new implementation. All nine known and 139 unknown temperature keys, known names,
and 148 temperature reading keys/types matched. The 129 finite numeric pairs had
zero difference in that sample. HID still returned 41 readings; this machine had
no fan entries. The probe did not start the app, run graph timers, read or modify
app preferences, or show UI. This is sample equivalence, not sensor calibration or
proof of future readings; physical fan transitions, full app relaunch, and Intel
runtime remain unverified.

Production Objective-C is now confined to the two native/compatibility boundary
files (283 lines including notices). Unbuilt AI prototypes and historical interface
resources remain separate cleanup work. Linux is unchanged. APSL-derived Swift and
native code retain APSL; the existing combined-distribution compatibility issue
remains unresolved.

## Retired Objective-C prototypes and development guide (2026-10-26)

Removed the unbuilt plural XRGAITokensView prototype and the obsolete
XRGAppDelegate+AIWindowIntegration and XRGGraphWindow+AITokens categories, including
their headers. Their only source references were to one another, they were absent
from the Xcode build, and no nib, xib, plist or historical fixture archive refers
to their runtime identities. The active singular XRGAITokenView, window actions,
notifications and AI preferences flow remain implemented in Swift.

Removed four unused headers: definitions.h, XRGAISettingsKeys.h, XRGPlugin.h and
ppp_msg.h. The old settings macros and network structs had no remaining source
consumers after the Swift ports. Removed the corresponding compatibility imports
and project references. THIRD_PARTY_NOTICES.md no longer lists the deleted APSL
1.1 PPP header; all notices for the retained APSL 2.0 sources remain intact.
The existing combined-distribution licensing issue is unchanged.

CLAUDE.md now describes the Swift framework and app shell, NSView panel composition,
main-actor/lifecycle contracts, the actual 0.125-second fast timer, macOS 26.0,
Debug/Release universal validation, injected test fixtures and the two remaining
native exception boundaries. It replaces instructions to add Objective-C classes
or edit deleted macro headers. Linux implementation and troubleshooting guidance
are retained; no Linux source is changed.

The first fork CI run never reached checkout: GitHub reported hosted-runner
allocation failures and macOS arm64 capacity constraints. The workflow now selects
the standard macos-26-intel runner. The official runner image lists the existing
Xcode_26.3.app path, so the toolchain pin, 26.0 deployment floor, both executable
architectures and all test checks remain unchanged. Local arm64 validation and
remote Intel runtime validation must still be reported separately.

Local Debug and Release validation both passed: universal arm64/x86_64 app builds,
metadata/notices/runtime-class checks, and 837 cases across 439 test functions per
configuration, with zero failures. Tests executed on arm64 with local Xcode 27.2;
this does not establish Intel runtime or Xcode 26.3 compatibility. Project syntax
and whitespace checks passed, and retained archives were not modified.

### Intel CI toolchain follow-up

Run 40373509915 allocated both Intel runners successfully. Debug and Release
universal app builds passed under Xcode 26.3, including bundled metadata/notices,
the 26.0 floor and required runtime classes in both slices. Both jobs then reached
test-fixture XIB compilation and exceeded twenty minutes while ibtool/ibtoold were
active. Tests never started, so this run does not establish Intel test coverage.

The workflow now pins Xcode 26.6, the Intel runner image's documented default,
to retry fixture compilation with the current toolchain. This is an attempted
remedy pending remote results, not a proven root cause or a claimed pass. The
runner architecture, deployment floor, source fixtures, test assertions, universal
build checks and twenty-minute limit are unchanged. The 26.3 app-build result
remains useful evidence separately from the pending 26.6 test run.

Runner image: https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md

### CI stall diagnostics

The CI script now records timestamped phases and, only on GitHub Actions, starts
an optional read-only sampler. Every five minutes it records selected compiler/
test process statistics and two-second samples of one ibtool, ibtoold and xctest
process owned by the runner, if present. Process arguments and environments are
not recorded. The existing artifact upload includes these .log files. No system
services are disabled, no third-party diagnostic package is installed, and no
fixture or validation assertion changes.

An EXIT trap stops and reaps the sampler while retaining the original build/test
exit status; INT/TERM retain their conventional failure status. Isolated checks
verified phase/process capture, termination during an active sample, termination
while waiting between samples, invalid-interval rejection, preservation of a
synthetic build failure's exit code 73, and absence of leftover background
processes. The updated Debug script completed locally with both app slices,
metadata/runtime checks and 837 cases across 439 functions, with zero failures.
Release source and validation assertions are unchanged from the previous pass.
The remote Xcode 26.6 retry is tracked separately from these local checks.

### Restore the ARM CI host after Intel fixture stalls

The Xcode 26.6 retry (40376824201) also exceeded twenty minutes in both
configurations. Each universal app build succeeded and passed product, deployment
floor and runtime-symbol checks. Both test builds stopped producing output at
WeatherView.xib compilation, with ibtool/ibtoold still active at cancellation.
This reproduces the stalled test-build phase across 26.3 and 26.6 on hosted Intel;
it does not prove a specific tool or operating-system root cause.

The workflow returns to its original ARM macos-26 host and keeps the Xcode 26.6
pin plus the new diagnostic sampler. Every build/test assertion, both executable
architectures, the 26.0 floor and the twenty-minute limit remain enforced. The
initial ARM allocation failure may recur; the runner change is an attempt to
complete hosted validation, not a claim that the pending run passes. Local ARM
tests and successful hosted Intel universal app builds remain separate evidence;
hosted Intel test execution is still unverified.

## Isolated application composition and process restoration (2026-10-26)

The previous ARM CI run (40379975106, b08f400) completed successfully in both
Debug and Release. The new work adds an application-level harness beyond the
individual panel/controller tests.

XRGAppDelegate now has an internal dependency-injected initializer for preferences,
nib loading, window presentation, activation, sensor data/policy and theme errors.
Its default initializer retains the production standard-defaults, main-bundle,
Dock/application activation, live sensor fallback and alert behavior. Sensor
controllers with no data source explicitly receive their owning delegate. The
same delegate source is compiled into the test target; no production smoke flag,
menu or framework-wide mutable test configuration is added.

XRGApplicationSmokeScene composes the production delegate, graph window,
background, all ten panels, preferences and sensor controller using fixture
collectors and private notifications. Coverage includes duplicate launch callbacks,
visibility actions, resize/layout, all ten preference routes, lazy nib reuse,
sensor policy/forwarding, valid/invalid theme files, collapsed restoration in both
orientations, wake notification handling and power-off/termination cleanup.
Graph update callbacks are driven explicitly; its graph timers are created but
not scheduled. Existing collector/transport assertions remain intact.

Tools/smoke-macos.py builds a disposable, ad-hoc-signed AppKit executable using
these classes and the test-enabled framework. Two distinct processes enter the
real NSApplication run loop. The first saves a budget, title, horizontal orientation,
collapsed state and sensor-window preference. The second verifies those persisted
values and state before repeating the controls and shutdown checks. Both must
keep their windows hidden, invalidate all four graph timer objects, produce JSON
reports/offscreen PNGs and succeed within thirty seconds per process. Release
compiles the harness/delegate with optimization. A generated UUID bundle identifier
must match the allowed private preference namespace before standard defaults can
be used; the runner deletes that domain and treats cleanup failure as a failure.

The sensor nib fixture is generated from the unchanged production Sensors.xib;
only automatic presentation and frame autosave are suppressed. Source parity is
checked before every process run. Early checks caught the original nib presenting
itself, Foundation rejecting a suite named after its own bundle, and AppKit treating
positional harness inputs as documents. The harness now uses the hidden fixture,
standard defaults under its verified private bundle ID, and environment inputs.
It also accepts restored sensor-window loading before lazy preference loading,
while still requiring each nib to load exactly once. These were harness isolation
and expectation fixes; the production resources are unchanged.

Both local CI configurations pass universal app builds, bundled metadata/notices,
required runtime classes, and 843 cases across 443 test functions with zero failures.
Each also passes the two-process smoke check and preference cleanup. Isolated
failure checks confirm command timeouts kill/reap children and SIGTERM preserves
exit 143 without leaving a command running. Offscreen captures were inspected.
CI runs the new check after the complete test suite and uploads only its logs,
JSON and PNGs, not the temporary executable/framework. The temporary preference
domain is removed; the running user's app and its preference domain are not used.

This is a production-class composition harness, not a launch of the packaged app.
The shipping main.swift/NSApplicationMain path, original MainMenu nib loading,
LaunchServices, interactive dialogs/VoiceOver, physical sleep/wake, live providers,
physical sensor/fan changes and Intel runtime still need separate validation.
The existing APSL/GPL combined-distribution issue remains unchanged.

## Packaged entry point and original nib validation (2026-10-26)

The composition-harness commit b450f30 passed hosted Debug and Release CI
(40388453747). A separate packaged check now executes the actual shipping
main.swift/NSApplicationMain path in a disposable copy of the built app. Only
the copy's bundle identifier and ad-hoc signature change. Every executable
__TEXT section, the LC_MAIN entry command and the original MainMenu nib must
retain their hashes before and after execution; the original build is also
checked again. No production sources or resources change in this step.

The injected Swift observer uses Objective-C runtime interfaces, without linking
XRGCore a second time: that framework contains static classes already present in
the app. Small Objective-C files under Tools/PackagedSmoke provide test-only
presentation hooks and a preflight executable; they have no production target
membership. The two remaining production Objective-C hardware bridges are
unchanged.

Before any packaged-app launch, preflight requires a matching private UUID bundle
identifier, an executable inside the disposable output root, matching plain
ad-hoc signature flags, working injection and prohibited activation. Restricted
or privileged executables are refused. A sandbox denies networking and reads of
home-directory data except the disposable preferences, with parent-directory
metadata allowances for preference lookup. A task-owned cache sentinel verifies
the read denial. External-provider graphs and update checks are disabled. Native
read-only system collectors run, but reports contain no sensor readings, hostnames
or screenshots. Activation and window ordering are suppressed before main starts.

Four distinct app processes seed and restore collapsed state in vertical and
horizontal orientations. They verify the original MainMenu delegate/window/module
connections, all ten panels and their production executable images, the original
Preferences and Sensors nib outlets, scheduled graph-timer advancement, shipping
process priority and hidden windows. NSApp.terminate invokes the original delegate
termination callback before the observer checks all four timers are invalidated;
AppKit then exits normally. Each process has a sixty-second limit.

Cleanup removes the logical preference domain and verifies removal of UUID-owned
preference files, caches, saved state and HTTP storage. Physical cleanup covers
the residual plist observed after defaults deletion. Negative checks reject
production/invalid cleanup namespaces, detect changed text/entry commands, refuse
missing injection before AppKit startup, and remove private artifacts after a
synthetic preflight failure, including when logical defaults deletion also fails.

Both complete local CI configurations pass universal app builds, metadata/runtime
checks, 843 cases across 443 test functions, the two-process composition harness
and the four-process packaged check. Both packaged configurations were rerun
successfully after adding physical cleanup. CI now runs the packaged check and
uploads its logs and JSON only, without temporary apps or injected binaries.

This closes shipping-entry-point and original-nib coverage on the local ARM host.
LaunchServices, notarized/hardened-runtime launch, interactive UI and VoiceOver,
physical sleep/wake, live external providers, sensor/fan changes and Intel runtime
remain separate validation work.

## Finder launch and interactive Release validation (2026-10-26)

Hosted run 40398575098 passed Debug and Release, including the packaged check.
The next validation used the unchanged Release production binary on the local
ARM host, in a disposable UUID copy with external-provider graphs, AI tracking
and update checks disabled. Unlike the automated packaged harness, this copy had
no injected hooks or sandbox; real read-only system collectors and normal AppKit
presentation ran. Its executable text, entry command and original MainMenu hashes
matched the build before and after the UI check.

Native app control launched the copy for the initial interaction and a collapsed
relaunch. A further launch explicitly double-clicked XRG-ng.app in Finder after
confirming the disposable process had exited. Read-only process inspection then
confirmed the exact copied executable was running; its graph displayed the saved
title and budget. This exercises a local Finder/LaunchServices launch, without
claiming notarized or hardened-runtime distribution coverage.

The visible UI check opened Preferences with Command-comma; changed the title and
orientation; toggled GPU visibility off/on; visited all ten preference panels;
saved and loaded a task-owned theme through the native dialogs; and opened/closed
the production sensor window. AI tracking remained disabled while setting a
budget of 2345. The horizontal graph collapsed through its title double-click,
survived a normal quit/relaunch and expanded again. Saved preferences independently
matched the title, orientation, budget, visibility and collapsed/expanded states.
Normal Command-Q quit was verified before each offline preference check.

Tools/interactive-smoke-macos.py makes preparation, saved-value verification and
cleanup repeatable; Tools/interactive-smoke-macos.md records the manual steps.
Verification refuses a still-running copy. Cleanup unregisters only the disposable
bundle and removes its UUID-owned home artifacts; successful cleanup was checked
after this run. Reports contain identity hashes, static outcomes and preference
key names, without saved-value dumps or sensor readings. No screenshots or app
binaries are committed or added to CI artifacts.

This adds manual Release evidence, not additional automated test cases or Debug
interactive coverage. Full VoiceOver navigation, font/color dialogs, invalid-theme
alerts, physical sleep/wake, provider operation, sensor accuracy and Intel runtime
remain unverified. The production code and the two Objective-C hardware boundaries
are unchanged.

## Accessible graph visibility and expansion (2026-10-27)

Hosted run 40404698228 passed both configurations before this change. Inspection
of the native accessibility tree found that disabled Weather, Stock and AI panels
still exposed readings: layout reduced their frames to zero without hiding their
views. XRGModuleManager now hides disabled panels during expanded layout and shows
enabled panels. The existing collapsed-layout guard keeps layout callbacks from
revealing panels while the graph is collapsed.

XRGBackgroundView's title group now exposes Expanded/Collapsed as its accessible
value and a named Collapse Graph or Expand Graph custom action. The standard
accessibility press action uses the same path. These actions retain the existing
geometry/defaults behavior; explicit expansion releases the hover-collapse latch.
State changes post the standard accessibility value notification. Detached views
expose no custom action and refuse activation. The GPU preference checkbox's
inherited Temperature Graph help text is corrected in Swift setup.

Regression coverage checks disabled/re-enabled panel visibility, layout while
collapsed, action routing, state/defaults, restored geometry in both orientations,
hover-latch release and detached activation. Both complete local CI configurations
pass universal builds, product/runtime checks, 445 test functions covering 846
cases, fixture composition and packaged launch/restore/shutdown checks. This run
used Xcode 27.2 on arm64; hosted CI retains its Xcode 26.6 pin.

Native accessibility actions were invoked against the disposable Debug app in
both orientations. The tree reported each state change, removed all readings when
collapsed, omitted disabled providers, and removed/reinstated GPU readings when
its checkbox changed. The corrected GPU help was visible. The optimized Release
app also collapsed through its named action, quit/relaunched with Collapsed state
and expanded through the named action afterward. Saved preferences and cleanup
were independently verified for both copies. The manual workflow documents these
checks without exporting sensor readings or screenshots.

This verifies the native accessibility interface and targeted interactions. A full
VoiceOver session, physical Intel execution and the previously listed hardware and
distribution checks remain separate work. The two production Objective-C hardware
boundaries and original nib resources are unchanged.

## x86_64 execution under Rosetta (2026-10-27)

Hosted run 40500225182 passed the previous accessibility changes in both
configurations. The local ARM host has Rosetta available, enabling an additional
execution check of the shipped x86_64 slice rather than relying on universal
compilation and symbol checks alone.

Tools/packaged-smoke-macos.py now accepts --architecture arm64 or x86_64, defaulting
to its runner architecture. It confirms the requested slice exists and can run,
compiles matching test instrumentation, and builds its harmless preflight probe
with the same slice set as the app. The launcher explicitly selects the requested
architecture. Before main, the injected constructor checks its compiled
architecture and sysctl.proc_translated against the requested architecture and
host capability. Preflight and every app process report and revalidate those
values. Wrong architecture, wrong translation state and missing injection were
each rejected before AppKit startup in isolated negative checks.

Both Debug and Release packaged checks passed four distinct x86_64 processes with
translation confirmed: seed/restore in both orientations, original entry point and
nibs, ten modules, real timers, normal AppKit termination and private cleanup.
The native arm64 check also passed with translation false. Existing executable
text/entry/MainMenu identity checks, hidden windows, denied networking/home-data
reads, private preferences and report restrictions remain enforced.

The first complete translated Debug suite exposed two GPU nib tests assuming
exactly one GPU's three labels. Both decoded views actually contained two managed
label groups. The nib tests now require exactly three unique labels per group,
exact ownership of every subview, and identity preservation through repeated
awakening and layout. Strict one- and multi-GPU fixture assertions remain intact;
no production GPU collector or layout logic changes.

Complete x86_64 Debug and Release suites subsequently passed 445 test functions
covering 846 cases each. Their test executables are thin x86_64, so an ARM test
host cannot load them as a native fallback. The revised GPU suite also passed
under native Release. A complete run of the updated Debug CI script passed native
and translated suites, native composition, both packaged modes and cleanup on the
local Xcode 27.2 ARM host.

On ARM, the CI script now requires Rosetta availability and uses a separate
X86DerivedData directory and X86Tests.xcresult bundle for the x86_64 suite. The
same result gate applies to both suites; the translated test executable must be
thin x86_64. Both existing workflow configurations run the extra phases. CI adds
translated logs/JSON and the test result bundle to artifacts, without uploading
temporary apps or instrumentation binaries. The hosted Xcode 26.6 pin, universal
app checks, deployment floor and timeout are unchanged.

This adds translated x86_64 runtime evidence on ARM. Physical Intel CPU/GPU/SMC
behavior, full VoiceOver usage and the existing hardware/distribution checks
remain separate validation. Production sources and the two Objective-C hardware
boundaries are unchanged in this step.

## Built-in color themes (2026-10-27)

Appearance now offers Classic, Midnight, Ocean, Dusk, Paper and Phosphor through a
Built-in Themes menu. Classic matches the existing palette; Paper supplies a light
alternative, and the other presets provide dark palettes. Selecting a preset
applies colors and opacity immediately and refreshes the existing wells, sliders
and graphs. The menu is an apply action rather than a saved theme-name setting,
so later custom edits or imported files cannot leave a misleading preset label.

Presets produce the same fourteen-field dictionary validated by XRGTheme and use
XRGSettings.applyThemeDictionary for atomic application and persistence. Load Theme
and Save Theme retain their original selectors, native dialogs and .xtf format.
Presets can be edited with the existing controls and exported as ordinary theme
files. Font, graph style, layout and monitoring settings are independent. Opening
Appearance adds controls once without applying a preset or changing the original
nib resources.

Parameterized tests apply every preset through its real control action and check
settings/defaults, unchanged font/style/budget, and file export/import. They retain
existing malformed-theme, failed-write and cancelled-dialog tests. The five new
palettes also require opaque fills and a text contrast ratio of at least 4.5 over
each background/graph fill. Repeated configuration must not duplicate the menu or
grow the panel.

Complete local Debug and Release runs passed 447 test functions covering 857 cases
on native ARM and Rosetta x86_64, plus both packaged smoke modes and composition.
Live UI checks inspected Appearance layout, Paper/Ocean graph rendering, export of
Paper through Save Theme and restoration through Load Theme. The Release menu
applied Midnight, and its colors survived a normal quit/relaunch. A visual check
caught disabled-looking header text in the pull-down; its title now stays enabled.
Disposable preferences and launch registrations were removed after verification.
README documents the preset menu and the retained file controls.

## Initial 0.1.0 release preparation (2026-10-27)

Marketing versions now identify XRG-ng 0.1.0, build 1; latest_version.txt agrees.
The updater now uses sdelavega/XRG-ng for version lookup and release links, avoiding
an offer to replace this new version with the older fork's 3.x releases. Existing
injected update-path tests cover the revised addresses. The maintainer confirmed
that distribution permission or a licensing arrangement is in place for this
release; the third-party notices record that confirmation without relicensing
APSL sources.

The complete local Release CI script passed 447 test functions / 857 cases on
native ARM and Rosetta x86_64, both packaged smoke modes and fixture composition.
Tools/release-macos.sh provides a separate clean-source Developer ID archive,
signature/metadata checks, notarization/stapling, ZIP/DMG packaging, Gatekeeper
checks and checksums. RELEASING.md documents the process; build metadata ties
release assets to their source commit. Distribution results are recorded by the
packaging logs and GitHub release rather than inferred from these source checks.

## Linux Swift / Rust GTK4 foundation (2026-10-27)

The maintainer selected GTK4 for the Linux rewrite. Six existing Swift files now
live in Shared/Sources/XRGSharedCore: XRGDataSet, XRGRateTracker,
XRGLocalProviderParser, XRGCodexLogParser, XRGProviderLogParser and XRGWeatherReport.
Xcode compiles these same files into XRGCore; SwiftPM compiles them into the dynamic
XRGSharedCore library on Linux/macOS. Objective-C annotations are conditional, and
XRGDataSet retains its Accelerate path on macOS with a Swift arithmetic path on
Linux. Runtime class names/selectors and macOS archives remain compatible.
XRGBuiltinTheme provides the six shared palettes; the AppKit extension retains
Classic's device-RGB identity, fourteen-field XTF dictionaries and opacity values.

A Swift 6.3+ @c ABI exports thread-confined retained handles, fixed-width scalars,
explicit buffer capacities, and parser statuses. Shared/include/xrg_shared.h
specifies caller ownership and bounds; no Swift object layout crosses into Rust.
Rust wrappers prevent Send/Sync for mutable Swift handles and free each exactly
once. Claude/Gemini/METAR sources are portable but their ABI consumers remain future
work; local metrics and individual Codex records are exposed now.

xrg-linux/rust provides the first runnable Linux slice: aggregate CPU, memory,
network receive/send and physical-disk read/write graphs, all six theme presets,
and persisted preset selection in a separate xrg-ng config directory. Rust owns
Linux acquisition and GTK4/Cairo presentation. A worker owns Swift histories/rate
trackers and publishes copied Rust data through one bounded latest-snapshot slot.
No external processes or provider scans run in the UI thread. The existing C/GTK3
executable, build and preferences remain available throughout migration.

Tools/ci-linux.sh and the Linux workflow verify Swift tests, a C executable against
the documented ABI, Rust formatting/Clippy/tests, live headless collection, and a
GTK/Xvfb main loop with actual draw callbacks and Paper/Ocean selection actions.
Smoke mode avoids user preference reads/writes and saves an optional rendered PNG.
The supplied Swift/Rust Dockerfile builds the same environment. GTK 4.10 is the
minimum; Linux development binaries have a build-local rpath and are not yet
standalone distribution packages.

Local validation passed seven shared Swift test functions (including six palette
cases) on macOS and Linux, eight Rust tests on both platforms, and complete Linux
Debug/Release scripts in ARM64 Ubuntu 24.04 containers with Swift 6.4.1,
Rust 1.99.1 and GTK 4.14.5. Both GTK runs reached four samples / sixteen draws and
saved visually inspected snapshots. The Dockerfile itself built successfully.
The complete macOS Debug and Release scripts each passed 447 test functions / 857
cases on native ARM and Rosetta x86_64, composition and both packaged smoke checks.

This is not C feature parity. Remaining Rust collectors include GPU, battery,
temperature, process and TPU. Provider acquisition, detailed preferences/custom
load-save/import, per-device selection, module controls, window pinning/placement,
accessibility/compositor verification and runtime packaging remain. Xvfb/Cairo
results do not establish Wayland, GPU acceleration or physical-device behavior.
See xrg-linux/rust/README.md for construction, commands and the migration checklist.

### Reuse the tested Swift library in Linux CI

The first hosted x86_64 Debug job passed. Release passed the standalone Swift
suite but its second SwiftPM invocation, inside Cargo's build script, crashed in
libdispatch. CI now exports XRG_SHARED_LIB_DIR for the exact library it has just
built, tested and exercised through the C header. Cargo validates that directory
and library and links it directly. Ordinary Cargo builds still build Swift with
separate scratch output and bounded parallelism. This avoids duplicate Swift
compilation in CI; it does not claim to repair the SwiftPM/libdispatch crash.
Local ARM64 Linux Debug and Release scripts passed with the reused artifact.

## Linux battery and temperature slice (2026-10-27)

Rust now reads system batteries and standard hwmon/thermal-zone temperatures through
injectable sysfs roots. Battery scanning skips HID/HID++ names before attribute
reads, excludes device-scoped and absent supplies, and never mixes energy and
charge units. Complete pairs or capacity percent produce up to three per-device
histories; tooltips include status and available wattage. Name-keyed histories
survive ordering changes, reject malformed values and reset when a device leaves.
Battery time/health estimates are not part of this slice.

Temperature scanning retains labels and signed Celsius readings, honors channel
fault/enable flags, and uses thermal zones only when hwmon has no usable values.
The graph reports the highest readable temperature; tooltips list all readings
and partial errors. Explicit type-4 thermistor channels are deferred until
calibrated conversion support; raw voltage must not be displayed as Celsius.
Libsensors configuration/compute rules and fan speeds remain future work. Missing
optional hardware produces an absence label and no synthetic-zero graph. Per-device
errors remain visible and do not suppress healthy devices or fail the core smoke
gate on hosts without optional hardware.

GTK now presents six panels with a scrollable graph area, signed temperature scale,
hover details and accessible descriptions. Thirteen sysfs/sampler fixture tests
cover energy/charge separation, actual zero charge, signed-current power,
peripheral/HID exclusions, partial errors, multiple batteries, hotplug/history
identity, temperature units/labels/negative values, fault/disabled channels,
thermistor exclusion and thermal fallback. Together with the existing eight Rust
tests they pass on macOS and ARM64 Linux. Full Linux Debug/Release scripts pass
shared Swift tests, C ABI checks, strict Clippy, all 21 Rust tests, live core
collection, and four GTK samples / 24 draws. The six-panel snapshot was visually
inspected. Containers expose no battery or thermal sensors, so live readings from
physical hardware remain unverified. No macOS production source changed here.

The preceding CI correction (644f39a) passed both hosted x86_64 Linux Debug/Release
jobs. macOS hosted runners were still queued when checked; local macOS Debug and
Release suites passed at the initial shared-source extraction.

## Linux Rust GPU collection (2026-10-27)

The GTK4 monitor now has a seventh, GPU utilization panel. DRM primary-node
scanning deduplicates device aliases and excludes connector/render nodes. PCI
identities key Swift-backed histories so card renumbering cannot splice different
adapters' data. Compute-only NVIDIA installations are also discovered through
bound PCI devices. Up to three available utilization series are drawn; accessible
tooltips show supported memory, clock, temperature, power and fan telemetry.

AMDGPU uses its documented busy percentage and VRAM byte counters plus hwmon.
NVIDIA uses one query for the discovered active adapters, matched by normalized PCI
addresses rather than output order. Vendor and actual driver binding gate all
queries. Suspended devices remain asleep, nouveau never starts SMI, and fixture
roots cannot accidentally start the host's SMI executable. Intel i915 clock and
available i915/xe hwmon telemetry are shown without inventing utilization: a PMU
backend remains future work. Other driver counters and NVIDIA N/A remain absent.
Fan RPM and NVIDIA fan percentage retain separate units; reported SoC power is not
presented as necessarily GPU-only power. No simulated readings are emitted.

The shell-free query runner bounds stdout to 64 KiB and runs with a 750 ms deadline.
Nonblocking pipes prevent a descendant holding stdout from escaping that deadline;
failed queries terminate their own process group. Reaping uses a bounded poll and
retains a killed-but-uninterruptible child rather than spawning replacements or
blocking in wait. A 30-second failure cooldown limits repeated driver failures.
Final cleanup cannot block normal application shutdown on that child. Sampling
now schedules its one-second cadence around collection time, preventing normal
query latency from extending every interval. Sysfs kernel calls themselves do not
have a userspace cancellation guarantee.

Fourteen GPU/command fixture tests cover units, genuine idle samples, invalid data,
Intel unavailable utilization, alias filtering, vendor/driver/suspend gates,
compute-only devices, quoted CSV/N/A, invalid/duplicate PCI rows, output ordering,
timeouts/cooldown, bounded output, spawn/exit failures, descendant-held pipes and
PCI-keyed history through card renumbering and failures. All 35 Rust tests passed
on macOS and ARM64 Linux. Complete Linux Debug/Release scripts passed shared Swift
and C ABI checks, strict formatting/Clippy, live core collection and GTK checks
reaching four samples / 28 draw callbacks. The seven-panel PNG was visually
inspected. The container has no GPU, so physical AMD/Intel/NVIDIA readings and
accelerated rendering remain unverified. No macOS production source changed.
