---
name: observable-execution
description: 可观测执行约定 — 控制平面 + 数据平面分层，覆盖 Agent 代码修改和黑盒实验两种场景
user-invocable: true
version: 9bed590
---

# Observable Execution Convention

核心原则：**每次执行都有一个独立的 run 目录；控制平面日志（`execution.log`）提供结构化、机器可解析的全局视图；数据平面按需扩展（源码修改产物 vs 黑盒实验产物）。**

## 通用规范

### 控制平面 (`execution.log`)

所有场景共享。key=value 格式，每行带 ISO 8601 时间戳：

```
[2026-05-24T10:00:00] STAGE BEGIN  stage=<stage>  tasks=N  run=<run-id>
[2026-05-24T10:00:01] TASK DISPATCH  name=<task>  log=<path>
[2026-05-24T10:05:00] TASK DONE  name=<task>  result=success|failed
[2026-05-24T10:05:01] STAGE DONE  stage=<stage>  pass=N  fail=N
```

### run-id 格式

`YYYYMMDD-HHMMSS` — 纯时间戳，确保排序和唯一性。

### 通用验证清单

- [ ] `execution.log` 包含 `STAGE BEGIN` 和 `STAGE DONE`
- [ ] 每条 `TASK DISPATCH` 有对应的 `TASK DONE`
- [ ] `TASK DISPATCH` 的 `log=` 指向实际存在的文件
- [ ] `STAGE DONE` 中 pass/fail 计数与实际一致

---

## 场景 A: Agent 代码修改

Agent 执行读文件→改代码→跑测试等操作。日志放在 `.omc/executions/` 下。

### 目录结构

```
.omc/executions/<run-id>/
├── execution.log                      # 控制平面
└── policies/                          # 数据平面（策略日志）
    ├── 01-<策略名>.log
    ├── 02-<策略名>.log
    └── ...
```

### run-id 格式

`YYYYMMDD-HHMMSS-<任务简述>`，如 `20260523-143000-修复认证模块类型错误`。

### 控制平面 (Agent 场景)

```
[2026-05-23T14:30:00] STAGE BEGIN  stage=<阶段名>  policies=N  run=<run-id>
[2026-05-23T14:30:01] POLICY DISPATCH  name=<策略名>  log=policies/<NN>-<策略名>.log
[2026-05-23T14:35:00] POLICY DONE  name=<策略名>  result=success|failed  artifacts=N
[2026-05-23T14:35:01] STAGE DONE  stage=<阶段名>  pass=N  fail=N
[2026-05-23T14:35:01] ACTION REQUIRED  policy=<策略名>  reason="<原因>"  log=policies/<NN>-<策略名>.log
```

### 策略日志 (`policies/<NN>-<策略名>.log`)

每行带时间，`key=value` 格式。`STEP` 必须标注序号（`当前/总数`），`edit` 带 `reason=`，`run` 带 `→` 结果。

```
[14:30:01] POLICY BEGIN  goal="<目标>"
[14:30:05] STEP 1/4  read <文件路径>
[14:30:08] STEP 2/4  edit <文件路径>:<行号>  reason="<修改原因>"
[14:30:12] STEP 3/4  run <验证命令> → <结果>
[14:35:00] POLICY DONE  result=success|failed  changes=N  files=<涉及文件>
```

### 场景 A 验证清单

- [ ] 每条 `POLICY DISPATCH` 有对应的 `POLICY DONE`
- [ ] 每个子日志包含 `POLICY BEGIN` 和 `POLICY DONE`
- [ ] 子日志中 `STEP` 标有序号
- [ ] 失败策略后有 `ACTION REQUIRED`

---

## 场景 B: 黑盒实验阶段

执行外部黑盒程序（benchmark、profiling 等），Agent 只负责脚本调度，不介入程序内部。

### 目录结构

