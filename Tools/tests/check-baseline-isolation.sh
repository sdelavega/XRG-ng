#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Stephen de la Vega.
# Prove that build-upgrade-baseline.sh leaves the caller's Git metadata alone:
# .git/shallow is absent (or byte-identical to its starting state, e.g. in a
# shallow CI checkout) and the worktree list is unchanged after the build.
# Usage: bash Tools/tests/check-baseline-isolation.sh ABSOLUTE_BASELINE_OUTPUT_DIR
set -euo pipefail
[[ $# == 1 && "$1" == /* ]] || { echo 'Use an absolute baseline output directory' >&2; exit 2; }
cd "$(dirname "$0")/../.."

shallow_state() {
    if [[ -f .git/shallow ]]; then
        printf 'present %s' "$(<.git/shallow)"
    else
        printf 'absent'
    fi
}

shallow_before=$(shallow_state)
worktrees_before=$(git worktree list --porcelain)

bash Tools/build-upgrade-baseline.sh "$1"

shallow_after=$(shallow_state)
worktrees_after=$(git worktree list --porcelain)
if [[ "$shallow_after" != "$shallow_before" ]]; then
    echo "BASELINE_ISOLATION_FAILED: .git/shallow changed ($shallow_before -> $shallow_after)" >&2
    exit 1
fi
if [[ "$worktrees_after" != "$worktrees_before" ]]; then
    echo 'BASELINE_ISOLATION_FAILED: git worktree list changed' >&2
    exit 1
fi
echo "BASELINE_ISOLATION_OK shallow=$shallow_after worktrees-unchanged"
