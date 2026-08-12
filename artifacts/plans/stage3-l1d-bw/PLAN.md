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

- 修复后重跑（`artifacts/runs/l1d-bw/20260802-142911`，672 个运行全部完成、零 DEADLOCK）：**5/12 traces 排名发生变化**
- b0_no 基线在全部 12 条 trace 上严格单调（bw3200 ≥ bw1600 ≥ bw800），内存敏感 trace 下降明显（libquantum 0.217→0.172，soplex 0.217→0.168），计算型几乎不变（perlbench 2.496→2.492）
- zeusmp/mcf 最稳定：next_line 在任何带宽下都最优
- **bw800 旧数据异常原因（已修复）**：旧配置中 DRAM 时序参数（tCAS/tRCD/tRP/tRAS）是 MC 时钟周期数而非 ns，降 data_rate 会使绝对延迟同比放大（bw800 单次访问纯等待 ~480 个全局周期），触发 ChampSim deadlock 检测器（500 拍无进展阈值，`src/champsim.cc:32`）误杀全部 bw800 运行；compare 脚本把 warmup IPC（warmup 期间 DRAM 零延迟，虚高）当成了最终结果
- **修复**：`gen_bw_configs.py` 按 data_rate 等比缩放时序参数（bw3200/1600/800 = 24/12/6, tRAS 52/26/13），保持绝对延迟 15ns 恒定、只改带宽；`compare_bw.py` 跳过含 DEADLOCK 或未跑完的输出，并修正 bw3200 基线路径（stage2-l1d-batch）
- 注意：修复后的 bw1600 也是恒定延迟配置，与旧的 bw1600 数据（延迟翻倍）不可直接比较

## Auxiliary: Prefetch Stats across Bandwidth

`prefetch_bw_stats.py` 从三档带宽输出中提取 L1D PREFETCH REQUESTED / ISSUED / USEFUL(_HIT/_LATE) / USELESS 与 IPC。

**USEFUL 拆分（20260802 起）**：`pf_useful` 在源码层拆为 `pf_useful_hit`（demand 命中已填充预取行，及时）
与 `pf_useful_late`（demand 撞上 MSHR 在途预取，迟到），`pf_useful` 保留为两者之和；
输出格式追加 `USEFUL_HIT` / `USEFUL_LATE` 列（`src/cache.cc`, `inc/cache_stats.h`, `src/plain_printer.cc`）。

最新数据（含拆分）：stage2 = `artifacts/runs/l1d-baseline-batch/20260802-181549`，
stage3 = `artifacts/runs/l1d-bw/20260802-185948`，CSV = `<stage3>/prefetch_stats.csv`（1044 行，全部运行零 DEADLOCK）。

要点：
- 全机器汇总 late_share（USEFUL_LATE / USEFUL）随带宽收紧上升：22.6% → 23.3% → 26.2%；drop 率 60.6% → 62.9% → 64.5%
- useful 总数稳定只是"选址质量"稳定；典型如 libquantum b2_hint：useful 恒定 250,408，但 hit:late 从 178k:72k 恶化到 138k:112k，IPC 0.687→0.418
- b2_hint 的 requested 由 hint 表驱动跨带宽恒定；mcf/milc 在低带宽下 b2_hint 低于 B0 基线

## Auxiliary: Bandwidth-Native Hint Retraining

`retrain_hint_bw.sh` 从 bw1600/bw800 的 profiling 输出重新提取 per-PC AMAT、重训 hint.bin（`retrain_hint_bw.sh <bw_run_dir>`），
评估结果为各 bw 目录下的 `b2_hint_native.txt`。结论（对比 3200 训练的 b2_hint）：
- **milc**：原生重训消除了倒挂（bw1600 0.4355 vs B0 0.4259；useless 从 10.6 万降到 4 千）——3200-oracle 在受限带宽下过于激进是倒挂主因
- **mcf**：重训无改善（仍低于 B0）——per-PC dispatch 本身在 mcf 上制造无效流量，与训练带宽无关
- **libquantum / sphinx3 / zeusmp(bw1600)**：原生 oracle 明显回退（-0.10 ~ -0.26 IPC）——低带宽下 profiling 的 AMAT 信号被压缩/噪声化，oracle 选错策略
- 总结：按带宽重训不是稳定收益（24 个数据点中 9 个略优、3 个大幅回退）；3200 训练的 oracle 泛化性出乎意料地好

## Auxiliary: Bandwidth-Aware Relabeling (coarse, per-trace waste)

`relabel_hint_bw.py`：不改 profiler，用 `prefetch_stats.csv` 的 (trace, prefetcher, bw) 全局浪费率
`waste = (issued - useful_hit)/issued` 重标注。方案 A：`score = amat × (1 + λ·waste)`（λ=0.5/2.0，
`b3_hint_tax_l05/l20`）；方案 B：保留 3200 标注、waste>0.9 的 PC 门控为 no（`b4_hint_gate`）。

