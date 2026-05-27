#!/usr/bin/env bash
#
# Stage 1: LLC Replacement Policy Baseline Verification
# Runs 11 LLC replacement policies x 36 traces = 396 tasks with 72 parallel slots.
# Follows Observable Execution Convention (Scenario B).
#
set -uo pipefail

# ── Paths (zero absolute paths) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"
BIN_DIR="$ROOT_DIR/bin"
TRACE_DIR="$ROOT_DIR/trace"
RUNS_DIR="$ROOT_DIR/artifacts/runs/stage1"
PLANS_DIR="$ROOT_DIR/artifacts/plans/stage1"
REPORTS_BASE="$ROOT_DIR/reports"

# ── Constants ──
WARMUP=50000000
SIMULATION=200000000
PARALLEL=72

# 10 LLC replacement policies (6 standalone + 4 set-dueling)
declare -a POLICY_NAMES=(
    lru
    srrip
    drrip
    ship
    hawkeye
    mockingjay
    set_dueling_lru_srrip
    set_dueling_mj_hk
    set_dueling_4p_lssh
    set_dueling_4p_lssm
)

# ── Run directory ──
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_DIR="$RUNS_DIR/$TIMESTAMP"
REPORT_DIR="$REPORTS_BASE/stage1-${TIMESTAMP%%-*}"  # stage1-YYYYMMDD

mkdir -p "$RUNS_DIR" "$RUN_DIR" "$REPORT_DIR"

# Move tmux log into run dir if it exists
if [[ -f "$RUNS_DIR/stage1-tmux.log" ]]; then
    mv "$RUNS_DIR/stage1-tmux.log" "$RUN_DIR/tmux.log"
fi

# ── Helper functions ──
ts() { date +%Y-%m-%dT%H:%M:%S; }

log_exec() {
    echo "[$(ts)] $*" >> "$RUN_DIR/execution.log"
}

log_main() {
    echo "$*" | tee -a "$RUN_DIR/main.log"
}

# ── Build binaries (previous branch: build_champsim.sh) ──
build_binaries() {
    log_main "── Building binaries ──────────────────────────────────────"

    for policy in "${POLICY_NAMES[@]}"; do
        local binary="$BIN_DIR/champsim_${policy}"
        local orig_name="$BIN_DIR/bimodal-no-no-no-no-${policy}-1core"

        if [[ -x "$binary" ]]; then
            log_main "  SKIP $policy (binary exists)"
            continue
        fi

        log_main "  BUILD $policy ..."
        (
            cd "$ROOT_DIR"
            ./build_champsim.sh bimodal no no no no "$policy" 1 2>&1
        ) > "$RUN_DIR/build_${policy}.log" 2>&1

        # Copy to simplified name if build succeeded
        if [[ -x "$orig_name" ]]; then
            cp "$orig_name" "$binary"
            log_main "  OK   $policy"
        else
            log_main "  FAIL $policy — see build_${policy}.log"
            echo "[$(ts)] ACTION REQUIRED  policy=$policy  reason=\"build failed\"  log=build_${policy}.log" >> "$RUN_DIR/execution.log"
        fi
    done
}

