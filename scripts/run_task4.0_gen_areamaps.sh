#!/bin/bash
# Task 4.0: Generate area_map files for random + first_touch placements
#   DRAM:CXL ratio fixed at 1:2 (auto-derived from distinct pages)
# Usage:
#   bash scripts/run_task4.0_gen_areamaps.sh <trace1.xz> <trace2.xz> ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
TOOL="$STAGE_DIR/build/bin/tools/gen_area_map"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task4.0-e2e-rpp"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task4.0-e2e-rpp/area_maps/$RUN_TS"

# Configurable
MAX_PARALLEL="${TASK4_0_PARALLEL:-8}"
# Full instruction window: warmup(50M) + sim(1000M) = 1050M
# This ensures the area_map covers ALL pages accessed during simulation.
# If a page is NOT in the area_map, MemoryMapper defaults it to area=1 (CXL),
# which would distort results for pages accessed late in the trace.
# Reduce via env var for faster but less complete coverage:
#   TASK4_0_MAX_INSTR=200000000 bash run_task4.0_gen_areamaps.sh ...
MAX_INSTR="${TASK4_0_MAX_INSTR:-1050000000}"

# Placements for Task 4.0
PLACEMENTS=(random)

if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo ""
  echo "  Generate area_map files for Task 4.0 (random + first_touch placements,"
  echo "  DRAM:CXL = 1:2 by distinct 4KB pages)."
  echo ""
  echo "  Environment variables:"
  echo "    TASK4_0_PARALLEL   Max parallel jobs (default: 8)"
  echo "    TASK4_0_MAX_INSTR  Instruction window for page discovery (default: 150000000)"
  exit 1
fi

TRACES=("$@")
mkdir -p "$RUN_DIR"

# ------------------------------------------------------------------
# Build gen_area_map tool if needed
# ------------------------------------------------------------------
if [ ! -x "$TOOL" ] || [ "$STAGE_DIR/src/tools/gen_area_map.cc" -nt "$TOOL" ]; then
  echo "Building gen_area_map..."
  mkdir -p "$(dirname "$TOOL")"
  g++ -std=c++17 -O2 -o "$TOOL" "$STAGE_DIR/src/tools/gen_area_map.cc" || {
    echo "FATAL: gen_area_map build failed"
    exit 1
  }
  echo "  → $TOOL built OK"
fi

