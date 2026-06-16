#!/bin/bash
# Quick test: 3 configs (random, sort_heat, first_touch) × 3 policies × 12 benchmarks
# No migration, no prefetcher. DRAM:CXL=1:2. Warmup=10M Sim=20M.
set -uo pipefail

STAGE_DIR="$(cd "$(dirname "$0")" && pwd)/.."
TRACE_DIR="$STAGE_DIR/trace"
AMAP_DIR="$STAGE_DIR/artifacts/runs/task3.1-gen-areamaps/latest"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$STAGE_DIR/artifacts/runs/quick-3configs/$RUN_TS"
MAX_PARALLEL=64

mkdir -p "$RUN_DIR"

# ── 12 benchmarks ──
declare -A TRACES
TRACES=(
  [astar]=astar_163B [cactusADM]=cactusADM_734B [h264ref]=h264ref_178B
  [libquantum]=libquantum_964B [mcf]=mcf_46B [milc]=milc_360B
  [omnetpp]=omnetpp_4B [perlbench]=perlbench_53B [soplex]=soplex_66B
  [sphinx3]=sphinx3_883B [xalancbmk]=xalancbmk_99B [zeusmp]=zeusmp_100B
)

# ── 3 configs: placement only, no migration ──
declare -A CONFIG_LABEL
CONFIG_LABEL[random]="Rnd+Nomig+NoPF"
CONFIG_LABEL[sort_heat]="Sort+Nomig+NoPF"
CONFIG_LABEL[first_touch]="FCFS+Nomig+NoPF"

PLACEMENTS=(random sort_heat first_touch)
POLICIES=(lru mockingjay rpp)

TOTAL=$((${#TRACES[@]} * ${#PLACEMENTS[@]} * ${#POLICIES[@]}))

cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=quick-3configs  tasks=$TOTAL  run=$RUN_TS
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Quick Test: 3 Placement Configs × 3 Policies
  Configs: random, sort_heat, first_touch (no migration, no prefetcher)
  Policies: lru, mockingjay, rpp
  Warmup: 50M  Sim: 100M  DRAM:CXL = 1:2
  Benchmarks: ${#TRACES[@]}  Workers: $MAX_PARALLEL  Tasks: $TOTAL
  Started: $(date '+%Y-%m-%d %H:%M:%S')
══════════════════════════════════════════════════════════

EOF

missing_maps=0
for wl in "${!TRACES[@]}"; do
  for placement in "${PLACEMENTS[@]}"; do
    amap="$AMAP_DIR/${wl}_${placement}.amap"
    if [ ! -f "$amap" ]; then
      echo "MISSING area_map: $amap" >> "$RUN_DIR/main.log"
      missing_maps=$((missing_maps+1))
    fi
  done
done
if [ "$missing_maps" -ne 0 ]; then
  echo "FATAL: missing $missing_maps area_map files. Run scripts/run_task3.1_gen_areamaps.sh first." | tee -a "$RUN_DIR/main.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=quick-3configs  pass=0  fail=$TOTAL  result=missing_area_maps" >> "$RUN_DIR/execution.log"
  exit 1
fi

running=0; idx=0
for wl in "${!TRACES[@]}"; do
  tname="${TRACES[$wl]}"
  TRACE="$TRACE_DIR/${tname}.trace.xz"

  for placement in "${PLACEMENTS[@]}"; do
    # Build args
    args=()
    amap="$AMAP_DIR/${wl}_${placement}.amap"
    [ -f "$amap" ] && args+=("-a" "$amap")

    for pol in "${POLICIES[@]}"; do
      idx=$((idx+1))
      bin="$STAGE_DIR/bin/hp-no-no-no-no-${pol}-1core"
      label="${CONFIG_LABEL[$placement]}"
      name="${wl}_${label}_${pol}"

      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$idx/$TOTAL] $name" >> "$RUN_DIR/execution.log"
      echo "── $name ──" >> "$RUN_DIR/main.log"

      (
        t0=$(date +%s%3N)
        "$bin" -warmup_instructions 50000000 -simulation_instructions 100000000 \
          "${args[@]}" -traces "$TRACE" > "$RUN_DIR/${name}.raw" 2>&1
        rc=$?; t1=$(date +%s%3N); elapsed=$((t1-t0))

        if [ $rc -eq 0 ]; then
          ipc=$(grep "cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | tail -1 | awk '{print $NF}' || echo "N/A")
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  ipc=$ipc" >> "$RUN_DIR/execution.log"
          echo "  OK  ipc=$ipc  elapsed=${elapsed}ms" > "$RUN_DIR/${name}.sub.log"
        else
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=$rc  elapsed_ms=$elapsed  result=failed" >> "$RUN_DIR/execution.log"
          echo "  FAILED  exit=$rc" > "$RUN_DIR/${name}.sub.log"
        fi
      ) &

      running=$((running+1))
      if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running-1)); fi
    done
  done
done
wait

# ── Summary ──
pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || true)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || true)

