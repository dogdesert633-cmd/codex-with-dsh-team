# DSH Recovery and configured-model Fallback

## 目的

DSH 是首选 child-agent backend，但 Coordinator 负责真正的协调与主导：

> 有有效事件就继续等待；静默时才低频检查；明确报错时先诊断；先调整任务并恢复 DSH；经过有限且有意义的恢复仍失败，才把同一角色任务交给 `<team-configured-fallback-model>`、`medium` reasoning 的 Codex child agent。

不得因为一次短暂静默、单个工具错误或一次弹窗就立即回退。

---

## 1. 什么叫“有效进度”

以下任一项可重置静默计时：

- ACP / Monitor 收到新的公开 Thought summary；
- Tool start / Tool update；
- Plan update；
- Reply / assistant output；
- 新的测试、构建或命令状态；
- 明确的 session/process 状态变化；
- 其他能够证明当前 child agent 仍在推进任务的可核验事件。

只要持续有有效进度，Coordinator 不应额外轮询干扰 DSH。

---

## 2. 低频静默检查

默认从“最后一次有效进度事件”开始计时。

### 普通任务

- 首次静默检查：从最后一次有效进度开始，至少等待 120 秒；
- 后续每次状态轮询间隔也不得短于 120 秒；
- 不要高频轮询。

### 明显较慢的任务

对于测试、构建、依赖安装、较重扫描或长命令：

- Coordinator 应根据任务性质主动放宽等待时间；
- 较慢但仍适合 DSH 的步骤可把静默窗口放宽到约 3–5 分钟，或按任务性质进一步延长；
- 不得机械地因为短时间没有文本输出就判断 DSH 卡死。真正长等待型任务应在拆 Task 时直接路由给 Codex。

### 进入 SUSPECT

当连续多次低频检查都没有新的有效进度时，才进入 `SUSPECT`。

建议默认：

```text
last meaningful event
  -> wait >= 120s
  -> status check #1
  -> wait >= 120s
  -> status check #2
  -> wait >= 120s
  -> status check #3
  -> still no meaningful progress => DIAGNOSING
```

Coordinator 可以依据任务类型适当延长，但不要无限等待。

---

## 2.1 有事件就不要轮询

只要收到新的有效 ACP / Tool / Plan / Reply / process-state 事件：

- 重置静默计时；
- 继续等待；
- 不额外发起状态轮询。

事件持续增长本身就是“仍在推进”的证据。只有明确 error/stderr/process/session failure，或真正达到静默阈值，才检查状态。

## 3. 明确错误不需要傻等

若出现可核验的明确错误，可直接进入 `DIAGNOSING`，例如：

- DSH/ACP/provider/auth error；
- session resume failure；
- child process unexpected exit；
- tool crash / repeated tool error；
- Monitor 明确显示 agent/run failed；
- 连续错误弹窗且没有有效工作进展。

Coordinator 应读取并记录能够获得的：

- error message；
- stderr；
- exit code；
- session/process state；
- 最后一次成功事件；
- 当前 Work Package；
- 已产生的部分修改和 Git 状态；
- retry/attempt 计数。

不要只写“DSH 没响应”。

---


## 3.1 DSH Stop-and-Return 门禁

“明确错误时进入 DIAGNOSING”不表示允许 DSH 自己无限探索恢复。DSH worker-side 的本地恢复受 [dsh-stop-and-return.md](dsh-stop-and-return.md) 约束。

关键边界：

- 普通实现/测试失败不是基础设施 hard stop；
- 瞬时、无副作用工具错误最多本地重试 1 次；
- native crash、用户可见错误弹窗、失控进程、权限升级需求、session/transport hard failure、visual/long-wait 误路由应 Stop-and-Return；
- 同一或等价 infrastructure error 第 2 次出现时必须停止当前 DSH Attempt；
- DSH 停止后不得继续 parameter fishing；
- DSH 返回结构化 `STATUS: DSH_STOPPED`，由 Coordinator 决定新的 Attempt；
- Stop Report 不等于整个 Task 失败，也不自动触发 configured-model；Coordinator 仍按本文件的有界恢复状态机处理。

对于带 native crash / 用户可见弹窗 / 失控进程的 failure path，一次 hard stop 后只有 materially different 的执行架构才允许 Coordinator 再开 1 个 DSH Attempt；若等价根因再次出现，不得创建第 3 个 DSH 变体。

## 4. Coordinator 的恢复责任

诊断后，Coordinator 应先判断是哪类失败：

### A. 临时执行错误

动作：

