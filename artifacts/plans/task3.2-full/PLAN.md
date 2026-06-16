# Stage 3.2: Full Sweep — Placement × Migration × Policy

**Spec:** N/A

## Goal

在 12 个 unique-workload ChampSim traces 上评估 7 种 placement+migration 配置 × 4 种 LLC 替换策略的完整实验矩阵。验证 page placement 对 prefetcher-based simulator 的影响，以及 PageMigrationEngine 的有效性。

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Warmup | 50M instructions |
| Simulation | 100M instructions |
| Branch predictor | hashed_perceptron |
| Prefetchers | no (all levels) |
| DRAM:CXL ratio | Fixed 1:2 by distinct 4KB pages in each area_map |
| DRAM pages (K) | Auto-derived as `floor(distinct_pages / 3)` when generating each area_map; no Task 3.0 `pages.jsonl` dependency |
| Page size | 4KB |
| Cores | 1 |
| MAX_PARALLEL | 12 |

## Candidates (7 configs)

| Index | Placement | Migration | Description |
|-------|-----------|-----------|-------------|
| 0 | baseline | none | Deterministic random area_map with DRAM:CXL=1:2 |
| 1 | sort_heat | none | Offline heat sort + static placement |
| 2 | sort_heat | forward | + future nextAccess prediction migration |
| 3 | sort_heat | backward | + past heat count migration |
| 4 | first_touch | none | First-touch order placement |
| 5 | first_touch | forward | + future prediction migration |
| 6 | first_touch | backward | + past heat migration |

## Candidates (4 policies)

| Index | Policy | Description |
|-------|--------|-------------|
| 0 | lru | Baseline LRU |
| 1 | hawkeye | Hawkeye predictor-based |
| 2 | mockingjay | MockingJay (ML-based) |
| 3 | rpp | SilkLoom RPP (latency-aware) |

## Candidates (12 benchmarks)

astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp

## Filter Rule

无 — 全部 12 × 7 × 4 = 336 tasks 均保留。

## Auxiliary Checks

1. **All tasks complete:** 336 tasks dispatched, 336 completed with exit=0
2. **Zero failures:** No builds fail, no simulator crashes
3. **IPC > 0:** All simulation results produce valid IPC values
4. **Area stats:** When area_map is loaded, llc_miss_by_area shows DRAM+CXL distribution
5. **Migration logs:** When migration is enabled, [migration] log lines appear in raw output

## How to Run

```bash
bash scripts/run_task3.2_full.sh
```

## Output Structure

```
artifacts/
  plans/task3.2-full/
    PLAN.md              <- this file
    run.sh               <- symlink to scripts/run_task3.2_full.sh (auto)
    SUMMARY.log          <- symlink to latest main.log (auto)
    CONCLUSIONS.md       <- auto-generated after run

  runs/task3.2-full/
    latest -> <timestamp>
    <YYYYMMDD-HHMMSS>/
      execution.log      <- control plane (336 TASK DISPATCH/DONE)
      main.log           <- global log
      build_{lru,hawkeye,mockingjay,rpp}.log
      {benchmark}_{placement}_{migration}_{policy}.raw
      {benchmark}_{placement}_{migration}_{policy}.sub.log
```