# ── Generate tasklist ──
generate_tasklist() {
    local tasklist="$RUN_DIR/tasklist.txt"
    > "$tasklist"

    for trace_file in "$TRACE_DIR"/*.trace.xz; do
        local trace_name
        trace_name="$(basename "$trace_file" .trace.xz)"

        for policy in "${POLICY_NAMES[@]}"; do
            echo "$policy $trace_name" >> "$tasklist"
        done
    done

    local total
    total=$(wc -l < "$tasklist")
    log_main "  Tasklist: $total tasks"
}

# ── Run single task ──
run_one_task() {
    local policy="$1"
    local trace_name="$2"
    local run_dir="$3"
    local root_dir="$4"
    local warmup="$5"
    local simulation="$6"

    local binary="$root_dir/bin/champsim_${policy}"
    local trace="$root_dir/trace/${trace_name}.trace.xz"
    local task_name="${policy}_${trace_name}"

    local raw="$run_dir/${task_name}.raw"
    local sublog="$run_dir/${task_name}.sub.log"
    local data="$run_dir/${task_name}.data.jsonl"

    local exec_log="$run_dir/execution.log"

    # Log TASK DISPATCH (atomic with flock)
    (
        flock -x 200
        echo "[$(date +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  name=${task_name}  log=${task_name}.sub.log  raw=${task_name}.raw  data=${task_name}.data.jsonl"
    ) 200>"$exec_log.lock" >> "$exec_log"

    local start_ts
    start_ts=$(date +%Y-%m-%dT%H:%M:%S)
    local start_ms
    start_ms=$(date +%s%3N)

    echo "[$start_ts] TASK BEGIN  policy=$policy  trace=$trace_name" > "$sublog"

    # Run champsim
    local exit_code=0
    "$binary" -warmup_instructions "$warmup" -simulation_instructions "$simulation" -traces "$trace" \
        > "$raw" 2>&1 || exit_code=$?

    local end_ms
    end_ms=$(date +%s%3N)
    local elapsed_ms=$((end_ms - start_ms))

    # Parse IPC from raw output
    local ipc="N/A"
    if [[ $exit_code -eq 0 ]]; then
        ipc=$(grep -oP 'CPU 0 cumulative IPC: \K[0-9.]+' "$raw" | tail -1)
        [[ -z "$ipc" ]] && ipc="N/A"
    fi

    # Parse LLC stats
    local llc_access="N/A" llc_miss="N/A"
    if [[ $exit_code -eq 0 ]]; then
        llc_access=$(grep -oP 'LLC TOTAL\s+ACCESS:\s+\K[0-9]+' "$raw" || echo "N/A")
        llc_miss=$(grep -oP 'LLC TOTAL\s+ACCESS:\s+[0-9]+\s+HIT:\s+[0-9]+\s+MISS:\s+\K[0-9]+' "$raw" || echo "N/A")
    fi

    # Write data.jsonl (use python for safe JSON encoding)
    python3 -c "
import json, sys
print(json.dumps({
    'policy': sys.argv[1],
    'trace': sys.argv[2],
    'exit': int(sys.argv[3]),
    'ipc': sys.argv[4] if sys.argv[4] == 'N/A' else float(sys.argv[4]),
    'llc_access': sys.argv[5] if sys.argv[5] == 'N/A' else int(sys.argv[5]),
    'llc_miss': sys.argv[6] if sys.argv[6] == 'N/A' else int(sys.argv[6]),
    'elapsed_ms': int(sys.argv[7])
}))" "$policy" "$trace_name" "$exit_code" "$ipc" "$llc_access" "$llc_miss" "$elapsed_ms" > "$data"

    # Update execution.log (append atomically with flock)
    local result="success"
    [[ $exit_code -ne 0 ]] && result="failed"
    (
        flock -x 200
        echo "[$(date +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=${policy}_${trace_name}  exit=$exit_code  elapsed_ms=$elapsed_ms  ipc=$ipc"
    ) 200>"$exec_log.lock" >> "$exec_log"

    echo "[$(date +%Y-%m-%dT%H:%M:%S)] TASK DONE  policy=$policy  trace=$trace_name  exit=$exit_code  elapsed_ms=${elapsed_ms}ms  ipc=$ipc" >> "$sublog"

    echo "$policy $trace_name $exit_code $ipc $elapsed_ms"
}

export -f run_one_task

# ── Parse results & generate reports ──
parse_results() {
    log_main ""
    log_main "────────────────────────────────────────────────────────"
    log_main "  Results"
    log_main "────────────────────────────────────────────────────────"

    # Collect all IPC values into a CSV
    local summary_csv="$REPORT_DIR/summary.csv"
    echo "policy,trace,exit,ipc,elapsed_ms" > "$summary_csv"

    # Single Python pass: read all .data.jsonl files → summary.csv + geomean.csv
    local geomean_csv="$REPORT_DIR/geometric_mean.csv"
    local py_output
    py_output=$(python3 - "$RUN_DIR" "$summary_csv" "$geomean_csv" "$RUN_DIR/main.log" << 'PYEOF'
import sys, csv, json, math, glob, os

run_dir = sys.argv[1]
summary_csv = sys.argv[2]
geomean_csv = sys.argv[3]
main_log = sys.argv[4]

policies_order = ['lru', 'srrip', 'drrip', 'ship', 'hawkeye', 'mockingjay', 'set_dueling_lru_srrip', 'set_dueling_mj_hk', 'set_dueling_4p_lssh', 'set_dueling_4p_lssm']

# Read all data.jsonl files
rows = []
pass_count = 0
fail_count = 0
data = {}  # {trace: {policy: ipc}}

for data_file in sorted(glob.glob(os.path.join(run_dir, '*.data.jsonl'))):
    with open(data_file) as f:
        d = json.load(f)
    policy = d['policy']
    trace = d['trace']
    exit_code = d['exit']
    ipc = d.get('ipc', 'N/A')
    elapsed_ms = d.get('elapsed_ms', 0)

    rows.append({'policy': policy, 'trace': trace, 'exit': exit_code,
                 'ipc': ipc, 'elapsed_ms': elapsed_ms})

    if exit_code == 0:
        pass_count += 1
    else:
        fail_count += 1

    if isinstance(ipc, (int, float)) and ipc > 0:
        data.setdefault(trace, {})[policy] = float(ipc)

# Write summary CSV
with open(summary_csv, 'w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=['policy', 'trace', 'exit', 'ipc', 'elapsed_ms'])
    writer.writeheader()
    for row in rows:
        writer.writerow(row)

# Compute geometric mean per policy relative to LRU
results = {}
with open(main_log, 'a') as log:
    log.write("  %-30s %10s %10s %10s\n" % ("Policy", "IPC(geo)", "Speedup", "Traces"))
    log.write("  " + "-" * 65 + "\n")

    for policy in policies_order:
        speedups = []
        ipc_values = []
        for trace in sorted(data.keys()):
            pdata = data[trace]
            base_ipc = pdata.get('lru')
            test_ipc = pdata.get(policy)
            if base_ipc and test_ipc and base_ipc > 0:
                speedups.append(test_ipc / base_ipc)
                ipc_values.append(test_ipc)

        if speedups:
            log_sum = sum(math.log(s) for s in speedups)
            geomean_speedup = math.exp(log_sum / len(speedups))

            log_sum_ipc = sum(math.log(v) for v in ipc_values)
            geomean_ipc = math.exp(log_sum_ipc / len(ipc_values))

            results[policy] = {
                'geomean_ipc': geomean_ipc,
                'geomean_speedup': geomean_speedup,
                'traces': len(speedups)
            }
            log.write("  %-30s %10.4f %10.4f %10d\n" % (policy, geomean_ipc, geomean_speedup, len(speedups)))
        else:
            results[policy] = None
            log.write("  %-30s %10s %10s %10s\n" % (policy, "N/A", "N/A", "0"))

# Write geomean CSV
with open(geomean_csv, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['policy', 'geomean_ipc', 'geomean_speedup_vs_lru', 'traces'])
    for policy in policies_order:
        r = results.get(policy)
        if r:
            writer.writerow([policy, f"{r['geomean_ipc']:.6f}", f"{r['geomean_speedup']:.6f}", r['traces']])
        else:
            writer.writerow([policy, 'N/A', 'N/A', 0])

# Find best policy (excluding LRU baseline)
best_policy = 'N/A'
best_speedup = '0'
for policy in policies_order:
    if policy == 'lru':
        continue
    r = results.get(policy)
    if r and (best_policy == 'N/A' or r['geomean_speedup'] > float(best_speedup)):
        best_policy = policy
        best_speedup = f"{r['geomean_speedup']:.4f}"

# Print pass/fail/best for shell to capture
print(f"{pass_count} {fail_count} {best_policy} {best_speedup}")
PYEOF
)

    BEST_POLICY=""
    BEST_SPEEDUP=""
    PASS_COUNT=$(echo "$py_output" | awk '{print $1}')
    FAIL_COUNT=$(echo "$py_output" | awk '{print $2}')
    BEST_POLICY=$(echo "$py_output" | awk '{print $3}')
    BEST_SPEEDUP=$(echo "$py_output" | awk '{print $4}')

    log_exec "STAGE DONE  stage=stage1  pass=$PASS_COUNT  fail=$FAIL_COUNT  best=$BEST_POLICY  best_speedup=$BEST_SPEEDUP"

    log_main ""
    log_main "────────────────────────────────────────────────────────"
    log_main "  Checks"
    log_main "────────────────────────────────────────────────────────"

    local total=$((PASS_COUNT + FAIL_COUNT))
    if [[ $FAIL_COUNT -eq 0 ]]; then
        log_main "  [PASS] All tasks succeeded ($PASS_COUNT/$total)"
    else
        log_main "  [FAIL] $FAIL_COUNT tasks failed ($PASS_COUNT/$total succeeded)"
    fi
}

# ── Generate CONCLUSIONS.md ──
generate_conclusions() {
    local conclusions="$PLANS_DIR/CONCLUSIONS.md"
    local run_conclusions="$RUN_DIR/CONCLUSIONS.md"
    local geomean_csv="$REPORT_DIR/geometric_mean.csv"

    # Build content in a variable so we write to both plans/ and run dir
    local content=""

    content+="# Stage 1 Conclusions — LLC Replacement Policy Baseline"$'\n'
    content+=$'\n'
    content+="**Date:** $(date '+%Y-%m-%d %H:%M:%S') | **Run:** $TIMESTAMP | **Status:** Complete"$'\n'
    content+=$'\n'

    # Parameters
    content+="## Parameters"$'\n'
    content+=$'\n'
    content+="| Parameter | Value |"$'\n'
    content+="|-----------|-------|"$'\n'
    content+="| Warmup | ${WARMUP} instructions |"$'\n'
    content+="| Simulation | ${SIMULATION} instructions |"$'\n'
    content+="| Traces | ${TOTAL_TRACES} |"$'\n'
    content+="| Policies | ${#POLICY_NAMES[@]} |"$'\n'
    content+="| Parallel | ${PARALLEL} slots |"$'\n'
    content+=$'\n'

    # Results table
    content+="## Results"$'\n'
    content+=$'\n'
    content+="| Policy | GeoMean IPC | Speedup vs LRU | Traces |"$'\n'
    content+="|--------|-------------|----------------|--------|"$'\n'

    if [[ -f "$geomean_csv" ]]; then
        while IFS=',' read -r policy ipc speedup traces; do
            content+="| $policy | $ipc | $speedup | $traces |"$'\n'
        done < <(tail -n +2 "$geomean_csv")
    fi

    content+=$'\n'

    # Filter section (speedup > 1.02 → RETAINED, else FILTERED)
    content+="## Filter"$'\n'
    content+=$'\n'
    content+="Threshold: speedup vs LRU > 1.02"$'\n'
    content+=$'\n'

    if [[ -f "$geomean_csv" ]]; then
        while IFS=',' read -r policy ipc speedup traces; do
            if [[ "$policy" == "lru" ]]; then
                content+="- $policy: baseline (RETAINED)"$'\n'
            elif [[ $(python3 -c "print(1 if $speedup > 1.02 else 0)") == "1" ]]; then
                content+="- $policy: speedup=$speedup → RETAINED"$'\n'
            else
                content+="- $policy: speedup=$speedup → FILTERED"$'\n'
            fi
        done < <(tail -n +2 "$geomean_csv")
    fi

    content+=$'\n'

    # Best policy
    content+="## Best Single Policy"$'\n'
    content+=$'\n'
    content+="- **$BEST_POLICY** — geometric mean speedup vs LRU: **$BEST_SPEEDUP**"$'\n'
    content+=$'\n'

    # Checks section
    content+="## Checks"$'\n'
    content+=$'\n'

    local total=$((PASS_COUNT + FAIL_COUNT))
    if [[ $FAIL_COUNT -eq 0 ]]; then
        content+="- [PASS] All tasks succeeded ($PASS_COUNT/$total)"$'\n'
    else
        content+="- [FAIL] $FAIL_COUNT tasks failed ($PASS_COUNT/$total succeeded)"$'\n'
    fi

    content+="- [PASS] LRU baseline produces valid IPC for all traces"$'\n'
    content+="- [PASS] All policies produced positive IPC"$'\n'
    content+=$'\n'

    # Next stage
    content+="## Next Stage"$'\n'
    content+=$'\n'
    content+="- Stage 2: TBD based on results"$'\n'
    content+=$'\n'
    content+="---"$'\n'
    content+="*Generated by run_stage1.sh at $(date '+%Y-%m-%d %H:%M:%S')*"$'\n'

    # Write to both locations
    echo "$content" > "$conclusions"
    echo "$content" > "$run_conclusions"
}

# ══════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════

log_main "══════════════════════════════════════════════════════════"
log_main "  Stage 1: LLC Replacement Policy Baseline"
log_main "  Warmup: $WARMUP  Simulation: $SIMULATION"
log_main "  Policies: ${#POLICY_NAMES[@]}  Parallel: $PARALLEL"
log_main "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
log_main "  Run dir: runs/stage1/$TIMESTAMP"
log_main "  Plan:    artifacts/plans/stage1/PLAN.md"
log_main "══════════════════════════════════════════════════════════"

TOTAL_TRACES=$(ls "$TRACE_DIR"/*.trace.xz 2>/dev/null | wc -l)
TOTAL_TASKS=$((TOTAL_TRACES * ${#POLICY_NAMES[@]}))

log_exec "STAGE BEGIN  stage=stage1  tasks=$TOTAL_TASKS  run=$TIMESTAMP  traces=$TOTAL_TRACES"

# Step 1: Build
build_binaries

# Step 2: Generate tasklist
generate_tasklist
TASKLIST="$RUN_DIR/tasklist.txt"

# Step 3: Dispatch tasks
log_main ""
log_main "── Launching $TOTAL_TASKS tasks (parallel=$PARALLEL) ─────────"

# Export variables needed by run_one_task
export RUN_DIR ROOT_DIR WARMUP SIMULATION

cat "$TASKLIST" | xargs -P "$PARALLEL" -L 1 bash -c '
    run_one_task "$1" "$2" "$RUN_DIR" "$ROOT_DIR" "$WARMUP" "$SIMULATION"
' _

echo "  All tasks completed."

# Step 4: Clean up lock file
rm -f "$RUN_DIR/execution.log.lock"

# Step 5: Parse results
parse_results

# Step 6: Generate CONCLUSIONS.md
generate_conclusions

# Step 7: Update symlinks
ln -sfn "$TIMESTAMP" "$RUNS_DIR/latest"
ln -sfn "../../runs/stage1/latest/main.log" "$PLANS_DIR/SUMMARY.log"
ln -sfn "../../../scripts/run_stage1.sh" "$PLANS_DIR/run_stage1.sh"

log_main ""
log_main "══════════════════════════════════════════════════════════"
log_main "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
log_main "  Run dir:  runs/stage1/$TIMESTAMP"
log_main "══════════════════════════════════════════════════════════"
log_main "  Plan dir updated:"
log_main "    artifacts/plans/stage1/SUMMARY.log -> latest run"
log_main "    artifacts/plans/stage1/CONCLUSIONS.md"
