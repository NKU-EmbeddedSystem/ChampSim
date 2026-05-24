# Stage 1: L1D Prefetcher IPC Baseline

**Spec:** `.omc/specs/deep-interview-pc-split-oracle-20260523.md`

## Goal

Establish B1 baseline: IPC of 5 individual L1D prefetchers on each candidate trace.

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Replacement (all levels) | LRU |
| L1I prefetch | no |
| L2C prefetch | no |
| LLC prefetch | no |
| L1D prefetch | **varies** (5 candidates) |
| Prefetch degree | default |
| Warmup | 1,000,000 instructions |
| Simulation | 10,000,000 instructions |

## Candidate Prefetchers

| Index | Prefetcher |
|-------|-----------|
| 0 | no |
| 1 | next_line |
| 2 | ip_stride |
| 3 | spp_dev |
| 4 | va_ampm_lite |

## Trace Filter Rule

Best IPC / Worst IPC < 1.05 → filter trace

## Auxiliary Checks

1. **IPC sanity:** 0.1 < IPC < 4.0 for all prefetchers
2. **L1D hit rate vs IPC consistency:** hit rate ranking matches IPC ranking direction
3. **Per-prefetcher AMAT spread:** profiling records per-PC AMAT differences visible

## How to Run

```bash
cd ChampSim
bash scripts/run_stage1.sh <trace.xz> [warmup] [sim]
```

## Output Structure

```
artifacts/
  plans/stage1/
    PLAN.md              ← this file (write before execution)
    run_stage1.sh        ← symlink to ../../../scripts/run_stage1.sh (auto)
    SUMMARY.log          ← symlink to ../../runs/stage1/latest/main.log (auto)
    CONCLUSIONS.md       ← auto-generated after run

  runs/stage1/
    latest → <timestamp>              ← symlink to latest run (auto)
    <timestamp>/                       ← one directory per run (auto)
      main.log                         ← main log (all 5 sub-threads)
      {pref}.sub.log                   ← per-prefetcher sub-log
      {pref}.raw                       ← ChampSim raw stdout+stderr
      {pref}.profile.jsonl             ← per-PC profiling JSON
```
