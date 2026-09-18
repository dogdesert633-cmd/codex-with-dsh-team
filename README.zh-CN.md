# Codex × DSH Team Toolkit（中文说明）

[English](README.md) | **简体中文**

一个 GitHub-ready、仅面向 Windows、完全离线的安装器，用于把 **Codex × DSH 团队 Skill**
（`codex-dsh-team` 与 `mcp-to-dsh`）安全地安装进一个已存在的项目。它只管理自己安装过的
文件，为每个受管文件保留一份 pristine 原始字节副本作为归属证据，并且能够把这些文件
干净地撤销。

> 状态：v1.0.0 源码工程。`payload/` 存放受管 Skill 文件；本仓库还包含安装引擎、
> 薄卸载器、Release 工具、文档与测试。

---

## 为什么需要它

把文件复制进项目很容易；**安全地**复制进项目，意味着此后任何时候都能回答三个问题：

| 问题 | 本工具包 |
| --- | --- |
| 这个文件是我们的，还是用户自己写的？ | ownership ledger，并为每个受管文件保留 `pristine/` 原始字节副本 |
| 安装中途失败会怎样？ | 事务：durable journal + backup + 原子替换 + 逆序回滚 |
| 能卸载吗？ | 事务式卸载，只删除能证明归属的文件 |

---

## 快速开始

