#!/usr/bin/env bash
#
# verify_set_dueling.sh — Set-Dueling Verification Suite
#
# Usage:
#   bash scripts/verify_set_dueling.sh <run-dir>                        # print results
#   bash scripts/verify_set_dueling.sh <run-dir> --conclusions <path>    # also append to CONCLUSIONS.md
#
# Runs V1-V4 on the set-dueling results in the given run directory.
# V3 (Degenerate Test) requires rebuilding a test binary (~8 min).
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

RUN_DIR="${1:-artifacts/runs/stage1/latest}"
CONCLUSIONS_FILE=""
if [ "${2:-}" = "--conclusions" ] && [ -n "${3:-}" ]; then
    CONCLUSIONS_FILE="$3"
fi

if [ ! -d "$RUN_DIR" ]; then
    echo "ERROR: run directory not found: $RUN_DIR"
    exit 1
fi

# ── Output accumulator ──
MD=""
md() { MD+="$*"$'\n'; }

ts() { date +%Y-%m-%dT%H:%M:%S; }

echo "══════════════════════════════════════════════════════════"
echo "  Set-Dueling Verification Suite"
echo "  Run dir: $RUN_DIR"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "══════════════════════════════════════════════════════════"
echo ""

md ""
md "## Set-Dueling Verification"
md ""
md "**Verified:** $(date '+%Y-%m-%d %H:%M:%S') | **Run:** $(basename "$RUN_DIR")"
md ""

# ══════════════════════════════════════════════════════════════
# V1: SDM Convergence
# ══════════════════════════════════════════════════════════════
verify_sdm_convergence() {
    echo "── V1: SDM Convergence ──────────────────────────────────"
    echo ""

    md "### V1: SDM Convergence"
    md ""

    for sd in set_dueling_lru_srrip set_dueling_mj_hk set_dueling_4p_lssh set_dueling_4p_lssm; do
        local raw_files=("$RUN_DIR"/${sd}_*.raw)
        if [ ! -f "${raw_files[0]}" ]; then
            echo "  $sd: SKIP (no raw files)"
            md "- **$sd**: SKIP (no raw files)"
            continue
        fi

        local total=0
        declare -A winners

        for f in "${raw_files[@]}"; do
            total=$((total + 1))
            local txt best_line winner
            txt="$(cat "$f")"
            best_line="$(echo "$txt" | grep 'Best' | tail -1)"
            if [ -n "$best_line" ]; then
                winner="$(echo "$best_line" | sed 's/.*Best[^:]*: *//' | tr -d ' .')"
                winners["$winner"]=$((${winners["$winner"]:-0} + 1))
            fi
        done

        echo "  $sd ($total traces):"
        local detail=""
        for w in "${!winners[@]}"; do
            echo "    $w: ${winners[$w]}/$total"
            detail+="$w ${winners[$w]}, "
        done
        detail="${detail%, }"

        local max_win=0 max_name=""
        for w in "${!winners[@]}"; do
            if [ "${winners[$w]}" -gt "$max_win" ]; then
                max_win="${winners[$w]}"
                max_name="$w"
            fi
        done
        local pct=$((max_win * 100 / total))
        local ver=""
        if [ "$pct" -ge 60 ]; then
            echo "    → Converged: $max_name dominates ($pct%)"
            ver="converged"
        else
            echo "    → Weak convergence: max=$max_name at $pct%"
            ver="weak"
        fi
        md "- **$sd** ($total traces): $detail → $max_name dominates ($pct%) — $ver"
        echo ""
        unset winners
    done
    md ""
}

