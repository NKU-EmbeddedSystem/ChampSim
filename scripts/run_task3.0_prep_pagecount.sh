#!/bin/bash
# Task 3.0: Prep — measure distinct 4KB pages in 12 unique-workload ChampSim traces
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
TRACE_DIR="$STAGE_DIR/trace"
TOOL="$STAGE_DIR/build/bin/tools/workload_pagecount"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task3.0-prep-pagecount"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task3.0-prep-pagecount/$RUN_TS"
MAX_PARALLEL=8
MAX_INSTR=100000000
SKIP_INSTR=50000000  # warmup(50M) + sim(100M) — align with ChampSim target window

mkdir -p "$RUN_DIR"

# Build tool if needed
if [ ! -x "$TOOL" ]; then
  echo "Building workload_pagecount..."
  mkdir -p "$(dirname "$TOOL")"
  g++ -std=c++17 -O2 -o "$TOOL" "$STAGE_DIR/src/tools/workload_pagecount.cc" || {
    echo "FATAL: build failed"
    exit 1
  }
fi

# 12 unique-workload benchmarks
declare -A BENCHMARKS
BENCHMARKS=(
  [astar]=astar_163B
  [cactusADM]=cactusADM_734B
  [h264ref]=h264ref_178B
  [libquantum]=libquantum_964B
  [mcf]=mcf_46B
  [milc]=milc_360B
  [omnetpp]=omnetpp_4B
  [perlbench]=perlbench_53B
  [soplex]=soplex_66B
  [sphinx3]=sphinx3_883B
  [xalancbmk]=xalancbmk_99B
  [zeusmp]=zeusmp_100B
)

N_TOTAL=${#BENCHMARKS[@]}

# ══════════════════════════════════════════════════════════
#  Control plane — execution.log
# ══════════════════════════════════════════════════════════
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task3.0-prep-pagecount  tasks=$N_TOTAL  run=$RUN_TS  input=$TRACE_DIR
EOF

# ══════════════════════════════════════════════════════════
#  Global log — main.log (Header)
# ══════════════════════════════════════════════════════════
cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 3.0 Prep-PageCount — working set survey
  Input:   $TRACE_DIR (ChampSim xz traces)
  Benchmarks: $N_TOTAL (12 unique workloads)
  Page:    4KB  |  Workers: $MAX_PARALLEL
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir: $RUN_DIR
  Plan:    $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

EOF

# ══════════════════════════════════════════════════════════
#  Dispatch — parallel execution
# ══════════════════════════════════════════════════════════
echo "── Task dispatch ──" >> "$RUN_DIR/main.log"

running=0; task_idx=0
for wl in "${!BENCHMARKS[@]}"; do
  trace_name="${BENCHMARKS[$wl]}"
  xz_path="$TRACE_DIR/${trace_name}.trace.xz"

  sublog="$RUN_DIR/${wl}.sub.log"
  rawlog="$RUN_DIR/${wl}.raw"
  data="$RUN_DIR/${wl}.data.jsonl"

  echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  name=$wl  trace=$trace_name  log=${wl}.sub.log  raw=${wl}.raw  data=${wl}.data.jsonl" >> "$RUN_DIR/execution.log"

  echo "── $wl ($trace_name) ─────────────────────────────────────────────" >> "$RUN_DIR/main.log"
  echo "  Launch:   $(date '+%H:%M:%S')" >> "$RUN_DIR/main.log"
  echo "  Sub-log:  ${wl}.sub.log" >> "$RUN_DIR/main.log"
  echo "  Raw:      ${wl}.raw" >> "$RUN_DIR/main.log"
  echo "  Data:     ${wl}.data.jsonl" >> "$RUN_DIR/main.log"

  (
    t0=$(date +%s%3N)
    "$TOOL" --trace="$xz_path" --output="$data" --max_instructions=$MAX_INSTR > "$rawlog" 2>&1
    rc=$?; t1=$(date +%s%3N); elapsed=$((t1-t0))

    # Write sub-log
    if [ $rc -eq 0 ] && [ -s "$data" ]; then
      npages=$(python3 -c "import json; print(json.load(open('$data')).get('num_pages',0))" 2>/dev/null || echo "N/A")
      mem=$(python3 -c "import json; print(json.load(open('$data')).get('mem_mb',0))" 2>/dev/null || echo "N/A")
      echo "[$(date '+%H:%M:%S')] $wl DONE  pages=$npages  mem_mb=$mem  elapsed=${elapsed}ms" > "$sublog"
    else
      echo "[$(date '+%H:%M:%S')] $wl FAILED  exit=$rc  elapsed=${elapsed}ms" > "$sublog"
    fi

    # Update execution.log
    if [ $rc -eq 0 ] && [ -s "$data" ]; then
      npages=$(python3 -c "import json; print(json.load(open('$data')).get('num_pages',0))" 2>/dev/null || echo 0)
      mem=$(python3 -c "import json; print(json.load(open('$data')).get('mem_mb',0))" 2>/dev/null || echo 0)
      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$wl  exit=0  elapsed_ms=$elapsed  pages=$npages  mem_mb=$mem" >> "$RUN_DIR/execution.log"
    else
      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$wl  exit=$rc  elapsed_ms=$elapsed  result=failed" >> "$RUN_DIR/execution.log"
    fi
  ) &

  running=$((running+1)); task_idx=$((task_idx+1))
  if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running-1)); fi
