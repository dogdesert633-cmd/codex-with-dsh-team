# Codex × DSH Team Toolkit（中文说明）

[English](README.md) | **简体中文**

Codex 额度总是不够用？把重复的实现与审查工作交给分工清楚的团队。

本工具包提供**三个相互独立的 Skill**：

| Skill | 作用 |
| --- | --- |
| `$codex-team` | 通用多角色模板：角色边界、任务合同、独立审查、失败返回修复、证据与最终验收。与执行后端无关，不需要 DSH、Node 或 Monitor。 |
| `$dsh-role-boundaries` | DSH 能做什么、不能做什么：非视觉代码实现、只读探索、代码审查与文本整理可以；绘图、图像生成/编辑、识图、OCR、截图分析、GUI 视觉判断/验收与长等待不可以。 |
| `$mcp-to-dsh` | DSH 调用路径与 Monitor：把已经决定好的工作包送达真实 DSH session，并回传公开事件与 session/turn/run 证据。它不决定角色分工。 |

```
$codex-team                                   # 只用通用团队
$dsh-role-boundaries $mcp-to-dsh              # DSH 工作；通用模板可选
$codex-team $dsh-role-boundaries $mcp-to-dsh  # 三者同时读取（不是相互加载）
```

**推荐的安装方式是完整 Windows 安装包**：运行一次包根安装器，三个 Skill 会一起写入你选择的项目，
之后也能干净卸载。Codex 始终是协调者与最终验收方；DSH 按需分担普通实现与审查工作，使用**你自己
配置的** provider，因此可能产生费用。

