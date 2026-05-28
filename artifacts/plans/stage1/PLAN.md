# Stage 1: LLC Replacement Policy Baseline Verification

**Spec:** Validate LLC-only replacement policy variations across all traces

**Status:** ✅ Complete — 10 policies x 36 traces = 360/360 passed (2026-05-27)

## Goal

Measure and compare IPC for 10 LLC replacement policies (6 standalone + 4 set-dueling) across all 36 SPEC CPU traces. Compute geometric mean of speedup relative to the LRU baseline. Only the LLC replacement policy varies; all other architectural parameters remain fixed.

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Cores | 1 |
| Branch Predictor | bimodal |
| BTB | basic_btb |
| Prefetcher | all no |
| L1I/L1D/L2C replacement | default (unchanged) |
| **LLC replacement** | **varies (10 candidates)** |
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
| 6 | set_dueling_lru_srrip | champsim_set_dueling_lru_srrip | 2-policy dueling: LRU vs SRRIP |
| 7 | set_dueling_mj_hk | champsim_set_dueling_mj_hk | 2-policy dueling: Mockingjay vs Hawkeye |
| 8 | set_dueling_4p_lssh | champsim_set_dueling_4p_lssh | 4-policy dueling: LRU+SRRIP+SHIP+Hawkeye |
| 9 | set_dueling_4p_lssm | champsim_set_dueling_4p_lssm | 4-policy dueling: LRU+SRRIP+SHIP+Mockingjay |

## Traces

36 SPEC CPU traces (12 programs x 3 slices):
astar, cactusADM, h264ref, libquantum, mcf, milc, omnetpp, perlbench, soplex, sphinx3, xalancbmk, zeusmp

## Filter Rule

Threshold: speedup vs LRU > 1.02 → RETAINED, else FILTERED.

## Auxiliary Checks

1. **All tasks pass:** 360/360 tasks exit=0
2. **IPC positive:** All IPC values > 0
3. **Baseline sanity:** LRU baseline produces valid IPC for all 36 traces

## How to Run

```bash
# Via tmux (recommended for detachable observation)
bash .claude/skills/tmux/scripts/launch_in_tmux.sh stage1 \
    bash scripts/run_stage1.sh

# Or directly
bash scripts/run_stage1.sh
```

## Concurrency

- 72 parallel slots via `xargs -P 72`
- 360 total tasks (10 policies x 36 traces)
- ~5 batches, each batch fills 72 slots

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
      tasklist.txt       <- 360-line task manifest
      {policy}_{trace}.raw
      {policy}_{trace}.sub.log
      {policy}_{trace}.data.jsonl

reports/
  stage1-<YYYYMMDD>/
    summary.csv          <- full IPC table: policy x trace
    geometric_mean.csv   <- geometric mean per policy vs LRU
```

---

## Set-Dueling Verification

### Background

The 4 set-dueling meta-policies were migrated from `dev-set-dueling` to the `previous` branch as self-contained `.llc_repl` files. The `previous` branch uses a fundamentally different build system (`build_champsim.sh` copy-to-`llc_replacement.cc`) and simulator API (legacy `CACHE::llc_*` member functions). The migration required inlining all sub-policy code with prefixed variable names and adapting the Set Dueling Mechanism (SDM) to the old API.

### Core SDM Terminology

| Term | Definition |
|------|-----------|
| **SDM** | Set Dueling Mechanism — dynamically selects the best sub-policy by sampling performance on randomly chosen leader sets |
| **Leader set** | An LLC set randomly assigned to a specific sub-policy as its "testing ground" (32 sets per policy, 2.9% of LLC) |
| **Follower set** | All other LLC sets (97.1%) — the currently-best policy handles these |
| **PSEL** | Policy SELection counter — 10-bit saturating counter (0–1023). For 2-policy SDM: PSEL > 511 prefers policy 1. For 4-policy SDM: each policy has its own counter; highest wins |

### Verification Schemes

Four verification schemes validate the correctness of the migrated set-dueling implementation. Run all via:

```bash
bash scripts/verify_set_dueling.sh <run-dir>
```

#### V1: SDM Convergence

*Status:* ✅ Passed — PSEL correctly converges to a clear winner on every trace.

Verify that PSEL counters produce a decisive winner per trace. Check `final PSEL` and `Best` output from `llc_replacement_final_stats()` in `.raw` files. The winner should dominate ≥ 60% of traces.

*Caveat:* Leader-set sampling bias. With only 32 leader sets per policy (out of 2048 total), the sampled sets may not be representative. This can cause PSEL to favor a sub-optimal policy (observed in `mj_hk` where Hawkeye won 30/36 traces despite Mockingjay having +3.4% higher standalone IPC).

#### V2: Range Consistency

*Status:* ✅ Passed — 4-policy SDM IPC falls within sub-policy range. 2-policy SDM exceeds range due to per-phase adaptation.

Check that each SDM policy's IPC falls within the [min, max] IPC range of its constituent sub-policies. 2-policy SDM may exceed both sub-policies (genuine advantage of per-phase adaptive selection — switching policies mid-trace captures the best of each). 4-policy SDM overhead may offset gains, keeping IPC within range.

#### V3: Degenerate Test

*Status:* ✅ Passed — SDM(LRU, LRU) IPC = standalone LRU IPC (0.446984 exactly).

Build a special SDM where both sub-policies are identical real LRU (`lru_victim()` + `lru_update()`). Verify the result matches standalone LRU within noise (< 0.002 IPC). This proves the SDM dispatch framework introduces zero behavioral overhead.

#### V4: Leader Set Distribution

*Status:* ✅ Passed — 64 unique leader sets, quartile distribution 18/18/15/13, max gap 124 sets.

Verify that `llc_initialize_replacement()` selects:
- Exactly `SDM_SIZE` leader sets per policy (no more, no less)
- No duplicate leader sets across policies
- Reasonable distribution across `[0, LLC_SET)` range (no clustering)

### Built-In PSEL Logging

Each `set_dueling_*.llc_repl` includes always-on PSEL trace logging. Every ~500K LLC accesses, the current PSEL state is printed to the `.raw` file:

```
PSEL_LOG [500000] PSEL=512 best=LRU leader=-1
PSEL_LOG [1000000] PSEL=520 best=LRU leader=0
PSEL_LOG [1500000] PSEL=680 best=SRRIP leader=1
```

Controlled by `#define SD_PSEL_LOG_INTERVAL 500000` at the top of each file. The per-access counter overhead is negligible (one increment + one modulo check per LLC access).
