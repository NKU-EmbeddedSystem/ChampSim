#!/usr/bin/env bash
#
# setup.sh — General environment preparation for the Profiling Pipeline
#
# Handles:
#   Step C: Download & install Intel PIN
#   Step D: Build ChampSim PIN tracer
#   Step E: Build ChampSim (profiling config)
#
# For benchmark-specific setup (e.g. compiling SPEC), see tools/benchmarks/
#
# Usage:
#   ./setup.sh                    # run all steps
#   ./setup.sh --step C           # run specific step
#   ./setup.sh --dry-run          # preview without executing
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

log()  { echo "[setup $(date '+%H:%M:%S')] $*"; }
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
# Step C: Download & install Intel PIN
# ═══════════════════════════════════════════════════════════════════════════════
step_c() {
    should_run C || return 0
    log "=== Step C: Install Intel PIN ==="

    if [ -x "$PIN_ROOT/pin" ]; then
        log "PIN already installed at $PIN_ROOT"
        return 0
    fi

    local tarball="$HOME/pin-${PIN_VERSION}.tar.gz"
    if [ ! -f "$tarball" ]; then
        log "Downloading PIN ${PIN_VERSION} ..."
        run wget "$PIN_URL" -O "$tarball"
    fi

    log "Extracting PIN ..."
    run tar zxf "$tarball" -C "$HOME/"

    if [ ! -x "$PIN_ROOT/pin" ]; then
        log "ERROR: PIN extraction failed"
        exit 1
    fi

    log "Building PIN tools infrastructure ..."
    if [ -d "$PIN_ROOT/source/tools" ]; then
        run make -j$(nproc) -C "$PIN_ROOT/source/tools"
    fi

    log "PIN installed: $PIN_ROOT"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step D: Build ChampSim PIN tracer
# ═══════════════════════════════════════════════════════════════════════════════
step_d() {
    should_run D || return 0
    log "=== Step D: Build ChampSim tracer ==="

    if [ -f "$PIN_TRACER" ]; then
        log "Tracer already built: $PIN_TRACER"
        return 0
    fi

    if [ ! -x "$PIN_ROOT/pin" ]; then
        log "PIN not found. Run Step C first."
        exit 1
    fi

    local tracer_dir="$CHAMPSIM_ROOT/tracer/pin"
    run make -C "$tracer_dir" clean
    run PIN_ROOT="$PIN_ROOT" make -C "$tracer_dir"

    log "Tracer built: $PIN_TRACER"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Step E: Build ChampSim (profiling config)
# ═══════════════════════════════════════════════════════════════════════════════
step_e() {
    should_run E || return 0
    log "=== Step E: Build ChampSim ==="

    if [ -f "$CHAMPSIM_BIN" ]; then
        log "ChampSim already built: $CHAMPSIM_BIN"
        return 0
    fi

    if [ ! -f "$CHAMPSIM_CONFIG" ]; then
        log "ERROR: Config not found: $CHAMPSIM_CONFIG"
        exit 1
    fi

    run cd "$CHAMPSIM_ROOT" && ./config.sh "$CHAMPSIM_CONFIG" && make -j$(nproc)
    log "ChampSim built: $CHAMPSIM_BIN"
}

# ═══════════════════════════════════════════════════════════════════════════════

log "Setup start: step=$STEP"
step_c
step_d
step_e

log "Setup complete."
echo ""
echo "Toolchain status:"
[ -x "$PIN_ROOT/pin" ]                                 && echo "  [✓] Intel PIN"  || echo "  [ ] Intel PIN"
[ -f "$PIN_TRACER" ]                                   && echo "  [✓] PIN tracer" || echo "  [ ] PIN tracer"
[ -f "$CHAMPSIM_BIN" ]                                 && echo "  [✓] ChampSim"   || echo "  [ ] ChampSim"
