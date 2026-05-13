#!/usr/bin/env bash
#
# setup.sh — SPEC CPU2017 environment preparation
#
# Step A: Generate SPEC config for modern gcc/glibc
# Step B: Setup ref inputs + compile benchmarks
#
# Usage:
#   ./setup.sh                    # run all steps
#   ./setup.sh --step A           # run specific step
#   ./setup.sh --dry-run          # preview without executing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

STEP="all"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --step) STEP="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

log()  { echo "[spec2017-setup $(date '+%H:%M:%S')] $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        log "Running: $*"
        eval "$@"
    fi
}
should_run() { [ "$STEP" = "all" ] || [ "$STEP" = "$1" ]; }

# Step A: Generate SPEC config
step_a() {
    should_run A || return 0
    log "=== Step A: Generate SPEC2017 config ==="

    local spec_config_path="$SPEC2017_ROOT/config/$SPEC2017_CONFIG"
    if [ -f "$spec_config_path" ]; then
        log "Config already exists: $spec_config_path"
        return 0
    fi

    local template="$SPEC2017_ROOT/config/Example-gcc-linux-x86.cfg"
    if [ ! -f "$template" ]; then
        log "ERROR: Template config not found at $template"
        exit 1
    fi

    run cp "$template" "$spec_config_path"

    # Add -no-pie for fixed load address (PC consistency with objdump)
    run sed -i 's/^OPTIMIZE[[:space:]]*=[[:space:]]*\(.*\)$/OPTIMIZE    = \1 -no-pie -fcommon/' "$spec_config_path"
    run sed -i '/^OPTIMIZE/a FOPTIMIZE    = $(OPTIMIZE)' "$spec_config_path"
    run sed -i '/^OPTIMIZE/a CXXOPTIMIZE  = $(OPTIMIZE)' "$spec_config_path"
    run sed -i '/^OPTIMIZE/a COPTIMIZE    = $(OPTIMIZE)' "$spec_config_path"

    log "Config generated: $spec_config_path"
}

# Step B: Compile benchmarks
step_b() {
    should_run B || return 0
    log "=== Step B: Setup + Compile SPEC2017 benchmarks (ref) ==="

    if [ ! -f "$SPEC2017_ROOT/bin/runcpu" ]; then
        log "ERROR: SPEC CPU2017 not found at $SPEC2017_ROOT"
        exit 1
    fi

    step_a

    local failed=()
    for bench in "${SPEC2017_BENCHMARKS[@]}"; do
        local exe_name=$(grep "exename" "$SPEC2017_ROOT/benchspec/CPU/$bench/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
        [ -z "$exe_name" ] && exe_name=$(echo "$bench" | sed 's/^[0-9]*\.//')

        if find "$SPEC2017_ROOT/benchspec/CPU/$bench/build" -name "$exe_name" -type f -executable 2>/dev/null | grep -q .; then
            log "  $bench: already compiled, skipping"
            continue
        fi

        log "  Building $bench (ref) ..."
        if run "cd $SPEC2017_ROOT && . ./shrc 2>/dev/null && runcpu --action=setup --size=ref --config=$SPEC2017_CONFIG --tune=base $bench 2>/dev/null && runcpu --action=build --config=$SPEC2017_CONFIG --tune=base $bench 2>&1 | grep -E 'Build (success|error|Complete)'"; then
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

log "SPEC2017 setup start: step=$STEP"
step_a
step_b

log "SPEC2017 setup complete."
