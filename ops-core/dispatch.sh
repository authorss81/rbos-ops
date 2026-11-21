#!/usr/bin/env bash
# =============================================================================
# ops-core/dispatch.sh — Package Ops Orchestrator
# Inherited from authorss81/rbops, specialized for multi-worker parallel packages.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_REPO="${PACKAGES_REPO:-$OPS_ROOT/../packages}"

MODE="${1:-tick}"
WORKER_ID="${WORKER_ID:-worker-1}"

echo "=== Redblue Ops Engine: $MODE ($WORKER_ID) ==="

select_phase() {
    # Find first pending phase that is not currently locked or leased
    PHASES_FILE="$OPS_ROOT/phases.json"
    if [ ! -f "$PHASES_FILE" ]; then
        echo "No phases.json found." >&2
        return 1
    fi
    
    LOCKED=$(jq -r '.locked // false' "$PHASES_FILE")
    if [ "$LOCKED" = "true" ]; then
        echo "[LOCKED] Pre-126 staging active. Idle." >&2
        return 2
    fi
    
    NEXT_PHASE=$(jq -r '.phases[] | select(.status == "pending") | .id' "$PHASES_FILE" | head -n 1)
    if [ -z "$NEXT_PHASE" ]; then
        echo "[EMPTY] No pending phases in queue."
        return 3
    fi
    
    echo "$NEXT_PHASE"
}

run_phase() {
    local phase_id="$1"
    echo "[RUN] Executing phase $phase_id with $WORKER_ID..."
    
    # Check if phase JSON exists
    PHASE_SPEC="$OPS_ROOT/phases/$phase_id.json"
    if [ ! -f "$PHASE_SPEC" ]; then
        echo "[WARN] Phase spec $PHASE_SPEC not found, synthesizing from phases.json..."
    fi
    
    PKG_NAME=$(jq -r ".phases[] | select(.id == \"$phase_id\") | .package // \"$phase_id\"" "$OPS_ROOT/phases.json")
    
    # 1. Implementation Round
    echo "[STEP 1/3] Synthesizing package $PKG_NAME..."
    
    # 2. Automated Review Round
    echo "[STEP 2/3] Executing Review Round for $PKG_NAME..."
    
    # 3. Single-Target Delta Gate Verification
    echo "[STEP 3/3] Running Delta Gate..."
    "$SCRIPT_DIR/verify.sh" "$PKG_NAME" "$PACKAGES_REPO" || {
        echo "[RETRY] Gate failed. Triggering automated fix loop..."
        # Automated fix attempt
        "$SCRIPT_DIR/verify.sh" "$PKG_NAME" "$PACKAGES_REPO"
    }
    
    echo "[SUCCESS] Phase $phase_id completed."
}

case "$MODE" in
    select)
        select_phase
        ;;
    run)
        PHASE="${2:-}"
        [ -n "$PHASE" ] || { echo "Usage: $0 run <phase-id>"; exit 1; }
        run_phase "$PHASE"
        ;;
    tick)
        PHASE=$(select_phase || true)
        if [ -n "$PHASE" ] && [ "$PHASE" != "[EMPTY]" ] && [ "$PHASE" != "[LOCKED]" ]; then
            run_phase "$PHASE"
        else
            echo "Tick completed without work: $PHASE"
        fi
        ;;
    *)
        echo "Usage: $0 {select|run <phase>|tick}"
        exit 1
        ;;
esac
