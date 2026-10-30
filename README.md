XRG-ng
======

<img width="1080" height="188" alt="AI-Tokens" src="https://github.com/user-attachments/assets/bfb873ea-6564-437f-af2c-315b14b3dfb0" />


A real-time system resource monitor for **macOS and Linux** with customizable floating graphs.

🍎 **macOS**: Native Swift/Objective-C AppKit implementation (macOS 26+, Intel and Apple silicon)
🐧 **Linux**: Swift/Rust + egui application; the C/GTK implementation has been retired.
See the [new Linux build and migration status](xrg-linux/rust/README.md).
The Linux build includes an opt-in [station weather window](xrg-linux/rust/README.md#weather-observations)
using the same Swift METAR decoder as macOS.



Original XRG website: https://gaucho.software/xrg/

## Linux UI

The Linux build uses egui/eframe instead of GTK.

This is a deliberate technical and governance decision. egui fits
XRG-ng's Rust architecture and custom graph interface.

As maintainer, I disagree with aspects of GNOME's political advocacy
and community governance, and prefer not to build on GTK. I want
XRG-ng to remain focused on software engineering, with contributions
evaluated on technical merit and constructive conduct. Agreement
with my political views is not a condition of participation.

## Hardware support and feedback

Hardware support is a **best-effort attempt**, especially across Linux GPU families,
sensors and driver versions. We do not have access to every platform and cannot
physically test them all. Development uses published driver interfaces, automated
fixtures, native architecture builds and the hardware available to us. Automated
checks verify software behavior; real-device coverage is limited and will grow
with community feedback. Available metrics depend on the device, kernel, driver
and permissions.

**Feedback is welcome and encouraged**, including reports of configurations that
work well. Please [open an issue](https://github.com/sdelavega/XRG-ng/issues) with
your XRG-ng version, distribution, kernel, CPU architecture, GPU/device model and
driver, plus expected versus observed behavior and relevant diagnostic output.
Bug reports, corrections and contributions help improve support for everyone.
Physical validation of every listed platform is not a prerequisite for progress
or releases.

## Apple Neural Engine on macOS

The **NPU** graph sits directly below **GPU** and above **Memory** in vertical
layout (GPU → NPU → Memory horizontally). It is enabled by default on Apple
Silicon; General Preferences provides a **Neural Engine** visibility checkbox.
Intel Macs keep it hidden by default. Existing module sizes, visibility choices,
themes and XTF load/save continue to work.

The graph shows **active time (%)** when macOS exposes an ANE `ACT` residency
counter under IOReport **SoC Stats → Cluster Power States**. The scale is fixed
at 0–100%, with **Busy/Idle** and power in watts beside it. Active time is the
busiest ANE cluster's software active-state share over the sampling interval;
it does not measure compute-core occupancy, operations per second or inference
throughput. Overlapping clusters are never added together.

Where residency is unavailable, the graph shows **ANE power in watts**, from
energy-counter changes over elapsed monotonic time, and **n/a%**. **Pwr↑** marks
an energy increase: an inferred activity signal, not a utilization percentage.
The fallback scale follows observed watts. A zero energy delta means only that
the counter reported no increase; it does **not** prove the NPU was idle.
Where macOS exposes ANE fabric sampling, a narrow secondary-color **traffic band**
also marks observed transfers. **Traffic** / **No bus** describe those reports;
they do not claim compute occupancy or idle. The band follows the rate of positive
bandwidth-bin reports, with its own observed scale. It is not a percent meter,
bytes/sec or an inference count. Background/housekeeping traffic can appear too.
This path was exercised against controlled ANE evaluation calls on an M4 Pro and
M5, including runs where the energy counter stayed unchanged. Watts and **n/a%**
remain visible when direct active-time telemetry is unavailable.
Tooltips/context menu and accessibility text include the last detected activity
and its source, endpoint identity, core count/architecture and firmware state.
Detection, firmware presence and open client connections do not prove execution.

Acquisition is read-only, runs on a serial background queue and coalesces requests
to at most one per second. It opens no accelerator user client, loads no models,
and needs no root helper, `powermetrics`, network service or extra dependency.
The optional private IOReport symbols are resolved at runtime. Residency,
energy and traffic use independent subscriptions; unavailable power does not hide
valid activity readings. State intervals use `IOReportCreateSamplesDelta`, reject
counter resets and unknown state layouts, and require positive total residency
before reporting even 0%. Only recognized ANE channels/units are used; energy
aggregates take precedence over their indexed components and counter identities
must be unique. The first sample, resets, source/unit changes, stale data and
failures establish a fresh interval. Missing data creates no synthetic idle
samples. Registry discovery is bounded to 16 endpoints.

See [macOS NPU telemetry notes](Tools/macos-npu-telemetry.md) for the private API
investigation, hardware limitations and a read-only diagnostic command.

Apple's private interfaces can differ across chips and macOS versions. This is
best-effort support: unavailable metrics remain explicit, and device feedback is
welcome and encouraged. The implementation uses IOReport's energy subscription
interface (see the [interface reference](https://github.com/tmc/aneperf/blob/main/ioreport.go));
automated fixtures cover conversion, recovery, graph placement and preferences.
Live checks on the available Mac verify discovery and readable energy counters,
not every model or workload.

## Features

XRG-ng displays real-time graphs for:

- **CPU Usage** - Per-core utilization and load averages
- **GPU Usage** - GPU utilization and memory (Apple Silicon & Intel)
- **Neural Engine (NPU)** - Apple ANE active-time percentage where exposed, power and recent activity, between GPU and Memory on macOS
- **Memory** - RAM usage, swap, page ins/outs
- **Network** - Upload/download rates per interface
- **Disk Activity** - Read/write operations per volume
- **Battery** - Charge level, time remaining, health
- **Temperature** - CPU, GPU, and system sensors
- **Weather** - METAR station observations with optional 6/12/24-hour history and a secondary curve
- **Stock Prices** - Real-time market data
- **AI Token Usage** - Live token consumption and cost tracking for Claude, Codex, Gemini, Ollama, and Hermes agents

## AI Token Monitoring

**New in this fork**: Monitoring of locally recorded AI usage and estimated/source
costs across multiple providers. AI collection uses a nominal five-second cadence
on Mac and Linux, independently of system graph refresh. Logs may arrive in bursts;
observed usage counters are not billing records.

### Supported Providers

| Provider | Data Source | Type | Auto-Detected |
|----------|-------------|------|---------------|
| **Claude Code** | `~/.claude/projects/*/sessionid.jsonl` | Cloud API | ✓ |
| **OpenAI Codex CLI** | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Cloud API | ✓ |
| **Google Gemini CLI** | `~/.gemini/tmp/<hash>/chats/session-*.json` | Cloud API | ✓ |
| **Ollama** | REST API (localhost:11434) | Local Inference | ✓ |
| **Hermes agents** | SQLite (`~/.hermes/state.db`) | Agent orchestrator | ✓ |

### Features

- **Provider Monitoring** - Observed token rates for Claude, Codex, Gemini and Hermes, plus Ollama model inventory/status
- **Cost Context** - The Mac menu labels legacy estimates, source estimates and reported values; the mixed total and extrapolations are not billing records or a current price catalog
- **Ollama Integration** - Detect available and running models; `/api/tags` and `/api/ps` do not supply token usage
- **Hermes Agent Tracking** - Per-model token breakdown and cost read straight from the Hermes state DB
- **Zero Configuration** - Auto-detects installed AI tools, no setup required
- **Cached Tracking** - Mac log scans run in the background on a 30-second schedule; database/endpoint sampling follows graph updates
- **Per-Provider Breakdown** - Color-coded visualization shows usage by provider (and per-model for Hermes)
- **Background Collection** - Incremental file caches and background scans keep log parsing off the UI thread

Mac AI preferences now apply session/daily accounting and token budgets to all
four collected usage providers. Enable **AI Token Tracking** to keep sampling
even while its graph is hidden. When tracking is off and the graph is hidden,
pending collection is cancelled; visible graphs retain their normal monitoring.
The first complete read establishes a baseline;
historical files are excluded from these counters. New tokens are assigned to the
day they are observed, not reconstructed by event timestamp. Source changes,
decreasing counters and failed database/endpoint reads establish fresh baselines;
log scans retain their last complete snapshot on failure. Gaps and history edits
can therefore undercount activity. These are local observed counters, not invoices.

Input/output splits and model names are used only when available. Total-only
Codex and custom Claude monitoring counters retain an **Unknown split** count.
Claude/Gemini log models and Hermes database models contribute to daily model
breakdowns; late or inconsistent attribution is omitted rather than added to the
provider total. Reset Session and Reset Daily are independent and preserve graphs
and historical provider totals. Resets, midnight rollover and tracking changes
establish new observation baselines, excluding any pending pre-reset scan delta.

Use **Allow Budget Notifications…** in Mac AI preferences to request macOS alert
permission. A positive daily budget emits at most one threshold alert per day
(or after Reset Daily); zero disables it. Delivery follows macOS authorization and
notification settings. A denied alert is not retried for that day's threshold.
Permission is never requested by background sampling or smoke tests.

Linux now has the same observed session/daily accounting rules, independent
resets and token budgets. Enable tracking in **Preferences → AI**; desktop alerts
have a separate, default-off checkbox. **AI usage…** shows exact totals, unknown
splits, daily model/provider aggregates, persistence errors and notification
status, with Reset Session and Reset Daily buttons. Both platforms continue accounting
while the graph is hidden when tracking is enabled. Its daily state lives in
`$XDG_STATE_HOME/xrg-ng/ai-usage.json` (default `~/.local/state/xrg-ng`); session
totals restart with the app. An exclusive lock prevents competing instances from
overwriting daily totals or duplicating alerts. Corrupt or externally changed
state is preserved, counters continue in memory, and alerts are suppressed until
state can be saved. Linux alerts use the standard desktop D-Bus interface directly
from Rust, without GTK or libnotify; a notification service must be running.
Delivery is attempted once per threshold day, with a one-second deadline and no
automatic retry. Desktop notification settings determine whether a banner appears.

### How It Works

The AI Token monitor automatically detects all installed AI coding tools:

1. **Claude Code** (Anthropic) - Cloud API
   - Source: `~/.claude/projects/*/sessionid.jsonl`
   - Tracks input/output tokens; Mac applies a legacy model-based cost estimate

2. **OpenAI Codex CLI** - Cloud API
   - Source: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
   - Parses `token_count` events from session files
   - Mac legacy cost estimate assumes a 70/30 input/output split

3. **Google Gemini CLI** - Cloud API
   - Source: `~/.gemini/tmp/<hash>/chats/session-*.json`
   - Extracts tokens from message history
   - Mac applies a legacy model-based cost estimate

4. **Ollama** - Local Inference
   - Source: REST API at `http://localhost:11434`
   - Queries `/api/tags` for available models
   - Queries `/api/ps` for currently loaded models
   - Inventory/status only; no token usage or electricity cost measurement

5. **Hermes Agents** - Agent Orchestrator
   - Source: SQLite database at `~/.hermes/state.db`
   - Aggregates every model the agent ran (e.g. gpt-5.5, MiniMax, qwen, gemma, claude-opus)
   - Shows a per-model token breakdown under the Hermes line, sorted by usage
   - Cost read directly from Hermes (`actual`/`estimated_cost_usd`), never re-priced

### Quick Start

1. Build and run XRG-ng
2. Open Preferences → Graphs
3. Enable "Show AI Tokens"
4. Use Claude Code in another terminal
5. Watch live token consumption in the graph

For detailed documentation, see [README_AI_TOKENS.md](README_AI_TOKENS.md)

## Built-in themes (macOS)

Open **Preferences → Appearance → Built-in Themes** to apply **Classic**,
**Midnight**, **Ocean**, **Dusk**, **Paper**, or **Phosphor**. Presets update colors
and opacity immediately. **Classic** is the default macOS palette: the original
XRG theme's blue, gold and red graphs on black, with white text. Paper provides a
light background, while the other palettes offer dark alternatives. Existing
saved appearances keep their colors; choose Classic to apply it to an existing setup.

Customize any preset with the existing color wells and opacity sliders. **Load
Theme** accepts original `.xtf` files and portable `.json` palettes from Linux.
**Save Theme → Format** offers **Original XRG (.xtf)** and **Portable Mac/Linux
(.json)**; XTF remains the default. JSON palettes can move in either direction
between the two apps. Theme drag-and-drop and explicit application file-open also
accept JSON. Loading a palette applies colors and alpha without changing the
font, graph style, layout or monitoring settings. Untouched imported JSON colors
retain their original numeric precision and theme name when re-exported.
Wide-gamut Mac colors are converted and clipped to sRGB for portable JSON; XTF
retains the native color archives.

JSON support is available in the current macOS development build. The published
macOS 0.1.0 release still uses XTF only.

Portable files use `format: "xrg-ng-theme"`, `version: 1`, a printable name of
1–80 Unicode scalars, and seven sRGB RGBA arrays in window, graph background,
series 1/2/3, border and text order. Components must be finite values between
0 and 1; files are limited to 128 KiB. Both apps reject unknown fields, duplicate
fields and unsupported versions. Theme files contain palettes, not complete
cross-platform preference profiles. Shared compatibility fixtures exercise the
Swift and Rust readers against the same valid and invalid documents.

## Graph presentation (macOS development build)

Open **Preferences → Graphs** to reorder modules, toggle visibility, and customize
each graph. **Preferred height** accepts 64–240 points. Vertical layouts compress
these heights when space is limited; automatic graphs retain their minimum space.
Horizontal layouts align graphs at the top. Hidden graphs keep their position
and customizations for when you enable them again.

Each graph can override its background and three series colors, including opacity,
or inherit the global theme. **Curve fill** offers Solid, Pixel, Dot and Hollow;
**Inherit existing curves** preserves the original rendering. **Display effect**
independently selects Normal, Scanlines, Pixel Grid or Retro Dots, or inherits the
global Appearance setting.

**Apply** saves this panel; **Cancel** discards its draft. **Reset Selected** clears
the selected graph's presentation overrides. **Reset All** also restores the
original ordering; both leave visibility unchanged until you edit it explicitly.
Presentation overrides stay local and are not included in XTF or portable JSON
palette files. These controls are not included in the published macOS 0.1.0 app.

## Monitoring inspectors (development builds)

On **macOS**, **Preferences → Graphs** also offers optional **VRAM** and **Fans**
panels, both off by default. Each plots up to three sources with its own colors,
height and curve style. Right-click for **Choose Sources…**, read-only details or
**Reset Graph**. Automatic selection remains the default. Custom choices assign
reported sources to curves 1/2/3; **None** leaves a color slot empty. Apply saves
choices for that panel; Cancel or closing the window discards the draft. Source
selection changes display only and never writes fan or GPU controls. Additional
readable sources remain in details. The existing GPU and Temperature panels
retain their integrated readings.

Custom sources stay pinned when unavailable, with explicit labels and gaps instead
of substituting another device. Compatible returning sources resume after the gap;
changed source metadata starts a fresh curve, and changing memory axis units clears
history. Source changes preserve unaffected curves and use cached readings without
an extra hardware sample. **Reset Graph** keeps saved source choices.

VRAM choices use IOService locations when available. Driver/topology changes can
require reselection; fallback numeric registry IDs can change after reboot. Fan
choices use the collector's sensor keys. These platform-local IDs stay out of XTF
and portable JSON palettes. Invalid saved choices are preserved and use automatic
selection for the session until valid choices are explicitly applied.

VRAM shows driver-reported GPU memory pools as percentages when all plotted
adapters report usable capacity. Allocation-only readings, including Apple shared
or unified-memory allocations, use a byte scale labeled **GPU allocations**;
system RAM and GART apertures are not treated as installed VRAM. Fan curves show
actual RPM, including measured zero for stopped fans. Missing readings stay
unavailable, and neither panel changes hardware controls. Older custom graph
orders and overrides are preserved; the two new graphs append hidden to saved
orders. GPU/VRAM share collection within each graph tick, and Fans reuses the
existing fan cache even when the Temperature panel is hidden.

On **macOS**, right-click CPU or Memory and choose **Processes…**. The table
supports name/PID search, exact user-name filtering, CPU/memory/name/PID sorting
and a saved row limit. It refreshes every five seconds while open, shows failures
explicitly, and retains the last successful snapshot on collection failure.
Double-click a row or choose **Inspect Selected…** for live, instance-bound details:
state, parent PID, ownership, start time, threads, nice/priority, memory, lifetime
CPU time and interval CPU usage. Details refresh every five seconds while open.
The Mac table uses `ps`'s recent decaying CPU average; live details and Linux use
interval measurements. RSS can include shared pages. Neither arguments nor
environments are collected. Missing counters remain unavailable.

Mac live detail windows offer **Terminate**, **Force Kill**, **Pause** and **Resume**.
Every action requires confirmation with Cancel as the default. The reviewed audit
token identifies the target at signal delivery; there is no numeric-PID fallback
or privilege helper. macOS permissions and process protections still apply.
Delivery is reported separately from the next observed state. Exit, identity or
ownership changes stop live updates and disable actions, keeping the last details
visible. Failed reads retain details with an explicit error and disable actions
until recovery. Rows without a verified identity retain frozen, read-only details.
Closing an inspector closes its detail windows and cancels pending refreshes.

On **Linux**, choose **Sensors and statistics…** from the application menu or the
Temperature/Fans graph menu. View current/minimum/average/maximum temperatures
and fan RPM, copy a sensor report, or reset session statistics. Statistics include
all readable inputs regardless of graph selection, use sample-weighted averages,
and stay in memory for the current run. Missing readings show **n/a**; replacement
inputs start fresh statistics. Reset takes effect at the next sample and keeps
graph histories, source selection and sampling settings.

These inspectors are additions after the published macOS 0.1.0 / Linux 0.2.0
releases. See [platform parity](PLATFORM_PARITY.md) for remaining differences.

Linux development builds support **Ctrl+M** or a hostname double-click to collapse
the dashboard to a strip, with optional hover expansion in General preferences.
The **+** button expands it; explicit expansion keeps it open. Collection continues
while collapsed, and saved window dimensions retain the expanded size. Both graph
layouts are supported; Wayland placement remains controlled by the compositor.
See [Linux window behavior](xrg-linux/rust/README.md#collapsing-the-dashboard).

Linux development builds also provide **Clear graph history** in graph menus and
Live details, plus **Clear all graph histories** in the application menu. Network
and Disk display observed session transfers and offer a separate **Reset session
transfers** action. Clearing a plot preserves rates and totals; resetting transfers
preserves the plot. Source changes restart transfer sessions, and missed intervals
are explicitly marked as partial coverage. Raw kernel counters remain in details.

Mac Network/Disk now also offer **Transfer Details…** and **Reset Session
Transfers** in their graph menus. Details separate Rx/Tx or Read/Write observed
bytes from kernel counters; the compact faces retain their existing combined
byte totals and display **≥** for partial or saturated session totals. **Reset
Graph** preserves current rates, sampling baselines and transfer totals. Transfer
reset preserves the plot and rates; the next successful sample starts accounting
so the interval spanning the reset is excluded. Source membership/identity changes
or a counter restart begin a new session. Failed reads produce graph gaps and an
unavailable rate display; recovery rebaselines without importing missed traffic.
Network identity uses name/index, so reuse of both between observations cannot be
detected. Disk identity uses IOKit registry entry IDs. Totals remain session-only.

Mac CPU and GPU graph menus now include persistent **CPU Source** / **GPU Source**
choices. Defaults remain all logical CPUs and all discovered GPUs. Logical CPU
indices are zero-based kernel slots; GPU choices prefer IOService locations with
registry IDs as a fallback. Missing pins remain selected and show unavailable
instead of switching devices. Choices are native preferences, separate from themes
and from the optional VRAM/Fans selectors. Source changes use each source's cached
history without reading hardware or disturbing another graph.

The GPU menu also offers **Utilization Only**, which plots reported device busy
percent and leaves unsupported readings unavailable. **Memory + Activity** preserves
the existing view. Compact utilization uses one bar per selected GPU and an
unweighted mean when all selected utilization values are present; it is not a
combined-capacity measure. GPU **Reset Graph** clears only selected GPU histories
and preserves the latest readouts. Failed GPU reads append gaps and show `n/a`.
Read-only **CPU Details…** / **GPU Details…** explain scope and measurement limits.
Mac CPU's **Average** now uses the latest measured interval across selected logical
CPUs (0–100% aggregate capacity). The total remains core-percent, with up to 100%
per logical CPU. Graph width and historical padding no longer affect these readings.
**Reset Graph** clears CPU history while preserving current readings, source choice,
normal/fast baselines, fast-bar smoothing and availability; it does not read hardware.
Load, uptime and process listings remain system-wide when a core is pinned.

Set CPU, Memory, Network, Disk, GPU, NPU, VRAM, Temperature, Fans and Battery
retention through each Mac graph's **History** submenu or **Preferences → Sources → Retained … samples** on Linux. Explicit capacities
retain the newest samples and survive graph resizing without restarting rate or
paging measurements or session transfer totals. Automatic keeps the original defaults: graph width on Mac, 120 samples
on Linux. Linux accepts 1–20,000 samples; Mac offers presets and retains valid
custom counts. Displayed time spans are nominal: sampling delays and cadence
changes affect the actual span. The Mac Memory setting covers paging history;
Linux Memory retains RAM/cache/swap percentage curves. Their measurements remain
platform-specific. Source and failure resets keep their existing policies.
GPU activity, NPU quantities and VRAM use independent capacities. Device
replacement, activity-source and unit changes keep their existing history
boundaries; capacity changes never turn unavailable counters into activity.
Temperature and fan capacities are independent, including their sensor selection and
session statistics. The standalone Mac Fans graph has its own capacity; fan curves
inside Temperature share Temperature’s capacity. Battery retains charge and signed
power separately on Linux; Mac retains its charging/discharging watt curves. Missing padding stays unavailable,
valid cold temperatures and stopped fans remain readings, and retention changes do
not increase sensor polling cadence. Linux settings migrate to schema 38 in memory
and are written only on an explicit save.
CPU also offers **CPU Time Window** on Mac and **Preferences → Sources → CPU time
window** on Linux. Choose 1–60 minutes, or zero to use sample count. The window ends
at the latest completed normal CPU observation. Its grid follows the sampling target
with a minimum 200 ms spacing; centered bins tolerate ordinary scheduling jitter
without interpolating values. A one-minute window at 200 ms has 301 positions.
Gaps, warm-up and unavailable intervals remain missing. Fast bars, current readings
and rate baselines stay independent.

CPU timestamp memory is bounded to one hour / 20,000 observations per displayed
scope. Very fast legacy settings or forced refreshes can reach that count early.
Changing scope or topology starts a fresh timestamp history; existing sample-count
source policies remain. Mac views retain their own observed scope without inventing
timestamps for older miner data. Native window actions do not poll CPU counters;
Linux retains the system worker’s existing settings-wake behavior. Paused graphs
stay anchored to their last observation, and backward completion timestamps start
a new presentation era without altering counter baselines.

Network and Disk also offer independent **Network Time Window** / **Disk Time
Window** menus on Mac, and time-window fields in Linux Sources. Each supports
1–60 minutes (zero uses samples), with the same sampling-target grid, latest
completed observation anchor and one-hour / 20,000-observation bound as CPU.
Only normal observations enter these histories; fast bars, rate baselines and
session transfer totals stay independent. Window or capacity edits do not reset
transfers; resetting transfers does not clear the graph. Reset Graph clears the
time history, while source identity, membership and counter restarts begin fresh
sessions. Existing I/O baseline warm-up still reports zero rates. Failed reads
append missing observations. Linux hides unavailable series and retains its older
sample-mode failure reset, while time mode preserves earlier observations across
the gap and resumes on recovery. Mac retains earlier observations in both modes.
Native window actions do not poll counters; Linux keeps its system-settings wake
behavior. Choosing a Mac sample count returns to sample mode.

Memory also supports **Memory Time Window** on Mac and a time-window field in
Linux Sources: 1–60 minutes, or zero for samples. It uses the same sampling-target
grid, latest completed observation anchor and one-hour / 20,000-observation bound
per curve. Mac keeps its paging-event deltas and live RAM/swap bars; Linux keeps
independent RAM-used, cache/RAM and swap-used percentages. These measurements are
not equivalent across platforms. Window and cadence edits do not reset paging
baselines. Mac Reset Graph retains its existing baseline reset; Linux Reset Graph
preserves paging intervals. Failed Mac reads leave legacy samples/current readings
unchanged but add missing timestamp observations; recovery keeps the existing
cumulative paging delta across the gap. A decreased paging counter starts fresh
Mac time history without changing the existing per-counter delta rules. Linux
keeps its sample-mode failure resets and hides unavailable curves, while time mode
preserves earlier observations across gaps. Changes to total RAM clear RAM/cache
time history; configured swap capacity changes (including no swap) clear swap time
history. Missing optional counters remain gaps, and recovering with the same
capacity preserves earlier timestamp observations. Backward completion clocks
start a new graph era independently of paging state. Native window actions do not
poll memory counters; Linux retains its system-settings wake behavior.

GPU also supports **GPU Time Window** on Mac and a Linux Sources field, with
1–60-minute windows (zero uses samples), the sampling-target grid and the same
one-hour / 20,000-observation bound per device. Mac projects its native VRAM,
CPU-wait and utilization channels; Linux projects each device’s selected activity
quantity. These quantities retain their existing units and meanings. Current
readings and mini bars remain independent. Device replacement, driver/activity
source changes and unavailable-source resets retain their existing boundaries.
Mac failed polls add gaps and retain prior observations; Linux unavailable activity
keeps its existing history reset. Changing windows does not poll counters on Mac;
Linux retains its settings-wake behavior. Sample counts remain saved as fallback.
Standalone VRAM windows are described below.

NPU also supports **NPU Time Window** on Mac and a Linux Sources field: 1–60
minutes, zero uses samples, with the same sampling-target grid and one-hour /
20,000-observation bound per quantity/source. Mac timestamps accepted asynchronous
telemetry only; duplicate callbacks or timer ticks do not invent observations.
Residency (%), measured power (W) and traffic reports/s retain separate histories
and axes. Traffic remains a narrow marker band, not utilization. Existing stale,
invalid, device, energy-unit and traffic-source reset policies remain. Linux keeps
device/client activity percentages separate from unscoped producer inference
rates, preserving existing mode/source and unavailable-activity boundaries. Graph
resets clear both Linux history modes. Window edits preserve collector baselines;
current readings remain independent. Cadence changes do not accelerate the telemetry
producer. Standalone VRAM windows are described below.

Standalone VRAM supports **VRAM Time Window** on Mac and a Linux Sources field:
1–60 minutes, zero uses saved sample counts, with the same sampling-target grid
and one-hour / 20,000-observation bound per pool. Mac retains reported pool
percentages or allocation bytes under its existing all-plotted-sources unit rule;
Linux retains driver-reported pool percentages only. Client allocations do not
become pool capacity. Capacity, driver/metadata, unit and replacement changes keep
their existing reset boundaries. Automatic disappearance/failure clears histories
as before; Mac pinned missing sources append gaps. Source-menu edits use cached
readings and do not invent timestamp observations for newly selected sources.
Graph reset clears both modes, while current readouts and sample fallback remain
independent. Mac Fans retains separate settings; its time-window controls are described below.

Standalone Fans supports **Fans Time Window** on Mac and a Linux Sources field:
1–60 minutes, zero uses saved sample counts, with the same sampling-target grid
and one-hour / 20,000-observation bound per physical input. Curves retain RPM;
zero remains a stopped fan, and PWM duty is not converted into RPM. Source
replacement/disappearance and failure policies remain: Mac pinned missing inputs
append gaps, while automatic disappearance and Linux unreadable inputs discard
the affected histories. Graph reset clears both modes and preserves current
readouts and temperature/session statistics. Mac Fans and VRAM window settings
are independent. Temperature’s integrated fan curves retain Temperature’s own
history behavior; Temperature and Battery time windows remain follow-up work.

AI retention is separate. Sample-count mode uses the Mac **AI History** menu or
Linux **Preferences → AI → Retained AI samples**. Its original automatic choices
remain: Mac graph width minus the indicator strip, or 120 samples on Linux. At
five-second cadence, 300 samples have a nominal span of 1,495 seconds.

For actual time coverage, use Mac **AI Time Window** or Linux **AI time window
(minutes; 0 uses samples)**. Windows support 1–1,440 minutes, ending at the latest
completed observation. Five-second bins show the latest recorded value in each
bin; time bins without observations stay gaps. Delayed scans no longer compress
that elapsed time into adjacent points. A paused or frozen graph remains anchored
to its last observation until another completes. Rates still use their existing
interval clock; retention uses completion timestamps. Backward completion timestamps
start a new graph-history era; rate state and existing calendar/accounting rules
remain independent.

Up to 24 hours and 20,000 timestamped observations are retained in memory, including
while sample-count mode is selected. Very dense manual refreshes can reach that
observation limit before 24 hours. Legacy sample buffers remain separate; index-only
samples are never assigned invented timestamps. Choosing a Mac sample count returns
to sample mode; Linux uses a zero-minute window. Retention edits preserve counters,
alerts, source choices, pricing and the next sampling deadline. An ongoing scan
remains valid; source/accounting edits and counter resets keep their refresh behavior.

Both builds support sampling targets from 200 ms to 10 seconds. Mac edits retain
millisecond precision; existing valid Mac preferences outside that range remain
intact when opened/saved. AI collection keeps its separate five-second cadence.

CPU warm-up, failed reads and zero-progress intervals show `n/a` and graph gaps;
measured idle remains a valid 0%. Recovery establishes a fresh baseline before
reporting an interval. All selected cores need valid intervals for an aggregate
readout; a valid pinned core remains usable when another core has no interval.
Normal and fast sampling fail/recover independently. CPU inventory count changes
clear histories and invalidate both streams to avoid mixing logical-slot histories.
Both builds retain CPU observations around missing intervals and reject intervals
over five minutes. Mac's continuous clock includes sleep; Linux's elapsed clock
excludes suspend. OS tick accounting and topology/wrap policies still differ;
Mac retains its stacked system/user/nice presentation.
The shared Mac renderer now segments missing intervals even with the default curve
style, so cleared/read-failure gaps do not draw ramps or extend stale values to the
latest time. Fully measured histories retain the existing default rendering.
CPU indices may remap after topology changes/reboot, and GPU registry IDs may change
on reboot. Actual replacement GPU registry instances start fresh histories.

## Building

### macOS

**Requirements:**
- Xcode 26.3 or newer with the macOS SDK and Command Line Tools selected
- macOS 26 or newer to run the app and tests; Intel and Apple silicon builds remain supported.

This checkout includes local signing and bundle-identifier changes. Select your own development team in Xcode for signed builds. For a compile-only check without a signing identity:

```bash
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The app product and shared launch scheme are `XRG-ng`; internal `XRGCore`/`XRGTests` modules and preference identifiers remain stable.

See [the modernization review](MODERNIZATION.md) for the current baseline, fork-specific issues, and remaining work.

**Tests:** Select either shared scheme (`XRG-ng` or `XRGTests`) in Xcode and choose Product → Test. The macOS suite links the same static Swift `XRGCore` framework as the app and uses temporary preferences suites. Coverage includes built-in theme application and file round trips, settings, collectors, provider parsers, graph rendering, native interfaces and application lifecycle.

**Continuous integration:** [The macOS workflow](.github/workflows/macos.yml) builds universal Apple Silicon/Intel apps and runs native and Rosetta x86_64 tests for both Debug and Release on pushes, pull requests, and manual dispatch. It uses Xcode 26.6 on `macos-26`, requires no signing secrets, and retains logs and test results for seven days. Separate composition and packaged-app smoke checks use disposable preference domains. These are compile/test builds, not signed distribution packages.

Run the same checks locally with your selected Xcode:

```bash
bash Tools/ci-macos.sh Debug
bash Tools/ci-macos.sh Release
```

Each run prints a temporary directory containing its build output, logs, and `.xcresult` bundle. The script fails on build/test errors or an empty test run. Remove that directory when you no longer need the results. Command-line tests require access to the macOS test runner service; in restricted environments, run the tests from Xcode instead.

**Build Commands:**

```bash
# Build
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng build

# Clean and rebuild
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng clean build

# Open in Xcode
open XRG-ng.xcodeproj
```

### Linux

The active build uses **Rust + shared Swift + egui/eframe**, with OpenGL and
X11/Wayland support. It has no GTK, GSK, Cairo or GLib frontend dependency.
Build natively on x86_64 or ARM64 with Swift 6.3+ (CI: 6.4.1), Rust 1.99.1,
a C compiler, pkg-config and the windowing/graphics libraries listed in the
[Linux build guide](xrg-linux/rust/README.md#build-and-run).

From the repository root:

```bash
cargo run --manifest-path xrg-linux/rust/Cargo.toml --features egui-ui
# Toolkit-independent diagnostics:
cargo run --manifest-path xrg-linux/rust/Cargo.toml -- --headless --samples 3
```

Linux 0.2.0 release packaging supports x86-64 and ARM64 `.deb`, `.rpm`,
`.pkg.tar.zst`, `.AppImage` and relocatable archives with the Swift runtime included.
See the [installation guide](xrg-linux/preview/README.md) and
[release verification instructions](signing/README.md). No Swift or Rust toolchain
is needed to run the packages. CI continues to produce unsigned development previews.

The obsolete C/GTK application and archived GTK frontend have been retired from
the checkout. The Rust/Swift implementation is the only Linux build path.
[Retirement notes](xrg-linux/RETIREMENT.md) document the historical revision and
legacy-settings import; existing installed files and settings are preserved.

## License

Project code uses **GNU GPL version 3 or later (GPL-3.0-or-later)**. See [LICENSE](LICENSE), [COPYRIGHT](COPYRIGHT), and [third-party notices](THIRD_PARTY_NOTICES.md).

The current macOS sensor backend uses first-party GPL code in place of the former
APSL-derived implementations, vendor headers and sensor-name catalog. Existing
sensor keys remain the preference identities, with generated SMC labels; Apple HID
product labels remain available. Relative-to-limit legacy SMC channels are not
presented as absolute temperatures. Signed/fractional SMC values now follow their
numeric formats rather than legacy decoder special cases. Compatible third-party
dependencies retain their required notices. Historical releases keep the licenses
and notices attached to their corresponding source revisions.

## Credits

- **Mike Piatek-Jimenez / Gaucho Software, LLC — 2002–2024:** original XRG creator.
- **Marc Shade — 2025–2026:** fork maintenance, AI token monitoring, and Linux port.
- **Stephen de la Vega — 2026–present:** XRG-ng maintenance and Swift migration.
- Other contributors retain their source notices and Git attribution.
