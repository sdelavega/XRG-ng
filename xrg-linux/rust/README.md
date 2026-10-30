# Linux Swift / Rust transition

The active Linux frontend uses **egui / eframe**, with Rust collectors and the
shared Swift core. **GTK, GSK, Cairo and GLib are absent from the new executable's
Cargo dependency graph.** `Tools/check-linux-ui-deps.py` enforces this, and packaging
also rejects those libraries in the ELF runtime dependency closure.

The compact dashboard retains the macOS layout and the original **Classic**
palette: 140-pixel graph width, 90-pixel default height, draggable hostname band,
overlaid readings, thin separators and optional current-value / CPU-core bars.
All thirteen modules remain available. Supported older settings migrate in memory
to schema 25; missing collapse options retain an expanded window with hover
expansion disabled. Missing battery/weather options preserve charge-percent history and
the saved weather unit system. Existing AI tracking/alert choices are retained;
those missing from older profiles remain disabled. The next normal preferences
save writes the new schema. Existing source identities,
module order, colors, heights, JSON themes and original XRG XTF imports are retained.

The C/GTK3 application, its CMake build and the uncompiled GTK4 reference tree
have been retired from the checkout. The current application has no fallback
build of either implementation. [Retirement notes](../RETIREMENT.md) identify the
last historical revision and retained settings compatibility. Earlier GTK
screenshots remain historical artifacts; the captures below show the active UI.

[Classic](../../screenshots/linux-egui-classic.png) ·
[Midnight](../../screenshots/linux-egui-midnight.png) ·
[Preferences](../../screenshots/linux-egui-preferences.png).
These are native ARM64 debug captures with live Linux system readings; unavailable
hardware stays explicit and AI/weather collection is disabled in smoke mode.

## Keyboard navigation and scaling

Tab and Shift+Tab move through the application menu and visible graph order.
Focused graphs have a visible outline and scroll into view when necessary.
Enter or Space opens the focused graph's live details; Shift+F10 opens its graph
options. Mouse double-click remains supported. Escape closes preferences and
inspectors; Ctrl+, opens preferences and Ctrl+Q quits the dashboard.

The application menu includes Zoom controls. Ctrl+plus (or Ctrl+equals),
Ctrl+minus and Ctrl+0 also adjust/reset session UI zoom. Saved window dimensions
remain independent of UI zoom and restore at the same native logical size.
Graph widgets expose named button roles, current-status descriptions and
AccessKit activation; general preference fields and metric-source selectors
have associated labels. Automated accessibility-tree tests cover these semantics;
full screen-reader interoperability remains a separate validation task.

## Collapsing the dashboard

Ctrl+M, a double-click on the hostname, or **Collapse graphs** in the application
menu toggles a compact hostname strip. The **+** button expands the strip.
The vertical layout becomes a horizontal strip; the horizontal layout becomes a
vertical strip with a rotated hostname. Collection and accounting
continue while graphs are collapsed.

Preferences → General offers **Temporarily expand on hover**. After collapsing,
leave the strip and return to open the graphs temporarily; leaving retracts them.
An explicit expansion keeps the graphs open. Preferences, inspectors, menus and
pointer gestures keep temporary expansion open until those interactions finish.
The manual collapse choice persists; temporary hover expansion does not. Remembered
window dimensions always describe the expanded window, independently of UI zoom.

The collapse anchor selects top/left or bottom/right. X11 placement uses the window
coordinates supplied by the desktop. Wayland compositors control surface placement;
when global coordinates are unavailable, XRG-ng changes size without requesting a
position. Collapse is unavailable while maximized or fullscreen. Desktop size and
placement policies can differ; reports from real desktops are welcome.

## Desktop validation and idle diagnostics

Release CI runs `Tools/desktop-check-linux.py` under Fluxbox/Picom X11 and nested
Weston 13 Wayland on native x86_64 and ARM64 runners. It checks the actual native
window handle; Wayland clients have no `DISPLAY`, so an X11 fallback cannot pass.
The checks exercise window resizing, saved-size restoration, Ctrl+, Preferences,
Escape cancellation, Enter/Space graph activation, CPU detail windows and clean
application shutdown. X11 also covers minimization. Additional native interaction
cases use a 125% X11 native-scale override and 125% UI zoom on Wayland. Headless rendering/accessibility checks cover
100%, 125%, 150% and 200% scale. Saved dimensions are compared with independently
measured window bounds before a relaunch, so UI zoom cannot silently shrink them.

Debug and release CI also run `Tools/collapse-check-linux.py` on both backends,
with both layouts and anchors at normal and 125% scale/zoom. It independently
measures native strip bounds, exercises hover, Preferences, explicit expansion,
title double-click and the + button, checks sampling progress while collapsed,
and relaunches from the saved latch without changing expanded dimensions.