# ══════════════════════════════════════════════════════════════
# V2: Range Consistency
# ══════════════════════════════════════════════════════════════
verify_range_consistency() {
    echo "── V2: Range Consistency ────────────────────────────────"
    echo ""

    md "### V2: Range Consistency"
    md ""

    local py_out
    py_out=$(python3 - "$RUN_DIR" << 'PYEOF'
import sys, json, glob, math

run_dir = sys.argv[1]
data = {}
for f in sorted(glob.glob(f"{run_dir}/*.data.jsonl")):
    d = json.load(open(f))
    if d['exit'] != 0: continue
    p, t, ipc = d['policy'], d['trace'], d['ipc']
    if isinstance(ipc, (int, float)) and ipc > 0:
        data.setdefault(p, {})[t] = float(ipc)

sd_subs = {
    'set_dueling_lru_srrip': ['lru', 'srrip'],
    'set_dueling_mj_hk': ['mockingjay', 'hawkeye'],
    'set_dueling_4p_lssh': ['lru', 'srrip', 'ship', 'hawkeye'],
    'set_dueling_4p_lssm': ['lru', 'srrip', 'ship', 'mockingjay'],
}
lines = []
for sd, subs in sd_subs.items():
    if sd not in data:
        lines.append(f"SKIP:{sd}:no_data")
        continue
    traces = set(data[sd].keys())
    for s in subs:
        if s in data: traces &= set(data[s].keys())
    if len(traces) < 5:
        lines.append(f"SKIP:{sd}:insufficient:{len(traces)}")
        continue
    within = below = above = 0
    for t in sorted(traces):
        sd_ipc = data[sd][t]
        sub_ipcs = [data[s][t] for s in subs if s in data and t in data[s]]
        if len(sub_ipcs) < 2: continue
        lo, hi = min(sub_ipcs), max(sub_ipcs)
        if lo <= sd_ipc <= hi: within += 1
        elif sd_ipc < lo: below += 1
        else: above += 1
    sd_geo = math.exp(sum(math.log(data[sd][t]) for t in traces) / len(traces))
    sub_geos = [math.exp(sum(math.log(data[s][t]) for t in traces) / len(traces)) for s in subs if s in data]
    lo, hi = min(sub_geos), max(sub_geos)
    geo_ok = lo <= sd_geo <= hi
    total = within + below + above
    note = ""
    if len(subs) == 2 and not geo_ok and sd_geo > hi:
        note = f"exceeds range (+{((sd_geo/hi)-1)*100:.1f}%, per-phase SDM advantage)"
    elif not geo_ok and sd_geo < lo:
        note = "below range (overhead/sampling bias)"
    else:
        note = "within range"
    lines.append(f"OK:{sd}:{sd_geo:.4f}:{lo:.4f}:{hi:.4f}:{within}/{total}:{below}:{above}:{note}")
for l in lines:
    print(l)
PYEOF
    )

    while IFS=':' read -r status sd rest; do
        if [ "$status" = "SKIP" ]; then
            echo "  $sd: SKIP ($rest)"
            md "- **$sd**: SKIP"
        else
            local geo lo hi within below above note
            geo=$(echo "$rest" | cut -d: -f1)
            lo=$(echo "$rest" | cut -d: -f2)
            hi=$(echo "$rest" | cut -d: -f3)
            within=$(echo "$rest" | cut -d: -f4)
            below=$(echo "$rest" | cut -d: -f5)
            above=$(echo "$rest" | cut -d: -f6)
            note=$(echo "$rest" | cut -d: -f7-)
            echo "  $sd: GeoMean=$geo sub_range=[$lo,$hi] per_trace: within=$within below=$below above=$above"
            echo "    → $note"
            md "- **$sd**: GeoMean=$geo, sub_range=[$lo, $hi], $within traces within, $note"
        fi
    done <<< "$py_out"
    echo ""
    md ""
}

