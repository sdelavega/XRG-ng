# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

XRG-ng is a **cross-platform** system resource monitoring application with native implementations for **macOS** (Swift AppKit with small Objective-C hardware boundaries) and **Linux** (C/GTK3). It displays real-time graphs for CPU, memory, network, disk, GPU, battery, temperature, weather, stocks, and AI token usage.

**Key Points:**
- Both platforms follow a collector → graph → module-manager architecture.
- AI token monitoring works on both platforms (parses `~/.claude/projects/*/sessionid.jsonl`)
- macOS: `XRGCore/` holds Swift models, miners, panels and window/preferences controllers; `Controllers/XRGAppDelegate.swift` and `Other Sources/main.swift` form the app shell. Remaining `.h` files mostly preserve Objective-C import compatibility.
- Linux: `xrg-linux/src/collectors/`, `xrg-linux/src/widgets/`, `xrg-linux/src/core/`

**Default Module Display Order:**

| Order | Module | macOS View | Linux Widget |
|-------|--------|------------|--------------|
| 0 | CPU | `XRGCPUView` | `cpu_widget` |
| 1 | GPU | `XRGGPUView` | `gpu_widget` |
| 2 | Memory | `XRGMemoryView` | `memory_widget` |
| 3 | Battery | `XRGBatteryView` | `battery_widget` |
| 4 | Temperature | `XRGTemperatureView` | `sensors_widget` |
| 5 | Network | `XRGNetView` | `network_widget` |
| 6 | Disk | `XRGDiskView` | `disk_widget` |
| 7 | Weather | `XRGWeatherView` | (not ported) |
| 8 | Stock | `XRGStockView` | (not ported) |
| 9 | AI Tokens | `XRGAITokenView` | `aitoken_widget` |
| 10 | Process | (not implemented) | `process_widget` |
| 11 | TPU | (not implemented) | `tpu_widget` |

## Building and Running

### macOS Build Commands

```bash
# Build the project
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng build

# Build for debugging
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng -configuration Debug build

# Build for release
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng -configuration Release build

# Clean build folder
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng clean

# Build and run (use Xcode for easier debugging)
open XRG-ng.xcodeproj  # Then press ⌘R in Xcode
```

**Build Without Code Signing:**
```bash
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng \
    CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO build
```

**Targets and validation:**
- **App**: XRG-ng; internal Swift module name `XRG`, generated header `XRG-Swift.h`.
- **Framework**: XRGCore; Swift runtime classes keep explicit legacy Objective-C names.
- **Tests**: XRGTests, including Swift tests and Objective-C compatibility/transport fixtures.
- **Minimum OS**: macOS 26.0 for app, framework and tests.
- **Architectures**: arm64 and x86_64, Debug and Release.
- **CI**: standard `macos-26-intel` runner, Xcode 26.6.

Run the same checks as CI from the repository root:

```bash
bash Tools/ci-macos.sh Debug
bash Tools/ci-macos.sh Release
```

The script builds both architectures, verifies product metadata, bundled notices,
minimum OS and required runtime symbols, then runs XRGTests on the host architecture.
It prints a unique directory containing build logs, an xcresult bundle and JSON
summary. Tests use injected transports, fixture archives and private defaults.
On GitHub Actions, a background sampler records the current phase, selected process
statistics and brief ibtool/ibtoold/xctest stack samples every five minutes. These
diagnostic logs are uploaded with the results; they omit process arguments and
environments. Local runs do not start the sampler. The build/test exit status and
all validation checks still determine success.
Do not replace these checks with a build alone or claim Intel runtime coverage
from an arm64 host's universal build.

### Linux Build Commands

```bash
# Navigate to Linux port directory
cd xrg-linux

# Create build directory
mkdir -p build && cd build

# Configure with CMake
cmake ..

# Build
make -j$(nproc)

# Run
./xrg-linux

# Install system-wide (optional)
sudo make install
```

