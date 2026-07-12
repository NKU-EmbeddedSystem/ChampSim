#!/bin/bash
# Task 4.0: E2E RPP Performance — 4-Core Experiment
#   Auto-groups traces into sets of 4, merges area_maps, runs 4-core sims
#   Groups × 2 placements (random, first_touch) × 4 policies
#   Warmup: 50M per core  |  Sim: 1000M per core  |  No prefetch, no migration
# Usage:
#   bash scripts/run_task4.0_e2e_rpp_4core.sh <trace1.xz> <trace2.xz> ... <traceN.xz>
#
#   Traces are automatically grouped into groups of 4 in input order.
#   If the number of traces is not divisible by 4, the last incomplete
#   group is skipped with a warning.
#
#   Or specify groups explicitly via a group file:
#   bash scripts/run_task4.0_e2e_rpp_4core.sh --groups <groups.txt>
#     where groups.txt has one group per line, 4 traces per line.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task4.0-e2e-rpp"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task4.0-e2e-rpp/$RUN_TS"
BIN_DIR="$STAGE_DIR/bin"

# Configurable
MAX_PARALLEL="${TASK4_0_4C_PARALLEL:-4}"
WARMUP="${TASK4_0_WARMUP:-50000000}"
SIM="${TASK4_0_SIM:-1000000000}"

# Fixed
PLACEMENTS=(random)
POLICIES=(lru hawkeye mockingjay rpp)
BRANCH_PRED="bimodal"
PREFETCHERS="no-no-no-no"

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo "       $0 --groups <groups.txt>"
  echo ""
  echo "  Run Task 4.0 4-core experiment. Traces are auto-grouped into sets of 4."
  echo "  Each group: 2 placements × 4 policies = 8 simulations."
  echo ""
  echo "  Required: area_maps from run_task4.0_gen_areamaps.sh"
  echo "  Required: binaries from run_task4.0_build.sh"
  echo ""
  echo "  Environment variables:"
  echo "    TASK4_0_4C_PARALLEL  Max parallel sims (default: 4)"
  echo "    TASK4_0_WARMUP       Warmup instructions (default: 50000000)"
  echo "    TASK4_0_SIM          Simulation instructions (default: 1000000000)"
  echo "    TASK4_0_AMAP_DIR     Area maps directory (default: auto-detect)"
  exit 1
fi

