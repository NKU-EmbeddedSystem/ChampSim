#!/bin/bash

# =========================================================================
# ChampSim 并行正交实验脚本 (24 configs)
#
# 实验维度:
#   - 预取器:    NoPref | L2Only (ip_stride) | L1DOnly (ipcp) | L1L2 (both)
#   - 替换策略:  LRU | Mockingjay | RPP
#   - 带宽:      Normal (6.4 GB/s) | LowBw (1.6 GB/s)
#   共 4 × 3 × 2 = 24 种配置
#
# 用法: ./run_experiments.sh [并发数]
# 示例: ./run_experiments.sh 4
# =========================================================================

set -e

# =========================================================================
# 参数解析
# =========================================================================
CONCURRENCY=${1:-4}
if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || [ "$CONCURRENCY" -lt 1 ]; then
    echo "错误: 并发数必须是正整数"
    echo "用法: $0 [并发数]"
    exit 1
fi

# =========================================================================
# 实验参数配置
# =========================================================================
WARMUP_INSTR=5000000
SIM_INSTR=50000000
OUT_DIR="results-analy-CXL-2"
LOG_DIR="${OUT_DIR}/logs"
TRACE_DIR="traces"
BIN_DIR="bin"
RESULT_FILE="${OUT_DIR}/unified_results.txt"
DETAIL_FILE="${OUT_DIR}/rpp_detailed_metrics.txt"

# =========================================================================
# 全部 24 个二进制文件及其标签
#
# 命名规则: bimodal-no-{L1D_pref}-{L2C_pref}-no-{repl}-1core[-lowbw]
#   L1D_pref:  no | ipcp         (position 3 = L1D_PREFETCHER in build_champsim.sh)
#   L2C_pref:  no | ip_stride    (position 4 = L2C_PREFETCHER in build_champsim.sh)
#   repl:     lru | mockingjay | rpp
#   lowbw:    带宽受限 (1.6 GB/s CXL), 不带为正常带宽 (6.4 GB/s)
# =========================================================================
declare -A BIN_LABELS
BIN_LABELS=(
    # ==================== NoPref (无预取) ====================
    # --- Normal bandwidth ---
    ["bimodal-no-no-no-no-lru-1core"]="NoPref-LRU"
    ["bimodal-no-no-no-no-mockingjay-1core"]="NoPref-Mockingjay"
    ["bimodal-no-no-no-no-rpp-1core"]="NoPref-RPP"
    # --- Low bandwidth ---
    ["bimodal-no-no-no-no-lru-1core-lowbw"]="NoPref-LRU-lowbw"
    ["bimodal-no-no-no-no-mockingjay-1core-lowbw"]="NoPref-Mockingjay-lowbw"
    ["bimodal-no-no-no-no-rpp-1core-lowbw"]="NoPref-RPP-lowbw"

    # ==================== L1DOnly (L1D IPCP 预取) ====================
    # --- Normal bandwidth ---
    ["bimodal-no-ipcp-no-no-lru-1core"]="L1DOnly-LRU"
    ["bimodal-no-ipcp-no-no-mockingjay-1core"]="L1DOnly-Mockingjay"
    ["bimodal-no-ipcp-no-no-rpp-1core"]="L1DOnly-RPP"
    # --- Low bandwidth ---
    ["bimodal-no-ipcp-no-no-lru-1core-lowbw"]="L1DOnly-LRU-lowbw"
    ["bimodal-no-ipcp-no-no-mockingjay-1core-lowbw"]="L1DOnly-Mockingjay-lowbw"
    ["bimodal-no-ipcp-no-no-rpp-1core-lowbw"]="L1DOnly-RPP-lowbw"

    # ==================== L2Only (L2 IP_stride 预取) ====================
    # --- Normal bandwidth ---
    ["bimodal-no-no-ip_stride-no-lru-1core"]="L2Only-LRU"
    ["bimodal-no-no-ip_stride-no-mockingjay-1core"]="L2Only-Mockingjay"
    ["bimodal-no-no-ip_stride-no-rpp-1core"]="L2Only-RPP"
    # --- Low bandwidth ---
    ["bimodal-no-no-ip_stride-no-lru-1core-lowbw"]="L2Only-LRU-lowbw"
    ["bimodal-no-no-ip_stride-no-mockingjay-1core-lowbw"]="L2Only-Mockingjay-lowbw"
    ["bimodal-no-no-ip_stride-no-rpp-1core-lowbw"]="L2Only-RPP-lowbw"

    # ==================== L1L2 (L1D + L2 预取) ====================
    # --- Normal bandwidth ---
    ["bimodal-no-ipcp-ip_stride-no-lru-1core"]="L1L2-LRU"
    ["bimodal-no-ipcp-ip_stride-no-mockingjay-1core"]="L1L2-Mockingjay"
    ["bimodal-no-ipcp-ip_stride-no-rpp-1core"]="L1L2-RPP"
    # --- Low bandwidth ---
    ["bimodal-no-ipcp-ip_stride-no-lru-1core-lowbw"]="L1L2-LRU-lowbw"
    ["bimodal-no-ipcp-ip_stride-no-mockingjay-1core-lowbw"]="L1L2-Mockingjay-lowbw"
    ["bimodal-no-ipcp-ip_stride-no-rpp-1core-lowbw"]="L1L2-RPP-lowbw"
)

