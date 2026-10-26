# Native Claude Code OTel Setup for XRG-ng

This guide shows how to use Claude Code's **built-in OpenTelemetry support** instead of custom log parsing scripts.

## Architecture Comparison

### Old Architecture (Complex)
```
Claude Code → JSONL files → Python extractor → Log → Metrics exporter → OTel endpoint → XRG-ng
```

### New Architecture (Simple)
```
Claude Code → OTel Bridge → XRG-ng
```

## Benefits

✅ **Native Support** - Uses Claude Code's official telemetry
✅ **No External Scripts** - Eliminates Python extractors and log parsers
✅ **Real-time** - Direct OTLP streaming, no file polling
✅ **More Metrics** - Get cost, sessions, code modifications
✅ **Multi-session** - Automatic tracking across all Claude Code instances
✅ **Future-proof** - Won't break with Claude Code updates

## Setup Instructions

### Step 1: Enable Claude Code Telemetry

Add to `~/.zshrc` or `~/.bashrc`:

```bash
# Enable Claude Code OpenTelemetry
export CLAUDE_CODE_ENABLE_TELEMETRY=1

# Configure OTLP exporter
export OTEL_METRICS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json

# Optional: Enable logs/events
export OTEL_LOGS_EXPORTER=otlp

# Optional: Reduce cardinality if needed
export OTEL_METRICS_INCLUDE_SESSION_ID=false
export OTEL_METRICS_INCLUDE_VERSION=false
```

Reload shell:
```bash
source ~/.zshrc  # or source ~/.bashrc
```

### Step 2: Start the OTel Bridge

Make the bridge executable:
```bash
chmod +x /Volumes/FILES/code/XRG/claude-otel-bridge.py
```

Run the bridge:
```bash
/Volumes/FILES/code/XRG/claude-otel-bridge.py
```

You should see:
```
Claude Code OTel Bridge running on http://127.0.0.1:4318
Receiving OTLP at: POST http://127.0.0.1:4318/v1/metrics
Exposing Prometheus at: GET http://127.0.0.1:4318/v1/metrics
XRG-ng will poll the GET endpoint for metrics
```

### Step 3: Verify It's Working

Open a new terminal and use Claude Code:
```bash
claude-code "write a hello world program"
```

Check metrics are being collected:
```bash
curl http://localhost:4318/v1/metrics
```

Expected output:
```
# HELP claude_code_token_usage Token usage by type
# TYPE claude_code_token_usage counter
claude_code_token_usage{type="input"} 1234
claude_code_token_usage{type="output"} 567
claude_code_token_usage{type="cache_read"} 0
claude_code_token_usage{type="cache_creation"} 0
# HELP claude_code_cost_usage Total cost in USD
# TYPE claude_code_cost_usage gauge
claude_code_cost_usage 0.0045
```

### Step 4: Launch XRG-ng

Build and run XRG-ng:
```bash
cd /Volumes/FILES/code/XRG
xcodebuild -project XRG-ng.xcodeproj -scheme XRG-ng build
open build/Release/XRG-ng.app
```

Or if already running, just enable the AI Tokens module:
- Preferences → Graphs → Check "Show AI Tokens"

### Step 5: Run the Bridge at Startup (Optional)

Create a LaunchAgent to auto-start the bridge:

```bash
cat > ~/Library/LaunchAgents/com.gaucho.xrg.otelbridge.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gaucho.xrg.otelbridge</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/Volumes/FILES/code/XRG/claude-otel-bridge.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/xrg-otel-bridge.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/xrg-otel-bridge.error.log</string>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.gaucho.xrg.otelbridge.plist
```

## Migration from Old System

### Stop Old Services

If you're running the Python extractors and metrics exporter:

```bash
# Find and kill old processes
ps aux | grep claude-token-extractor-all
kill <PID>

ps aux | grep claude-metrics-exporter
kill <PID>

# Disable from startup if configured
launchctl unload ~/Library/LaunchAgents/com.claude.token.extractor.plist 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.claude.metrics.exporter.plist 2>/dev/null
```

### Keep Old System as Backup (Recommended)

During transition, you can run both systems in parallel:
1. Keep Python extractors running (they write to logs)
2. Enable Claude Code OTel (writes to bridge)
3. Configure bridge on different port temporarily (e.g., 4319)
4. Test with both running
5. Switch XRG-ng to new port when confident
6. Disable old system

## Troubleshooting

### No Metrics Appearing in XRG-ng

**Check if Claude Code telemetry is enabled:**
```bash
echo $CLAUDE_CODE_ENABLE_TELEMETRY  # Should show "1"
```