**Build Options:**
```bash
# Debug build
cmake -DCMAKE_BUILD_TYPE=Debug ..

# Release build
cmake -DCMAKE_BUILD_TYPE=Release ..

# Build with tests
cmake -DBUILD_TESTS=ON ..
make test
```

**Dependencies (Install Before Building):**

Fedora/RHEL:
```bash
sudo dnf install gtk3-devel cairo-devel glib2-devel json-glib-devel \
                 sqlite-devel libcurl-devel cmake gcc
```

Debian/Ubuntu:
```bash
sudo apt install libgtk-3-dev libcairo2-dev libglib2.0-dev libjson-glib-dev \
                 libsqlite3-dev libcurl4-openssl-dev cmake build-essential
```

**Target Information:**
- **Build System**: CMake 3.16+
- **Minimum Libs**: GTK 3.24, Cairo 1.16, GLib 2.66
- **Build Configurations**: Debug, Release
- **Required Libraries**: GTK3, Cairo, GLib, SQLite3, libcurl, json-glib

## Architecture

### macOS Swift implementation

1. **Miners** (`XRGCore/*Miner.swift`) collect system metrics or provider records.
   Histories use Swift-owned `XRGDataSet` buffers; parsers and readers expose fixture
   seams so tests do not need production hardware or user logs.
2. **Panels** (`XRGCore/*View.swift`) are main-actor `NSView` subclasses conforming
   to `XRGModuleView`. They compose `XRGGraphRenderer` and `XRGGraphLabels`.
   The Swift `XRGGenericView` remains a compatibility base; active leaf panels
   inherit directly from NSView.
3. **Modules and window** (`XRGModule`, `XRGModuleManager`, `XRGGraphWindow`) own
   registration, layout, visibility and timer dispatch. Panel registration must
   remain idempotent; detach/rebind removes only the panel's own module. Panels
   keep host, manager and module references weak where needed to avoid cycles.
4. **Preferences** (`XRGSettings`, `XRGWindowPreferences`, `XRGPrefController`)
   retain existing defaults keys, bindings, settings formats and nib selectors.
   `XRGAppDelegate` handles application lifecycle and routes AI preferences to the
   existing AI panel. The executable entry point is Swift.

Graph updates use the saved positive finite refresh interval, falling back to one
second. Fast updates run every 0.125 seconds; slow timers run every 300 and 1800
seconds. Modules opt in with `doesGraphUpdate`, `doesFastUpdate`, `doesMin5Update`,
`doesMin30Update` and `alwaysDoesGraphUpdate`.

### Remaining native hardware boundary

Only two Objective-C implementation files are compiled into the app:

- `Data Miners/APSL/SMCInterface.m`: legacy failable-init facade forwarding to
  `XRGSMCInterface`, plus IOKit packet calls, cleanup and exception containment.
- `Data Miners/XRGTemperatureHardwareReader.m`: SMC/HID adapters with private C
  ABI calls, Core Foundation ownership and Objective-C exception containment.

Packet construction, metadata caching, decoding, SMC sensor selection and HID
sample collection are Swift. Do not move `@try` boundaries into Swift: Objective-C
exceptions must be caught before returning to Swift. Keep the native SMC command
allowlist read-only and preserve packet ABI assertions for both architectures.
The test target compiles the same native bodies with injected C calls/runtime
names, covering errors and cleanup without accessing real hardware.

### Linux implementation

The C/GTK3 port remains in `xrg-linux/` and is independent of the macOS migration.
Collectors in `src/collectors/` feed widgets in `src/widgets/`; the module manager
in `src/core/module_manager.c` handles layout and GLib timer dispatch. Widgets use
GtkDrawingArea and Cairo. Linux build instructions and hardware troubleshooting
below still apply.

### Platform-Specific Data Sources

