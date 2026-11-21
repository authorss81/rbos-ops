#!/usr/bin/env bash
# =============================================================================
# ops-core/dispatch.sh — Production Autonomous Dispatcher & Multi-Round Review Loop
# Inherited from authorss81/rbops, adapted for single-target delta testing & multi-worker leases.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGES_REPO="${PACKAGES_REPO:-$OPS_ROOT/../packages}"
LOG_DIR="$OPS_ROOT/logs"
PHASES_DIR="$OPS_ROOT/phases"
mkdir -p "$LOG_DIR" "$PHASES_DIR"

MODE="${1:-tick}"
WORKER_ID="${WORKER_ID:-worker-1}"

# Model Chains (Ranked fallback list)
IMPL_MODELS="${OPENCODE_IMPL_MODELS:-opencode/deepseek-v4.1-flash-free,opencode/big-pickle,opencode/glm-5.3-flash-free,opencode/tidepool-alpha-free}"
REVIEW_MODELS="${OPENCODE_REVIEW_MODELS:-opencode/deepseek-v4.1-flash-free,opencode/big-pickle,opencode/tidepool-alpha-free}"

log() {
    printf '[%s][%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$WORKER_ID" "$*" >&2
}

toolchain_ok() {
    command -v opencode >/dev/null 2>&1 || { log "opencode CLI not on PATH"; return 3; }
    [ -n "${OPENCODE_API_KEY:-}" ] || [ -n "${OPENCODE_KEY_1:-}" ] || { log "OPENCODE_API_KEY is not set"; return 3; }
    return 0
}

tree_fingerprint() {
    git -C "$PACKAGES_REPO" rev-parse HEAD 2>/dev/null || echo "empty"
}

# -----------------------------------------------------------------------------
# Agent Invocation with Fallback Chains (Mirroring rbops/dispatch.sh)
# -----------------------------------------------------------------------------
run_agent() {
    local models="$1"
    local logfile="$2"
    local msg="$3"
    shift 3

    local role="${RBOPS_AGENT_ROLE:-build}"
    local code=1

    for m in $(echo "$models" | tr ',' ' '); do
        m="$(echo "$m" | tr -d ' \r')"
        [ -n "$m" ] || continue
        log "invoking model → $m (role: $role)"
        
        pre=$(wc -c < "$logfile" 2>/dev/null || echo 0)
        start_time=$(date +%s)
        
        if [ -n "$msg" ]; then
            timeout "${MODEL_TIMEOUT:-1800}" opencode run --model "$m" "$@" "$msg" >>"$logfile" 2>&1 || code=$?
        else
            timeout "${MODEL_TIMEOUT:-1800}" opencode run --model "$m" "$@" >>"$logfile" 2>&1 || code=$?
        fi
        
        # If model exited successfully and logged output, accept
        post=$(wc -c < "$logfile" 2>/dev/null || echo 0)
        growth=$((post - pre))
        
        if [ "$code" -eq 0 ] && [ "$growth" -ge 100 ]; then
            log "model $m completed turn successfully."
            return 0
        else
            log "model $m exited with code $code (growth: $growth bytes). Falling back to next model..."
        fi
    done

    log "ERROR: all models in chain exhausted."
    return 1
}

# -----------------------------------------------------------------------------
# Phase Queue Selection
# -----------------------------------------------------------------------------
select_phase() {
    local phases_file="$OPS_ROOT/phases.json"
    if [ ! -f "$phases_file" ]; then
        log "phases.json missing"
        return 1
    fi

    local locked
    locked=$(jq -r '.locked // false' "$phases_file")
    if [ "$locked" = "true" ]; then
        log "Pre-126 staging lock is active. No phases eligible."
        return 2
    fi

    local next_phase
    next_phase=$(jq -r '.phases[] | select(.status == "pending") | .id' "$phases_file" | head -n 1)
    if [ -z "$next_phase" ]; then
        log "Queue is empty (pending == 0)."
        return 3
    fi

    echo "$next_phase"
}