# 运行顺序: 按 Pref × BW × Repl 排列, 每组 3 个 (LRU, Mockingjay, RPP)
# 组结构: [LRU=baseline, Mockingjay, RPP]
BINARIES=(
    # --- NoPref (无预取) ---
    # Normal bandwidth
    "bimodal-no-no-no-no-lru-1core"
    "bimodal-no-no-no-no-mockingjay-1core"
    "bimodal-no-no-no-no-rpp-1core"
    # Low bandwidth
    "bimodal-no-no-no-no-lru-1core-lowbw"
    "bimodal-no-no-no-no-mockingjay-1core-lowbw"
    "bimodal-no-no-no-no-rpp-1core-lowbw"

    # --- L1DOnly (L1D IPCP) ---
    # Normal bandwidth
    "bimodal-no-ipcp-no-no-lru-1core"
    "bimodal-no-ipcp-no-no-mockingjay-1core"
    "bimodal-no-ipcp-no-no-rpp-1core"
    # Low bandwidth
    "bimodal-no-ipcp-no-no-lru-1core-lowbw"
    "bimodal-no-ipcp-no-no-mockingjay-1core-lowbw"
    "bimodal-no-ipcp-no-no-rpp-1core-lowbw"

    # --- L2Only (L2 IP_stride) ---
    # Normal bandwidth
    "bimodal-no-no-ip_stride-no-lru-1core"
    "bimodal-no-no-ip_stride-no-mockingjay-1core"
    "bimodal-no-no-ip_stride-no-rpp-1core"
    # Low bandwidth
    "bimodal-no-no-ip_stride-no-lru-1core-lowbw"
    "bimodal-no-no-ip_stride-no-mockingjay-1core-lowbw"
    "bimodal-no-no-ip_stride-no-rpp-1core-lowbw"

    # --- L1L2 (L1D + L2 双预取) ---
    # Normal bandwidth
    "bimodal-no-ipcp-ip_stride-no-lru-1core"
    "bimodal-no-ipcp-ip_stride-no-mockingjay-1core"
    "bimodal-no-ipcp-ip_stride-no-rpp-1core"
    # Low bandwidth
    "bimodal-no-ipcp-ip_stride-no-lru-1core-lowbw"
    "bimodal-no-ipcp-ip_stride-no-mockingjay-1core-lowbw"
    "bimodal-no-ipcp-ip_stride-no-rpp-1core-lowbw"
)

# 每组 3 个 (LRU=baseline, Mockingjay, RPP)
GROUP_SIZE=3

# =========================================================================
# 预检查
# =========================================================================
echo "========================================================"
echo "  ChampSim 并行正交实验 (24 配置)"
echo "========================================================"
echo "并发数:     $CONCURRENCY"
echo "预热指令数: $WARMUP_INSTR"
echo "模拟指令数: $SIM_INSTR"
echo "二进制文件: ${#BINARIES[@]} 个"
echo "Trace 文件: $(ls $TRACE_DIR/*.trace.xz 2>/dev/null | wc -l) 个"
echo "总任务数:   $((${#BINARIES[@]} * $(ls $TRACE_DIR/*.trace.xz 2>/dev/null | wc -l))) 个"
echo "输出目录:   $OUT_DIR/"
echo "结果文件:   $RESULT_FILE"
echo "详细指标:   $DETAIL_FILE"
echo "========================================================"
echo ""

