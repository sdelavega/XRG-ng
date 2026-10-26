#!/bin/bash
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
# Read-only snapshots for stalled hosted builds. Never dump command arguments or environments.
set -u

diagnostic_output="${1:-}"
diagnostic_interval="${2:-300}"
if [[ ! -d "$diagnostic_output" || ! "$diagnostic_interval" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: $0 EXISTING_RESULTS_DIRECTORY [POSITIVE_INTERVAL_SECONDS]" >&2
    exit 2
fi

diagnostic_child=""
stop_diagnostics() {
    trap - TERM INT
    if [[ -n "$diagnostic_child" ]]; then
        kill "$diagnostic_child" 2>/dev/null || true
        wait "$diagnostic_child" 2>/dev/null || true
    fi
    exit 0
}
trap stop_diagnostics TERM INT

while true; do
    sleep "$diagnostic_interval" &
    diagnostic_child=$!
    wait "$diagnostic_child" || exit 0
    diagnostic_child=""
    diagnostic_stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    {
        echo "Snapshot: $diagnostic_stamp"
        cat "$diagnostic_output/phase.log"
        ps -axo pid,ppid,state,pcpu,pmem,etime,comm | awk \
            'NR == 1 || /\/(xcodebuild|ibtool|ibtoold|xctest|swift-frontend|clang|SWBBuildService|DTServiceHub)$/'
        for diagnostic_name in ibtool ibtoold xctest; do
            # Bound each snapshot to one process of each kind, owned by this runner.
            diagnostic_pid=$(pgrep -u "$(id -u)" -x "$diagnostic_name" | head -n 1)
            if [[ -n "$diagnostic_pid" ]]; then
                sample "$diagnostic_pid" 2 -mayDie \
                    -file "$diagnostic_output/sample-${diagnostic_stamp}-${diagnostic_name}.log" &
                diagnostic_child=$!
                wait "$diagnostic_child" || true
                diagnostic_child=""
            fi
        done
    } >> "$diagnostic_output/diagnostics.log" 2>&1
done
