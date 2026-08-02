# L1D Bandwidth-Constrained Experiment

## Goal

验证内存带宽受限场景下，无限带宽条件下的最优 prefetcher 排名是否发生变化。量化每个 prefetcher 对 DRAM 带宽的压力，观察激进型 vs 保守型 prefetcher 在带宽约束下的表现差异。

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Replacement (all levels) | LRU |
| L1I / L2C / LLC prefetch | no |
| L1D prefetch | varies (27 configs) |
| Warmup | 1,000,000 instructions |
| Simulation | 10,000,000 instructions |
| Parallelism | JOBS=90 |

## Bandwidth Levels

| Level | data_rate (MT/s) | 等效峰值带宽 | 模拟场景 |
|-------|-----------------|-------------|---------|
| bw3200 (baseline) | 3200 | 25.6 GB/s | 桌面/服务器 |
| bw1600 | 1600 | 12.8 GB/s | 低功耗/共享 |
| bw800 | 800 | 6.4 GB/s | 极端受限 |

通过修改 ChampSim config 中 `physical_memory.data_rate` 实现。

## Traces

同 l1d-baseline-batch（12 条 SPEC06 trace）。

## Pipeline

```
Step 1: gen_bw_configs.py → configs/l1d-bw/{bw1600,bw800}/*.json
Step 2: Build bw1600/bw800 binaries (sequential, ~54 builds)
Step 3: Run all (trace × prefetcher × bw_level) in parallel
Step 4: compare_bw.py → ranking comparison table
```

## How to Run

```bash
cd ChampSim
JOBS=90 bash scripts/run_bw_experiment.sh [warmup] [sim]
```

## Output Structure

```
artifacts/runs/l1d-bw/<timestamp>/
  <trace_name>/
    bw1600/             ← per-prefetcher eval stdout
    bw800/
  logs/                 ← build logs
```

## Key Results

- **10/12 traces 排名发生变化**（bw3200 vs bw1600 vs bw800）
- bw1600 下 5/12 traces 最优 prefetcher 切换
- 趋势：激进型（stream, dspatch, mlop）退化，保守精准型（ppf, power7, next_line）上升
- zeusmp/mcf 最稳定：next_line 在任何带宽下都最优
- bw800 数据异常（IPC 反升），疑似 DRAM 模型在极低 data_rate 下的数值问题，待排查

## Auxiliary: Bandwidth Pressure Stats

`parse_bandwidth.py` 从 l1d-baseline-batch 的 eval 输出中提取：
- L1D PF Issued（预取请求总数）
- LLC Total Miss（DRAM 请求数）
- LLC PF Miss（预取导致的 DRAM 请求）
- 等效 DRAM BW 需求 (GB/s)

产出: `artifacts/runs/l1d-baseline-batch/20260801-121706/bandwidth_stats.csv`