# -----------------------------------------------------------------------------
# Implementation & Multi-Round Review/Fix Loop
# -----------------------------------------------------------------------------
run_phase() {
    local phase_id="$1"
    log "=== Starting Phase $phase_id ==="

    local pkg_name
    pkg_name=$(jq -r ".phases[] | select(.id == \"$phase_id\") | .package // .app // \"$phase_id\"" "$OPS_ROOT/phases.json")
    local phase_title
    phase_title=$(jq -r ".phases[] | select(.id == \"$phase_id\") | .title // \"Implementation\"" "$OPS_ROOT/phases.json")

    local phase_log="$LOG_DIR/$phase_id.log"
    : > "$phase_log"

    # --- Round 0: Build / Synthesis ---
    log "[STEP 1/3] Synthesizing $pkg_name: $phase_title"
    local prompt_msg="Implement Redblue package '$pkg_name': $phase_title.
Rules:
1. Pure Redblue plain-English syntax (.rb) in packages/$pkg_name/src/.
2. Thorough assertions in packages/$pkg_name/tests/run.rb.
3. No C/Rust FFI shims, placeholders, or empty stubs.
4. Valid rb.toml manifest with concept_id."

    if toolchain_ok; then
        RBOPS_AGENT_ROLE=build run_agent "$IMPL_MODELS" "$phase_log" "$prompt_msg" --dir "$PACKAGES_REPO" || {
            log "Synthesis encountered an error. Proceeding to gate..."
        }
    else
        log "[DRY-RUN] Toolchain in standby mode. Skipping live LLM call."
    fi

    # --- Initial Verification Gate ---
    log "[STEP 2/3] Running initial verification gate..."
    if ! "$SCRIPT_DIR/verify.sh" "$pkg_name" "$PACKAGES_REPO"; then
        log "Initial gate failed. Entering 3-Round Review & Fix loop..."
    fi

    # --- Rounds 1..3: Review & Automated Fix Loop ---
    local max_rounds=3
    local round=1
    local converged=0

    while [ "$round" -le "$max_rounds" ]; do
        log "[REVIEW ROUND $round/$max_rounds] Evaluating $pkg_name..."
        local rlog="$LOG_DIR/$phase_id.review.$round.log"
        : > "$rlog"

        local review_req="Review Redblue package '$pkg_name' against invariants:
1. Pure Redblue syntax without un-audited shims?
2. Deterministic assertions covering nominal and error cases?
3. No TODOs or placeholder code?
State VERDICT: CLEAN or list findings with [BLOCKER], [MAJOR], [MINOR]."

        if toolchain_ok; then
            RBOPS_AGENT_ROLE=review run_agent "$REVIEW_MODELS" "$rlog" "$review_req" --dir "$PACKAGES_REPO" || true
        fi

        # Check for clean verdict or gate pass
        if grep -q "VERDICT: CLEAN" "$rlog" 2>/dev/null || "$SCRIPT_DIR/verify.sh" "$pkg_name" "$PACKAGES_REPO"; then
            log "[REVIEW ROUND $round] Clean verification gate passed!"
            converged=1
            break
        fi

        # Fix Round
        log "[FIX ROUND $round/$max_rounds] Attempting automated remediation..."
        local fix_msg="Fix review findings for package '$pkg_name':
$(cat "$rlog" 2>/dev/null | tail -n 50)
Fix the errors and ensure tests/run.rb passes cleanly."

        if toolchain_ok; then
            RBOPS_AGENT_ROLE=build run_agent "$IMPL_MODELS" "$phase_log" "$fix_msg" --dir "$PACKAGES_REPO" || true
        fi

        round=$((round + 1))
    done

    # --- Step 3: Final Gate Verification ---
    log "[STEP 3/3] Final Gate Verification"
    if "$SCRIPT_DIR/verify.sh" "$pkg_name" "$PACKAGES_REPO"; then
        log "SUCCESS: Phase $phase_id passed all review and verification gates!"
        # Mark phase completed in phases.json
        local tmp_json="$OPS_ROOT/phases.tmp.json"
        jq "(.phases[] | select(.id == \"$phase_id\")).status = \"completed\"" "$OPS_ROOT/phases.json" > "$tmp_json" && mv "$tmp_json" "$OPS_ROOT/phases.json"
        return 0
    else
        log "FAILURE: Phase $phase_id failed to converge after $max_rounds rounds."
        return 1
    fi
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
        if [ -n "$PHASE" ] && [ "$PHASE" != "Pre-126 staging lock is active. No phases eligible." ] && [ "$PHASE" != "Queue is empty (pending == 0)." ]; then
            run_phase "$PHASE"
        else
            log "Tick completed cleanly without work: $PHASE"
        fi
        ;;
    *)
        echo "Usage: $0 {select|run <phase>|tick}"
        exit 1
        ;;
esac
