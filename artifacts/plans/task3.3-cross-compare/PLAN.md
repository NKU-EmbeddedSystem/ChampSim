# Stage 3.3: Cross Comparison — MJ vs RPP IPC Speedup over LRU

**Spec:** N/A

## Goal

在 10 种配置（Placement × Migration × Prefetcher 组合）下，对比 MockingJay (MJ) 和 SilkLoom RPP 相对于 LRU 的 IPC 加速比。IPC 使用 CXL latency-weighted IPC（已考虑 DRAM/CXL 延迟差异）。目标是回答：**在不同 page placement 质量和 prefetcher 存在的情况下，RPP 相较于 MJ 的增益是否持续存在？**

## Fixed Parameters

| Parameter | Value |
|-----------|-------|
| Warmup | 50M instructions |
| Simulation | 100M instructions |
| Branch predictor | hashed_perceptron |
| Page size | 4KB |
| DRAM pages (K) | min(WSS × 0.3, 262144) — from Task 3.0 |
| Cores | 1 |
| MAX_PARALLEL | 6 |

## Candidates (10 configurations)

Config 分解为三个维度：**Placement** (Random / Sort_offline / FCFS), **Migration** (None / Forward / Backward), **Prefetcher** (None / IPCP@L1D / IP-stride@L2C / Both).

| # | Label | Placement | Migration | L1D Pref | L2C Pref | area_map | migration_arg |
|---|-------|-----------|-----------|----------|----------|----------|---------------|
| 1 | Rnd+Nomig+NoPF | Random | None | no | no | — | — |
| 2 | Sort+Nomig+NoPF | sort_heat | None | no | no | `{wl}_sort_heat.amap` | — |
| 3 | FCFS+Nomig+NoPF | first_touch | None | no | no | `{wl}_first_touch.amap` | — |
| 4 | Rnd+Fwd+NoPF | Random | Forward | no | no | — | `--migration=forward` |
| 5 | Rnd+Bwd+NoPF | Random | Backward | no | no | — | `--migration=backward` |
| 6 | Rnd+Nomig+IPCP(L1D) | Random | None | ipcp | no | — | — |
| 7 | Rnd+Nomig+IPstride(L2C) | Random | None | no | ip_stride | — | — |
| 8 | Rnd+Nomig+BothPF | Random | None | ipcp | ip_stride | — | — |
| 9 | FCFS+Bwd+BothPF | first_touch | Backward | ipcp | ip_stride | `{wl}_first_touch.amap` | `--migration=backward` |
| 10 | Sort+Fwd+BothPF | sort_heat | Forward | ipcp | ip_stride | `{wl}_sort_heat.amap` | `--migration=forward` |

## Candidates (3 policies per config)

| # | Policy | Binary suffix |
|---|--------|--------------|
| 0 | lru | `-lru-1core` |
| 1 | mockingjay | `-mockingjay-1core` |
| 2 | rpp | `-rpp-1core` |

## Filter Rule

无 — 全部 10 × 3 = 30 runs per benchmark 均保留。IPC ≤ 0 的 run 标记为异常。

## Benchmarks (12 unique workloads)

astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp

Total tasks: 12 benchmarks × 10 configs × 3 policies = **360 runs**

## Prefetcher Binary Matrix (12 binaries)

每个 (prefetcher_combo, policy) 组合编译一个独立二进制：

| L1D Pref | L2C Pref | Policy | Binary Name |
|----------|----------|--------|-------------|
| no | no | lru | `hp-no-no-no-lru-1core` |
| no | no | mockingjay | `hp-no-no-no-mockingjay-1core` |
| no | no | rpp | `hp-no-no-no-rpp-1core` |
| ipcp | no | lru | `hp-ipcp-no-no-lru-1core` |
| ipcp | no | mockingjay | `hp-ipcp-no-no-mockingjay-1core` |
| ipcp | no | rpp | `hp-ipcp-no-no-rpp-1core` |
| no | ip_stride | lru | `hp-no-ip_stride-no-lru-1core` |
| no | ip_stride | mockingjay | `hp-no-ip_stride-no-mockingjay-1core` |
| no | ip_stride | rpp | `hp-no-ip_stride-no-rpp-1core` |
| ipcp | ip_stride | lru | `hp-ipcp-ip_stride-no-lru-1core` |
| ipcp | ip_stride | mockingjay | `hp-ipcp-ip_stride-no-mockingjay-1core` |
| ipcp | ip_stride | rpp | `hp-ipcp-ip_stride-no-rpp-1core` |

