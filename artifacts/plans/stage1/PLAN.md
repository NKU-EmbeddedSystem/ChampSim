# Stage 1: LLC Replacement Policy Baseline Verification

**Spec:** Validate LLC-only replacement policy variations across all traces

## Goal

Measure and compare IPC for 11 LLC replacement policies (7 standalone + 4 set-dueling combinations) across all 36 SPEC CPU traces. Compute geometric mean of speedup relative to the LRU baseline. Only the LLC replacement policy varies; all other architectural parameters remain fixed.

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Cores | 1 |
| Branch Predictor | bimodal |
| BTB | basic_btb |
| Prefetcher | all no |
| L1I/L1D/L2C replacement | default (unchanged) |
| **LLC replacement** | **varies (11 candidates)** |
| Warmup | 50,000,000 instructions |
| Simulation | 200,000,000 instructions |

## Candidates

| Index | Name | Binary | Description |
|-------|------|--------|-------------|
| 0 | lru | champsim_lru | Baseline LRU |
| 1 | srrip | champsim_srrip | Static Re-reference Interval Prediction |
| 2 | drrip | champsim_drrip | Dynamic RRP |
| 3 | ship | champsim_ship | Signature-based Hit Predictor |
| 4 | hawkeye | champsim_hawkeye | Hawkeye |
| 5 | mockingjay | champsim_mockingjay | Mockingjay |
| 6 | random | champsim_random | Random replacement |
| 7 | set_dueling_lru_srrip | champsim_set_dueling_lru_srrip | 2-policy dueling: LRU vs SRRIP |
| 8 | set_dueling_mj_hk | champsim_set_dueling_mj_hk | 2-policy dueling: Mockingjay vs Hawkeye |
| 9 | set_dueling_4p_lssh | champsim_set_dueling_4p_lssh | 4-policy dueling: LRU+SRRIP+SHIP+Hawkeye |
| 10 | set_dueling_4p_lssm | champsim_set_dueling_4p_lssm | 4-policy dueling: LRU+SRRIP+SHIP+Mockingjay |

## Traces

36 SPEC CPU traces (12 programs x 3 slices):
astar, cactusADM, h264ref, libquantum, mcf, milc, omnetpp, perlbench, soplex, sphinx3, xalancbmk, zeusmp

## Filter Rule

No filtering at this stage. All traces and policies are retained for analysis.

## Auxiliary Checks

1. **All tasks pass:** 396/396 tasks exit=0
2. **IPC positive:** All IPC values > 0
3. **Baseline sanity:** LRU baseline produces valid IPC for all 36 traces

## How to Run

```bash
# Via tmux (recommended for detachable observation)
bash .claude/skills/tmux/scripts/launch_in_tmux.sh stage1-replacement \
    bash scripts/run_stage1.sh

# Or directly
bash scripts/run_stage1.sh
```

## Concurrency

- 72 parallel slots via `xargs -P 72`
- 396 total tasks (11 policies x 36 traces)
- ~6 batches, each batch fills 72 slots

## Output Structure

```
artifacts/
  plans/stage1/
    PLAN.md              <- this file
    run_stage1.sh        <- symlink to scripts/run_stage1.sh (auto)
    SUMMARY.log          <- symlink to latest main.log (auto)
    CONCLUSIONS.md       <- auto-generated after run

  runs/stage1/
    latest -> <timestamp>
    <YYYYMMDD-HHMMSS>/
      execution.log      <- control plane
      main.log           <- global log
      tasklist.txt       <- 396-line task manifest
      lru/
        <trace>.raw
        <trace>.sub.log
        <trace>.data.jsonl
      srrip/
        ...
      (one subdir per policy)

reports/
  stage1-<YYYYMMDD>/
    summary.csv          <- full IPC table: policy x trace
    geometric_mean.csv   <- geometric mean per policy vs LRU
    comparison.md        <- comparison summary
```
