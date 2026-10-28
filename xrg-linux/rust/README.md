# Linux Swift / Rust transition

This is the GTK 4 replacement in progress. It runs alongside the C/GTK3 application
in `../src`; the C executable and its `~/.config/xrg-linux/settings.conf` remain
available. The new executable is `xrg-ng-linux`, version 0.1.0. It currently shows
aggregate CPU, memory, network receive/send, physical-disk read/write, system
battery capacity, temperature, GPU activity, AI token-rate, process-count and
TPU/NPU neural accelerator, VRAM pool and fan RPM graphs, with per-core/interface/disk/GPU/temperature/fan selection and a
sortable, filterable process table.
An opt-in **Weather** graph and settings window show station observations using
the shared Swift METAR decoder, with saved visibility, station, units and refresh
controls.
The main window follows the macOS strip: a draggable hostname band with a compact
menu, plots with overlaid readings, thin separators and the same six Swift theme
palettes. New profiles default to **Classic**, 140-pixel graph width and 90-pixel
height. CPU, GPU, NPU and memory lead the default order; process counts, VRAM and
fans remain available through Preferences. Existing saved profiles retain their
sizes, order, visibility, sources, colors and theme. Window dimensions follow
layout changes; both axes still scroll when the desktop or a manual resize limits
space. Preferences, theme selection, process tools, AI, weather and Quit are in
the title-band menu; graph actions remain available by right-click or Shift+F10.
Linux compositor decorations, fonts and placement behavior can differ from macOS.
This is an initial vertical slice, not feature parity with the C application.

[Classic preview](../../screenshots/linux-compact-classic.png) ·
[Midnight preview](../../screenshots/linux-compact-midnight.png).
These are actual GTK4 release-build captures in a Linux X11 validation VM;
GPU/NPU, battery and sensors absent from that VM show unavailable states.


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

The **CPU** graph keeps the total non-idle curve and adds independent **user**
(including nice) and **system** (including reported IRQ/softirq) curves. All use
the same interval total; they are not stacked. Total non-idle includes steal,
which is hypervisor wait rather than executed work. Guest time already included
in user/nice is not counted again. **Live details…** lists nice, idle, I/O wait and
steal separately, plus system-wide 1/5/15-minute load averages, runnable/total
scheduling entities (including threads) and uptime including suspend. Selecting
one logical CPU changes its curves; load and uptime keep their exposed `/proc`
scope. Those counters may exceed a container's assigned CPU capacity.

The compact CPU face shows total **core-percent** (average × logical CPU count),
the aggregate 0–100% **Average**, one-minute load and uptime. When selecting one
CPU, the total and average both refer to that CPU. Activity bars along the bottom
show up to 64 logical CPUs with stable IDs; unreadable/regressed intervals stay
blank. Memory displays Linux used, available, cached and swap-used byte counts,
without inventing macOS wired memory. Net/Disk faces show kernel lifetime totals
(normally since boot) and the latest rates. Compact B/K/M/G/T suffixes use powers
of 1024; totals are neither disk capacity nor transfers since launching the app.
Full labels, accounting semantics and source details remain in accessibility,
tooltips and Live details.

