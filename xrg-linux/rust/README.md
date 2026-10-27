# Linux Swift / Rust transition

This is the GTK 4 replacement in progress. It runs alongside the C/GTK3 application
in `../src`; the C executable and its `~/.config/xrg-linux/settings.conf` remain
available. The new executable is `xrg-ng-linux`, version 0.1.0. It currently shows
aggregate CPU, memory, network receive/send, physical-disk read/write, system
battery capacity, temperature, GPU activity, AI token-rate, process-count and
Coral TPU inference-rate, VRAM pool and fan RPM graphs, with per-core/interface/disk/GPU selection and a
sortable, filterable process table.
An opt-in **Weather** window shows station observations using the shared Swift
METAR decoder, with saved station, units and refresh controls.
This is an initial vertical slice, not feature parity with the C application.

## Hardware support and feedback

This port is a **best-effort attempt** across supported architectures and GPU/driver
families. We do not own most of these platforms and cannot physically validate
them all. The support matrix documents implemented interfaces and their limits;
automated fixtures and native x86_64/ARM64 CI verify software behavior, while
real-device coverage depends on available hardware and community reports.
Physical validation of every platform is not a release prerequisite.

**Feedback is welcome and encouraged.** Reports of working setups are useful too.
Please [open an issue](https://github.com/sdelavega/XRG-ng/issues) with the app
version/commit, distribution, kernel, CPU architecture, GPU/device model and driver,
plus expected/observed results and relevant diagnostics. Corrections, driver details
and contributions are welcome. See the [project support policy](../../README.md#hardware-support-and-feedback).

## Construction

- **Shared Swift:** the *same source files* compile into macOS's XRGCore target and
  the root Swift package, XRGSharedCore. Ring buffers retain Accelerate on macOS
  and use Swift arithmetic on Linux. Rate tracking, Claude/Gemini/Codex/local
  provider parsers, METAR decoding and the six macOS theme palettes are shared.
  AppKit, macOS collectors, Objective-C selectors and XTF archives stay in XRGCore.
- **C ABI:** `Shared/Bridge/XRGCBridge.swift` exports versioned `@c` functions;
  `Shared/include/xrg_shared.h` documents ownership and capacities. No C
  implementation or shared Swift/Rust object layout is required. The first ABI
  exposes histories, rates, themes, provider usage records, local metrics and model
  inventories, model-attributed usage records, station validation and dated METAR observations. Missing weather
  values have explicit validity flags, so a valid zero is not treated as absent.
- **Rust:** owns `/proc` and `/sys` collection, GTK4/Cairo drawing, configuration and
  lifecycle. System and AI workers create/own their mutable Swift handles. They send only copied
  Rust snapshots through bounded latest-value slots; GTK touches them on its main
  thread. No shell commands, provider scans or collection run in drawing callbacks.
- **Preferences:** graph visibility/order, height, metric sources, process filters, AI sources and weather
  and theme colors are saved in
  `$XDG_CONFIG_HOME/xrg-ng/settings.conf` (or `~/.config/xrg-ng`). All six shared
  presets remain selectable alongside a custom palette. The editor supports
  portable JSON theme load/save; details are below. Legacy C settings stay separate.

CPU calculations exclude guest time already included in user/nice. Memory uses
MemAvailable. Network aggregates non-loopback interfaces (bridges/VPNs may count
traffic more than once); disks aggregate whole non-loop/ram/zram/dm/md devices to
avoid counting partitions and stacked devices twice. Rates use elapsed monotonic
time and the shared reset/saturation policy. Disk/network labels show read/receive
first, write/send second. First CPU sample waits for an interval. Failed collection
shows an error rather than recording fabricated zeros; CPU/network/disk source
failures clear their plotted histories and establish a fresh interval on recovery.

Battery collection reads system power supplies, skips HID/HID++ names before
opening attributes, and excludes `scope=Device` and absent batteries. Each percent
uses a complete energy or charge pair; a bounded capacity percent is the fallback.
Up to three batteries have separate histories keyed by device name, with status
and available power readings in tooltips. There is no battery aggregate.
Details include reported full/design capacity (which can exceed
100%), driver health condition, cycle count and time to empty/full when available.
Driver time values take precedence; otherwise estimates use a complete energy/power
or charge/current pair in matching micro-units. Current magnitude is used with the
explicit charging/discharging status. Zero/missing rates do not become infinite or
fabricated countdowns. Full/not-charging/unknown states have no countdown. Estimates
are instantaneous and change with load/charge rate; they are not a prediction of
future use. Optional malformed attributes preserve capacity and are reported in
details. No health or time values are combined across batteries.

The **Fans** graph reads standard hwmon `fan*_input` RPM, plotting up to three
channels with further readings in details. Zero is a valid stopped-fan reading;
disabled/faulted channels are omitted rather than plotted at zero. Driver alarm
flags are reported separately. Canonical path/channel/inode identity prevents class
aliases duplicating a sensor and resets histories after disappearance/replacement.
Scanning has a cooperative 100 ms / 256-channel budget, bounded directory/attribute
reads, and explicit partial-coverage errors. Fan details are capped at 64 channels.
Driver labels do not establish CPU/GPU ownership. PWM values are not RPM, and this
collector never writes fan controls or guesses board-specific calibration.

Temperature collection reads standard hwmon temperature channels, honors disabled
and fault flags, and falls back to thermal zones if no hwmon values are usable.
The graph shows the maximum readable temperature; tooltips list individual sensors.
Negative temperatures use a signed graph range. Channels marked as thermistors
(`tempN_type=4`) are excluded until calibrated conversion is supported, since some
report voltage rather than Celsius. This initial reader does not apply libsensors
configuration/compute rules. See the kernel's
[power-supply ABI](https://docs.kernel.org/power/power_supply_class.html) and
[hwmon interface](https://docs.kernel.org/hwmon/sysfs-interface.html).
Missing optional hardware shows an explicit absence label and no fabricated zero
series; read failures show unavailable/partial labels. Neither makes core-only
headless or live GTK smoke checks fail on desktops/containers without that hardware.
The graph area scrolls on small windows and exposes details to accessibility APIs.

The **VRAM** graph displays the driver-reported VRAM pool used as a percentage of
each adapter's reported total (up to three adapters). Activity and memory share one collector
sample and the **GPU and VRAM** source selector. AMD/NVIDIA counters feed this view
when available; activity need not be available to plot memory. Missing/invalid
totals produce no memory series. These counters describe the driver's VRAM pool
and do not identify the physical memory topology. Unified system memory and
readable-client allocation totals are not used to infer VRAM capacity. Histories reset on source, capacity, driver or availability changes.

GPU discovery uses DRM primary/render nodes and recognized platform GPU drivers;
compute-only NVIDIA devices also use bound PCI discovery. Canonical platform or
PCI identity keeps histories stable when node numbering changes. Connector nodes
are excluded and primary/render/platform aliases are deduplicated. Up to three
adapters with supported activity readings are graphed.
Memory, clock, temperature, power and fan readings appear in accessible tooltips
when available. Power reported by hwmon may cover a whole SoC, including its CPU.

| Backend | Available acquisition |
| --- | --- |
| AMD amdgpu | Documented busy percentage, VRAM bytes, GPU hwmon telemetry |
| NVIDIA nvidia | One bounded `nvidia-smi` query, matched by PCI address |
| Intel i915 | Reported clock and available hwmon telemetry; utilization unavailable |
| Intel xe | Available hwmon telemetry; utilization unavailable |
| Mali panfrost / panthor | Owned devfreq clocks/load when provided, readable DRM-client activity and resident allocations; client activity needs profiling |
| Mali lima / vendor Mali | Identification, owned devfreq/hwmon, vendor devfreq load where provided, readable DRM-client stats where exported |
| Adreno mainline MSM | Owned GPU devfreq/hwmon and readable DRM-client engine stats |
| Adreno vendor KGSL | `gpubusy` busy/total interval and `gpuclk` Hz, including KGSL class-device layout |
| Apple AGX / Asahi | Platform/render-node discovery and available devfreq/hwmon/client stats; unexposed utilization stays unavailable |
| Broadcom V3D / Vivante etnaviv / PowerVR | Platform/render-node discovery and available devfreq/hwmon/client stats |
| nouveau / other drivers | Identification; unsupported counters remain unavailable |
| Runtime-suspended adapters | Identification only; telemetry reads/commands are skipped |

Intel utilization needs a future PMU/performance-counter backend. Clock frequency
is never converted into an estimated busy percentage. There is no simulated GPU
fallback. Actual zero utilization is retained; unsupported, malformed or absent
values create no synthetic idle samples. NVIDIA `N/A` fields remain unavailable,
and duplicate/invalid PCI rows cannot attach telemetry to another adapter.

ARM platform GPUs do not need a PCI vendor file or a primary DRM card. Device-tree
compatibles identify the GPU model when supplied. MSM display masters are linked
to separately bound Adreno GPUs only for an unambiguous one-to-one pair; display
controller clocks/sensors are never treated as GPU telemetry. Devfreq aliases are
read only when their canonical owner belongs to that GPU. Clock frequency never
becomes a utilization estimate. KGSL intervals require `0 <= busy <= total` and a
nonzero total; `0 0` means no measurement.
Rockchip-style devfreq `load` samples (`percent@frequencyHz`) provide measured
whole-device activity when the GPU owns exactly one domain. Empty, malformed,
out-of-range or zero-clock samples remain unavailable. Multiple domains are not
guessed to represent graphics load, and this path does not require DRM profiling.


DRM fdinfo is **per-client accounting**, not a global device utilization counter.
The scanner reads permitted `/proc/<pid>/fdinfo` records associated with known GPU
nodes, deduplicates inherited/shared FDs by device and DRM client ID, and computes
the busiest observed engine after normalizing its declared capacity. The UI marks
those graph values with `clients`; counter-source changes reset the history rather
than splice different quantities. First observations, temporary counter regressions,
inconsistent capacity and delayed intervals above elapsed capacity do not produce
invented load. Resident allocations are separately labeled readable-client data;
shared buffers can count once per client. System RAM is never reported as dedicated
VRAM. Protected/exiting clients and short-lived workloads can be missed.

The proc scan has a 50 ms cooperative budget, 4096 directory-entry / 8192 FD limits
and 64 KiB record cap. Permissions, transient failures and budget truncation are
reported as partial coverage. Like other kernel reads, an individual fdinfo callback
cannot be hard-cancelled by this userspace budget. Mali Panfrost needs profiling
set to 1; Panthor needs timestamp bit 2. XRG-ng only reads these controls and does
not enable profiling or change governors, clocks or power state. Without suitable
published counters (including on current Asahi configurations), the adapter is
identified while unavailable statistics remain explicitly unavailable.

NVIDIA requires both its PCI vendor ID and the bound `nvidia` driver before any
command runs. This includes NVIDIA's open kernel module, whose driver name is also
`nvidia`; nouveau never launches SMI. The executable is resolved from absolute PATH
entries. Queries use fixed arguments without a shell, a 750 ms deadline, a 64 KiB
stdout limit, nonblocking pipes and process-group termination. A 25 ms bounded reap
poll handles normal killed children. An uninterruptible child is retained for later
reaping and prevents replacements; final cleanup does not block application exit.
Failures back off for 30 seconds. Custom fixture roots never execute system commands
unless an explicit test executable is supplied to GpuCollector. These limits cover
the external query, not arbitrary stalled kernel sysfs reads.

Sources: [DRM client accounting](https://docs.kernel.org/gpu/drm-usage-stats.html),
[Panfrost profiling](https://docs.kernel.org/gpu/panfrost.html),
[Panthor profiling](https://docs.kernel.org/gpu/panthor.html),
[Asahi driver](https://github.com/AsahiLinux/linux/blob/asahi/drivers/gpu/drm/asahi/driver.rs),
[Rockchip devfreq load interface](https://github.com/rockchip-linux/kernel/blob/develop-5.10/drivers/devfreq/devfreq.c),
[AMDGPU monitoring ABI](https://kernel.org/doc/html/latest/gpu/amdgpu/thermal.html),
[NVIDIA query documentation](https://docs.nvidia.com/deploy/nvidia-smi/index.html).

## Build and run

For an installable preview, download the native `linux-ubuntu-24.04-preview`
(x86_64) or `linux-ubuntu-24.04-arm-preview` (ARM64) artifact from a successful
[Linux workflow](https://github.com/sdelavega/XRG-ng/actions/workflows/linux.yml).
Each contains an archive and SHA-256 checksum. The included
[preview instructions](../preview/README.md) cover dependencies, direct launch,
per-user desktop installation, upgrades and uninstall. Swift/Rust toolchains are
not needed to run these archives. Previews retain version 0.1.0 and are separate
from the published macOS release.

On Linux install **Swift 6.3+** (CI: 6.4.1), **Rust 1.99.1**, pkg-config, a C compiler
and **GTK 4.10+** development libraries. GTK4-rs is locked through Cargo.lock. On
Ubuntu 24.04 the GTK package is `libgtk-4-dev`. The build script builds and links the
Swift package automatically. CI supplies `XRG_SHARED_LIB_DIR` to link the exact
Swift library already built and tested by the script. The override must be an
absolute directory containing the matching native/configuration library; its
freshness is the caller's responsibility. Native builds are required; setting a foreign Cargo
`--target` does not cross-compile the Swift side.

From the repository root:

```bash
swift test
cargo test --manifest-path xrg-linux/rust/Cargo.toml --locked
cargo run --manifest-path xrg-linux/rust/Cargo.toml --features gtk-ui
cargo run --manifest-path xrg-linux/rust/Cargo.toml -- --headless --samples 3
bash Tools/ci-linux.sh debug
bash Tools/ci-linux.sh release
```

The core-only Cargo build also works on macOS without GTK, for FFI and parser tests.
Live collectors and the GTK application require Linux. Development binaries have a
build-directory rpath for XRGSharedCore; a distributable package must bundle or
install the matching Swift runtime and shared library. Moving the executable alone
is not a supported installation.

For isolated Linux validation on another host:

```bash
docker build -f xrg-linux/Dockerfile.swift-rust -t xrg-ng-linux-dev .
docker run --rm -v "$PWD:/workspace" xrg-ng-linux-dev
docker run --rm -v "$PWD:/workspace" xrg-ng-linux-dev bash Tools/ci-linux.sh release
```

CI runs natively on x86_64 and ARM64 Linux in Debug and Release. It runs Swift tests, a C header/ABI executable, Rust formatting/Clippy/tests, three
live headless samples, and a GTK/Xvfb launch that requires multiple live samples
and actual Cairo draw callbacks. The GTK check switches Paper/Ocean presets,
opens Preferences, tests invalid drafts/imports and Cancel/Apply, exports/reloads
a custom theme, reorders/hides graphs, recovers from an all-hidden layout and reopens
saved settings. It also selects live metric sources, opens the process table,
checks invalid UID handling, filters to its own process and reopens saved filters.
The AI window checks invalid paths/URLs, applying/reopening provider settings,
discarding drafts, stale-report suppression, and preservation of AI sources when
restoring graph defaults. It renders a clearly labeled synthetic usage/model fixture
without scanning provider data. The model fixture exercises the production detail
formatter, including unattributed tokens, recorded Hermes costs and unsupported
attribution. Weather checks invalid station rejection, normalized
Apply/reopen, draft discard, old-station suppression and preservation when restoring
graph defaults, using an explicitly labeled fixture with no network requests.
Graph menu checks emit GTK mouse/key signals, test live details/source guards,
hide/reorder/show-all persistence and existing window actions, including About.
Legacy import checks invalid input, preview cancellation, draft cancellation,
Apply/reopen, unchanged source bytes and closing during an asynchronous read.
The main window, preferences, process table, both AI tabs, weather window, graph
menu, live details and legacy import preview are
exported as PNGs. Smoke
mode uses temporary settings/theme files and never reads or writes user preferences.
Xvfb uses Cairo, so this does not validate accelerated rendering, Wayland compositor
behavior, screen readers or physical-device collection. Linux build output is
separate from host Swift output when using a shared Docker checkout.

Release jobs also package the exact tested binary/Swift library with the resolved
Swift runtime closure. ELF RUNPATHs are changed to `$ORIGIN` paths; GTK, glibc,
graphics drivers and their system dependencies remain external. Packages include
licenses, a manifest with commit/toolchain/input hashes, and corresponding source
with vendored locked Cargo dependencies. Offline Cargo resolution is checked in
an empty cache. The package baseline is Ubuntu 24.04, rather than all Linux
distributions. Runtime checks run as an unprivileged user in a separate Ubuntu
24.04 container with no Swift or Rust installation. They verify archive checksums,
relocation, private library resolution, desktop Exec parsing, a full installed GTK
smoke flow, upgrade/uninstall and preservation of unrelated files/preferences.

To package an already-tested native Release build:

```bash
python3 Tools/package-linux.py --binary /absolute/path/to/release/xrg-ng-linux \
  --swift-library /absolute/path/to/libXRGSharedCore.so
```

Packaging needs Python 3.11+, patchelf, desktop-file-utils, native Swift 6.4.1,
Rust/Cargo and a clean committed checkout. CI passes the paths emitted by
`Tools/ci-linux.sh release`, so it never builds Swift again during packaging.
The default output is `dist/linux/`. `--allow-dirty` is for local development only
and marks the source snapshot accordingly. To repeat runtime validation locally:

```bash
docker build -f xrg-linux/Dockerfile.preview-test -t xrg-ng-preview-test .
# Make /absolute/results writable by container UID 10001.
docker run --rm -v /absolute/download:/download:ro -v /absolute/results:/results \
  xrg-ng-preview-test --archive /download/xrg-ng-0.1.0-linux-aarch64-preview.tar.gz \
  --results /results
```

## Graph actions and live details

Right-click any graph, or focus it with Tab and press **Shift+F10** or the
**Menu** key. The GTK4 menu shows the latest copied summary and offers **Live
details…**, **Graph preferences…**, **Move up/down** and **Hide graph**. AI and
process graphs also link to their dedicated windows. Moving a graph updates the
saved graph list, including hidden entries. Hiding and reordering preserve its
sampling/history and the existing source, theme, AI and weather choices.

Live details update from worker snapshots even while a graph is hidden. Each
module has one details window; opening it again presents the existing window.
Changing a metric source clears the old details immediately and waits for a
matching sample. Missing hardware and read errors retain their explicit status.
Opening menus or details performs no collection, filesystem scan or HTTP request.
The menu summary is a snapshot taken when opened; the details window stays live.

The toolbar's **Application menu** opens Preferences, Processes, AI monitoring,
Weather, About and Quit. **Show all graphs** restores visibility while preserving
order and other preferences, including when every graph has been hidden. Layout
actions use the existing asynchronous settings writer and persistence-error
handling. Graph focus has a visible outline for keyboard navigation.

## Importing legacy Linux settings

Open **Preferences → Import legacy Linux settings…** and choose the C/GTK3 app's
`settings.conf`. The chooser starts at `$XDG_CONFIG_HOME/xrg-linux/settings.conf`
or `~/.config/xrg-linux/settings.conf`. Import is explicit; startup never reads or
converts that file automatically.

A preview lists the supported values and every entry not transferred. **Cancel**
keeps the current draft. **Import into draft** lets you inspect/edit the result;
the main window and saved settings change only after **Apply** in Preferences.
Cancelling Preferences discards the import. The legacy source is read-only and
remains available to the C app; saves use the Rust app's normal `xrg-ng` settings
path and existing atomic/background writer and persistence-error handling.

The importer transfers the ten legacy graph visibility flags and the seven global
colors: background, graph background, three series, border and text. It also
transfers `[Display] layout_orientation` (0 vertical, 1 horizontal) and
`[Temperature] units` (0 Celsius, 1 Fahrenheit). Imported
colors become an embedded custom theme, retaining alpha and black/zero values.
The legacy theme name supplies a label only; palettes are never guessed from a
matching preset name. A name without color entries leaves the current theme intact.
Partial files keep current draft values for missing fields. New VRAM/Fans
visibility, graph order/height, metric sources, process filters, AI sources and
weather remain as configured. A legacy weather visibility flag does not enable
requests. The main window background stays opaque as with other custom themes.

Window geometry/pinning/opacity, activity bars, module-specific
colors/styles, billing and unrecognized entries are listed as
not transferred. Unsupported values are not echoed in the preview. Invalid
supported booleans, colors, layout or unit values reject the entire import and
leave the draft unchanged.
Files containing no supported visibility/color/layout/unit entries are rejected.

Parsing follows the C writer's GLib key-file layout: UTF-8, case-sensitive grouped
keys, `#` comments, lower-case `true`/`false`, repeated-group merging and last-key
precedence. String escapes support `\\`, `\s`, `\n`, `\r` and `\t`. Colors accept
the C writer's `rgba(R,G,B,A)` (RGB 0–255, alpha 0–1), `rgb(R,G,B)`, and 3/4/6/8-digit
hexadecimal RGB/RGBA; other CSS color spellings require conversion first. Reads
and parsing run off GTK's thread, using regular local files with final-component
symlinks/special files rejected. Limits are 128 KiB, 4,096 lines, 8,192 bytes per
line, 1,024 distinct entries and 128 bytes per key/group name. Closing Preferences
while a read is in flight prevents a late preview or draft change.

## Graph and theme preferences

The toolbar provides all six built-in presets and **Preferences…**. The Custom
entry opens the editor when a built-in preset is active. In Preferences:

- Check which graphs to show; use **Up/Down** to arrange them.
- Set graph height between 64 and 240 pixels.
- Choose **Vertical** (stacked) or **Horizontal** (side by side) layout. Ordering
  controls become Left/Right horizontally; graph menus use the same order.
- Choose **Celsius** or **Fahrenheit** for system sensor, GPU and TPU temperatures.
  Graph labels, tooltips, accessibility text and open live details update together.
  Collector/history values stay Celsius; unit changes preserve history and graph
  shape. Missing readings stay unavailable. Weather has its own units setting.
- Choose aggregate or individual CPU, network, disk and GPU sources. **Refresh
  source lists** uses the latest collector inventory without discarding the draft.
- Select a preset, name a custom palette and edit its seven colors.
- Use **Load theme…** and **Save theme…** for local portable JSON files.
- **Apply** uses the draft and saves preferences; **Cancel** keeps the active layout
  and colors. **Restore defaults** changes the draft until Apply is pressed.

Hidden graphs continue sampling, preserving their histories. Ordering changes the
presentation while each graph retains its original collector. An all-hidden layout
shows a recovery message and keeps Preferences accessible. Headless diagnostics
continue reporting all collectors independently of these presentation preferences.
Graph height is a minimum; small windows scroll. Horizontal graphs retain at
least 360 pixels each and scroll sideways, with vertical scrolling when needed.
Window placement/pinning is not part of these preferences.

CPU choices use logical core IDs. Network choices include loopback, while the
default aggregate excludes it. Individual disks include partitions and stacked
devices; the default aggregate uses whole physical devices as described above.
GPU choices retain the collector's adapter identity; the default displays up to
three adapters. A saved source that disappears stays selected and shows unavailable
until it returns or another source is chosen. It never silently changes to an
aggregate. Changing sources resets the affected history. Network/disk membership,
identity changes and counter resets establish a fresh rate baseline; device
replacement detection is limited by the identity metadata the kernel exposes.

Custom theme files use the suggested `.xrg-theme.json` extension. Exporting a preset
provides a valid starting document. The format contains `format: "xrg-ng-theme"`,
`version: 1`, a printable name of 1–80 characters and `colors`: seven RGBA arrays in
**background, graph background, series 1, series 2, series 3, border, text** order.
Each component must be finite and between 0 and 1. Alpha is retained in files and
used for graph layers; the window background stays opaque. JSON numbers preserve
round-trip precision. Editing a theme name does not quantize untouched colors to
the color picker's display precision.

Loading validates the whole document before changing the draft; errors leave its
previous values intact. Theme reads/writes run outside GTK's main thread. Files
are limited to 128 KiB and must be regular local files without final-component
symlinks. Built-in presets remain available after using custom colors. A custom
palette is embedded in saved preferences, so reopening does not depend on the
original imported file. XTF conversion remains follow-up work; legacy Linux import
is available as described above. The macOS application's
XTF load/save behavior is unchanged.

Settings use version 6 JSON in the existing `settings.conf` path. Version 1/2 JSON
still loads, preserving graph order/visibility, theme and existing source/process
controls. VRAM and Fans are appended **hidden** when upgrading these layouts; enable
them in Preferences. An all-hidden layout stays hidden. New installations show all
twelve graphs by default. Version 3 layouts also load, adding default AI source
controls. Versions 1–4 gain weather settings with requests **disabled**. Existing
AI sources, layouts and themes are preserved. Versions 1–5 gain vertical layout
and Celsius defaults; existing settings are upgraded without immediate writes.
The earlier Rust `theme=Ocean` format also loads with
default controls. Formats upgrade only when preferences are next saved.
Writes use private temporary files and atomic replacement; a single background
writer coalesces pending changes and flushes the latest value on normal shutdown.
Invalid, unreadable or unsupported settings files are preserved for the session:
changes can still apply in memory, and the status explains that saving failed.
Correct or move the file and reopen the app to enable persistence. Edits made by
another process are detected before saving and require reopening rather than
silently replacing the external changes. No legacy C settings file is modified.


## AI monitoring

The eighth panel graphs **observed token-counter change per second**, polling every
five seconds on a separate worker. Core graphs keep their one-second schedule even
when provider scans or local APIs are slow. Tooltips/accessibility details show each
provider's locally retained token total, rate, source, recorded cost when available,
and errors. These totals are not account billing or a billing-period summary;
batched log writes produce bursts in the graph.

**AI…** in the toolbar opens **Usage and models** plus a **Sources** tab. Usage
shows provider totals, observed rates, selected source, recorded costs and errors.
It also shows **token totals by model** for Claude logs, Gemini logs and Hermes
sessions, plus installed/loaded Ollama model names (up to 128 per list). Ollama
lists remain inventories; they do not supply token counts.

Claude model attribution follows the same message-ID replacement and cross-file
deduplication as its provider total. A replacement changes the count and model
together. Gemini uses each message's recorded model, falling back to the legacy
session-level model when absent. Its explicit total is preserved even when it
differs from input plus output. Missing, blank, control-containing or overlong
model names keep their tokens in **Unattributed**. Valid names retain their exact
case and spelling; model names are quoted in the detail view.

Hermes groups the existing nonempty-model session rows, keeping actual-cost
precedence over estimated cost, including valid zero cost. A model's cost is
unavailable if any of its rows lacks a recorded cost, independently of other
models. No model prices are applied. Claude custom SQLite/OTel and Codex cumulative
session totals currently show **per-model token attribution unavailable**. The
port does not assign a whole cumulative Codex session to its most recent model.

Model rows are sorted by total tokens, then name. Each provider is bounded to
256 model groups including Unattributed; exceeding this limit fails the complete
snapshot rather than publishing a partial breakdown. The window displays up to
128 rows per provider and reports omitted rows; provider totals still include all
groups. Failed or disabled sources do not display previous model rows as current.
These breakdowns add no new polling, persistent data or changes to rate baselines.

Sources offers individual Claude/Codex/Gemini/Hermes switches and an independent
Ollama inventory switch. Disabled providers do not read their logs/database or
query their API. Override each provider's directory/database with an absolute UTF-8
path; leave it blank for the defaults below. Paths are validated without a filesystem
probe on GTK's thread and may point to an offline/missing location. The existing
log filename/layout rules, symlink exclusions and budgets still apply.

Claude can use **Auto**, **Logs only**, **Database only** or **Metrics only**. Auto
uses the priority below against the configured paths. An explicitly selected source
does not fall back when unavailable. Local endpoints accept only HTTP URLs with a
loopback IP literal such as `127.0.0.1` or `[::1]`, without credentials, query or
fragment. Hostnames, remote hosts and HTTPS are not supported by these local
controls. The metrics field is a complete URL; the Ollama field is a base URL,
optionally with a path prefix, to which `/api/tags` and `/api/ps` are appended.

**Apply sources** validates the entire draft and saves it; **Close** discards unsaved
edits. **Default sources** changes only the draft until applied. Restoring graph/theme
defaults keeps AI source and weather choices. Changes coalesce in a bounded slot and apply on
the next five-second AI poll; a running scan may finish first. Rates/history reset
when source preferences change, and the UI suppresses reports from the old
configuration while waiting. No worker restart/join, file scan, SQLite query or
HTTP request runs on GTK's thread. Headless diagnostics also honor saved AI source
preferences while retaining their aggregate system metrics and fixed panel order.

| Provider | Default source and behavior |
| --- | --- |
| Claude | `~/.claude/projects/**/*.jsonl`; cache creation/read tokens included; repeated assistant message IDs replace earlier snapshots and copied IDs are deduplicated |
| Claude fallback | Custom `~/.claude/monitoring/claude_usage.db` when no transcript directory exists; otherwise local Claude OTel metrics at `127.0.0.1:8889/metrics` when neither disk source exists |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl`; last cumulative token count per file, never a sum of cumulative events |
| Gemini | `~/.gemini/tmp/**/chats/session-*.json` or `.jsonl`; saved session/message token counts |
| Hermes | Read-only `~/.hermes/state.db`; input/output tokens and actual cost, falling back to recorded estimated cost |
| Ollama | Installed and loaded model lists at `127.0.0.1:11434/api/tags` and `/api/ps`; these endpoints provide no lifetime token counter, so inventory never becomes token usage |

Claude's sources are exclusive and use the priority above; read failures retain
that source instead of silently switching to a different counter. OTel monitoring
must already be configured by the user. Only Claude's token/cost metric families
are accepted. See [Claude telemetry](https://code.claude.com/docs/en/monitoring-usage)
and [Ollama's inventory API](https://docs.ollama.com/api/tags).

The shared Swift decoders own JSON/metrics interpretation. Rust owns discovery,
metadata caches, reads, SQLite and local HTTP acquisition. Unchanged log files are
not reread; changed files are reparsed so truncation/replacement cannot leave old
usage behind. Incomplete scans publish no partial provider total. A failed source
shows unavailable and the last complete total as stale; it contributes no synthetic
idle series. First samples, source changes, counter resets and recovery establish
new rate baselines. The graph combines rates only from currently readable sources.
Anonymous legacy Claude records cannot be deduplicated by message ID. Codex totals
cover retained session files; independently copied rollout files can count twice.

Scans exclude symlinks and special files, bound discovery to 20,000 entries/six
nested directory levels, keep at most 100,000 identified messages per provider,
and allow 64 MiB per changed log file, 8 MiB per record/session, 128 MiB of changed
files and two seconds per provider pass. Hitting a limit is reported as unavailable;
completed file-cache work can be reused on the next poll. SQLite uses read-only
connections, no lock waiting, a 250 ms VM deadline and a 100,000-row limit. WAL
snapshots include committed changes. Costs are unavailable if rows lack recorded
costs; no hard-coded model prices or synthetic token splits are used.

Local API reads require the **`curl` executable**. Queries disable curl config,
proxies, redirects and URL globbing, use validated loopback HTTP endpoints, and cap each child at
650 ms/1 MiB (curl also has its own 500 ms timeout). No prompts or transcripts
are sent to these endpoints. SQLite is bundled through rusqlite; no sqlite CLI or
system SQLite development package is required. Fixtures and the GTK smoke check
never scan the user's actual provider data. Log formats are internal to providers
and may change; feedback and sample schemas with private content removed are welcome.


## Processes

The ninth panel graphs the number of **readable / running processes** in the current
PID namespace. Running counts mean process leaders whose stat state is `R`;
threads doing work under a sleeping leader do not increment that count. Its
tooltip and accessibility details list the top ten processes by
CPU and RSS, with PID, name, real UID when readable, threads, state and nice value.
Names come from `/proc/PID/stat`; command-line arguments and environments are not
read. **Processes…** in the toolbar opens a read-only table with PID, name, real
UID, CPU percentage, resident MiB, threads and state. Sort by CPU or RSS descending,
PID ascending or name A–Z; filter by case-insensitive name substring and numeric
real UID, with **My UID** as a shortcut. Filters apply before the 10–200 row limit.
An invalid UID clears the table and reports the error. Sorting/filtering runs in a
background query over the collector's existing snapshot, without another `/proc`
scan. Controls persist between launches. Coverage counts and partial-scan status
remain visible; unknown CPU percentages and UIDs display as unavailable.

CPU percentages use per-process `utime + stime`, elapsed monotonic time and the
host's `_SC_CLK_TCK`: **100% is one core**, so a multi-threaded process may exceed
100%. PID plus kernel start time identifies each process. New/reused PIDs and
regressed counters establish a new interval; stale sample times do not consume
newer counters. Dead/unreadable processes lose their baseline. During budgeted
scan rotation, an observed process keeps its own elapsed interval.

Resident pages use the host's `_SC_PAGESIZE`, with overflow checks. RSS is an
approximate kernel measurement and may include shared pages; it is never summed
into system memory usage. Memory percentages are omitted when MemTotal is unknown,
and missing UIDs stay unknown. No blocking user-name service lookup is required.
The parser handles spaces and closing parentheses in process names and checks
start time before/after reading UID information to reject PID-reuse races.

Discovery and reads have a cooperative 100 ms budget, a 65,536-entry directory
limit, an 8 KiB stat limit and 64 KiB status/memory limits. A read window rotates
when a pass cannot cover every PID. Counts and rankings describe that pass's
readable subset; partial coverage, protected/malformed tasks and ordinary process
exits are reported separately. Mount options such as hidepid and container PID
namespaces restrict visibility. No process-control actions are implemented.
See the kernel's [proc documentation](https://www.kernel.org/doc/html/latest/filesystems/proc.html).

## Coral Edge TPU

The tenth panel separates **hardware inventory** from **producer-reported inference
statistics**. It recognizes Coral USB IDs `1a6e:089a` (before firmware initialization)
and `18d1:9302` (runtime firmware), plus PCIe/M.2 `1ac1:089a` devices. PCIe and
`/sys/class/apex/apex_N` aliases are deduplicated by canonical device path. A bound
apex driver's `temp` attribute is interpreted as millidegrees Celsius; temperature
reads are deferred while runtime power is suspended or transitioning. Missing
telemetry stays unavailable. See Google's [USB firmware notes](https://github.com/google-coral/webcoral)
and [apex driver](https://github.com/google/gasket-driver/blob/main/src/apex_driver.c).

Discovery only reads sysfs. It does not open device nodes, initialize firmware,
reset devices, run inference or change clock/power controls. Detection and a bound
driver alone do not establish that inference will succeed. Discovery is bounded
to 4,096 entries per root and a cooperative 100 ms budget; errors reduce coverage.

The existing `/tmp/xrg-coral-tpu-stats.json` integration is preserved. The inference
engine must write a complete JSON object, preferably by atomic rename, for example:

```json
{
  "total_inferences": 12345,
  "last_latency_ms": 18.5,
  "avg_latency_ms": 19.2,
  "model_name": "mobilenet_v2",
  "timestamp": 1793116800.0,
  "session_id": "unique-producer-start-id",
  "by_category": {"direct": 100, "hooked": 200, "logged": 12000, "warming": 45}
}
```

`total_inferences` is required and must be an unsigned integer. Other fields are
optional. `timestamp` is Unix wall time in seconds: supply the current time when
writing, and refresh the report at least every 30 seconds, including while idle.
Without a timestamp, file modification time is used. `session_id` is an optional
extension; change it on producer restart. Legacy files without it are supported,
but a restart that overtakes the old counter between polls cannot be recognized.
Optional `temperature` is producer-reported Celsius, separate from sysfs readings.

The graph shows observed counter change per elapsed second, including fractional
rates. Batched writes can produce bursts. The first sample, decreased counter,
changed session ID, read failure and recovery establish a new baseline. Missing,
malformed, partial or over-30-second-old reports create no synthetic idle samples.
Future timestamps beyond five seconds are rejected. Unknown category counts remain
unavailable and categories are not assumed exclusive. Latency values stay in
millisecond details rather than sharing a scale with inference rates.

Reports are capped at 64 KiB, must be regular files without final-component symlinks,
and must remain stable while being read. Producer statistics are unscoped: they
are not assigned to every detected adapter. Valid statistics without detected
hardware are explicitly labeled **hardware unverified**. Hardware without fresh
statistics shows **statistics unavailable**. No device utilization is inferred
from USB connection, mapped pages, latency, temperature or inference counts.
Support remains best effort; device reports and feedback are welcome.

## Weather observations

Open **Weather** with the sun icon in the main toolbar. Requests are **off by
default**. Enable them, enter a four-character ICAO station such as `KSEA`, choose
Metric or US units, and press **Apply**. Station codes are normalized to uppercase;
invalid drafts leave active settings unchanged. **Close** discards unapplied edits.
No automatic location detection or API key is used.

The window shows temperature, dewpoint, relative humidity, wind/gusts, visibility,
pressure, observation time/age, source and normalized raw METAR. Missing values
show **unavailable**; zero temperature and calm wind remain valid readings.
Metric uses °C, km/h, km and hPa; US uses °F, mph, miles and inHg. The shared Swift
decoder handles KT/MPS/KMH winds, visibility qualifiers, mixed-station responses
and METAR/SPECI prefixes. Month/year are inferred in UTC relative to the local
clock, accepting observations from the preceding 36 hours through five minutes
ahead, including month/leap-day rollover. The newest matching report wins.
These are station observations, not forecasts.

Automatic refresh is configurable from **5–60 minutes**, defaulting to 15.
**Refresh now** coalesces repeated clicks. All requests, including changes of
station and re-enabling weather, obey a **one-minute minimum per app instance**.
Changing display units reuses the cached report. Observations older than two
hours are marked **stale**. A failed refresh retains the same station's previous
report with its age and an explicit error/stale status; changing station or
disabling weather clears that cache. The cache is in memory only.

Rust requests the fixed NWS Aviation Weather Center HTTPS endpoint
`/api/data/metar?ids=STATION&format=raw&hours=24` with an XRG-ng user agent.
The runtime needs `curl` and trusted CA certificates. Redirects and proxies are
disabled; normal TLS certificate verification remains enabled. Each request has
a three-second connection timeout, five-second curl timeout and a bounded child
process deadline of 5.5 seconds. Responses are capped at 2 MiB; parsing examines
up to 2,048 headers, with at most 8,192 UTF-8 bytes and 256 fields per report.
Acquisition and parsing run on a separate weather worker, outside GTK and the
system/AI workers. Publishing uses a copied latest-value slot whose mutex is not
held during network activity. Headless diagnostics honor saved weather settings;
automated tests use fixtures and make no weather requests.

## Remaining migration

1. Intel GPU PMU utilization, additional vendor counters, calibrated thermistor
   support, individual fan/sensor controls and detailed process controls.
2. Safe Codex model attribution where cumulative records permit it, append-offset
   scanning for very large logs and optional price tables.
3. Deeper metric preferences, XTF conversion and broader legacy-field mappings
   as their corresponding Rust features become available.
4. Wayland/X11 behavior and accessibility validation. GTK4 removed GTK3's global
   window placement / keep-above APIs; supported positioning/pinning needs a
   compositor-specific implementation. No always-on-top or edge-placement promise
   is made by this initial shell.
5. Signed/tagged Linux releases and distribution-native packages before replacing
   the C application's release path. Broaden real-device coverage through community
   feedback as hardware becomes available.

GTK4 fits the rewrite: supported Rust bindings, modern scene-graph rendering and
retained Cairo drawing through GtkDrawingArea. GTK4 does not make blocking collectors
asynchronous; the separate worker is what keeps collection out of the UI loop.
See the [GTK migration guide](https://docs.gtk.org/gtk4/migrating-3to4.html),
[drawing model](https://docs.gtk.org/gtk4/drawing-model.html) and
[gtk4-rs](https://gtk-rs.org/gtk4-rs/).
