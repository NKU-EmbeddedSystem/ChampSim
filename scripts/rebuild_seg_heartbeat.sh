#!/bin/bash
# Rebuild all experiment binaries with -DSTAT_PRINTING_PERIOD=500000LL
# (20 heartbeat segments over a 1e7-instruction sim).
set -uo pipefail
ROOT=/mnt/sdd/liz/pc-split/ChampSim
cd "$ROOT"
GLOBAL_OPTIONS="$ROOT/global.options"
ORIG_OPTIONS="$(cat "$GLOBAL_OPTIONS")"

build_one() {
    local cfg="$1" name="$2" macro="$3" extra="$4"
    printf '%s\n%s\n%s\n' "$ORIG_OPTIONS" "$macro" "$extra" > "$GLOBAL_OPTIONS"
    python3 config.sh "$cfg" > /dev/null 2>&1
    rm -f .csconfig/generated_environment.o
    if make -j"$(nproc)" > "/tmp/segbuild_${name}.log" 2>&1; then
        echo "[OK] $name"
    else
        echo "[FAIL] $name (see /tmp/segbuild_${name}.log)"
    fi
    printf '%s\n' "$ORIG_OPTIONS" > "$GLOBAL_OPTIONS"
}

HB="-DSTAT_PRINTING_PERIOD=${1:-500000}LL"

# bw3200: 13 profile binaries + hint_eval
while IFS='|' read -r cfg name macro; do
    [ -n "$cfg" ] || continue
    build_one "$cfg" "$name" "$macro" "$HB"
done < <(python3 - configs/l1d-profile/manifest.json <<'PYEOF'
import json, sys
for e in json.load(open(sys.argv[1])):
    print("|".join((e["config_path"], e["name"], e.get("degree_macro") or "")))
PYEOF
)
build_one configs/stage1/champsim_config_hint_eval.json champsim_hint_eval "" "$HB"

# bw1600/bw800: all variants (profile + hint_eval); skip bw3200 duplicates
while IFS='|' read -r cfg name macro; do
    [ -n "$cfg" ] || continue
    build_one "$cfg" "$name" "$macro" "$HB"
done < <(python3 - configs/l1d-bw/manifest.json <<'PYEOF'
import json, sys
for e in json.load(open(sys.argv[1])):
    if e.get("bw_level") not in ("bw1600", "bw800"):
        continue
    print("|".join((e["config_path"], e["name"], e.get("degree_macro") or "")))
PYEOF
)
echo REBUILD_DONE
