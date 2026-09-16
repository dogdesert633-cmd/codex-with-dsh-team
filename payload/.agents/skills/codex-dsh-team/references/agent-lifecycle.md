# Agent Lifecycle Contract

## 目的

DSH 是 Codex child-agent 的执行后端，不拥有独立的角色生命周期策略。

权威原则：

> Codex 如何 spawn / continue / wait / terminate / replace 子代理，DSH adapter 就如何创建、恢复、保留或关闭对应 DSH session。

## Identity hierarchy

```text
Codex Agent
  agent_id
  role
  status
  -> DSH Session
      session_id
      -> Turn 1
          run_id
      -> Turn 2
          run_id
```

### Agent

一个逻辑 Codex child agent。`agent_id` 在该 child 生命周期内稳定。

### DSH Session

Agent 的上下文容器。一个活跃 `agent_id` 在正常情况下只绑定一个 native DSH session。

### Turn

Coordinator 对同一个 child agent 的一次 follow-up 输入以及该次 DSH 输出。

### Run

该 Turn 的实际执行/evidence 单元。新的 Turn 可以产生新的 Run，但不能因此自动产生新的 Agent 或 Session。

## Lifecycle mapping

| Codex child-agent action | DSH adapter behavior |
|---|---|
| spawn | new `agent_id` -> new DSH session |
| send first task | prompt bound session |
| follow-up same child | resume same session, create new turn/run |
| poll / wait | inspect same agent/run; no new session |
| idle | retain binding; DSH process may exit |
| cancel current work | cancel active turn; agent may remain reusable |
| terminate child | mark agent terminal and close/archive session where supported |
| replace child | new `agent_id` and new session |

## Long-lived Agent retention

所有已招募 Agent 默认都是长寿团队成员：

```text
Task COMPLETED
 -> Agent IDLE
 -> retain agent_id
 -> retain session_id binding
 -> eligible for later follow_up
```

- Task 完成、暂时没有 Ready Task、当前轮结束或 Team 进入 `AWAITING_USER_ACCEPTANCE`，均不得自动 retire/terminate Agent。
- Scheduler 分配新 Task 时必须优先寻找兼容的 Idle Agent；复用时继续原 Agent identity 和原 Session。
- 只要仍有 Ready Task 能填入兼容 Idle 槽，就不得 spawn 新 Agent；只有所有空闲槽已用满且仍有独立可验收 Ready Task 时，才可进入 Phase 2。
- 新建同角色 Agent 只用于真实并行、所需独立性无法由现有成员满足、现有成员不可用/不可恢复，或明确能力不匹配。
- 只有用户明确要求，或 Coordinator 显式评估该 Agent 在剩余可预见工作中已无合理复用可能并记录理由时，才可 retire。
- “刚完成 Task”或“当前没有任务”本身不是退役理由。

### Same-role growth 是 capacity-aware parallel-first

`same_role_growth_policy: capacity_aware_parallel_first`。`maxMembers` 是 Coordinator 创建 Team 时写入的必填 Team 参数（控制面投影），本 Skill 不引入新的硬编码默认数字；成员上限计所有非 `TERMINATED` 的 Team members——Running + Idle 是常态示例，WAITING/RECOVERING/FALLBACK/FAILED 等暂态或失败态同样计入——不是 active Task 数；用户 role cap 保留。一个空闲但兼容的 Idle Agent 就是必须先使用的容量槽。

```text
Phase 1  用满每个兼容 Idle Agent 的一个 slot（复用原 Session）
Phase 2  所有兼容 Idle 槽已用满，且仍有独立 Ready Task 且 maxMembers / role cap 有余量 -> spawn 同角色 Agent 并行
Phase 3  cap 用满 -> Task 保持 READY/WAITING，不排队到忙 Agent 之后
```

Phase 2 的进入条件是所有兼容 Idle 槽已用满且仍有独立可验收 Ready Task，并必须同时满足三个安全门：Task 独立可验收；write scope 不冲突或使用隔离 workspace；禁止为凑并行度制造伪任务。并行扩容不改变已配置模型，也不放松“一个 Agent 最多一个 Active Task”。

## 禁止

- 不因“每个 WP 默认 fresh”而绕过 Codex child lifecycle。
- 不因新建 monitor Run 而新建 DSH Session。
- 不因为 role 名相同就把两个不同 Codex agents 合并成一个 session。
- 不把已经终止的 agent session 偷偷复用于一个新 child。
- transport 不自己决定 Coder/Tester/Explorer fresh 或 persistent。

## Reviewer 独立性

Reviewer 也是长寿 Agent，正式 review 默认先复用兼容的 Idle Reviewer 及其 Session。独立性来自：

- 不接收 Coder 私有 reasoning/transcript；
- 使用独立、只读或 disposable review workspace；
- 自行检查 candidate diff/evidence 并给出 verdict；
- 不让同一 Agent 同时承担被审 Coder 与 Reviewer 职责。

只有现有 Reviewer 无法保持所需隔离、正在执行其他 Task、不可恢复，或存在真实并行审查需求时，Coordinator 才 spawn 新 Reviewer；此时新 `agent_id` 必须获得新 DSH session。transport 不得把 Reviewer role 硬编码为永远 fresh。

并行的明确条件：有多个互相独立的 change 等待审查、现有 Reviewer 槽已全部占用、且 role cap 仍有余量时可创建并行同角色 Reviewer。独立性边界不变：不接收 Coder 私有 reasoning/transcript，使用独立只读/disposable workspace，独立给出 verdict。

## Repair

若 Coordinator 的语义是“让原 Coder 继续修复”：

```text
follow-up same Coder agent
    -> same DSH session
```

若 Coordinator 明确 replace / spawn 新 Coder：

```text
new Coder agent
    -> new DSH session
```

## Monitor projection

Monitor 的主要导航对象应逐步从 Run 改为 Agent：

```text
Agents
├─ Coder
├─ Explorer
├─ Tester
├─ Reviewer
└─ Reporter
```

点击 Agent 后，右侧显示其持续对话：

```text
Turn 1
CODEX -> DSH
DSH -> CODEX

Turn 2
CODEX -> DSH
DSH -> CODEX
```

每个 Turn 背后仍保留独立 `run_id`、timing、Git 和 process evidence。

## 实现验收

当 Monitor/adapter 实现本契约时，至少验证：

1. spawn Coder -> session A；
2. follow-up Coder -> 仍为 session A；
3. idle 时 process 可退出但 binding 保留；
4. terminate 后不再把 session A 当作新 child；
5. spawn 新 Coder -> session B；
6. Task 完成 -> Agent IDLE，binding/session 保留并可被后续 Task 复用；
7. Idle Reviewer 可在保持独立性边界时复用原 session；确需新 Reviewer 时才获得独立 session；
8. retire 有用户指令或 Coordinator 的明确无复用评估与理由；
9. Run/Turn evidence 仍可独立计时与归属。
