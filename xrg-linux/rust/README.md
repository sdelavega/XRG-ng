# Linux Swift / Rust transition

This is the GTK 4 replacement in progress. It runs alongside the C/GTK3 application
in `../src`; the C executable and its `~/.config/xrg-linux/settings.conf` remain
available. The new executable is `xrg-ng-linux`, version 0.1.0. It currently shows
aggregate CPU, memory, network receive/send, physical-disk read/write, system
battery capacity, temperature, GPU activity, AI token-rate, process-count and
Coral TPU inference-rate graphs.
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
  inventories. METAR sources compile in the package but have no Rust consumer yet.
- **Rust:** owns `/proc` and `/sys` collection, GTK4/Cairo drawing, configuration and
  lifecycle. System and AI workers create/own their mutable Swift handles. They send only copied
  Rust snapshots through bounded latest-value slots; GTK touches them on its main
  thread. No shell commands, provider scans or collection run in drawing callbacks.
- **Themes:** all six shared presets are selectable. The new UI saves the selection
  atomically in `$XDG_CONFIG_HOME/xrg-ng/settings.conf` (or `~/.config/xrg-ng`). It
  does not import or modify the old C application's settings or theme files yet.

CPU calculations exclude guest time already included in user/nice. Memory uses
MemAvailable. Network aggregates non-loopback interfaces (bridges/VPNs may count
traffic more than once); disks aggregate whole non-loop/ram/zram/dm/md devices to
avoid counting partitions and stacked devices twice. Rates use elapsed monotonic
time and the shared reset/saturation policy. Disk/network labels show read/receive
first, write/send second. First CPU sample waits for an interval. Failed collection
shows an error and retains previous history rather than recording fabricated zeros.

Battery collection reads system power supplies, skips HID/HID++ names before
opening attributes, and excludes `scope=Device` and absent batteries. Each percent
uses a complete energy or charge pair; a bounded capacity percent is the fallback.
Up to three batteries have separate histories keyed by device name, with status
and available power readings in tooltips. There is no mixed-unit aggregate or
battery time/health estimate yet. Faulty devices are reported as partial data.

Temperature collection reads standard hwmon temperature channels, honors disabled
and fault flags, and falls back to thermal zones if no hwmon values are usable.
The graph shows the maximum readable temperature; tooltips list individual sensors.
Negative temperatures use a signed graph range. Channels marked as thermistors
(`tempN_type=4`) are excluded until calibrated conversion is supported, since some
report voltage rather than Celsius. This initial reader does not apply libsensors
configuration/compute rules or collect fan speeds. See the kernel's
[power-supply ABI](https://docs.kernel.org/power/power_supply_class.html) and
[hwmon interface](https://docs.kernel.org/hwmon/sysfs-interface.html).
Missing optional hardware shows an explicit absence label and no fabricated zero
series; read failures show unavailable/partial labels. Neither makes core-only
headless or live GTK smoke checks fail on desktops/containers without that hardware.
The graph area scrolls on small windows and exposes details to accessibility APIs.

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
and actual Cairo draw callbacks. The GTK check switches Paper/Ocean presets and
exports a rendered PNG for inspection. Smoke mode does not read or write user preferences.
Xvfb uses Cairo, so this does not validate accelerated rendering, Wayland compositor
behavior, screen readers or physical-device collection. Linux build output is
separate from host Swift output when using a shared Docker checkout.

## AI monitoring

The eighth panel graphs **observed token-counter change per second**, polling every
five seconds on a separate worker. Core graphs keep their one-second schedule even
when provider scans or local APIs are slow. Tooltips/accessibility details show each
provider's locally retained token total, rate, source, recorded cost when available,
and errors. These totals are not account billing or a billing-period summary;
batched log writes produce bursts in the graph.

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
proxies and redirects, use fixed loopback HTTP endpoints, and cap each child at
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
read. The collector API also supports CPU/memory/PID/name sorting, name filters
and UID filters; detailed GTK table/filter controls remain follow-up work.

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

## Remaining migration

1. Intel GPU PMU utilization, additional vendor counters, VRAM graphs/device selection,
   richer battery health/time, calibrated/fan sensors and detailed process controls.
2. AI provider/model detail controls, custom data roots/endpoints, append-offset
   scanning for very large logs, optional price tables, and a weather ABI consumer.
3. Per-core/interface/device selection, module visibility/order, context menus,
   detailed preferences, custom theme load/save and explicit legacy-settings import.
4. Wayland/X11 behavior and accessibility validation. GTK4 removed GTK3's global
   window placement / keep-above APIs; supported positioning/pinning needs a
   compositor-specific implementation. No always-on-top or edge-placement promise
   is made by this initial shell.
5. Runtime bundling, desktop integration and distribution packages before replacing
   the C application's release path. Broaden real-device coverage through community
   feedback as hardware becomes available.

GTK4 fits the rewrite: supported Rust bindings, modern scene-graph rendering and
retained Cairo drawing through GtkDrawingArea. GTK4 does not make blocking collectors
asynchronous; the separate worker is what keeps collection out of the UI loop.
See the [GTK migration guide](https://docs.gtk.org/gtk4/migrating-3to4.html),
[drawing model](https://docs.gtk.org/gtk4/drawing-model.html) and
[gtk4-rs](https://gtk-rs.org/gtk4-rs/).
