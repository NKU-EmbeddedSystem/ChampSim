#!/usr/bin/env bash
#
# profiling_controller.sh — All-in-one profiling controller for Coordinate Hint Cache
#
# Usage:
#   ./profiling_controller.sh --status                  # Full status panel
#   ./profiling_controller.sh --check-build             # Prefetcher compilation status
#   ./profiling_controller.sh --prefetchers "no:1,next_line:1,ip_stride:1-4" --stage 4
#   ./profiling_controller.sh --prefetchers standard --benchmarks 401.bzip2,429.mcf
#   ./profiling_controller.sh --dry-run                 # Preview without executing
#
# Preset groups:
#   basic      no:1, next_line:1
#   standard   basic + ip_stride:1-4, spp_dev:1-4, va_ampm_lite:1-4
#   full       every binary in bin/
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Internal name → paper name mapping ──────────────────────────────────────
# Keys are the internal ChampSim binary names (from bin/champsim_*_d*).
# Values are the human-readable paper names used in config.sh PREFETCH_POLICIES.
# Each internal binary name maps to a distinct paper name.
# "stride" (PC-based) and "ip_stride" (IP-based) are DIFFERENT prefetchers.
# "va_ampm_lite" and "ampm" are DIFFERENT prefetchers.
declare -A INTERNAL_TO_PAPER=(
    ["no"]="no"
    ["next_line"]="next_line"
    ["ip_stride"]="ip_stride"
    ["va_ampm_lite"]="va_ampm_lite"
    ["spp_dev"]="spp_dev"
    ["stream"]="stream"
    ["stride"]="stride"
    ["ampm"]="ampm"
    ["power7"]="power7"
    ["sandbox"]="sandbox"
    ["sms"]="sms"
)

# Built at runtime: paper_to_internal[paper_name] → internal_name
declare -A paper_to_internal=()

# ─── Preset groups (comma-separated paper names) ────────────────────────────
declare -A PRESETS=(
    ["basic"]="no,next_line"
    ["paper"]="no,next_line,stride,stream,ampm,sms,bingo,sandbox,power7,dspatch,mlop,ppf"
    ["standard"]="no,next_line,stride,stream,ampm,sms,bingo,sandbox,power7,dspatch,mlop,ppf,ip_stride,va_ampm_lite,spp_dev"
    ["legacy"]="no,next_line,stride,stream"
    ["full"]="__ALL__"
)

# ─── CLI defaults ────────────────────────────────────────────────────────────
PREFETCHER_SPEC="${PREFETCHER_SPEC:-paper}"
BENCHMARK_LIST=""
STAGE="all"
JOBS="${JOBS:-4}"
DRY_RUN=false
CMD="run"          # run | status | check-build | clean

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)            CMD="status"; shift ;;
        --check-build)       CMD="check-build"; shift ;;
        --clean)             CMD="clean"; shift ;;
        --prefetchers)       PREFETCHER_SPEC="$2"; shift 2 ;;
        --benchmarks)        BENCHMARK_LIST="$2"; shift 2 ;;
        --stage)             STAGE="$2"; shift 2 ;;
        --jobs)              JOBS="$2"; shift 2 ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --help|-h)
            echo "Usage: $0 [--status|--check-build] [--prefetchers <spec>] [--benchmarks <list>] [--stage N] [--dry-run]"
            echo ""
            echo "Commands:"
            echo "  --status          Full status panel (benchmarks × stages)"
            echo "  --check-build     Prefetcher compilation check vs bin/"
            echo "  (default)         Run the profiling pipeline"
            echo ""
            echo "Options:"
            echo "  --prefetchers <spec>   e.g. \"no,next_line,stride,ampm\""
            echo "                         Presets: basic, paper (default), standard, full"
            echo "  --benchmarks <list>    Comma-separated (default: all with traces)"
            echo "  --stage N              Pipeline stage to run (default: all)"
            echo "  --jobs N               Concurrency (default: 4)"
            echo "  --dry-run              Preview without executing"
            exit 0
            ;;
        *) echo "Unknown option: $1 (try --help)"; exit 1 ;;
    esac