| Module | macOS Data Source | Linux Data Source |
|--------|-------------------|-------------------|
| **CPU** | IOKit, `host_processor_info()`, `vm_statistics64()` | `/proc/stat`, `/proc/loadavg` |
| **Memory** | Mach VM: `host_statistics64()`, `vm_statistics64()` | `/proc/meminfo`, `/proc/vmstat` |
| **Network** | `ioctl` with `SIOCGIFDATA` | `/proc/net/dev`, `/sys/class/net/*/statistics/` |
| **Disk** | IOKit disk statistics | `/proc/diskstats`, `/sys/block/*/stat` |
| **GPU** | IOAccelerator, IOGraphics (Apple Silicon/Intel) | NVML (NVIDIA), libdrm (AMD/Intel), `/sys/class/drm/` |
| **Temperature** | SMC (Intel), IOHIDEventSystem (Apple Silicon) | lm-sensors, `/sys/class/thermal/`, `/sys/class/hwmon/` |
| **Battery** | IOKit: `IOPSCopyPowerSourcesInfo` | UPower DBus API, `/sys/class/power_supply/` |
| **AI Tokens** | `~/.claude/projects/*/sessionid.jsonl` (JSONL parsing) | Same (platform-independent) |
| **Weather/Stock** | HTTP APIs (platform-independent) | Same (platform-independent) |

**Graphics APIs:**
- **macOS**: Quartz 2D (Core Graphics) for vector rendering
- **Linux**: Cairo for vector rendering (similar capabilities)

**UI Frameworks:**
- **macOS**: Cocoa/AppKit with NIB files
- **Linux**: GTK3 with code-based UI

## Adding a New Module

**Reference implementations:** `XRGCore/XRGCPUView.swift` and
`XRGCore/XRGCPUMiner.swift` on macOS; `aitoken_collector.c` and
`aitoken_widget.c` on Linux.

### macOS Module Checklist

1. Add a Swift miner in `XRGCore/`, using injected data sources and `XRGDataSet`
   histories where appropriate.
2. Add a main-actor Swift NSView conforming to `XRGModuleView`; compose the shared
   renderer/labels and implement the update callbacks required by the protocol.
3. Define the host protocol and register the module once after nib awakening and
   window attachment. Set its default order, visibility and size, and handle
   detachment, host replacement and manager replacement.
4. Add settings to `XRGSettings.swift`, register defaults in the existing
   preferences flow, and wire the window action and preference control. Preserve
   existing keys; use Swift string keys rather than resurrecting macro headers.
5. Add the Swift files to the framework target in the Xcode project. Preserve any
   explicit `@objc` names/selectors needed by Interface Builder or native callers.
6. Add focused fixture tests for collection, rendering inputs and lifecycle.
   Use the existing nib extraction tools when an archive contract changes; keep
   historical test fixtures intact.

### Linux Module Checklist

1. **Collector** (`xrg-linux/src/collectors/yourmodule_collector.{c,h}`)
   - Define struct with `XRGDataSet`, implement `_new()`, `_update()`, `_free()`

2. **Widget** (`xrg-linux/src/widgets/yourmodule_widget.{c,h}`)
   - Create `GtkDrawingArea`, connect `draw` signal, render with Cairo

3. **Registration** (`xrg-linux/src/ui/main_window.c`)
   - Create collector, widget, add to modules box, set up timer

4. **CMakeLists.txt**: Add to `COLLECTOR_SOURCES` and `WIDGET_SOURCES`

5. **Build**: `cd xrg-linux/build && cmake .. && make -j$(nproc)`

## Common Development Tasks

### Adding User Preferences

**macOS:**

Add the Swift accessor to `XRGCore/XRGSettings.swift` and register its default in
the existing settings flow. Use the same persisted string key in bindings and
consumers. For tests, inject a private `UserDefaults` suite; never rewrite the
user's running application's preferences to validate a change.

**Linux:**

Settings are stored in `~/.config/xrg-linux/settings.conf` using GLib's `GKeyFile`:

