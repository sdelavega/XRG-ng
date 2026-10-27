# XRG-ng for Linux

A real-time system resource monitor for Linux with customizable floating graphs.

The **Swift/Rust + GTK4 replacement** is under active development in [rust/](rust/README.md).
It currently provides CPU, memory, network, disk, battery, temperature, GPU, AI
token-rate, process-count and Coral TPU inference-rate graphs, with shared macOS Swift histories, rate tracking, provider parsers
and themes. The new Preferences editor saves graph visibility/order/height and
custom colors, with built-in presets and JSON theme load/save. Layout can be
vertical or horizontal, with Celsius/Fahrenheit system temperature display.
Per-core/interface/disk/GPU selectors and a sortable process table with name/UID
filters are available in the new UI.
Driver-reported VRAM and fan RPM graphs, plus battery health/time details, use available
driver counters without fabricating unsupported readings. AI monitoring covers
Claude/Codex/Gemini/Hermes usage and Ollama model
status; see the [new provider sources and limits](rust/README.md#ai-monitoring). The instructions below describe the existing
C/GTK3 implementation, retained during migration.

The new **AI…** window shows usage, recorded Claude/Gemini/Hermes token totals by
model and Ollama model inventories, with saved provider
switches, custom data paths, Claude source selection and loopback API endpoints.
The toolbar's sun icon opens the opt-in **Weather** window, with shared Swift
METAR decoding, saved station/units/refresh settings and explicit observation age
and stale states. See [weather observations](rust/README.md#weather-observations).
Right-click a graph (or use Shift+F10) for live details, settings and hide/reorder
actions. The application menu can show all graphs again without resetting sources
or themes; see [graph actions](rust/README.md#graph-actions-and-live-details).
Preferences also offers a reviewed, read-only [legacy settings import](rust/README.md#importing-legacy-linux-settings)
for the C app's graph visibility, global colors, layout and temperature units. Unsupported entries are listed;
the old configuration is preserved.

Installable x86_64/ARM64 preview archives are produced by the
[Linux workflow](https://github.com/sdelavega/XRG-ng/actions/workflows/linux.yml).
They bundle the Swift runtime and support direct launch or per-user desktop
installation; see the [preview requirements and instructions](preview/README.md).

Port of the macOS [XRG-ng](https://github.com/marc-shade/XRG) application to Linux using GTK and Cairo.

![XRG-ng for Linux Screenshot](docs/screenshot.png)

The Linux executable and configuration directory remain `xrg-linux` for compatibility.

## Hardware support and feedback

Linux hardware support is a **best-effort attempt**. We cannot physically validate
every GPU, sensor, architecture or driver combination; coverage relies on published
interfaces, automated tests, native builds and available hardware. Community
feedback is welcome and encouraged, including reports of working configurations.
Please [open an issue](https://github.com/sdelavega/XRG-ng/issues) with your app
version, distribution/kernel, architecture, device model, driver and relevant
observations. See the [project support policy](../README.md#hardware-support-and-feedback)
and the [Swift/Rust backend details](rust/README.md) for current capabilities.

## Features

XRG-ng for Linux displays real-time graphs for:

- **CPU Usage** - Per-core utilization and load averages
- **Memory** - RAM usage, swap, page ins/outs
- **Network** - Upload/download rates per interface
- **Disk Activity** - Read/write operations per volume
- **GPU Usage** - GPU utilization and memory (NVIDIA, AMD, Intel)
- **Temperature** - CPU, GPU, and system sensors
- **Battery** - Charge level, time remaining, health (laptops)
- **AI Token Usage** - Live AI API token consumption

## Requirements

### Build Dependencies

**Required:**
- GTK 3.24+ (the C application requires GTK3; GTK4 is used by the Rust rewrite)
- Cairo 1.16+
- GLib 2.66+
- SQLite3
- libcurl
- json-glib
- CMake 3.16+
- GCC or Clang

**Optional (for enhanced features):**
- lm-sensors (temperature monitoring)
- libupower-glib (battery monitoring on laptops)
- nvidia-ml (NVIDIA GPU monitoring)
- libdrm (AMD/Intel GPU monitoring)

### Runtime Dependencies

**Fedora/RHEL:**
```bash
sudo dnf install gtk3 cairo glib2 sqlite-libs libcurl json-glib
sudo dnf install lm_sensors upower  # Optional
```

**Debian/Ubuntu:**
```bash
sudo apt install libgtk-3-0 libcairo2 libglib2.0-0 libsqlite3-0 libcurl4 libjson-glib-1.0-0
sudo apt install libsensors5 libupower-glib3  # Optional
```

**Arch Linux:**
```bash
sudo pacman -S gtk3 cairo glib2 sqlite curl json-glib
sudo pacman -S lm_sensors upower  # Optional
```

## Building from Source

```bash
# Clone repository
git clone https://github.com/marc-shade/XRG.git
cd XRG/xrg-linux

# Create build directory
mkdir build && cd build

# Configure with CMake
cmake ..

# Build
make -j$(nproc)

# Install (optional)
sudo make install
```

### Build Options

```bash
# Debug build
cmake -DCMAKE_BUILD_TYPE=Debug ..

# Build with tests
cmake -DBUILD_TESTS=ON ..
make test
```

## Running

```bash
# From build directory
./xrg-linux

# If installed system-wide
xrg-linux
```

## AI Token Monitoring

XRG-ng for Linux includes real-time monitoring of AI API token usage across multiple providers (auto-detected):

| Provider | Data Source |
|----------|-------------|
| Claude Code | `~/.claude/projects/*/sessionid.jsonl` (JSONL) |
| OpenAI Codex CLI | `~/.codex/sessions/` (JSONL) |
| Google Gemini CLI | `~/.gemini/tmp/` (JSON) |
| Hermes agents | `~/.hermes/state.db` (SQLite, per-model tokens + cost) |

Hermes activity is broken out per model (every model the agent ran), with cost read straight from the Hermes database. (Ollama tracking is macOS-only for now.)

### How It Works

The AI Token monitor automatically detects and uses the best available data source:

1. **JSONL Transcripts** (Primary - Universal)
   - Source: `~/.claude/projects/*/sessionid.jsonl`
   - Works with default Claude Code installation
   - No configuration required

2. **SQLite Database** (Fallback - Advanced)
   - Source: `~/.claude/monitoring/claude_usage.db`
   - For users with custom monitoring setups

3. **OpenTelemetry** (Fallback - Advanced)
   - Source: `http://localhost:8889/metrics`
   - For users with OTel configured

### Quick Start

1. Run XRG-ng for Linux
2. Open Preferences → Modules
3. Enable "AI Tokens" module
4. Use Claude Code in another terminal
5. Watch live token consumption in the graph

No setup or configuration needed - it just works!

### Per-Model Token Breakdown

**New in Nov 2025:** The AI Token module now displays token usage **per AI model**!

**Visual Example:**
```
AI Tokens
Rate: 1234/s
Total: 4567890
─ By Model ─
* claude-sonnet-4-5...: 3456789
  claude-opus-4...: 1111101
```

**Features:**
- ✅ Automatic model detection from JSONL files
- ✅ Per-model token aggregation
- ✅ Active model marked with asterisk (*)
- ✅ Long model names truncated for readability
- ✅ Toggle model breakdown on/off in preferences

**Configuration:**
```bash
# Enable model breakdown (default: true)
show_model_breakdown=true
```

Or via Preferences UI: **AI Token → Show Model Breakdown**

**Supported Models:**
- claude-sonnet-4-5-20250929
- claude-opus-4-20250514
- claude-haiku-3-5-20250410
- gpt-4, gpt-4-turbo
- And any other model in your JSONL files

## Configuration

XRG-ng for Linux stores preferences in `~/.config/xrg-linux/settings.conf` (GKeyFile format).

### Default Settings

- **Window Position:** Remembered on exit
- **Update Intervals:**
  - Fast (100ms): CPU, Network
  - Normal (1s): Memory, Disk, GPU
  - Slow (5s): Temperature, Battery
  - Very Slow (5min): Weather, Stocks
- **Colors:** Customizable cyberpunk theme
  - Background: Dark blue-black (RGB 0.02, 0.05, 0.12, 95% opacity)
  - Graph BG: Dark blue (RGB 0.05, 0.08, 0.15, 95% opacity)
  - FG1: Electric Cyan (RGB 0.0, 0.95, 1.0) - #00F2FF
  - FG2: Magenta (RGB 1.0, 0.0, 0.8) - #FF00CC
  - FG3: Electric Green (RGB 0.2, 1.0, 0.3) - #33FF4D

### Module Configuration

Each module can be individually:
- Enabled/disabled
- Reordered (display priority)
- Resized (height)
- Customized (colors, update rate)

## Architecture

XRG-ng for Linux follows the original XRG-ng three-layer architecture:

1. **Data Collector Layer** - Gathers system metrics via /proc, /sys, lm-sensors
2. **Graph Widget Layer** - Renders graphs using Cairo (GTK)
3. **Module Manager** - Orchestrates module lifecycle and layout

### Project Structure

```
xrg-linux/
├── src/
│   ├── collectors/      # Data collection (CPU, Memory, Network, etc.)
│   ├── widgets/         # Graph rendering (GTK widgets with Cairo)
│   ├── core/            # Module manager, dataset, preferences
│   ├── ui/              # Main window, preferences dialog
│   └── main.c           # Application entry point
├── data/                # Desktop file, icons
├── tests/               # Unit and integration tests
└── CMakeLists.txt       # Build configuration
```

## Data Sources

| Module | Linux Data Source |
|--------|-------------------|
| CPU | `/proc/stat`, `/proc/loadavg` |
| Memory | `/proc/meminfo`, `/proc/vmstat` |
| Network | `/proc/net/dev`, `/sys/class/net/*/statistics/` |
| Disk | `/proc/diskstats`, `/sys/block/*/stat` |
| GPU | NVML (NVIDIA), libdrm (AMD/Intel), `/sys/class/drm/` |
| Temperature | lm-sensors library, `/sys/class/thermal/`, `/sys/class/hwmon/` |
| Battery | UPower DBus API, `/sys/class/power_supply/` |
| AI Tokens | `~/.claude/projects/*/sessionid.jsonl`, SQLite, HTTP |

## Packaging

### DEB Package (Debian/Ubuntu)

```bash
# Install build dependencies
sudo apt install build-essential cmake libgtk-3-dev libcairo2-dev libglib2.0-dev \
                 libsqlite3-dev libcurl4-openssl-dev libjson-glib-dev

# Build DEB
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make package
sudo dpkg -i xrg-linux_1.0.0_amd64.deb
```

### RPM Package (Fedora/RHEL)

```bash
# Install build dependencies
sudo dnf install gcc cmake gtk3-devel cairo-devel glib2-devel \
                 sqlite-devel libcurl-devel json-glib-devel

# Build RPM
mkdir build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make package
sudo rpm -i xrg-linux-1.0.0.x86_64.rpm
```

### AppImage (Universal)

```bash
# Build AppImage
./build-appimage.sh
./xrg-linux-1.0.0-x86_64.AppImage
```

## Performance

XRG-ng for Linux is designed to be lightweight:

- **CPU Usage:** <1% when idle, 2-3% during active monitoring
- **Memory:** ~30-50 MB RAM
- **Disk:** Minimal (only config file writes)

## Contributing

Contributions welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## Comparison with Original XRG-ng

| Feature | macOS XRG-ng | XRG-ng for Linux |
|---------|-----------|-----------|
| CPU Monitor | ✓ | ✓ |
| Memory Monitor | ✓ | ✓ |
| Network Monitor | ✓ | ✓ |
| Disk Monitor | ✓ | ✓ |
| GPU Monitor | ✓ (Apple Silicon, Intel) | ✓ (NVIDIA, AMD, Intel) |
| Temperature | ✓ (SMC) | ✓ (lm-sensors) |
| Battery | ✓ (IOKit) | ✓ (UPower) |
| AI Tokens | ✓ | ✓ |
| Weather | ✓ | ✓ |
| Stocks | ✓ | ✓ |
| UI Framework | Cocoa/AppKit | GTK |
| Graphics | Quartz 2D | Cairo |

## Known Issues

- GPU monitoring requires vendor-specific libraries (NVML for NVIDIA, etc.)
- Some hardware sensors may not be detected (depends on lm-sensors support)
- Weather and stock modules require internet connection

## License

GNU General Public License v3.0 or later - see [LICENSE](../LICENSE) file for details.

See [project copyright](../COPYRIGHT) and [third-party notices](../THIRD_PARTY_NOTICES.md). Based on the original XRG by Mike Piatek-Jimenez / Gaucho Software, LLC.

## Credits

- Mike Piatek-Jimenez / Gaucho Software, LLC (2002–2024): original XRG.
- Marc Shade (2025–2026): fork maintenance, AI token monitoring, and Linux port.
- Stephen de la Vega (2026–present): XRG-ng maintenance and Swift migration.

## Links

- **Original XRG website:** https://gaucho.software/xrg/
- **GitHub Repository:** https://github.com/marc-shade/XRG
- **Issues:** https://github.com/marc-shade/XRG/issues
- **Documentation:** https://github.com/marc-shade/XRG/wiki
