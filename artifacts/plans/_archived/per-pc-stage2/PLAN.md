# Stage 2: Oracle Per-PC Hint Dispatch (B1 vs B2)

**Spec:** `.omc/specs/deep-interview-pc-split-oracle-20260523.md`

## Goal

Compare B1 (best single-policy IPC from Stage 1) vs B2 (Oracle Per-PC Hint Dispatch IPC) on retained traces. Verify **B2 geomean IPC > Best-B1 geomean IPC**.

## Pipeline

```
Stage 1 profiling data (.profile.jsonl)
    │
    ▼
┌──────────────────────────────────┐
│ 1. Prepare                       │  Rename {pref}.profile.jsonl →
│                                  │  {bench}__{pref}__{degree}.json
└──────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────┐
│ 2. Aggregate                     │  aggregate_ground_truth.py
│                                  │  Per-PC: pick lowest AMAT prefetcher
└──────────────────────────────────┘
    │  → labels.jsonl (string names)
    ▼
┌──────────────────────────────────┐
│ 3. Convert                       │  Map prefetch name → index
│                                  │  best_prefetch "ip_stride" → 2
└──────────────────────────────────┘
    │  → labels_indexed.jsonl (integer indices)
    ▼
┌──────────────────────────────────┐
│ 4. Hint Generation               │  oracle_gen.py profile
│                                  │  → hints.bin (binary format)
└──────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────┐
│ 5. Evaluation                    │  champsim_hint_eval
│                                  │  --hint-file hints.bin <trace>
└──────────────────────────────────┘
    │
    ▼
  B2 IPC  vs  Best-B1 IPC
```

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Replacement (all levels) | LRU |
| L1I prefetch | no |
| L1D prefetch | hint_dispatch (loads hints.bin) |
| L2C prefetch | no |
| LLC prefetch | no |
| Hint file | hints.bin (from oracle pipeline) |
| Warmup | 1,000,000 instructions |
| Simulation | 10,000,000 instructions |

## Prefetcher Index Mapping

| Index | Prefetcher |
|-------|-----------|
| 0 | no |
| 1 | next_line |
| 2 | ip_stride |
| 3 | spp_dev |
| 4 | va_ampm_lite |

## B1 Baseline (from Stage 1)

Stage 1 already produced B1 data for trace `602.gcc_s-1850B`:

| Prefetcher | IPC |
|------------|-----|
| no | 0.2569 |
| next_line | 0.4407 |
| ip_stride | 0.564 |
| spp_dev | 0.5616 |
| va_ampm_lite | **0.6982** (best) |

Best-B1 = va_ampm_lite, IPC = 0.6982

## B2 Oracle Evaluation

1. Use Stage 1 profiling data (5 × `.profile.jsonl`)
2. `aggregate_ground_truth.py` compares per-PC AMAT across 5 prefetchers
3. For each PC, select prefetcher with lowest AMAT as oracle label
4. Generate `hints.bin` encoding per-PC oracle selections
5. Run `champsim_hint_eval --hint-file hints.bin` on same trace
6. Record B2 IPC

## Primary Judgment

- B2 geomean IPC > Best-B1 geomean IPC → **reproduction success** (no minimum gap required)

## Auxiliary Checks

| # | Check | Source | Expected |
|---|-------|--------|----------|
| 1 | Prefetcher distribution | `aggregate_ground_truth.py` output | If 90%+ pick same → B2 ≈ single policy, small gap is normal |
| 2 | PF accuracy: B2 vs B1-best | ChampSim L1D stats | B2 accuracy ≥ B1-best accuracy |
| 3 | Dispatch correctness | Profiler JSON `active_prefetch_policy` vs hints.bin `prefetch_index` | Same PC → same index |
| 4 | PF volume: B2 vs B1-best | ChampSim L1D `pf_issued` | B2 should not significantly exceed B1-best |

## How to Run

```bash
cd ChampSim
bash scripts/run_stage2.sh <trace.xz> [warmup] [sim]
```

## Output Structure

```
artifacts/
  plans/stage2/
    PLAN.md              ← this file
    run_stage2.sh        ← symlink to ../../../scripts/run_stage2.sh
    SUMMARY.log          ← symlink to ../../runs/stage2/latest/main.log
    CONCLUSIONS.md       ← auto-generated after run

  runs/stage2/
    latest → <timestamp>
    <timestamp>/
      main.log                  ← main log
      prepare.log               ← data preparation log
      labels.jsonl              ← aggregate output (string names)
      labels_indexed.jsonl      ← converted labels (integer indices)
      hints.bin                 ← oracle hint binary
      aggregate.log             ← aggregate stdout
      hint_gen.log              ← hint generation stdout
      eval.raw                  ← ChampSim hint_eval raw output
      eval.sub.log              ← evaluation sub-log
      eval.profile.jsonl        ← hint_dispatch profiling output
```
