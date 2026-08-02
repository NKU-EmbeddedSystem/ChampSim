# L1D Baseline Batch: Multi-Trace Prefetcher × Degree Profiling

## Goal

在 12 条 SPEC06 trace（每个 workload 选一条）上，对 14 个 prefetcher × 多个 degree 组合进行 L1D-only profiling，生成 per-trace oracle hint 表，评估 per-PC dispatch 相对于最佳单一 prefetcher 的 IPC 收益。

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Replacement (all levels) | LRU |
| L1I / L2C / LLC prefetch | no |
| L1D prefetch | varies (27 configs) |
| Warmup | 1,000,000 instructions |
| Simulation | 10,000,000 instructions |
| Parallelism | JOBS=90 (flat: all trace × binary pairs) |

## Traces

| Workload | Trace |
|----------|-------|
| astar | astar_163B |
| cactusADM | cactusADM_1039B |
| h264ref | h264ref_178B |
| libquantum | libquantum_1210B |
| mcf | mcf_158B |
| milc | milc_360B |
| omnetpp | omnetpp_17B |
| perlbench | perlbench_105B |
| soplex | soplex_205B |
| sphinx3 | sphinx3_1339B |
| xalancbmk | xalancbmk_748B |
| zeusmp | zeusmp_100B |

Source: `/mnt/sdd/trace/CRC2_trace/discriminative/`

## Pipeline

```
Phase 1: All (trace × binary) profiling sims in parallel (JOBS=90)
Phase 2: Per-trace aggregate → hint.bin → B2 eval (parallel)
```

## Comparison

- B0: no prefetch on L1D
- B1: best single (prefetcher, degree) per trace
- B2: oracle per-PC hint dispatch

## How to Run

```bash
cd ChampSim
JOBS=90 bash scripts/run_batch_l1d.sh [warmup] [sim]
```

## Output Structure

```
artifacts/runs/l1d-baseline-batch/<timestamp>/
  <trace_name>/
    profiling/          ← per-PC AMAT JSONL
    eval/               ← per-prefetcher ChampSim stdout
    ground_truth.jsonl
    hint.bin
  results.csv
```

## Key Results

- B2 > B1: 4/12 traces (astar, libquantum, omnetpp, perlbench)
- B2 > B0: 11/12 traces (xalancbmk regressed)
- Per-PC AMAT oracle 的价值有限，无法超越最佳单一 prefetcher 的全局覆盖优势