```c
// In xrg-linux/src/core/preferences.c

// Save setting
void preferences_set_bool(const char *key, gboolean value) {
    GKeyFile *keyfile = g_key_file_new();
    g_key_file_set_boolean(keyfile, "General", key, value);
    // ... save to file ...
}

// Load setting
gboolean preferences_get_bool(const char *key, gboolean default_value) {
    GKeyFile *keyfile = g_key_file_new();
    // ... load from file ...
    return g_key_file_get_boolean(keyfile, "General", key, NULL);
}
```

### Rendering, settings and compatibility

- Use `XRGGraphRenderer` and `XRGGraphLabels` for drawing, labels and mini mode.
  Colors and transparency come from `XRGSettings`/`XRGTheme`.
- Keep UI mutations on the main actor. Prefer injected clocks/readers/transports
  and fixture snapshots over starting production timers or endpoints in tests.
- Preserve explicit Objective-C runtime names, selectors and archive keys when
  migrating or simplifying Swift classes. Existing keyedarchives and NIBArchive
  fixtures exercise both forms of the historical UI resources.
- Keep bundle identifier `com.sdelavega.xrg`, internal module names, defaults keys
  and saved settings formats stable across the XRG-ng product rename.
- Keep the 26.0 deployment target and both supported executable slices. Inspect
  `Tools/ci-macos.sh` before changing required runtime classes or metadata.
- Most `.h` files are compatibility imports for generated Swift interfaces.
  Retain imports/selectors covered by Objective-C bridge tests. Obsolete AI
  prototypes and unused macro/plugin/PPP headers have been removed.

## Code Conventions

- New macOS implementation code is Swift; class names retain the `XRG` prefix.
- Keep licensing and source attribution when translating code. First-party code
  is GPL-3.0-or-later; APSL-derived sensor translations remain APSL 2.0. See
  `THIRD_PARTY_NOTICES.md` for files and the unresolved combined-distribution issue.
- Use four-space indentation and comments that explain non-obvious behavior.
- Add project membership for new source files; merely creating a file is not
  sufficient. Do not add duplicate implementations under `Resources/`.
- Keep regression assertions and transport failure coverage intact. Report what
  tests establish separately from live hardware, whole-app and Intel runtime checks.

## Common Issues

- **Network counters:** filter loopback and calculate deltas before advancing the
  previous counter. Cover resets and interface replacement with fixtures.
- **Temperature names:** use `Resources/SMCSensorNames.plist`; wildcard selection,
  ordering and known/unknown filtering have compatibility tests.
- **Module layout:** preserve module identities and the default order table. The
  manager sorts nonsequential values and preserves registration order for ties;
  ensure registration is idempotent and old managers release detached modules.
- **Missing UI callbacks:** verify generated Objective-C selectors and nib class
  identities as well as Swift compilation. A universal build alone cannot prove
  a nib-only class survives linking; the CI script checks required symbols.
- **Slow or hanging collection:** keep collection bounded and inspect Instruments
  traces. Do not add synchronous provider/network work to drawing callbacks.

### Linux: Preferences Window Tab Navigation

The preferences window supports direct navigation to specific module tabs via `xrg_preferences_window_show_tab()`. Tab indices are defined in `preferences_window.h`:

```c
typedef enum {
    XRG_PREFS_TAB_WINDOW = 0,
    XRG_PREFS_TAB_CPU = 1,
    XRG_PREFS_TAB_MEMORY = 2,
    XRG_PREFS_TAB_NETWORK = 3,
    XRG_PREFS_TAB_DISK = 4,
    XRG_PREFS_TAB_GPU = 5,
    XRG_PREFS_TAB_BATTERY = 6,
    XRG_PREFS_TAB_TEMPERATURE = 7,
    XRG_PREFS_TAB_AITOKEN = 8,
    XRG_PREFS_TAB_TPU = 9,
    XRG_PREFS_TAB_PROCESS = 10,
    XRG_PREFS_TAB_COLORS = 11
} XRGPrefsTab;
```

Use this to implement "Settings..." context menu items that navigate directly to the module's tab:

```c
static void on_menu_module_settings(GtkMenuItem *item, gpointer user_data) {
    AppState *state = (AppState *)user_data;
    xrg_preferences_window_show_tab(state->prefs_window, XRG_PREFS_TAB_MODULE);
}
```

### Linux: TPU Module (Coral Edge TPU)

The TPU module monitors Google Coral Edge TPU accelerators via USB. Files:
- `xrg-linux/src/collectors/tpu_collector.{c,h}` - Detects USB TPU devices at `/sys/bus/usb/devices/`
- `xrg-linux/src/widgets/tpu_widget.{c,h}` - Graph widget for TPU status

The TPU settings panel includes enable/disable, graph height, and visual style options.

**Stats File Integration**: The TPU collector reads inference statistics from `/tmp/xrg-coral-tpu-stats.json`. This file must be written by the TPU inference engine (e.g., Coral MCP server) in the following format:

```json
{
  "total_inferences": 123,
  "last_latency_ms": 18.5,
  "avg_latency_ms": 19.2,
  "model_name": "mobilenet_v2_edgetpu.tflite",
  "timestamp": 1234567890.123
}
```

For the Coral TPU MCP server, use the `xrg_tpu_stats` Python module:
```python
from xrg_tpu_stats import record_inference
record_inference(latency_ms=18.5, model_name="mobilenet_v2")
```

### Linux: GPU Collector nvidia-smi Blocking

**Symptom**: XRG-ng takes 10+ seconds to start, or hangs completely during initialization.

**Cause**: The GPU collector calls `popen("nvidia-smi ...")` to detect NVIDIA GPUs. When the nouveau driver is active (instead of proprietary nvidia), nvidia-smi either times out or blocks indefinitely.

**Diagnosis**:
```bash
# Check which driver is in use
cat /sys/class/drm/card*/device/driver/module/drivers

# If you see "pci:nouveau" instead of "pci:nvidia", that's the issue
```

**Solution** (implemented Nov 2025): The `detect_gpu_backend()` function now checks for the proprietary nvidia driver via sysfs BEFORE calling nvidia-smi:

```c
// gpu_collector.c - check_nvidia_proprietary_driver()
// Scans /sys/class/drm/card*/device/ for vendor=0x10de (NVIDIA)
// AND driver/module/drivers containing "pci:nvidia" (not "pci:nouveau")
// Only returns TRUE if proprietary driver is confirmed
```

**Key insight**: Always use non-blocking sysfs checks before calling external tools like nvidia-smi that may hang.

### Linux: Battery Collector HID Device Blocking

**Symptom**: XRG-ng opens but shows "Not Responding" dialog. Window appears but graphs never render.

**Cause**: Bluetooth HID devices (keyboards, mice, trackpads) appear in `/sys/class/power_supply/` as `hid-XX:XX:XX:XX:XX:XX-battery`. Reading certain sysfs files for these devices (especially `status`) can block indefinitely if the Bluetooth device is disconnected, sleeping, or has communication issues.

**Diagnosis**:
```bash
# List power supply devices
ls /sys/class/power_supply/

# Look for hid-* entries like:
# hid-d0:81:7a:ee:1f:c6-battery  (Apple Magic Trackpad, etc.)

# Test if it blocks:
timeout 2 cat /sys/class/power_supply/hid-*/status
# If this times out, that device blocks reads
```

**Solution** (implemented Nov 2025): Skip all HID batteries in the battery collector:

```c
// battery_collector.c - xrg_battery_collector_update()
while ((entry = readdir(dir)) != NULL) {
    if (entry->d_name[0] == '.') continue;

    /* Skip HID batteries (Bluetooth devices) - they can hang when queried */
    if (strncmp(entry->d_name, "hid-", 4) == 0) {
        continue;
    }
    // ... process non-HID batteries
}
```

### Linux: Debugging GTK Application Hangs

When the GTK main loop blocks, use this debugging approach:

