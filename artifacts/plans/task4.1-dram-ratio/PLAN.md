# Stage 4.1: DRAM Ratio Sensitivity — RPP Performance Under Varying DRAM Capacity

**Spec:** N/A

## Goal

评估在不同 DRAM 内存占比下 RPP 替换策略的性能稳定性。通过调整页面放置中的 DRAM:CXL 比例（0% 到 100%），测试 hawkeye、mockingjay、rpp 三种替换策略的 IPC/MPKI 变化趋势。本实验不开启任何 prefetch 和 page migration，仅考察静态页面放置 + 替换策略在不同内存层级容量分配下的表现。

核心关注点：
1. RPP 在不同 DRAM 占比下的性能收益是否稳定
2. 当 DRAM 极度稀缺 (0%, 10%) 或极度充裕 (90%, 100%) 时，各策略的行为差异
3. Hawkeye / MockingJay / RPP 相对于 LRU 的加速比随 DRAM 比例的变化曲线
4. 确认 RPP 的 latency-aware 设计在所有 DRAM 比例下都能提供正向收益

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Warmup | 50M instructions |
| Simulation | 1000M instructions |
| Branch predictor | bimodal |
| Prefetchers | no (all levels: L1I, L1D, L2C, LLC) |
| Page migration | none (no `-m` flag) |
| Page placement strategy | random + first_touch（两种均测试） |
| Page size | 4KB |
| Cores | 1 |
| MAX_PARALLEL | 16 |

## DRAM Ratios (7 levels)

每个 benchmark 首先生成完整的 random area_map（包含所有 distinct pages），然后按指定比例将 top-K 页面分配给 DRAM。K 的计算方式：

| Ratio Label | DRAM % | CXL % | `--dram_pages` 参数 |
|-------------|--------|-------|---------------------|
| 0% | 0 | 100 | `--dram_pages=0` |
| 10% | 10 | 90 | `--dram_pages=floor(0.10 × total_pages)` |
| 30% | 30 | 70 | `--dram_pages=floor(0.30 × total_pages)` |
| 50% | 50 | 50 | `--dram_pages=floor(0.50 × total_pages)` |
| 70% | 70 | 30 | `--dram_pages=floor(0.70 × total_pages)` |
| 90% | 90 | 10 | `--dram_pages=floor(0.90 × total_pages)` |
| 100% | 100 | 0 | `--dram_pages=<total_pages>` |

> **注意：** 0% DRAM 时所有页面分配在 CXL，100% DRAM 时所有页面分配在 DRAM。这两种极端情况用于验证 CXL-only 和 DRAM-only 的延迟差异对 IPC 的上限/下限影响。

## Candidates: Ratio × Policy

### Replacement Policies (4)

| Index | Policy | Description |
|-------|--------|-------------|
| 0 | lru | Baseline LRU |
| 1 | hawkeye | Hawkeye predictor-based |
| 2 | mockingjay | MockingJay (ML-based) |
| 3 | rpp | SilkLoom RPP (latency-aware) |

### DRAM Ratios (7)

| Index | Ratio | `--dram_pages` | Description |
|-------|-------|----------------|-------------|
| 0 | 0% | 0 | All pages on CXL |
| 1 | 10% | `0.10 × N` | 极度稀缺 |
| 2 | 30% | `0.30 × N` | 稀缺 |
| 3 | 50% | `0.50 × N` | 均衡 |
| 4 | 70% | `0.70 × N` | 充裕 |
| 5 | 90% | `0.90 × N` | 极度充裕 |
| 6 | 100% | N | All pages on DRAM |

### Placement Strategy (2)

使用 **random** 和 **first_touch** 两种 placement 策略。random 策略使用 deterministic shuffle (MT19937, seed=42) 打乱页面顺序后取 top-K 作为 DRAM，对页面冷热无偏好，能够最纯粹地反映 DRAM 容量本身对替换策略的影响。first_touch 按 trace 中首次出现顺序分配，反映简单页面放置的实际情况。

## Benchmarks

**动态指定** — 实验脚本的命令行参数传入，不硬编码。traces/ 目录下 `.champsimtrace.xz` 和 `.champsim.trace.xz` 格式均可。

示例 12 workloads: astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp

## Task Count

N benchmarks × 7 ratios × 2 placements × 4 policies = **N × 56 tasks**

## Filter Rule

无 — 全部 336 tasks 均保留。IPC ≤ 0 的 run 标记为异常。

## Metrics to Collect

| Metric | Source |
|--------|--------|
| IPC | `grep "CPU 0 cumulative IPC"` from raw output |
| MPKI | 从 raw output 解析 LLC misses per 1000 instructions |
| LLC Miss Distribution | `llc_miss_by_area[0]` (DRAM) 和 `llc_miss_by_area[2]` (CXL) |
| DRAM/CXL access ratio | `sim_dram_accesses` / `sim_cxl_accesses` |
| Average Miss Latency | `AVERAGE MISS LATENCY` from raw output |

