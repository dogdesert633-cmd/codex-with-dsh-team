## Codex × DSH team routing

当用户要求 DSH 团队、DSH 子代理替代、代码归属验证或 DSH Monitor 时，使用 `$codex-dsh-team`；底层传输使用 `$mcp-to-dsh`。

核心原则：

- Codex 继续拥有原有 child-agent 生命周期。
- DSH adapter 只把 `agent_id` 映射到 native DSH session。
- spawn 新 child -> 新 session。
- follow-up 同一 child -> resume 同一 session。
- Run/Turn 是 evidence 单元，不是 Agent identity。
- transport 不按 Coder/Tester/Explorer role 自行决定 fresh/resume。
- Reviewer 独立性通过角色/私有上下文/只读 workspace 隔离实现；不默认每轮新建 Reviewer。

所有项目代码、测试、验证工具、正式 review 由 DSH 承担。人类可读进度和报告正文优先交给 DSH Progress Recorder / Reporter。

Monitor/Git/确定性命令自动生成 timing、Git、session、run、exit、retry 等机器证据；DSH Reporter 只能整理，不得发明。

Codex Coordinator 负责需求、合同、路由、agent 生命周期、Monitor ownership 与 Final Gate，不直接修改项目代码，也不在 Reporter 可用时重写长篇报告。

Monitor 端口由 Coordinator 自动管理；用户不需要选择或记忆端口。

### 模型、验证与 No-Hash

- 角色复制、并行扩容、额度优化和失败恢复不得改变已经配置的 role/backend 模型。
- 使用最小充分验证；不为取得第二份相同结果而重复 Coder、Reviewer、Tester 或 Coordinator 检查。
- 禁止让 DSH 与 Codex 重复执行同一 Task 仅用于 reassurance。
- 禁止使用 `Get-FileHash`、`sha256sum`、`md5sum`、`certutil -hashfile` 或等价 hash/checksum/digest 手段。
- 不创建、更新或使用 checksum 文件、digest manifest，也不调用依赖 hash 比较的同步/验证路径。
- 使用 Git 状态/diff、直接内容比较、确定性测试、exit code、日志和实际输出作为证据。
- 每个新的 Coordinator 对话第一次实际使用 DSH 时，报告实际 `Project / Workspace / Monitor URL / started|reused`。


### DSH failure recovery

DSH 是首选执行 backend。Coordinator 不因单次静默或一次工具错误立即停止。

- 有持续事件时不轮询。
- 普通任务从最后一次有效事件起至少 120 秒后才首次检查，之后每次检查间隔也不得短于 120 秒；较慢但仍适合 DSH 的步骤可放宽到约 3–5 分钟。
- 明确报错时读取 stderr/exit/session/process evidence。
- DSH 本地只允许对瞬时、无副作用工具失败 retry 1 次；native crash、错误弹窗、失控进程、权限升级需求、session/transport hard failure、visual/long-wait 误路由必须 Stop-and-Return。
- 同一/等价 infrastructure error 第 2 次出现时，DSH 必须停止当前 Attempt；不得通过不断换 flag/shell/launcher/headless mode 继续 parameter fishing。
- 未真实验证的方案只能写 `HYPOTHESIS / UNVERIFIED_CANDIDATE`，不得写 `works / PASS`。
- Coordinator 收到 `DSH_STOPPED` 后先诊断、缩小/重编 WP、materially different follow-up、replacement 或 re-route；不得简单要求“继续试”。
- Coordinator 默认最多 2 次有意义的恢复。对 native crash/用户可见弹窗/失控进程，一次 hard stop 后最多只允许一个 materially different 的新 DSH Attempt；等价根因再次出现则不再开第 3 个 DSH 变体。
- 仍无效时，spawn 同角色 `<team-configured-fallback-model>` + `medium` reasoning child agent 接管。
- 不使用 high reasoning。
- 顶层 Coordinator 不直接实现该角色任务。
- configured-model 完成的任务必须明确标记 fallback，不能计为 DSH PASS。

### Team / Agent / Task model

- Team 由用户要求创建，只有用户明确要求时才解散。
- 当前目标完成后进入 `AWAITING_USER_ACCEPTANCE`，不自动散队。
- Agent 是长寿成员，按需创建；同一轮允许创建多个。
- 同角色增长策略为 `capacity_aware_parallel_first`；没有“同角色默认 1 个”的硬编码上限。
- 优先复用兼容的 Idle Agent 及其原 Session；只要仍有 Ready Task 能填入兼容 Idle 槽，就不得 spawn 新成员。
- 一个 Agent 同时只执行一个 Active Task。
- Task DAG 动态扩展。
- create/dependency/assign/reassign 仅由 Coordinator 控制。
- 用户 UI 只能查看 Task DAG，不直接干预 assign。
- Task 完成后 Agent 回到 Idle。
- Task 完成、暂时无任务或 Team 等待验收都不得自动退役 Agent。
- 只有用户明确要求，或 Coordinator 明确评估该 Agent 后续已无合理复用可能并记录具体理由时，才可 retire；“完成了当前 Task”不是充分理由。
- Task/Agent 状态变化立即触发简单事件驱动调度。

