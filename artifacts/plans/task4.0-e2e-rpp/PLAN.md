# Stage 4.0: End-to-End RPP Performance — Single-Core & Multi-Core

**Spec:** N/A

## Goal

在单核 (1-core) 和多核 (4-core) 场景下评估 RPP 替换策略的端到端性能，对比 lru / hawkeye / mockingjay / rpp 四种 LLC 替换策略在 random 和 first_touch 两种页面放置下的 IPC 和 MPKI。本实验不开启任何 prefetch 和 page migration，仅考察静态页面放置 + 替换策略的效果。

核心关注点：
1. RPP 在单核 vs 多核下的性能表现是否一致
2. RPP 相对于 LRU / Hawkeye / MockingJay 的 IPC 加速比
3. 不同页面放置策略 (random vs first_touch) 下各替换策略的相对收益

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Warmup | 50M instructions |
| Simulation | 1000M instructions |
| Branch predictor | bimodal |
| Prefetchers | no (all levels: L1I, L1D, L2C, LLC) |
| Page migration | none (no `-m` flag) |
| DRAM:CXL ratio | 固定 1:2 by distinct 4KB pages（area_map 生成时不传 `--dram_pages`，由 `floor(pages/3)` 自动推导） |
| DRAM pages (K) | Auto-derived as `floor(distinct_pages / 3)` |
| Page size | 4KB |
| Cores | 1 and 4 |
| 1-core MAX_PARALLEL | 16 |
| 4-core MAX_PARALLEL | 4 (4-core 模拟开销更大) |

## Candidates: Placement × Policy × Core Count

### Placement Strategies (2)

| Index | Placement | Migration | Description |
|-------|-----------|-----------|-------------|
| 0 | random | none | 在目标指令窗口内 collect distinct pages → deterministic shuffle → top-K area0 (DRAM), rest area1 (CXL) |
| 1 | first_touch | none | 在目标指令窗口内 first K distinct pages in trace order → area0 (DRAM), rest area1 (CXL) |

### Replacement Policies (4)

| Index | Policy | Description |
|-------|--------|-------------|
| 0 | lru | Baseline LRU |
| 1 | hawkeye | Hawkeye predictor-based |
| 2 | mockingjay | MockingJay (ML-based) |
| 3 | rpp | SilkLoom RPP (latency-aware) |

### Core Configurations (2)

| Index | Cores | Description |
|-------|-------|-------------|
| 0 | 1 | 单核运行，binary 编译为 `-1core` |
| 1 | 4 | 四核同时运行，binary 编译为 `-4core`；4 个不同 trace 并行执行 |

## Benchmarks

**动态指定** — 实验脚本的命令行参数传入，不硬编码。traces/ 目录下 `.champsimtrace.xz` 和 `.champsim.trace.xz` 格式均可。

示例 12 workloads: astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp

### 1-Core Task Count

12 benchmarks × 2 placements × 4 policies = **96 tasks**

### 4-Core Task Count

4 核实验使用 4-trace 组合。从 12 个 workload 中选择互不相同的 4 个组成一组，形成 3 组 (12 ÷ 4 = 3) 互斥组合：

| Group | Traces |
|-------|--------|
| G0 | astar, cactusADM, h264ref, libquantum |
| G1 | mcf, milc, omnetpp, perlbench |
| G2 | soplex, sphinx3, xalancbmk, zeusmp |

3 groups × 2 placements × 4 policies = **24 tasks**

**Total: 96 + 24 = 120 tasks**

## Filter Rule

无 — 全部 120 tasks 均保留。IPC ≤ 0 的 run 标记为异常。

## Metrics to Collect

| Metric | Source |
|--------|--------|
| IPC | `grep "CPU X cumulative IPC"` 从 raw output |
| MPKI | 需从 raw output 解析 `branch_mispredictions / (num_retired - warmup)` 或从 LLC miss 自行计算 |
| LLC Miss Distribution | `llc_miss_by_area[0]` (DRAM) 和 `llc_miss_by_area[2]` (CXL) |
| DRAM/CXL access ratio | `sim_dram_accesses` / `sim_cxl_accesses` |
| Average Miss Latency | `AVERAGE MISS LATENCY` from raw output |

