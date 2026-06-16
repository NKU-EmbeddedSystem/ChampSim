# Stage 3.0: Prep — Page Count Survey

**Spec:** N/A

## Goal

统计 ChampSim trace 中所有 benchmark 的 distinct 4KB page 数量，作为工作集规模 survey。Stage 3 placement 的 DRAM:CXL=1:2 分配由 area_map 生成器直接从 trace distinct pages 自动推导，不再依赖本阶段输出作为 `--dram_pages` 输入。

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Page size | 4096 (4KB) |
| 统计粒度 | `addr / 4096` 去重 |
| Trace 格式 | ChampSim input_instr (64-byte records, gz/xz compressed) |
| 内存地址来源 | source_memory[4] + destination_memory[2] |
| DRAM pages 公式 | 信息性统计：`floor(WSS / 3)`；实验运行不从本阶段读取 K |
| MAX_PARALLEL | 8 |

## Candidates (12 unique workloads)

| Index | Name | Workload | Trace |
|-------|------|----------|-------|
| 0 | astar | astar_163B | trace/astar_163B.trace.xz |
| 1 | cactusADM | cactusADM_734B | trace/cactusADM_734B.trace.xz |
| 2 | h264ref | h264ref_178B | trace/h264ref_178B.trace.xz |
| 3 | libquantum | libquantum_964B | trace/libquantum_964B.trace.xz |
| 4 | mcf | mcf_46B | trace/mcf_46B.trace.xz |
| 5 | milc | milc_360B | trace/milc_360B.trace.xz |
| 6 | omnetpp | omnetpp_4B | trace/omnetpp_4B.trace.xz |
| 7 | perlbench | perlbench_53B | trace/perlbench_53B.trace.xz |
| 8 | soplex | soplex_66B | trace/soplex_66B.trace.xz |
| 9 | sphinx3 | sphinx3_883B | trace/sphinx3_883B.trace.xz |
| 10 | xalancbmk | xalancbmk_99B | trace/xalancbmk_99B.trace.xz |
| 11 | zeusmp | zeusmp_100B | trace/zeusmp_100B.trace.xz |

## Filter Rule

无 — 统计全部 12 个 trace（每 workload 一个代表）。

## Auxiliary Checks

1. **All traces found:** 12 个 benchmark 的 `.trace.xz` 文件均存在
2. **Non-zero WSS:** 每个 benchmark 的 `num_pages > 0`
3. **Results sorted:** `pages.jsonl` 按 WSS 升序排列
4. **Informational DRAM pages:** 输出 `floor(WSS / 3)` 仅用于记录，不作为 Stage 3.1/3.3 输入

## How to Run

```bash
bash scripts/run_task3.0_prep_pagecount.sh
```

## Output Structure

```
artifacts/
  plans/task3.0-prep-pagecount/
    PLAN.md              <- this file
    run.sh               <- symlink to scripts/run_task3.0_prep_pagecount.sh (auto)
    SUMMARY.log          <- symlink to latest main.log (auto)
    CONCLUSIONS.md       <- auto-generated after run

  runs/task3.0-prep-pagecount/
    latest -> <timestamp>
    <YYYYMMDD-HHMMSS>/
      execution.log      <- control plane
      main.log           <- global log
      {benchmark}.sub.log
      {benchmark}.raw
      {benchmark}.data.jsonl
      pages.jsonl        <- merged results
```