Each run uses disposable HOME/XDG directories with AI and weather disabled. It
records process CPU time as a percentage of one core, RSS/PSS, voluntary thread
context switches and root UI pass rate at one- and ten-second sampling intervals,
including a translucent window. `XRG_DESKTOP_REPORT=1` enables bounded diagnostic
counters; normal launches collect none of these QA counters. Publication callbacks
wake the UI directly, without the former 100 ms polling thread. CI rejects a
continuous idle repaint loop, but records CPU/memory values without brittle
machine-specific pass thresholds.

These are software Mesa/Pixman results in isolated desktops. They do not establish
physical GPU power consumption, multi-monitor scale transitions, native Wayland
fractional-scale protocol behavior, every desktop's focus/placement policy or
accessibility interoperability. Those remain
best-effort validation areas for real-world feedback. JSON reports, application
logs and desktop captures are retained with the CI validation artifacts.

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

### Physical ARM64 checks (2026-10-30)

A fresh runtime bundle from `0fdf7a3` was tested without installing system packages
or toolchains on either device. AI providers/weather were disabled in isolated
preferences; existing apps and settings were preserved.

| Hardware / OS | Observed validation | Limits |
| --- | --- | --- |
| Raspberry Pi 5 / 64-bit Debian 13.4, Raspberry Pi kernel 6.12.75 | Live CPU/memory/network/disk samples, four temperature inputs and PWM fan RPM; Xvfb/X11 smoke passed. Native Wayland app smoke exited 0 and its own diagnostics reported V3D 7.1.7.0 rendering. | Headless `labwc` segfaulted during shutdown (exit 139), reproduced separately from the successful app exit. This is not an unqualified compositor/session pass. No TPU/NPU endpoint was present. |
| Orange Pi 5 Plus (RK3588) / Beryllium OS (Arch-derived), kernel 6.1.75-rkr3 | Live system samples, eight temperature inputs and one NPU endpoint; Xvfb/X11 smoke passed. A separate EGL pbuffer clear/finish probe reported Mali-G610 MC4 (Panfrost), OpenGL ES 3.1 / Mesa 26.0.3. | No native Wayland app session was tested. NPU activity remained unavailable; devfreq reported `100@1000000000Hz` while runtime status was `suspended`, so it is not treated as verified inference utilization. No readable fan RPM. |

Both initial headless probes reported unavailable device-wide GPU utilization/VRAM;
the Pi's hardware-rendered UI also exposed explicitly labeled client activity.
Client activity is not whole-device utilization, and working rendering does not
prove complete GPU telemetry. Apart from the RK3588 follow-up below, NPU compute
workloads remain unverified. Native package installation, full desktop
interaction/accessibility, suspend/resume and power use also remain unverified. These checks expand the best-effort matrix; they do not certify every
board image or driver. Feedback on these platforms remains welcome.

A follow-up RK3588 experiment used a temporary vendor RKNN runtime and MobileNet
model outside the app: 3,950 inference calls completed in eight seconds on core 0.
Privileged debugfs sampling observed core 0 up to 91%, cores 1/2 at 0%, then idle
and suspended state. XRG averages the three reported cores (91/0/0 means about
30.3% overall), rather than displaying the busiest core as whole-device usage.
The collector now recognizes the vendor's uppercase `RKNPU` driver alias. This
validates the counter under one workload. A patched debug headless app then
reported 0% to 30.7% during 3,971 further inferences over eight seconds, followed
by unavailable activity after suspension. This is not a general throughput benchmark
or a packaged release/UI test. On this image debugfs requires root, so an
ordinary unprivileged app still reports activity unavailable. XRG does not elevate
privileges or bundle the experimental vendor runtime/model. Devfreq load remains
excluded from NPU activity. Other vendor/runtime combinations remain best effort.

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
  inventories, model-attributed usage records, observed token deltas, station validation and dated METAR observations. Missing weather
  values have explicit validity flags, so a valid zero is not treated as absent.
- **Rust:** owns `/proc` and `/sys` collection, egui painting, configuration and
  lifecycle. System and AI workers create/own their mutable Swift handles. They send only copied
  Rust snapshots through bounded latest-value slots; the frontend consumes them on its UI
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
without inventing macOS wired memory. Net/Disk faces show observed session transfers
and the latest rates. Compact B/K/M/G/T suffixes use powers
of 1024. Raw kernel lifetime counters remain in Live details. Session totals count
valid deltas since the first monitoring sample or an explicit transfer reset;
they are not disk capacity or counters since boot.
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
headless or live desktop smoke checks fail on desktops/containers without that hardware.
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
| Intel xe | Opt-in PMU active/total-tick busiest-engine activity; readable DRM-client busy/total cycles and resident allocations; available hwmon |
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
are skipped before scanning.