> **状态：v1.1.0 开发预览 / 预发布；源码 checkout 内不含已编译的 `.exe`。** v1.1.0 安装包以
> **Pre-release（预发布）**形式提供，不是稳定版：下载见
> [releases/tag/v1.1.0](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.1.0)，
> 拿到包后的步骤见[快速开始](#快速开始)，尚未完成的项见[已知限制](#已知限制)。

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

**用完整安装包一次装好（推荐）。**

1. **下载安装包**：从 v1.1.0 预发布页下载
   [codex-dsh-team-toolkit-v1.1.0.zip](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.1.0)。
   （维护者也可用 `tools/Build-Release.ps1` 在本地构建，产物在 `dist/`。）
2. **完整解压** —— 安装器需要整棵包目录，不是只要一个 EXE。
3. **运行包根目录的 `CodexDshTeamToolkit.Install.exe`**（常规 GUI 入口），或使用零依赖的
   `Install.cmd`。
4. **在弹出的 Windows 文件夹选择器里选择你已有的项目根目录。**
5. **核对逐文件计划并确认。** 在此之前不会写入任何内容。
6. 三个 Skill 一次整体落地：`<project>/.agents/skills/codex-team`、
   `<project>/.agents/skills/dsh-role-boundaries`、`<project>/.agents/skills/mcp-to-dsh`。
   项目根目录还会写入 `start_dsh_team.cmd`、`sync_dsh_team_config.cmd` 与薄卸载器。这些文件都由
   包 inventory 与项目 ownership ledger 管理——**不需要你手工逐个复制**，安装器也**不会**修改项目的
   `AGENTS.md`。

首次真正运行 DSH 前，请在 `<project>\.agents\skills\mcp-to-dsh` 内执行一次 `npm ci` 安装运行依赖。
之后首次启动会自行准备其余部分：在 toolkit-owned Team Home 内，用**已安装并锁定的 DSH 自带模板**
初始化 DSH **ACP profile**。你**不需要**手写 profile 的 `package.json`，profile 目录也不需要再装
一套依赖——详见下方「ACP profile（DSH 入口配置）」小节。

命令行方式（CI 或高级用户，基于已解压的包）：

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

## ACP profile（DSH 入口配置）

这里的 profile 是**DSH 的启动配置 / 模块声明**（`profiles/<name>/` 下的 `package.json` 声明 DSH
加载哪些 ACP bundle），**不是**你的个人资料、账户、provider 或 model 选择。工具包的默认值是 DSH
内置的 **`acp`**；启动器、Monitor 与 bridge 子进程用的都是同一个值。

| 你的设置 | 含义 |
| --- | --- |
| `-TeamProfile <name>`（启动器 / `start_dsh_team.cmd`） | 指定使用的 ACP profile；环境变量等价物是 `CODEX_DSH_TEAM_PROFILE`。指定的自定义名字即使尚不存在也会被创建。 |
| 不设置 | 若 owned Team Home 内恰好只有一个既有可选 profile，就用它；否则使用内置 `acp` 并自动准备。 |
| `-TeamProfile <新名字>` | 自定义名字会在 owned Team Home 内用已安装 DSH 自带的 ACP 模板创建（`dsh --from-default-profile acp`）。profile 目录及其插件绝不会被替换、搬移或删除；配置同步只会重写**当前选定** profile 的 `cordis.patch.yml`（保留带时间戳的 `.bak`），把该 profile 固定到你配置的 provider/model。 |
| Monitor `--dsh-profile <name>` | 同一个名字：Monitor 记录它，并以 `CODEX_DSH_ACP_PROFILE` 交给 bridge。`/api/health` 的 `dshProfile` 与本地 Monitor record 的 `dsh_profile` 暴露它；复用要求 workspace、Team Home 与 profile **三者一致**。 |

名字的确定顺序：

1. `-TeamProfile <name>`；
2. `CODEX_DSH_TEAM_PROFILE`；
3. owned Team Home 内已有的那一个可选 profile；
4. 都没有时使用默认 `acp` 并自动准备。

- **多个候选必须显式选择。** Team Home 内已有多个可选 profile 时不做任何猜测：请用 `-TeamProfile` /
  `CODEX_DSH_TEAM_PROFILE` 指定。"一个 profile 都没有"不是歧义——会直接用默认 `acp` 并准备它。
- **你的 profile 归你。** 已存在的 profile 一律保留；其中的用户插件不会被工具包搬移、合并或覆盖。
  唯一会写入的是**当前选定** profile 的 `cordis.patch.yml`（同步会保留一份带时间戳的 `.bak`）。
- **内置辅助模板不算入口。** `web`、`headless`、`sdk`、`sdk-minimal` 在查找可选 profile 时被忽略，
  也不能作为 Team 的 ACP 入口；`node_modules` 也被拒绝作为 profile 名。
- **半成品 profile 一律拒绝。** 目标目录已存在但没有有效 profile manifest 时，既不接管也不覆盖：
  请修复它，或换一个名字。
- **全链路同一个名字。** 启动器、Monitor、配置同步与 bridge 子进程收到同一个 profile，因此不会出现
  “按 profile A 规划、DSH 却跑 profile B”。
- **安装器只复制文件，profile 在运行时准备。** profile 只在 owned Team Home 内准备，绝不放在你的
  用户 DSH Home（它始终是只读同步来源）。同步照旧复制 `settings.yaml`、provider/model 选择，以及
  一份当前用户 ACL 的 `.credentials.yaml` 副本；这条边界未变。

## 可选：只手工复制纯规则 Skill

如果你**只**想用那两个纯规则 Skill、不要安装器，可以手工复制目录，而不使用安装包：

```text
<repo>/payload/.agents/skills/codex-team            -> <project>/.agents/skills/codex-team
<repo>/payload/.agents/skills/dsh-role-boundaries   -> <project>/.agents/skills/dsh-role-boundaries
```

这是轻量路径，不是推荐路径：手工副本不受 ownership ledger 管理，而 DSH 运行需要它自己的前置
（Node、DSH runtime、其配置，以及由安装器准备的 owned Team Home）。**真正要调用 DSH 时，请使用完整
安装包并按其既有前置执行**，不要靠手工复制 `mcp-to-dsh` 绕过；手工副本日后也无法由安装器代管卸载。

> 从带有旧混合 `codex-dsh-team` 入口的旧包升级？普通 upgrade 会把它作为 `retained` 保留下来，
> 因此请先用项目内卸载器卸载旧受管文件 —— 见
> [从旧混合团队 Skill 迁移](docs/INSTALLATION.md#migrating-from-the-older-mixed-team-skill)。

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

**本地存了什么、没存什么**：工具包**确实**保留它管理文件的字节副本——`pristine/<path>` 保存
安装时的确切字节（归属比较与卸载依据），事务的 `backup/`、`quarantine/` 保存可回滚/恢复的副本。
plan、journal、log 记录**路径与状态**，不记录文件正文；路径中形似 secret 的片段在打印或落盘前
会被脱敏。这是关于"消息"的脱敏保证，**不等于**"任何位置都没有你内容的副本"。完整说明（含
Monitor 自身的 prompt/event/Git 证据与 owned Team Home 中的凭据副本）见
[docs/SECURITY.md](docs/SECURITY.md)。

**DSH 以真实权限执行**：Monitor 固定使用 `danger-full-access`，ACP bridge 自动应答权限请求
（`ALLOW_ONCE`），因此 DSH 工具运行时**没有交互式审批弹窗**。工作包里的角色 allowlist 是
**指令边界，不是 OS 沙箱**。`dispatch_dsh_gui.ps1 -RejectTools`（等价于 `allowTools:false`）会让
bridge 应答 `REJECT_ONCE`——它是**拒绝工具**，不是新增的审批界面。

**运行产物不会自动被忽略**：工具包**不会**修改你项目根的 `.gitignore`，已安装 Skill 自身的
`.gitignore` 也只作用于该 Skill 目录。运行 DSH 前，如果不想让这些目录被跟踪，请把它们加进项目
`.gitignore` 或 `.git/info/exclude`：`artifacts/dsh-monitor/`、`artifacts/dsh-gui-runs/`、
`.dsh/contracts/`。已被跟踪的文件不受 ignore 规则影响，请先用 `git status` 确认。

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
   pwsh -File tools/Build-Release.ps1 -Version 1.1.0             # 打包 + zip，离线
   pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.1.0.zip
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

## 已知限制

这是开发中的源码工程，不是完成品。未完成项如实列出：

- **owned Team Home 首启会自动准备。** 在已安装的 `mcp-to-dsh` skill 目录执行一次 `npm ci` 后，启动器
  会在 owned Team Home 内用已安装并锁定的 DSH 自带模板初始化 ACP profile。安装器本身仍然只是离线复制
  文件、不预置任何 profile；自定义 `-TeamProfile` 名字也用同样方式创建。
- **测试并非表面那么全绿**：PowerShell 测试入口可能把"缺依赖而 skip"计为通过。请先安装 payload
  依赖，并查看 Node 套件的真实执行结果与 SKIP 统计，再判断测试是否真的跑过。
- **尚未全面验证**：GUI 文件夹选择器、真实 provider 运行，以及部分 ACL / 凭据 / 部分权限场景。

已获得的证据（规则审查、定向 9 PASS / 1 SKIP 片段、隔离包安装与迁移演练）真实但有限，
不足以把本项目称为成熟、正式发布的成品。

## 参考与致谢

本项目在开发过程中参考了 [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams)，这是 DeepSeek Harness 的 AgentTeams 插件。感谢该项目作者及贡献者公开分享其设计与实现。

该参考项目使用 MIT 许可证，详见其 [LICENSE](https://github.com/NanmiCoder/dsh-agent-teams/blob/main/LICENSE)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