GROUPS=()
if [ "$1" = "--groups" ]; then
  # Read groups from file
  if [ $# -lt 2 ] || [ ! -f "$2" ]; then
    echo "FATAL: --groups requires a valid group file (one group per line, 4 traces per line)"
    exit 1
  fi
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    GROUPS+=("$line")
  done < "$2"
else
  # Auto-group traces into sets of 4
  ALL_TRACES=("$@")
  N_TRACES=${#ALL_TRACES[@]}
  N_GROUPS=$((N_TRACES / 4))
  REMAINDER=$((N_TRACES % 4))

  if [ "$REMAINDER" -ne 0 ]; then
    echo "WARNING: $N_TRACES traces not divisible by 4 — last $REMAINDER trace(s) will be skipped"
    echo "  Traces skipped: ${ALL_TRACES[*]:$((N_GROUPS * 4))}"
  fi

  for ((i = 0; i < N_GROUPS; i++)); do
    start=$((i * 4))
    group="${ALL_TRACES[$start]} ${ALL_TRACES[$start+1]} ${ALL_TRACES[$start+2]} ${ALL_TRACES[$start+3]}"
    GROUPS+=("$group")
  done
fi

if [ "${#GROUPS[@]}" -eq 0 ]; then
  echo "FATAL: no valid groups (need at least 4 traces for one group)"
  exit 1
fi

# ------------------------------------------------------------------
# Locate area_maps
# ------------------------------------------------------------------
AMAP_DIR="${TASK4_0_AMAP_DIR:-}"
if [ -z "$AMAP_DIR" ]; then
  AMAP_DIR="$ARTIFACTS_DIR/runs/task4.0-e2e-rpp/area_maps/latest"
  if [ ! -d "$AMAP_DIR" ]; then
    echo "FATAL: area_maps not found at $AMAP_DIR"
    echo "  Run scripts/run_task4.0_gen_areamaps.sh first, or set TASK4_0_AMAP_DIR"
    exit 1
  fi
fi

# ------------------------------------------------------------------
# Verify binaries
# ------------------------------------------------------------------
missing_bins=0
for pol in "${POLICIES[@]}"; do
  bin_name="${BRANCH_PRED}-${PREFETCHERS}-${pol}-4core"
  if [ ! -f "$BIN_DIR/$bin_name" ]; then
    echo "MISSING binary: bin/$bin_name"
    missing_bins=$((missing_bins + 1))
  fi
done
if [ "$missing_bins" -gt 0 ]; then
  echo "FATAL: $missing_bins binaries missing. Run scripts/run_task4.0_build.sh first."
  exit 1
fi

mkdir -p "$RUN_DIR" "$RUN_DIR/merged_amaps"

# ------------------------------------------------------------------
# Derive benchmark name
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
# Count tasks
# ------------------------------------------------------------------
N_GROUPS=${#GROUPS[@]}
N_TOTAL=$((N_GROUPS * ${#PLACEMENTS[@]} * ${#POLICIES[@]}))

echo "=== Task 4.0 4-Core Experiment ==="
echo "  Groups:     $N_GROUPS"
echo "  Placements: ${PLACEMENTS[*]}"
echo "  Policies:   ${POLICIES[*]}"
echo "  Warmup:     $WARMUP (per core)"
echo "  Sim:        $SIM (per core)"
echo "  Total tasks: $N_TOTAL"
echo "  Workers:    $MAX_PARALLEL"
echo "  Area maps:  $AMAP_DIR"
echo "  Run dir:    $RUN_DIR"
echo ""

# ------------------------------------------------------------------
# Python merge helper for area_maps
# ------------------------------------------------------------------
MERGE_PY=$(cat <<'PYEOF'
import struct, sys, os

MAGIC = 0x41524541
VERSION = 1
HEADER_FMT = '<IIQ'
ENTRY_FMT = '<QB'

def read_amap(path):
    entries = {}
    if not os.path.exists(path):
        print(f"WARNING: missing area_map: {path}", file=sys.stderr)
        return entries
    with open(path, 'rb') as f:
        header = f.read(16)
        if len(header) < 16:
            print(f"WARNING: truncated header in {path}", file=sys.stderr)
            return entries
        magic, version, n = struct.unpack(HEADER_FMT, header)
        if magic != MAGIC:
            print(f"WARNING: bad magic in {path}", file=sys.stderr)
            return entries
        for _ in range(n):
            rec = f.read(9)
            if len(rec) < 9:
                break
            page_id, area = struct.unpack(ENTRY_FMT, rec)
            # Keep first assignment for duplicates
            if page_id not in entries:
                entries[page_id] = area
    return entries

def write_amap(path, entries):
    sorted_entries = sorted(entries.items())
    with open(path, 'wb') as f:
        f.write(struct.pack(HEADER_FMT, MAGIC, VERSION, len(sorted_entries)))
        for page_id, area in sorted_entries:
            f.write(struct.pack(ENTRY_FMT, page_id, area))
    return len(sorted_entries)

if __name__ == '__main__':
    # Usage: python3 merge_amaps.py <merged_output> <amap1> <amap2> <amap3> <amap4>
    out_path = sys.argv[1]
    inputs = sys.argv[2:]
    merged = {}
    for inp in inputs:
        d = read_amap(inp)
        merged.update(d)  # later files overwrite, but dedup keeps first
    n = write_amap(out_path, merged)
    print(f"Merged {n} entries from {len(inputs)} files → {out_path}")
PYEOF
)

# ------------------------------------------------------------------
# Control plane
# ------------------------------------------------------------------
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task4.0-e2e-rpp-4core  tasks=$N_TOTAL  run=$RUN_TS
  warmup=$WARMUP  sim=$SIM  workers=$MAX_PARALLEL  amap_dir=$AMAP_DIR  groups=$N_GROUPS
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 4.0: End-to-End RPP Performance — 4-Core
  Groups:     $N_GROUPS
  Placements: ${PLACEMENTS[*]}
  Policies:   ${POLICIES[*]}
  Warmup:     $WARMUP (per core)
  Sim:        $SIM (per core)
  Workers:    $MAX_PARALLEL
  Area maps:  $AMAP_DIR
  Started:    $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:    $RUN_DIR
  Plan:       $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

  Groups:
EOF

for ((gi = 0; gi < N_GROUPS; gi++)); do
  echo "  G${gi}: ${GROUPS[$gi]}" >> "$RUN_DIR/main.log"
done
echo "" >> "$RUN_DIR/main.log"

# ------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------
running=0; task_idx=0

for ((gi = 0; gi < N_GROUPS; gi++)); do
  group_name="G${gi}"
  read -ra TRACE_ARR <<< "${GROUPS[$gi]}"

  # Verify all 4 traces exist
  all_ok=1
  for t in "${TRACE_ARR[@]}"; do
    if [ ! -f "$t" ]; then
      echo "WARNING: trace not found: $t — skipping group $group_name" | tee -a "$RUN_DIR/main.log"
      all_ok=0
    fi
  done
  [ "$all_ok" -eq 0 ] && continue

  for placement in "${PLACEMENTS[@]}"; do
    # ------------------------------------------------------------------
    # Merge area_maps for this group × placement
    # ------------------------------------------------------------------
    merged_amap="$RUN_DIR/merged_amaps/${group_name}_${placement}.amap"
    amap_args=()
    for t in "${TRACE_ARR[@]}"; do
      bname="$(benchmark_name "$t")"
      amap_args+=("$AMAP_DIR/${bname}_${placement}.amap")
    done

    echo "── Merging area_maps for ${group_name}_${placement} ──" >> "$RUN_DIR/main.log"
    python3 -c "$MERGE_PY" "$merged_amap" "${amap_args[@]}" >> "$RUN_DIR/main.log" 2>&1 || {
      echo "FATAL: area_map merge failed for ${group_name}_${placement}" | tee -a "$RUN_DIR/main.log"
      continue
    }

    for pol in "${POLICIES[@]}"; do
      task_idx=$((task_idx + 1))
      bin_name="${BRANCH_PRED}-${PREFETCHERS}-${pol}-4core"
      name="${group_name}_${placement}_${pol}_4core"

      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$task_idx/$N_TOTAL] name=$name  traces=${GROUPS[$gi]}" >> "$RUN_DIR/execution.log"
      echo "── ${name} ─────────────────────────────────────────────" >> "$RUN_DIR/main.log"
      echo "  Traces: ${TRACE_ARR[*]}" >> "$RUN_DIR/main.log"
      echo "  Launch: $(date '+%H:%M:%S')" >> "$RUN_DIR/main.log"

      (
        t0=$(date +%s%3N)
        cd "$STAGE_DIR"

        ./bin/${bin_name} \
          -warmup_instructions "$WARMUP" \
          -simulation_instructions "$SIM" \
          -a "$merged_amap" \
          -traces "${TRACE_ARR[@]}" \
          > "$RUN_DIR/${name}.raw" 2>&1
        rc=$?; t1=$(date +%s%3N); elapsed=$((t1 - t0))

        if [ $rc -eq 0 ]; then
          # Extract IPC for each CPU
          ipc0=$(grep "CPU 0 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")
          ipc1=$(grep "CPU 1 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")
          ipc2=$(grep "CPU 2 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")
          ipc3=$(grep "CPU 3 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")

          # Compute geomean of 4 IPCs
          ipc_gm=$(python3 -c "
import math
vals = [float(x) for x in ['$ipc0','$ipc1','$ipc2','$ipc3'] if x and x != 'N/A']
if vals:
    gm = math.exp(sum(math.log(v) for v in vals) / len(vals))
    print(f'{gm:.4f}')
else:
    print('N/A')
" 2>/dev/null)

          # Verify all 4 IPCs > 0
          all_positive=1
          for ipc_val in "$ipc0" "$ipc1" "$ipc2" "$ipc3"; do
            if [ "$ipc_val" = "N/A" ] || ! python3 -c "exit(0 if float('$ipc_val' or '0') > 0 else 1)" 2>/dev/null; then
              all_positive=0
            fi
          done

          anomaly_flag=""
          [ "$all_positive" -eq 0 ] && anomaly_flag=" result=ipc_anomaly"

          echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  ipc_cpu0=$ipc0  ipc_cpu1=$ipc1  ipc_cpu2=$ipc2  ipc_cpu3=$ipc3  ipc_gm=$ipc_gm" > "$RUN_DIR/${name}.sub.log"
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  ipc_cpu0=$ipc0  ipc_cpu1=$ipc1  ipc_cpu2=$ipc2  ipc_cpu3=$ipc3  ipc_gm=$ipc_gm${anomaly_flag}" >> "$RUN_DIR/execution.log"
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
# Results summary
# ------------------------------------------------------------------
pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || true)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || true)
anomaly=$(grep -c "result=ipc_anomaly" "$RUN_DIR/execution.log" 2>/dev/null || true)

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  IPC Geomean Summary (4-Core, geomean over group IPC geomeans)
────────────────────────────────────────────────────────
EOF

for placement in "${PLACEMENTS[@]}"; do
  echo "  --- Placement: $placement ---" >> "$RUN_DIR/main.log"
  for pol in "${POLICIES[@]}"; do
    gms=()
    for ((gi = 0; gi < N_GROUPS; gi++)); do
      group_name="G${gi}"
      name="${group_name}_${placement}_${pol}_4core"
      gm=$(grep "ipc_gm=" "$RUN_DIR/execution.log" 2>/dev/null | grep "name=$name " | sed 's/.*ipc_gm=//;s/ .*//' || echo "")
      if [ -n "$gm" ] && [ "$gm" != "N/A" ]; then
        gms+=("$gm")
      fi
    done
    if [ ${#gms[@]} -gt 0 ]; then
      geomean=$(python3 -c "
import math
vals = [float(x) for x in '${gms[*]}'.split()]
gm = math.exp(sum(math.log(v) for v in vals) / len(vals))
print(f'{gm:.4f}')
")
      echo "  ${placement}/${pol}: geomean IPC = $geomean (${#gms[@]} groups)" >> "$RUN_DIR/main.log"
    else
      echo "  ${placement}/${pol}: geomean IPC = N/A" >> "$RUN_DIR/main.log"
    fi
  done
done

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Results
────────────────────────────────────────────────────────
  Pass: $pass  |  Fail: $fail  |  Anomalies: $anomaly  |  Total: $N_TOTAL
────────────────────────────────────────────────────────
  Checks
────────────────────────────────────────────────────────
  [$( [ "$pass" -eq "$N_TOTAL" ] && echo "PASS" || echo "FAIL")] All ${pass}/$N_TOTAL tasks completed
  [$( [ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL")] Zero failures ($fail failures)
  [$( [ "$anomaly" -eq 0 ] && echo "PASS" || echo "WARN")] No IPC anomalies — all 4 CPUs IPC > 0 ($anomaly with issues)

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
EOF

echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.0-e2e-rpp-4core  pass=$pass  fail=$fail  anomaly=$anomaly" >> "$RUN_DIR/execution.log"

# Symlinks
ln -sfn "$RUN_TS" "$ARTIFACTS_DIR/runs/task4.0-e2e-rpp/latest"
ln -sfn "../../scripts/run_task4.0_e2e_rpp_4core.sh" "$PLANS_DIR/run_4core.sh"

cat "$RUN_DIR/main.log"
echo ""
echo "Done. pass=$pass fail=$fail anomaly=$anomaly"
echo "Results: $RUN_DIR"
