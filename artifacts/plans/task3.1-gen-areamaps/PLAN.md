# Stage 3.1: Generate Area Maps

**Spec:** N/A

## Goal

从 12 个 unique-workload ChampSim traces 生成 binary area_map (`.amap`) 文件，支持 random、sort_heat 和 first_touch 三种 placement 策略。area_map 用于 Stage 3.2/3.3 的 deterministic page placement。

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Trace 格式 | ChampSim input_instr (64-byte records, gz/xz compressed) |
| 内存地址来源 | source_memory[4] + destination_memory[2] |
| Page size | 4096 (4KB) |
| area_map 格式 | binary: magic(4B="AREA") + version(4B=1) + num_entries(8B) + [{page_id(8B), area(1B)}] |
| area 含义 | 0=DRAM, 1=CXL |
| DRAM:CXL ratio | 固定 1:2 by target-window distinct 4KB pages |
| Instruction window | 每个实验规模单独生成：只读取 `[0, warmup+simulation)` 指令窗口 |
| DRAM pages (K) | 生成器读目标窗口后自动取 `floor(distinct_pages / 3)`，不依赖 Task 3.0 `pages.jsonl` |
| MAX_PARALLEL | 4 |

## Candidates (3 strategies)

| Index | Strategy | Description |
|-------|----------|-------------|
| 0 | random | 在目标指令窗口内 collect distinct pages → deterministic shuffle → first K area0, rest area1 |
| 1 | sort_heat | 在目标指令窗口内 count page references → sort desc → top-K area0, rest area1 |
| 2 | first_touch | 在目标指令窗口内 first K distinct pages in trace order → area0, rest area1 |

## Candidates (12 benchmarks)

astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp

## Filter Rule

无 — 为全部 12 个 benchmark × 3 种 strategy 生成 area_map。

## Auxiliary Checks

1. **Magic bytes correct:** 每个 `.amap` 文件头 4 字节为 `AREA` (0x41524541)
2. **Entries sorted:** entries 按 page_id 升序排列
3. **Area=0 count fixed:** DRAM page 数等于 `floor(num_entries / 3)`
4. **All 36 files generated:** 12 benchmarks × 3 strategies = 36 `.amap` files

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