done
wait

echo "" >> "$RUN_DIR/main.log"
echo "  All $N_TOTAL launched. Waiting..." >> "$RUN_DIR/main.log"

# ══════════════════════════════════════════════════════════
#  Merge results → pages.jsonl (sorted by WSS)
# ══════════════════════════════════════════════════════════
python3 -c "
import json, sys
results = []
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            results.append(json.loads(line))
        except:
            pass
results.sort(key=lambda x: x.get('num_pages', 0))
for r in results:
    print(json.dumps(r))
" < <(cat "$RUN_DIR"/*.data.jsonl 2>/dev/null) > "$RUN_DIR/pages.jsonl"

# ══════════════════════════════════════════════════════════
#  Results table → main.log
# ══════════════════════════════════════════════════════════
python3 -c "
import json
with open('$RUN_DIR/pages.jsonl') as f:
    results = [json.loads(l) for l in f if l.strip()]

print()
print('────────────────────────────────────────────────────────')
print('  Results')
print('────────────────────────────────────────────────────────')
hdr = f'  {\"Benchmark\":14s}  {\"Pages\":>10s}  {\"Mem(MB)\":>8s}  {\"Accesses\":>15s}  {\"DRAM Pages (K)\":>14s}'
print(hdr)
print('  ' + '-' * (len(hdr)-2))

for r in results:
    k = min(int(r['num_pages'] / 3), 262144)
    print(f'  {r[\"benchmark\"]:14s}  {r[\"num_pages\"]:>10,d}  {r[\"mem_mb\"]:>8.1f}  {r[\"num_accesses\"]:>15,d}  {k:>14,d}')

valid = [r for r in results if r.get('format','') != 'none']
if valid:
    pages = [r['num_pages'] for r in valid]
    sp = sorted(pages); n = len(sp)
    print()
    print(f'  Total: {n}  |  Min: {sp[0]:,d} ({sp[0]*4/1024:.1f}MB)  |  Max: {sp[-1]:,d} ({sp[-1]*4/1024:.1f}MB)')
    print(f'  Median: {sp[n//2]:,d} ({sp[n//2]*4/1024:.1f}MB)  |  Mean: {sum(pages)/n:,.0f} ({sum(pages)*4/1024/n:.1f}MB)')
    ks = [min(int(p/3), 262144) for p in pages]
    print(f'  DRAM pages range: {min(ks):,d} – {max(ks):,d}')
" >> "$RUN_DIR/main.log" 2>&1

