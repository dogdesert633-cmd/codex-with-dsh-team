# DSH 有界恢复与 Stop-and-Return

阈值是**硬性预算**，不是建议值。目的：既不因一次抖动就放弃，也不允许无限试错。

## 1. 本地重试预算（DSH 单个 Attempt 内）

- **瞬时、无副作用**的工具错误：最多**本地重试 1 次**。
  例：一次短命令超时、一次连接 reset、一次短暂文件占用且重试不扩大副作用。
- **同一或等价的 infrastructure error 第 2 次出现**：必须停止当前 DSH Attempt
  （`DSH_STOPPED`），不得继续本地重试。
- 不得进入"不断换参数试"的探索循环。

## 2. 立即 Stop-and-Return（不消耗上面的预算）

出现以下任一项，**立即停止并带部分证据返回**：

- native process crash / unexpected fatal exit；
- 用户可见错误弹窗、失控进程；
- 需要权限升级；
- session/transport hard failure；
- **visual 或 long-wait 误派**（发现任务实际需要视觉能力或长等待）；
- 同一 failure episode 内等价基础设施错误第 2 次出现。

## 3. 不要把失败混为一类

- 代码/测试**红**是**工作内容**：Coder 继续修，Tester/Reviewer 返回发现；
  **不得**把它包装成 infrastructure failure 来触发回退。
- 基础设施/传输失败才走本文件的恢复预算。
- 两类失败在报告中必须分开陈述。

## 4. Coordinator 层恢复预算

- 同一个 failure episode：Coordinator 有意义的恢复尝试默认**最多 2 次**。
- 带 native hard stop（native crash / 可见弹窗 / 失控进程）的 failure path：
  一次 hard stop 后，**仅当执行架构有实质不同**时才允许再开 **1 个** DSH Attempt；
  若等价根因再次出现，**不得**创建第 3 个变体。
- 仅重复发送完全相同的 prompt **不算**一次有效恢复策略。

## 5. Fallback 与证据

- 模型/后端 fallback 只能来自**调用方已配置的设置**；fallback 不改变同角色的权限与独立性。
- **fallback 完成的任务不得记为 DSH PASS。**
- 证据必须真实：未测的候选只能说"未验证"，不得假称 PASS；也不得用恢复成功掩盖未验证。
