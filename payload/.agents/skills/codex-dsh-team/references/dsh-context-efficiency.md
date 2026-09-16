# DSH Context Efficiency / Bounded Reading Contract


## 适用范围

本文件 **只约束 DSH-backed roles**：

- DSH Code Explorer / Debugger
- DSH Coder / Repair Worker
- DSH Code Reviewer
- DSH Progress Recorder / Reporter
- 其他 DSH-backed non-visual Operator

本文件 **不约束非 DSH 角色**，包括：

- Codex Coordinator / Orchestrator
- Codex Tester / Test Engineer
- Codex-side vision validation
- Codex-side long-wait / long-running execution
- 其他 Codex child agent

非 DSH 角色根据自身任务需要决定读取范围，不受这里的 1–5 primary files、8-file reconsideration、bounded-reading ladder 等限制。

## 目标

减少 DSH 为完成一个局部 Task 而通读整个项目、整个文件或大量无关文档造成的 token 浪费。

核心原则：

> 先把 Task 拆小，再把上下文裁到最小；DSH 从最小必要信息开始，只有出现明确证据表明上下文不足时，才逐级扩大读取范围。

这不是禁止 DSH 阅读代码，而是要求 **按需读取、证据驱动扩展**。

---

## 1. Coordinator 负责 Context Curation

Codex Coordinator 在派发 Task 前，优先提供一个最小 `Context Pack`。

Context Pack 应尽量包含：

- Task objective；
- acceptance criteria；
- 已知相关文件；
- 相关 symbol / function / class / section；
- 必要接口和依赖；
- 必要测试入口；
- 已知错误/日志；
- 允许的 discovery 范围；
- 哪些目录/文件默认不要读。

DSH 不应因为“项目很大”就自行全仓库通读。

---

## 2. Task 拆分应降低上下文需求

拆 Task 时优先做到：

- 一个 Task 聚焦一个明确结果；
- write allowlist 尽量小；
- 尽量让一个 Task 只依赖少量主文件；
- 前后端、UI、测试、文档等不同问题拆开；
- 不把多个耦合较弱的问题塞给一个 DSH Agent；
- 若一个 Task 必须阅读大量无关目录才能理解，优先重新拆分，而不是直接扩大 context。

正确方向：

```text
大需求
  -> Explorer 定位
  -> T1: 修改 registry
  -> T2: 修改 sidebar
  -> T3: 测试 lifecycle
```

而不是：

```text
“阅读整个项目，然后完成所有改造”
```

---

## 3. 默认读取策略

### 3.1 先搜索，再打开

优先：

- filename / symbol search；
- grep / rg；
- imports / call sites；
- line-range / symbol-level read；
- shallow tree / targeted glob。

避免一开始：

- 全仓库递归读取所有文件内容；
- 把所有 docs 全部打开；
- 对每个匹配文件全文读取；
- 为了“熟悉项目”读取大量无关模块。

### 3.2 大文件优先局部读取

如果文件较大：

1. 先找 symbol / heading / line range；
2. 只读相关片段；
3. 必要时补读相邻函数/调用点；
4. 只有确认局部信息不足，才全文读取。

### 3.3 文档同样按需

DSH 不需要重复读取 Coordinator 已经读过并编译进 Work Package 的全部：

- AGENTS；
- Skill；
- PROGRESS；
- 历史 review；
- 大量设计文档。

除非 Task 本身需要验证这些原始规则，或 Work Package 明确要求。

---

## 4. Context Expansion Ladder

默认采用逐级扩展：

### Level 0 — Compiled Context

只使用 Work Package + Context Pack。

### Level 1 — Primary Files

读取 Coordinator 指定的直接相关文件/符号。

### Level 2 — One-hop Dependencies

只补读：

- imports；
- callers/callees；
- referenced config；
- direct tests；
- direct interface definitions。

### Level 3 — Bounded Discovery

在明确目录内做有界搜索，定位额外文件。

### Level 4 — Broad Repository Investigation

只有出现明确证据表明前面层级不足时才允许。

需要 broad investigation 时：

- 先向 Coordinator说明为什么；
- 指明要扩大到哪些目录；
- 不把“整个 repo”当作默认范围。

---

## 5. Soft Read Budget

这是软约束，不是硬性报错阈值。

普通局部 Task 建议：

