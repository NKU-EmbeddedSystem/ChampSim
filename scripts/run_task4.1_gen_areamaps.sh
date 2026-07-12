#!/bin/bash
# Task 4.1: Generate area_map files for 7 DRAM ratios × 2 placements
#   DRAM ratios: 0%, 10%, 30%, 50%, 70%, 90%, 100%
#   Placements:  random, first_touch
# Usage:
#   bash scripts/run_task4.1_gen_areamaps.sh <trace1.xz> <trace2.xz> ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
TOOL="$STAGE_DIR/build/bin/tools/gen_area_map"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task4.1-dram-ratio"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task4.1-dram-ratio/area_maps/$RUN_TS"

# Configurable
MAX_PARALLEL="${TASK4_1_PARALLEL:-8}"
# Full instruction window: warmup(50M) + sim(1000M) = 1050M
# This ensures the area_map covers ALL pages accessed during simulation.
# If a page is NOT in the area_map, MemoryMapper defaults it to area=1 (CXL),
# which would distort results for pages accessed late in the trace.
# Reduce via env var for faster but less complete coverage:
#   TASK4_1_MAX_INSTR=200000000 bash run_task4.1_gen_areamaps.sh ...
MAX_INSTR="${TASK4_1_MAX_INSTR:-1050000000}"

# 7 DRAM ratios for Task 4.1
# Format: "label fraction"
RATIOS=(
  "000 0.00"
  "010 0.10"
  "030 0.30"
  "050 0.50"
  "070 0.70"
  "090 0.90"
  "100 1.00"
)

PLACEMENTS=(random)

if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo ""
  echo "  Generate area_map files for Task 4.1 (7 DRAM ratios × 2 placements)."
  echo "  Each trace is first scanned to count distinct pages, then 14 area_maps"
  echo "  are generated per trace with the correct --dram_pages for each ratio."
  echo ""
  echo "  DRAM ratios: 0% 10% 30% 50% 70% 90% 100%"
  echo "  Placements:  random first_touch"
  echo ""
  echo "  Environment variables:"
  echo "    TASK4_1_PARALLEL   Max parallel jobs (default: 8)"
  echo "    TASK4_1_MAX_INSTR  Instruction window (default: 150000000)"
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
# Derive benchmark name from trace path
# ------------------------------------------------------------------
benchmark_name() {
  local fname
  fname="$(basename "$1")"
  fname="${fname%.champsimtrace.xz}"
  fname="${fname%.champsim.trace.xz}"
  fname="${fname%.trace.xz}"
  fname="${fname%.xz}"
  echo "$fname"
}

# ------------------------------------------------------------------
# Phase 1: Discover total distinct pages for each trace
# ------------------------------------------------------------------
echo "=== Phase 1: Discovering distinct pages per trace ==="
declare -A TRACE_PAGES