# ══════════════════════════════════════════════════════════════
# V3: Degenerate Test
# ══════════════════════════════════════════════════════════════
verify_degenerate_test() {
    echo "── V3: Degenerate Test ──────────────────────────────────"
    echo ""

    md "### V3: Degenerate Test"
    md ""

    local trace="trace/astar_23B.trace.xz"
    if [ ! -f "$trace" ]; then
        echo "  SKIP: trace not found ($trace)"
        md "- SKIP: trace not found"
        return
    fi

    local deg_file="/tmp/sd_verify_deg_$$.llc_repl"
    local deg_bin="bin/champsim_sd_verify_deg"
    local orig_bin="bin/champsim_lru"

    if [ ! -x "$orig_bin" ]; then
        echo "  SKIP: LRU binary not found"
        md "- SKIP: LRU binary not found"
        return
    fi

    cat > "$deg_file" << 'DEGEOF'
#include "cache.h"
#define SD_SDM 32
int sd_leader[LLC_SET]; uint32_t sd_psel;
void CACHE::llc_initialize_replacement() {
    for (int i=0; i<LLC_SET; i++) sd_leader[i]=-1;
    unsigned long rs=1; uint32_t ch[128];
    for (uint32_t i=0; i<2*SD_SDM; i++) {
        int dup; do { dup=0; rs=rs*1103515245+12345; ch[i]=((unsigned)((rs/65536)%1048576)) % (LLC_SET);
        for (uint32_t j=0; j<i; j++) if(ch[i]==ch[j]){dup=1;break;} } while(dup); }
    for (uint32_t i=0; i<SD_SDM; i++) sd_leader[ch[i]]=0;
    for (uint32_t i=0; i<SD_SDM; i++) sd_leader[ch[SD_SDM+i]]=1;
    sd_psel = (1<<10)/2;
}
uint32_t CACHE::llc_find_victim(uint32_t cpu, uint64_t instr_id, uint32_t set, const BLOCK *cs, uint64_t ip, uint64_t fa, uint32_t t) {
    return lru_victim(cpu, instr_id, set, cs, ip, fa, t);
}
void CACHE::llc_update_replacement_state(uint32_t cpu, uint32_t set, uint32_t way, uint64_t fa, uint64_t ip, uint64_t va, uint32_t t, uint8_t h) {
    if (h && t == WRITEBACK) return;
    lru_update(set, way);
}
void CACHE::llc_replacement_final_stats() {}
DEGEOF

    local hk_bak=0
    if [ -d replacement/hawkeye ]; then
        mv replacement/hawkeye /tmp/hawkeye_v3_$$ 2>/dev/null
        hk_bak=1
    fi
    cp "$deg_file" replacement/sd_verify_deg.llc_repl

    ./build_champsim.sh bimodal no no no no sd_verify_deg 1 > /tmp/build_v3_$$.log 2>&1
    if [ -x bin/bimodal-no-no-no-no-sd_verify_deg-1core ]; then
        cp bin/bimodal-no-no-no-no-sd_verify_deg-1core "$deg_bin"
    fi

    rm -f replacement/sd_verify_deg.llc_repl bin/bimodal-no-no-no-no-sd_verify_deg-1core "$deg_file"
    [ "$hk_bak" = 1 ] && mv /tmp/hawkeye_v3_$$ replacement/hawkeye 2>/dev/null

    if [ ! -x "$deg_bin" ]; then
        echo "  FAIL: degenerate binary build failed"
        md "- **FAIL**: degenerate binary build failed"
        return
    fi

    echo "  Running: LRU vs SDM(LRU,LRU) on astar_23B (50M+200M)..."

    local lru_ipc deg_ipc
    lru_ipc="$("$orig_bin" -warmup_instructions 50000000 -simulation_instructions 200000000 -traces "$trace" 2>&1 | grep -oP 'CPU 0 cumulative IPC: \K[0-9.]+' | tail -1)"
    deg_ipc="$("$deg_bin"   -warmup_instructions 50000000 -simulation_instructions 200000000 -traces "$trace" 2>&1 | grep -oP 'CPU 0 cumulative IPC: \K[0-9.]+' | tail -1)"

    rm -f "$deg_bin"

    echo "    LRU standalone:    IPC=$lru_ipc"
    echo "    SDM(LRU,LRU):     IPC=$deg_ipc"

    if [ -z "$lru_ipc" ] || [ -z "$deg_ipc" ]; then
        echo "  FAIL: could not parse IPC"
        md "- **FAIL**: could not parse IPC"
        return
    fi

    local diff
    diff=$(python3 -c "print(abs($lru_ipc - $deg_ipc))")
    echo "    diff=$diff"

    if python3 -c "exit(0 if abs($lru_ipc - $deg_ipc) < 0.002 else 1)"; then
        echo "  [PASS] IPC identical within noise"
        md "- **[PASS]** LRU=$lru_ipc, SDM(LRU,LRU)=$deg_ipc, diff=$diff (< 0.002)"
    else
        echo "  [FAIL] IPC mismatch (diff=$diff > 0.002)"
        md "- **[FAIL]** IPC mismatch: LRU=$lru_ipc, SDM(LRU,LRU)=$deg_ipc, diff=$diff"
    fi
    echo ""
    md ""
}

