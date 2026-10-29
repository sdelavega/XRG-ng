XRG-ng
======

<img width="1080" height="188" alt="AI-Tokens" src="https://github.com/user-attachments/assets/bfb873ea-6564-437f-af2c-315b14b3dfb0" />


A real-time system resource monitor for **macOS and Linux** with customizable floating graphs.

🍎 **macOS**: Native Swift/Objective-C AppKit implementation (macOS 26+, Intel and Apple silicon)
🐧 **Linux**: Swift/Rust + egui rewrite in progress; C/GTK3 application remains available.
See the [new Linux build and migration status](xrg-linux/rust/README.md).
The Linux preview includes an opt-in [station weather window](xrg-linux/rust/README.md#weather-observations)
using the same Swift METAR decoder as macOS.



Original XRG website: https://gaucho.software/xrg/

## Hardware support and feedback

Hardware support is a **best-effort attempt**, especially across Linux GPU families,
sensors and driver versions. We do not have access to every platform and cannot
physically test them all. Development uses published driver interfaces, automated
fixtures, native architecture builds and the hardware available to us. Automated
checks verify software behavior; real-device coverage is limited and will grow
with community feedback. Available metrics depend on the device, kernel, driver
and permissions.

**Feedback is welcome and encouraged**, including reports of configurations that
work well. Please [open an issue](https://github.com/sdelavega/XRG-ng/issues) with
your XRG-ng version, distribution, kernel, CPU architecture, GPU/device model and
driver, plus expected versus observed behavior and relevant diagnostic output.
Bug reports, corrections and contributions help improve support for everyone.
Physical validation of every listed platform is not a prerequisite for progress
or releases.

## Apple Neural Engine on macOS

The **NPU** graph sits directly below **GPU** and above **Memory** in vertical
layout (GPU → NPU → Memory horizontally). It is enabled by default on Apple
Silicon; General Preferences provides a **Neural Engine** visibility checkbox.
Intel Macs keep it hidden by default. Existing module sizes, visibility choices,
themes and XTF load/save continue to work.

The graph shows **active time (%)** when macOS exposes an ANE `ACT` residency
counter under IOReport **SoC Stats → Cluster Power States**. The scale is fixed
at 0–100%, with **Busy/Idle** and power in watts beside it. Active time is the
busiest ANE cluster's software active-state share over the sampling interval;
it does not measure compute-core occupancy, operations per second or inference
throughput. Overlapping clusters are never added together.

Where residency is unavailable, the graph shows **ANE power in watts**, from
energy-counter changes over elapsed monotonic time, and **n/a%**. **Pwr↑** marks
an energy increase: an inferred activity signal, not a utilization percentage.
The fallback scale follows observed watts. A zero energy delta means only that
the counter reported no increase; it does **not** prove the NPU was idle.
Where macOS exposes ANE fabric sampling, a narrow secondary-color **traffic band**
also marks observed transfers. **Traffic** / **No bus** describe those reports;
they do not claim compute occupancy or idle. The band follows the rate of positive
bandwidth-bin reports, with its own observed scale. It is not a percent meter,
bytes/sec or an inference count. Background/housekeeping traffic can appear too.
This path was exercised against controlled ANE evaluation calls on an M4 Pro and
M5, including runs where the energy counter stayed unchanged. Watts and **n/a%**
remain visible when direct active-time telemetry is unavailable.
Tooltips/context menu and accessibility text include the last detected activity
and its source, endpoint identity, core count/architecture and firmware state.
Detection, firmware presence and open client connections do not prove execution.

Acquisition is read-only, runs on a serial background queue and coalesces requests
to at most one per second. It opens no accelerator user client, loads no models,
and needs no root helper, `powermetrics`, network service or extra dependency.
The optional private IOReport symbols are resolved at runtime. Residency,
energy and traffic use independent subscriptions; unavailable power does not hide
valid activity readings. State intervals use `IOReportCreateSamplesDelta`, reject
counter resets and unknown state layouts, and require positive total residency
before reporting even 0%. Only recognized ANE channels/units are used; energy
aggregates take precedence over their indexed components and counter identities
must be unique. The first sample, resets, source/unit changes, stale data and
failures establish a fresh interval. Missing data creates no synthetic idle
samples. Registry discovery is bounded to 16 endpoints.

See [macOS NPU telemetry notes](Tools/macos-npu-telemetry.md) for the private API
investigation, hardware limitations and a read-only diagnostic command.

Apple's private interfaces can differ across chips and macOS versions. This is
best-effort support: unavailable metrics remain explicit, and device feedback is
welcome and encouraged. The implementation uses IOReport's energy subscription
interface (see the [interface reference](https://github.com/tmc/aneperf/blob/main/ioreport.go));
automated fixtures cover conversion, recovery, graph placement and preferences.
Live checks on the available Mac verify discovery and readable energy counters,
not every model or workload.

## Features

XRG-ng displays real-time graphs for:

- **CPU Usage** - Per-core utilization and load averages
- **GPU Usage** - GPU utilization and memory (Apple Silicon & Intel)
- **Neural Engine (NPU)** - Apple ANE active-time percentage where exposed, power and recent activity, between GPU and Memory on macOS
- **Memory** - RAM usage, swap, page ins/outs
- **Network** - Upload/download rates per interface
- **Disk Activity** - Read/write operations per volume
- **Battery** - Charge level, time remaining, health
- **Temperature** - CPU, GPU, and system sensors
- **Weather** - Current conditions and forecast
- **Stock Prices** - Real-time market data
- **AI Token Usage** - Live token consumption and cost tracking for Claude, Codex, Gemini, Ollama, and Hermes agents

## AI Token Monitoring

**New in this fork**: Real-time monitoring of AI token usage and costs across multiple AI providers.

### Supported Providers

| Provider | Data Source | Type | Auto-Detected |
|----------|-------------|------|---------------|
| **Claude Code** | `~/.claude/projects/*/sessionid.jsonl` | Cloud API | ✓ |
| **OpenAI Codex CLI** | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Cloud API | ✓ |
| **Google Gemini CLI** | `~/.gemini/tmp/<hash>/chats/session-*.json` | Cloud API | ✓ |
| **Ollama** | REST API (localhost:11434) | Local Inference | ✓ |
| **Hermes agents** | SQLite (`~/.hermes/state.db`) | Agent orchestrator | ✓ |

### Features

- **5-Provider Support** - Track Claude, Codex, Gemini, Ollama, and Hermes agents in a single stacked graph
- **Cost Intelligence** - Total cost, $/hour burn rate, and projected daily cost in the right-click menu
- **Per-Provider Costs** - Accurate pricing (Claude $3/$15, Codex $2.50/$10, Gemini $0.15/$0.60 per MTok)
- **Ollama Integration** - Detect available models, show running models, track local inference
- **Hermes Agent Tracking** - Per-model token breakdown and cost read straight from the Hermes state DB
- **Zero Configuration** - Auto-detects installed AI tools, no setup required
- **Real-Time Tracking** - Updates within 1-2 seconds during active AI usage
- **Per-Provider Breakdown** - Color-coded visualization shows usage by provider (and per-model for Hermes)
- **Performance Optimized** - Background threading, intelligent caching, 95MB memory footprint

### How It Works

The AI Token monitor automatically detects all installed AI coding tools:

1. **Claude Code** (Anthropic) - Cloud API
   - Source: `~/.claude/projects/*/sessionid.jsonl`
   - Tracks input/output tokens with accurate cost calculation
   - Pricing: $3/MTok input, $15/MTok output

2. **OpenAI Codex CLI** - Cloud API
   - Source: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`
   - Parses `token_count` events from session files
   - Pricing: $2.50/MTok input, $10/MTok output

3. **Google Gemini CLI** - Cloud API
   - Source: `~/.gemini/tmp/<hash>/chats/session-*.json`
   - Extracts tokens from message history
   - Pricing: $0.15/MTok input, $0.60/MTok output

4. **Ollama** - Local Inference
   - Source: REST API at `http://localhost:11434`
   - Queries `/api/tags` for available models
   - Queries `/api/ps` for currently loaded models
   - Zero cost (local inference)

5. **Hermes Agents** - Agent Orchestrator
   - Source: SQLite database at `~/.hermes/state.db`
   - Aggregates every model the agent ran (e.g. gpt-5.5, MiniMax, qwen, gemma, claude-opus)
   - Shows a per-model token breakdown under the Hermes line, sorted by usage
   - Cost read directly from Hermes (`actual`/`estimated_cost_usd`), never re-priced

### Quick Start

1. Build and run XRG-ng
2. Open Preferences → Graphs
3. Enable "Show AI Tokens"
4. Use Claude Code in another terminal
5. Watch live token consumption in the graph

For detailed documentation, see [README_AI_TOKENS.md](README_AI_TOKENS.md)

## Built-in themes (macOS)

Open **Preferences → Appearance → Built-in Themes** to apply **Classic**,
**Midnight**, **Ocean**, **Dusk**, **Paper**, or **Phosphor**. Presets update colors
and opacity immediately. **Classic** is the default macOS palette: the original
XRG theme's blue, gold and red graphs on black, with white text. Paper provides a
light background, while the other palettes offer dark alternatives. Existing
saved appearances keep their colors; choose Classic to apply it to an existing setup.

Customize any preset with the existing color wells and opacity sliders. **Load
Theme** and **Save Theme** continue to use `.xtf` files, including existing custom
themes. Presets keep your font, graph style, layout and monitoring settings.

## Building

### macOS

**Requirements:**
- Xcode 26.3 or newer with the macOS SDK and Command Line Tools selected
- macOS 26 or newer to run the app and tests; Intel and Apple silicon builds remain supported.

This checkout includes local signing and bundle-identifier changes. Select your own development team in Xcode for signed builds. For a compile-only check without a signing identity:

```bash
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The app product and shared launch scheme are `XRG-ng`; internal `XRGCore`/`XRGTests` modules and preference identifiers remain stable.

See [the modernization review](MODERNIZATION.md) for the current baseline, fork-specific issues, and remaining work.

**Tests:** Select either shared scheme (`XRG-ng` or `XRGTests`) in Xcode and choose Product → Test. The macOS suite links the same static Swift `XRGCore` framework as the app and uses temporary preferences suites. Coverage includes built-in theme application and file round trips, settings, collectors, provider parsers, graph rendering, native interfaces and application lifecycle.

**Continuous integration:** [The macOS workflow](.github/workflows/macos.yml) builds universal Apple Silicon/Intel apps and runs native and Rosetta x86_64 tests for both Debug and Release on pushes, pull requests, and manual dispatch. It uses Xcode 26.6 on `macos-26`, requires no signing secrets, and retains logs and test results for seven days. Separate composition and packaged-app smoke checks use disposable preference domains. These are compile/test builds, not signed distribution packages.

Run the same checks locally with your selected Xcode:

```bash
bash Tools/ci-macos.sh Debug
bash Tools/ci-macos.sh Release
```

Each run prints a temporary directory containing its build output, logs, and `.xcresult` bundle. The script fails on build/test errors or an empty test run. Remove that directory when you no longer need the results. Command-line tests require access to the macOS test runner service; in restricted environments, run the tests from Xcode instead.

**Build Commands:**

```bash
# Build
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng build

# Clean and rebuild
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng clean build

# Open in Xcode
open XRG-ng.xcodeproj
```

### Linux

The active build uses **Rust + shared Swift + egui/eframe**, with OpenGL and
X11/Wayland support. It has no GTK, GSK, Cairo or GLib frontend dependency.
Build natively on x86_64 or ARM64 with Swift 6.3+ (CI: 6.4.1), Rust 1.99.1,
a C compiler, pkg-config and the windowing/graphics libraries listed in the
[Linux build guide](xrg-linux/rust/README.md#build-and-run).

From the repository root:

```bash
cargo run --manifest-path xrg-linux/rust/Cargo.toml --features egui-ui
# Toolkit-independent diagnostics:
cargo run --manifest-path xrg-linux/rust/Cargo.toml -- --headless --samples 3
```

Native CI produces relocatable preview archives with the Swift runtime included;
see the [preview installation guide](xrg-linux/preview/README.md). No Swift or Rust
toolchain is needed to run those archives.

The earlier C/GTK3 application remains available separately for reference and
fallback. Its CMake instructions and dependencies are in the
[legacy Linux guide](xrg-linux/README.md).

## License

Project code uses **GNU GPL version 3 or later (GPL-3.0-or-later)**. See [LICENSE](LICENSE), [COPYRIGHT](COPYRIGHT), and [third-party notices](THIRD_PARTY_NOTICES.md).

Bundled Apple/CodeExchange sensor sources retain APSL licenses. APSL/GPL compatibility for distribution of the combined macOS executable remains unresolved; the project license update does not relicense those components.

## Credits

- **Mike Piatek-Jimenez / Gaucho Software, LLC — 2002–2024:** original XRG creator.
- **Marc Shade — 2025–2026:** fork maintenance, AI token monitoring, and Linux port.
- **Stephen de la Vega — 2026–present:** XRG-ng maintenance and Swift migration.
- Other contributors retain their source notices and Git attribution.
