# Stage3-Prefetcher 当前状态报告

## 最终目标

跑出 task3.3 cross-compare 完整实验结果：

- **10 configs × 3 policies × 12 benchmarks = 360 runs**
- 两个规模：**50M+100M** 和 **50M+1B**
- **Policy 对比**: LRU vs MockingJay vs RPP (SilkLoom)
- **Config 对比**: 3 placement × 2 migration × 3 prefetcher
- **关键指标**: CXL latency-weighted IPC, DRAM/CXL 流量分布, policy 间 IPC 加速比

## 已验证修复的 Bug

### 1. ✅ CXL 流量为零 — 已修复
**根因**: `cache.cc` 的 L1 area 赋值代码中 `packet->area =` 丢失，导致所有 packet 的 area 保持默认值 -1，CXL 路由永不触发。
**修复**: `src/cache.cc:1441-1443` — 加上 `packet->area = MemoryMapper::get_instance().get_assigned_area(_al, true);`
**验证**: 10M+20M 测试，Sort RPP: DRAM=203,827 / CXL=204,880

### 2. ✅ VA/PA 地址混用 — 已修复
**根因**: ooo_cpu 的 load/store 路径中 `full_addr` 在部分路径设为 PA（物理地址），而 area_map 基于 VA（虚拟地址）构建，导致 area 查询 miss。
**修复**: `src/cache.cc` 两处 area 赋值使用 `_al = packet->full_v_addr ? packet->full_v_addr : packet->full_addr`（VA 优先，PA 兜底）。`src/ooo_cpu.cc` **完全不动**——prefetcher 继续使用 PA，不受影响。
**验证**: Sort DRAM=50%, Random DRAM=31%, FCFS DRAM=30%

### 3. ✅ MockingJay SIGSEGV — 已修复
**根因**: `replacement/mockingjay.llc_repl:105` — `sampled_cache[set]` 在 warmup 阶段未初始化时返回 nullptr，直接解引用。
**修复**: `replacement/mockingjay.llc_repl:106` — 加 `if (!sampled_set) return -1;`

### 4. ✅ MJ WARNING 刷屏 — 已修复
**根因**: `cache.h` 的 `llc_find_victim` 和 `llc_update_replacement_state` 新增 `int area` 参数，默认值 -1。非 handle_fill 路径传入 -1，MJ 检测到 `addr_area == -1` 后输出 `[WARNING]`。
**修复**: `inc/cache.h` — 默认值从 `-1` 改为 `0`（DRAM）

### 5. ✅ make 不重编译 — 已修复
**根因**: `make` 的 timestamp 依赖跳过了部分文件的重编译（尤其是 `llc_replacement.cc`）。
**修复**: 每次构建前必须 `make clean`

### 6. ✅ CLI --area_map 不识别 — 已修复
**根因**: `getopt_long_only` 需要 `--area_map <value>` 格式（双横线 + 空格分隔值）。
**注意**: 短格式 `-a <value>` 也可以。`--area_map=<value>` 不支持。

---

## 已实现的基础设施

### 文件修改清单

| 文件 | 改动 | 状态 |
|------|------|------|
| `inc/block.h` | BLOCK 加 `int area` 字段，初始化 -1 | ✅ |
| `inc/cache.h` | `llc_find_victim`/`llc_update_replacement_state` 加 `int area = 0` 参数 | ✅ |
| `inc/cache.h` | 加 `sim_dram_accesses`, `sim_cxl_accesses`, `sim_dram_evictions`, `sim_cxl_evictions` 字段 | ✅ |
| `inc/memory_mapper.h` | 加 `load_area_map()`, `area_map_4k`, 4KB/2MB 粒度双模式 | ✅ |
| `inc/page_migration.h` | PageMigrationEngine 定义（forward/backward/lazy 模式） | ✅ |
| `inc/trace_page_buffer.h` | TracePageBuffer 类（forward migration 的 lookahead） | ✅ |
| `inc/tracereader.h` | 加 `get_trace_path()` 方法 | ✅ |
| `src/cache.cc` | L1 area 赋值用 `full_v_addr`（VA）；fill_cache 写 `block.area`；handle_fill 传 area 到 replacement；writeback 路由用 `block.area` | ✅ |
| `src/page_migration.cc` | PageMigrationEngine 实现 | ✅ |
| `src/main.cc` | CLI args: `-area_map`, `-migration`, `-dram_pages`；init MemoryMapper + PageMigrationEngine + TracePageBuffer；main loop 触发 forceMigrate；per-area 统计输出 | ✅ |
| `replacement/rpp.llc_repl` | `llc_find_victim` 用 `area` 参数代替重新查 get_assigned_area；victim area 用 `block[].area` | ✅ |
| `replacement/mockingjay.llc_repl` | 同上 + sampled_cache null guard | ✅ |
| `replacement/lru.llc_repl` | 函数签名加 `int area` 参数 | ✅ |
| `Makefile` | C++14，排除 `src/tools` | ✅ |

### 命令行用法

