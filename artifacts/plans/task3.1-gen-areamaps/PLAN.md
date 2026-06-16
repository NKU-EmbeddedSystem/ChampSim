# Stage 3.1: Generate Area Maps

**Spec:** N/A

## Goal

从 12 个 unique-workload ChampSim traces 生成 binary area_map (`.amap`) 文件，支持 sort_heat 和 first_touch 两种 placement 策略。area_map 用于 Stage 3.2 的 deterministic page placement。

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Trace 格式 | ChampSim input_instr (64-byte records, gz/xz compressed) |
| 内存地址来源 | source_memory[4] + destination_memory[2] |
| Page size | 4096 (4KB) |
| area_map 格式 | binary: magic(4B="AREA") + version(4B=1) + num_entries(8B) + [{page_id(8B), area(1B)}] |
| area 含义 | 0=DRAM, 1=CXL |
| DRAM pages (K) | 来自 Task 3.0 的 `pages.jsonl`，公式 `min(WSS × 0.3, 262144)` |
| MAX_PARALLEL | 4 |

## Candidates (2 strategies)

| Index | Strategy | Description |
|-------|----------|-------------|
| 0 | sort_heat | Pass 1: count accesses per page → sort desc → top-K=area0, rest=area1 |
| 1 | first_touch | Single pass: first K distinct pages → area0, rest → area1 |

## Candidates (12 benchmarks)

astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp

## Filter Rule

无 — 为全部 12 个 benchmark × 2 种 strategy 生成 area_map。

## Auxiliary Checks

1. **Magic bytes correct:** 每个 `.amap` 文件头 4 字节为 `AREA` (0x41524541)
2. **Entries sorted:** entries 按 page_id 升序排列
3. **Area=0 count ≤ K:** DRAM page 数不超过 K
4. **All 24 files generated:** 12 benchmarks × 2 strategies = 24 `.amap` files

## How to Run

```bash
bash scripts/run_task3.1_gen_areamaps.sh
```

## Output Structure

```
artifacts/
  plans/task3.1-gen-areamaps/
    PLAN.md              <- this file
    run.sh               <- symlink to scripts/run_task3.1_gen_areamaps.sh (auto)
    SUMMARY.log          <- symlink to latest main.log (auto)
    CONCLUSIONS.md       <- auto-generated after run

  runs/task3.1-gen-areamaps/
    latest -> <timestamp>
    <YYYYMMDD-HHMMSS>/
      execution.log
      main.log
      {benchmark}_{strategy}.amap       <- binary area map
      {benchmark}_{strategy}.sub.log
      {benchmark}_{strategy}.raw
```