Load averages are task counts, including uninterruptible I/O wait, not utilization
percentages. Uptime's cumulative idle value can exceed elapsed uptime on multicore
systems and is not used to estimate CPU usage. Optional load/uptime failures show
unavailable details while preserving valid CPU curves. Their reads are capped at
4 KiB each and reject final-component symlinks/special files. Failed CPU reads,
counter regressions (including decreasing iowait), counter-layout changes,
non-increasing times and gaps over 300 seconds clear the affected histories and
start a fresh interval. Aggregate history also resets when logical CPU membership
changes; a separately selected surviving CPU keeps its own baseline. See the
kernel's [CPU counters](https://www.kernel.org/doc/html/latest/filesystems/proc.html#miscellaneous-kernel-statistics-in-proc-stat),
[load-average definition](https://man7.org/linux/man-pages/man5/proc_loadavg.5.html)
and [uptime definition](https://man7.org/linux/man-pages/man5/proc_uptime.5.html).

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
reads, and explicit partial-coverage errors. Automatic fan details list the three plotted slots and up to 64 additional channels.
Preferences offers individual **Fan RPM** sources as well as the default three-channel view.
Choose a primary fan, then expand **Additional temperature and fan curves** to
pin curves 2 and 3 independently. Automatic fan mode keeps surviving sensors in
their color slots and fills empty slots with newly readable sources.
A selected missing, faulted or disabled fan shows unavailable; another fan never
replaces it automatically. Driver labels do not establish CPU/GPU ownership. PWM values are not RPM, and this
collector never writes fan controls or guesses board-specific calibration.

Temperature collection reads standard hwmon temperature channels, honors disabled
and fault flags, and falls back to thermal zones if no hwmon values are usable.
The default graph shows the maximum readable hwmon temperature, using thermal
zones only when no hwmon values are usable. **Temperature** in Preferences can
instead select a primary hwmon channel or thermal zone and up to two additional
channels in **Additional temperature and fan curves**. They plot independently,
with numbered readouts mapping to the graph's three colors and current-value bars.
A selected thermal
zone stays readable when hwmon appears. The source list includes both backends;
tooltips list the readings contributing to the selected graph.
Temperature scans share a cooperative 100 ms / 256-channel budget and report
partial coverage. Negative temperatures use a signed graph range. Standard hwmon
channels use millidegrees Celsius, including thermistors (`tempN_type=4`). The
type describes probe technology, not a voltage unit. In particular the kernel's
`ntc-thermistor` driver already performs resistance/table conversion for its
Murata, EPCOS and Samsung-compatible sensors; Winbond and other conforming hwmon
drivers can also report converted thermistor temperatures. Negative and zero
readings remain valid. Probe-type changes reset the curve while keeping the saved
physical source selection. Chip/type/enable/fault metadata must agree before and
after the input read; malformed/unsupported types, disabled inputs and faulted
sensors do not produce measurements. System and GPU hwmon views share this reader.

Known legacy VIA exceptions remain unavailable until board-specific conversion
is supported: VT1211 external channels (temp1 and temp3–temp7), and VT8231 channels.
Only VT1211's driver-converted internal temp2 is used directly. Raw voltage or
unscaled diode readings never become tiny Celsius values or contribute to the
hottest-sensor graph; thermal-zone fallback remains available. No input magnitude,
label, guessed thermistor beta or default resistor network determines conversion.
This reader does not apply libsensors configuration/compute rules or write sensor
configuration. The paths are tested with fixtures; physical hardware validation
remains best effort and community feedback is welcome. See the kernel's
[NTC thermistor driver](https://docs.kernel.org/hwmon/ntc_thermistor.html),
[Winbond driver](https://docs.kernel.org/hwmon/w83781d.html),
[VT1211 conversion rules](https://docs.kernel.org/hwmon/vt1211.html),
[VT8231 implementation](https://github.com/torvalds/linux/blob/master/drivers/hwmon/vt8231.c),
[legacy board-conversion examples](https://github.com/lm-sensors/lm-sensors/blob/master/etc/sensors.conf.eg#L1392),
[power-supply ABI](https://docs.kernel.org/power/power_supply_class.html) and
[hwmon interface](https://docs.kernel.org/hwmon/sysfs-interface.html).
Missing optional hardware shows an explicit absence label and no fabricated zero
series; read failures show unavailable/partial labels. Neither makes core-only
headless or live GTK smoke checks fail on desktops/containers without that hardware.
The graph area scrolls on small windows and exposes details to accessibility APIs.

The **Memory** panel carries forward the C collector's cache, swap and paging
readings. Its curves follow the label order: **RAM used** (`MemTotal − MemAvailable`)
as a percentage of RAM, reported **Cached** as a percentage of RAM when readable,
then **swap used** as a percentage of configured swap. These are independent
curves, not stacked components: Linux memory categories overlap, and Cached is
not subtracted again from the kernel's available-memory estimate. Zero swap
capacity says **no swap** and produces no swap percentage; an enabled but empty
swap pool has a valid zero curve. Missing/invalid swap counters say **swap n/a**.

Right-click Memory → **Live details…** for used/total/available RAM, reported free,
buffers, cache, slab/reclaimable slab, shared memory, dirty/writeback and swap
values. Buffers and Slab are not labeled macOS wired memory or added to infer
application memory. Paging details use elapsed monotonic time: `pgpgin/pgpgout`
are **KiB/s** (including file-backed I/O), while `pswpin/pswpout` are **pages/s**.
They are separate quantities; the collector does not assume a 4 KiB page size.
First samples, counter regressions, missing reads and clock gaps above 300 seconds
establish a fresh interval before showing a rate. Valid no-change intervals show
zero. Optional failures retain valid RAM readings and explain unavailable values.
Memory read failures clear its plotted histories; capacity changes reset the
affected curves. All parsing/reads run on the system worker, with 256 KiB file,
4,096-line and 4,096-byte line limits. These counters describe the exposed `/proc`
scope, which may exceed a container's cgroup limit. See the kernel's
[memory-counter definitions](https://www.kernel.org/doc/html/latest/filesystems/proc.html#meminfo)
and [vmstat export units](https://code.googlesource.com/linux/torvalds/linux/+/0cb552aa97843f24549ce808883494138471c16b/mm/vmstat.c#1800).

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
| Intel i915 | Kernel PMU busiest-engine activity where permitted; readable DRM-client engine times/allocations, reported clock and hwmon |
| Intel xe | Readable DRM-client busy/total cycle activity and resident allocations; available hwmon telemetry |
| Mali panfrost / panthor | Owned devfreq clocks/load when provided, readable DRM-client activity and resident allocations; client activity needs profiling |
| Mali lima / vendor Mali | Identification, owned devfreq/hwmon, vendor devfreq load where provided, readable DRM-client stats where exported |
| Adreno mainline MSM | Owned GPU devfreq/hwmon and readable DRM-client engine stats |
| Adreno vendor KGSL | `gpubusy` busy/total interval and `gpuclk` Hz, including KGSL class-device layout |
| Apple AGX / Asahi | Platform/render-node discovery and available devfreq/hwmon/client stats; unexposed utilization stays unavailable |
| Broadcom V3D / Vivante etnaviv / PowerVR | Platform/render-node discovery and available devfreq/hwmon/client stats |
| nouveau / other drivers | Identification; unsupported counters remain unavailable |
| Runtime-suspended adapters | Identification only; telemetry reads/commands are skipped |

Intel `i915` engine activity uses the native backend described below, with readable
client accounting as a fallback. Xe uses client accounting; system-wide Xe PMU
activity remains future work. Clock frequency
is never converted into an estimated busy percentage. There is no simulated GPU
fallback. Actual zero utilization is retained; unsupported, malformed or absent
values create no synthetic idle samples. NVIDIA `N/A` fields remain unavailable,
and duplicate/invalid PCI rows cannot attach telemetry to another adapter.

The **i915 PMU** backend reads exported `*-busy` events in nanoseconds using
`perf_event_open`, with no helper process, privilege elevation or permission
changes. The GPU graph shows **PMU** next to these readings. This is the **maximum
busy percentage of the exported engines**, covering system-wide engine activity;
it is not a sum, GPU-wide busy union, compute capacity or readable-client usage.
Per-engine readings and source semantics remain in Live details/accessibility.
Driver busy accounting can include waiting, rather than only executed work.
Device utilization, PMU engines and readable-client activity use separate history
scopes; source/driver changes and unavailable telemetry start fresh curves.
Unobserved GPU history is blank, while a measured zero remains zero.

PMU names containing a PCI address map directly to that adapter. The legacy
unqualified `i915` PMU is used only when bound PCI inventory leaves exactly one
unmatched i915 device. Ambiguous, malformed or inaccessible mappings stay
unavailable. Reader CPUs follow an exported PMU cpumask and online CPUs; kernels
without that legacy cpumask use the first online CPU. Device/PMU identity, event
inventory, counter type and reader changes recreate handles and baselines.
Only busy-event configs with `ns` units and an absent scale or a scale of 1
are accepted.

The first valid read establishes a baseline. Failed/short reads, regressions,
zero running time, incomplete/multiplexed intervals and implausible busy deltas
produce no idle sample. Small accounting overshoots (up to 5%) clamp to 100%;
larger ones are rejected. Delayed intervals over five minutes and regressed sample
times establish fresh baselines. Permission/read failures back off for 30 seconds;
suspend, disappearance and discovery failures close counters. Enumeration is
bounded to 4,096 PCI entries, 1,024 event-directory entries, 64 engines per adapter and 256 live
counter handles, with bounded metadata and counting-only 24-byte records.
Custom sysfs roots never open host perf events; fixture readers are internal to
the tests. `i915` PMU data is **best effort and not physically validated on Intel
hardware here**. Reports from real hardware are welcome under the support policy.

The ABI follows the kernel’s [i915 PMU implementation](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/i915/i915_pmu.c),
[engine-event definitions](https://github.com/torvalds/linux/blob/master/include/uapi/drm/i915_drm.h)
and [perf-event interface](https://github.com/torvalds/linux/blob/master/include/uapi/linux/perf_event.h).
Software-counter ABI tests either verify a native record or explicitly observe
kernel refusal; this does not establish Intel hardware behavior. Fixtures cover
mapping, units, CPU changes, warm-up, zero/busy readings, counter failures, resets,
permission backoff and handle cleanup.

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

Intel i915 client activity uses the exported nanosecond engine counters. Xe uses
`100 × Δbusy-cycles / Δtotal-cycles / engine-capacity` for each readable client,
sums clients within each engine class, and plots the busiest class. Xe's GPU
timestamp is the denominator, never the CPU polling interval or a clock-frequency
estimate. Missing/zero/regressed total-cycle intervals are unavailable. Xe SR-IOV
virtual functions currently omit these optional cycle counters in the upstream
driver and therefore do not supply an activity reading. PCI client records must
match the discovered adapter's `drm-pdev` and driver. Baselines reset on device or
driver replacement, suspend, disappearing clients, capacity changes, backward
sample times and intervals longer than five minutes. Busy-counter regressions
retain the preceding larger baseline until catch-up. Missing resident regions
remain unavailable; readable resident regions are summed separately from VRAM
capacity and can include system/GTT memory.

Xe fdinfo collection opens no DRM device or perf counter. The kernel's fdinfo
callback may temporarily wake the GPU during a read; runtime-suspended adapters
are skipped before scanning. Persistent Xe PMU collection is deferred because
upstream holds runtime-PM/forcewake references for the lifetime of each engine
event. An explicit power-policy choice is needed before using that interface in
a background monitor. See the kernel's
[Xe client implementation](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/xe/xe_drm_client.c),
[i915 client implementation](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/i915/i915_drm_client.c)
and [Xe PMU implementation](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/xe/xe_pmu.c).
Intel client support is **best effort and has not been physically validated here**;
real-device feedback is welcome. Fixtures exercise cycle/time units, capacity,
zero/busy values, resets, duplicate FDs, multiple GPUs, PCI/driver mismatches,
suspend/removal and rejected symlinks/FIFOs. Existing ARM client tests remain gates.

The proc scan has a 50 ms cooperative budget, 4096 directory-entry / 8192 FD limits
and 64 KiB record cap. Permissions, transient failures and budget truncation are
reported as partial coverage. Like other kernel reads, an individual fdinfo callback
cannot be hard-cancelled by this userspace budget. Mali Panfrost needs profiling
set to 1; Panthor needs timestamp bit 2. XRG-ng only reads these controls and does
not enable profiling or write governors, clocks or power controls. Without suitable
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
Activity-bar checks cover controls, Apply/Cancel, persistence/reopen, defaults,
legacy mappings and dedicated previews of all four styles, zero/missing values,
signed temperatures and relative rate scaling. Multi-sensor checks exercise
three pinned channels, duplicate rejection, Apply/Cancel, missing-source refresh,
persistence/reopen and fixture previews collected through the production sampler.
Sensor regressions cover reordered/duplicate labels, stopped fans, independent
histories, thermal-zone selection, disappearance/replacement and scan failures.
A second GTK smoke invocation (`XRG_SMOKE_PROCESS_ACTIONS=1 --smoke-test`) has its
own unchanged twenty-second deadline and targets only disposable child processes.
It checks row/action state, a frozen context-menu target, cancel, pause/resume,
selection through sorting, parent-close cancellation, terminate and force kill.
Its process-menu, confirmation and controls screenshots are exported separately.
An independent process-details GTK gate checks button/row/menu entry points,
frozen menu targets, filtering, partial/failed scans, PID reuse, delayed reports
and parent-close cleanup, using explicitly labeled copied report fixtures without
sending signals. Inspector screenshots are exported separately.
A separate weather-graph smoke invocation uses a visibly labeled fixture with
network workers disabled. It checks visibility drafts, saved controls, unit and
station guards, stale gaps, disabling, and compact drawing; fresh/stale screenshots
are exported.
Width smoke checks exercise draft cancellation, Apply/reopen, default restoration,
wide vertical scrolling and compact horizontal allocations, with screenshots of
both layouts and the control. Kernel-backed Rust regressions also verify stale start/UID/directory rejection,
fixture refusal and exited pidfds without numeric-PID fallback. These tests never
signal pre-existing user processes.
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
`[Temperature] units` (0 Celsius, 1 Fahrenheit). `[GraphStyles]` transfers the
CPU, memory, network, disk, GPU, battery, temperature, AI-token and TPU style keys:
0 Solid, 1 Pixel, 2 Dot and 3 Hollow. Missing style entries retain the draft's
choices; invalid supported style values reject the whole import. Imported global
colors become an embedded custom theme, retaining alpha and black/zero values.
The legacy theme name supplies a label only; palettes are never guessed from a
matching preset name. A name without global color entries leaves the current theme intact.
The thirteen `[Colors]` keys written by the C app for Memory, Network, Disk and
AI-token backgrounds/series import as overrides for those graph components.
Missing components keep their current override or theme inheritance; module-only
color imports leave the global palette intact.
`[Display] show_activity_bars` (true/false), `activity_bar_style` (0–3 as above)
and `[Colors] activity_bar` transfer independently. Malformed supported bar
settings reject the entire import. A bar-only color import keeps the global theme.
Partial files keep current draft values for missing fields. New VRAM/Fans
visibility, graph order/height, metric sources, process filters, AI sources and
weather remain as configured. A legacy weather visibility flag does not enable
requests. Theme background alpha is separate from whole-window opacity.
The C writer does not save its update-interval fields; import preserves the Rust
system sampling target instead of guessing it from unrelated keys or window data.

`[AIToken] show_model_breakdown` transfers independently as a display preference:
`true` shows recorded per-model token rows in AI monitoring; `false` keeps grouped
provider totals. Missing values preserve the draft choice, and malformed booleans
reject the entire import. This does not alter AI sources or their histories.

`[Window] opacity` transfers as a fraction from 0.1 to 1.0. Missing values keep
current draft opacity; invalid/non-finite values reject the whole import. The
preview and Preferences stay opaque, and transparency changes only after Apply.

`[Window] width` and `height` import as an explicit dashboard size (100–8192
logical pixels each), independently of graph dimensions. Both are required when
the draft uses automatic sizing. With an existing explicit size, a missing
dimension preserves its draft value. An incomplete size in automatic mode is
listed as not transferred; malformed/out-of-range dimensions reject the import.
Window position/pinning, billing and unrecognized entries are listed as
not transferred. Unsupported values are not echoed in the preview. Invalid
supported booleans, colors, layout or unit values reject the entire import and
leave the draft unchanged.
Files containing no supported visibility/color/layout/unit/style/activity-bar/model-display entries are rejected.

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

The title-band menu provides all six built-in presets and **Preferences…**. The Custom
entry opens the editor when a built-in preset is active. In Preferences:

- Check which graphs to show; use **Up/Down** to arrange them.
- Choose each graph's **Solid**, **Pixel**, **Dot** or **Hollow** style beside its
  visibility control. Solid fills the area; Pixel and Dot use coarse square or
  fine dotted fills; Hollow retains the outline alone. Fills run to zero,
  including for negative temperatures. Curves remain independent rather than
  stacked, and their outlines stay visible above overlapping fills. Theme colors
  and opacity apply to every style. Style changes keep the sampled histories.
- Set **Minimum graph width** between 100 and 1200 pixels. Graphs can expand to
  fill available space. A width larger than the viewport scrolls horizontally in
  either layout without forcing the whole window wider. The default stays at
  140 pixels. Width changes keep sources, sampled histories, graph order, colors
  and individual heights. Apply/Cancel and Restore defaults cover this control.
- Set the **Default graph height** between 64 and 240 pixels. Expand **Individual
  graph heights**, select a graph and uncheck **Use default height** to give it
  an independent height in the same range. Changing the default resizes inherited
  graphs while preserving overrides. **Use default height for all graphs** clears
  the overrides in the draft and keeps the default value. Sizes apply in both
  layouts; horizontal graphs align at the top rather than stretching shorter
  graphs. Ordering, hiding, sources, themes and styles preserve size choices.
- Set **System sampling interval** between **250 and 10,000 milliseconds**; the
  default is **1,000 ms**. Any whole millisecond in that range can be saved.
  This retimes the system worker (CPU, memory, network, disk, GPU, processes and
  hardware sensors). Apply wakes a sleeping worker, without rebuilding collectors,
  changing sources or resetting rate baselines/history. Cancel discards the draft;
  Restore defaults puts 1,000 ms in the draft. Existing settings gain that default
  without an immediate write. Headless sampling honors the same saved target.
  Normal collection time is included in each interval. If collection overruns,
  the next attempt waits one target interval after completion, avoiding catch-up
  bursts. Changing the target cannot interrupt an active read/scan/command.
  Rates use actual monotonic elapsed time; historical points retain their values
  and are spaced by sample order, so a cadence change is not a uniform time axis.
  AI still collects every five seconds, and weather keeps its own refresh policy.
  Their latest cached views reach the window at the system snapshot cadence.
- Expand **Dashboard window size** to enable **Remember dashboard window size**
  and choose width/height in **logical pixels** (100–8192). Apply sets the requested
  size independently of graph widths/heights. Subsequent dashboard resizing is
  captured when opening Preferences, closing the dashboard or quitting normally.
  Maximized/fullscreen dimensions are ignored; maximize/fullscreen state is not
  restored. Your desktop and widget minimums can constrain the requested size.
  Disabling the option or applying Restore defaults resumes automatic compact
  sizing; Cancel leaves the active size unchanged. Existing Rust settings keep
  automatic sizing by default. Theme load/save does not exchange window size.
- Set **Main window opacity (%)** between **10% and 100%**. New installations,
  existing Rust settings and Restore defaults use **100%**. This affects the entire
  dashboard, including text and graphs; Preferences, details and other windows
  stay opaque. Apply changes and saves it; Cancel discards the draft. Theme
  load/save continues to exchange colors independently of window opacity.
  [GTK requires X11 compositing for this effect](https://docs.gtk.org/gtk4/method.Widget.set_opacity.html);
  Wayland supports it, but live changes can flicker on some windowing systems.
  The automated Xvfb gate checks GTK's property and preference lifecycle; physical
  compositor behavior remains best effort and feedback is welcome.
- Expand **Activity bars** to show/hide the compact current-value indicators and choose
  their independent Solid/Pixel/Dot/Hollow style and RGBA color, or inherit graph
  series colors (the new default). Up to three bars
  follow graph series order, left to right. Each shows the latest sample on the
  **same axis as its graph**: percentage graphs use 0–100%; rates/counts use the
  recent-history scale, not hardware capacity; temperatures use the graph's signed
  display range, not a thermal threshold. Tooltips and accessibility descriptions
  explain the axis. Missing latest values leave no track; measured zero has an
  empty track and a zero marker. Signed values extend from zero. Apply/Cancel and
  Restore defaults work like other appearance controls. Theme load/save keeps bar
  settings intact; theme files still contain only the global palette.
- Choose **Vertical** (stacked) or **Horizontal** (side by side) layout. Ordering
  controls become Left/Right horizontally; graph menus use the same order.
- Choose **Celsius** or **Fahrenheit** for system sensor, GPU and TPU/NPU temperatures.
  Graph labels, tooltips, accessibility text and open live details update together.
  Collector/history values stay Celsius; unit changes preserve history and graph
  shape. Missing readings stay unavailable. Weather has its own units setting.
- Toggle **Show per-model token details in AI monitoring** to show recorded model
  attribution or grouped provider totals in the AI window. Both views retain
  source-recorded costs, availability messages and Ollama inventory. This changes
  the display immediately on Apply, without re-polling sources or resetting graph
  history; Cancel and Restore defaults follow the usual draft behavior. Existing
  Rust settings keep model details enabled; legacy import honors its explicit flag.
- Choose aggregate or individual CPU, network, disk and GPU sources, a temperature
  sensor, and a fan RPM channel. **Refresh
  source lists** uses the latest collector inventory without discarding the draft.
- Expand **Additional temperature and fan curves** after choosing a primary
  temperature/fan source. Assign distinct inputs to curves 2 and 3, or leave
  **Not graphed** slots empty. Saved but unavailable sensors remain selected.
  Missing curves keep their color slot blank; a measured zero (including a stopped
  fan) stays a real reading. Duplicate selections are rejected on Apply.
  Returning the primary selector to its automatic view clears and disables the
  additional choices. Apply/Cancel, reopening and Restore defaults cover all slots.
- Select a preset, name a custom palette and edit its seven colors.
- Expand **Per-graph colors**, select a graph and uncheck **Use theme** for a
  background or series color to customize it, including opacity. Every component
  initially inherits the global palette. Checking Use theme resumes inheritance;
  **Use theme for this graph** clears only that graph's overrides. Theme changes
  update inherited components and preserve explicit overrides. Window background,
  text and border colors remain global. Style/source changes preserve overrides.
- Use **Load theme…** for portable JSON themes or supported original macOS `.xtf`
  themes. **Save theme…** always writes portable XRG-ng JSON.
- **Apply** uses the draft and saves preferences; **Cancel** keeps the active layout
  and colors. **Restore defaults** changes the draft until Apply is pressed.

Hidden graphs continue sampling, preserving their histories. Ordering changes the
presentation while each graph retains its original collector. An all-hidden layout
shows a recovery message and keeps Preferences accessible. Headless diagnostics
continue reporting all collectors independently of these presentation preferences.
Graph heights are minimum requests; small windows scroll. Graphs retain their
chosen minimum width (140 pixels by default) in either layout and scroll sideways
when necessary, with vertical scrolling when needed.
Explicit dashboard dimensions stay fixed across layout/graph changes, while
scrolling keeps the graphs accessible. Automatic sizing continues to fit their
configured dimensions. Window placement/pinning is not part of these preferences.

CPU choices use logical core IDs. Network choices include loopback, while the
default aggregate excludes it. Individual disks include partitions and stacked
devices; the default aggregate uses whole physical devices as described above.
GPU choices retain the collector's adapter identity; the default displays up to
three adapters. A saved source that disappears stays selected and shows unavailable
until it returns or another source is chosen. It never silently changes to an
aggregate. Changing CPU/network/disk/GPU sources resets the affected history.
Temperature/fan histories follow input identity, preserving surviving histories
when selected curves are reordered or changed. An unselected, disappeared or
replaced input starts fresh when next graphed. Temperature/fan choices use
canonical device/channel identities, including the reported chip name. Physical hwmon
paths exclude transient `hwmonN` class numbering; virtual sources whose kernel
paths change can still need re-selection. Labels include channel identifiers to
distinguish duplicate driver labels. Aliases are deduplicated, ambiguous identities
are omitted, and attribute/device inode changes reset histories. The default
temperature maximum also resets when its contributing sensors change.
Network/disk membership,
identity changes and counter resets establish a fresh rate baseline; device
replacement detection is limited by the identity metadata the kernel exposes.

Custom theme files use the suggested `.xrg-theme.json` extension. Exporting a preset
provides a valid starting document. The format contains `format: "xrg-ng-theme"`,
`version: 1`, a printable name of 1–80 characters and `colors`: seven RGBA arrays in
**background, graph background, series 1, series 2, series 3, border, text** order.
Each component must be finite and between 0 and 1. Alpha is retained in files and
used for graph layers; theme alpha does not control whole-window transparency.
Use the separate Main window opacity preference for that. JSON numbers preserve
round-trip precision. Editing a theme name does not quantize untouched colors to
the color picker's display precision.

Loading validates the whole document before changing the draft; errors leave its
previous values intact. Theme reads/writes run outside GTK's main thread. Files
are limited to 128 KiB and must be regular local files without final-component
symlinks. Built-in presets remain available after using custom colors. A custom
palette is embedded in saved preferences, so reopening does not depend on the
original imported file. Legacy Linux settings import is available as described
above. The macOS application's XTF load/save behavior is unchanged.

Original macOS XTF import accepts XML and binary property lists containing the
seven `*Color` archives and separate `*Transparency` numbers used by XRG. It reads
plain NSColor RGB (device/calibrated) and grayscale components as palette values;
it does not instantiate archived classes or call an Objective-C unarchiver.
Modern AppKit standard sRGB archives use their original `NSComponents`, not the
legacy calibrated `NSRGB` fallback. Their space must identify standard sRGB
(`NSID = 7`) with no embedded ICC data, or with the exact verified 3,144-byte
sRGB IEC61966-2.1 profile. A claimed sRGB ID never overrides an unknown profile.
Display P3 archives use `NSSpaceID = 12` and require an exact verified embedded
profile: Apple's 536-byte Display P3 profile or the 480-byte CC0 Compact ICC
Profiles DisplayP3-v4 profile. A P3 ID without its profile is rejected: AppKit
itself decodes that form as generic RGB, so the ID alone is insufficient.
P3 components are linearized, transformed using the D65 primary matrices and
encoded into the existing bounded sRGB palette. Out-of-sRGB channels are clipped
independently; this can reduce saturation and is not perceptual gamut mapping.
See the [CSS Color 4 conversion equations](https://www.w3.org/TR/css-color-4/#color-conversion-code).
Absent or zero linear exposure is supported; other exposure is rejected.
Separate transparency overrides archived alpha, matching the macOS loader, and
must be a finite number between 0 and 1 (a boolean is not a number here). The
original `ClassicTheme.xtf` fixture is checked against the shared Classic preset.
Imported palettes are named **Imported macOS**, editable before Apply. Cancel and
failed imports retain the previous settings. Saving converts the palette to JSON;
it does not rewrite the original XTF or export macOS archives.

This does not promise physical-monitor or exact ColorSync matching. Other
ICC/profile-based colors and extended-range channels,
named/system colors, patterns and CMYK are rejected with a clear error;
export standard sRGB, a verified Display P3 profile, device RGB/grayscale colors
or use JSON instead. Different versions of embedded profiles need verification
before acceptance. The [sRGB generator](../../Tools/generate-srgb-xtf-fixture.swift)
and [P3 generator](../../Tools/generate-p3-xtf-fixture.swift) exercise real AppKit
archives. The P3 fixture substitutes the CC0 profile and verifies the component
round trip with AppKit; Apple's system-profile bytes stay local. The converter
agrees with 216 AppKit-generated RGB test cases within 0.0005 per channel; this
is scoped fixture evidence, not a guarantee for every color or physical display.
The GTK gate checks Classic cancellation, sRGB and P3 Apply/persistence, JSON
export and rejection without changing the draft. All seven fields must be
supported before any draft change. Per-graph overrides, layout and metric choices
are preserved. Decoder bounds include 128 KiB per file, 64 KiB per color archive,
64 archive objects, 12 collection nesting levels, 2,048 events and 256 KiB expanded
payload per property list. Duplicate dictionary keys and invalid UID/class
references are rejected. The pinned
[Rust plist parser](https://docs.rs/plist/1.10.3/plist/) supplies streaming
events; XRG-ng enforces these limits while building values.

Theme files continue to exchange only the global seven-color palette. Per-graph
overrides are embedded in preferences and stay intact when loading/saving a theme.

Settings use version 19 JSON in the existing `settings.conf` path. Version 1/2 JSON
still loads, preserving graph order/visibility, theme and existing source/process
controls. VRAM and Fans are appended **hidden** when upgrading these layouts; enable
them in Preferences. An all-hidden layout stays hidden. New installations show nine
compact graphs; process counts, VRAM and fans are optional. Version 3 layouts also load, adding default AI source
controls. Versions 1–4 gain weather settings with requests **disabled**. Existing
AI sources, layouts and themes are preserved. Versions 1–5 gain vertical layout
and Celsius defaults; existing settings are upgraded without immediate writes.
Versions 1–6 gain default temperature/fan source choices while preserving existing
layout, colors, units, sources and provider settings. Versions 1–7 without graph
style fields gain **Hollow** styles, preserving their earlier line appearance.
The earlier Rust `theme=Ocean` format also keeps Hollow styles. New installations
and **Restore defaults** use Solid styles, matching the C application's default.
Each module's style is stored with its identity and visibility, so reordering or
hiding graphs does not move their style choices. Formats upgrade only when
preferences are next saved. Versions 1–8 gain inherited per-graph colors, preserving
their existing global palette and styles. Module color overrides follow module
identity through ordering/visibility changes and round-trip without quantizing
untouched RGBA values. Restore defaults clears all overrides in the draft.
Versions 1–9 gain inherited per-graph heights, retaining their existing default
height and layout. Individual heights are optional fields stored with each
module; missing/null values follow the default. Invalid values reject the whole
settings document. Restore defaults clears size overrides in the draft. The C
build does not serialize its per-graph height fields; legacy import keeps current
graph sizes instead of treating saved window geometry as graph dimensions.
Versions 1–10 without activity-bar fields, and the original `theme=…` format,
keep bars hidden to preserve their appearance. New installations and Restore
defaults enable Solid bars using graph series colors. Explicit legacy bar colors
disable series-color inheritance. Bar preferences are
stored separately from graph styles/colors and the exchanged theme document.
Versions 1–11 gain empty optional temperature/fan curve slots, retaining their
saved primary sources and automatic behavior. The two optional slots require a
primary, distinct valid source identities and exactly two nullable entries.
Malformed new fields reject the whole file; migration writes only on explicit save.
Versions 1–12 without an explicit width gain the 140-pixel minimum graph width without an immediate
write. Invalid widths reject the whole document. The C app does not serialize its
`graph_width` field; legacy import preserves the current minimum rather than
mistaking saved window geometry for graph width.
Version 15 appends a hidden Weather module to earlier twelve-graph layouts,
retaining their order, source preferences and deliberately all-hidden states. It
does not enable requests. Invalid older module sets remain rejected; migration
writes only when preferences are saved.
Version 14 adds optional activity-bar series-color inheritance; older saved bar
colors stay explicit. Existing dimensions and ordering are not rewritten.
Version 16 adds the display-only AI model-breakdown preference. Older Rust files
default to showing model rows, preserving their existing view. Migration retains
sources, layout and colors and writes only on explicit save. Invalid
model-display booleans reject the entire file. Grouped and expanded detail text is
prepared by the AI worker; GTK switches between cached views without collection
or JSON parsing. A dedicated GTK gate checks Apply/Cancel, reopening, Restore
defaults, persistence, immediate cached updates and retained rate history.
Version 17 adds the system sampling target, retaining a 1,000 ms default for older
files. Out-of-range, non-integer and malformed intervals reject the whole file;
migration writes only on explicit save. Worker timing and overrun handling have
deterministic schedule tests; a separate GTK gate starts at ten seconds, applies
a faster interval and checks cancellation, defaults, persistence and reopening.
Version 18 adds `window_opacity` as a finite fraction from 0.1 to 1.0. Older
settings default to 1.0, preserving their appearance without a write until save.
Invalid values reject the entire document. A dedicated GTK gate starts from saved
transparency and checks cancellation, draft-only defaults, minimum and fractional
opacity, fully opaque Preferences, persistence, reopening and applied defaults.
Version 19 adds optional `window_size` with bounded integer `width` and `height`.
Missing/null values retain automatic sizing, with no migration write until save.
Unknown fields or malformed/out-of-range dimensions reject the whole document.
The independent GTK size gate checks startup restoration, Cancel, draft-only
Restore defaults, Apply, resize capture through the real close-request handler,
persistence, reopening, and returning to automatic mode. It uses GTK normal-size
requests under Xvfb, rather than physical pointer dragging or a particular window
manager. Desktop-specific geometry behavior remains best effort; feedback is welcome.
Writes use private temporary files and atomic replacement; a single background
writer coalesces pending changes and flushes the latest value on normal shutdown.
Invalid, unreadable or unsupported settings files are preserved for the session:
changes can still apply in memory, and the status explains that saving failed.
Correct or move the file and reopen the app to enable persistence. Edits made by
another process are detected before saving and require reopening rather than
silently replacing the external changes. No legacy C settings file is modified.


## AI monitoring

The AI panel graphs **observed token-counter change per second**, polling every
five seconds on a separate worker. Core graphs keep their configured system schedule even
when provider scans or local APIs are slow. Tooltips/accessibility details show each
provider's locally retained token total, rate, source, recorded cost when available,
and errors. These totals are not account billing or a billing-period summary;
batched log writes produce bursts in the graph.

**AI monitoring…** in the title-band menu opens **Usage and models** plus a **Sources** tab. Usage
shows provider totals, observed rates, selected source, recorded costs and errors.
It also shows **token totals by model** for Claude logs, Gemini logs and Hermes
sessions, plus installed/loaded Ollama model names (up to 128 per list). Ollama
lists remain inventories; they do not supply token counts.

Claude model attribution follows the same message-ID replacement and cross-file
deduplication as its provider total. A replacement changes the count and model
together. Across copied files, the newest modification time wins; equal timestamps
use stable path order (the lexicographically later path wins), independent of file
creation/discovery order and cache warmth. An append within the same filesystem
timestamp tick does not establish which copy is newer. Gemini uses each message's
recorded model, falling back to the legacy
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
not reread. Cache stamps include device/inode, size, modification time and change
time, so ordinary same-size rewrites invalidate the cache even if mtime is restored.
Changed files are read in full and checked for mutation before/after parsing.
Growing JSONL files can reuse a decoded prefix only when device/inode still match
and a BLAKE3 digest verifies **all** bytes through the preceding complete newline.
Edits in the middle of a growing file invalidate reuse, not just boundary edits.
Truncation, replacement and same-size rewrites parse from the beginning. Gemini
whole-session JSON documents also always parse from the beginning.

Complete records lacking a final newline remain visible, but are excluded from
the reusable checkpoint. Each append reparses that final line, including partial
JSON/UTF-8, so anonymous records are not added twice and an extended invalid line
cannot retain its former count. Message-ID replacements, copied-message
deduplication, model groups and Codex's last cumulative total keep the same rules.
A failed file read/parse, including overflow or budget exhaustion, leaves that
file's cached snapshot and checkpoint intact. A provider result is published only after a
complete sweep. The checkpoint and visible snapshot share storage when possible;
an unterminated usage record can require a second bounded parsed view, each
subject to the existing message/model caps. This reduces JSON decoding work,
**not changed-file I/O**; incremental I/O for very large logs remains future work.

Incomplete scans publish no partial provider total. A failed source
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

The process panel graphs the number of **readable / running processes** in the current
PID namespace. Running counts mean process leaders whose stat state is `R`;
threads doing work under a sleeping leader do not increment that count. Its
tooltip and accessibility details list the top ten processes by
CPU and RSS, with PID, name, real UID when readable, threads, state and nice value.
Names come from `/proc/PID/stat`; command-line arguments and environments are not
read. **Processes…** in the title-band menu opens a selectable table with PID, name, real
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
namespaces restrict visibility.

Select a row to use **Terminate (SIGTERM)**, **Force Kill (SIGKILL)**, **Pause
(SIGSTOP)** or **Resume (SIGCONT)**. The same actions appear on right-click and
**Menu / Shift+F10**. Pause/Resume availability follows the sampled state. Selection
follows process identity through sorting and refreshes; filtering out or losing the
selected process clears it. Context menus capture their original target even if
selection later changes. Each action opens a confirmation naming the process,
PID and UID, with Cancel as the default. No signal is sent before confirmation.
Closing a review or its parent discards an unconfirmed action. Once confirmed,
results report signal delivery, not a promise that the process exited or obeyed it.
Failures remain visible independently of refreshing process statistics.

Controls require a live `/proc` mount matching the caller's PID namespace and
Linux `pidfd_open` / `pidfd_send_signal` support (normally Linux 5.3+; sandbox
policy may restrict them). Parsed fixture records and alternate proc roots cannot
be control targets. PID 0, PID 1, the monitor itself, exited processes and records
with unknown ownership are refused. The collector records proc directory identity
in addition to PID, start time and UID. Opening a review pins a pidfd, revalidates
those fields and checks kernel permission without delivering a signal. Confirmation
rechecks identity, ownership and name, then sends only the chosen signal through
that pinned handle. It never falls back to a numeric-PID signal or a process
group, escalates privileges, invokes a shell or retries with a stronger signal.
See the Linux [pidfd_open](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)
and [pidfd_send_signal](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html)
manuals and the kernel's [proc documentation](https://www.kernel.org/doc/html/latest/filesystems/proc.html).


**Details…**, row double-click/Enter and the process context menu open a read-only
inspector for the chosen process instance. It shows PID/parent PID, real UID,
start ticks, state, threads, CPU percent, accumulated CPU time, user/kernel ticks,
resident/virtual memory, RAM share, nice and raw kernel priority. These fields
come from the [kernel’s proc interface](https://docs.kernel.org/filesystems/proc.html).
CPU time uses the collector’s `_SC_CLK_TCK` with integer conversion; it excludes
waited-for child CPU time, does not add guest time twice and can exceed elapsed
wall time for multithreaded work. Missing clock/CPU/memory values remain
unavailable; measured zeros remain zero. Raw priority is displayed separately
from nice and is not an editable priority control.

Details consume the existing complete background reports, adding no file reads,
commands, command-line/environment collection or user-database lookups. Table
filtering, sorting and limits do not change their target or stop updates. Name
changes within the same instance update the readings. Missing/partial/failed
scans keep explicitly marked last-observed values rather than claiming the
process exited. A PID/start-time, ownership or source-identity change stops updates
permanently in that inspector; a delayed earlier report cannot reactivate it.
Open a new inspector to view a replacement process. Own/PID 1 inspection stays
available even when process signal controls are disabled. Up to eight inspectors
can be open; reopening the same instance reuses its window. Closing the process
table closes its inspectors. Freshness stays visible above the scrollable details;
updates preserve the reading position. The inspector GTK gate treats native
cleanup diagnostics as failures.

[Process inspector fixture](../../screenshots/linux-process-details-fixture.png) ·
[Identity-change fixture](../../screenshots/linux-process-identity-fixture.png).
These GTK4 Release captures use explicitly labeled copied test reports; the
identity-change condition is synthesized and no signals are sent.



## TPU / NPU neural accelerators

The tenth panel includes onboard **NPUs**, compute DSP/HTP endpoints and add-on
TPUs. Its saved module ID remains `tpu`; existing visibility/order settings and
legacy `show_tpu` imports keep working. Inventory, measured device activity and
producer-reported inference throughput are distinct quantities.

| Family | Inventory evidence | Activity in this build |
| --- | --- | --- |
| Intel NPU | `intel_vpu`/`ivpu`, accel-class aliases and known NPU PCI IDs | Elapsed delta of `npu_busy_time_us`; optional reported MHz and allocated-memory bytes |
| AMD Ryzen AI / XDNA | `amdxdna`, accel-class aliases and known AMD NPU PCI IDs | AIE2 readable-client busy-time activity when `drm-engine-npu` is exposed; other devices remain inventory only |
| Apple Neural Engine | ANE platform compatible/driver; known M-series SoC fallback | Inventory or explicitly unverified SoC capability; no Linux ANE utilization reader |
| Rockchip RKNN / RKNPU | `rknpu` and mainline `rocket` endpoints; selected known SoC fallback | Vendor `rknpu/load` mean core load when readable and uniquely owned; Rocket inventory only |
| Qualcomm Hexagon / HTP | NPU or compute DSP CDSP/NSP platform compatibles, with remoteproc state where exposed; selected known SoC fallback | Inventory; no inference/activity estimate from firmware or DSP state |
| Qualcomm Cloud AI | `qaic` and known PCI IDs, deduplicated with accel-class aliases | Inventory; activity unavailable |
| Arm Ethos, including NXP systems exposing Ethos | Recognized Ethos-U/N compatible or driver | Inventory; activity unavailable |
| NVIDIA DLA | NVDLA platform compatible or driver | Inventory; activity unavailable |
| Samsung Exynos NPU / MediaTek APU | Accelerator-specific platform compatibles; clock, power and IOMMU nodes excluded | Inventory; activity unavailable |
| Coral Edge TPU | USB firmware/runtime IDs and PCIe/M.2 apex devices | Existing producer-reported inference throughput, not device utilization |

**Detection is not a promise that inference will work.** Bound drivers, firmware
state and a running compute DSP do not verify the userspace runtime, firmware
compatibility or inference execution. Qualcomm audio/modem DSPs, generic FastRPC
presence, ordinary Intel/AMD PCI devices, GPUs and NPU clock/IOMMU nodes are not
counted as neural accelerators. Core/VF endpoints are not necessarily separate
physical chips; endpoint counts are not added into a performance estimate.

When no corresponding Linux endpoint is detected, selected known Apple,
Rockchip and Qualcomm machine compatibles produce a **SoC capability only**
record. It explicitly marks availability/activity unverified and is replaced by
real endpoint inventory when exposed. No runtime initialization is attempted.

The graph prefers real NPU activity percentages, with up to three device series
and all detected endpoints in **Live details**. Otherwise it retains the existing
unscoped inference-rate graph. Percentages and inf/s never share a scale, and
switching sources/scales clears their histories. Intel's first interval, counter
resets, rebind/hotplug, missing attributes and suspended devices warm up again;
zero is retained as a real reading. Implausible deltas are rejected (at most 2%
read/scheduling skew is clamped at 100%). Rockchip's multi-core report is averaged,
not summed; its global debugfs report is never copied onto multiple devices.
Missing/inaccessible counters remain **unavailable**, with no privilege escalation.

**AMD client activity** reads existing `/proc/PID/fdinfo/FD` records mapped to
`/dev/accel/accelN` through the accelerator class. It requires `amdxdna`, vendor
`1022`, an AIE2 device ID (`1502` or `17f0`), matching `drm-pdev` and
`drm-driver: amdxdna_accel_driver`, and `drm-engine-npu` in nanoseconds. This
recent interface is absent in older kernels. AIE4/PF/VF IDs remain inventory
only until their accounting hooks are verified; the existence of a generic
zero-valued field alone is insufficient. No accelerator device is opened.

The graph marks AMD values **(clients)** and uses the maximum observed
`100 × delta(client busy ns) / measured elapsed ns`, rather than summing clients
that can overlap. It represents driver-accounted submitted work for the busiest
observed readable client, not device-wide occupancy, capacity, TOPS or inference
throughput. Protected/exiting clients may be absent; partial scans are noted.
No readable counters means unavailable, not idle. First/new clients, rebinds,
missing data, non-increasing clocks and gaps over 300 seconds warm up; temporary
counter regressions retain the larger baseline until recovery. Impossible deltas
are omitted, with at most 2% read skew clamped at 100%. Histories reset when the
observed client set, binding or device/client source changes. Client memory,
clocks and power are not converted into activity estimates.

The GPU and AMD NPU paths share the bounded read-only DRM scanner: a cooperative
50 ms budget per scan, 4,096 process entries, 8,192 descriptors and 64 KiB per
record. AMD additionally bounds class-node discovery to 256 entries, observed
clients to 256 per device and retained baselines to 1,024 globally. Records with
duplicate fields, wrong identities/units, final-component symlinks or oversized
contents are rejected. Descriptor targets and physical driver bindings are
checked before/after acquisition. Tests use synthetic proc/sysfs data and do not
establish physical AMD hardware accuracy; community feedback is encouraged.

Discovery reads sysfs only: `/sys/class/accel`, PCI and platform devices, plus
known machine compatibles. It does not open accelerator device nodes, submit
ioctls, load firmware, reset hardware or change power/clocks. Rockchip load is read
only if an active vendor `rknpu` endpoint uniquely owns the report; other debugfs
controls are not read. Scans share a cooperative 100 ms budget, 4,096-entry root
limits and a 256-record NPU inventory cap. Attributes are limited to 4 KiB;
malformed/inaccessible optional telemetry preserves inventory with a note.
Kernel sysfs reads themselves cannot be forcibly cancelled by this budget.

Coral USB IDs `1a6e:089a` (before firmware initialization) and `18d1:9302` (runtime),
plus PCIe/M.2 `1ac1:089a`, remain supported. PCI and apex-class aliases deduplicate
by canonical device path. A bound apex driver's `temp` is millidegrees Celsius;
temperature reads are deferred while runtime power is suspended/transitioning.

Interface references: Intel [PCI IDs](https://github.com/torvalds/linux/blob/master/drivers/accel/ivpu/ivpu_drv.h)
and [sysfs counters](https://github.com/torvalds/linux/blob/master/drivers/accel/ivpu/ivpu_sysfs.c),
AMD [XDNA driver](https://docs.kernel.org/accel/amdxdna/amdnpu.html),
AMD [client counter interface](https://www.kernel.org/doc/html/next/accel/amdxdna/amdnpu.html#amdxdna-drm-client-usage-stats-implementation)
and [accounting implementation](https://github.com/torvalds/linux/blob/master/drivers/accel/amdxdna/aie.c),
Rockchip [vendor load format](https://github.com/rockchip-linux/kernel/blob/develop-6.1/drivers/rknpu/rknpu_debugger.c)
and [Rocket](https://docs.kernel.org/accel/rocket/index.html),
Qualcomm [CDSP bindings](https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/remoteproc/qcom,sm8550-pas.yaml)
and [QAIC](https://docs.kernel.org/accel/qaic/qaic.html),
Apple [ANE driver](https://github.com/eiln/ane) and
[SoC/device list](https://asahilinux.org/docs/hw/devices/device-list/),
Arm [Ethos-U driver](https://github.com/torvalds/linux/tree/master/drivers/accel/ethosu),
and Google's [apex driver](https://github.com/google/gasket-driver/blob/main/src/apex_driver.c).
Support is **best effort**: automated fixtures cover these interfaces; they do not
establish physical-device validation. Feedback, device reports and sanitized
counter samples are welcome and encouraged.

The existing `/tmp/xrg-coral-tpu-stats.json` integration is preserved for any neural
inference producer; its historical filename does not require a Coral device. The
inference engine must write a complete JSON object, preferably by atomic rename, for example:

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
hardware are explicitly labeled **hardware unverified**. Hardware without a readable activity counter or fresh producer statistics shows
**activity unavailable**. No device utilization is inferred
from USB connection, mapped pages, latency, temperature or inference counts.
Support remains best effort; device reports and feedback are welcome.

## Weather observations

Open **Weather** with the sun icon in the main toolbar. Requests are **off by
default**. Enable them, enter a four-character ICAO station such as `KSEA`, choose
Metric or US units, and press **Apply**. Station codes are normalized to uppercase;
invalid drafts leave active settings unchanged. **Close** discards unapplied edits.
No automatic location detection or API key is used.

Check **Show weather graph in the main strip** and **Apply** to display the compact
panel. This checkbox is independent of **Enable weather requests**; showing or
hiding a graph never opts in to requests. Graph visibility/order, styles, colors
and height are also available in Preferences, like other modules. The graph menu
opens Weather settings and offers **Refresh observations**, using the same bounded
worker and cooldown. **Close** discards both station and visibility drafts.

The face uses the saved weather Metric/US units independently of the system's
temperature setting. It shows station, temperature, wind, humidity, visibility and
pressure, with dewpoint, gust and **H/L (session)** when height permits. Set the
individual Weather height to about 128 pixels to fit all nine rows at the default
font. Full values, timestamp, age, source, raw METAR and exact retained session
high/low remain in Live details, tooltips and accessibility text.

[Fresh graph fixture](../../screenshots/linux-weather-graph-fixture.png) ·
[Stale graph fixture](../../screenshots/linux-weather-stale-fixture.png).
The weather observations in these GTK4 Release screenshots are explicitly labeled
synthetic data, with no network requests; CPU and memory readings are live in a
Linux validation VM.

The Celsius temperature curve retains up to **120 distinct observations received
during this station session**, in timestamp order with equal spacing. It is not a
24-hour archive or a forecast. Repeated worker ticks do not add points; a corrected
latest observation replaces its timestamp. Missing temperatures and gaps longer
than two hours stay gaps. Stale/missing observations leave a gap at the newest end
and no current-value bar. Cached readings are marked **STALE**. An older report
cannot roll the current values backward. Station changes and disabling clear the
history; unit/refresh changes reuse it. H/L uses only retained observations, not a
daily high/low. The signed plot range follows retained Celsius values; its axis is
not a utilization percentage or a thermal limit.

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

1. Xe PMU activity, additional vendor counters, board-specific conversion for raw
   thermistor/diode inputs, and optional process priority controls.
2. Safe Codex model attribution where cumulative records permit it, incremental
   I/O for very large logs beyond the verified append-parsing cache, and optional price tables.
3. Deeper metric preferences, broader XTF color-space support and legacy-field mappings
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
