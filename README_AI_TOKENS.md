# XRG-ng AI Token Monitoring

Track AI API token usage and costs system-wide in real-time with XRG-ng's AI Token module.

## Quick Start (Zero Configuration)

```bash
# 1. Build and run XRG-ng
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng build
open ~/Library/Developer/Xcode/DerivedData/XRG-ng-*/Build/Products/Debug/XRG-ng.app

# 2. Enable in XRG-ng: Preferences → Graphs → Show AI Tokens

# 3. Use any AI tool - XRG-ng auto-detects and tracks tokens!
```

XRG-ng will display real-time token usage in a 5-layer stacked area graph with **accurate per-model cost tracking**!

## What It Tracks

**5 Providers Supported:**
- ✅ **Claude Code** - All sessions, all subagents (`~/.claude/projects/`)
- ✅ **OpenAI Codex CLI** - Session transcripts (`~/.codex/sessions/`)
- ✅ **Google Gemini CLI** - Chat sessions (`~/.gemini/tmp/`)
- ✅ **Ollama** - Local inference via REST API (localhost:11434)
- ✅ **Hermes agents** - Agent-orchestrator activity via SQLite (`~/.hermes/state.db`)

**Metrics Tracked:**
- ✅ Input/output tokens per provider
- ✅ Real-time token rate (tokens/sec)
- ✅ **Accurate per-model API cost calculation** (not hardcoded estimates)
- ✅ Total cost in USD with per-provider breakdown
- ✅ Hourly burn rate ($/hour)
- ✅ Projected daily cost
- ✅ Ollama model availability and status

## Per-Model Pricing (Accurate API Costs)

XRG-ng extracts the actual model name from each API call and calculates costs using **official provider pricing**:

### Claude (Anthropic) Models
| Model | Input $/MTok | Output $/MTok |
|-------|--------------|---------------|
| Opus 4.5 | $15.00 | $75.00 |
| Opus 4 / Opus 3 | $15.00 | $75.00 |
| Sonnet 4 | $3.00 | $15.00 |
| Sonnet 3.5 v2 | $3.00 | $15.00 |
| Haiku 3.5 | $0.80 | $4.00 |
| Haiku 3 | $0.25 | $1.25 |

### OpenAI/Codex Models
| Model | Input $/MTok | Output $/MTok |
|-------|--------------|---------------|
| o1-preview | $15.00 | $60.00 |
| o1-mini | $3.00 | $12.00 |
| o3-mini | $1.10 | $4.40 |
| GPT-4o | $2.50 | $10.00 |
| GPT-4o-mini | $0.15 | $0.60 |
| GPT-4 Turbo | $10.00 | $30.00 |
| GPT-4 | $30.00 | $60.00 |
| GPT-3.5 Turbo | $0.50 | $1.50 |

### Gemini (Google) Models
| Model | Input $/MTok | Output $/MTok |
|-------|--------------|---------------|
| Gemini 2.0 Flash | $0.10 | $0.40 |
| Gemini 1.5 Pro | $1.25 | $5.00 |
| Gemini 1.5 Flash | $0.075 | $0.30 |
| Gemini Ultra | $10.00 | $30.00 |

### Ollama (Local)
- **Cost**: $0.00 (local inference)
- Shows model availability and running status

### Hermes (Agent Orchestrator)
- **Source**: SQLite `~/.hermes/state.db` (`sessions` table)
- Tracks every model the agent dispatched to, with a per-model token breakdown
- **Cost**: read straight from Hermes (`actual_cost_usd`, falling back to `estimated_cost_usd`) and never re-priced by XRG-ng — local models report $0, cloud models report their real cost

**Note for Max/Subscription Users**: The displayed API costs are for reference only - they show what your usage *would* cost at API rates. Great for understanding the value of your subscription!

## Architecture

```
Claude/Codex/Gemini → JSONL files ┐
Ollama              → REST API     ├─→ XRG-ng Parser → Graph
Hermes agents       → SQLite DB    ┘   (real-time)
```

**Benefits:**
- Real-time updates (1-2 second latency)
- Zero configuration - auto-detects installed AI tools
- Accurate per-model pricing from actual API responses
- Minimal resource usage (<1% CPU, background parsing)
- Privacy-preserving: only parses token counts, not content