- 初始 primary files 通常控制在约 1–5 个；
- 超过约 8 个完整文件前，应重新判断 Task 是否过大或 context 是否可进一步裁剪；
- 大文件尽量使用 symbol/range reads，而不是全文；
- 全仓库/大量目录扫描必须有明确理由。

不要为了机械满足数字而漏掉必要事实；目标是减少无关读取。

---

## 6. Explorer 的特殊规则

Explorer 可以比 Coder 有更宽的 discovery 范围，但仍要节制。

推荐顺序：

```text
shallow inventory
 -> targeted search
 -> open matching symbols/files
 -> map minimal dependency neighborhood
 -> return Context Pack
```

Explorer 输出应帮助后续 Coder **少读文件**，而不是把大量原始文件内容复制进报告。

Explorer 应返回：

- 最小相关文件集；
- 关键 symbols；
- dependency neighborhood；
- 建议 write allowlist；
- 建议 validation；
- 哪些区域确认无需读取。

---

## 7. Coder / Tester / Reviewer

### Coder

- 以 Context Pack + primary files 为起点；
- 不重新做一次全仓库 Explorer；
- 缺上下文时按 Expansion Ladder 补读；
- 若 Task 明显需要大范围调查，先返回 Coordinator 重新拆包/Explorer。

### Tester

Tester 默认由 Codex child agent 承担，因此 **不适用本 DSH Context Efficiency 策略**。

Tester 的读取范围由 Tester 自己和 Coordinator 根据验证任务决定，不受本文件的 bounded-reading / file-count 软约束。

### Reviewer

Reviewer 仍由 DSH 承担，默认采用 **change-scoped review**。

初始 context：

1. 当前 Task contract；
2. Coder candidate diff；
3. changed files；
4. direct tests；
5. 必要的一跳 interfaces/imports/callers/callees/config。

Reviewer 默认不重新审查整个项目。只有明确 evidence 表明风险跨出当前 change scope 时，才按 Expansion Ladder 扩大范围。

不得把 reviewer independence 等同于 full-repo scan。

### Reporter

- 读取 machine evidence 和公开结果；
- 不为写报告重新遍历整个代码库。

---

## 8. 长寿 Agent 的上下文复用

长寿 Agent 可以利用已有 session 上下文减少重复读取。

但必须注意 stale context：

- 文件被其他 Agent 修改后，不应只依赖旧记忆；
- 对当前 Task 直接相关的 changed files 做 targeted refresh；
- 不需要因为一次修改就重新全文读取所有历史文件。

推荐：

```text
reuse known context
 + refresh changed/critical symbols
```

而不是：

```text
每个新 Task 都从头阅读整个项目
```

---

## 9. Coordinator 的 escalation 责任

当 DSH 返回：

```text
CONTEXT_INSUFFICIENT
```

应说明：

- 缺少什么事实；
- 需要读取哪些文件/目录；
- 为什么现有 Context Pack 不足。

Coordinator 决定：

1. 补充一个小的 Context Pack；
2. 允许 Level 2/3 有界扩展；
3. 重新拆 Task；
4. 必要时派 Explorer；
5. 最后才允许 broad investigation。

不得把“上下文不足”自动等同为“给 DSH 整个项目”。

---

## 10. 禁止模式

默认禁止以下低效模式：

- `read every file in the repo`;
- “先完整熟悉整个项目再开始”；
- 小 Task 无理由读取所有 AGENTS/docs；
- Coder 重复 Explorer 已完成的全局调查；
- Tester/Reviewer 为独立性而全文扫描项目；
- 把大量完整文件原文复制进 Work Package；
- follow-up 同一 Agent 时重复读取未变化的大文件；
- 仅为了保险而递归读取所有目录。

---

## 11. Evidence / Metrics

建议记录：

- initial_context_files；
- extra_files_read；
- full_file_reads；
- targeted_range_reads；
- broad_repo_scan_used；
- context_escalation_count；
- task_redecomposed_for_context；
- repeated_unchanged_file_reads（如可检测）。

这些仅用于评估 **DSH task** 的 token efficiency，不要求 Monitor 当前立即实现全部指标；Codex-only roles 不纳入这些 context-efficiency 指标。

---

## 12. 目标判断

好的 DSH Task 应尽量满足：

```text
明确目标
+ 小 write scope
+ 小 Context Pack
+ 少量 targeted discovery
+ 可验证结果
```

如果完成一个局部需求必须让 DSH 通读大半个项目，优先怀疑 Task 拆分或 Context Pack 设计不合理。