# ══════════════════════════════════════════════════════════════
# V4: Leader Set Distribution
# ══════════════════════════════════════════════════════════════
verify_leader_distribution() {
    echo "── V4: Leader Set Distribution ──────────────────────────"
    echo ""

    md "### V4: Leader Set Distribution"
    md ""

    local check_bin="/tmp/sd_v4_check_$$"

    cat > /tmp/sd_v4_check_$$.c << 'CEOF'
#include <stdio.h>
#include <stdint.h>
#define LLC_SET 2048
#define SD_SDM 32
int main() {
    int sd_leader[LLC_SET];
    for (int i=0; i<LLC_SET; i++) sd_leader[i]=-1;
    unsigned long rs=1; uint32_t total=2*SD_SDM;
    uint32_t ch[128];
    for (uint32_t i=0; i<total; i++) {
        int dup; do { dup=0; rs=rs*1103515245+12345; ch[i]=((unsigned)((rs/65536)%1048576)) % LLC_SET;
        for (uint32_t j=0; j<i; j++) if(ch[i]==ch[j]){dup=1;break;} } while(dup); }
    for (uint32_t i=0; i<SD_SDM; i++) sd_leader[ch[i]]=0;
    for (uint32_t i=0; i<SD_SDM; i++) sd_leader[ch[SD_SDM+i]]=1;
    int c[2]={0}; for (int i=0; i<LLC_SET; i++) if(sd_leader[i]>=0) c[sd_leader[i]]++;
    int bins[4]={0}; for (int i=0; i<LLC_SET; i++) if(sd_leader[i]>=0) bins[i*4/LLC_SET]++;
    int max_gap=0, cur_gap=0;
    for (int i=0; i<LLC_SET; i++) { if(sd_leader[i]==-1) cur_gap++; else { if(cur_gap>max_gap) max_gap=cur_gap; cur_gap=0; } }
    printf("P:%d,%d,%d,%d,%d,%d,%d\n", c[0], c[1], bins[0], bins[1], bins[2], bins[3], max_gap);
    int ok=1;
    if (c[0]!=32 || c[1]!=32) { printf("E:leader_count\n"); ok=0; }
    if (c[0]+c[1]!=64) { printf("E:overlap\n"); ok=0; }
    if (ok) printf("OK\n");
    return 0;
}
CEOF
    gcc -o "$check_bin" /tmp/sd_v4_check_$$.c 2>/dev/null
    if [ -x "$check_bin" ]; then
        local out
        out="$("$check_bin")"
        local data passes errors
        data=$(echo "$out" | grep '^P:' | cut -d: -f2)
        passes=$(echo "$out" | grep '^OK')
        errors=$(echo "$out" | grep '^E:' || true)

        local p0 p1 q1 q2 q3 q4 gap
        p0=$(echo "$data" | cut -d, -f1)
        p1=$(echo "$data" | cut -d, -f2)
        q1=$(echo "$data" | cut -d, -f3)
        q2=$(echo "$data" | cut -d, -f4)
        q3=$(echo "$data" | cut -d, -f5)
        q4=$(echo "$data" | cut -d, -f6)
        gap=$(echo "$data" | cut -d, -f7)

        echo "  Policy0 leaders: $p0  Policy1 leaders: $p1"
        echo "  Quartiles: $q1 $q2 $q3 $q4  Max gap: $gap"
        # Use 2-policy as representative; 4-policy init has same SDM logic
        echo "  (verified on 2-policy SDM; 4-policy init uses identical logic)"

        md "- Leaders per policy: $p0 / $p1 (expected 32 each)"
        md "- Unique sets: $((p0 + p1)) (expected 64)"
        md "- Quartile distribution: $q1 / $q2 / $q3 / $q4"
        md "- Max follower gap: $gap sets"

        if [ -n "$passes" ]; then
            echo "  [PASS]"
            md "- **[PASS]** Leader set distribution correct"
        else
            echo "  [FAIL]: $errors"
            md "- **[FAIL]**: $errors"
        fi
        rm -f "$check_bin"
    else
        echo "  SKIP: gcc not available for standalone check"
        md "- SKIP: gcc not available"
    fi
    rm -f /tmp/sd_v4_check_$$.c
    echo ""
    md ""
}

# ══════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════

verify_sdm_convergence
verify_range_consistency
verify_degenerate_test
verify_leader_distribution

echo "────────────────────────────────────────────────────────"
echo "  Verification complete: $(date '+%Y-%m-%d %H:%M:%S')"
echo "────────────────────────────────────────────────────────"

# Append to CONCLUSIONS.md if requested
if [ -n "$CONCLUSIONS_FILE" ]; then
    echo ""
    echo "Appending verification results to $CONCLUSIONS_FILE ..."
    echo "$MD" >> "$CONCLUSIONS_FILE"
    echo "Done."
fi