done

# ─── Resolve preset → prefetcher spec ────────────────────────────────────────
if [[ -n "${PRESETS[$PREFETCHER_SPEC]:-}" ]]; then
    PREFETCHER_SPEC="${PRESETS[$PREFETCHER_SPEC]}"
fi

# ─── Auto-discovery: scan bin/ for all champsim_<name>_d<degree> ─────────────
# Returns: discovered[paper_name]="d1,d2,..." (sorted, comma-separated)
#          internal_of[paper_name]="internal_name"
discover_binaries() {
    declare -gA discovered=() internal_of=() paper_to_internal=()
    local -A seen=()

    shopt -s nullglob
    for bin in "$CHAMPSIM_ROOT/bin/champsim_"*"_d"*; do
        local bname
        bname=$(basename "$bin")
        # Extract internal_name and degree from champsim_<name>_d<N>
        if [[ "$bname" =~ ^champsim_(.+)_d([0-9]+)$ ]]; then
            local iname="${BASH_REMATCH[1]}"
            local deg="${BASH_REMATCH[2]}"
            local pname="${INTERNAL_TO_PAPER[$iname]:-$iname}"

            internal_of["$pname"]="$iname"
            paper_to_internal["$pname"]="$iname"

            if [[ -z "${discovered[$pname]:-}" ]]; then
                discovered["$pname"]="$deg"
            else
                discovered["$pname"]="${discovered[$pname]},$deg"
            fi
            seen["$pname:$deg"]="$bin"
        fi
    done
    shopt -u nullglob

    # Sort degrees
    for key in "${!discovered[@]}"; do
        local sorted
        sorted=$(echo "${discovered[$key]}" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')
        discovered["$key"]="$sorted"
    done
}

# ─── Parse prefetcher spec → associative array pref_degrees[paper_name]="d1,d2,..." ──
# Accepts comma-separated prefetcher names. All available degrees are auto-discovered.
# Example: "no,next_line,ip_stride,spp_dev,va_ampm_lite"
parse_prefetcher_spec() {
    declare -gA pref_degrees=()
    local spec="$1"

    if [[ "$spec" == "__ALL__" ]]; then
        for pname in "${!discovered[@]}"; do
            pref_degrees["$pname"]="${discovered[$pname]}"
        done
        return
    fi

    set +u  # associative array access patterns conflict with nounset
    IFS=',' read -ra NAMES <<< "$spec" || true
    set -u

    for name in "${NAMES[@]}"; do
        name="${name## }"; name="${name%% }"
        [[ -z "$name" ]] && continue
        if [[ -n "${discovered[$name]:-}" ]]; then
            pref_degrees["$name"]="${discovered[$name]}"
        fi
    done

    if [[ ${#pref_degrees[@]} -eq 0 ]]; then
        echo "WARNING: No matching prefetcher binaries found for spec: $spec" >&2
        echo "  Available: ${!discovered[*]}" >&2
        echo "  Run --check-build to see full status." >&2
    fi
}

# ─── Resolve benchmark list ──────────────────────────────────────────────────
resolve_benchmarks() {
    declare -gA benchmarks=()
    if [[ -n "$BENCHMARK_LIST" ]]; then
        IFS=',' read -ra BLIST <<< "$BENCHMARK_LIST"
        for b in "${BLIST[@]}"; do
            b="${b## }"; b="${b%% }"
            local bdir="$DATA_ROOT/$b"
            if [[ -d "$bdir" ]] && ls "$bdir/traces/"*.champsimtrace.xz &>/dev/null; then
                benchmarks["$b"]="$bdir"
            fi
        done
    else
        for d in "$DATA_ROOT/"*/; do
            local b
            b=$(basename "$d")
            [[ "$b" == "batch_logs" || "$b" == "stage_3" || "$b" == "simpoints" ]] && continue
            if ls "$d/traces/"*.champsimtrace* &>/dev/null 2>&1; then
                benchmarks["$b"]="$d"
            fi
        done
    fi
}

# ─── Per-benchmark stage completion check ────────────────────────────────────
check_benchmark_stages() {
    local bdir="$1"
    local simpoints="$bdir/simpoints.json"
    local disasm="$bdir/disasm_index.json"
    local traces_dir="$bdir/traces"
    local profiling_dir="$bdir/profiling"
    local asm_ctx="$bdir/assembly_context.jsonl"
    local ground_truth="$bdir/ground_truth.jsonl"
    local tuning="$bdir/tuning_dataset.jsonl"

    local s1="-" s2="-" s3="-" s4="-" s5="-" s6="-" s7="-"

    # Stage 1: simpoints.json
    [[ -f "$simpoints" ]] && s1="✓"

    # Stage 2: disasm_index.json
    [[ -f "$disasm" ]] && s2="✓"

    # Stage 3: traces — count ready (.xz >1KB) vs recording (raw) vs bad (<1KB) vs expected
    local ready=0 expect=0 recording=0 bad=0
    if [[ -d "$traces_dir" ]]; then
        for f in "$traces_dir"/*.champsimtrace.xz; do
            [[ -f "$f" ]] || continue
            fsize=$(stat -c %s "$f" 2>/dev/null || echo 0)
            if [ "$fsize" -lt 1024 ]; then
                ((bad++))
            else
                ((ready++))
            fi
        done 2>/dev/null
        for f in "$traces_dir"/*.champsimtrace; do
            [[ -f "$f" ]] && [[ "$f" != *.xz ]] && ((recording++))
        done 2>/dev/null
    fi
    if [[ -f "$simpoints" ]]; then
        expect=$(python3 -c "
import json
d=json.load(open('$simpoints'))
print(sum(1 for e in d if e['weight']>=0.01))
" 2>/dev/null)
    fi
    local tracing_active=false
    if [[ "$recording" -gt 0 ]]; then
        tracing_active=true
    fi

    if [[ "$expect" -gt 0 ]]; then
        if $tracing_active; then
            s3="$ready+$recording/$expect"
        elif [[ "$ready" -ge "$expect" ]]; then
            s3="$ready/$expect"
        elif [[ "$ready" -gt 0 ]]; then
            s3="$ready/$expect"
        else
            s3="$ready/$expect"
        fi
        if [[ "$bad" -gt 0 ]]; then
            s3="$s3 B$bad"
        fi
    fi

    # Stage 4: profiling outputs — count valid (non-empty) vs empty
    local pcount=0 pempty=0
    if [[ -d "$profiling_dir" ]]; then
        for f in "$profiling_dir"/*.json; do
            [[ -f "$f" ]] || continue
            if [[ -s "$f" ]]; then
                ((pcount++))
            else
                ((pempty++))
            fi
        done 2>/dev/null
        local ptotal=$((pcount + pempty))
        if [[ "$ptotal" -gt 0 ]]; then
            s4="${pcount}"
            if [[ "$pempty" -gt 0 ]]; then
                s4="${s4} B$pempty"
            fi
        else
            s4="-"
        fi
    else
        s4="-"
    fi

    # Stage 5: assembly_context.jsonl
    if [[ -f "$asm_ctx" ]]; then
        s5="✓"
    else
        s5="-"
    fi

    # Stage 6: ground_truth.jsonl
    if [[ -f "$ground_truth" ]]; then
        s6="✓"
    else
        s6="-"
    fi

    # Stage 7: tuning_dataset.jsonl
    if [[ -f "$tuning" ]]; then
        s7="✓"
    else
        s7="-"
    fi

    echo "$s1|$s2|$s3|$s4|$s5|$s6|$s7|$ready|$expect|$recording|$pcount|$pempty"
}

# ══════════════════════════════════════════════════════════════════════════════
# COMMAND: --check-build
# ══════════════════════════════════════════════════════════════════════════════
cmd_check_build() {
    discover_binaries

    echo "=== Prefetcher Compilation Status ==="
    echo ""
    printf "%-18s %-22s %-20s %s\n" "Paper Name" "Internal Bin Name" "Configured (config.sh)" "Built (bin/)"
    printf "%-18s %-22s %-20s %s\n" "------------------" "----------------------" "--------------------" "--------------------"

    local all_pnames=()
    # Collect from config.sh PREFETCH_POLICIES + discovered binaries
    for entry in "${PREFETCH_POLICIES[@]}"; do
        IFS=':' read -r pname degrees <<< "$entry"
        all_pnames+=("$pname")
    done
    for pname in "${!discovered[@]}"; do
        [[ " ${all_pnames[*]} " =~ " ${pname} " ]] || all_pnames+=("$pname")
    done

    for pname in "${all_pnames[@]}"; do
        local iname="${paper_to_internal[$pname]:-$pname}"
        local cfg_degrees=""
        local built_degrees="${discovered[$pname]:-}"

        # Find config.sh entry
        for entry in "${PREFETCH_POLICIES[@]}"; do
            IFS=':' read -r ep edeg <<< "$entry"
            if [[ "$ep" == "$pname" ]]; then
                cfg_degrees="$edeg"
                break
            fi
        done

        local cfg_disp="${cfg_degrees:--}"
        local built_disp="${built_degrees:--}"

        # Highlight mismatches
        local flag="  "
        if [[ -n "$cfg_degrees" && -n "$built_degrees" ]]; then
            # Check if built has all configured degrees
            local all_found=true
            IFS=',' read -ra CFG_DEGS <<< "$cfg_degrees"
            for cdg in "${CFG_DEGS[@]}"; do
                if [[ ! ",$built_degrees," =~ ",$cdg," ]]; then
                    all_found=false
                    break
                fi
            done
            $all_found || flag="❲-❳"
        elif [[ -n "$cfg_degrees" && -z "$built_degrees" ]]; then
            flag="❲✗❳"
        elif [[ -z "$cfg_degrees" && -n "$built_degrees" ]]; then
            flag="❲+❳"
        fi

        printf "%-18s %-22s %-20s %s %s\n" "$pname" "$iname" "$cfg_disp" "$built_disp" "$flag"
    done

    echo ""
    echo "Legend:  ❲✗❳=not built  ❲-❳=partial  ❲+❳=extra (no config.sh entry)"
}

# ══════════════════════════════════════════════════════════════════════════════
# COMMAND: --status
# ══════════════════════════════════════════════════════════════════════════════
cmd_status() {
    discover_binaries
    resolve_benchmarks

    echo "=== Profiling Pipeline Status — $(date '+%Y-%m-%d %H:%M:%S') ==="
    echo ""
    echo "Prefetchers available (paper preset, default):"
    parse_prefetcher_spec "${PRESETS[paper]}"
    for pname in "${!pref_degrees[@]}"; do
        local iname="${internal_of[$pname]:-$pname}"
        echo "  $pname ($iname): degrees ${pref_degrees[$pname]}"
    done
    echo ""

    printf "%-18s %5s %5s %8s %8s %4s %4s %4s  %-10s\n" \
        "Benchmark" "S1" "S2" "S3" "S4" "S5" "S6" "S7" "Status"
    printf "%-18s %5s %5s %8s %8s %4s %4s %4s  %-10s\n" \
        "------------------" "-----" "-----" "--------" "--------" "----" "----" "----" "----------"

    for b in $(printf '%s\n' "${!benchmarks[@]}" | sort); do
        local bdir="${benchmarks[$b]}"
        IFS='|' read -r s1 s2 s3 s4 s5 s6 s7 ready expect recording pcount pempty <<< "$(check_benchmark_stages "$bdir")"

        # Determine overall status using the numeric counts
        local status="PENDING"
        if [[ "$recording" -gt 0 ]]; then
            status="TRACING"
        elif [[ "$s7" == "✓" ]]; then
            status="COMPLETE"
        elif pgrep -f "champsim_.*$(basename "$bdir")" &>/dev/null; then
            status="PROFILING"
        elif [[ "$s4" != "-" ]] && [[ "$pcount" -gt 0 ]]; then
            status="PROFILING"
        elif [[ "$expect" -gt 0 ]] && [[ "$ready" -lt "$expect" ]]; then
            status="NEED_TRACE"
        elif [[ "$expect" -gt 0 ]] && [[ "$ready" -ge "$expect" ]]; then
            status="READY"
        elif [[ "$expect" -gt 0 ]]; then
            status="NO_TRACES"
        fi

        printf "%-18s %5s %5s %8s %8s %4s %4s %4s  %-10s\n" \
            "$b" "$s1" "$s2" "$s3" "$s4" "$s5" "$s6" "$s7" "$status"
    done

    # Show benchmarks that exist as dirs but have no traces
    echo ""
    echo "--- Without traces ---"
    for d in "$DATA_ROOT/"*/; do
        local b
        b=$(basename "$d")
        [[ "$b" == "batch_logs" || "$b" == "stage_3" || "$b" == "simpoints" ]] && continue
        if [[ -n "${benchmarks[$b]:-}" ]]; then continue; fi
        local tdir="$d/traces"
        local raw=0
        for f in "$tdir"/*.champsimtrace; do [[ -f "$f" ]] && [[ "$f" != *.xz ]] && ((raw++)); done 2>/dev/null
        local ready=0
        for f in "$tdir"/*.xz; do [[ -f "$f" ]] && ((ready++)); done 2>/dev/null
        if [[ "$raw" -gt 0 ]]; then
            printf "  %-18s  %d recording, %d ready\n" "$b" "$raw" "$ready"
        else
            printf "  %-18s  (empty)\n" "$b"
        fi
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# COMMAND: run (default) — execute pipeline for selected prefetchers
# ══════════════════════════════════════════════════════════════════════════════
cmd_run() {
    discover_binaries
    parse_prefetcher_spec "$PREFETCHER_SPEC"
    resolve_benchmarks

    if [[ ${#pref_degrees[@]} -eq 0 ]]; then
        echo "ERROR: No valid prefetcher+degree combinations found."
        echo "  Spec: $PREFETCHER_SPEC"
        echo "  Run --check-build to see what's available."
        exit 1
    fi

    echo "=== Profiling Controller ==="
    echo "  Prefetchers:"
    for pname in "${!pref_degrees[@]}"; do
        echo "    $pname → degrees ${pref_degrees[$pname]}"
    done
    echo "  Benchmarks (${#benchmarks[@]}): ${!benchmarks[*]}"
    echo "  Stage: $STAGE"
    echo "  Jobs: $JOBS"
    echo "  Dry-run: $DRY_RUN"
    echo ""

    # Export the chosen prefetcher spec for run_pipeline.sh to consume
    export PROFILING_PREFETCHERS="${!pref_degrees[*]}"
    export PROFILING_PREFETCHER_DEGREES
    # Serialize pref_degrees for subprocess
    PROFILING_PREFETCHER_DEGREES=""
    for pname in "${!pref_degrees[@]}"; do
        PROFILING_PREFETCHER_DEGREES="${PROFILING_PREFETCHER_DEGREES}${pname}:${pref_degrees[$pname]};"
    done

    total=${#benchmarks[@]}
    done_count=0
    failed=()

    for b in $(printf '%s\n' "${!benchmarks[@]}" | sort); do
        ((done_count++)) || true
        echo ""
        echo "======================================================================"
        echo "[$done_count/$total] $b (stage=$STAGE)"
        echo "======================================================================"

        local pipeline="$SCRIPT_DIR/run_pipeline.sh"

        if $DRY_RUN; then
            bash "$pipeline" "$b" --stage "$STAGE" --jobs "$JOBS" --dry-run 2>&1 || true
        else
            if JOBS="$JOBS" bash "$pipeline" "$b" --stage "$STAGE" 2>&1; then
                echo "[$done_count/$total] $b: DONE"
            else
                echo "[$done_count/$total] $b: FAILED (exit code $?)"
                failed+=("$b")
            fi
        fi
    done

    echo ""
    echo "=== All benchmarks processed ==="
    echo "  Done: $((total - ${#failed[@]}))/$total"
    if [[ ${#failed[@]} -gt 0 ]]; then
        echo "  Failed: ${failed[*]}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# COMMAND: --clean — remove bad (empty/invalid) output files
# ══════════════════════════════════════════════════════════════════════════════
cmd_clean() {
    echo "=== Cleaning bad files ==="
    echo ""

    local total_removed=0
    for d in "$DATA_ROOT/"*/; do
        b=$(basename "$d")
        [[ "$b" == "batch_logs" || "$b" == "stage_3" || "$b" == "simpoints" ]] && continue
        local removed=0

        # S3: remove traces < 1KB compressed
        if [[ -d "$d/traces" ]]; then
            for f in "$d/traces/"*.champsimtrace.xz; do
                [[ -f "$f" ]] || continue
                fsize=$(stat -c %s "$f" 2>/dev/null || echo 0)
                if [ "$fsize" -lt 1024 ]; then
                    echo "  rm trace: $f ($fsize bytes)"
                    rm -f "$f"
                    ((removed++)) || true
                fi
            done 2>/dev/null
        fi

        # S4: remove empty profiling JSONs
        if [[ -d "$d/profiling" ]]; then
            for f in "$d/profiling/"*.json; do
                [[ -f "$f" ]] || continue
                if [[ ! -s "$f" ]]; then
                    echo "  rm empty: $f"
                    rm -f "$f"
                    ((removed++)) || true
                fi
            done 2>/dev/null
        fi

        # S5: remove empty load_pcs.json / assembly_context.jsonl
        for fname in load_pcs.json assembly_context.jsonl; do
            f="$d/$fname"
            if [[ -f "$f" ]] && [[ ! -s "$f" ]]; then
                echo "  rm empty: $f"
                rm -f "$f"
                ((removed++)) || true
            fi
        done

        # S6: remove empty ground_truth.jsonl
        if [[ -f "$d/ground_truth.jsonl" ]] && [[ ! -s "$d/ground_truth.jsonl" ]]; then
            echo "  rm empty: $d/ground_truth.jsonl"
            rm -f "$d/ground_truth.jsonl"
            ((removed++)) || true
        fi

        # S7: remove empty tuning_dataset.jsonl
        if [[ -f "$d/tuning_dataset.jsonl" ]] && [[ ! -s "$d/tuning_dataset.jsonl" ]]; then
            echo "  rm empty: $d/tuning_dataset.jsonl"
            rm -f "$d/tuning_dataset.jsonl"
            ((removed++)) || true
        fi

        if [[ "$removed" -gt 0 ]]; then
            echo "  → $b: removed $removed file(s)"
            total_removed=$((total_removed + removed))
        fi
    done

    echo ""
    echo "Total removed: $total_removed file(s)"
}

# ══════════════════════════════════════════════════════════════════════════════
# Main dispatch
# ══════════════════════════════════════════════════════════════════════════════
case "$CMD" in
    status)      cmd_status ;;
    check-build) cmd_check_build ;;
    clean)       cmd_clean ;;
    run)         cmd_run ;;
esac