> 所有 prefetcher 文件均已存在：`ipcp.l1d_pref` + `ip_stride.l2c_pref`，无需额外创建。

## Run Matrix (mapping config → binary + args)

```
Config 1 (Rnd+Nomig+NoPF):
  Binary: hp-no-no-no-{pol}-1core
  Args:  (none extra)

Config 2 (Sort+Nomig+NoPF):
  Binary: hp-no-no-no-{pol}-1core
  Args:  --area_map={wl}_sort_heat.amap --dram_pages={K}

Config 3 (FCFS+Nomig+NoPF):
  Binary: hp-no-no-no-{pol}-1core
  Args:  --area_map={wl}_first_touch.amap --dram_pages={K}

Config 4 (Rnd+Fwd+NoPF):
  Binary: hp-no-no-no-{pol}-1core
  Args:  --migration=forward --dram_pages={K}

Config 5 (Rnd+Bwd+NoPF):
  Binary: hp-no-no-no-{pol}-1core
  Args:  --migration=backward --dram_pages={K}

Config 6 (Rnd+Nomig+IPCP@L1D):
  Binary: hp-ipcp-no-no-{pol}-1core
  Args:  (none extra)

Config 7 (Rnd+Nomig+IPstride@L2C):
  Binary: hp-no-ip_stride-no-{pol}-1core
  Args:  (none extra)

Config 8 (Rnd+Nomig+BothPF):
  Binary: hp-ipcp-ip_stride-no-{pol}-1core
  Args:  (none extra)

Config 9 (FCFS+Bwd+BothPF):
  Binary: hp-ipcp-ip_stride-no-{pol}-1core
  Args:  --area_map={wl}_first_touch.amap --dram_pages={K} --migration=backward

Config 10 (Sort+Fwd+BothPF):
  Binary: hp-ipcp-ip_stride-no-{pol}-1core
  Args:  --area_map={wl}_sort_heat.amap --dram_pages={K} --migration=forward
```

## Auxiliary Checks

1. **All 360 tasks complete:** 每个 task 的 `exit=0`，IPC > 0
2. **LRU baseline consistent:** Config 1 (Rnd+Nomig+NoPF) 在不同 prefetcher combo 下 LRU IPC 与理论一致
3. **RPP ≥ MJ in random placement:** Config 1 中 RPP/MJ ≥ 1.0（RPP 在 random placement 下优势最大）
4. **Prefetcher doesn't break migration:** Configs 9/10 中 migration 正常工作（log 中有 `[migration]` 行）
5. **IPC 随 placement 改善而提升:** Sort_offline 和 FCFS 的 IPC ≥ Random baseline

## Expected Comparison Table

每个 config 对 12 个 benchmark 取 geomean：

| # | Config | LRU IPC | MJ IPC | RPP IPC | MJ/LRU | RPP/LRU | RPP/MJ |
|---|--------|---------|--------|---------|--------|---------|--------|
| 1 | Rnd+Nomig+NoPF | — | — | — | — | — | — |
| 2 | Sort+Nomig+NoPF | — | — | — | — | — | — |
| 3 | FCFS+Nomig+NoPF | — | — | — | — | — | — |
| 4 | Rnd+Fwd+NoPF | — | — | — | — | — | — |
| 5 | Rnd+Bwd+NoPF | — | — | — | — | — | — |
| 6 | Rnd+Nomig+IPCP(L1D) | — | — | — | — | — | — |
| 7 | Rnd+Nomig+IPstride(L2C) | — | — | — | — | — | — |
| 8 | Rnd+Nomig+BothPF | — | — | — | — | — | — |
| 9 | FCFS+Bwd+BothPF | — | — | — | — | — | — |
| 10 | Sort+Fwd+BothPF | — | — | — | — | — | — |

## How to Run

```bash
bash scripts/run_task3.3_cross_compare.sh
```

## Output Structure

```
artifacts/
  plans/task3.3-cross-compare/
    PLAN.md              <- this file
    run.sh               <- symlink to run_task3.3_cross_compare.sh (auto)
    SUMMARY.log          <- symlink to latest main.log (auto)
    CONCLUSIONS.md       <- auto-generated after run (含 geomean 对比表)

  runs/task3.3-cross-compare/
    latest -> <timestamp>
    <YYYYMMDD-HHMMSS>/
      execution.log      <- control plane (360 TASK DISPATCH/DONE)
      main.log           <- global log, 含 geomean 汇总表
      build_*.log        <- 12 binary build logs
      {wl}_{config}_{policy}.raw     <- raw simulation output (含 IPC)
      {wl}_{config}_{policy}.sub.log <- per-task summary
```
