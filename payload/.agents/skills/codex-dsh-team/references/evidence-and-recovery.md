# 证据、计时与恢复

## 三层信息

### 机器证据

由 Monitor / Git / deterministic commands 自动生成：

- `agent_id`
- native `session_id`
- `turn_index`
- `run_id`
- timestamps / wall-clock duration
- process PID / exit code
- retry count
- ACP/SSE events
- Git before/after / diff / numstat
- validation exit status

DSH Reporter 和 Codex 都不得凭印象补写这些事实。

### DSH 工作结果

由 Explorer/Coder/Tester/Reviewer 返回的公开结果、代码和 verdict。

### 人类可读记录

由 DSH Progress Recorder / Reporter 基于前两类证据生成：

- PROGRESS
- RUN_REPORT
- 阶段总结
- failure summary
- final report draft

Codex Final Gate 核验，不重新发明另一套数字。

## 生命周期证据

每次 dispatch 至少可追踪：

```text
agent_id
role
lifecycle_action: spawn | follow_up
session_id
turn_index
run_id
```

必须能够证明：

- 同一 child 的 follow-up 复用了同一 session；
- 新 child 获得了新 session；
- Task 完成后 Agent 回到 Idle，且原 session binding 被保留；
- Reviewer 的独立性来自角色、私有上下文和 workspace 隔离；只有确需新 identity 时才使用新的 Reviewer agent/session；
- Coordinator 主动 retire 时保存了明确的 no-future-reuse 评估与理由；
- Run/Turn 没有被误当成新的 Agent。

## 时间边界

preflight/cold start 可单独记录。measured run 至少记录：

- task compilation/routing；
- Explorer；
- Coder；
- Tester；
- Reviewer；
- Reporter；
- Final Gate；
- total wall time。

## 归属

```text
delegated_code_task_ratio =
DSH 实际执行的代码 WP / 全部代码 WP

dsh_target_code_change_ratio =
DSH 归属 target-code changed LOC / 全部 target-code changed LOC
```

LOC 使用 Git numstat 时，必须有可核验 baseline 与 workspace/session/run 绑定。

## First attempt / retry

先保存首次 stdout/stderr、exit、diff、tests、timing，再进行有界 retry。

DSH/ACP/provider/auth/monitor 基础设施持续失败时停止为 `BLOCKED_INFRASTRUCTURE`，不得由 Codex 接管代码。

## 失效条件

- Codex 在 measured interval 直接编辑项目代码/测试/验证工具；
- agent/session/run 无法对应；
- follow-up 意外创建了新 session 且未报告；
- 新 child 偷用了旧 child session；
- Git/exit/test 关键证据缺失；
- Reviewer 独立性被破坏；
- Reporter 编造了机器数据；
- 失败 DSH run 经 Codex 修复后仍声称为 DSH PASS。

## 建议布局

```text
artifacts/dsh-team-runs/<team_run_id>/
├── contracts/
├── tests/
├── reviews/
├── reports/
├── metrics.json
└── machine-evidence-index.json

artifacts/dsh-gui-runs/<run_id>/
└── ACP/session/Git/process 原始证据
```


## DSH health / recovery / fallback evidence

当 DSH agent 出现静默或错误时，额外记录：

- `backend_initial = dsh`
- last meaningful event timestamp
- status-check timestamps
- observed error / stderr / exit
- `DSH_STOPPED` stop code（如有）
- DSH local retry count
- spawned process/PID ownership 与 cleanup 状态（如适用）
- recovery action(s)
- recovery attempt count
- replacement DSH agent/session（如有）
- fallback trigger reason（如有）
- `backend_final = dsh | configured-model`
- configured-model fallback model/effort（必须为 `<team-configured-fallback-model>` / `medium`）
- final role verdict

### Attribution rule

如果某个角色最终由 configured-model fallback 完成：

- 不得计为 DSH role success；
- 代码/测试/报告 attribution 归 fallback child；
- 最终 human-readable report 必须明确写出 fallback；
- DSH success rate 与 fallback rate 分开统计。


## Permission propagation evidence

对 DSH child 的 machine evidence 建议记录：

- requested execution permission；
- effective execution permission；
- permission verification status；
- permission propagation failure（如有）；
- agent_id / session_id / task_id / attempt_id。

至少在：

- 新 transport/adapter 首次使用；
- permission launch 逻辑发生变化；
- 出现 permission/sandbox denial；

时验证。

如果 requested=`full_access` 而 effective 不是 Full Access：

- attribution/implementation verdict 不应继续正常计算；
- 记录 `PERMISSION_PROPAGATION_FAILURE`；
- 先修 transport/launch。