echo "" >> "$RUN_DIR/main.log"
echo "────────────────────────────────────────────────────────" >> "$RUN_DIR/main.log"
echo "  Results: pass=$pass fail=$fail / $TOTAL" >> "$RUN_DIR/main.log"
echo "────────────────────────────────────────────────────────" >> "$RUN_DIR/main.log"

# Extract IPC table
python3 << PYEOF >> "$RUN_DIR/main.log"
import os, re

run_dir = "$RUN_DIR"
placements = ["random", "sort_heat", "first_touch"]
policies = ["lru", "mockingjay", "rpp"]
benchmarks = ["astar","cactusADM","h264ref","libquantum","mcf","milc","omnetpp","perlbench","soplex","sphinx3","xalancbmk","zeusmp"]
labels = {"random":"Rnd","sort_heat":"Sort","first_touch":"FCFS"}

print("\n  Per-Config Geomean IPC:")
print(f"  {'Config':20s}  {'LRU':>8s}  {'MJ':>8s}  {'RPP':>8s}  {'MJ/LRU':>8s}  {'RPP/LRU':>8s}  {'RPP/MJ':>8s}")
print("  " + "-" * 80)

for placement in placements:
    lab = labels[placement]
    label = {"random":"Rnd+Nomig+NoPF","sort_heat":"Sort+Nomig+NoPF","first_touch":"FCFS+Nomig+NoPF"}[placement]
    ipcs = {p: [] for p in policies}
    for wl in benchmarks:
        for pol in policies:
            name = f"{wl}_{label}_{pol}"
            raw = f"{run_dir}/{name}.raw"
            if os.path.exists(raw):
                try:
                    with open(raw) as f:
                        for line in f:
                            m = re.search(r'cumulative IPC:\s*([\d.]+)', line)
                            if m:
                                ipcs[pol].append(float(m.group(1)))
                                break
                except:
                    pass

    if all(len(ipcs[p]) > 0 for p in policies):
        import math
        geo = {}
        for p in policies:
            vals = ipcs[p]
            geo[p] = math.exp(sum(math.log(v) for v in vals) / len(vals))
        mj_lru = geo["mockingjay"] / geo["lru"] if geo["lru"] > 0 else 0
        rpp_lru = geo["rpp"] / geo["lru"] if geo["lru"] > 0 else 0
        rpp_mj = geo["rpp"] / geo["mockingjay"] if geo["mockingjay"] > 0 else 0
        print(f"  {label:20s}  {geo['lru']:8.4f}  {geo['mockingjay']:8.4f}  {geo['rpp']:8.4f}  {mj_lru:8.4f}  {rpp_lru:8.4f}  {rpp_mj:8.4f}")
    else:
        print(f"  {label:20s}  (incomplete data)")

print("\n  Per-Benchmark IPC (RPP):")
hdr = f"  {'Benchmark':14s}"
for placement in placements:
    hdr += f"  {labels[placement]:>6s}"
print(hdr)
print("  " + "-" * 50)
for wl in benchmarks:
    row = f"  {wl:14s}"
    for placement in placements:
        label = {"random":"Rnd+Nomig+NoPF","sort_heat":"Sort+Nomig+NoPF","first_touch":"FCFS+Nomig+NoPF"}[placement]
        name = f"{wl}_{label}_rpp"
        raw = f"{run_dir}/{name}.raw"
        ipc = "N/A"
        if os.path.exists(raw):
            try:
                with open(raw) as f:
                    for line in f:
                        m = re.search(r'cumulative IPC:\s*([\d.]+)', line)
                        if m:
                            ipc = f"{float(m.group(1)):.4f}"
                            break
            except:
                pass
        row += f"  {ipc:>6s}"
    print(row)
PYEOF

echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=quick-3configs  pass=$pass  fail=$fail" >> "$RUN_DIR/execution.log"
ln -sfn "$RUN_TS" "$STAGE_DIR/artifacts/runs/quick-3configs/latest"

echo "Done. pass=$pass fail=$fail"
echo "Results: $RUN_DIR"
cat "$RUN_DIR/main.log" | tail -50
