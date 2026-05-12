#!/usr/bin/env bash
# Batch disassembly for CPU2017 benchmarks
# Usage: ./batch_disasm_cpu2017.sh [--jobs N]

set -euo pipefail

CPU2017_ROOT="${CPU2017_ROOT:-$HOME/cpu2017}"
PIPELINE_DATA="${PIPELINE_DATA:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/data}"
PARSE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/parse_disassembly.py"
JOBS="${1:-$(( $(nproc) / 2 ))}"
[[ "$JOBS" =~ ^[0-9]+$ ]] || JOBS=4

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Build exe name mapping from object.pm files
declare -A EXE_NAMES
while IFS= read -r bench_dir; do
    bname=$(basename "$bench_dir")
    exe=$(grep "exename" "$bench_dir/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
    [ -n "$exe" ] && EXE_NAMES["$bname"]="$exe"
done < <(find "$CPU2017_ROOT/benchspec/CPU" -maxdepth 1 -type d -name "*_*" 2>/dev/null | sort)

log "Found ${#EXE_NAMES[@]} benchmarks"

running=0

for bname in "${!EXE_NAMES[@]}"; do
    exe="${EXE_NAMES[$bname]}"

    # Find build directory
    build_dir=$(find "$CPU2017_ROOT/benchspec/CPU/$bname/build" -maxdepth 2 -type d -name "build_base_*" 2>/dev/null | head -1)
    [ -z "$build_dir" ] && continue

    binary="$build_dir/$exe"
    [ ! -f "$binary" ] && binary=$(find "$build_dir" -type f -executable -name "$exe*" 2>/dev/null | head -1)
    [ ! -f "$binary" ] && continue

    out_dir="$PIPELINE_DATA/$bname"
    out_file="$out_dir/disasm_index.json"
    [ -f "$out_file" ] && { log "[SKIP] $bname — already done"; continue; }

    # Concurrency control
    while [ "$running" -ge "$JOBS" ]; do
        wait -n 2>/dev/null || true
        ((running--)) || true
    done

    log "[START] $bname ($binary)"
    mkdir -p "$out_dir"
    python3 "$PARSE_SCRIPT" --binary "$binary" --output "$out_file" &
    ((running++))
done

# Wait for remaining jobs
wait
log "Batch disassembly complete."
