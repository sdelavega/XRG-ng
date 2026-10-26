# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

XRG-ng is a **cross-platform** system resource monitoring application with native implementations for **macOS** (Swift/Objective-C AppKit) and **Linux** (C/GTK3). It displays real-time graphs for CPU, memory, network, disk, GPU, battery, temperature, weather, stocks, and AI token usage.

**Key Points:**
- Both platforms share identical three-layer architecture (Data Collector → Graph View → Module Manager)
- AI token monitoring works on both platforms (parses `~/.claude/projects/*/sessionid.jsonl`)
- macOS: `Controllers/`, `Data Miners/`, `Graph Views/`, `Utility/`
- Linux: `xrg-linux/src/collectors/`, `xrg-linux/src/widgets/`, `xrg-linux/src/core/`

**Current Module Display Order** (must be sequential, no gaps):
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

**Target Information:**
- **Single Target**: XRG-ng
- **Schemes**: XRG-ng
- **Minimum OS**: macOS 10.13
- **Build Configurations**: Debug, Release
- **Required Frameworks**: Cocoa, IOKit, Accelerate

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

XRG-ng maintains a consistent three-layer architecture across **both macOS and Linux** implementations, with platform-specific data collection and rendering layers.

### Three-Layer Module Pattern

Both platforms use this consistent architecture across all monitoring modules:

**macOS Implementation:**

1. **Data Miner Layer** (`Data Miners/`)
   - Inherits from `NSObject`
   - Collects system metrics via IOKit, sysctl, or log file parsing
   - Stores time-series data in `XRGDataSet` ring buffers
   - Updates on timer callbacks: `graphUpdate:`, `fastUpdate:`, `min5Update:`, `min30Update:`
   - Examples: `XRGCPUMiner`, `XRGMemoryMiner`, `XRGNetMiner`, `XRGAITokenMiner`

2. **View Layer** (`Graph Views/`)
   - Inherits from `XRGGenericView` → `NSView`
   - Owns its corresponding miner instance
   - Implements `drawRect:` to render graphs using Quartz
   - Responds to timer events by querying the miner and calling `setNeedsDisplay:`
   - Supports both full and "mini" display modes
   - Examples: `XRGCPUView`, `XRGMemoryView`, `XRGNetView`, `XRGAITokenView`

3. **Module Registration** (via `XRGModule`)
   - Created in view's `awakeFromNib`
   - Registered with `XRGModuleManager` in `XRGGraphWindow`
   - Manages visibility (`isDisplayed`), display order, size constraints
   - Controls which timer events the module receives

**Linux Implementation:**

1. **Data Collector Layer** (`xrg-linux/src/collectors/`)
   - Plain C structs with function pointers
   - Collects system metrics via `/proc`, `/sys`, lm-sensors
   - Stores time-series data in `XRGDataSet` ring buffers (same as macOS)
   - Updates on GLib timer callbacks: `update_callback()`
   - Examples: `cpu_collector.c`, `memory_collector.c`, `network_collector.c`, `aitoken_collector.c`

2. **Widget Layer** (`xrg-linux/src/widgets/`)
   - Custom GTK widgets using `GtkDrawingArea`
   - Owns its corresponding collector instance
   - Implements `draw` signal handler to render graphs using Cairo
   - Responds to timer events by querying the collector and calling `gtk_widget_queue_draw()`
   - Includes activity bar showing real-time stats
   - Examples: `cpu_widget.c`, `memory_widget.c`, `network_widget.c`, `aitoken_widget.c`

3. **Module Manager** (`xrg-linux/src/core/module_manager.c`)
   - Manages module lifecycle and layout
   - Tracks visibility, display order, size constraints
   - Dispatches timer events to modules
   - Same conceptual design as macOS `XRGModuleManager`

### Core Components

- **`XRGAppDelegate`**: Application lifecycle, preferences, window management
- **`XRGGraphWindow`**: Main floating window, hosts all graph views, owns module manager
- **`XRGModuleManager`**: Orchestrates modules, handles layout, dispatches timer events
- **`XRGSettings`**: User preferences wrapper around `NSUserDefaults`
- **`XRGDataSet`**: Ring buffer for time-series data storage
- **`XRGGenericView`**: Base class providing common graphing methods
- **`XRGModule`**: Metadata container (name, size, visibility, update flags)

### Timer-Based Updates

The app uses multiple timers with different frequencies:

- **`graphTimer`** (1 second): Main update loop for most graphs
- **`fastTimer`** (0.1 seconds): High-frequency updates (CPU, network)
- **`min5Timer`** (5 minutes): Weather, stock updates
- **`min30Timer`** (30 minutes): Extended polling intervals

Modules opt-in to timer events via flags:
```objc
m.doesGraphUpdate = YES;      // Receives 1-second updates
m.doesFastUpdate = YES;       // Receives 0.1-second updates
m.doesMin5Update = YES;       // Receives 5-minute updates
m.alwaysDoesGraphUpdate = YES; // Updates even when window minimized
```