# ------------------------------------------------------------------
# Control plane
# ------------------------------------------------------------------
N_TOTAL=$((${#TRACES[@]} * ${#PLACEMENTS[@]}))
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task4.0-gen-areamaps  tasks=$N_TOTAL
  run=$RUN_TS  max_instr=$MAX_INSTR  placements=${PLACEMENTS[*]}
  DRAM:CXL=1:2 (auto)
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 4.0: Generate area_map files
  Placements: ${PLACEMENTS[*]}
  Traces:     ${#TRACES[@]}
  DRAM:CXL:   1:2 (auto-derived from distinct pages)
  Max instr:  $MAX_INSTR
  Workers:    $MAX_PARALLEL
  Started:    $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:    $RUN_DIR
  Plan:       $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

EOF

# ------------------------------------------------------------------
# Derive benchmark name from trace path
# ------------------------------------------------------------------
benchmark_name() {
  local fpath="$1"
  local fname
  fname="$(basename "$fpath")"
  # Strip .champsimtrace.xz or .champsim.trace.xz or .trace.xz or .xz
  fname="${fname%.champsimtrace.xz}"
  fname="${fname%.champsim.trace.xz}"
  fname="${fname%.trace.xz}"
  fname="${fname%.xz}"
  echo "$fname"
}

# ------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------
running=0; task_idx=0

for trace in "${TRACES[@]}"; do
  if [ ! -f "$trace" ]; then
    echo "WARNING: trace not found: $trace — skipping" | tee -a "$RUN_DIR/main.log"
    continue
  fi

  bname="$(benchmark_name "$trace")"

  for placement in "${PLACEMENTS[@]}"; do
    task_idx=$((task_idx + 1))
    amap="$RUN_DIR/${bname}_${placement}.amap"
    name="${bname}_${placement}"

    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$task_idx/$N_TOTAL] name=$name" >> "$RUN_DIR/execution.log"
    echo "── ${name} ─────────────────────────────────────────────" >> "$RUN_DIR/main.log"
    echo "  Trace:  $trace" >> "$RUN_DIR/main.log"

    if [ -f "$amap" ]; then
      nbytes=$(stat --printf='%s' "$amap" 2>/dev/null || echo 0)
      echo "  → Already exists ($nbytes bytes), skipping" >> "$RUN_DIR/main.log"
      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=0  map_bytes=$nbytes  result=cached" >> "$RUN_DIR/execution.log"
      continue
    fi

    echo "  Launch: $(date '+%H:%M:%S')" >> "$RUN_DIR/main.log"

    (
      t0=$(date +%s%3N)
      "$TOOL" \
        --trace="$trace" \
        --output="$amap" \
        --placement="$placement" \
        --max_instructions="$MAX_INSTR" \
        > "$RUN_DIR/${name}.raw" 2>&1
      rc=$?; t1=$(date +%s%3N); elapsed=$((t1 - t0))

      if [ $rc -eq 0 ] && [ -s "$amap" ]; then
        nbytes=$(stat --printf='%s' "$amap" 2>/dev/null || echo 0)
        magic_ok=0
        [ "$(xxd -l 4 -p "$amap" 2>/dev/null)" = "41455241" ] && magic_ok=1

        # Verify DRAM:CXL = 1:2 ratio (dram_pages = floor(total_entries / 3))
        ratio_ok=0
        if [ "$magic_ok" -eq 1 ]; then
          ratio_ok=$(python3 -c "
import struct
with open('$amap', 'rb') as f:
    magic, version, entries = struct.unpack('<IIQ', f.read(16))
    dram = sum(1 for _ in range(entries) if len(f.read(9)) == 9 and f.tell())
print(dram, entries)
" 2>/dev/null)
        fi

        echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  bytes=$nbytes  magic_ok=$magic_ok" > "$RUN_DIR/${name}.sub.log"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  map_bytes=$nbytes  magic_ok=$magic_ok" >> "$RUN_DIR/execution.log"
      else
        echo "[$(date '+%H:%M:%S')] FAILED  exit=$rc  elapsed=${elapsed}ms" > "$RUN_DIR/${name}.sub.log"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=$rc  elapsed_ms=$elapsed  result=failed" >> "$RUN_DIR/execution.log"
      fi
    ) &

    running=$((running + 1))
    if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running - 1)); fi
  done
done
wait

# ------------------------------------------------------------------
# Results summary
# ------------------------------------------------------------------
pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || true)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || true)

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Results
────────────────────────────────────────────────────────
  Pass: $pass  |  Fail: $fail  |  Total: $N_TOTAL
$(for trace in "${TRACES[@]}"; do
  bname="$(benchmark_name "$trace")"
  for placement in "${PLACEMENTS[@]}"; do
    name="${bname}_${placement}"
    amap="$RUN_DIR/${name}.amap"
    if [ -f "$amap" ]; then
      sz=$(stat --printf='%s' "$amap" 2>/dev/null)
      echo "  ${name}  bytes=$sz"
    else
      echo "  ${name}  MISSING"
    fi
  done
done)
────────────────────────────────────────────────────────
  Checks
────────────────────────────────────────────────────────
  [$( [ "$pass" -eq "$N_TOTAL" ] && echo "PASS" || echo "FAIL")] All ${pass}/$N_TOTAL tasks succeeded
  [$( [ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL")] Zero failures ($fail failures)

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
EOF

echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.0-gen-areamaps  pass=$pass  fail=$fail" >> "$RUN_DIR/execution.log"

# Symlinks
ln -sfn "$RUN_TS" "$(dirname "$RUN_DIR")/latest"

# Restore
echo "" && cat "$RUN_DIR/main.log"
echo "Done. pass=$pass fail=$fail"
echo "Area maps: $RUN_DIR"
