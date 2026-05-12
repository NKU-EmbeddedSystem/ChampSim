#!/usr/bin/env bash
# setup_simpoints.sh — 一键安装 SimPoints 工作流的所有依赖工具
#
# 安装内容：
#   1. SimPoint 3.2（C++ k-means 聚类工具）
#   2. BBV Pin Tool（Basic Block Vector 收集工具）
#
# 前置条件：Intel Pin 3.22+ 和 SPEC CPU2017 已就绪
#
# 用法：
#   ./setup_simpoints.sh                        # 交互式安装
#   ./setup_simpoints.sh --non-interactive       # 无人值守安装
#   PIN_ROOT=/custom/path ./setup_simpoints.sh   # 指定 Pin 路径
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACER_DIR="${SCRIPT_DIR}/../../tracer/pin"
SIMPOINT_DIR="${HOME}/simpoint"
SIMPOINT_REPO="https://github.com/ppenzin/SimPoint.3.2.git"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

NON_INTERACTIVE=false
[[ "${1:-}" == "--non-interactive" ]] && NON_INTERACTIVE=true

say()  { echo -e "${CYAN}[setup_simpoints]${NC} $*"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; }

pause() {
    if [ "$NON_INTERACTIVE" = false ]; then
        echo ""
        read -r -p "  按 Enter 继续，Ctrl-C 取消... " _
    fi
}

# ── Prerequisites ──────────────────────────────────────────────────

say "Step 0 — 检查前置条件"

MISSING=()

for cmd in git g++ make; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd 可用"
    else
        err "$cmd 未安装"
        MISSING+=("$cmd")
    fi
done

# Detect or accept PIN_ROOT
if [ -z "${PIN_ROOT:-}" ]; then
    # Try common locations
    PIN_CANDIDATES=(
        "${HOME}/pin-3.22-98547-g7a303a835-gcc-linux"
        $(ls -d "${HOME}"/pin-3.*/pin 2>/dev/null | head -1 | xargs dirname 2>/dev/null || true)
    )
    PIN_ROOT=""
    for candidate in "${PIN_CANDIDATES[@]}"; do
        if [ -n "$candidate" ] && [ -f "${candidate}/pin" ]; then
            PIN_ROOT="$candidate"
            break
        fi
    done
fi

if [ -z "${PIN_ROOT:-}" ] || [ ! -f "${PIN_ROOT}/pin" ]; then
    err "Intel Pin 未找到。请设置 PIN_ROOT 环境变量指向 Pin 安装目录"
    warn "例如: PIN_ROOT=${HOME}/pin-3.22-... ./setup_simpoints.sh"
    MISSING+=("Intel Pin")
else
    ok "Intel Pin: ${PIN_ROOT}"
fi

PIN_MAKEFILE="${PIN_ROOT}/source/tools/Config/makefile.config"
if [ ! -f "$PIN_MAKEFILE" ]; then
    err "Pin SDK 文件缺失: ${PIN_MAKEFILE}"
    warn "请确认 Pin 是完整安装（含 source/tools/ 目录）"
    MISSING+=("Pin SDK")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    err "缺少 ${#MISSING[@]} 个前置条件: ${MISSING[*]}"
    exit 1
fi

# ── SimPoint 3.2 ────────────────────────────────────────────────────

say "Step 1 — 安装 SimPoint 3.2"

if [ -f "${SIMPOINT_DIR}/bin/simpoint" ]; then
    ok "SimPoint 3.2 已安装: ${SIMPOINT_DIR}/bin/simpoint"
