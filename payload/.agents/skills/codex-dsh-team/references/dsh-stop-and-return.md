# DSH Stop-and-Return Gate

## 目的

本规则约束 **DSH child 自己** 在工具、基础设施、原生进程、权限或执行环境失败时的行为。

核心原则：

> DSH 是 Worker，不是无限自恢复的 Orchestrator。普通开发失败可以继续修；基础设施/工具/原生进程失败必须有严格的本地重试上限。达到停止条件后，DSH 立即停止当前失败路径、保留证据并把错误返回给 Coordinator，由 Coordinator 决定 re-plan / follow-up / replacement / re-route / configured-model fallback。

本规则不把“测试红了”“实现还有 bug”自动当作基础设施故障。目标代码的正常开发迭代仍按角色职责继续。

---

## 1. 先区分三类失败

### A. 正常任务失败（不触发本规则的硬停止）

例如：

- 单元测试因为待修代码失败；
- lint/type-check 暴露真实代码问题；
- 目标程序按测试目的返回业务错误；
- Reviewer/Tester 发现验收不通过。

这些属于工作内容本身。Coder 可继续修复；Tester/Reviewer 返回发现，不要把它包装成 infrastructure failure。

### B. 可疑的瞬时工具失败（允许极少量本地重试）

例如：

- 一次无副作用的短命令超时；
- 一次临时连接 reset；
- 一次短暂的文件占用，而重试不会扩大副作用。

仅当 **安全、短时、无新增副作用、且预计同一方法立即重试有价值** 时，DSH 才可在当前 Attempt 内进行 **最多 1 次本地重试**。

### C. 基础设施 / 工具 / 原生进程硬失败（Stop-and-Return）

以下任一项出现时，DSH 必须停止当前失败路径并返回错误：

- native process crash / unexpected fatal exit；
- Windows SEH / NTSTATUS 类 fatal exit，例如 `0x80000003 / STATUS_BREAKPOINT`、access violation；
- segfault / core dump / runtime fatal abort；
- 浏览器、GUI、helper、driver 等外部工具出现用户可见 crash dialog、错误弹窗或失控窗口；
- 同一或等价 infrastructure/tool error 在同一 failure episode 内出现 **第 2 次**；
- sandbox / permission / policy denial，且实际 DSH child 未满足 Team 要求的 Full Access execution permission；
- provider / auth / ACP / session 明确损坏或无法恢复；
- 进程树失控、无法确认哪些 PID 属于本 Attempt，或无法安全 cleanup；
- 执行中发现 Task 实际是 `visual` 或 `long_wait`，不应由 DSH 执行；
- 下一步需要越过 allowlist、做不可逆操作、扩大权限或触碰未授权资源；
- 当前 Work Package 的 stop condition 已满足。

---

## 2. DSH 本地重试预算

### 2.1 默认规则

- **硬失败：默认 0 次自动重试。**
- **瞬时、无副作用工具失败：最多 1 次本地重试。**
- 同一或等价 infrastructure failure 出现第 2 次后，必须 `DSH_STOPPED`。
- 改 flag、换 shell、换 headless mode、换启动器、换临时目录等，如果根因没有证据表明已改变，仍算同一 failure episode，不得借此重置计数。

### 2.2 原生进程 / 弹窗特别规则

如果一次失败已经造成：

- 原生 crash dialog；
- 连续错误弹窗；
- 新的 GUI/browser 实例不断被启动；
- 用户桌面被干扰；
- 无法可靠追踪/回收子进程；

则 **立即冻结该启动路径**：

1. 不再启动新的同类进程；
2. 不枚举更多启动参数碰运气；
3. 仅允许读取现有日志、stderr、exit、PID/process evidence；
4. 尝试安全清理“明确由本 Attempt 创建”的子进程；
5. 返回 `DSH_STOPPED_NATIVE_CRASH` 或 `DSH_STOPPED_UNCONTROLLED_PROCESS`。

除非 Coordinator 在新的 Attempt 中明确批准 materially different 的执行架构，否则原 DSH child 不得继续该路径。

---

## 3. 禁止 parameter fishing

在 infrastructure/tool failure 后，DSH 不得自行进入“不断换参数试”的探索循环。

禁止模式包括但不限于：

```text
command A fails
 -> add --no-sandbox
 -> fails
 -> add --single-process
 -> fails
 -> switch headless mode
 -> fails
 -> write another launcher
 -> spawn another browser
 -> keep trying
```

DSH 可以在 Stop Report 中提出候选方案，但 **候选方案 ≠ 已验证成功**。是否执行候选方案由 Coordinator 在新的 Attempt 中决定。

---

## 4. 权限 / sandbox 规则

本 Team 已明确要求 DSH child 使用 Full Access execution permission。

因此：

- DSH child 不负责自行“申请更宽权限”；
- Coordinator / adapter 必须在 launch 层正确传播 Full Access；
- 没有明确 denial evidence 时，fatal crash 仍不能自动解释为 sandbox denial；
- 若出现明确 sandbox/permission denial，并发现实际 child 没有获得要求的 Full Access，返回 `DSH_STOPPED_PERMISSION_PROPAGATION`；
- 这属于 launch/transport infrastructure bug，不属于目标代码失败；
- DSH 不允许通过 `--no-sandbox`、换 shell、换 launcher 等 parameter fishing 绕过 permission gate；
- Full Access 只改变 execution capability，不取消角色合同、write allowlist 或 Task scope。

详见 `dsh-full-access-permissions.md`。

