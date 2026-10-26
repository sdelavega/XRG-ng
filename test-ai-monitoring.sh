#!/bin/bash
# Test AI Token Monitoring System
# Verifies the complete pipeline: Claude Code → OTel Bridge → XRG-ng

echo "=== XRG-ng AI Token Monitoring Test ==="
echo ""

FAIL=0

# Test 1: Check environment variables
echo "1. Checking Claude Code telemetry environment..."
if [ "$CLAUDE_CODE_ENABLE_TELEMETRY" = "1" ]; then
    echo "   ✓ CLAUDE_CODE_ENABLE_TELEMETRY=1"
else
    echo "   ❌ CLAUDE_CODE_ENABLE_TELEMETRY not set"
    echo "      Run: export CLAUDE_CODE_ENABLE_TELEMETRY=1"
    FAIL=1
fi

if [ -n "$OTEL_EXPORTER_OTLP_ENDPOINT" ]; then
    echo "   ✓ OTEL_EXPORTER_OTLP_ENDPOINT=$OTEL_EXPORTER_OTLP_ENDPOINT"
else
    echo "   ⚠️  OTEL_EXPORTER_OTLP_ENDPOINT not set (Claude Code won't send telemetry)"
    echo "      Run: export OTEL_EXPORTER_OTLP_ENDPOINT=\"http://localhost:4318\""
fi

echo ""

# Test 2: Check if bridge is running
echo "2. Checking if OTel bridge is running..."
if lsof -i :4318 > /dev/null 2>&1; then
    PID=$(lsof -t -i :4318)
    echo "   ✓ Bridge running on port 4318 (PID: $PID)"
else
    echo "   ❌ No service on port 4318"
    echo "      Run: /Volumes/FILES/code/XRG/start-ai-monitoring.sh"
    FAIL=1
fi

echo ""

# Test 3: Test metrics endpoint
echo "3. Testing metrics endpoint..."
RESPONSE=$(curl -s http://localhost:4318/v1/metrics 2>&1)
if [ $? -eq 0 ] && [ -n "$RESPONSE" ]; then
    echo "   ✓ Endpoint responding"

    # Check for expected metrics
    if echo "$RESPONSE" | grep -q "claude_code_token_usage"; then
        echo "   ✓ Token metrics present"
    else
        echo "   ⚠️  No token metrics yet (use Claude Code to generate some)"
    fi

    if echo "$RESPONSE" | grep -q "claude_code_cost_usage"; then
        echo "   ✓ Cost metrics present"
    else
        echo "   ⚠️  No cost metrics yet"
    fi

    echo ""
    echo "   Sample metrics:"
    echo "$RESPONSE" | grep -E "claude_code_(token|cost)" | head -5 | sed 's/^/      /'
else
    echo "   ❌ Endpoint not responding"
    FAIL=1
fi

echo ""

# Test 4: Check if XRG-ng is running
echo "4. Checking if XRG-ng is running..."
if ps aux | grep -i xrg | grep -v grep > /dev/null; then
    PID=$(ps aux | grep -i xrg | grep -v grep | awk '{print $2}' | head -1)
    echo "   ✓ XRG-ng running (PID: $PID)"
else
    echo "   ⚠️  XRG-ng not running"
    echo "      Launch XRG-ng from Xcode or Applications folder"
fi

echo ""

# Test 5: Verify XRG-ng preferences
echo "5. Checking XRG-ng AI Token module preferences..."
AI_ENABLED=$(defaults read com.gauchosoft.xrg showAITokenGraph 2>/dev/null)
if [ "$AI_ENABLED" = "1" ]; then
    echo "   ✓ AI Token graph enabled in XRG-ng"
else
    echo "   ⚠️  AI Token graph not enabled"
    echo "      Enable in XRG-ng: Preferences → Graphs → Show AI Tokens"
fi

CUSTOM_ENDPOINT=$(defaults read com.gauchosoft.xrg XRG_aiTokenOTelEndpoint 2>/dev/null)
if [ -n "$CUSTOM_ENDPOINT" ]; then
    echo "   ℹ️  Custom endpoint: $CUSTOM_ENDPOINT"
else
    echo "   ✓ Using default endpoint: http://localhost:4318/v1/metrics"
fi

echo ""

# Summary
echo "=== Summary ==="
if [ $FAIL -eq 0 ]; then
    echo "✓ All critical checks passed"
    echo ""
    echo "Next steps:"
    echo "  1. Use Claude Code to generate some token traffic"
    echo "  2. Watch XRG-ng for real-time graph updates"
    echo "  3. Verify metrics with: curl http://localhost:4318/v1/metrics"
else
    echo "❌ Some checks failed - see errors above"
    echo ""
    echo "Quick fix:"
    echo "  1. Run: /Volumes/FILES/code/XRG/start-ai-monitoring.sh"
    echo "  2. In new terminal, add to ~/.zshrc or ~/.bashrc:"
    echo "     export CLAUDE_CODE_ENABLE_TELEMETRY=1"
    echo "     export OTEL_EXPORTER_OTLP_ENDPOINT=\"http://localhost:4318\""
    echo "  3. Restart terminal or: source ~/.zshrc"
fi

echo ""
exit $FAIL
