# Linux Swift / Rust transition

This is the GTK 4 replacement in progress. It runs alongside the C/GTK3 application
in `../src`; the C executable and its `~/.config/xrg-linux/settings.conf` remain
available. The new executable is `xrg-ng-linux`, version 0.1.0. It currently shows
aggregate CPU, memory, network receive/send, physical-disk read/write, system
battery capacity, temperature and GPU utilization graphs.
This is an initial vertical slice, not feature parity with the C application.

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

GPU discovery uses DRM primary cards and, for compute-only NVIDIA installations,
PCI devices actually bound to the NVIDIA driver. PCI identity keeps histories
stable when `cardN` numbering changes; connector/render nodes and aliases are
excluded. Up to three adapters with supported utilization readings are graphed.
Memory, clock, temperature, power and fan readings appear in accessible tooltips
when available. Power reported by hwmon may cover a whole SoC, including its CPU.

| Backend | Available acquisition |
| --- | --- |
| AMD amdgpu | Documented busy percentage, VRAM bytes, GPU hwmon telemetry |
| NVIDIA nvidia | One bounded `nvidia-smi` query, matched by PCI address |
| Intel i915 | Reported clock and available hwmon telemetry; utilization unavailable |
| Intel xe | Available hwmon telemetry; utilization unavailable |
| nouveau / other drivers | Identification; unsupported counters remain unavailable |
| Runtime-suspended adapters | Identification only; telemetry reads/commands are skipped |

Intel utilization needs a future PMU/performance-counter backend. Clock frequency
is never converted into an estimated busy percentage. There is no simulated GPU
fallback. Actual zero utilization is retained; unsupported, malformed or absent
values create no synthetic idle samples. NVIDIA `N/A` fields remain unavailable,
and duplicate/invalid PCI rows cannot attach telemetry to another adapter.

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

Sources: [AMDGPU monitoring ABI](https://kernel.org/doc/html/latest/gpu/amdgpu/thermal.html),
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

CI runs Swift tests, a C header/ABI executable, Rust formatting/Clippy/tests, three
live headless samples, and a GTK/Xvfb launch that requires multiple live samples
and actual Cairo draw callbacks. The GTK check switches Paper/Ocean presets and
exports a rendered PNG for inspection. Smoke mode does not read or write user preferences.
Xvfb uses Cairo, so this does not validate accelerated rendering, Wayland compositor
behavior, screen readers or physical-device collection. Linux build output is
separate from host Swift output when using a shared Docker checkout.

## Remaining migration

1. Rust process and TPU collectors; Intel GPU PMU utilization, other GPU backends,
   VRAM graphs/device selection, richer battery health/time and calibrated/fan sensors.
2. Connect the shared provider parsers to incremental Rust log/SQLite/network
   acquisition; expose Claude/Gemini and weather through the ABI when consumers land.
3. Per-core/interface/device selection, module visibility/order, context menus,
   detailed preferences, custom theme load/save and explicit legacy-settings import.
4. Wayland/X11 behavior and accessibility validation. GTK4 removed GTK3's global
   window placement / keep-above APIs; supported positioning/pinning needs a
   compositor-specific implementation. No always-on-top or edge-placement promise
   is made by this initial shell.
5. Runtime bundling, desktop integration, distribution packages and native x86_64 /
   ARM64 hardware verification before replacing the C application's release path.

GTK4 fits the rewrite: supported Rust bindings, modern scene-graph rendering and
retained Cairo drawing through GtkDrawingArea. GTK4 does not make blocking collectors
asynchronous; the separate worker is what keeps collection out of the UI loop.
See the [GTK migration guide](https://docs.gtk.org/gtk4/migrating-3to4.html),
[drawing model](https://docs.gtk.org/gtk4/drawing-model.html) and
[gtk4-rs](https://gtk-rs.org/gtk4-rs/).