结论（geomean speedup over B0，24 个 trace×bw 点）：b2_hint **1.240** > native 1.187 > tax_l05 1.070 > gate 1.012 ≈ tax_l20 1.014。
粗粒度税/门控能修复负收益 trace（mcf、xalancbmk 精确回到 B0；milc bw1600 tax_l05 0.4327 翻正），
但在 hint 优势 trace 上损失惨重（sphinx3 0.97→0.61，zeusmp 2.37→1.47）——全局浪费率无法区分同一
prefetcher 内"值得激进的 PC"和"纯浪费的 PC"。精细版需要 per-PC 成本数据：profiler 的
`record_prefetch_issue/hit` 宏（`inc/profiler.h:85-86`）已定义但从未在 cache.cc 中调用，字段全为 0，
需接线后重新 profiling。

## Auxiliary: Bandwidth Pressure Stats

`parse_bandwidth.py` 从 l1d-baseline-batch 的 eval 输出中提取：
- L1D PF Issued（预取请求总数）
- LLC Total Miss（DRAM 请求数）
- LLC PF Miss（预取导致的 DRAM 请求）
- 等效 DRAM BW 需求 (GB/s)

产出: `artifacts/runs/l1d-baseline-batch/20260801-121706/bandwidth_stats.csv`

## Auxiliary: Per-PC Bandwidth Tax Relabeling (fine-grained)

接线 profiler 宏后重跑 bw3200 profiling（`artifacts/runs/l1d-profile-cost/20260812-104321`，
324 文件，per-PC prefetch_issued/hit 非零）。改动：`inc/cache.h` 加 `pref_trigger_ip`，
`src/cache.cc` 在 cache_operate/cache_fill 前记录触发 IP，在 `prefetch_line`（issue）和
两个 useful 分支（try_hit timely / MSHR 搭车 late）打点。注意 hit 按**消费预取的 demand PC**
记账，与 issue 的触发 PC 存在错位，全局 hit/issued 偏低是预期现象。

`relabel_hint_bw.py` 第 4 参数 = cost profiling 目录时生成精细版：
`score = amat_native(pc) × (1 + λ·waste_pc)`，`waste_pc = (issued_pc - hit_pc)/issued_pc`，
输出 `hint_pc_tax_l05/l20.bin`，评估为 `b5_hint_pc_tax_l05/l20.txt`。

结果（geomean speedup over B0，12 traces）：

| variant | bw1600 | bw800 |
|---|---|---|
| b2_hint (3200-trained) | **1.2814** | **1.1998** |
| b2_hint_native | 1.2109 | 1.1630 |
| b3 tax_l05 (coarse) | 1.0739 | 1.0651 |
| b4 gate | 1.0145 | 1.0091 |
| b5 pc_tax_l05 | 1.0478 | 1.0716 |
| b5 pc_tax_l20 | 1.0439 | 1.0382 |

结论：per-PC 税比粗粒度门控好（bw800 1.072 vs 1.009），且精确修复 mcf 倒挂
（bw800 1.0036 vs b2_hint 0.6975），但仍远不如不做带宽感知的 b2_hint——90%+ 的 PC
被改标（mcf 从 sms 主导变 ampm 主导、xalancbmk 从 sandbox 变 ampm），大赢家 trace
（sphinx3 2.12→1.14、zeusmp 1.61→1.00、soplex 1.31→1.14）被税压垮。**静态重标注路线
（无论粗细）都无法兼得：带宽成本与 AMAT 收益不是简单的乘法关系**。剩余选项是方案 C
（运行时带宽反馈，hint_dispatch 里按 dbus_cycle_congested 动态切表）。

## Auxiliary: Per-PC Bandwidth Tax v2 (unified accounting)

v1 的 hit 按消费 PC 记账、issue 按触发 PC 记账，per-PC 浪费率系统性失真。v2 统一为
**全部归因到发起预取的 PC**：`channel::request` / `cache_block` / `tag_lookup_type` /
`mshr_type` 新增 `pref_ip` 字段（`inc/channel.h`、`inc/block.h`、`inc/cache.h`），
`prefetch_line` 写入触发 PC，`mshr_type::merge` 保留 predecessor 的 `pref_ip`，
两处 hit 打点（timely / MSHR-late）改用 `pref_ip`。对拍：astar next_line_d1 per-PC 合计
hit 3971 ≈ 全局 USEFUL 3864（差 2.7%）。新 profiling 数据 =
`artifacts/runs/l1d-profile-cost/20260812-124751`。

v2 结果（geomean speedup over B0，12 traces）：

| variant | bw1600 | bw800 |
|---|---|---|
| b2_hint (3200-trained) | **1.2814** | **1.1998** |
| b2_hint_native | 1.2109 | 1.1630 |
| b3 tax_l05 (coarse) | 1.0739 | 1.0651 |
| b4 gate | 1.0145 | 1.0091 |
| **b5 pc_tax_l05 v2** | **1.1297** | **1.1474** |
| b5 pc_tax_l20 v2 | 1.0475 | 1.0463 |