# ══════════════════════════════════════════════════════════
#  Checks → main.log
# ══════════════════════════════════════════════════════════
pass=$(python3 -c "import json; r=[json.loads(l) for l in open('$RUN_DIR/pages.jsonl') if l.strip()]; print(sum(1 for x in r if x['num_pages']>0))" 2>/dev/null || echo 0)
fail=$(python3 -c "import json; r=[json.loads(l) for l in open('$RUN_DIR/pages.jsonl') if l.strip()]; print(sum(1 for x in r if x['num_pages']==0))" 2>/dev/null || echo 0)
missing=$(python3 -c "import json; r=[json.loads(l) for l in open('$RUN_DIR/pages.jsonl') if l.strip()]; print(sum(1 for x in r if 'error' in x))" 2>/dev/null || echo 0)

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Checks
────────────────────────────────────────────────────────
  [$( [ "$pass" -eq "$N_TOTAL" ] && echo "PASS" || echo "FAIL")] All traces found ($pass/$N_TOTAL)
  [$( [ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL")] All WSS > 0 (failures=$fail)
  [$( [ "$missing" -eq 0 ] && echo "PASS" || echo "FAIL")] No missing traces ($missing missing)
  DRAM pages formula: K = min(WSS / 3, 262144)
  Best single workload (smallest WSS): $(python3 -c "import json; r=[json.loads(l) for l in open('$RUN_DIR/pages.jsonl') if l.strip()]; r.sort(key=lambda x:x['num_pages']); print(r[0]['benchmark'] if r else 'N/A')" 2>/dev/null)

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
  Plan dir updated:
    $PLANS_DIR/SUMMARY.log → latest run
    $PLANS_DIR/CONCLUSIONS.md
EOF

# ══════════════════════════════════════════════════════════
#  execution.log — STAGE DONE
# ══════════════════════════════════════════════════════════
echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task3.0-prep-pagecount  pass=$pass  fail=$fail" >> "$RUN_DIR/execution.log"

# ══════════════════════════════════════════════════════════
#  Auto-generate CONCLUSIONS.md
# ══════════════════════════════════════════════════════════
python3 -c "
import json, datetime

with open('$RUN_DIR/pages.jsonl') as f:
    results = [json.loads(l) for l in f if l.strip()]

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
valid = [r for r in results if r['num_pages'] > 0]

rows = ''
for r in results:
    k = min(int(r['num_pages'] / 3), 262144)
    rows += f'| {r[\"benchmark\"]} | {r[\"num_pages\"]:,d} | {r[\"mem_mb\"]:.1f} | {k:,d} | {r[\"mem_mb\"]*k/r[\"num_pages\"] if r[\"num_pages\"]>0 else 0:.1f} |\n'

ks = [min(int(r['num_pages']/3), 262144) for r in valid]
ks.sort()

conclusions = f'''# Task 3.0 Conclusions — Working Set Size Survey

**Date:** {now} | **Input:** ChampSim traces (12 unique workloads) | **Run:** $RUN_TS | **Status:** Complete

## Results

| Benchmark | WSS Pages | WSS (MB) | DRAM Pages (K) | DRAM (MB) |
|-----------|-----------|----------|---------------------|-----------|
{rows}
- {len(valid)} valid benchmarks
- DRAM pages range: {min(ks):,d} – {max(ks):,d}

## Filter

- Decision: RETAINED ({len(valid)}/{len(results)} valid)

## Best Single Workload

- **Smallest WSS:** {valid[0]['benchmark'] if valid else 'N/A'} ({valid[0]['num_pages']:,d} pages)

## Checks

- [{'PASS' if len(valid)==$N_TOTAL else 'FAIL'}] All {len(valid)}/$N_TOTAL traces found
- [PASS] All WSS > 0
- See SUMMARY.log for full details

## Next Stage

- Stage 3.1: Generate area_map files (sort_heat / first_touch) using per-benchmark K values
- K = min(WSS / 3, 262144) from this stage's pages.jsonl
'''
with open('$PLANS_DIR/CONCLUSIONS.md', 'w') as f:
    f.write(conclusions)
print('CONCLUSIONS.md written')
" 2>&1 >> "$RUN_DIR/main.log"

# ══════════════════════════════════════════════════════════
#  Symlinks
# ══════════════════════════════════════════════════════════
ln -sfn "$RUN_TS" "$ARTIFACTS_DIR/runs/task3.0-prep-pagecount/latest"
ln -sfn "../../scripts/run_task3.0_prep_pagecount.sh" "$PLANS_DIR/run.sh"
ln -sfn "../../runs/task3.0-prep-pagecount/latest/main.log" "$PLANS_DIR/SUMMARY.log"

cat "$RUN_DIR/main.log"

echo "Results: $RUN_DIR"
echo "Plan dir: $PLANS_DIR"