**Check if bridge is running:**
```bash
curl http://localhost:4318/v1/metrics
# Should return Prometheus format metrics
```

**Check if Claude Code is sending data:**
- Use Claude Code for any task
- Check bridge logs (if running manually, you'll see POST requests)

**Verify endpoint in XRG-ng:**
- XRG-ng expects `http://localhost:4318/v1/metrics` (hardcoded in XRGAITokenMiner.m:60)
- Or can be customized via `XRG_aiTokenOTelEndpoint` preference

### Bridge Not Receiving Data

**Check Claude Code configuration:**
```bash
# Should all be set:
env | grep CLAUDE_CODE
env | grep OTEL
```

**Test OTLP endpoint manually:**
```bash
# Send test OTLP data
curl -X POST http://localhost:4318/v1/metrics \
  -H "Content-Type: application/json" \
  -d '{
    "resourceMetrics": [{
      "scopeMetrics": [{
        "metrics": [{
          "name": "claude_code.token.usage",
          "sum": {
            "dataPoints": [{
              "attributes": [
                {"key": "token_type", "value": {"stringValue": "input"}}
              ],
              "asInt": "999"
            }]
          }
        }]
      }]
    }]
  }'

# Check if it appears
curl http://localhost:4318/v1/metrics | grep 999
```

### Port Already in Use

If port 4318 is taken:

**Option 1: Use different port for bridge**
```bash
# Edit claude-otel-bridge.py, change line:
server_address = ('127.0.0.1', 4319)  # Use 4319 instead

# Update Claude Code config:
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4319"

# Update XRG-ng preference:
defaults write com.gauchosoft.xrg XRG_aiTokenOTelEndpoint "http://localhost:4319/v1/metrics"
```

**Option 2: Stop conflicting service**
```bash
lsof -i :4318  # Find what's using the port
kill <PID>     # Stop it
```

## What's Different in XRG-ng

**No code changes needed!** XRGAITokenMiner.m already:
- Polls the correct endpoint (localhost:4318/v1/metrics)
- Parses Prometheus format correctly
- Extracts token types (input, output, cache_read, cache_creation)
- Extracts cost metrics
- Calculates rates correctly

The implementation was already designed for this architecture!

## Available Metrics

With native OTel, you get these metrics (some not yet used by XRG-ng):

1. **claude_code_token_usage** - Token counts by type (✅ displayed in XRG-ng)
   - input, output, cache_read, cache_creation

2. **claude_code_cost_usage** - USD cost (✅ tracked, could be displayed)

3. **claude_code_sessions_count** - Session count (❌ not yet displayed)

4. **claude_code_code_modifications** - Lines added/removed (❌ not yet displayed)

5. **claude_code_pull_requests** - PRs created (❌ not yet displayed)

Future XRG-ng enhancements could display these additional metrics!

## Advanced Configuration

### Custom Metric Attributes

Filter by team/project:
```bash
export OTEL_RESOURCE_ATTRIBUTES="team=engineering,project=xrg"
```

### Reduce Cardinality

If metrics grow too large:
```bash
export OTEL_METRICS_INCLUDE_SESSION_ID=false
export OTEL_METRICS_INCLUDE_ACCOUNT_UUID=false
```

### Add Authentication

If exposing bridge over network:
```python
# In claude-otel-bridge.py, add to do_GET():
auth_header = self.headers.get('Authorization')
if auth_header != 'Bearer YOUR_SECRET_TOKEN':
    self.send_error(401)
    return
```

## Performance

**Bridge Resource Usage:**
- Memory: ~10-20 MB
- CPU: <1% (only active during metric updates)
- Network: Minimal (HTTP requests only when Claude Code is active)

**Compared to old system:**
- Old: 2 Python processes + file I/O + log parsing
- New: 1 Python process + direct HTTP (50% reduction)

## Next Steps

Once confirmed working:
1. Update XRG-ng documentation to reference native OTel
2. Consider removing old Python extractors from codebase
3. Enhance XRGAITokenView to display cost metrics
4. Add support for additional Claude Code metrics
5. Package bridge as proper macOS service

## Reference

- **Claude Code Docs**: https://code.claude.com/docs/en/monitoring-usage
- **XRG-ng Source**: `/Volumes/FILES/code/XRG/`
- **Bridge Script**: `/Volumes/FILES/code/XRG/claude-otel-bridge.py`
- **Miner Implementation**: `Data Miners/XRGAITokenMiner.m`
- **View Implementation**: `Graph Views/XRGAITokenView.m`
