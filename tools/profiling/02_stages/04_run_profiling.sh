#!/usr/bin/env bash
# Module 4: Run ChampSim profiling over traces with multiple prefetcher configs.
# Output: data/<benchmark>/profiling/<trace>__<pref>__<deg>.json
#
# Usage:
#   ./modules/04_run_profiling.sh <benchmark> [--force] [--dry-run] [--jobs N]
#   PROFILING_PREFETCHER_DEGREES="no:1;next_line:1" ./modules/04_run_profiling.sh <benchmark>
#
# Re-runnable: Re-run when adding or changing prefetchers.
# Set PROFILING_PREFETCHER_DEGREES to select specific prefetchers, or auto-discovers all.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
shift 2>/dev/null || true
FORCE=false
DRY_RUN=false
JOBS="${JOBS:-4}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark> [--force] [--dry-run] [--jobs N]"
    echo "Example: $0 400.perlbench"
    echo "  PROFILING_PREFETCHER_DEGREES=\"no:1;ip_stride:1,2\" $0 400.perlbench"
    exit 1
fi

BENCH_DIR="$DATA_ROOT/$BENCHMARK"
TRACES_DIR="$BENCH_DIR/traces"
PROFILING_DIR="$BENCH_DIR/profiling"
MODULE_NAME="[04_profiling]"

PROFILE_WARMUP="${PROFILE_WARMUP:-1000000}"
PROFILE_SIM="${PROFILE_SIM:-10000000}"

log()  { echo "[$(date '+%H:%M:%S')] $MODULE_NAME $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Discover traces
shopt -s nullglob
traces=("$TRACES_DIR"/*.champsimtrace.xz)
shopt -u nullglob

if [ ${#traces[@]} -eq 0 ]; then
    log "ERROR: No traces found in $TRACES_DIR"
    log "  Run module 03 first."
    exit 1
fi
log "Found ${#traces[@]} trace(s)"

# Discover or use provided prefetcher binaries
declare -A pref_binaries=()

if [[ -n "${PROFILING_PREFETCHER_DEGREES:-}" ]]; then
    IFS=';' read -ra PF_ENTRIES <<< "${PROFILING_PREFETCHER_DEGREES}" || true
    for entry in "${PF_ENTRIES[@]}"; do
        [[ -z "$entry" ]] && continue
        IFS=':' read -r pname degs <<< "$entry"
        IFS=',' read -ra DEG_LIST <<< "$degs" || true
        for dg in "${DEG_LIST[@]}"; do
            pbin="$CHAMPSIM_ROOT/bin/champsim_${pname}_d${dg}"
            if [[ -x "$pbin" ]]; then
                pref_binaries["${pname}:${dg}"]="$pbin"
            else
                log "  [WARN] Binary not found: champsim_${pname}_d${dg}"
            fi
        done
    done
    log "Controller spec → ${#pref_binaries[@]} binaries"
else
    shopt -s nullglob
    for bin in "$CHAMPSIM_ROOT/bin/champsim_"*"_d"*; do
        bname=$(basename "$bin")
        if [[ "$bname" =~ ^champsim_(.+)_d([0-9]+)$ ]]; then
            pref_binaries["${BASH_REMATCH[1]}:${BASH_REMATCH[2]}"]="$bin"
        fi
    done
    shopt -u nullglob
    log "Auto-discovered ${#pref_binaries[@]} profiling binaries"
fi

if [ ${#pref_binaries[@]} -eq 0 ]; then
    log "ERROR: No per-prefetcher binaries found"
    log "  Build them: cd $CHAMPSIM_ROOT && for cfg in tools/profiling/configs/champsim_*_d*.json; do ./config.sh \"\$cfg\" && make -j\$(nproc); done"
    exit 1
fi

# List binaries
for key in "${!pref_binaries[@]}"; do
    log "  $key → ${pref_binaries[$key]}"
done

run mkdir -p "$PROFILING_DIR"

# ── Build job list ──────────────────────────────────────────
declare -a jobs_trace=() jobs_pref=() jobs_deg=() jobs_bin=() jobs_out=()
skipped=0

for trace in "${traces[@]}"; do
    trace_name=$(basename "$trace" .champsimtrace.xz)
    for pf_key in "${!pref_binaries[@]}"; do
        IFS=':' read -r pref_name degree <<< "$pf_key"
        profile_out="$PROFILING_DIR/${trace_name}__${pref_name}__${degree}.json"
        if [ -f "$profile_out" ] && [ "$FORCE" != "true" ]; then
            if [ -s "$profile_out" ] && python3 -c "
import json
with open('$profile_out') as f:
    for i, line in enumerate(f):
        if i >= 1: break
        r = json.loads(line)
        assert 'pc' in r
" 2>/dev/null; then
                log "  [SKIP] ${trace_name}__${pref_name}__${degree}.json (exists, $(wc -l < "$profile_out") lines)"
                ((skipped++)) || true
                continue
            else
                log "  [WARN] ${trace_name}__${pref_name}__${degree}.json exists but invalid, re-running"
            fi
        fi
        jobs_trace+=("$trace")
        jobs_pref+=("$pref_name")
        jobs_deg+=("$degree")
        jobs_bin+=("${pref_binaries[$pf_key]}")
        jobs_out+=("$profile_out")
    done
done

total_jobs=${#jobs_trace[@]}
log "  $total_jobs profiling jobs, $skipped already done"

if [ "$total_jobs" -eq 0 ]; then
    log "All profiling outputs already exist. Nothing to do."
    exit 0
fi

# ── Parallel execution ──────────────────────────────────────
running=0 job_idx=0
failfile=$(mktemp)

while [ "$job_idx" -lt "$total_jobs" ] || [ "$running" -gt 0 ]; do
    while [ "$job_idx" -lt "$total_jobs" ] && [ "$running" -lt "$JOBS" ]; do
        t="${jobs_trace[$job_idx]}"
        pn="${jobs_pref[$job_idx]}"
        pd="${jobs_deg[$job_idx]}"
        pb="${jobs_bin[$job_idx]}"
        po="${jobs_out[$job_idx]}"
        tn=$(basename "$t" .champsimtrace.xz)

        log "  [LAUNCH] trace=$tn pref=$pn deg=$pd (slot=$((running+1))/$JOBS)"

        (
            if $DRY_RUN; then
                echo "[DRY-RUN] ${pb} --warmup-instructions ${PROFILE_WARMUP} --simulation-instructions ${PROFILE_SIM} ${t} | grep '^{' > ${po}"
                exit 0
            fi
            "${pb}" --warmup-instructions ${PROFILE_WARMUP} \
                --simulation-instructions ${PROFILE_SIM} \
                "${t}" 2>"${po}.log" \
                | grep "^{" > "${po}"
            if [ $? -eq 0 ] && [ -s "$po" ]; then
                echo "[$(date '+%H:%M:%S')] [OK] ${tn}__${pn}__${pd}: $(wc -l < "$po") PCs"
                exit 0
            else
                echo "[$(date '+%H:%M:%S')] [FAIL] ${tn}__${pn}__${pd}"
                echo "1" >> "$failfile"
                exit 1
            fi
        ) &
        ((running++)) || true
        ((job_idx++)) || true
    done

    if [ "$running" -gt 0 ]; then
        wait -n 2>/dev/null || true
        ((running--)) || true
    fi
done

wait

if [ -s "$failfile" ]; then
    failed_count=$(wc -l < "$failfile")
    rm -f "$failfile"
    log "WARNING: $failed_count profiling job(s) failed — check .log files"
fi
rm -f "$failfile"

log "Profiling complete. Results in $PROFILING_DIR"