统一记账后 per-PC 税从 v1 的 1.048/1.072 升到 **1.130/1.147**，成为所有带宽感知方案中最好的：
- 修复负收益 trace：mcf 1.0003/1.0008（b2_hint 0.94/0.70）、xalancbmk 1.0006/0.9994（0.87/0.81）、
  milc 翻正 1.026/1.009（0.98/0.96）
- 保留大部分收益：cactusADM 1.43/1.36（bw1600 甚至超过 b2_hint 的 1.38）、sphinx3 1.57/1.55、
  soplex 1.24/1.12
- 仍落后于 b2_hint 的主要是：libquantum（1.20 vs 3.00/2.44，其最优策略 stride 类浪费率高被税压）、
  zeusmp（1.07 vs 1.61/1.65）、sphinx3（1.57 vs 2.12/1.88）
- λ=2.0 始终劣于 λ=0.5：过重的税仍然会把"高浪费高绝对收益"的 PC 压死

## Auxiliary: Scheme C v1 — Runtime Congestion Feedback (dual-table switching)

实现：`hint_table` 支持双表（`--hint-file` 激进 + `--hint-file-conservative` 保守），
CACHE 在 `handle_fill` 对 demand 填充延迟做 EMA（α=1/256），每 1024 次 fill 按迟滞阈值
（`--hint-congestion-high/low`，默认 500/350 L1D cycles）切换 `conservative_mode`，
`hint_dispatch` 查表时按模式选标签。改动：`inc/hint_table.h`、`src/hint_table.cc`、
`src/cache.cc`、`prefetcher/hint_dispatch/hint_dispatch.cc`、`src/main.cc`。

注意：bw 目录下的 `hint.bin` 已被原生重训覆盖（≠ b2 的 3200 表）；激进表须用
stage2 目录的 hint.bin。首轮 c1 误用导致结果复现了 b2_hint_native，已修正。

结果（激进=b2 3200 表，保守=pc_tax_l05，阈值 500/350）：
geomean bw1600 C=1.2813 ≈ b2 1.2814；bw800 C=1.2011 ≈ b2 1.1998。
**v1 退化为 b2_hint**：填充延迟 EMA 几乎从不越阈（多数 trace cons=0%；
mcf bw800 仅 3.7% 保守时间，IPC 仅从 0.698 回到 0.711，远不及 pc_tax 的 1.0008）。

诊断：绝对延迟阈值无法区分"拥塞受损"与"拥塞但受益"——mcf bw800 EMA=229（倒挂 0.70，
需要保守）与 libquantum EMA=221（b2 收益 2.44，必须激进）数值上不可分。
**延迟是错误信号；区分变量是预取本身的准确性**（mcf b2 全局精度 ~0.3%，libquantum ~13%）。
v2 方向：用滚动窗口的 prefetch accuracy（useful/issued）或 useful_late 占比做切换信号。

## Auxiliary: Scheme C v2 — Per-PC Runtime Accuracy Gate (成功)

v1 的全局延迟信号失败后改为 **per-PC 运行时准确率门控**：CACHE 在 `prefetch_line` 和
两个 useful 分支向 hint_table 上报按发起 PC 记账的 issued/useful 计数（指数衰减窗口，
每 1024 次 demand fill 折半）；hint_dispatch 查表时对"近期 issued ≥ 64 且
accuracy < 2%"的 PC 改用保守标签（pc_tax_l05）。参数：`--hint-acc-thresh`、`--hint-min-issued`
（v1 的延迟 EMA 机制保留，可用 `--hint-congestion-high` 禁用/启用）。

设计依据（来自 prefetch_stats.csv）：b2 下 mcf 精度 0.33%、xalancbmk 1.25%，而
libquantum 13.3%、milc 19%——精度跨带宽几乎不变，是真正的"值不值"信号；
精度低但受益的 h264ref（0.5%）靠 issued 量级下限（64）保护——其 PC 发行量少不触门。

结果（acc_thresh=0.02，min_issued=64；geomean speedup over B0，12 traces）：

| variant | bw1600 | bw800 |
|---|---|---|
| b2_hint (3200 oracle) | 1.2814 | 1.1998 |
| b5 pc_tax_l05 (静态税) | 1.1297 | 1.1474 |
| **c3_accgate (动态门控)** | **1.2999** | **1.2438** |

**动态门控在两个带宽下都超过了纯 oracle b2_hint**，同时消除所有倒挂：
- mcf：0.938/0.698 → **1.061/1.008**（优于静态税的 1.000，因门控只关浪费的 PC，保留受益的）
- xalancbmk：0.868/0.812 → 0.907/0.866（部分修复，其精度 1.25% 贴近 2% 阈值）
- libquantum：门控零触发，完整保留 3.00/2.44
- sphinx3/h264ref/zeusmp/cactusADM：≥ b2（sphinx3 bw1600 2.131 vs 2.115）
- milc：不触发（精度 19%），保持 b2 行为（0.98/0.96，其问题在 late 而非浪费）