for trace in "${TRACES[@]}"; do
  bname="$(benchmark_name "$trace")"
  ref_amap="$RUN_DIR/_ref_${bname}.amap"

  echo -n "  $bname ... "

  if [ -f "$ref_amap" ] && [ -s "$ref_amap" ]; then
    echo "  (reference already exists, reusing)"
  else
    "$TOOL" \
      --trace="$trace" \
      --output="$ref_amap" \
      --placement=random \
      --max_instructions="$MAX_INSTR" \
      > "$RUN_DIR/_ref_${bname}.raw" 2>&1
  fi

  if [ -f "$ref_amap" ] && [ -s "$ref_amap" ]; then
    total=$(python3 -c "
import struct
with open('$ref_amap', 'rb') as f:
    data = f.read(16)
    if len(data) < 16:
        print(0)
    else:
        magic, version, entries = struct.unpack('<IIQ', data)
        print(entries)
")
    TRACE_PAGES["$bname"]=$total
    echo "${total} distinct pages"
  else
    echo "FAILED — cannot compute total pages"
    TRACE_PAGES["$bname"]=0
  fi
done

# ------------------------------------------------------------------
# Compute total tasks
# ------------------------------------------------------------------
N_TOTAL=0
for trace in "${TRACES[@]}"; do
  bname="$(benchmark_name "$trace")"
  if [ "${TRACE_PAGES[$bname]}" -gt 0 ]; then
    N_TOTAL=$((N_TOTAL + ${#RATIOS[@]} * ${#PLACEMENTS[@]}))
  fi
done

echo ""
echo "=== Phase 2: Generating $N_TOTAL area_maps ==="

# ------------------------------------------------------------------
# Control plane
# ------------------------------------------------------------------
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task4.1-gen-areamaps  tasks=$N_TOTAL
  run=$RUN_TS  max_instr=$MAX_INSTR  placements=${PLACEMENTS[*]}
  ratios=$(printf '%s ' "${RATIOS[@]}")
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 4.1: Generate area_map files (DRAM Ratio Sensitivity)
  Ratios:     $(printf '%s ' "${RATIOS[@]}")
  Placements: ${PLACEMENTS[*]}
  Traces:     ${#TRACES[@]}
  Max instr:  $MAX_INSTR
  Workers:    $MAX_PARALLEL
  Started:    $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:    $RUN_DIR
  Plan:       $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

EOF

# ------------------------------------------------------------------
# Phase 2: Dispatch all ratio × placement combinations
# ------------------------------------------------------------------
running=0; task_idx=0

for trace in "${TRACES[@]}"; do
  bname="$(benchmark_name "$trace")"
  total_pages="${TRACE_PAGES[$bname]}"

  if [ "$total_pages" -le 0 ]; then
    echo "SKIP $bname: total_pages=$total_pages" >> "$RUN_DIR/main.log"
    continue
  fi

  for ratio_entry in "${RATIOS[@]}"; do
    ratio_label="${ratio_entry%% *}"
    ratio_frac="${ratio_entry##* }"

    # Compute dram_pages = floor(ratio * total_pages)
    if [ "$ratio_frac" = "1.00" ]; then
      dram_pages="$total_pages"
    elif [ "$ratio_frac" = "0.00" ]; then
      dram_pages=0
    else
      dram_pages=$(python3 -c "import math; print(int(math.floor($total_pages * $ratio_frac)))")
    fi

    for placement in "${PLACEMENTS[@]}"; do
      task_idx=$((task_idx + 1))
      amap="$RUN_DIR/${bname}_${placement}_ratio${ratio_label}.amap"
      name="${bname}_${placement}_ratio${ratio_label}"
      ratio_pct="${ratio_label}%"

      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$task_idx/$N_TOTAL] name=$name  dram_pages=$dram_pages/$total_pages" >> "$RUN_DIR/execution.log"
      echo "── ${name} (dram_pages=$dram_pages/$total_pages) ──" >> "$RUN_DIR/main.log"

      if [ -f "$amap" ] && [ -s "$amap" ]; then
        nbytes=$(stat --printf='%s' "$amap" 2>/dev/null || echo 0)
        echo "  → Already exists ($nbytes bytes), skipping" >> "$RUN_DIR/main.log"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=0  map_bytes=$nbytes  result=cached" >> "$RUN_DIR/execution.log"
        continue
      fi

      (
        t0=$(date +%s%3N)
        "$TOOL" \
          --trace="$trace" \
          --output="$amap" \
          --placement="$placement" \
          --dram_pages="$dram_pages" \
          --max_instructions="$MAX_INSTR" \
          > "$RUN_DIR/${name}.raw" 2>&1
        rc=$?; t1=$(date +%s%3N); elapsed=$((t1 - t0))

        if [ $rc -eq 0 ] && [ -s "$amap" ]; then
          nbytes=$(stat --printf='%s' "$amap" 2>/dev/null || echo 0)
          magic_ok=0
          [ "$(xxd -l 4 -p "$amap" 2>/dev/null)" = "41455241" ] && magic_ok=1

          # Verify dram_pages count in output
          actual_dram=0
          if [ "$magic_ok" -eq 1 ]; then
            actual_dram=$(python3 -c "
import struct
with open('$amap', 'rb') as f:
    magic, version, entries = struct.unpack('<IIQ', f.read(16))
    dram = 0
    for _ in range(entries):
        rec = f.read(9)
        if len(rec) == 9:
            dram += (rec[8] == 0)
    print(dram)
" 2>/dev/null)
          fi

          echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  bytes=$nbytes  dram_pages=$actual_dram/$total_pages" > "$RUN_DIR/${name}.sub.log"
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  map_bytes=$nbytes  dram_actual=$actual_dram  dram_expect=$dram_pages" >> "$RUN_DIR/execution.log"
        else
          echo "[$(date '+%H:%M:%S')] FAILED  exit=$rc  elapsed=${elapsed}ms" > "$RUN_DIR/${name}.sub.log"
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=$rc  elapsed_ms=$elapsed  result=failed" >> "$RUN_DIR/execution.log"
        fi
      ) &

      running=$((running + 1))
      if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running - 1)); fi
    done
  done
done
wait

# ------------------------------------------------------------------
# Clean up reference files
# ------------------------------------------------------------------
rm -f "$RUN_DIR"/_ref_*.amap "$RUN_DIR"/_ref_*.raw

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

echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.1-gen-areamaps  pass=$pass  fail=$fail" >> "$RUN_DIR/execution.log"

# Symlinks
ln -sfn "$RUN_TS" "$(dirname "$RUN_DIR")/latest"

echo "" && cat "$RUN_DIR/main.log"
echo "Done. pass=$pass fail=$fail"
echo "Area maps: $RUN_DIR"
