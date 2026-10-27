XRG-ng
======

<img width="1080" height="188" alt="AI-Tokens" src="https://github.com/user-attachments/assets/bfb873ea-6564-437f-af2c-315b14b3dfb0" />


A real-time system resource monitor for **macOS and Linux** with customizable floating graphs.

🍎 **macOS**: Native Swift/Objective-C AppKit implementation (macOS 26+, Intel and Apple silicon)
🐧 **Linux**: Swift/Rust + GTK4 rewrite in progress; C/GTK3 application remains available.
See the [new Linux build and migration status](xrg-linux/rust/README.md).



Original XRG website: https://gaucho.software/xrg/

## Features

XRG-ng displays real-time graphs for:

- **CPU Usage** - Per-core utilization and load averages
- **GPU Usage** - GPU utilization and memory (Apple Silicon & Intel)
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
and opacity immediately. Classic restores the existing palette; Paper provides a
light background, while the other palettes offer dark alternatives.

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

**Requirements:**
- GTK 3.24+
- Cairo 1.16+
- GLib 2.66+
- json-glib
- CMake 3.16+
- C compiler (gcc/clang)

**Build Commands:**

```bash
cd xrg-linux
mkdir build && cd build
cmake ..
make -j$(nproc)
./xrg-linux
```

**Install System-Wide:**

```bash
sudo make install
```

For detailed Linux documentation, see [xrg-linux/README.md](xrg-linux/README.md)

## License

Project code uses **GNU GPL version 3 or later (GPL-3.0-or-later)**. See [LICENSE](LICENSE), [COPYRIGHT](COPYRIGHT), and [third-party notices](THIRD_PARTY_NOTICES.md).

Bundled Apple/CodeExchange sensor sources retain APSL licenses. APSL/GPL compatibility for distribution of the combined macOS executable remains unresolved; the project license update does not relicense those components.

## Credits

- **Mike Piatek-Jimenez / Gaucho Software, LLC — 2002–2024:** original XRG creator.
- **Marc Shade — 2025–2026:** fork maintenance, AI token monitoring, and Linux port.
- **Stephen de la Vega — 2026–present:** XRG-ng maintenance and Swift migration.
- Other contributors retain their source notices and Git attribution.
