# 团队路由协议

## 角色与执行后端

| 正式角色 | 后端 | 写入边界 |
|---|---|---|
| Coordinator / Orchestrator | Codex 主 Agent | 合同、路由、Final Gate |
| Advisor | Codex 子 Agent | 只读建议 |
| Code Explorer / Debugger | DSH child agent | 默认只读 |
| Coder / Repair Worker | DSH child agent | 合同 allowlist |
| Tester / Test Engineer | Codex child agent (`<team-configured-fallback-model>`, medium) | 默认只读；测试/工具按 allowlist |
| Code Reviewer | DSH child agent | disposable workspace，只读 |
| Progress Recorder / Reporter | DSH child agent | 人类可读记录/报告 |
| Final Gate | Codex Coordinator | 只读判断 |

## 生命周期

角色是否继续使用原上下文，不由 DSH transport 按 role 名硬编码。

唯一规则：

> 继承 Codex 原本的 child-agent lifecycle。

- Coordinator spawn 新 child -> 新 `agent_id` + 新 DSH session。
- Coordinator follow-up 同一个 child -> 同 `agent_id` + 同 DSH session + 新 Turn/Run。
- wait/poll -> 不创建 session。
- terminate/replace -> 按 child lifecycle 结束旧 binding；新 child 使用新 session。
- Task 完成 -> Agent 回到 Idle，保留 `agent_id` 与 Session binding，等待后续复用。
- 不因本轮完成、暂时无 Task 或 Team 等待验收而自动 retire。

详见 `agent-lifecycle.md`。

## 正式 Reviewer

正式 review cycle 要求 Reviewer 与 Coder 独立，但不要求每轮新建 Reviewer。默认先复用 Team 内兼容的 Idle Reviewer，并通过私有 transcript 隔离和独立只读 workspace 保持独立性。

只有现有 Reviewer 无法满足隔离、不可用/不可恢复，或需要真实并行 review 时才：

```text
Coordinator spawn new Reviewer child
 -> new agent_id
 -> new DSH session
```

并行同角色 Reviewer 的明确条件：有多个互相独立的 change 等待审查、现有 Reviewer 槽已全部占用、且 role cap 仍有余量。此时可 spawn 并行 Reviewer；独立性边界不变。

Reviewer 不接收 Coder 私有 transcript，使用 disposable read-only workspace。

## Codex 控制面禁区

Codex 不创建或修改：

- 生产源码、测试、fixtures；
- migration/build/config behavior；
- 临时验证代码；
- 已委派 WP 的 target paths。

Codex 可以：

- 编译 Work Package；
- 路由/等待/终止 child agent；
- 查询只读 Git/状态；
- 操作 Monitor；
- 执行 Final Gate。

## 人类可读记录

长篇进度、运行报告和报告正文优先交给 DSH Reporter。

机器证据必须由 Monitor/Git/确定性命令生成，Reporter 只引用和整理。

## 工作流示意

```text
需求
 -> Codex Coordinator
    -> Advisor（按需）
    -> spawn Explorer（按需）
    -> Phase 1: 用满兼容 Idle Coder（复用原 Session）
    -> Phase 2: 独立可验收 / write scope 不冲突 / cap 有余量
                -> spawn 更多同角色 Coder 并行
    -> Phase 3: cap 用满 -> Task 保持 READY/WAITING
    -> spawn/follow-up Codex Tester（<team-configured-fallback-model>, medium）
    -> reuse Idle independent Reviewer when compatible
       -> 多个独立 change + Reviewer 槽已占用 + cap 有余量 -> spawn 并行 Reviewer
    -> blocker/major?
        -> follow-up original Coder 或 replace/spawn new Coder
        -> follow-up Idle Reviewer；仅在隔离/并行/恢复需要时 spawn 新 Reviewer
    -> DSH Reporter
    -> Codex Final Gate
```

## 拆包

- 一个 WP 对应一个清晰结果。
- WP 必须带 `agent_id` 和 `lifecycle_action`。
- `spawn` 创建新 child；`follow_up` 只能指向已存在 agent。
- Run 是 evidence 单元，不是 Agent identity。
- 测试/验证工具属于 DSH-authored code。


## DSH 失败时的路由

正常优先级：

```text
DSH child
  -> wait for meaningful events
  -> low-frequency status checks only when silent
  -> diagnose explicit/repeated failures
  -> bounded DSH recovery / re-plan
  -> same-role configured-model fallback
```

Fallback 固定：

- model: `<team-configured-fallback-model>`
- reasoning: `medium`

不使用 high reasoning。

Fallback 不是 Coordinator 直接执行任务，而是 spawn 一个同角色 Codex child agent。
Tester/Reviewer 的独立性和只读/写入边界保持不变。

详细阈值和状态机见 `dsh-recovery-and-fallback.md`。

## Team / Task routing

不要把“一个 WP”自然等价成“一个新 Worker”。

正确模型：

```text
Team
  -> Agent Pool
  -> Dynamic Task DAG
```

