# Stage 3: Per-PC × Context Oracle (B1 vs B2 vs B3)

**Spec:** `.omc/specs/deep-interview-pc-split-oracle-20260523.md`

## Goal

Compare B1 (best single-policy IPC from Stage 1) vs B2 (per-PC Oracle from Stage 2) vs B3 (per-PC × context Oracle) on retained traces. Verify **B3 IPC > B2 IPC** to determine if context splitting provides additional value.

## Pipeline

```
Stage 1 profiling data (.profile.jsonl)
    │
    ▼
┌──────────────────────────────────┐
│ 1. Load B1 & B2                  │  Read Stage 1 & 2 results
│                                  │  B1: best single-policy IPC
│                                  │  B2: per-PC Oracle IPC
└──────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────┐
│ 2. Build Context Profiling       │  Compile with -DHINT_CONTEXT_PROFILING
│                                  │  5 prefetcher binaries
└──────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────┐
│ 3. Context Profiling             │  Run 5 prefetchers with context extraction
│                                  │  Output: per-(PC, context_key) AMAT
└──────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────┐
│ 4. Context-Aware Aggregation     │  aggregate_context_ground_truth.py
│                                  │  Per-extractor: pick lowest AMAT prefetcher
└──────────────────────────────────┘
    │  → labels_ctx.{extractor}.jsonl (4 files)
    ▼
┌──────────────────────────────────┐
│ 5. Generate v2 hints.bin         │  oracle_gen.py context-profile
│                                  │  → hints_v2_{extractor}.bin (4 files)
└──────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────┐
│ 6. Build Context Eval Binaries   │  Compile with CONTEXT_FEATURE=1,2,3,4
│                                  │  4 hint_dispatch binaries
└──────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────┐
│ 7. Evaluate B3                   │  Run 4 evaluations (one per extractor)
│                                  │  → B3-page_offset IPC
│                                  │  → B3-delta_signature IPC
│                                  │  → B3-recent_pc_hash IPC
│                                  │  → B3-composite IPC
└──────────────────────────────────┘
    │
    ▼
  B3 (best) vs B2 vs B1
```

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Replacement (all levels) | LRU |
| L1I prefetch | no |
| L1D prefetch | hint_dispatch (loads hints.bin) |
| L2C prefetch | no |
| LLC prefetch | no |
| Hint file | hints_v2_{extractor}.bin (from oracle pipeline) |
| Warmup | 1,000,000 instructions |
| Simulation | 10,000,000 instructions |

## Context Extractor Mapping

| Index | Extractor | Description |
|-------|-----------|-------------|
| 0 | NONE | No context (baseline, Stage 2) |
| 1 | page_offset | Page number + offset |
| 2 | delta_signature | Rolling signature of address deltas |
| 3 | recent_pc_hash | XOR-fold of recent PC history |
| 4 | composite | Delta signature + page offset |

## B1 Baseline (from Stage 1)

Stage 1 produced B1 data for trace `602.gcc_s-1850B`:

| Prefetcher | IPC |
|------------|-----|
| no | 0.2569 |
| next_line | 0.4407 |
| ip_stride | 0.564 |
| spp_dev | 0.5616 |
| va_ampm_lite | **0.6982** (best) |

Best-B1 = va_ampm_lite, IPC = 0.6982

## B2 Oracle (from Stage 2)

Stage 2 produced B2 (per-PC Oracle):

| Metric | Value |
|--------|-------|
| IPC | 0.7224 |
| Gap vs B1 | +3.46% |
| Verdict | PASS |

## B3 Oracle Evaluation

1. Rebuild 5 prefetcher binaries with `-DHINT_CONTEXT_PROFILING`
2. Run profiling to collect per-(PC, context_key) AMAT for all 4 extractors
3. `aggregate_context_ground_truth.py` compares per-(PC, context_key) AMAT across 5 prefetchers
4. For each (PC, context_key), select prefetcher with lowest AMAT as oracle label
5. Generate `hints_v2_{extractor}.bin` encoding per-(PC, context) oracle selections
6. Build 4 evaluation binaries with `CONTEXT_FEATURE=1,2,3,4`
7. Run each evaluation binary on same trace
8. Record B3 IPC for each extractor

## Primary Judgment

- B3 (best extractor) IPC > B2 IPC → **context splitting provides value**
- B3 (best extractor) IPC ≤ B2 IPC → **per-PC granularity is sufficient**

## Auxiliary Checks

| # | Check | Source | Expected |
|---|-------|--------|----------|
| 1 | Context key distribution | `aggregate_context_ground_truth.py` output | Reasonable granularity (not too few or too many keys) |
| 2 | Prefetcher distribution | Aggregation output | If 90%+ pick same → B3 ≈ B2, small gap is normal |
| 3 | PF accuracy: B3 vs B2 | ChampSim L1D stats | B3 accuracy ≥ B2 accuracy |
| 4 | Dispatch correctness | Profiler JSON vs hints_v2.bin | Same (PC, context) → same policy |
| 5 | PF volume: B3 vs B2 | ChampSim L1D `pf_issued` | B3 should not significantly exceed B2 |

## How to Run

```bash
cd ChampSim
bash scripts/run_stage3.sh <trace.xz> [warmup] [sim]
```

## Output Structure

```
artifacts/
  plans/stage3/
    PLAN.md              ← this file
    run_stage3.sh        ← symlink to ../../../scripts/run_stage3.sh
    SUMMARY.log          ← symlink to ../../runs/stage3/latest/main.log
    CONCLUSIONS.md       ← auto-generated after run

  runs/stage3/
    latest → <timestamp>
    <timestamp>/
      main.log                          ← main log
      build.log                         ← context profiling build log
      eval_build.log                    ← evaluation binary build log
      aggregate_context.log             ← context aggregation stdout
      profiling/                        ← raw profiling outputs
        {trace}__{pref}__1.json         ← per-(PC, context) profiling data
      labels_ctx.{extractor}.jsonl      ← context-aware oracle labels (4 files)
      hints_v2_{extractor}.bin          ← v2 hint binaries (4 files)
      eval_{extractor}.raw              ← evaluation raw outputs (4 files)
```

## Design Notes

### Context Key Computation

Context keys are computed from `(pc, addr)` and access history, independent of which prefetcher is active. This ensures fair comparison across prefetchers.

### v2 Hint Format

v2 hints use 24B entries (vs 16B for v1):
- PC (8B)
- replacement_index (1B)
- prefetch_index (1B)
- prefetch_degree (1B)
- demand_filter (1B)
- reserved (4B)
- **context_key (8B)** ← new in v2

### Profiling Overhead

Context profiling adds minimal overhead:
- 4 context extractors run per cache access
- Each extractor computes a uint64_t context key
- Keys are stored in profiler records for aggregation

### Stage Isolation

Stage 3 is fully isolated from Stage 1/2:
- `-DHINT_CONTEXT_PROFILING` is only used for Stage 3 profiling
- `CONTEXT_FEATURE=N` is only used for Stage 3 evaluation
- Stage 1/2 binaries and results are not modified