**1. Add timing to the update timer callback**:
```c
// main.c - temporarily add to on_update_timer()
static gboolean on_update_timer(gpointer data) {
    gint64 start, end;

    start = g_get_monotonic_time();
    xrg_cpu_collector_update(app->cpu_collector);
    end = g_get_monotonic_time();
    g_message("CPU update: %ldμs", end - start);

    start = g_get_monotonic_time();
    xrg_battery_collector_update(app->battery_collector);
    end = g_get_monotonic_time();
    g_message("Battery update: %ldμs", end - start);

    // ... repeat for each collector
}
```

**2. Run with strace to trace blocking syscalls**:
```bash
# Trace file operations with timing
timeout 15 strace -ttt -f -e trace=open,openat,read ./xrg-linux 2>&1 | tee trace.log

# Look for long gaps between timestamps - indicates blocking
```

**3. Test individual collectors via CLI test utility**:
```bash
# Build and run CLI test (if available)
./xrg-cli-test -l -n 1  # List collectors, run 1 iteration

# Or write a minimal test that calls only one collector
```

**Key patterns that cause hangs**:
- `popen()` to external tools that may not exist or timeout
- Reading sysfs files for hardware that's disconnected/sleeping
- Network operations without timeouts
- Blocking D-Bus calls

**Prevention**: Always test on systems with diverse hardware configurations, especially:
- Systems with nouveau instead of proprietary nvidia
- Systems with Bluetooth peripherals
- Laptops vs desktops (different power supply configurations)

## AI Token Monitoring

Multi-provider AI token tracking works on both platforms. Zero configuration required.

**Supported Providers** (auto-detected):

| Provider | Data Source |
|----------|-------------|
| Claude Code | `~/.claude/projects/*/sessionid.jsonl` |
| OpenAI Codex CLI | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Google Gemini CLI | `~/.gemini/tmp/<hash>/chats/session-*.json` |
| Ollama | REST API (`http://localhost:11434/api/*`) |
| Hermes agents | SQLite (`~/.hermes/state.db`, `sessions` table) |

**Key Files**:
- macOS: `XRGCore/XRGAITokenMiner.swift`, `XRGCore/XRGAITokenView.swift`, `XRGCore/XRGAITokensObserver.swift`
- Linux: `xrg-linux/src/collectors/aitoken_collector.c`

**JSONL Parsing Note**: Model field is in `message.model`, not root level:
```json
{"message": {"model": "claude-sonnet-4-5-20250929", "usage": {"input_tokens": 10, "output_tokens": 791}}}
```

**Codex CLI Format**: Token counts in `event_msg` with `token_count` payload:
```json
{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":X,"output_tokens":Y}}}}
```

**Gemini CLI Format**: Session JSON with messages array containing tokens:
```json
{"messages":[{"tokens":{"input":X,"output":Y,"total":Z}}]}
```

**Hermes Format**: Agent-orchestrator activity in SQLite `~/.hermes/state.db` (`sessions` table). Each row has `model`, `input_tokens`, `output_tokens`, and cost columns (`actual_cost_usd`, falling back to `estimated_cost_usd`). XRG-ng aggregates every model with a per-model token breakdown and takes cost straight from the DB (never re-priced). The AI Token view shows all models under the Hermes line; the on-graph "API Cost" section was removed in favor of the right-click Cost Intelligence menu.

**Settings** (macOS - `XRGCore/XRGSettings.swift` and `XRGCore/XRGAITokensObserver.swift`):
- `aiTokensTrackingEnabled`: Master toggle (must be YES for Observer)
- `aiTokensAggregateByModel`: Per-model breakdown
- `aiTokensDailyBudget`: Daily limit (0 = unlimited)

## Platform Requirements

**macOS**: 26.0+, Xcode 26.3 or newer, Cocoa/IOKit/Accelerate frameworks
**Linux**: GTK 3.24+, Cairo 1.16+, GLib 2.66+, SQLite3, libcurl, json-glib, CMake 3.16+
