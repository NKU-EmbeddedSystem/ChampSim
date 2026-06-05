#!/bin/bash

# =========================================================================
# ChampSim CXL vs MSHR 自动化正交实验脚本
# =========================================================================

# 1. 检查是否传入了 Trace 文件
if [ "$#" -ne 1 ]; then
    echo "用法: $0 <trace文件的路径>"
    echo "示例: $0 traces/mcf.trace.xz"
    exit 1
fi

TRACE_FILE=$1
TRACE_NAME=$(basename $TRACE_FILE) # 提取 trace 文件名，用于生成日志名称

# 2. 检查 Trace 文件是否存在
if [ ! -f "$TRACE_FILE" ]; then
    echo "错误: 找不到 Trace 文件 '$TRACE_FILE'"
    exit 1
fi

# 3. 设置实验参数 (你可以根据需要修改预热和模拟的指令数)
WARMUP_INSTR=1000000   # 1000万条预热
SIM_INSTR=10000000      # 5000万条模拟
OUT_DIR="results_cxl_mshr" # 日志存放的目录

# 4. 创建日志输出目录
mkdir -p $OUT_DIR
echo "========================================================"
echo "开始运行 MSHR 拥堵正交实验"
echo "Trace 文件: $TRACE_NAME"
echo "预热指令数: $WARMUP_INSTR"
echo "模拟指令数: $SIM_INSTR"
echo "输出目录:   $OUT_DIR/"
echo "========================================================"

# 5. 定义要运行的二进制文件及其对应的日志名称
declare -A BINARIES=(
    ["champsim_baseline"]="baseline"
    ["champsim_cxl_normal_mshr"]="cxl_normal"
    ["champsim_cxl_infinite_mshr"]="cxl_infinite"
    ["champsim_dram_infinite_mshr"]="dram_infinite"
    #["champsim_cxl_big_window_infinite_mshr"]="cxl_big_infinite"
)

# 6. 检查所有二进制文件是否存在并启动运行
for BIN_NAME in "${!BINARIES[@]}"; do
    BIN_PATH="./bin/$BIN_NAME"
    LOG_PREFIX=${BINARIES[$BIN_NAME]}
    LOG_FILE="${OUT_DIR}/${LOG_PREFIX}_${TRACE_NAME}.log"

    if [ ! -f "$BIN_PATH" ]; then
        echo "警告: 找不到可执行文件 '$BIN_PATH'，跳过该实验。"
        continue
    fi

    echo "正在后台启动: $BIN_NAME ..."
    # 使用 & 将进程放入后台并行执行，并将标准输出重定向到 log 文件
    $BIN_PATH -warmup_instructions $WARMUP_INSTR -simulation_instructions $SIM_INSTR -traces $TRACE_FILE > "$LOG_FILE" 2>&1 &
done

echo "--------------------------------------------------------"
echo "所有 4 个模拟器均已在后台启动！"
echo "正在等待它们全部运行完毕... (你可以新开一个终端输入 'top' 或 'htop' 查看 CPU 占用情况)"

# 7. 等待所有后台进程结束
wait

echo "========================================================"
echo "实验全部完成！"
echo "请前往 '$OUT_DIR' 目录查看以下日志文件："
ls -lh $OUT_DIR/*_${TRACE_NAME}.log
echo "========================================================"