- 保持同一个 logical child agent；
- 若 session 健康，follow-up / retry 同一个 DSH session；
- 不重复发送完全相同的任务而不做任何判断。

### B. Work Package 过大或耦合过多

动作：

- Coordinator 重新拆分或缩小 WP；
- 优先 follow-up 原 child agent；
- 只有明确需要 replacement 时才 spawn 新 agent。

### C. 指令或验收不清晰

动作：

- Coordinator 重编更明确的 DS_READY 合同；
- 补充必要输入、allowlist、acceptance、stop condition；
- 再交给 DSH。

### D. Session / agent 损坏

动作：

- 记录旧 agent/session 的 failure evidence；
- terminate / archive 旧 child；
- spawn replacement DSH child；
- 不把 replacement 假装成原 session 的自然 continuation。

### E. DSH/backend 持续故障

当经过有限恢复仍无法取得有效进展，进入 configured-model fallback。

---

## 5. “有限且有意义的恢复”标准

默认最多允许：

- 同一个 failure episode 进行 **2 次 Coordinator 有意义的恢复尝试**；
- “有意义”指 Coordinator 实际做了诊断并改变了执行条件，例如：
  - 重新拆包；
  - 缩小范围；
  - 修正合同；
  - replacement session；
  - 根据错误改变验证方式。

仅仅重复发送完全相同 prompt 不算一次有效恢复策略。

Coordinator 层面的总恢复预算仍是 2 次，但这不授权 DSH 在单个 Attempt 内自行连续试错。DSH 本地 retry 预算按 Stop-and-Return Gate 执行。

如果相同或等价 hard-stop root cause 在第二个 DSH Attempt 仍出现，应直接视为持续故障，不再创建第 3 个 DSH 参数变体。对于普通非 hard-stop 错误，若相同或等价错误持续出现约 3 次且没有新的有效进度，也应视为持续故障。

---

## 6. configured-model fallback

当满足以下条件之一时允许 fallback：

- 两次有意义的 DSH 恢复仍失败；
- DSH/provider/ACP 持续故障；
- replacement DSH child 仍无法取得有效进展；
- Coordinator 有足够 evidence 判断继续等待只会重复失败。

Fallback 规则：

```text
原角色任务
  DSH backend preferred
       ↓ failure + diagnose + bounded recovery
  Codex child agent fallback
       model = <team-configured-fallback-model>
       reasoning = medium
```

### 重要

- 角色不变，只替换 backend。
- 不由顶层 Coordinator 自己直接写代码。
- Coder 失败 -> spawn configured-model Coder child。
- Tester 失败 -> spawn configured-model Tester child。
- Explorer / Reviewer / Reporter 同理。
- configured-model fallback 仍遵守原角色 write/read 限制、独立性和验证规则。
- 不允许使用 high reasoning；fallback 固定为 `<team-configured-fallback-model>` + `medium`。

---

## 7. Reviewer / Tester 独立性

Fallback 不得破坏角色独立性。

例如正式 Reviewer 的 DSH backend 失败：

```text
DSH Reviewer child
  -> bounded recovery fails
  -> spawn independent configured-model Reviewer child
```

不能把 Coder 或 Coordinator 当作 Reviewer 替代。

---

## 8. 状态机

推荐控制面状态：

```text
ACTIVE
  -> SUSPECT
  -> DIAGNOSING
  -> RECOVERING
  -> ACTIVE
```

若恢复无效：

```text
RECOVERING
  -> FALLBACK_CONFIGURED_MODEL
  -> ACTIVE
```

若 configured-model fallback 也失败：

```text
FALLBACK_CONFIGURED_MODEL
  -> FAILED
```

---

## 9. Evidence

每次 failure / recovery / fallback 至少记录：

- agent_id / role；
- backend：`dsh | configured-model`；
- native session id（如适用）；
- last meaningful event time；
- observed error / stderr / exit；
- `DSH_STOPPED` stop code（如有）；
- DSH local retry count；
- spawned process/PID ownership 与 cleanup 状态（如适用）；
- status checks；
- recovery action；
- attempt number；
- fallback reason；
- final backend；
- final verdict。

不得在最终报告中把 configured-model 完成的任务记成 DSH PASS。

---

## 10. 用户可见行为

Coordinator 应在真正需要用户知道时报告：

- DSH 当前发生了什么错误；
- Coordinator 做了什么诊断；
- 是否正在重新拆包或 replacement；
- 是否已经触发 configured-model fallback；
- fallback 后的最终结果。

不要把内部每一次低频轮询都刷屏给用户。
