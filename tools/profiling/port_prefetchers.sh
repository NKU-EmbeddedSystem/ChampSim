#!/usr/bin/env bash
# Port Pythia prefetchers into our ChampSim module structure.
# Usage: ./port_prefetchers.sh
set -euo pipefail

PYTHIA_ROOT="/tmp/Pythia"
CHAMPSIM_ROOT="/data/home/liz/coordinate_proj/ChampSim"
PREFETCHER_DIR="$CHAMPSIM_ROOT/prefetcher"

# List of prefetchers to port (Pythia name)
PREFETCHERS=(stride streamer ampm sms sandbox bingo dspatch mlop scooby pref_power7 ppf_dev)

log() { echo "[$(date '+%H:%M:%S')] $*"; }

for name in "${PREFETCHERS[@]}"; do
  pythia_cc="$PYTHIA_ROOT/prefetcher/${name}.cc"
  pythia_h="$PYTHIA_ROOT/inc/${name}.h"
  [ ! -f "$pythia_cc" ] && { log "SKIP $name: no .cc"; continue; }

  out_dir="$PREFETCHER_DIR/$name"
  mkdir -p "$out_dir"

  # ── Step 1: Copy and adapt the Pythia header ─────────────────────
  if [ -f "$pythia_h" ]; then
    # Read the original header, transform it
    cat "$pythia_h" | \
      sed 's|#include "prefetcher.h"|#include "pythia_adapter.h"\n#include "pythia_compat.h"|' | \
      sed 's|#include "champsim.h"|#include "pythia_compat.h"|' | \
      sed 's|class \([A-Za-z]*\)Prefetcher : public Prefetcher|struct \1 : public pythia::PrefetcherAdapter|' | \
      sed 's|class \([A-Za-z]*\) : public Prefetcher|struct \1 : public pythia::PrefetcherAdapter|' | \
      sed 's|public Prefetcher|public pythia::PrefetcherAdapter|' | \
      sed 's|using namespace std;||' | \
      sed 's|~\([A-Za-z]*\)Prefetcher();|~\\1() = default;|' | \
      sed 's|~\([A-Za-z]*\)();|~\\1() = default;|' | \
      sed 's|void invoke_prefetcher|void invoke_prefetcher override|' | \
      sed 's|void register_fill|void register_fill override|' | \
      sed 's|void dump_stats|void dump_stats override|' | \
      sed 's|void print_config|void print_config override|' \
      > "$out_dir/${name}.h"
    log "  $name: header adapted"
  else
    log "  $name: no header, will inline"
  fi

  # ── Step 2: Copy the .cc and adjust includes ────────────────────
  # Replace Pythia-specific includes, keep everything else
  cat "$pythia_cc" | \
    sed 's|#include "champsim.h"|#include "pythia_compat.h"|' | \
    sed 's|#include "cache.h"|#include "pythia_compat.h"|' | \
    sed 's|#include "prefetcher.h"|#include "pythia_adapter.h"|' | \
    sed "s|#include \"${name}.h\"|#include \"${name}.h\"\n#include \"pythia_adapter.h\"|" | \
    sed "s|\([A-Za-z]*\)Prefetcher::|${name}::|g" | \
    sed "s|\([A-Za-z]*\)::\1|${name}::${name}|g" \
    > "$out_dir/${name}.cc"

  # Fix constructor names
  sed -i "s|^\([A-Za-z]*\)Prefetcher::|\1::|g" "$out_dir/${name}.cc" 2>/dev/null || true

  log "  $name: done"
done

log "=== Done porting ${#PREFETCHERS[@]} prefetchers ==="
log "Next: create profiling configs and compile"