## Auxiliary Checks

1. **All tasks complete:** 336 tasks dispatched, 336 completed with exit=0
2. **Zero failures:** No builds fail, no simulator crashes
3. **IPC > 0:** All simulation results produce valid IPC values
4. **Ratio correctness:** 每个 area_map 的 area0 页面数等于指定的 `K = floor(ratio × total_pages)`
5. **IPC monotonicity:** IPC 应随 DRAM 比例增加而单调递增（DRAM 越多 → 平均访存延迟越低 → IPC 越高）
6. **No migration logs:** raw output 中不应出现 `[migration]` 行
7. **0% DRAM sanity:** 0% DRAM 时 `sim_dram_accesses = 0`，所有 miss 走 CXL
8. **100% DRAM sanity:** 100% DRAM 时 `sim_cxl_accesses = 0`，所有 miss 走 DRAM

## How to Run

```bash
# 一键运行（推荐）：
bash scripts/run_task4.1_full.sh <trace1.xz> <trace2.xz> ...

# 自定义参数：
TASK4_1_SIM=500000000 bash scripts/run_task4.1_full.sh traces/*.xz

# 分步运行：
# Step 1: 为 7 个比例 × 2 个 placement 生成 area_map
bash scripts/run_task4.1_gen_areamaps.sh <traces...>
# Step 2: 构建 4 个 policy 的二进制 (1-core, no prefetch)
bash scripts/run_task4.1_build.sh
# Step 3: 运行完整实验矩阵
bash scripts/run_task4.1_dram_ratio.sh <traces...>
```

## Output Structure

```
artifacts/
  plans/task4.1-dram-ratio/
    PLAN.md              <- this file
    run.sh               <- symlink to scripts/run_task4.1_dram_ratio.sh (auto)
    SUMMARY.log          <- symlink to latest main.log (auto)
    CONCLUSIONS.md       <- auto-generated after run (含 geomean 对比表和趋势图数据)

  runs/task4.1-dram-ratio/
    latest -> <timestamp>
    <YYYYMMDD-HHMMSS>/
      execution.log      <- control plane (336 TASK DISPATCH/DONE)
      main.log           <- global log, 含按 ratio 汇总的 IPC geomean
      build_{lru,hawkeye,mockingjay,rpp}.log

      # Area maps (N benchmarks × 7 ratios × 2 placements = 14N files)
      area_maps/
        {benchmark}_{placement}_ratio000.amap
        {benchmark}_{placement}_ratio010.amap
        {benchmark}_{placement}_ratio030.amap
        {benchmark}_{placement}_ratio050.amap
        {benchmark}_{placement}_ratio070.amap
        {benchmark}_{placement}_ratio090.amap
        {benchmark}_{placement}_ratio100.amap
        # placement = random | first_touch

      # Simulation results
      {benchmark}_random_ratio{XXX}_{policy}.raw
      {benchmark}_random_ratio{XXX}_{policy}.sub.log
```

## Expected Comparison Tables

### Table 1: IPC Geomean (12 benchmarks) — Policy × Ratio

| DRAM Ratio | LRU | Hawkeye | MockingJay | RPP |
|------------|-----|---------|------------|-----|
| 0% | — | — | — | — |
| 10% | — | — | — | — |
| 30% | — | — | — | — |
| 50% | — | — | — | — |
| 70% | — | — | — | — |
| 90% | — | — | — | — |
| 100% | — | — | — | — |

### Table 2: Speedup vs LRU (geomean) — Policy × Ratio

| DRAM Ratio | Hawkeye/LRU | MockingJay/LRU | RPP/LRU |
|------------|-------------|----------------|---------|
| 0% | — | — | — |
| 10% | — | — | — |
| 30% | — | — | — |
| 50% | — | — | — |
| 70% | — | — | — |
| 90% | — | — | — |
| 100% | — | — | — |

### Table 3: RPP vs MockingJay (geomean) — Ratio

| DRAM Ratio | RPP/MJ |
|------------|--------|
| 0% | — |
| 10% | — |
| 30% | — |
| 50% | — |
| 70% | — |
| 90% | — |
| 100% | — |

### Expected Trend

- **IPC 应随 DRAM 比例增加单调递增**：DRAM 延迟远低于 CXL (CXL tRP/tRCD/tCAS ≈ 3.3× DRAM)，更多页在 DRAM 意味着更低的平均 miss latency
- **RPP 在所有比例下应 ≥ MJ**：RPP 的 latency-aware 设计在 DRAM 稀缺时优势应更明显（因为 CXL miss 的代价更大）
- **100% DRAM 时策略间差异最小**：此时没有 CXL 延迟差异，latency-aware 策略退化，各策略差异应缩小
- **0% DRAM 时 IPC 最低**：所有 miss 走 CXL，平均延迟最高