## Auxiliary Checks

1. **All tasks complete:** 120 tasks dispatched, 120 completed with exit=0
2. **Zero failures:** No builds fail, no simulator crashes
3. **IPC > 0:** All simulation results produce valid IPC values
4. **Area stats:** `llc_miss_by_area` shows correct DRAM+CXL distribution
5. **DRAM:CXL = 1:2 verified:** area_map 中 area0 页面数 = `floor(num_entries / 3)`
6. **No migration logs:** raw output 中不应出现 `[migration]` 行（确认迁移未开启）
7. **4-core consistency:** 4-core 运行时 4 个 CPU 的 IPC 均 > 0

## How to Run

```bash
# 一键运行（推荐）
# 单核实验：
bash scripts/run_task4.0_1core.sh <trace1.xz> <trace2.xz> ...

# 四核实验（trace 数量必须是 4 的倍数）：
bash scripts/run_task4.0_4core.sh <trace1.xz> ... <traceN.xz>

# 自定义参数：
TASK4_0_SIM=500000000 TASK4_0_WARMUP=50000000 bash scripts/run_task4.0_1core.sh traces/*.xz

# 分步运行：
# Step 1: 生成 area_maps
bash scripts/run_task4.0_gen_areamaps.sh <traces...>
# Step 2: 构建 1-core 和 4-core 二进制
bash scripts/run_task4.0_build.sh
# Step 3a: 1-core 实验
bash scripts/run_task4.0_e2e_rpp_1core.sh <traces...>
# Step 3b: 4-core 实验
bash scripts/run_task4.0_e2e_rpp_4core.sh <traces...>
```

## Output Structure

```
artifacts/
  plans/task4.0-e2e-rpp/
    PLAN.md              <- this file
    run.sh               <- symlink to scripts/run_task4.0_e2e_rpp.sh (auto)
    SUMMARY.log          <- symlink to latest main.log (auto)
    CONCLUSIONS.md       <- auto-generated after run

  runs/task4.0-e2e-rpp/
    latest -> <timestamp>
    <YYYYMMDD-HHMMSS>/
      execution.log      <- control plane (120 TASK DISPATCH/DONE)
      main.log           <- global log
      build_{lru,hawkeye,mockingjay,rpp}-{1core,4core}.log  <- 8 build logs
      area_maps/         <- 生成的 area_map 文件 (12 benchmarks × 2 strategies = 24 files)

      # 1-core results
      {benchmark}_{placement}_{policy}_1core.raw
      {benchmark}_{placement}_{policy}_1core.sub.log

      # 4-core results
      {group}_{placement}_{policy}_4core.raw
      {group}_{placement}_{policy}_4core.sub.log
```

## Expected Comparison Tables

### Table 1: Single-Core IPC (geomean over 12 benchmarks)

| Placement | LRU | Hawkeye | MockingJay | RPP |
|-----------|-----|---------|------------|-----|
| random | — | — | — | — |
| first_touch | — | — | — | — |

### Table 2: Single-Core Speedup vs LRU

| Placement | Hawkeye/LRU | MockingJay/LRU | RPP/LRU |
|-----------|-------------|----------------|---------|
| random | — | — | — |
| first_touch | — | — | — |

### Table 3: 4-Core IPC (geomean over 3 groups)

| Placement | LRU | Hawkeye | MockingJay | RPP |
|-----------|-----|---------|------------|-----|
| random | — | — | — | — |
| first_touch | — | — | — | — |

### Table 4: 4-Core Speedup vs LRU

| Placement | Hawkeye/LRU | MockingJay/LRU | RPP/LRU |
|-----------|-------------|----------------|---------|
| random | — | — | — | — |
| first_touch | — | — | — | — |