# 检查目录和文件
if [ ! -d "$BIN_DIR" ]; then
    echo "错误: 找不到二进制目录 '$BIN_DIR'"
    exit 1
fi

if [ ! -d "$TRACE_DIR" ]; then
    echo "错误: 找不到 trace 目录 '$TRACE_DIR'"
    exit 1
fi

TRACES=($(ls $TRACE_DIR/*.trace.xz 2>/dev/null))
if [ ${#TRACES[@]} -eq 0 ]; then
    echo "错误: 在 '$TRACE_DIR' 中没有找到 .trace.xz 文件"
    exit 1
fi

for BIN_NAME in "${BINARIES[@]}"; do
    if [ ! -f "$BIN_DIR/$BIN_NAME" ]; then
        echo "错误: 找不到二进制文件 '$BIN_DIR/$BIN_NAME'"
        exit 1
    fi
done

# 创建输出目录
mkdir -p "$LOG_DIR"

# =========================================================================
# 运行实验 (并发控制)
# =========================================================================
TOTAL=$(( ${#BINARIES[@]} * ${#TRACES[@]} ))
COMPLETED=0

echo "开始运行 $TOTAL 个实验任务..."
echo ""

running=0

for TRACE_FILE in "${TRACES[@]}"; do
    TRACE_NAME=$(basename "$TRACE_FILE")

    for BIN_NAME in "${BINARIES[@]}"; do
        LABEL=${BIN_LABELS[$BIN_NAME]}
        LOG_FILE="${LOG_DIR}/${TRACE_NAME}__${LABEL}.log"

        # 并发控制: 达到上限时等待任一任务完成
        while [ "$running" -ge "$CONCURRENCY" ]; do
            wait -n 2>/dev/null || true
            running=$((running - 1))
            COMPLETED=$((COMPLETED + 1))
            echo "[$COMPLETED/$TOTAL] 任务完成"
        done

        echo "[$COMPLETED/$TOTAL] 启动: $LABEL -> $TRACE_NAME"

        "$BIN_DIR/$BIN_NAME" \
            -warmup_instructions "$WARMUP_INSTR" \
            -simulation_instructions "$SIM_INSTR" \
            -traces "$TRACE_FILE" \
            > "$LOG_FILE" 2>&1 &
        running=$((running + 1))
    done
done

# 等待剩余任务完成
while [ "$running" -gt 0 ]; do
    wait -n 2>/dev/null || true
    running=$((running - 1))
    COMPLETED=$((COMPLETED + 1))
    echo "[$COMPLETED/$TOTAL] 任务完成"
done

echo ""
echo "所有 $TOTAL 个模拟任务已完成！"
echo ""

# =========================================================================
# 解析日志并生成统一结果文件
# =========================================================================
echo "正在解析结果并生成统一输出文件..."

# 解析单个日志文件，输出 tab 分隔的数据行
parse_log() {
    local log=$1
    awk '
    BEGIN { FS = " "; OFS = "\t" }

    # Extract IPC from CPU 0 cumulative line
    /CPU 0 cumulative IPC:/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "IPC:") ipc = $(i+1)
        }
    }

    # Section headers toggle active section
    /LLC Access & Miss by Memory Area/  { in_mem = 1; next }
    /Cache Hierarchy Access.*Summary/   { in_mem = 0; next }

    # Skip separator/header lines
    in_mem && /^====/  { next }
    in_mem && /^----/  { next }

    # --- Memory Area data lines ---
    in_mem && /Local DRAM \(Area 0\):/ {
        getline
        for (i = 1; i <= NF; i++) {
            if ($i == "Access:")  dram_access  = $(i+1)
            if ($i == "Miss:")    dram_miss    = $(i+1)
            if ($i == "Miss" && $(i+1) == "Rate:") dram_rate = $(i+2)
        }
    }

    in_mem && /NUMA Node  \(Area 1\):/ {
        getline
        for (i = 1; i <= NF; i++) {
            if ($i == "Access:")  numa_access  = $(i+1)
            if ($i == "Miss:")    numa_miss    = $(i+1)
            if ($i == "Miss" && $(i+1) == "Rate:") numa_rate = $(i+2)
        }
    }

    in_mem && /CXL Node   \(Area 2\):/ {
        getline
        for (i = 1; i <= NF; i++) {
            if ($i == "Access:")  cxl_access  = $(i+1)
            if ($i == "Miss:")    cxl_miss    = $(i+1)
            if ($i == "Miss" && $(i+1) == "Rate:") cxl_rate = $(i+2)
        }
    }

    in_mem && /^Total[[:space:]]+Access:/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "Access:")  total_access  = $(i+1)
            if ($i == "Miss:")    total_miss    = $(i+1)
        }
    }

    in_mem && /Total Estimated Miss Latency Cost/ {
        miss_latency_cost = $NF
    }

    END {
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
            dram_access, dram_miss, dram_rate,
            numa_access, numa_miss, numa_rate,
            cxl_access, cxl_miss, cxl_rate,
            total_access, total_miss,
            miss_latency_cost,
            ipc
    }
    ' "$log"
}

# =========================================================================
# 解析 RPP 日志中的 RPP_PER_TRACE_METRICS 20 指标块
# 输出: key=value 格式, 一行一个
# =========================================================================
parse_rpp_metrics() {
    local log=$1
    awk '
    BEGIN { in_block = 0; sep_count = 0 }
    /RPP_PER_TRACE_METRICS/ { in_block = 1; sep_count = 0; next }
    in_block && /^===========================================================/ {
        sep_count++
        if (sep_count == 1) next      # skip opening separator
        if (sep_count >= 2) exit      # closing separator → exit
    }
    in_block {
        line = $0

        # Try multi-value patterns first (order matters — most specific first)

        # Metric 3: Area_fill_distribution = DRAM X% / NUMA Y% / CXL Z%
        if (match(line, /DRAM *([0-9.]+)% *\/ *NUMA *([0-9.]+)% *\/ *CXL *([0-9.]+)%/, arr)) {
            printf "dram_fill_pct=%s\nnuma_fill_pct=%s\ncxl_fill_pct=%s\n", arr[1], arr[2], arr[3]
            next
        }
        # Metric 12: ETR_fill_distribution = 0:X%  local:Y%  remote:Z%  maxrd:W%
        if (match(line, /0: *([0-9.]+)% *local: *([0-9.]+)% *remote: *([0-9.]+)% *maxrd: *([0-9.]+)%/, arr)) {
            printf "etr0_pct=%s\netr_local_pct=%s\netr_remote_pct=%s\netr_maxrd_pct=%s\n", arr[1], arr[2], arr[3], arr[4]
            next
        }
        # Metric 11: RDP_source_ratio = reuse N / detrain M
        if (match(line, /reuse *([0-9]+) *\/ *detrain *([0-9]+)/, arr)) {
            printf "rdp_from_reuse=%s\nrdp_from_detrain=%s\n", arr[1], arr[2]
            next
        }
        # Metric 17: GVC_insert/hit/rate = N / M / X%
        if (match(line, /\[ *17\].*([0-9]+) *\/ *([0-9]+) *\/ *([0-9.]+)%/, arr)) {
            printf "gvc_insert=%s\ngvc_hit=%s\ngvc_hit_rate=%s\n", arr[1], arr[2], arr[3]
            next
        }
        # Metric 19: Area_miss_counts = DRAM N / NUMA M / CXL K
        if (match(line, /DRAM *([0-9]+) *\/ *NUMA *([0-9]+) *\/ *CXL *([0-9]+)/, arr)) {
            printf "dram_miss=%s\nnuma_miss=%s\ncxl_miss=%s\n", arr[1], arr[2], arr[3]
            next
        }
        # Metric 20: IPC / Miss_LatCost = X / Y
        if (match(line, /\[ *20\].*([0-9]+\.[0-9]+) *\/ *([0-9]+)/, arr)) {
            printf "rpp_ipc=%s\nmiss_latcost=%s\n", arr[1], arr[2]
            next
        }
        # Metric 2: LLC_miss_rate — extract first percentage (miss rate)
        if (match(line, /\[ *2\]/, arr)) {
            if (match(line, /([0-9.]+)%/, arr2)) {
                printf "LLC_miss_rate=%s\n", arr2[1]
            }
            next
        }
        # Generic single-value: [ N] Key_Name ... = value ...
        if (match(line, /\[ *[0-9]+\] *([A-Za-z_\/]+).*= *([0-9]+(\.[0-9]+)?)/, arr)) {
            key = arr[1]
            gsub(/ /, "", key)
            printf "%s=%s\n", key, arr[2]
            next
        }
    }
    ' "$log"
}

# =========================================================================
# 解析 Mockingjay 日志中的 Bypass Count
# =========================================================================
parse_mj_bypass() {
    local log=$1
    awk '/Mockingjay Bypass Count:/ { print $NF }' "$log"
}

# =========================================================================
# 计算提升百分比 (使用 awk 保证精度)
#   $1: baseline 值
#   $2: target 值
#   $3: 模式: "lower_better" = LW-MPKI (越小越好), "higher_better" = IPC (越大越好)
#
#   LW-MPKI_Improv   = (baseline - target) / baseline * 100   (positive = improvement)
#   IPC_Improv       = (target - baseline) / baseline * 100   (positive = improvement)
#
#   两者统一使用 baseline 作为分母 (顶级体系结构论文标准做法)
# =========================================================================
calc_improvement() {
    local base=$1 val=$2 mode=$3
    if [ -z "$base" ] || [ -z "$val" ] || [ "$base" = "0" ] || [ "$val" = "0" ]; then
        echo "N/A"
        return
    fi
    if [ "$mode" = "lower_better" ]; then
        # 越小越好 → (baseline - target) / baseline * 100
        awk -v b="$base" -v v="$val" 'BEGIN { printf "%.4f%%", (b - v) / b * 100 }'
    elif [ "$mode" = "higher_better" ]; then
        # 越大越好 → (target - baseline) / baseline * 100
        awk -v b="$base" -v v="$val" 'BEGIN { printf "%.4f%%", (v - b) / b * 100 }'
    else
        echo "N/A"
    fi
}

# =========================================================================
# 计算 LW-MPKI: 将 Miss_LatCost 除以 (SIM_INSTR / 1000) 换算为 per-kilo-instruction
# =========================================================================
calc_lw_mpki() {
    local miss_latcost=$1
    local divisor=$((SIM_INSTR / 1000))
    if [ -z "$miss_latcost" ] || [ "$miss_latcost" = "N/A" ]; then
        echo "N/A"
        return
    fi
    awk -v ml="$miss_latcost" -v d="$divisor" 'BEGIN { printf "%.2f", ml / d }'
}

# =========================================================================
# 预定义 Group A 和 Group B 的名称
# =========================================================================
# Group A: 8 组 = 4 Pref x 2 BW
GROUP_A_NAMES=(
    "NoPref-Normal"   "NoPref-LowBw"
    "L1DOnly-Normal"  "L1DOnly-LowBw"
    "L2Only-Normal"   "L2Only-LowBw"
    "L1L2-Normal"     "L1L2-LowBw"
)

# Group B: 12 组 = 4 Pref x 3 Repl
GROUP_B_NAMES=(
    "NoPref-LRU"    "NoPref-Mockingjay"    "NoPref-RPP"
    "L1DOnly-LRU"   "L1DOnly-Mockingjay"   "L1DOnly-RPP"
    "L2Only-LRU"    "L2Only-Mockingjay"    "L2Only-RPP"
    "L1L2-LRU"      "L1L2-Mockingjay"      "L1L2-RPP"
)

# 生成格式化输出文件
{
    echo "======================================================================================================"
    echo "  ChampSim 统一实验结果 (24 配置)"
    echo "  生成时间: $(date)"
    echo "  预热指令: $WARMUP_INSTR  模拟指令: $SIM_INSTR"
    echo "  配置维度: 4 预取器 × 3 替换策略 × 2 带宽 = 24 配置"
    echo ""
    echo "  指标说明:"
    echo "    LW-MPKI = Total_Estimated_Miss_Latency_Cost / (SIM_INSTR/1000)"
    echo "    LW-MPKI_Improv% = (baseline - target) / baseline × 100  (越小越好, positive=improvement)"
    echo "    IPC_Improv%     = (target - baseline) / baseline × 100  (越大越好, positive=improvement)"
    echo ""
    echo "  分组说明:"
    echo "    Group A (Replacement Policy Comparison): 相同 BW + 相同 Pref, 不同替换策略"
    echo "      比较 MJvsLRU / RPPvsLRU / RPPvsMJ"
    echo "    Group B (Bandwidth Sensitivity):         相同 Pref + 相同 Repl, 不同带宽"
    echo "      比较 LowBw vs Normal"
    echo "======================================================================================================"
    echo ""

    for TRACE_FILE in "${TRACES[@]}"; do
        TRACE_NAME=$(basename "$TRACE_FILE")

        echo "======================================================================================================"
        echo "  Trace: $TRACE_NAME"
        echo "======================================================================================================"
        echo ""

        # 为当前 trace 收集所有 binary 的数据 (索引顺序同 BINARIES)
        unset d_access d_miss d_rate n_access n_miss n_rate
        unset c_access c_miss c_rate t_access t_miss m_latcost lw_mpki ipc_val labels

        idx=0
        for BIN_NAME in "${BINARIES[@]}"; do
            LABEL=${BIN_LABELS[$BIN_NAME]}
            LOG_FILE="${LOG_DIR}/${TRACE_NAME}__${LABEL}.log"

            if [ -f "$LOG_FILE" ]; then
                DATA=$(parse_log "$LOG_FILE")
                if [ -n "$DATA" ]; then
                    IFS=$'\t' read -r \
                        da dm dr \
                        na nm nr \
                        ca cm cr \
                        ta tm ml \
                        ip \
                        <<< "$DATA"

                    d_access[$idx]="$da"; d_miss[$idx]="$dm"; d_rate[$idx]="$dr"
                    n_access[$idx]="$na"; n_miss[$idx]="$nm"; n_rate[$idx]="$nr"
                    c_access[$idx]="$ca"; c_miss[$idx]="$cm"; c_rate[$idx]="$cr"
                    t_access[$idx]="$ta"; t_miss[$idx]="$tm"
                    m_latcost[$idx]="$ml"
                    lw_mpki[$idx]=$(calc_lw_mpki "$ml")
                    ipc_val[$idx]="$ip"
                    labels[$idx]="$LABEL"
                fi
            fi
            idx=$((idx + 1))
        done

        # =====================================================================
        # Table 1: Absolute Metrics (24 行, 按 BINARIES 顺序)
        # =====================================================================
        echo "--- Table 1: Absolute Metrics ---"
        echo ""

        printf "%-24s %12s %10s %10s %12s %10s %10s %12s %10s %10s %12s %10s %10s %10s\n" \
            "Binary" \
            "DRAM_Access" "DRAM_Miss" "DRAM_MissRt" \
            "NUMA_Access" "NUMA_Miss" "NUMA_MissRt" \
            "CXL_Access" "CXL_Miss" "CXL_MissRt" \
            "Total_Access" "Total_Miss" "LW-MPKI" \
            "IPC"
        printf "%-24s %12s %10s %10s %12s %10s %10s %12s %10s %10s %12s %10s %10s %10s\n" \
            "------------------------" \
            "------------" "----------" "----------" \
            "------------" "----------" "----------" \
            "------------" "----------" "----------" \
            "------------" "----------" "----------" \
            "----------"

        for idx in $(seq 0 $((${#BINARIES[@]} - 1))); do
            LABEL="${labels[$idx]}"
            if [ -z "$LABEL" ]; then
                continue
            fi

            printf "%-24s %12s %10s %10s %12s %10s %10s %12s %10s %10s %12s %10s %10s %10s\n" \
                "$LABEL" \
                "${d_access[$idx]:-N/A}" "${d_miss[$idx]:-N/A}" "${d_rate[$idx]:-N/A}" \
                "${n_access[$idx]:-N/A}" "${n_miss[$idx]:-N/A}" "${n_rate[$idx]:-N/A}" \
                "${c_access[$idx]:-N/A}" "${c_miss[$idx]:-N/A}" "${c_rate[$idx]:-N/A}" \
                "${t_access[$idx]:-N/A}" "${t_miss[$idx]:-N/A}" "${lw_mpki[$idx]:-N/A}" \
                "${ipc_val[$idx]:-N/A}"
        done

        echo ""
        echo ""

        # =====================================================================
        # Table 2: Group A — Replacement Policy Comparison
        #   相同 BW + 相同 Pref, 不同替换策略
        #   8 组 × 3 比较 = 每组 6 列 (3 comparisons × 2 metrics)
        # =====================================================================
        echo "--- Table 2: Group A — Replacement Policy Comparison (same BW, same Pref) ---"
        echo ""

        printf "%-20s %18s %16s %18s %16s %18s %16s\n" \
            "Group(Pref,BW)" \
            "MJvsLRU_LWMPKI%" "MJvsLRU_IPC%" \
            "RPPvsLRU_LWMPKI%" "RPPvsLRU_IPC%" \
            "RPPvsMJ_LWMPKI%" "RPPvsMJ_IPC%"
        printf "%-20s %18s %16s %18s %16s %18s %16s\n" \
            "--------------------" \
            "------------------" "----------------" \
            "------------------" "----------------" \
            "------------------" "----------------"

        for ga in $(seq 0 7); do
            # 每组 3 个: [LRU, Mockingjay, RPP], 起始索引 = ga * GROUP_SIZE
            local_base=$(( ga * GROUP_SIZE ))
            lru_idx=$local_base
            mj_idx=$(( local_base + 1 ))
            rpp_idx=$(( local_base + 2 ))

            mj_vs_lru_lwmpki=$(calc_improvement "${lw_mpki[$lru_idx]}" "${lw_mpki[$mj_idx]}" "lower_better")
            mj_vs_lru_ipc=$(calc_improvement "${ipc_val[$lru_idx]}" "${ipc_val[$mj_idx]}" "higher_better")
            rpp_vs_lru_lwmpki=$(calc_improvement "${lw_mpki[$lru_idx]}" "${lw_mpki[$rpp_idx]}" "lower_better")
            rpp_vs_lru_ipc=$(calc_improvement "${ipc_val[$lru_idx]}" "${ipc_val[$rpp_idx]}" "higher_better")
            rpp_vs_mj_lwmpki=$(calc_improvement "${lw_mpki[$mj_idx]}" "${lw_mpki[$rpp_idx]}" "lower_better")
            rpp_vs_mj_ipc=$(calc_improvement "${ipc_val[$mj_idx]}" "${ipc_val[$rpp_idx]}" "higher_better")

            printf "%-20s %18s %16s %18s %16s %18s %16s\n" \
                "${GROUP_A_NAMES[$ga]}" \
                "$mj_vs_lru_lwmpki" "$mj_vs_lru_ipc" \
                "$rpp_vs_lru_lwmpki" "$rpp_vs_lru_ipc" \
                "$rpp_vs_mj_lwmpki" "$rpp_vs_mj_ipc"
        done

        echo ""
        echo ""

        # =====================================================================
        # Table 3: Group B — Bandwidth Sensitivity
        #   相同 Pref + 相同 Repl, 不同带宽 (LowBw vs Normal)
        #   12 组 × 2 列
        #   LowBw 性能应下降 → LW-MPKI 升高, IPC 降低 → 改善率为负值
        # =====================================================================
        echo "--- Table 3: Group B — Bandwidth Sensitivity (same Pref, same Repl) ---"
        echo ""

        printf "%-22s %18s %16s\n" \
            "Group(Pref,Repl)" \
            "LowBw_vs_Normal_LWMPKI%" "LowBw_vs_Normal_IPC%"
        printf "%-22s %18s %16s\n" \
            "----------------------" \
            "------------------" "----------------"

        for gb in $(seq 0 11); do
            # pref = gb / 3, repl = gb % 3
            pref=$(( gb / 3 ))
            repl=$(( gb % 3 ))

            # normal 在 pref*6 + repl, lowbw 在 pref*6 + 3 + repl
            normal_idx=$(( pref * 6 + repl ))
            lowbw_idx=$(( pref * 6 + 3 + repl ))

            bw_lwmpki_improv=$(calc_improvement "${lw_mpki[$normal_idx]}" "${lw_mpki[$lowbw_idx]}" "lower_better")
            bw_ipc_improv=$(calc_improvement "${ipc_val[$normal_idx]}" "${ipc_val[$lowbw_idx]}" "higher_better")

            printf "%-22s %18s %16s\n" \
                "${GROUP_B_NAMES[$gb]}" \
                "$bw_lwmpki_improv" "$bw_ipc_improv"
        done

        echo ""
        echo ""
    done

    echo "======================================================================================================"
    echo "  结果汇总完毕"
    echo "======================================================================================================"

} > "$RESULT_FILE"

# =========================================================================
# 生成 RPP 详细指标文件 (RPP 20 metrics + Mockingjay bypass count)
# 仅包含 Mockingjay 和 RPP 配置, LRU 数据见 unified_results.txt
# =========================================================================
echo ""
echo "正在生成 RPP 详细指标文件..."

{
    echo "# ========================================================================================================"
    echo "#   RPP 详细指标文件 (Per-Trace 20 Metrics + Mockingjay Bypass)"
    echo "#   生成时间: $(date)"
    echo "#   用于分析每个 trace 下 RPP 相对 Mockingjay 的性能变化原因"
    echo "#   LRU 数据请参见 unified_results.txt"
    echo "# ========================================================================================================"
    echo ""
    echo "# 格式: 每个 trace 一个 section, 包含 Mockingjay 和 RPP binary 的指标"
    echo "#   Mockingjay 行: mj_bypass=<N>"
    echo "#   RPP 行:        [20 metrics from RPP_PER_TRACE_METRICS block]"
    echo ""

    for TRACE_FILE in "${TRACES[@]}"; do
        TRACE_NAME=$(basename "$TRACE_FILE")

        echo "========================================================================================================"
        echo "  Trace: $TRACE_NAME"
        echo "========================================================================================================"
        echo ""

        for BIN_NAME in "${BINARIES[@]}"; do
            LABEL=${BIN_LABELS[$BIN_NAME]}
            LOG_FILE="${LOG_DIR}/${TRACE_NAME}__${LABEL}.log"

            if [ ! -f "$LOG_FILE" ]; then
                echo "  [$LABEL] LOG NOT FOUND"
                continue
            fi

            if [[ "$LABEL" == *"LRU"* ]]; then
                # LRU 不包含 RPP 相关指标, 跳过 (LRU 数据见 unified_results.txt)
                continue
            elif [[ "$LABEL" == *"Mockingjay"* ]]; then
                # Mockingjay: extract bypass count
                MJ_BYPASS=$(parse_mj_bypass "$LOG_FILE")
                echo "  [$LABEL]"
                echo "    repl=Mockingjay"
                echo "    mj_bypass=${MJ_BYPASS:-0}"
            elif [[ "$LABEL" == *"RPP"* ]]; then
                # RPP: extract 20 metrics block
                echo "  [$LABEL]"
                echo "    repl=RPP"
                METRICS=$(parse_rpp_metrics "$LOG_FILE")
                if [ -n "$METRICS" ]; then
                    echo "$METRICS" | while IFS='=' read -r key val; do
                        echo "    ${key}=${val}"
                    done
                else
                    echo "    # RPP_PER_TRACE_METRICS block not found in log"
                fi
            fi
            echo ""
        done
    done

    echo "# ========================================================================================================"
    echo "#   详细指标文件完毕"
    echo "# ========================================================================================================"

} > "$DETAIL_FILE"

echo "RPP 详细指标文件: $DETAIL_FILE"

echo ""
echo "========================================================"
echo "实验全部完成！"
echo "统一结果文件: $RESULT_FILE"
echo "详细指标文件: $DETAIL_FILE"
echo "各任务日志:   $LOG_DIR/"
echo "========================================================"