1. 下载 / 解压 Release 包（或按 [Fork 工作流](#fork-工作流)自行构建）。
2. **安装**：双击包根目录的 `CodexDshTeamToolkit.Install.exe`（常规 GUI 入口），或使用零依赖的
   `Install.cmd`。在弹出的 Windows 文件夹选择器里选择项目根目录；在看到逐文件 Install Plan
   之前不会写入任何内容。
3. **卸载**：双击项目内的 `CodexDshTeamToolkit.Uninstall.exe`，查看 Uninstall Plan 后确认。

命令行方式（CI 或高级用户）：

```powershell
# 仅显示计划，可证明零写入
.\CodexDshTeamToolkit.Install.exe --target "D:\projects\my-project" --plan-only
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly

# 安装 / 升级（无人值守）
.\CodexDshTeamToolkit.Install.exe --target "D:\projects\my-project" --yes

# 无人值守卸载
& "D:\projects\my-project\CodexDshTeamToolkit.Uninstall.exe" --target "D:\projects\my-project" --yes
```

### 入口

| 入口 | 作用 |
| --- | --- |
| `CodexDshTeamToolkit.Install.exe`（包根目录） | 常规入口：双击进入文件夹选择器，或无人值守驱动。参数：`--target <project>`（或位置参数）、`--package <dir>`（默认取 EXE 自身所在目录）、`--yes`、`--no-ui`、`--plan-only`、`--help`。它是薄薄的 framework-dependent 外壳：定位 package 与项目、显示共享引擎产出的计划、请求确认，然后调用该引擎并透传其退出码；自身不含任何 ownership、事务或路径逻辑。 |
| `Install.cmd`（包根目录） | 零依赖的 CLI/CI 入口与高级路径：把引擎参数直接透传，优先 `pwsh.exe`、回落到系统自带 Windows PowerShell。无法或不想运行 EXE 时使用它。 |
| `install/Invoke-Toolkit.ps1` | 两个启动器背后的唯一引擎。需要引擎级开关（`-Action`、`-TestMode`、`-TestFault` 等）时直接调用。 |
| `CodexDshTeamToolkit.Uninstall.exe`（安装后位于项目根） | 卸载路径的薄启动器，支持 `--plan-only` / `--yes` / `--no-ui`。 |

两个包根启动器**不会**被安装进你的项目、**不会**进入 ownership ledger、绝不提权，也不引入任何
网络使用或持久系统状态。它们是 framework-dependent 的，运行于 Windows 10/11 自带的 .NET
Framework 4.x。退出码稳定且已文档化（见
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#exit-codes)）：`0` 成功，`8` 需要显式确认，其他非零值
均为 fail-closed 并报告回滚状态。

---

## 安全保证

**manifest-owned（清单托管）**：只管理 release manifest 明确列出的文件。遇到同名但未知的
文件会整体阻断，绝不覆盖。

**先证明再修改**：升级只替换“与 pristine 原始字节副本逐字节一致”的旧受管文件（原始副本保存在
项目的 `.codex-dsh-team-toolkit/pristine/` 下）。你手工改过的受管文件会让升级整体阻断，且文件
被保留。

**事务化**：Plan → 完整 Preflight → 独占锁 → durable journal + backup → 同目录临时文件 +
原子替换 → 校验 → manifest 原子提交。任一步失败都会逆序回滚，并且回滚结果本身会被校验。

**fail-closed**：manifest 缺失/损坏/身份不符/路径异常，symlink、junction、reparse point、
`..`、绝对/UNC/设备路径、盘根、大小写折叠重复、文件/目录类型冲突，全部以**零写入**停止。

**卸载尊重你的工作**：只删除仍与其 pristine 原始字节副本逐字节一致的受管文件；被用户修改的
文件、用户新增文件、`node_modules`、其他 Skill 与未知内容一律保留并报告。目录仅在确认空时
逐级删除。

**证据里没有 secret**：plan、journal、backup、log 不保存文件内容或凭据值；路径中形似
secret 的片段在打印或落盘前会被脱敏。详见 [docs/SECURITY.md](docs/SECURITY.md)。

---

## 运行前置与边界

- 已安装的 Team/Monitor runtime 需要 **Node ≥ 22.19.0**（payload 的 `engines.node` 已声明）；
  安装器本身只需要 PowerShell。
- DSH runtime 依赖固定并仅针对 **`@deepseek-ai/dsh 0.1.5-rc.1`** 验证（见 payload 的
  `package.json`）。不声明兼容其他 DSH 版本：其他版本属"未测试"而非"禁止"，请固定你验证过的版本。
- 首次运行 Team 前，在 `<project>\.agents\skills\mcp-to-dsh` 内执行一次 `npm ci`。
- 安装与卸载都会先展示计划并要求确认。自动化请显式传 `-Yes`；非交互且未确认时以退出码 `8`
  退出且零写入。
- Team Home marker 是 `.codex-dsh-team-home.json`（`codex-dsh-team-home/v1`），与 Node runtime
  完全一致，安装器创建与 runtime 创建的 Team Home 可互相识别；任何其他 marker 文件（包括
  `.codex-dsh-team-runtime.json`）都会让该目录被拒绝接管，而不是被采用。
- 归属证明采用**直接字节比较**：目标文件与项目状态目录下的 `pristine/<path>` 副本逐字节比对；
  不计算、不保存、不信任任何 checksum/hash/digest，且“一致”只表示内容相同，不代表由谁产生。
  团队归属仍以 Git 证据模型为准。
- Release **传输**完整性（下载、镜像、传输中的归档）归分发渠道负责：toolkit 不生成也不消费任何
  checksum 清单或旁挂文件，也不声称能够检测 package 是否被篡改。

### 什么会离开本机，什么留在本地

这是两条不同的路径，不是同一个承诺：

| 路径 | 网络行为 |
| --- | --- |
| 安装、升级、卸载 | 完全离线。无 toolkit telemetry、无回传、无包还原、不提权。 |
| 维护者构建 / Verify / 测试 | 完全离线。不 push、不发布。 |
| 首次在 payload skill 内执行 `npm ci` | 会访问 npm registry 一次，以落地固定版本的依赖树。 |
| 真正运行 Team/Monitor AI 任务 | 你的 prompt、仓库上下文与任务文本会发送到**你在 DSH 中配置的 model provider**。该流量受你的 provider 账号与条款约束，且**可能产生第三方费用**。这是你的配置行为，不是 toolkit telemetry。 |

状态与证据留在本地：ownership ledger、`pristine/` 基线、事务 journal/backup 与 Team Home 都位于
你的项目与 toolkit 自有 runtime 目录内。plan、journal、log 只记录路径与结果，绝不记录文件内容或
凭据值（见 [docs/SECURITY.md](docs/SECURITY.md)）。

## 仓库结构

```
CodexDshTeamToolkit.Install.exe  包根 GUI/CLI 安装启动器（构建产物，非源码）
Install.cmd                     零依赖 CLI/CI 入口（STA 文件夹选择器）
install/Invoke-Toolkit.ps1      唯一核心引擎（安装 / 升级 / 卸载）
payload/                        受管 Skill 文件
installer/src/Installer.cs      薄 C# 5 安装外壳
installer/Build-Installer.ps1   用系统自带 csc.exe 构建安装 EXE
uninstaller/src/Uninstaller.cs  薄 C# 5 WinForms 外壳
uninstaller/Build-Uninstaller.ps1  用系统自带 csc.exe 构建 EXE
release/                        release manifest schema 与打包布局
tools/Build-Release.ps1         离线 Release 构建
tools/Verify-Release.ps1        离线 Release 校验
docs/                           安装、配置、安全、排错
tests/                          安全 / 事务 / 安装卸载测试
dist/                           构建产物（已被 .gitignore 忽略）
```

---

## 仓库材料 vs Release 包

`release/package-layout.json` 是"什么会被分发"的权威来源。当前：

- **仅仓库内**（不进包）：`tools/`、`tests/`、`dist/`。这些是维护者材料，需要源码 checkout 才能运行。
- **随包分发**：`Install.cmd`、`CodexDshTeamToolkit.Install.exe`、引擎
  （`install/Invoke-Toolkit.ps1`）、构建好的 `uninstaller/CodexDshTeamToolkit.Uninstall.exe`、
  两份 README、`CHANGELOG.md`、`LICENSE`、四份 `docs/`，以及 `release/` 的 schema 与布局文件。
- **为可审计性而分发**：两个薄启动器的构建脚本与源码（`installer/Build-Installer.ps1` +
  `installer/src/Installer.cs`，以及 `uninstaller/Build-Uninstaller.ps1` +
  `uninstaller/src/Uninstaller.cs`）是有意包含的，读者可以据此核对每个 EXE 的确切行为并用系统自带
  编译器重建；它们不是安装/卸载的必需品。

---

## Fork 工作流

Fork 所需的全部工作都在源码树内完成，产物是一个 package：

1. **改源码树。** 运行时 Skill 文件在 `payload/`；安装引擎是 `install/Invoke-Toolkit.ps1`；
   两个薄启动器是 `installer/src/Installer.cs` 与 `uninstaller/src/Uninstaller.cs`。受管安装集在
   `release/payload-inventory.json` 中声明 —— 新增 payload 文件时既要落盘也要登记，否则构建会把它
   报为 undeclared 并排除。
2. **在源码 checkout 内运行维护者工具。** 下面的完整工作流需要源码 checkout：`tools/`、`tests/`
   与 `dist/` 属仓库材料，不是包内容。两个启动器的构建脚本与源码是例外——它们随包分发，因此也可以
   直接从解压出的 Release 包中审计并重建 EXE：

   ```powershell
   pwsh -File installer/Build-Installer.ps1                      # 重建安装 EXE（系统自带 csc.exe）
   pwsh -File uninstaller/Build-Uninstaller.ps1                  # 重建薄 EXE（系统自带 csc.exe）
   pwsh -File tests/Run-Tests.ps1                                # 安全 / 事务测试套件
   pwsh -File tools/Build-Release.ps1 -Version 1.0.0             # 打包 + zip，离线
   pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.0.0.zip
   ```

   payload 缺失时 `Build-Release.ps1` 会直接失败，除非显式传入 `-AllowMissingPayload`；命中禁止
   路径，或在被打包文本文件中发现未标注的高置信度 secret，构建失败。
3. **查看测试。** `tests/` 覆盖安装、ownership、事务、卸载、路径策略、机密性、迁移位置、
   恢复/TOCTOU、Windows 卫生、Release 工具与薄 EXE；只使用临时目录与假凭据。
4. **发布产物。** 构建永不 push：由你自己把 `dist/codex-dsh-team-toolkit-v<version>/`（及 zip）
   通过你选用的渠道发布。Release 传输完整性由该渠道负责——见上文说明。

---

## 文档

- [docs/INSTALLATION.md](docs/INSTALLATION.md) — 安装、升级、校验、回滚
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — 命令行、退出码、owned runtime
- [docs/SECURITY.md](docs/SECURITY.md) — 威胁模型、deny-by-default、脱敏、Team Home
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — 锁、损坏的 ledger、csc.exe、reparse

## 测试

同样仅限仓库内：测试套件位于本源码工程的 `tests/`，不属于任何 Release 包。

```powershell
pwsh -File tests/Run-Tests.ps1            # 全量，仅使用临时目录
pwsh -File tests/Run-Tests.ps1 -Filter '04-*' -KeepTemp
```

测试只使用临时目录与假凭据，不读取任何真实 DSH 配置、凭据库或 runtime，也不联网。

## 参考与致谢

本项目在开发过程中参考了 [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams)，这是 DeepSeek Harness 的 AgentTeams 插件。感谢该项目作者及贡献者公开分享其设计与实现。

该参考项目使用 MIT 许可证，详见其 [LICENSE](https://github.com/NanmiCoder/dsh-agent-teams/blob/main/LICENSE)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
