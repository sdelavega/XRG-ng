#!/bin/bash
# Start AI Token Monitoring for XRG-ng
# This script enables Claude Code telemetry and starts the OTel bridge

set -e

echo "=== XRG-ng AI Token Monitoring Setup ==="
echo ""

# Check if bridge script exists
BRIDGE_SCRIPT="./claude-otel-bridge.py"
if [ ! -f "$BRIDGE_SCRIPT" ]; then
    echo "❌ Bridge script not found at: $BRIDGE_SCRIPT"
    exit 1
fi

# Check if port 4318 is already in use
if lsof -i :4318 > /dev/null 2>&1; then
    echo "⚠️  Port 4318 is already in use"
    echo "Current process:"
    lsof -i :4318
    echo ""
    read -p "Kill existing process and continue? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PID=$(lsof -t -i :4318)
        kill "$PID"
        echo "✓ Killed process $PID"
        sleep 1
    else
        echo "Exiting..."
        exit 1
    fi
fi

# Export Claude Code telemetry settings
echo "📝 Configuring Claude Code telemetry..."
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_LOGS_EXPORTER=otlp

# Add to shell config for persistence
SHELL_CONFIG=""
if [ -f "$HOME/.zshrc" ]; then
    SHELL_CONFIG="$HOME/.zshrc"
elif [ -f "$HOME/.bashrc" ]; then
    SHELL_CONFIG="$HOME/.bashrc"
fi

if [ -n "$SHELL_CONFIG" ]; then
    if ! grep -q "CLAUDE_CODE_ENABLE_TELEMETRY" "$SHELL_CONFIG"; then
        echo ""
        echo "📝 Adding telemetry config to $SHELL_CONFIG"
        cat >> "$SHELL_CONFIG" <<'EOF'

# Claude Code OpenTelemetry for XRG-ng AI Token Monitoring
export CLAUDE_CODE_ENABLE_TELEMETRY=1
export OTEL_METRICS_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
export OTEL_EXPORTER_OTLP_PROTOCOL=http/json
export OTEL_LOGS_EXPORTER=otlp
EOF
        echo "✓ Config added (will apply to new shell sessions)"
    else
        echo "✓ Telemetry config already in $SHELL_CONFIG"
    fi
fi

echo ""
echo "🚀 Starting OTel bridge..."
echo "   Listening on: http://localhost:4318"
echo "   Exposing metrics at: GET http://localhost:4318/v1/metrics"
echo ""
echo "Press Ctrl+C to stop"
echo "---"
echo ""

# Start the bridge
python3 "$BRIDGE_SCRIPT"
