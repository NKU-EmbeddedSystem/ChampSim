# 实验阶段1：Trace 可用性验证报告

## 实验目的

对收集到的 ChampSim trace 文件进行初步验证，判断其是否可用于后续的 ChampSim 仿真实验。验证内容包括文件完整性（xz 解压校验）、数据格式对齐性、以及在 ChampSim 上的基本可运行性。

## 实验方法

使用 `validate_traces.py` 脚本，对每个 trace 文件执行以下检查：
- **xz 解压校验**：验证 xz 压缩文件是否完整
- **数据对齐检查**：验证解压后的数据是否符合 ChampSim trace 格式要求
- **干运行测试**：在 ChampSim 上以最小指令数运行，验证 trace 是否能被正确解析和执行
- **IPC 基线记录**：记录干运行的 IPC 值作为性能参考

## 数据概览

共检查 **59 个** trace 文件，分布在 3 个子目录（`.`、`new/`、`new2/`）中。

## 验证结果

### 可用 trace（USABLE）：共 43 个

| 子目录 | 数量 | IPC 范围 |
|--------|------|----------|
| `.` (原始) | 31 | 0.88 ~ 3.97 |
| `new/` | 2 | 3.23 ~ 3.25 |
| `new2/` | 4 | 2.87 ~ 3.97 |

IPC 较高的 trace（IPC > 3.5）：
- `barnes_1` (3.91), `dlrm_4g` (3.97), `lu_cb_n1024` (3.98), `lu_ncb_1` (3.80)
- `fluidanimate_1` (3.97), `volrend_1` (3.90), `water_nsquared_1` (3.74), `water_spatial_1` (3.65)
- `xcompact3d` (3.79), `facesim_1` (3.55), `blackscholes_1` (2.87)

### 损坏文件（CORRUPTED）：共 12 个

全部来自 `new/` 和 `new2/` 子目录：
- `new/`: `fmm_nosp`, `ocean_cp_nosp`, `ocean_ncp_nosp`, `radiosity_nosp`, `raytrace_nosp`, `volrend_nosp`, `water_nsquared_nosp`, `water_spatial_nosp`
- `new2/`: `canneal_1`, `dedup_nosp`, `freqmine_nosp`, `raytrace_1`

这些文件解压后大小为零或 xz 校验失败，属于永久性损坏，无法用于后续实验。

### 格式错误（FORMAT_ERROR）：共 4 个

来自 `new2/` 子目录：`bodytrack_1`, `ferret_1`, `swaptions_1`, `vips_1`

这些文件虽然 xz 解压成功，但数据大小不满足 ChampSim trace 格式的对齐要求（不能被 64 整除），无法被 ChampSim 正确解析。

## 结论

1. **可用率**：59 个 trace 中有 **43 个可用**（72.9%），**16 个不可用**（27.1%）
2. **损坏集中区域**：几乎所有带 `_nosp` 后缀的 trace 均已损坏，暗示这些文件可能在传输或压缩过程中出现了系统性问题
3. **FORMAT_ERROR 来源**：来自 `new2/` 的 4 个 trace 格式不对齐，可能是在生成时使用不同版本的 pin 工具导致
4. **实验可行性**：43 个可用 trace 覆盖了多种 IPC 范围（0.88 ~ 3.97）和计算模式（SPEC、图算法、科学计算、机器学习等），为后续实验提供了足够的多样性
5. **建议**：后续实验优先使用来自 `.` 子目录的 31 个原始 trace，这些最可靠。`new/` 和 `new2/` 目录中可用的 6 个 trace 可作为补充