### Hardware Access Patterns

**Apple Silicon Sensors** (`Data Miners/APSL/`):
- Uses `IOHIDEventSystemClientCreate` to access HID sensors
- `XRGAppleSiliconSensorMiner` bridges to older `XRGTemperatureMiner`
- `SMCSensors` and `SMCSensorGroup` abstract sensor reading
- Sensor names mapped via `Resources/SMCSensorNames.plist`

**Intel SMC Access**:
- Uses `SMCInterface.m` to read System Management Controller
- Provides temperature, fan speed, and power metrics

**Network Stats**:
- Direct `ioctl` calls with `SIOCGIFDATA` for interface stats
- Ignores `lo0` (loopback) to avoid phantom VPN traffic
- Tracks `bytes_delta` for rate calculations

**GPU Monitoring**:
- Uses `IOAccelerator` and `IOGraphics` APIs
- Tracks GPU utilization and memory usage

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

**Reference Implementation**: Use `XRGAITokenMiner.m` / `XRGAITokenView.m` (macOS) or `aitoken_collector.c` / `aitoken_widget.c` (Linux) as templates.

### macOS Module Checklist

1. **Data Miner** (`Data Miners/XRGYourModuleMiner.{h,m}`)
   - Inherit from `NSObject`, store data in `XRGDataSet` ring buffers
   - Implement `graphUpdate:`, `setDataSize:` methods

2. **Graph View** (`Graph Views/XRGYourModuleView.{h,m}`)
   - Inherit from `XRGGenericView`, own the miner instance
   - In `awakeFromNib`: create miner, register `XRGModule` with **next sequential displayOrder**
   - Implement `drawRect:` using miner data

3. **Configuration** (`Other Sources/definitions.h`)
   - Add `XRG_showYourModuleGraph` and `XRG_YourModuleOrder` keys

4. **Window Controller** (`Controllers/XRGGraphWindow.{h,m}`)
   - Add property and `setShowYourModuleGraph:` action

5. **Xcode Project**: Add files to `Data Miners` and `Graph Views` groups

6. **NIB Files**: Add view to `MainMenu.nib`, checkbox to `Preferences.nib`

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

1. Define key in `definitions.h`:
   ```objc
   #define XRG_myNewSetting    @"myNewSetting"
   ```

2. Access in code:
   ```objc
   BOOL value = [[NSUserDefaults standardUserDefaults] boolForKey:XRG_myNewSetting];
   [[NSUserDefaults standardUserDefaults] setObject:value forKey:XRG_myNewSetting];
   ```

3. Wrap in `XRGSettings.h` for easier access:
   ```objc
   - (BOOL)myNewSetting;
   - (void)setMyNewSetting:(BOOL)value;
   ```

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

### Debugging with XRG_DEBUG

Enable debug logging:
```objc
// In definitions.h, change:
#undef XRG_DEBUG
// To:
#define XRG_DEBUG 1
```

Then add logging:
```objc
#ifdef XRG_DEBUG
NSLog(@"Debug info: %@", data);
#endif
```

### Drawing Graphs

Use helper methods from `XRGGenericView`:

```objc
// Stacked area graph
[self drawGraphWithDataFromDataSet:dataset
                          maxValue:maxValue
                            inRect:graphRect
                           flipped:YES
                            filled:YES
                             color:[appSettings graphFG1Color]];

// Line graph
[self drawRangedGraphWithDataFromDataSet:dataset
                              upperBound:100
                              lowerBound:0
                                  inRect:graphRect
                                 flipped:NO
                                  filled:NO
                                   color:[appSettings graphFG2Color]];

// Mini mode
[self drawMiniGraphWithValues:values
                   upperBound:max
                   lowerBound:min
                    leftLabel:@"Label"
                   rightLabel:@"Value"];
```

### Color Scheme

All modules use centralized color preferences:
- `graphBGColor`: Graph background
- `graphFG1Color`, `graphFG2Color`, `graphFG3Color`: Three data series colors
- `backgroundColor`: Window background
- `textColor`: Labels and text
- `borderColor`: Window borders

Each has corresponding transparency settings.

### Size and Layout

Modules define size constraints:
```objc
m.minHeight = 40;         // Minimum height in pixels
m.maxHeight = 300;        // Maximum height
m.minWidth = 100;         // Minimum width
// Width auto-adjusts based on window size
```

`XRGModuleManager` handles layout based on orientation:
- Vertical: Modules stack top-to-bottom
- Horizontal: Modules arrange left-to-right

### Testing Without Running Full App

For testing miners or calculations:
```objc
// In a separate test file
int main() {
    @autoreleasepool {
        XRGYourModuleMiner *miner = [[XRGYourModuleMiner alloc] init];
        [miner graphUpdate:nil];
        NSLog(@"Result: %@", [miner dataValues]);
    }
    return 0;
}
```

## Code Conventions