else
    if [ -d "$SIMPOINT_DIR" ]; then
        warn "目录 ${SIMPOINT_DIR} 已存在但缺少二进制，重新 clone..."
        rm -rf "$SIMPOINT_DIR"
    fi

    git clone --depth 1 "$SIMPOINT_REPO" "$SIMPOINT_DIR"
    ok "clone 完成"

    # 注意：Makefile 使用 gmake 和 capital-S Simpoint 目标
    if ! command -v gmake >/dev/null 2>&1; then
        warn "gmake 未找到，尝试用 make 替代"
        cd "$SIMPOINT_DIR/analysiscode"
        make simpoint
        mkdir -p "${SIMPOINT_DIR}/bin"
        cp simpoint "${SIMPOINT_DIR}/bin/"
    else
        cd "$SIMPOINT_DIR" && gmake Simpoint
    fi

    if [ -f "${SIMPOINT_DIR}/bin/simpoint" ]; then
        ok "SimPoint 3.2 编译成功"
    else
        err "SimPoint 3.2 编译失败"
        exit 1
    fi
fi

# ── BBV Pin Tool ────────────────────────────────────────────────────

say "Step 2 — 编译 BBV Pin Tool"

# Ensure bbv_tool in Makefile TOOL_ROOTS
MAKEFILE="${TRACER_DIR}/Makefile"
BBV_CPP="${TRACER_DIR}/bbv_tool.cpp"

if [ ! -f "$BBV_CPP" ]; then
    err "BBV tool 源码缺失: ${BBV_CPP}"
    warn "请确认 bbv_tool.cpp 在 ChampSim tracer/pin/ 目录下"
    exit 1
fi
ok "bbv_tool.cpp 已就位"

# Check and fix Makefile if needed
if ! grep -q 'bbv_tool' "$MAKEFILE" 2>/dev/null; then
    warn "Makefile 缺少 bbv_tool；自动添加..."
    sed -i 's/TOOL_ROOTS := champsim_tracer/TOOL_ROOTS := champsim_tracer bbv_tool/' "$MAKEFILE"
    ok "Makefile 已更新 (添加 bbv_tool 到 TOOL_ROOTS)"
else
    ok "Makefile 已包含 bbv_tool"
fi

# Compile
cd "$TRACER_DIR"
PIN_ROOT="$PIN_ROOT" make clean 2>/dev/null || true
PIN_ROOT="$PIN_ROOT" make

BBV_SO="${TRACER_DIR}/obj-intel64/bbv_tool.so"
if [ -f "$BBV_SO" ]; then
    ok "BBV Pin Tool 编译成功: ${BBV_SO}"
else
    err "BBV Pin Tool 编译失败"
    exit 1
fi

# ── Verification ────────────────────────────────────────────────────

say "Step 3 — 验证"

echo ""
echo "   ┌─────────────────────────────────────────────────────────┐"
echo "   │  SimPoints 工作流 — 安装完成                             │"
echo "   ├─────────────────────────────────────────────────────────┤"
printf "   │  SimPoint 3.2  …  %-37s │\n" "$(command -v "$SIMPOINT_DIR/bin/simpoint" 2>/dev/null && echo '~/simpoint/bin/simpoint' || echo 'MISSING')"
printf "   │  BBV Pin Tool   …  %-37s │\n" "$([ -f "$BBV_SO" ] && echo 'tracer/pin/obj-intel64/bbv_tool.so' || echo 'MISSING')"
printf "   │  convert 脚本    …  %-37s │\n" "$([ -f "${SCRIPT_DIR}/convert_simpoints.py" ] && echo 'tools/profiling/convert_simpoints.py' || echo 'MISSING')"
printf "   │  parse 脚本      …  %-37s │\n" "$([ -f "${SCRIPT_DIR}/parse_simpoints.py" ] && echo 'tools/profiling/parse_simpoints.py' || echo 'MISSING')"
echo "   └─────────────────────────────────────────────────────────┘"
echo ""

say "下一步: 按 docs/html/simpoints-workflow.html 中的路径 B 三步流程执行"
say "  Step 1 — BBV 收集: pin -t bbv_tool.so -o output.bb -- ./binary args"
say "  Step 2 — SimPoint:   simpoint -maxK 30 -loadFVFile output.bb ..."
say "  Step 3 — 转换 JSON:  python3 convert_simpoints.py ..."