```bash
# 单个 binary 构建（必须 make clean + 单独 cp）
cp replacement/<pol>.llc_repl replacement/llc_replacement.cc
cp prefetcher/<l1d>.l1d_pref prefetcher/l1d_prefetcher.cc
cp prefetcher/<l2c>.l2c_pref prefetcher/l2c_prefetcher.cc
make clean && make -j4
cp bin/champsim bin/hp-<l1d>-<l2d>-no-<pol>-1core

# 运行（注意 --area_map 双横线 + 空格，或 -a 短格式）
./bin/hp-no-no-no-rpp-1core \
  -warmup_instructions 50000000 \
  -simulation_instructions 100000000 \
  -a artifacts/runs/task3.1-gen-areamaps/latest/omnetpp_sort_heat.amap \
  -dram_pages 5384 \
  -traces trace/omnetpp_4B.trace.xz
```

### 构建脚本

`/mnt/sdd/liz/rebuttal/stages/stage3-prefetcher/scripts/run_task3.3_cross_compare.sh` — task3.3 全量实验脚本（360 runs, 64 parallel）

---

## ⚠️ 重要注意事项

1. **每次构建前必须 `make clean`+`cp replacement/*.llc_repl`** — 不要依赖 `make` 的增量编译
2. **构建后验证 hash** — 12 个 binary 的 md5 必须全部不同
3. **不要用 timeout** — 50M+100M 每个 run 需要 5-30 分钟不等，无 timeout
4. **并行测试**: 9 个并行测试可用 Python `threading.Thread` 或 `bash &`+`wait`
5. **二进制存放**: 存在 `/tmp` 是安全的（不会被覆盖）。`bin/` 目录也可，但每次 `make clean` 后 `bin/champsim` 不会被删除，需手动清理旧文件
6. **API 参数格式**: `getopt_long_only` 使用 `--key value`（双横线 + 空格），不支持 `--key=value`
7. **area_map 路径**: 必须存在于 `artifacts/runs/task3.1-gen-areamaps/latest/`
8. **K 值来源**: 从 `artifacts/runs/task3.0-prep-pagecount/latest/pages.jsonl` 读取，公式 `min(WSS/3, 262144)`
9. **`/home/liz/data_storage` 是 `/mnt/sdd/liz` 的软链接** — 两者是同一文件系统，注意文件冲突
10. **当前验证数据**: omnetpp 的单 benchmark 已通过 (Sort DRAM 50%, Random DRAM 31%, FCFS DRAM 30%)

---

## 待完成

- [ ] 构建全部 12 个 binary（4 prefetcher × 3 policy），验证 hash 唯一
- [ ] 重跑 task3.3 全量 360 runs（50M+100M）
- [ ] 跑 task3.3 全量 360 runs（50M+1B）
- [ ] 验证 prefetcher configs 的 IPC 合理性（目前 PA→VA 修复未影响 prefetcher，但 prefetcher 效果待确认）
- [ ] Forward migration 的 TracePageBuffer `consume()` 机制需测试是否正确触发
- [ ] RPP 内部 area 查询细节——目前 `handle_fill` 传 area 到 replacement，但其他调用路径用默认值

## 快速验证脚本

```bash
# 构建 3 个基础 binary + 9-way 并行测试
for p in lru mockingjay rpp; do
  cp replacement/${p}.llc_repl replacement/llc_replacement.cc
  cp prefetcher/no.l1d_pref prefetcher/l1d_prefetcher.cc
  cp prefetcher/no.l2c_pref prefetcher/l2c_prefetcher.cc
  make clean && make -j4 && cp bin/champsim bin/hp-no-no-no-${p}-1core
done

# 并行跑 Random, Sort, FCFS
python3 -c "
import subprocess, re, threading
base='/mnt/sdd/liz/rebuttal/stages/stage3-prefetcher'
amap_s=f'{base}/artifacts/runs/task3.1-gen-areamaps/latest/omnetpp_sort_heat.amap'
amap_f=f'{base}/artifacts/runs/task3.1-gen-areamaps/latest/omnetpp_first_touch.amap'
t=f'{base}/trace/omnetpp_4B.trace.xz'; K=5384
for cfg,extra in [('Random',''),('Sort',f'-a {amap_s} -d {K}'),('FCFS',f'-a {amap_f} -d {K}')]:
    for pol in ['lru','mockingjay','rpp']:
        def run(c=cfg,p=pol,e=extra):
            o=f'/tmp/vfy_{c}_{p}.out'
            subprocess.run(f'bin/hp-no-no-no-{p}-1core -warmup 10000000 -simulation 20000000 {e} -traces {t}'.split(),stdout=open(o,'w'),stderr=subprocess.STDOUT)
            with open(o) as fh: text=fh.read()
            m=re.search(r'Finished.*IPC:\s*([\d.]+)',text)
            d=re.search(r'DRAM accesses:\s*(\d+)',text)
            cxl=re.search(r'CXL accesses:\s*(\d+)',text)
            print(f'{c} {p}: IPC={m.group(1) if m else \"?\"} DRAM={d.group(1) if d else \"?\"} CXL={cxl.group(1) if cxl else \"?\"}')
        threading.Thread(target=run).start()
"
```