```
artifacts/
  plans/<stage>/                       # 设计层（执行前编写，执行后 symlink 到最新 run）
    PLAN.md                             # 阶段目标、参数、策略、过滤规则、辅助检查
    run.sh          → ../../../scripts/run_<stage>.sh
    SUMMARY.log     → ../../runs/<stage>/latest/main.log
    CONCLUSIONS.md                      # 自动生成（结果表 + 判定 + 下一步）

  runs/<stage>/                         # 运行层
    latest → <timestamp>                 # symlink 到最新
    <YYYYMMDD-HHMMSS>/
      execution.log                     # 控制平面（共享格式）
      main.log                          # 全局日志（自由文本，人眼可读）
      {task}.sub.log                    # 子任务日志
      {task}.raw                        # 黑盒 stdout+stderr 完整保留
      {task}.data.jsonl                 # 结构化数据（供下游 stage 消费）
```

模板文件位于 `templates/scenario-b/`，Agent 新建 stage 时参照模板填充：

| 模板 | 用途 |
|------|------|
| `execution.log.tmpl` | 控制平面日志，带可选领域指标字段 |
| `main.log.tmpl` | 全局日志段落结构：Header → Launch → Results → Checks → Footer |
| `PLAN.md.tmpl` | 计划文档骨架：目标 / 固定参数 / 候选列表 / 过滤规则 / 检查项 / 预期产物 |
| `CONCLUSIONS.md.tmpl` | 结论报告骨架：参数摘要 / 结果表 / 过滤判定 / 检查项 / 下一步 |

### 控制平面（实验场景）

```
[2026-05-24T10:00:00] STAGE BEGIN  stage=<stage>  tasks=N  run=<timestamp>  trace=<input>
[2026-05-24T10:00:01] TASK DISPATCH  name=<task>  log=<task>.sub.log  raw=<task>.raw  data=<task>.data.jsonl
[2026-05-24T10:05:00] TASK DONE  name=<task>  exit=0  elapsed_ms=294000  ipc=0.6982
[2026-05-24T10:05:01] STAGE DONE  stage=<stage>  pass=N  fail=N  best=<task>  best_ipc=X.XX  trace_kept=yes
```

规则：
- `TASK DONE` 携带该任务的关键指标（如 `ipc=`、`hit_rate=`），便于机器解析
- `STAGE DONE` 携带全局判定指标（`best=`、`trace_kept=`），下游 stage 可直接消费
- 所有字段均为可选——不同 stage 携带不同指标

### 脚本规范

1. **零绝对路径** — 所有路径通过 `$(dirname "$0")/..` 定位项目根目录
2. **纯黑盒** — 不修改被测程序源码，只调用预编译二进制
3. **并行执行** — 独立子任务 `&` + `wait`
4. **自动收尾** — 更新 `latest` symlink，生成 `CONCLUSIONS.md`，写出 `plans/` 软链接，写入 `execution.log`
5. **断点友好** — `set -uo pipefail`（非 `-e`）

### 场景 B 验证清单

- [ ] `plans/<stage>/PLAN.md` 在执行前已存在
- [ ] 脚本零绝对路径、纯黑盒
- [ ] 每次执行产生独立 `runs/<stage>/<timestamp>/` 目录
- [ ] 每个子任务有 `.sub.log` / `.raw` / `.data.jsonl`
- [ ] `execution.log` 包含 `STAGE BEGIN` / `TASK DISPATCH` / `TASK DONE` / `STAGE DONE`
- [ ] `main.log` 包含完整段落（header → launch → results → checks → footer）
- [ ] `latest` symlink 正确
- [ ] `plans/<stage>/` 软链接正确
- [ ] `CONCLUSIONS.md` 包含结果表 + 判定 + 下一步

---

## 两种场景对比

| 维度 | 场景 A: Agent 修改 | 场景 B: 黑盒实验 |
|------|-------------------|-----------------|
| 日志根目录 | `.omc/executions/` | `artifacts/runs/` |
| run-id | `时间戳-任务简述` | `时间戳` |
| 数据平面 | 策略日志（代码 diff、测试输出） | 子日志 + raw + data.jsonl |
| 步骤追踪 | `STEP N/M`（多步操作） | 无（单次黑盒调用） |
| 失败处理 | `ACTION REQUIRED` | 退出码 + `N/A` 标记 |
| 设计文档 | 无独立 plan | `plans/<stage>/PLAN.md` |
| 自动报告 | 无 | `CONCLUSIONS.md`（结果表 + 判定） |
| latest 指针 | 无 | `runs/<stage>/latest` symlink |
