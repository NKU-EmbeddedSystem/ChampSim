# L1D Baseline: Full Prefetcher × Degree Profiling + Oracle Hint Evaluation

## Goal

在 L1D 上对 14 个 prefetcher × 多个 degree 组合进行 per-PC AMAT profiling，生成 oracle hint 表，评估 per-PC dispatch 相对于最佳单一 prefetcher 的 IPC 收益。

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Replacement (all levels) | LRU |
| L1I prefetch | no |
| L2C prefetch | no |
| LLC prefetch | no |
| L1D prefetch | **varies** (14 candidates × multiple degrees) |
| Warmup | 1,000,000 instructions |
| Simulation | 10,000,000 instructions |

## Candidate Prefetchers × Degrees

| Index | Prefetcher | Degrees | 备注 |
|-------|-----------|---------|------|
| 0 | no | 1 | baseline |
| 1 | next_line | 1 | 固定 |
| 2 | ip_stride | 1, 2, 4 | |
| 4 | va_ampm_lite | 1, 2 | |
| 5 | stride | 1, 2, 4 | |
| 6 | stream | 1, 2, 4 | |
| 7 | ampm | 1, 2, 4 | |
| 8 | sms | 1, 4 | |
| 9 | bingo | 1 | adaptive |
| 10 | sandbox | 1, 4 | |
| 11 | power7 | 1 | adaptive |
| 12 | dspatch | 4, 8 | |
| 13 | mlop | 1, 4 | |
| 14 | ppf | 1 | adaptive |

spp_dev (idx 3) 排除（已知 crash）。共 27 个配置。

## Pipeline

```
Phase A: Profiling (并行)
  ├── 27 个 L1D-only binary 分别跑 trace
  ├── 每个输出 per-PC AMAT JSONL
  └── 产出: profiling/{bench}__{pref}__{deg}.json

Phase B: Oracle Label 聚合
  ├── aggregate_ground_truth.py 比较 per-PC AMAT
  ├── 每个 PC 选最低 AMAT 的 (prefetcher, degree)
  └── 产出: ground_truth.jsonl

Phase C: Hint 生成
  ├── oracle_gen.py 将 label 编码为 v1 二进制
  └── 产出: hint.bin (16B/entry)

Phase D: Evaluation
  ├── B0: champsim_no (L1D=no, 无预取)
  ├── B1: 最佳单一 prefetcher (从 Phase A 的 IPC 中选)
  ├── B2: champsim_hint_eval --hint-file hint.bin (oracle per-PC)
  └── 产出: eval/{b0,b1,b2}.txt

Phase E: 指标对比
  ├── IPC, L1D hit rate, prefetch accuracy/coverage/count
  └── 产出: comparison table
```

## Primary Judgment

- B2 IPC > B1 IPC → per-PC oracle 有收益
- B2 IPC > B0 IPC → hint dispatch 整体有效

## Auxiliary Checks

| # | Check | Expected |
|---|-------|----------|
| 1 | Prefetcher distribution | 不应 90%+ 选同一个（否则 B2 ≈ B1） |
| 2 | PF accuracy: B2 vs B1 | B2 ≥ B1 |
| 3 | PF volume: B2 vs B1 | B2 不应显著超过 B1（避免带宽浪费） |
| 4 | Degree distribution | 观察 degree 选择是否集中在某个值 |

## How to Run

```bash
cd ChampSim
bash scripts/run_l1d_baseline.sh <trace.xz> [warmup] [sim]
```

或分步：
```bash
# 生成配置
python3 tools/l1d_hint_demo/gen_configs.py

# 构建 + profiling + 聚合 + 评估（一键）
bash tools/l1d_hint_demo/run_demo.sh <trace.xz>
```

## Output Structure

```
artifacts/
  plans/l1d-baseline/
    PLAN.md              ← this file
    CONCLUSIONS.md       ← auto-generated after run

  runs/l1d-baseline/
    <timestamp>/
      main.log                  ← 主日志
      profiling/                ← Phase A 产出
        {bench}__{pref}__{deg}.json
      ground_truth.jsonl        ← Phase B 产出
      hint.bin                  ← Phase C 产出
      eval/
        b0_no.txt               ← B0 baseline
        b1_best.txt             ← B1 best single
        b2_hint.txt             ← B2 oracle hint
      comparison.txt            ← Phase E 对比表
```

## Target Benchmarks

| Trace | 类型 | 用途 |
|-------|------|------|
| 602.gcc_s-1850B | Mixed (compiler) | 已有 trace，首选验证 |
| SPEC06 其他 | — | 待生成 trace 后扩展 |

## Degree 控制机制

- **Profiling 时**: 编译时宏注入（`-DSTRIDE_PREF_DEGREE=N` 等），每个 (pref, deg) 一个 binary
- **Evaluation 时**: hint.bin 中 `prefetch_degree` 字段 → hint_dispatch 通过 metadata 传给 sub-prefetcher → pythia_adapter 截断 pf_addrs

## 与旧 Stage 的关系

旧 stage1/2/3（per-PC oracle 验证）已归档至 `artifacts/plans/_archived/`。本实验是其后继：
- 候选集从 5 → 14 个 prefetcher
- 新增 degree 维度
- 所有 prefetcher 限制在 L1D（旧版也是 L1D-only）
- 不再研究 per-PC × context（Stage 3 方向已放弃）