---

## 5. Long-wait / visual 误路由的停止规则

如果 DSH 执行后才发现 Task 实际属于：

- `long_wait`：长测试、长 build、长安装、长仿真、持续等待外部服务；
- `visual`：必须看图片/截图/GUI视觉结果才能验收；

DSH 不应继续占用 session 或自造替代方案。

返回：

- `DSH_STOPPED_LONG_WAIT_MISROUTE`；或
- `DSH_STOPPED_VISUAL_MISROUTE`。

DSH 可以准备脚本、命令、自动化检查，但真正的等待/视觉验收交回 Codex 对应能力。

---

## 6. 进程清理规则

DSH 创建外部进程时，应尽量记录 parent/child PID 和启动命令。

失败后的 cleanup：

- 只结束能够证明由当前 Attempt 创建的进程；
- 不得为了“清干净”而按进程名广泛杀进程，例如未经授权 `taskkill /IM msedge.exe /F`；
- 不得误伤用户已有浏览器、IDE、终端或其他会话；
- 无法确定 ownership 时，不做激进 cleanup，返回 `cleanup = uncertain`；
- cleanup 本身若再次失败，不继续递归尝试，记录后停止。

---

## 7. 成功声明门禁

DSH 必须区分：

- `HYPOTHESIS`：推测；
- `UNVERIFIED_CANDIDATE`：已准备但未真实验证的候选方案；
- `VERIFIED`：有实际执行证据满足 acceptance。

以下都 **不能** 写成 `works / fixed / PASS`：

- “我认为同一进程树可能可行”；
- 写出了一个 harness，但尚未运行成功；
- 某一步看起来没有报错，但 acceptance 尚未完成；
- 仅根据错误码猜测根因。

只有实际成功执行并满足 Work Package 的验证条件，才能标记 `VERIFIED`。

---

## 8. 标准 Stop Report

触发 Stop-and-Return 时，DSH 用结构化结果返回，不继续自恢复：

```text
STATUS: DSH_STOPPED
STOP_CODE: <code>
TASK_ID: <task-id>
ATTEMPT_ID: <attempt-id>
ROLE: <role>
FAILURE_CLASS: <native_crash | repeated_infra | permission_propagation | session | capability | long_wait | safety | other>
LAST_SUCCESS: <last verified successful step>
ERROR_EVIDENCE:
  - <exact error / stderr / exit / process state>
LOCAL_RETRY_USED: <0|1>
ATTEMPTS:
  - <attempt 1 + result>
  - <optional local retry + result>
SPAWNED_PROCESSES:
  - <pid / command / known state>
CLEANUP: <done | partial | uncertain | not_applicable>
CHANGED_FILES:
  - <files or none>
PARTIAL_RESULT: <what remains usable>
HYPOTHESIS: <optional, clearly unverified>
SAFE_NEXT_OPTIONS:
  - <candidate, not executed>
DO_NOT_RETRY_SAME_PATH: <true|false>
```

建议 `STOP_CODE`：

- `DSH_STOPPED_NATIVE_CRASH`
- `DSH_STOPPED_UNCONTROLLED_PROCESS`
- `DSH_STOPPED_REPEATED_INFRA`
- `DSH_STOPPED_PERMISSION_PROPAGATION`
- `DSH_STOPPED_SESSION_OR_TRANSPORT`
- `DSH_STOPPED_LONG_WAIT_MISROUTE`
- `DSH_STOPPED_VISUAL_MISROUTE`
- `DSH_STOPPED_SCOPE_OR_SAFETY`

---

## 9. Coordinator 接到 Stop Report 后

Stop Report 表示 **当前 DSH Attempt 已停止**，不等于整个用户任务立即失败。

Coordinator 必须：

1. 保存错误证据和 Attempt；
2. 不对同一个 child 简单回复“继续试”；
3. 判断是否需要：
   - 修正/缩小 Work Package；
   - materially different 的 follow-up；
   - replacement DSH child；
   - re-route 到 Codex long-wait / vision；
   - 同角色 configured-model fallback；
   - `BLOCKED_INFRASTRUCTURE`；
4. 同一 failure episode 仍受 Coordinator 的 **最多 2 次有意义恢复**总预算约束；
5. 若第二个 DSH Attempt 仍出现相同/等价 hard-stop root cause，不再启动第 3 个 DSH 变体，直接 fallback / re-route / blocked。

对于带用户可见弹窗、native crash 或失控进程的路径，应更保守：一次 hard stop 后，只有 materially different 且可解释的新执行架构才允许再试一次。

---

## 10. Edge / Chromium 类问题示例

若 Edge 启动返回：

```text
EXIT=-2147483645
0x80000003 / STATUS_BREAKPOINT
```

并伴随错误弹窗，则 DSH 应：

1. 记录 exit code、启动命令、PID、stderr；
2. 不再依次尝试 `--headless=old`、`--single-process`、`--no-sandbox` 等参数组合；
3. 不继续生成新的 Edge 实例；
4. 不因为“可能是 sandbox”就自行扩大权限；
5. 若能安全确认 ownership，则清理本 Attempt 创建的子进程；
6. 返回 `DSH_STOPPED_NATIVE_CRASH`；
7. 可以把“same-process-tree harness”列为 `UNVERIFIED_CANDIDATE`，但在未真实成功前不得写成 `works`。

Coordinator 若认为该候选方案值得尝试，应把它编译成 **新的 Attempt + 明确 acceptance**，而不是让原 DSH run 无限探索。
