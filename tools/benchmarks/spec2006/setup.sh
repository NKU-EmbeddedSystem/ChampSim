#!/usr/bin/env bash
#
# setup.sh — SPEC CPU2006 environment preparation
#
# Handles:
#   Step A: Generate SPEC config for modern gcc/glibc
#   Step B: Compile SPEC benchmarks
#
# Usage:
#   ./setup.sh                      # run all steps
#   ./setup.sh --step A             # run specific step
#   ./setup.sh --dry-run            # preview without executing
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"                         # SPEC-specific config
source "$SCRIPT_DIR/../../profiling/config.sh"         # general config (CHAMPSIM_ROOT etc.)

STEP="all"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step) STEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log()  { echo "[spec-setup $(date '+%H:%M:%S')] $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        log "Running: $*"
        eval "$@"
    fi
}
should_run() { [ "$STEP" = "all" ] || [ "$STEP" = "$1" ]; }

# ═══════════════════════════════════════════════════════════════════════════════
# Step A: Generate SPEC config for modern compiler
# ═══════════════════════════════════════════════════════════════════════════════
step_a() {
    should_run A || return 0
    log "=== Step A: Generate SPEC config ==="

    local spec_config_path="$SPEC_ROOT/config/$SPEC_CONFIG"
    if [ -f "$spec_config_path" ]; then
        log "Config already exists: $spec_config_path"
        return 0
    fi

    local template="$SPEC_ROOT/config/Example-linux64-amd64-gcc43.cfg"
    if [ ! -f "$template" ]; then
        log "ERROR: Template config not found at $template"
        exit 1
    fi

    run cp "$template" "$spec_config_path"

    # Add FORTIFY, common, and no-pie flags for modern gcc (8+) and glibc (2.31+)
    # -no-pie ensures the binary loads at a fixed address (0x400000), so runtime
    # PCs from PIN traces match objdump disassembly addresses exactly.
    run sed -i 's/^COPTIMIZE    = .*$/COPTIMIZE    = -O2 -fno-strict-aliasing -fcommon -fgnu89-inline -D_FORTIFY_SOURCE=0 -U_FORTIFY_SOURCE -no-pie/' "$spec_config_path"
    run sed -i 's/^CXXOPTIMIZE  = .*$/CXXOPTIMIZE  = -O2 -fno-strict-aliasing -fcommon -no-pie/' "$spec_config_path"
    run sed -i 's/^FOPTIMIZE    = .*$/FOPTIMIZE    = -O2 -fno-strict-aliasing -fcommon -no-pie/' "$spec_config_path"
    # Add to CPORTABILITY for C benchmarks (preprocessor level)
    run sed -i 's/^CPORTABILITY = -DSPEC_CPU_LINUX_X64$/CPORTABILITY = -DSPEC_CPU_LINUX_X64 -D_FORTIFY_SOURCE=0 -U_FORTIFY_SOURCE/' "$spec_config_path"

    log "Config generated: $spec_config_path"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step B: Compile SPEC benchmarks
# ═══════════════════════════════════════════════════════════════════════════════
step_b() {
    should_run B || return 0
    log "=== Step B: Compile SPEC benchmarks ==="

    if [ ! -f "$SPEC_ROOT/bin/runspec" ]; then
        log "ERROR: SPEC CPU2006 not found at $SPEC_ROOT"
        exit 1
    fi

    # Ensure config exists
    step_a

    local failed=()
    for bench in "${SPEC_BENCHMARKS[@]}"; do
        local exe_name=$(grep "exename" "$SPEC_ROOT/benchspec/CPU2006/$bench/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
        [ -z "$exe_name" ] && exe_name=$(echo "$bench" | sed 's/^[0-9]*\.//')

        # Check if already built
        if find "$SPEC_ROOT/benchspec/CPU2006/$bench/build" -name "$exe_name" -type f -executable 2>/dev/null | grep -q .; then
            log "  $bench: already compiled, skipping"
            continue
        fi

        log "  Building $bench ..."
        if run "cd $SPEC_ROOT && . ./shrc 2>/dev/null && runspec --action=build --config=$SPEC_CONFIG --tune=base $bench 2>&1 | grep -E 'Build (successes|errors|Complete)'"; then
            :
        else
            failed+=("$bench")
        fi
    done

    if [ ${#failed[@]} -gt 0 ]; then
        log "WARNING: ${#failed[@]} benchmarks failed to build: ${failed[*]}"
    else
        log "All benchmarks compiled successfully."
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════

log "SPEC setup start: step=$STEP"
step_a
step_b

log "SPEC setup complete."
echo ""
echo "Status:"
[ -f "$SPEC_ROOT/config/$SPEC_CONFIG" ] && echo "  [✓] SPEC config" || echo "  [ ] SPEC config"
for bench in "${SPEC_BENCHMARKS[@]}"; do
    exe=$(grep "exename" "$SPEC_ROOT/benchspec/CPU2006/$bench/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
    [ -z "$exe" ] && exe=$(echo "$bench" | sed 's/^[0-9]*\.//')
    if find "$SPEC_ROOT/benchspec/CPU2006/$bench/build" -name "$exe" -type f -executable 2>/dev/null | grep -q .; then
        echo "  [✓] $bench"
    else
        echo "  [ ] $bench"
    fi
done