**Intel Xe PMU activity is opt-in**, under Preferences → Metric sources →
**Intel Xe PMU power policy**. It is off for new and migrated settings. Enabling
it can keep active Xe GPUs awake and increase power consumption: the driver holds
runtime-PM/forcewake references for the lifetime of engine events. The preference
applies to all active Xe adapters, independently of the displayed GPU source.
Disabling wakes a sleeping system worker and closes its Xe counters at the next
control boundary; in-flight collection must finish first. Source-selection Apply
also wakes the same worker without rebuilding the other collectors or changing
the configured sampling period.

The backend maps the PCI-qualified `xe_*` PMU and render node, verifies device
numbers/driver identity, and uses the read-only [`DRM_XE_DEVICE_QUERY_ENGINES` API](https://docs.kernel.org/gpu/driver-uapi.html)
for engine class, instance and GT IDs. It validates exported event bit layouts and
pairs `engine-active-ticks` with `engine-total-ticks` in perf groups. Activity is
`100 × Δactive ticks / Δtotal ticks`; host time and GPU frequency are not the
utilization denominator. The graph plots the busiest engine, never their sum.
The first interval and missing/zero/regressed totals remain unavailable. A valid
zero active delta is measured idle. Group IDs, enabled/running time, rebinds,
suspend, CPU/PMU changes and clock gaps are checked. Multiplexed/incomplete
intervals are rejected. Up to 5% active/total read skew clamps to 100%; larger
overshoot is rejected. Counter open/read failures release the whole adapter's event set and back
off for 30 seconds. Existing readable-client activity remains the fallback.

Known-suspended adapters, VFs and PFs with enabled SR-IOV VFs are deferred. Current
native acquisition targets Linux x86_64/ARM64 with real `/sys`; custom sysfs roots
never open host DRM/perf. Query sizes are bounded to 64 hardware engines per
adapter, and Xe sessions have a conservative 256-descriptor budget. Acquisition
and read loops have cooperative 100 ms budgets; an individual kernel call is not
forcibly interrupted. Render nodes are opened read-only with no-follow and
nonblocking flags. No GPU work is submitted and no kernel permissions/sysctls are
changed. Missing event support or denied access stays explicit.

Xe support is **best effort and has not been physically validated on Xe
hardware**. Feedback and sanitized device reports are welcome and encouraged.
Fixtures cover ABI records, pair math, topology/identity checks, handle release,
clock/reset behavior, permissions and custom-root gating. The archived GTK policy
gate uses live proc with custom sysfs containing only copied block-device names,
verifies Apply/Cancel/defaults/persistence,
and checks that policy changes wake a ten-second wait; it opens no GPU counters.
See the kernel's
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

Build natively on x86_64 or ARM64 Linux with Swift 6.3+ (CI: 6.4.1), Rust 1.99.1,
a C compiler, pkg-config and X11/Wayland/OpenGL development libraries. For Ubuntu
24.04 install `libxkbcommon-dev libxkbcommon-x11-0 libwayland-dev libx11-dev libxi-dev libxrandr-dev
libxcursor-dev libegl1-mesa-dev libgl1-mesa-dev libgl1-mesa-dri`, plus the normal
compiler tools. GTK development packages are not needed.

```sh
swift test
cargo test --manifest-path xrg-linux/rust/Cargo.toml --locked
cargo run --manifest-path xrg-linux/rust/Cargo.toml --features egui-ui
cargo run --manifest-path xrg-linux/rust/Cargo.toml -- --headless --samples 3
bash Tools/ci-linux.sh debug
bash Tools/ci-linux.sh release
```

`egui-ui` is optional; the core-only build retains no GUI toolkit. The build script
builds shared Swift automatically; CI supplies `XRG_SHARED_LIB_DIR` to reuse the
exact Swift artifact already tested. Native architectures must match. Development
binaries use a build-directory rpath; distribute the complete preview bundle,
including its Swift runtime, rather than moving the ELF executable alone.

The current eframe renderer is **Glow (OpenGL)** through winit, supporting X11 and
Wayland. Our graph geometry uses egui meshes, paths and primitives; it is independent
of that renderer. No GTK file chooser or native-theme helper is included.

```sh
docker build -f xrg-linux/Dockerfile.swift-rust -t xrg-ng-linux-dev .
docker run --rm -v "$PWD:/workspace" xrg-ng-linux-dev
```

CI checks shared Swift, the C ABI, Rust formatting/Clippy/tests, live headless
samples, the dependency exclusion guard and native egui windows under Xvfb/Mesa.
The Cairo graph regression cases now inspect egui's production tessellated meshes:
styles, clipping, gaps, signed baselines, overlapping series, alpha and current
bars. UI tests verify that merely displaying each preferences tab preserves the
complete draft, including unavailable saved sources and full color precision.

The native smoke flow has a **20-second deadline**, isolated temporary preferences,
no AI-provider scans or weather requests, valid worker samples and repeated graph
draws. It opens preferences/inspectors, changes cadence and presentation, verifies uniform final-frame alpha with
overlapping graphs and a transparent custom-theme base, checks a
three-second sampler wake, reopens persisted settings and round-trips a theme.
Classic and Midnight captures run separately. These checks exercise native OpenGL
through Mesa software rendering; they do **not** establish physical GPU behavior,
Wayland compositor behavior, screen-reader interoperability or idle power use.
A separate native chooser gate covers XTF load, new JSON export, replacement
confirmation/cancellation, legacy review, rejected files and unchanged active/saved
preferences on Cancel. Its screenshots are exported. The same chooser gate also
runs against the installed preview without build toolchains.
The retired GTK widget smoke gates remain in Git history and are not claimed as
egui validation. The managed desktop checks above separately exercise X11 and
nested Wayland; the runtime-only installer gate still uses Xvfb without a shell.

Release packaging retains the tested binary/Swift library, runtime notices, input
hashes and corresponding source with locked vendored Cargo dependencies. It checks
offline resolution and relocatable `$ORIGIN` paths. Runtime-only checks use an
unprivileged user without Swift/Rust or GTK installed and exercise launch,
relocation, the installed desktop entry's Exec arguments, upgrade, rollback,
uninstall and preservation of unrelated files/settings. Desktop argument decoding
is tested directly; no running desktop shell is implied by Xvfb.

```sh
python3 Tools/package-linux.py --binary /absolute/path/to/release/xrg-ng-linux \
  --swift-library /absolute/path/to/libXRGSharedCore.so
```

Add `--deb` on Ubuntu 24.04 to also create an `amd64` or `arm64` native preview
from the same verified payload. CI publishes both formats and their checksums.
The `.deb` includes the private runtime, corresponding source and notices, uses
standard `/usr` paths and has no maintainer scripts or configuration files in
user homes. `--deb-revision N` selects a positive packaging revision (default 1).
System-library lower bounds conservatively match the installed build-image
packages; graphics/windowing dependencies loaded at runtime are declared
explicitly. A newly linked system library without a package mapping stops the
native build. Packages target fully updated Ubuntu 24.04, not arbitrary Debian
derivatives. See the [preview guide](../preview/README.md#native-ubuntu-package-preview)
for installation, removal and coexistence with a per-user archive installation.

Native packaging uses [dpkg-deb](https://manpages.debian.org/trixie/dpkg/dpkg-deb.1.en.html)
with root ownership metadata and a source-commit timestamp/hash in its preview
version. Standard-library unit tests cover input integrity, missing source/notices,
ELF architecture, control metadata, ownership, version ordering and deterministic
wrapping of identical fixture inputs. These do not establish reproducibility of
the entire application build. Runtime-only CI lets APT resolve the package's
dependencies, verifies the installed payload, and launches the desktop and chooser
flows under an ordinary UID. It tests a synthetic higher packaging revision with
the same application bytes, removal/purge, and preservation of user/legacy data.
Ubuntu's minimal container excludes documentation by default; the test passes
package-specific include options to retain and verify all source/notices without
editing global dpkg settings. Both native and archive gates remain required.

`--rpm --arch --appimage` adds Fedora RPM, Arch/Arch Linux ARM `.pkg.tar.zst` and
type-2 AppImage outputs for the native x86-64 or aarch64 build. CI publishes every
format with a SHA-256 file. Shared payload validation/staging prevents wrappers
from changing the tested runtime bytes or losing source/notices. RPM uses explicit
system dependencies and exports no private Swift SONAME provides. Arch packages
include `.PKGINFO` and `.MTREE`; provenance describes the Ubuntu-built application,
not an invented makepkg build environment. No application install scriptlets run.

Fedora 44 and Arch runtime jobs use native runners, resolve package dependencies,
verify payloads, launch GUI/chooser flows as an ordinary UID, upgrade to a higher
packaging revision with unchanged application bytes, and remove the package while
checking saved data. RPM build tools are added only after the initial runtime-only
launch to construct its upgrade fixture. The ARM Arch job imports the official
signed Arch Linux ARM root filesystem, verifies its published signing fingerprint,
and keeps repository signature checking enabled. Container pacman downloads use
`--disable-sandbox` because Docker may reject Landlock; applications still run
unprivileged. These are userspace checks, not physical-board validation.
Minimal Arch containers can also exclude documentation; their test uses a
temporary package-specific `NoExtract` exception without modifying system
configuration or signature policy.

AppImage's upstream runtime asset IDs, source revision and hashes are pinned in
`Tools/appimage-runtime.json`. Its source/license archives are included separately
from the application's corresponding source. Tests execute relocated images through
the FUSE-free extraction path; FUSE mounting itself remains unvalidated. Runtime
source/build notes are in `Tools/appimage-runtime-README.md`. See the
[format installation guide](../preview/README.md#rpm-arch-and-appimage-previews).

## Sensor statistics (development build)

**Application menu → Sensors and statistics…** (also available on Temperature
and Fans) lists all readable temperature and fan inputs with current, minimum,
sample-weighted average, maximum and sample count. Accumulation is independent of
graph selection and starts with the application. Display units follow Preferences;
temperature statistics remain Celsius internally. A missing input shows **n/a**
for current while retaining its historical statistics; a new physical input
incarnation at the same source starts fresh statistics. Labels do not establish
CPU/GPU ownership. Collection errors and fan driver alarms are included.

**Copy sensor report** copies a text report with source identities, statistics and
collection notes. **Reset session statistics** clears this accumulated data at the
next sample without changing graph histories, source selection or sampling.
Statistics are bounded to 4,096 input identities and are not saved between runs.
This inspector is newer than the published Linux 0.2.0 release.

## Graph actions and live details

Drag the hostname to move the dashboard. The title menu opens Preferences,
Processes, AI usage, Weather, themes, About and Quit. Right-click a graph for its
live details, style, visibility and preferences. Double-click also opens details.
The `Ctrl+,` shortcut opens Preferences. Details consume copied worker snapshots;
changing a source hides mismatched old readings until a matching report arrives.

**Clear graph history** is available on every graph and its Live details window;
the application menu also offers **Clear all graph histories**, including hidden
modules. Clearing removes prior plotted samples without resetting collectors,
rate baselines, source preferences, sensor statistics or transfer/AI totals.
Old samples remain gaps until new readings arrive. AI waits for its next provider
poll and rejects queued plots from before the reset. Weather keeps its latest
observation as the restart point and retains its older-response guard; clearing
does not fetch new weather or manufacture observations.

Network and Disk additionally offer **Reset session transfers**. Counting starts
with a fresh baseline at the next sample, while the graph and rate baseline stay
intact. Session totals restart automatically when selection, aggregate membership,
device identity or a counter reset changes their scope. Failed reads preserve
already-counted bytes, exclude the missing interval, and mark totals with **≥**
for partial coverage. The first recovered read re-establishes a rate baseline.
Totals use full 64-bit deltas even when the shared instantaneous rate saturates;
arithmetic saturation is explicitly marked as a lower bound. Sessions and manual
graph resets are not saved between launches. These controls are newer than the
published Linux 0.2.0 release.

## Graph and theme preferences

Preferences has General, Graphs, Sources, AI, Weather and Themes / import tabs.
Edits remain in a draft until **Apply**. **Cancel** discards edits; **Defaults**
changes only the draft, preserving AI-provider and weather-source preferences as
in the previous frontend. Invalid settings leave the active configuration unchanged.
Existing invalid/unreadable preferences remain protected by the same Store/Writer.

General controls layout, graph width/default height, sampling (250–10,000 ms),
temperature units, opacity, optional remembered window dimensions, network scale
floor (whole B/s; zero = automatic), and current-value bars. Opacity applies only
to the completed dashboard frame through an OpenGL compositing pass (not per-shape
fading) and requires a compositing desktop. The theme window base stays opaque
before this pass; theme-layer alpha remains independent of whole-window opacity. Graphs controls visibility,
order, four drawing styles, individual heights and optional background/series
color overrides. Sources retains missing saved identities and offers CPU,
network, disk, GPU/VRAM and up to three distinct temperature/fan channels. Intel
Xe PMU activity remains explicitly opt-in with its power-policy explanation.

The six built-in themes remain available alongside custom palettes. Themes /
import edits the seven named RGBA colors, loads JSON or original XRG `.xtf` files,
and exports portable JSON. **Browse to load…**, **Browse to save…** and
**Browse legacy settings…** open the built-in egui file picker; pasted paths
remain available. The chooser supports folder navigation, case-insensitive
JSON/XTF filtering, hidden files, filename search and explicit replacement review.
Loading/importing changes only the preferences draft; saving exports its palette.
Selecting a loaded XTF for export initially suggests a separate JSON filename.
New-file exports publish atomically without replacing a racing writer.

Directory inspection runs on one background worker per chooser, with coalesced
requests, a 4,096-entry cap, cooperative 100 ms scan budget and cancellation.
Incomplete listings are labeled; enter a filename directly to reach an unlisted
file. File contents are read only after selection, on the existing file worker.
Raw non-UTF-8 Unix filenames survive selection; file links and special files
remain rejected by the bounded file readers. Folder links may be entered
explicitly; directory listing does not recurse into links. **Ctrl+L** focuses
the folder path, **Alt+Up** navigates to its parent, **Ctrl+H** toggles hidden files,
**Ctrl+R** reloads and **Escape** cancels. File-format bounds, color conversion,
validation and settings/theme separation remain in the existing Rust backend.

[File picker preview](../../screenshots/linux-egui-file-picker.png) ·
[Replacement confirmation](../../screenshots/linux-egui-file-replace.png).
These native ARM64 Debug captures use disposable fixture files, with active and
saved user preferences unchanged by the chooser flow.

Custom theme documents contain `format: "xrg-ng-theme"`, `version: 1`, a printable
name and seven RGBA arrays in window, graph background, series 1/2/3, border and
text order. Components are finite 0–1 values. Files are capped at 128 KiB. The XTF
reader supports the previously verified RGB, grayscale and sRGB/Display-P3 cases;
it does not execute an Objective-C unarchiver. Theme alpha and window opacity are
separate. Untouched colors retain their original numeric precision.

Portable JSON palettes can also be loaded and saved by the current macOS
development build through Preferences → Appearance. Original XTF load/save
remains available on Mac. The published macOS 0.1.0 release is XTF-only; JSON
exchange requires a newer build. Both parsers use the same acceptance fixtures
under `Shared/Tests/Fixtures`, including duplicate-key, version, Unicode-name,
array-shape and numeric-precision cases.

## Importing legacy Linux settings

In Themes / import browse to the C application's `settings.conf`, or enter its
path and select **Review pasted path…**. The report lists imported/skipped fields. **Import
into draft** transfers supported settings for review; only Apply changes the
active application. Cancelling keeps the original state. The legacy file is
read-only and startup does not import it automatically. The new app saves to
`$XDG_CONFIG_HOME/xrg-ng/settings.conf` or `~/.config/xrg-ng/settings.conf`.

## AI monitoring

The AI inspector uses the existing background worker's cached provider/model
reports. Preferences retains provider enablement, Claude source selection, optional
log/database paths, loopback metrics/Ollama endpoints and the display-only model
breakdown. The display toggle preserves sources and token histories. Scanning,
SQLite, HTTP and Swift parsing remain outside the UI thread. Disabled, unsupported
attribution and unavailable cost/activity states remain explicit.

### Observed session/daily counters and budgets

Enable **Track observed session/daily usage** in Preferences → AI. The separate
desktop-alert checkbox is also off by default. The AI usage inspector provides
independent session/daily resets, exact input/output and unknown-split counts,
available daily model/provider aggregates, budget progress, persistence errors and
notification status. Compact AI graphs show session and daily totals. Accounting
continues in the AI worker while the graph is hidden; UI refreshes cannot drop
usage events. Budget or aggregation changes preserve provider graphs and rates.

The delta ledger is the same portable Swift implementation used by macOS, reached
through a bounded, thread-confined ABI. First complete samples establish baselines
without importing historical usage. Failed reads, source/counter changes and
tracking transitions break continuity. Session/daily resets discard observations
already in flight and establish fresh baselines while preserving graph histories
and historical provider totals. Midnight auto-reset uses the local calendar day;
tokens are assigned when observed, not by reconstructing event timestamps. Gaps,
log edits and baseline transitions can undercount activity. These are not invoices.
Ollama inventories supply no token counter. Model metadata never adds tokens to
the provider total; late/inconsistent attribution stays unknown.

Daily totals and the once-per-day alert marker are saved atomically with private
file permissions in `$XDG_STATE_HOME/xrg-ng/ai-usage.json`, falling back to
`~/.local/state/xrg-ng/ai-usage.json`. Session counters start at zero each launch.
A separate advisory lock allows one owner; competing instances retain in-memory
counters with an explicit persistence warning and no desktop alerts. Invalid,
unsupported, unreadable or externally changed files are preserved. Save failures
are shown in the inspector and suppress notifications. Daily model aggregates
retain at most 256 names; truncation is marked without losing provider totals.
Disabling aggregation retains earlier rows and stops adding new ones until enabled.

A positive budget and desktop-alert opt-in enable one attempt per local day
(or after Reset Daily), once the observed threshold is crossed. The marker is
saved before delivery. Alerts use the
[freedesktop notification interface](https://specifications.freedesktop.org/notification/latest/)
directly through Rust/zbus, without GTK, GLib or libnotify. Connection and reply
share a one-second deadline. Missing services, denials and timeouts are explicit;
there is no automatic retry that day. Acceptance by the service does not guarantee
a visible banner; desktop policy, do-not-disturb and notification settings apply.
Fixtures exercise a private D-Bus daemon; normal tests do not contact the user's
notification service or change desktop preferences.

### Resumable JSONL scans

Linux Claude, Codex and Gemini JSONL scans retain unfinished file work across
polls. A slice that reaches the provider's cooperative two-second or 128 MiB read
budget reports read progress, then resumes from the saved cursor and buffered
record. It retains at most one unfinished file per provider, using 64 KiB reads
and an 8 MiB record buffer. No open file descriptor survives a poll. Only a
complete successful provider sweep publishes totals and model attribution.

Each slice reopens a regular file and validates device/inode, size, modification
time and change time before and after reading. A changed or replaced file restarts
its draft; deleted logs discard their pending work. Appended files still verify
every saved prefix byte before reusing decoded records, including the middle of
the file. This saves restart work when a scan yields; it does not turn prefix
verification into tail-only I/O. Complete records without a final newline remain
visible and are replayed safely if more bytes arrive.

The existing limits remain: 64 MiB per file, 8 MiB per record or whole Gemini JSON
session, 20,000 discovery entries, 100,000 cached message identities per provider
and 256 model groups. Legacy Gemini JSON documents still use whole-document
decoding. A file that keeps changing during every unfinished read can delay a
complete snapshot; incomplete work reports progress rather than partial totals.
The shared Swift record decoders and macOS scan path are unchanged.

### Codex model evidence

The Linux and Mac model breakdowns can attribute a cumulative increase to the preceding
valid `turn_context.model` when `last_token_usage.total_tokens` matches that
increase and `last_usage_includes_reasoning` is a recorded Boolean. Both Boolean
values qualify. Missing/null markers, initial unseen history, mismatched deltas
and synthetic context-window fills remain unattributed. Repeated cumulative
snapshots never add tokens. Cumulative resets discard the old partition; invalid
contexts, routing changes, compaction and turn boundaries require a new context.
These are **recorded turn models**, not proof of the backend model that served a
request. Quota aliases and reroute targets never supply a model name.

This follows the [Codex protocol at revision 9cc14e7](https://github.com/openai/codex/blob/9cc14e79882ff8885cd5d33b4adadae014045aef/codex-rs/protocol/src/protocol.rs),
including its distinction between real request usage and context-window fills.
Older or incomplete logs may have no usable model breakdown. The shared Swift
decoder still determines cumulative provider totals independently of optional
model metadata. Named rows plus unattributed usage sum to those totals, including
sessions with no usable model evidence. The same shared decoder now preserves
explicit cumulative `input_tokens` and `output_tokens` when they fit the recorded
total; absent components remain unknown and inconsistent splits become entirely
unclassified. Cache and reasoning subfields are not added again. No split or price
is inferred. Linux provider/model details and Mac's **Codex Log Snapshot** menu
keep cumulative logs separate from observed session/daily counters. Codex model
rows currently carry totals only; their individual input/output splits and prices
remain unavailable. The existing model display toggle hides model rows without
changing collection or history.

At most 255 named groups and one unattributed group are kept per session and per
provider; additional distinct names fold into unattributed usage. These limits
do not discard tokens or turn excess Codex model metadata into a provider error.
Linux model state shares verified scan checkpoints, so resumable reads, EOF replay,
rewrites and replacement files cannot retain stale attribution. Mac uses complete
bounded per-file snapshots in its metadata cache, with I/O/size failures preserving
the last complete sweep. Reset/enable transitions invalidate pending scans. A
common fixture corpus checks both attribution implementations and the shared
component decoder. Fixtures are
synthetic; tests do not read personal sessions or contact live AI providers.

## Processes

The process table retains name filtering, saved UID filtering, row limit and
CPU/RSS/PID/name sorting. CPU 100% means one logical core. Read-only inspectors
use the existing pinned-instance View and copied reports, retaining explicit
stale/partial/identity-change states. Signal tools use the existing validated
pidfd Target and require a separate confirmation showing PID/start identity.
Cancellation drops the pending handle. There is no numeric-PID fallback or
privilege elevation. Priority editing remains deferred. Backend kernel tests
signal only disposable test children.

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
| Rockchip RKNN / RKNPU | Vendor `rknpu`/`RKNPU` and mainline `rocket` endpoints; selected known SoC fallback | Vendor `rknpu/load` mean core load when readable and uniquely owned; Rocket inventory only |
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
only if an active vendor `rknpu`/`RKNPU` endpoint uniquely owns the report; other debugfs
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

Preferences controls optional network access, ICAO station, Metric/US units and
5–60 minute refresh. Graph visibility remains independent. The Weather inspector
shows the cached observation and offers refresh through the existing worker and
cooldown. Parsing uses shared Swift METAR code. Station changes suppress stale
old-source reports. Missing/stale values remain explicit; zero is a measurement.
History retains up to 120 distinct session observations, not a 24-hour archive or
forecast. Requests remain off by default. No location detection is performed.

## Remaining migration

- Broader interaction/accessibility gates and physical GPU/power measurements.
  Managed X11 and nested Wayland checks now cover window interaction and idle
  process costs; other compositors, scale factors and hardware still need feedback.
- Additional vendor counters, Xe virtualization/topology coverage, board-specific
  raw thermistor calibration and optional process priority controls.
- Broader large-log/discovery coverage and Codex protocol compatibility,
  optional price tables, broader XTF color spaces and legacy-field mappings.
- Signed package repositories and further release automation. Signed/tagged Linux
  0.2.0 standalone Debian, RPM, Arch, AppImage and archive releases are available;
  see [verification instructions](../../signing/README.md). Hardware support remains
  best effort; feedback is welcome and encouraged.
- Remaining cross-platform presentation and workflow gaps are tracked in
  [PLATFORM_PARITY.md](../../PLATFORM_PARITY.md).


## Battery power mode and independent weather units

Preferences → Graphs → Battery → Battery history offers **Charge (%)** (the
existing default) and **Charging/discharging power (W)**. The power curve uses
reported watts (or the collector's existing current/voltage conversion) with
charging above zero and discharging below it. The symmetric axis spans at least
±30 W, matching the Mac power view's minimum range. Unknown direction or missing
power stays a gap, while reported zero stays zero. Up to three batteries retain
separate curves. Both histories collect together; switching display mode preserves
their units and values. Clearing the battery graph clears both histories. Battery
power is not wall power; charging limits and hardware controls are never written.
Driver fields follow the [kernel power-supply class](https://docs.kernel.org/power/power_supply_class.html).

Preferences → Weather retains its Metric/US default unit system and adds
independent overrides for temperature (°C/°F), visibility (km/mi), pressure
(hPa/inHg), and wind/gusts (knots/km/h/mph). Wind defaults to the visibility unit
system until overridden. These choices change labels/axes and inspector text,
without changing Celsius observations or making another network request. Saved
profiles without overrides keep their prior readings. Missing/stale data and
visibility qualifiers retain their previous meaning.

## Weather history windows and secondary curves

Preferences → Weather adds **Session (legacy)**, **Last 6 hours**, **Last 12 hours**
and **Last 24 hours**. Existing profiles retain the session default (up to 120
distinct observations). Time windows include dated reports received from the
station response and the current session, using actual UTC observation spacing.
The cache is bounded to 36 hours and 2,048 observations, held in memory only.
Changing window, curve or units uses the cache without making another request.

The optional secondary curve offers wind, humidity, visibility, dewpoint or
pressure with its own vertical scale. Temperature remains the primary curve;
secondary curves use outlines so their fills cannot obscure it. Scales and units
are included in the graph details. Missing fields split lines, visibility bounds
such as `<¼ mile` are not plotted as exact measurements, and intervals over two
hours remain gaps. Stale observations retain the received history with current
bars suppressed. Corrections replace the same timestamp; regressed responses
cannot replace the current observation. Graph reset keeps the newest observation
and prevents older cached rows from repopulating the cleared graph.

H/L covers only received temperatures in the selected window. It is not a
meteorological daily high/low, a guaranteed complete archive or a forecast.
Provider coverage may be shorter than the selected window. No location detection,
forward fill or synthetic observations are added. Station changes clear history.
The Mac Weather panel offers the same time windows while retaining its received
response default. Defaults and provider coverage remain platform-specific.


## Log source continuity

AI log totals describe the currently retained files. Observed session/daily counters
and graph rates additionally track the last **complete inventory**. Adding or
removing a matching file, renaming it, replacing its device/inode, shortening it or
reducing its per-file token total establishes a fresh provider baseline. A decrease
in one file is detected even if another file grows enough to hide it in the sum.
The Mac miner follows the same policy through a shared Swift file-state predicate.

Ordinary nonshrinking updates of known files with nondecreasing totals continue
counting. Imported history and replacement files do not become newly observed
usage, rates, model aggregates, alerts or mixed-cost-rate spikes. Existing observed
counters and plotted history remain intact. A failed or unfinished sweep does not
commit a new inventory. Errors break accounting continuity, and the first complete
recovery sample becomes a baseline; Mac can retain cached numeric data for display.

This intentionally favors avoiding inflated usage over capturing every token during
ambiguous transitions. A live new log's first snapshot and concurrent activity in
other files may therefore be excluded. It is not an exact per-request or billing
ledger. Metadata alone cannot identify a same-inode, nonshrinking rewrite with a
nondecreasing counter; unobserved changes between polls and duplicate transcripts
can also remain ambiguous, with format-specific deduplication differing by platform. Those deeper format-specific cases and retained-history duration still need alignment. No settings
migration or tracking-default change is required.


## AI collection cadence

Both platforms use a shared nominal **five-second** AI collection interval. Linux
continues to use its independent AI worker; Mac now has a dedicated common-mode
AppKit timer and a monotonic cadence gate independent of graph refresh. Updating
or resizing graphs does not fetch another observation. A slower system graph
refresh does not prevent the AI timer from collecting, including hidden accounting.

The Mac miner consumes completed background log scans and localhost responses
before publishing one rate/accounting observation. Metadata caching avoids rereading
unchanged logs, while an eligible cycle bypasses the old scan-start throttle.
Overlapping requests coalesce; missed ticks do not add invented samples or replay
an accumulated backlog. Counter resets, resume and applied tracking changes can
wake collection immediately. Pause, detach, reset and shutdown cancel outstanding
work and reject late results. Existing graph/usage counters remain intact.

Five seconds is a nominal interval: scan/endpoint latency, a busy Mac main run loop
or a slow Linux worker can delay samples. Rates use actual elapsed monotonic time.
Provider logs can arrive in bursts; these are not real-time per-request counters.
History capacity remains platform-specific, and Ollama model lists remain inventory,
not token measurements. System sampling, existing settings and tracking defaults
are unchanged; no schema migration is needed.
