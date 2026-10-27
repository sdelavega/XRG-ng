# Linux Swift / Rust transition

This is the GTK 4 replacement in progress. It runs alongside the C/GTK3 application
in `../src`; the C executable and its `~/.config/xrg-linux/settings.conf` remain
available. The new executable is `xrg-ng-linux`, version 0.1.0. It currently shows
aggregate CPU, memory, network receive/send, physical-disk read/write, system
battery capacity, temperature and GPU activity graphs.
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
  exposes histories, rates, themes, local metrics and individual Codex records.
  Claude/Gemini/METAR sources compile in the package but are not exposed to Rust yet.
- **Rust:** owns `/proc` and `/sys` collection, GTK4/Cairo drawing, configuration and
  lifecycle. A worker creates/owns all mutable Swift handles. It sends only copied
  Rust snapshots through a single latest-value slot; GTK touches them on its main
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

## Remaining migration

1. Rust process and TPU collectors; Intel GPU PMU utilization, additional vendor counters,
   VRAM graphs/device selection, richer battery health/time and calibrated/fan sensors.
2. Connect the shared provider parsers to incremental Rust log/SQLite/network
   acquisition; expose Claude/Gemini and weather through the ABI when consumers land.
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
