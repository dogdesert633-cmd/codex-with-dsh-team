# 模型锁定、最小充分验证与 No-Hash

## 1. 模型锁定

角色复制、并行扩容、节省额度或失败恢复都不授权更换模型。

- DSH-backed role 使用已配置的 DSH provider/model；Coordinator 不为单个 Task 修改 DSH 模型设置。
- Codex-backed role 使用 profile 或项目规则已经指定的 model/reasoning。
- configured-model fallback 继续使用本 Team 已定义的 `<team-configured-fallback-model>` + `medium`，不得临时升级、降级或换模型。
- 配置模型不可用时，按 recovery/fallback 规则处理并报告；不得静默替换。

## 2. 最小充分验证

每类验证事实只保留一个清晰 owner：

- Coder：与实现直接相关的 targeted self-check；
- Reviewer：candidate change 的技术正确性；
- Tester：正式 acceptance / user-flow evidence；
- Coordinator：消费既有证据并执行 Final Gate，不为取得第二份相同结果而重跑。

只有以下情况才重复验证：

- 相关代码或状态在证据产生后发生变化；
- 原证据不完整、互相矛盾或不可复现；
- 当前角色验证的是不同 acceptance surface；
- 已发现的失败表明相邻范围存在具体风险。

默认验证 changed surface、直接回归和必要的代表性路径。full repository / full suite 仅在变更范围或风险确有需要时执行。不得让 DSH 与 Codex 对同一 Task 做一遍相同工作，仅用于“再确认一次”。

## 3. No-Hash 硬规则

本节规则的作用域是 **Team 的验证证据**（团队用来判定某个 Task / 变更是否通过的事实）。
它不是对所有 hash 用途的一刀切禁令。

### 3.1 Team 验证证据：禁止 hash

本 Team 工作流禁止使用 hash/checksum/digest 作为项目、配置、Skill、交付物或运行证据的
验证手段。

禁止：

- `Get-FileHash`、`sha256sum`、`md5sum`、`certutil -hashfile` 或等价命令；
- `SHA256SUMS*`、`CHECKSUMS*`、`*.sha256`、`*.sha1`、`*.md5`、`*.checksum` 等校验文件；
- 创建或更新以保存/比较摘要为目的的 integrity manifest；
- 调用任何依赖 hash 比较的验证或配置同步路径；
- 仅为了证明文件未变化而计算摘要。

现有第三方或历史校验文件保持原样，不读取、不刷新、不作为 acceptance evidence。若必要操作只能通过 hash-based 路径完成，停止该路径并向用户报告前置条件，不得绕过规则。

### 3.2 产品侧所有权与 Release 完整性的显式例外

以下用途**不属于** 3.1 的禁令范围，并且不得被 Team 拿来当作 Task 验证证据：

- **产品 ownership 归属**：产品可以在自己的实现内部使用 SHA-256 等摘要来标识或校验
  自己生成的安装清单 / Team Home marker 内容，用于证明“这是本产品创建的产物”。
  这不构成 DSH/Agent 归属的证明方式——Agent/Session 归属仍只由 Monitor/Git machine
  evidence 证明。
- **Release 分发完整性**：发布流水线可以用 SHA-256（或发布者选定的摘要）作为 release
  manifest / 包的完整性字段，供下载者校验分发物未被篡改。

边界要求：

- 这类摘要只能由**产品/发布流程**产生与消费，不能进入 Team 的 Coder/Reviewer/Tester
  验证路径，也不能用来替代 Git diff、直接内容比较、deterministic tests 或运行证据。
- 不得因为产品存在 release 摘要，就在 Team 证据里引入 hash 门禁。
- 团队报告如引用 release 摘要，必须注明它来自发布流程，而不是本次 Task 的验证证据。

### 3.3 允许使用的证据

- Git working-tree 状态、diff、numstat 与 changed paths；
- 直接内容比较（逐字节 / 逐行）；
- deterministic tests、exit code、运行日志和实际产品输出；
- Monitor 为本地访问控制生成的随机 token。

Git 正常操作中自然出现的 commit/object ID 不视为主动 hash 验证，但不得把它升级成完整性校验门禁。
