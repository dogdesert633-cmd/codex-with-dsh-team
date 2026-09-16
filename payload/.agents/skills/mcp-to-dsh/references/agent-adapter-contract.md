# DSH Child-Agent Adapter Contract

这是 Monitor/transport 的目标语义。

## 目标

把 DSH 从“每个 Work Package 启动一个独立执行器”提升为“Codex child-agent 的外部执行后端”。

## Required identity

每次团队 dispatch 最终应可关联：

```text
agent_id
formal_role
lifecycle_action
session_id
turn_index
run_id
```

## Binding

- `spawn`: new agent -> new native DSH session.
- `follow_up`: existing agent -> resume its bound native session.
- new Run does not imply new Session.
- same role name does not imply same Agent.
- terminated/replaced Agent binding is not silently reused.

## Process lifetime

DSH process 不需要与 Agent 等寿命。

允许：

```text
turn completes
 -> bridge/process exits
 -> agent/session binding retained
 -> later follow-up starts bridge
 -> resume same native session
```

## Evidence

Run 继续作为独立 evidence 单元，保留：

- events
- prompt
- Git before/after
- timing
- exit
- retry

同时必须能追溯到 `agent_id/session_id/turn_index`。

## Monitor UI target

主要导航对象是 Agent，而不是 Run。

右侧展示该 Agent 的多轮持续对话，每轮清楚区分：

```text
CODEX -> DSH   输入
DSH -> CODEX   返回侧事件
```

返回侧事件可包含公开 Thought summary、Tool start/update、Plan、Reply、Stop。

非当前选中的 Agent 也必须持续更新状态与事件缓存；切换 Agent 不能创建新 session 或重复订阅。

## Reporter

Progress Recorder / Reporter 也是 DSH child agent。其输出是报告文本，不是机器 evidence。
