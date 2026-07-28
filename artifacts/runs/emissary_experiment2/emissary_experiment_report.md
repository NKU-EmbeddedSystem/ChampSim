# EMISSARY 验证实验报告（第2轮）

## 实验目的

第1轮实验的 4 个 trace 均未展现出 EMISSARY 的有效性，主要原因是这些 trace 缺乏足够的 I-cache 压力。第2轮实验更换 trace，选用具有更高分支密度和更复杂控制流的 workload（perlbench、xalancbmk），以寻找 EMISSARY 真正能发挥作用的场景。

## 实验配置

与第1轮相同，比较 4 种 L2C 配置：

| 配置名称 | L2 Way 数 | 替换策略 | 说明 |
|----------|----------|---------|------|
| Baseline (基准) | 8 | LRU | 全部用于数据缓存 |
| Phase1 (统一EMISSARY) | 8 | EMISSARY P(N) | 全部 8-way 使用 EMISSARY |
| Phase2 (分区异构) | 8 | LRU(4W) + EMISSARY(4W) | 4W 数据 + 4W I-cache保护 |
| Extra (容量对比) | 4 | LRU | 纯 4-way 数据缓存 |

- **仿真参数**：预热 50M 指令，仿真 500M 指令
- **计划测试 3 个 trace**：perlbench_135B, xalancbmk_768B, gcc_13B
- **实际完成 2 个**：gcc_13B 全部超时（仿真时间过长）

---

## 各 Trace 详细结果

### perlbench_135B.trace.xz

| 指标 | Baseline LRU 8W | Phase1 EMISSARY 8W | Phase2 分区 4+4W | Extra LRU 4W |
|------|----------------|--------------------|--------------------|-------------|
| **IPC** | 1.0064 | 1.0067 (+0.03%) | 1.0125 (+0.60%) | 0.9876 (-1.87%) |
| L2C 命中率 | 87.06% | 87.10% (+0.05%) | 80.56% (-7.5%) | 74.68% (-14.2%) |
| L2C MPKI | 2.34 | 2.34 (-0.3%) | 3.52 (+50.2%) | 4.59 (+95.6%) |
| L1I 命中率 | 89.60% | 89.60% | 89.60% | 89.60% |
| L1I MPKI | 8.94 | 8.94 | 8.94 | 8.95 |
| decode_starvation | 0 | 0 | 0 | 0 |

### xalancbmk_768B.trace.xz

| 指标 | Baseline LRU 8W | Phase1 EMISSARY 8W | Phase2 分区 4+4W | Extra LRU 4W |
|------|----------------|--------------------|--------------------|-------------|
| **IPC** | 1.2806 | 1.2804 (-0.01%) | 1.2832 (+0.20%) | 1.2692 (-0.89%) |
| L2C 命中率 | 89.18% | 89.18% (-0.0%) | 88.27% (-1.0%) | 84.74% (-5.0%) |
| L2C MPKI | 2.86 | 2.87 (+0.0%) | 3.10 (+8.4%) | 4.04 (+41.0%) |
| L1I 命中率 | 99.58% | 99.58% | 99.58% | 99.58% |
| L1I MPKI | 0.91 | 0.91 | 0.91 | 0.90 |
| decode_starvation | 0 | 0 | 0 | 0 |

---

## 平坦区分析

| Trace | Baseline IPC (8W) | Extra IPC (4W) | IPC 下降 | 平坦区？ |
|-------|-------------------|---------------|---------|---------|
| perlbench_135B | 1.0064 | 0.9876 | -1.87% | ✅ 是 |
| xalancbmk_768B | 1.2806 | 1.2692 | -0.89% | ✅ 是 |

两个 trace 都明确位于平坦区（8W→4W IPC 下降 < 2%），满足 EMISSARY 分区方案的前提条件。

---

## EMISSARY 有效性总结

| Trace | P1 vs Baseline | P2 vs Baseline | P2 vs LRU4W | 判定 |
|-------|---------------|---------------|-------------|------|
| perlbench_135B | +0.03% | +0.60% | **+2.52%** | ✅ 分区有正收益 |
| xalancbmk_768B | -0.01% | +0.20% | **+1.10%** | ⚠️ 微弱正收益 |

---

## 核心结论

### 1. 统一的 EMISSARY（Phase1）依然无效

与第1轮结果一致：8-way 统一 EMISSARY 相比 8-way LRU 基线，IPC 变化在 ±0.03% 以内（属于测量噪声范围）。在统一配置下，EMISSARY 的 I-cache 保护机制依然未能产生可度量的性能提升。

### 2. 分区异构（Phase2）首次展现正收益

这是两轮实验中**首次看到 EMISSARY 分区方案的正面效果**：

- **perlbench_135B**：Phase2 (4W LRU + 4W EMISSARY) 相比纯 4W LRU 提升了 **+2.52%**，相比 8W LRU 基线也提升了 +0.60%。这是目前为止最大的正向结果。
- **xalancbmk_768B**：Phase2 相比纯 4W LRU 提升 +1.10%，但相比 8W LRU 基线仅 +0.20%。

### 3. 收益机制分析

perlbench 的成功值得深入分析：
- **分支密度极高**（branch_mispredict_rate = 18.24 MPKI），远超第1轮的 trace（2.6~6.2 MPKI）
- **L1I MPKI = 8.94**，说明存在实际的 I-cache 压力（第1轮多个 trace 的 L1I MPKI 接近 0）
- 然而 `decode_starvation_cycles` 仍为 0，说明 Bench 的 I-cache miss 并没有直接导致前端的 decode 停顿

### 4. 为何提升有限？

尽管 perlbench 展现了正收益，但提升幅度（+2.52% vs LRU4W）仍然不大。可能原因：
- **乱序执行的延迟隐藏能力**：即使 L1I 有 miss，ROB 仍能从 I-cache miss 的延迟中恢复
- **Branch predictor 是更主要的瓶颈**：perlbench 的 branch mispredict rate 高达 18.24 MPKI，分支预测失败带来的流水线冲刷可能远超 I-cache miss 的影响
- **L2 延迟仍较大**：EMISSARY 保护的 I-cache 行在 L2 中，访问延迟远高于 L1I，因此命中 L2 的 I-cache 访问仍然会带来明显的流水线停顿

### 5. 整体实验结论

经过两轮实验（共 6 个不同 trace，排除超时的 gcc_13B），**EMISSARY 方案的整体结论**如下：

| 实验轮次 | Trace 数量 | P1 有效 | P2 有效 | 最高 P2 收益 |
|---------|-----------|---------|---------|-------------|
| 第1轮 | 4 | 0 | 0 (1 个微弱) | +0.88% (x264) |
| 第2轮 | 2 | 0 | 2 | **+2.52%** (perlbench) |

**最终判断**：
- **统一 EMISSARY（Phase1）无效**：在所有测试场景中，将全部 L2 way 切换为 EMISSARY 替换策略不带来任何 IPC 提升
- **分区 EMISSARY（Phase2）有微弱但真实的正收益**：在部分具有 I-cache 压力的 trace 上（特别是 perlbench），将 4 way 分配给 EMISSARY 相比纯 4W LRU 可提升 1~2.5% 的 IPC。但这仍无法追平 8W LRU 基线（perlbench: +0.60% 超过基线，xalancbmk: +0.20% 基本持平）
- **EMISSARY 的适用范围较窄**：仅在 workload 同时满足以下条件时才可能有效：(1) L2 数据缓存存在平坦区；(2) workload 具有显著的 I-cache 压力；(3) 分支预测不是主导瓶颈