Capacity-aware parallel-first 调度顺序：

1. Phase 1：用满每个兼容 Idle Agent 的一个 slot，复用其原 Session；
2. Phase 2：所有兼容 Idle 槽已用满，且仍有独立 Ready Task 且 `maxMembers` / role cap 有余量时，spawn 同角色 Agent 并行；
3. Phase 3：cap 用满时保持 READY/WAITING，不把独立 Task 无必要排队到忙 Agent 之后。

`maxMembers` 是 Coordinator 创建 Team 时写入的必填 Team 参数（控制面投影），本 Skill 不引入新的硬编码默认数字。成员上限计所有非 `TERMINATED` 的 Team members——Running + Idle 是常态示例，WAITING/RECOVERING/FALLBACK/FAILED 等暂态或失败态同样计入——不是 active Task 数；用户 role cap 保留。

Phase 2 的进入条件是所有兼容 Idle 槽已用满且仍有独立可验收 Ready Task，并必须同时满足三个安全门：

- Task 独立可验收；
- write scope 不冲突，或使用隔离 workspace；
- 禁止为凑并行度制造伪任务。

并行扩容不得改变已配置的 role/backend model，也不得放松角色独立性或“一个 Agent 最多一个 Active Task”。

### Capability routing

普通非视觉短/中时长任务可优先交给 DSH，包括 PowerShell/Git/文件/日志/短测试/短脚本等。

以下不得交给 DSH：

- 图片/截图/GUI视觉/视觉识别/视觉验收；
- 长时间运行或等待型测试、仿真、build、安装、benchmark、扫描。

DSH 可准备长任务的脚本、命令和测试；真正的长时间执行与等待由 Codex 侧完成。

### DSH polling

- 有新的有效 ACP/Tool/Plan/Reply/process-state 事件时重置静默计时，不额外轮询。
- 普通任务首次静默检查至少 120 秒。
- 后续状态检查间隔不得短于 120 秒。
- 较慢但仍适合 DSH 的步骤可放宽至约 3–5 分钟或更久。
- 明确 error/stderr/process/session failure 时立即诊断；若命中 Stop-and-Return hard-stop 条件，停止当前 DSH Attempt，不继续自发试错。


### DSH Full Access

Team 创建/恢复/replacement 的所有 DSH child 默认必须使用 Full Access execution permission。

- spawn / resume / replacement 不得静默降级。
- Explorer/Reviewer 等只读角色仍使用 Full Access execution capability，但通过角色合同保持 read-only。
- Full Access 不覆盖 Work Package allowlist、角色边界、Task scope 或不可逆操作限制。
- 如果实际 child 未获得 Full Access，标记 `PERMISSION_PROPAGATION_FAILURE`，由 Coordinator 修正 launch/transport；不得把它误记为目标代码失败。
- DSH child 不自行通过 `--no-sandbox`、换 launcher 等方式绕过权限门禁。


### DSH context efficiency

只有 DSH-backed roles 默认采用 bounded-reading：

- Coordinator 先拆小 Task，再提供最小 Context Pack；
- 优先指定相关文件、symbol、接口和测试入口；
- DSH 先 search 定位，再局部读取；
- 大文件优先 symbol/range read；
- 小 Task 不得无理由通读整个项目；
- context 不足时逐级扩大到 one-hop dependency / bounded discovery；
- broad repo investigation 必须有明确理由；
- 长寿 Agent 优先复用已有上下文，只刷新 changed/critical files；
- 如果一个局部需求必须读大量文件，优先重新拆 Task。

### Tester / Reviewer backend split

默认：

- Coder：DSH
- Tester：Codex child，`<team-configured-fallback-model>` + `medium`
- Reviewer：DSH

Tester 负责正式测试/回归和长时间等待/监控，不修改 production code。

Reviewer 默认只 review Coder 本轮 candidate diff、changed files、direct tests 和必要 one-hop 关联文件；不默认全文覆盖整个 repo。只有明确跨模块 evidence 时才扩展。

Reviewer 也是长寿成员，默认先复用兼容的 Idle Reviewer。当有多个互相独立的 change 等待审查、现有 Reviewer 槽已全部占用且 role cap 仍有余量时，可创建并行同角色 Reviewer；独立性边界不变（不接收 Coder 私有 transcript、使用独立只读/disposable workspace、独立 verdict）。


Codex Tester / Coordinator / vision / long-wait 不受上述 DSH context 限制；它们根据任务需要决定读取范围。
