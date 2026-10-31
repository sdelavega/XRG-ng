# Windows port notes

Status after the 0.2.1 Windows compile milestone (see
`.github/workflows/windows.yml`). Nothing here ships to users yet; this page
tracks what already builds, what each collector needs on Windows, and how the
0.3.0/0.4.0 parity goals fit in.

## What compiles today

The full shared core and the Rust collector crate build and pass their tests on
`x86_64-pc-windows-msvc` with Swift 6.4.1 and Rust 1.99.1:

- `swift build` and `swift test` for the root `XRGSharedCore` package
  (38 tests, 9 suites). The dynamic product is `XRGSharedCore.dll` with its
  `XRGSharedCore.lib` import library; test binaries resolve the DLL from the
  Swift build directory on `PATH`.
- `cargo check --locked --features egui-ui` in `xrg-linux/rust` — the Task 6
  `cfg(target_os = "linux")` gates keep the Linux-only modules out and the stub
  twins in, and `build.rs` links `XRGSharedCore.lib`.
- `cargo test --locked --lib` (101 tests, 0 failures).

The cross-platform `/proc`-reading collectors stay Linux-only via the stub
twins (`IMPLEMENTATION = "stub"`); they do not yet produce readings on
Windows. POSIX path handling keeps its `cfg(unix)` implementations with the
`cfg(not(unix))` fallbacks.

## Collector plan

| Collector | Linux source today | Planned Windows source |
| --- | --- | --- |
| CPU load | `/proc/loadavg` and task counts | PDH (`\Processor(...)`) counters and `GetSystemTimes` |
| Memory | `/proc/meminfo` | `GlobalMemoryStatusEx`, PDH memory counters |
| Battery | `/sys/class/power_supply` | `GetSystemPowerStatus` / `PowerGetBatteryReport` |
| Network and addresses | `/proc/net/*`, netlink | IP Helper (`GetIfTable2`, `GetAdaptersAddresses`) |
| GPU / VRAM | DRM client stats (`drm_clients`) | DXGI (`IDXGIFactory` enumeration, `QueryVideoMemoryInfo`) |
| Hardware inventory | `lspci`/sysfs | WMI (`Win32_*` classes) |
| Temperature and fans | hwmon sysfs | WMI (`MSAcpi_ThermalZoneTemperature`, vendor namespaces) |
| Filesystem usage | `/proc/mounts` + `statvfs` | `GetDiskFreeSpaceExW` / `GetLogicalDrives` |
| AI usage | provider log files (`~/.*`) | identical parsing; `%USERPROFILE%`/`%LOCALAPPDATA%` paths |
| Weather | platform-neutral (HTTP) | unchanged |
| TPU / NPU | Linux hardware: sysfs device/vendor discovery, `power/runtime_status` and readable DRM clients (`tpu`, `tpu::clients`) | vendor equivalents (WMI/D3DKMT); the sysfs and DRM seams do not exist on Windows |
| Engine | platform-neutral | unchanged |
| Desktop alerts | freedesktop D-Bus `Notify` directly in Rust (`ai::desktop_alert`) | Windows Toast (`WinRT`) — the `ai::desktop_alert` stub fills in; `notification` is only the generic publish/subscribe primitive, not the alerts seam |
| Window/egg UI | egui (X11/Wayland) | egui with `winit`/Win32 backend, feature `egui-ui` |

AI log parsing is pure string handling and already runs on Windows in the
tests; only the path discovery layer is platform-specific.

## Packaging

Candidates, in rough preference order:

- **MSIX** — the modern Windows app package; suits a Store-less sideload and
  gives a clean uninstall story, but MSIX on a taskbar/tray utility needs
  checking around autostart and tray support.
- **winget** — distribute through the winget community repo manifest, pointing
  at whichever package we ship; lowest friction for users.
- **zip** — the fallback the CI already knows how to build for Linux; simplest
  but no Start-menu integration.

### Signing — open question

No code-signing certificate is chosen yet. Authenticode signing (EV vs
standard, and whether the Linux side's signing story can share a vendor) is
an open question, as is how unsigned builds should present themselves during
development.

## Roadmap fit

- **0.3.0 — macOS look parity on all platforms.** The goal is that Linux and
  Windows render the macOS 26 look, including Liquid Glass materials, on every
  platform, driven by shared design tokens rather than per-platform pixel
  tuning. The existing portable JSON theme/`Shared` design-token work is the
  intended vehicle.
- **0.4.0 — desktop widgets and menu bar/dock modes.** After parity, the plan
  adds desktop widgets and the menubar/dock presentation choice. On Windows
  this means taskbar/tray counterparts for the macOS menu-bar mode and the
  Linux tray, so the mode choice stays meaningful everywhere.

No dates are promised for either.