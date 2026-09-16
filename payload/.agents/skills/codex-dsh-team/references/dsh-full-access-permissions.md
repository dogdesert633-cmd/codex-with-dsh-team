# DSH Full Access Permission Contract

## 目的

Codex × DSH Team 中的 DSH child agent 默认不是受限 sandbox worker。

> 所有由 Team 创建、恢复、replacement 的 DSH child，都必须以 Team 规定的 **Full Access execution permission** 启动并保持该权限。

这里必须严格区分：

```text
Execution permission
    = DSH Harness / OS 层面的可执行能力

Role / Work Package scope
    = 这个 Agent 被允许做什么
```

Full Access 解决“Agent 技术上能否执行命令、访问允许的文件、启动所需进程”等问题；
它 **不等于** Agent 可以忽略角色合同、write allowlist、Task 范围或安全边界。

---

## 1. Full Access 是 Team DSH child 的默认权限

以下所有 DSH child 类型都使用 Full Access execution permission：

- Code Explorer / Debugger
- Coder / Repair Worker
- Tester / Test Engineer
- Code Reviewer
- Progress Recorder / Reporter
- 非视觉 Operator / shell worker
- replacement DSH child
- resume / follow-up 的原 DSH child

不得因为：

- role 不同；
- spawn / resume 不同；
- replacement；
- 新 Turn / Run；
- Tester / Reviewer 身份；

而静默降级为受限 sandbox。

---

## 2. 生命周期中的权限继承

### spawn

```text
Codex spawn DSH child
 -> new agent_id
 -> new DSH session
 -> Full Access execution permission
```

### follow-up / resume

```text
same agent_id
 -> resume same DSH session
 -> Full Access 必须保持
```

### replacement

```text
old DSH child failed
 -> Coordinator creates replacement DSH child
 -> replacement 仍必须 Full Access
```

如果 replacement 使用了受限权限，不算合法 replacement。

---

## 3. Full Access ≠ 无限制授权

即使技术权限为 Full Access，DSH 仍必须遵守：

- Work Package allowed write paths；
- role read/write contract；
- Task objective；
- Team routing policy；
- 不读取/输出 credentials；
- 不执行未授权不可逆操作；
- 不杀死无法证明属于当前 Attempt 的用户进程；
- 不访问 Task 未授权资源；
- Reviewer 仍保持 read-only；
- Explorer 默认仍是 read-only；
- Tester 不修改 production code，除非独立合同明确允许。

也就是说：

```text
Full Access
  != unrestricted behavior
```

权限层负责“能执行”，合同层负责“允许执行什么”。

---

## 4. 不允许静默降级

Coordinator / adapter 必须能够确认 DSH child 的有效权限模式。

如果 Team 要求 Full Access，但实际 child 运行在受限 sandbox：

```text
PERMISSION_PROPAGATION_FAILURE
```

这属于 **Team launch / transport configuration bug**，不是目标代码失败。

不得：

- 静默继续；
- 把 permission denial 当作 Coder/Tester 实现失败；
- 让 DSH child 在受限 sandbox 内不断换命令尝试；
- 把“偶尔能执行某条命令”当作 Full Access 已验证。

---

## 5. 验证要求

在首次使用新的 Team/transport 配置，或权限相关实现发生变化后，应使用最小、非破坏性 smoke 验证 Full Access propagation。

验证应由 Coordinator 设计，避免破坏用户环境，例如：

1. 确认 effective permission mode；
2. 在 Work Package 明确允许的临时位置创建并删除一个临时文件；
3. 执行一个普通 PowerShell/CMD 命令；
4. 读取当前 workspace 中允许读取的文件；
5. 正常退出。

不要为了“验证 Full Access”：

- 修改无关系统设置；
- 写入系统目录；
- kill 无关进程；
- 输出 secrets；
- 执行不可逆操作。

验证通过后，不要每个 Task 重复做完整 permission smoke。

---

## 6. Permission failure 的处理

如果出现明确的 permission/sandbox denial，而 Team contract 已要求 Full Access：

DSH child 应返回：

```text
STATUS: DSH_STOPPED
STOP_CODE: DSH_STOPPED_PERMISSION_PROPAGATION
FAILURE_CLASS: permission_propagation
```

并附：

- 当前可观察到的 effective permission mode；
- 原始 denial/error evidence；
- 失败命令/操作；
- agent_id / session_id / task_id / attempt_id；
- 不包含 secret 的环境证据。

Coordinator 收到后：

1. 不把它当作目标实现 bug；
2. 不要求原 DSH child 通过参数 fishing 绕过；
3. 检查 Team/transport launch permission propagation；
4. 修正后创建 materially valid retry/replacement；
5. 若执行后端无法提供用户已要求的 Full Access，则报告 `BLOCKED_INFRASTRUCTURE` 或按既有 fallback policy 处理。

---

## 7. 与 Stop-and-Return 的关系

过去的规则：

> “需要 `danger-full-access` 才能继续 -> 让 DSH 自己申请/等待授权”

在本 Team 中不再适用，因为用户已经把 **Full Access 设为 DSH child 的默认 Team permission policy**。

新的规则是：

```text
Team requires Full Access
 + child is not Full Access
 -> permission propagation bug
 -> Stop-and-Return
 -> Coordinator 修正 launch/transport
```

DSH child 自己仍然不得尝试绕过 permission gate 或修改安全策略。

---

## 8. Monitor / adapter 实现责任

本文件是策略契约，不代表当前 Monitor 已经实现权限传播。

实际 adapter / Monitor 后续必须做到：

- spawn 时显式使用 Full Access；
- resume 时保持同一 Full Access session；
- replacement 仍 Full Access；
- 将 effective permission mode 写入 machine evidence；
- 如果无法满足，明确失败而不是降级。

具体 CLI flag / API 字段必须以当前 DSH Harness 的真实接口为准，禁止在 Skill 中凭空发明参数名。