## Requirements

- macOS 26+ (XRG-ng requirement)
- XRG-ng application
- One or more AI coding tools:
  - Claude Code (`~/.claude/projects/` must exist)
  - OpenAI Codex CLI (`~/.codex/sessions/` must exist)
  - Gemini CLI (`~/.gemini/tmp/` must exist)
  - Ollama (running on localhost:11434)
  - Hermes agents (`~/.hermes/state.db` must exist)

**No additional setup required** - XRG-ng auto-detects all installed tools!

## How It Works

1. **AI Tools** (Claude/Codex/Gemini) write session transcripts to JSONL files
2. **XRG-ng Parser** monitors these files in the background (non-blocking)
3. **Per-Model Pricing** extracts model name from `message.model` field
4. **Cost Calculation** uses accurate per-model rates from provider pricing
5. **Graph** displays real-time stacked area chart with token rates and costs

### Data Sources

| Provider | Source Path | Format |
|----------|-------------|--------|
| Claude Code | `~/.claude/projects/*/sessionid.jsonl` | JSONL with `message.model` |
| Codex CLI | `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | JSONL with `token_count` events |
| Gemini CLI | `~/.gemini/tmp/*/chats/session-*.json` | JSON with messages array |
| Ollama | `http://localhost:11434/api/*` | REST API |
| Hermes agents | `~/.hermes/state.db` | SQLite (`sessions` table) |

## XRG-ng Integration

The AI Token module appears in XRG-ng alongside other system monitors:
- **5-layer stacked area graph** (Claude, Codex, Gemini, Ollama, Hermes)
- **Real-time rate indicator** (color-coded per provider)
- **Provider legend** (C=Claude, X=Codex, G=Gemini, O=Ollama, H=Hermes)
- **Per-model Hermes breakdown** - lists every model the agent ran, sorted by token count
- **Token totals** with smart B/M/K formatting
- **Cost Intelligence menu** - right-click the graph for total cost, $/hour burn rate, projected 24-hour cost, and per-provider costs (cost lives in the menu, not drawn on the graph)
- **Mini-mode support** for compact display

Colors follow XRG-ng's theme (customizable in Preferences → Appearance).

## Performance

- **CPU**: <1% (background threading for file I/O)
- **Memory**: ~95 MB typical (intelligent caching)
- **Disk I/O**: Incremental parsing (only new data)
- **Update Latency**: 1-2 seconds during active AI usage

Efficient caching avoids re-parsing unchanged files.

## FAQ

**Q: Does this track ALL AI usage on my Mac?**
A: Yes! XRG-ng tracks Claude Code, OpenAI Codex CLI, Gemini CLI, Ollama, and Hermes agents - all major AI coding tools plus your agent orchestrator.

**Q: Are the costs accurate?**
A: Yes! XRG-ng extracts the actual model name from each API call and uses official provider pricing. Different models (Opus vs Sonnet vs Haiku) have different costs.

**Q: I use Max/subscription - why show API costs?**
A: The costs are for reference - they show what your usage would cost at API rates. Great for understanding the value you're getting from your subscription!

**Q: Does it work across multiple sessions?**
A: Yes! Automatically tracks all sessions from all providers system-wide.

**Q: Does this send data to the cloud?**
A: No. All monitoring is 100% local. Only reads local JSONL files and Ollama API.

**Q: What about privacy?**
A: Only token counts, model names, and costs are tracked. XRG-ng never reads prompts, responses, or file contents.

## Support

- **XRG-ng Issues**: https://gaucho.software/xrg/
- **Claude Code Docs**: https://docs.anthropic.com/en/docs/claude-code
- **Codex CLI Docs**: https://github.com/openai/codex

## License

XRG-ng project code uses GNU GPL version 3 or later. See [LICENSE](LICENSE) and [third-party notices](THIRD_PARTY_NOTICES.md) for retained APSL components and the combined-distribution limitation.

## Credits

- **XRG-ng**: Gaucho Software
- **AI Token Monitoring**: marc-shade (2025)
- **Claude Code**: Anthropic
- **Codex CLI**: OpenAI
- **Gemini CLI**: Google

---

**Status:** Production Ready

**Last Updated:** July 1, 2026
