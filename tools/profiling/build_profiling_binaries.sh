#!/usr/bin/env bash
# Build all profiling pipeline binaries.
# Temporarily injects -DHINT_PROFILING into global.options during build,
# then restores the original. No permanent change to ChampSim build config.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

OPTIONS_FILE="$ROOT/global.options"
BACKUP="$ROOT/global.options.bak"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Inject HINT_PROFILING flag temporarily
cp "$OPTIONS_FILE" "$BACKUP"
echo "-DHINT_PROFILING" >> "$OPTIONS_FILE"
log "Injected -DHINT_PROFILING for profiling build"

# Clean old profiling binaries, then build
rm -f bin/champsim_*_d*

CFG_DIR="$ROOT/tools/profiling/configs"
total=$(ls "$CFG_DIR"/champsim_*_d*.json 2>/dev/null | wc -l || true)
i=0
for cfg in "$CFG_DIR"/champsim_*_d*.json; do
    [ -f "$cfg" ] || continue
    name=$(basename "$cfg" .json)
    ((i++))
    log "BUILD [$i/$total] $name..."
    ./config.sh "$cfg" > /dev/null 2>&1 || true
    make -j$(nproc) > /dev/null 2>&1 || true
    if [ -x "bin/$name" ]; then
        log "  DONE"
    else
        log "  FAILED"
    fi
done

# Restore original
mv "$BACKUP" "$OPTIONS_FILE"
log "Restored global.options, built $(ls bin/champsim_*_d* 2>/dev/null | wc -l || true) binaries"