Task 由 Coordinator 显式 assign 给长寿 Agent。Task 完成后 Agent 回到 Idle。

Idle 是可复用状态，不是待退役状态。Coordinator 只有在记录了具体的“后续无合理复用可能”评估后才可主动 retire；Task 完成、当前没有 Ready Task、Team 进入 `AWAITING_USER_ACCEPTANCE` 都不是充分理由。用户显式 retire/dissolve 仍可结束对应生命周期。

### 简单 Scheduler

`same_role_growth_policy: capacity_aware_parallel_first`。调度是 parallel-first，不是默认串行：`maxMembers` 是 Coordinator 创建 Team 时写入的必填 Team 参数（控制面投影），本 Skill 不引入新的硬编码默认数字；成员上限计所有非 `TERMINATED` 的 Team members——Running + Idle 是常态示例，WAITING/RECOVERING/FALLBACK/FAILED 等暂态或失败态同样计入——不是 active Task 数；用户 role cap 仍然生效。一个已存在但空闲的兼容 Idle Agent 就是一个必须先使用的空闲槽位。

```text
Task/Agent state change
  -> recompute Ready Tasks
  -> collect compatible Idle Agents
  -> Phase 1: 用满每个兼容 Idle Agent 的一个 slot，复用其原 Session
  -> Phase 2: 所有兼容 Idle 槽已用满，且仍有独立 Ready Task 且 maxMembers / role cap 有余量
             -> spawn 同角色 Agent 并行
  -> Phase 3: cap 用满 -> 保持 READY/WAITING
```

Phase 2 必须同时满足三个安全门：

1. 该 Task 独立可验收（独立合同、独立 verdict，不是别的 Task 的碎片）；
2. write scope 不冲突，或各自使用隔离 workspace；
3. 禁止为凑并行度制造伪任务。

只要仍有 Ready Task 能填入兼容 Idle 槽，就不得 spawn 新 Agent；Phase 2 的进入条件是所有兼容 Idle 槽已用满且仍有独立可验收 Ready Task。也不得为了并行使 idle Agent 闲置，或在 cap 已满时把独立 Task 无必要地排队到忙 Agent 之后。并行扩容不改变已配置的 role/backend model，也不放松角色独立性与“一个 Agent 最多一个 Active Task”。下一版仍不做复杂调度评分或 autonomous task claiming。

### Capability routing

- 普通非视觉短/中时长工作：DSH preferred。
- PowerShell/Git/file/log/process/short test 等可交给 DSH。
- 图片/截图/GUI视觉/OCR/视觉验收：Codex-side vision。
- long_wait/long_running execution：Codex-side execute/monitor。
- 混合任务拆开后分别路由。


## DSH execution permission

所有 DSH backend child 默认 Full Access。

```text
Codex child-agent contract
 -> DSH adapter
 -> Full Access DSH session
```

这适用于 spawn、follow-up/resume、replacement 和所有 DSH 角色。

Role scope 与 execution permission 分离：

- Coder 可写范围仍由 WP allowlist 控制；
- Tester 不修改 production code，除非合同明确允许；
- Reviewer / Explorer 仍可被合同定义为 read-only；
- Reporter 只写报告路径。

如果实际 DSH child 被降级成 restricted sandbox：

```text
PERMISSION_PROPAGATION_FAILURE
```

不要继续执行目标 Task，也不要把它当作 implementation failure。


## Context-efficient routing

任务拆分不仅考虑代码职责，也考虑上下文成本。

优先把大需求拆成多个可以用少量文件完成的小 Task。

Coordinator 应让 Explorer/已有证据先定位最小相关文件集，再把精炼 Context Pack 交给 **DSH Coder / DSH Reviewer**。

默认禁止：

- 小 Task 全仓库阅读；
- Coder 重复 Explorer 的全局调查；
- DSH Reviewer 无理由扫描整个项目；
- follow-up 重读未变化的大文件。

DSH context expansion 必须按 `dsh-context-efficiency.md` 的 ladder 逐级进行。

## Tester routing

Tester / Test Engineer 默认使用 Codex child agent：

```text
model = <team-configured-fallback-model>
reasoning = medium
```

Tester 可承担普通回归、长时间测试/等待与监控；视觉验收走 Codex-side vision。

Tester 不修改 production code。需要测试代码/fixture/helper 时，使用独立 Tester WP 和 write allowlist。

## Reviewer routing

Code Reviewer 仍由 DSH 承担，但默认 `change_scoped`：

- current Task contract；
- candidate diff；
- changed files；
- direct tests；
- one-hop related interfaces/imports/callers/callees/config。

只有明确跨模块 evidence 时才扩大范围。Reviewer independence 不等于 full-repo scan。


## Context policy scope

`dsh-context-efficiency.md` 只约束 DSH-backed roles。

Codex Tester 不受 DSH bounded-reading 约束；它可以根据测试/回归/长时间验证需要读取更宽上下文。

Codex Coordinator、Codex-side vision、Codex long-wait execution 也不受 DSH context file-count / expansion-ladder 限制。
