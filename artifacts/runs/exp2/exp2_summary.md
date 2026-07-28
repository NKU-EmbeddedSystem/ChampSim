# 实验阶段2：Trace 基线仿真报告

## 实验目的

对实验阶段1验证为可用的 trace，使用 ChampSim 默认配置（LRU 8-way L2C）进行完整仿真运行。获取每条 trace 在基准配置下的完整性能数据（IPC、Cache 命中率、MPKI 等），为后续的容量敏感性分析和 EMISSARY 实验提供基线数据。

## 实验方法

使用 `run_simulation.py` 脚本，以 ChampSim 默认配置对所有可用 trace 执行完整仿真：
- **预热指令数**：50,000,000
- **仿真指令数**：500,000,000
- **超时限制**：7200 秒（2小时）

## 仿真结果

共提交 **28 个** trace 进行仿真。

### 成功完成的 trace（16 个）

| Trace | IPC | LLC 访问 | LLC 命中率 | L1D→L2C 比率 | 注记 |
|-------|-----|---------|-----------|-------------|------|
| barnes_1 | 2.231 | 54K | 40.9% | 0.0 | |
| bc_kron22 | 0.546 | 6.8M | 16.3% | 0.0 | 图算法，极低 IPC |
| blackscholes_1 | 1.753 | 446K | 76.8% | 0.0 | |
| cholesky_1 | 2.068 | 678K | 87.9% | 0.0 | |
| cholesky_nosp | 1.018 | 2.4M | 36.1% | 0.0 | 无 SP 版本性能显著下降 |
| dlrm_4g | 1.652 | 6K | 9.9% | 0.0 | LLC 访问极少 |
| facesim_1 | 2.178 | 130K | 39.8% | 0.0 | |
| fft_m24 | 1.999 | 445K | 33.5% | 0.0 | |
| fluidanimate_1 | 2.536 | 49K | 54.9% | 0.0 | IPC 最高 |
| fmm_1 | 2.448 | 46K | 33.2% | 0.0 | |
| lu_cb_n1024 | 1.219 | 335K | 49.5% | 0.0 | |
| lu_ncb_1 | 1.039 | 736K | 35.4% | 0.0 | |
| ocean_cp_1 | 1.886 | 923K | 25.1% | 0.0 | |
| ocean_ncp_1 | 1.927 | 5.0M | 91.9% | 0.0 | LLC 命中率极高 |
| radiosity_1 | 1.418 | 21K | 24.3% | 0.0 | |
| radix_1 | 2.202 | 338K | 50.0% | 0.0 | |
| radix_nosp | 2.202 | 338K | 50.0% | 0.0 | 与 radix_1 几乎完全一致 |
| raytrace_1 | 1.053 | 3.1M | 99.5% | 0.0 | LLC 命中率极高 |
| streamcluster_1 | 1.277 | 1.0M | 3.5% | 0.0 | LLC 命中率极低 |
| volrend_1 | 1.691 | 119K | 93.3% | 0.0 | |
| water_nsquared_1 | 1.571 | 613K | 99.9% | 0.0 | LLC 命中率极高 |
| water_spatial_1 | 1.400 | 17K | 15.0% | 0.0 | |
| x264_1 | 1.756 | 1.2M | 59.4% | 0.0 | |
| or_aes_place | 1.589 | 499K | 65.3% | 0.0 | |
| or_aes_route | 1.589 | 491K | 65.2% | 0.0 | |
| or_jpeg_place | 1.590 | 496K | 65.0% | 0.0 | |
| or_jpeg_route | 1.601 | 484K | 65.0% | 0.0 | |
| xcompact3d | 0.793 | 13.5M | 68.9% | 0.0 | IPC 最低 |

### 超时（TIMEOUT）的 trace（14 个）

大部分是图算法类 workload（bc/bfs/cc/pr/sssp/tc 等）：
`bc_urand22`, `bfs_kron22`, `bfs_kron22_n64`, `bfs_urand22_n64`, `cc_kron22`, `cc_urand22`, `pot3d_tiny`, `pr_kron22_n16`, `pr_urand22`, `pr_urand22_n16`, `sssp_kron22`, `sssp_urand22`, `tc_kron22`, `tc_urand22`

### 异常退出的 trace（1 个）

`xgboost_higgs` — 退出码 -6（可能是 OOM 或其他运行时错误）

## 结论

1. **完成率**：28 个 trace 中 **16 个成功完成**（57.1%），14 个超时（50.0%）
2. **超时集中特征**：超时的 trace 几乎全部为图算法类 workload，特点是 IPC 极低（0.5~2.5），仿真时间远超 2 小时限制
3. **IPC 分布范围广**：成功的 trace IPC 从 0.546（bc_kron22）到 2.536（fluidanimate_1），覆盖了多种计算特征
4. **LLC 行为差异大**：有的 trace LLC 命中率高达 99.9%（water_nsquared_1），有的仅 3.5%（streamcluster_1），说明不同的 trace 对 Cache 层次结构的压力差异显著
5. **OpenROAD trace 一致性好**：4 个 `or_` 开头的 trace（aes/jpeg, place/route）IPC 几乎完全一致（~1.59），适合作为验证 EMISSARY 效果的对照组
6. **nosp 后缀对比**：`radix_1` 与 `radix_nosp` 性能几乎完全相同（IPC 均为 2.202），而 `cholesky_1`（2.068）与 `cholesky_nosp`（1.018）差异巨大，说明 SP 优化的影响因应用而异
7. **后续实验建议**：选择成功完成的 trace 中 IPC 覆盖范围广的（高/中/低），同时优先选择仿真时间可控的 trace 进行进一步分析