- **Language**: Objective-C (modern runtime, ARC enabled where applicable)
- **Naming**: Classes prefixed with `XRG-ng`, ivars with underscores (legacy style)
- **Memory**: Use `strong` properties, avoid manual retain/release in new code
- **Headers**: Import foundation classes in `.h`, specific dependencies in `.m`
- **Comments**: License header in all files (GPL v3 or later), inline comments for complex logic
- **Indentation**: 4 spaces (not tabs in source, tabs in NIB XML)

## Common Issues

### Network Interface Changes

When adding new network interfaces, ensure `lo0` (loopback) is filtered out to avoid phantom traffic from VPN connections. See commit `0fca322`.

### Temperature Sensor Names

Sensor names are hardware-specific. Use `SMCSensorNames.plist` for friendly name mapping. Auto-configuration runs on first launch.

### GPU Metrics on Apple Silicon

GPU monitoring uses different APIs on Apple Silicon vs. Intel. Check `[XRGCPUMiner systemModelIdentifier]` to determine architecture.

### Build Errors After Adding Files

If Xcode can't find newly added files:
1. Verify files are added to project (not just filesystem)
2. Check target membership (should be checked)
3. Clean build folder (⇧⌘K)
4. Verify imports use correct paths

### High CPU Usage

If XRG-ng uses excessive CPU:
- Check for infinite loops in `drawRect:` (use `setNeedsDisplay:` sparingly)
- Verify timer intervals are reasonable (1 second minimum for most modules)
- Profile with Instruments to identify hotspots

### Module Display Order Issues

If modules overlap or have incorrect positioning:
- Display order must be **sequential** (0, 1, 2, 3...) - see table in Overview section
- Gaps in numbering cause layout problems - use next sequential number when adding modules
- Check `m.displayOrder` in each view's `awakeFromNib` method

### Rate Calculation Bug Pattern

When implementing rate calculations from cumulative counters:
```objc
// ❌ WRONG - Will always return 0
- (UInt32)myRate {
    return (UInt32)(totalCount - lastCount);  // lastCount already updated!
}

// ✅ CORRECT - Store rate in instance variable
- (void)update {
    currentRate = (UInt32)(totalCount - lastCount);  // Calculate BEFORE updating
    lastCount = totalCount;  // Then update
}

- (UInt32)myRate {
    return currentRate;  // Return stored value
}
```

### Missing Readonly Property Getters

When declaring readonly properties in the header, you **must** implement the getter method in the .m file:

```objc
// ❌ WRONG - Header declares property but .m has no implementation
// XRGMyClass.h
@property (readonly) NSDictionary *myData;

// XRGMyClass.m
// (no getter implementation - property returns nil!)

// ✅ CORRECT - Implement the getter
// XRGMyClass.m
- (NSDictionary *)myData {
    // Compute and return the value
    return [self computeData];
}
```

**Real Example from AI Token Observer** (Nov 2025 fix):
The header declared `dailyByModel` and `dailyByProvider` as readonly properties, but had no getter implementations. This caused the breakdown sections to never display. Fixed by implementing getters that combine prompt and completion token dictionaries.

### macOS SDK Compatibility

When targeting older macOS versions (10.13+), be aware of API availability:

**NSBindingName Constants** (10.15+):
```objc
// ❌ WRONG - Not available on macOS 10.13
[control bind:NSBindingNameValue toObject:udc ...];

// ✅ CORRECT - Use string literals for backwards compatibility
[control bind:@"value" toObject:udc ...];
```

Common binding names that require string literals on 10.13:
- `NSBindingNameValue` → `@"value"`
- `NSBindingNameEnabled` → `@"enabled"`
- `NSBindingNameHidden` → `@"hidden"`

### Duplicate File Prevention

When adding new modules, ensure files are not duplicated across directories:
- ✅ **Correct**: Implementation files in proper directories (`Data Miners/`, `Graph Views/`)
- ❌ **Wrong**: Duplicate or experimental files in `Resources/` directory

Before building, verify no conflicting implementations exist:
```bash
# Check for duplicate implementations
find . -name "XRGYourModule*.m" -o -name "XRGYourModule*.h"
```

If duplicate files exist, remove them from the Xcode project (not just filesystem):
1. Select file in Xcode Project Navigator
2. Delete → "Remove Reference" (not "Move to Trash")
3. Or edit `XRG-ng.xcodeproj/project.pbxproj` to remove PBXBuildFile entries

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
- macOS: `Data Miners/XRGAITokenMiner.m`, `Graph Views/XRGAITokenView.m`
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

**Settings** (macOS - `XRGAISettingsKeys.h`):
- `aiTokensTrackingEnabled`: Master toggle (must be YES for Observer)
- `aiTokensAggregateByModel`: Per-model breakdown
- `aiTokensDailyBudget`: Daily limit (0 = unlimited)

## Platform Requirements

**macOS**: 10.13+, Xcode, Cocoa/IOKit/Accelerate frameworks
**Linux**: GTK 3.24+, Cairo 1.16+, GLib 2.66+, SQLite3, libcurl, json-glib, CMake 3.16+
