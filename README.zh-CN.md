# Codex × DSH Team Toolkit（中文说明）

一个 GitHub-ready、仅面向 Windows、完全离线的安装器，用于把 **Codex × DSH 团队 Skill**
（`codex-dsh-team` 与 `mcp-to-dsh`）安全地安装进一个已存在的项目。它只管理自己安装过的
文件，为每个受管文件保留一份 pristine 原始字节副本作为归属证据，并且能够把这些文件
干净地撤销。

> 状态：v1.0.0 源码工程。`payload/` 存放受管 Skill 文件；本仓库还包含安装引擎、
> 薄卸载器、Release 工具、文档与测试。

---

## 为什么需要它

早期内部包附带的 v3.2.0 旧安装器（不属于本仓库）只会
复制文件，无法回答三个关键问题：

| 问题 | 旧安装器 | 本工具包 |
| --- | --- | --- |
| 这个文件是我们的，还是用户自己写的？ | 不知道 | ownership ledger，并为每个受管文件保留 `pristine/` 原始字节副本 |
| 安装中途失败会怎样？ | 项目处于半安装状态 | 事务：durable journal + backup + 原子替换 + 逆序回滚 |
| 能卸载吗？ | 不能 | 事务式卸载，只删除能证明归属的文件 |

---

## 快速开始

1. 下载 / 解压 Release 包（或按下方说明自行构建）。
2. **安装**：双击 `Install.cmd`，在弹出的 Windows 文件夹选择器里选择项目根目录。
   在看到逐文件 Install Plan 之前不会写入任何内容。
3. **卸载**：双击项目内的 `CodexDshTeamToolkit.Uninstall.exe`，查看 Uninstall Plan 后确认。

命令行方式（CI 或高级用户）：

```powershell
# 仅显示计划，可证明零写入
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly

# 安装 / 升级
.\Install.cmd -Target "D:\projects\my-project"

# 无人值守卸载
& "D:\projects\my-project\CodexDshTeamToolkit.Uninstall.exe" --target "D:\projects\my-project" --yes
```

`Install.cmd` 绝不提权、绝不联网，也不会修改 `PATH`、注册表、全局 PowerShell 配置、
Git 配置、你已有的 `AGENTS.md` 或任何源码文件。

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
- 首次运行 Team 前，在 `<project>\.agents\skills\mcp-to-dsh` 内执行一次 `npm ci`：这是**唯一**
  需要联网的步骤。安装、升级、卸载、测试、Release 构建与校验全部离线。
- 安装与卸载都会先展示计划并要求确认。自动化请显式传 `-Yes`；非交互且未确认时以退出码 `8`
  退出且零写入。
- Team Home marker 契约（`.codex-dsh-team-home.json` / `codex-dsh-team-home/v1`）与 Node
  runtime 完全一致，安装器创建与 runtime 创建的 Team Home 可互相识别；旧的
  `.codex-dsh-team-runtime.json` 一律拒绝，不做迁移。
- 归属证明采用**直接字节比较**：目标文件与项目状态目录下的 `pristine/<path>` 副本逐字节比对；
  不计算、不保存、不信任任何 checksum/hash/digest，且“一致”只表示内容相同，不代表由谁产生。
  团队归属仍以 Git 证据模型为准。
- Release **传输**完整性（下载、镜像、传输中的归档）归分发渠道负责：toolkit 不生成也不消费任何
  checksum 清单或旁挂文件，也不声称能够检测 package 是否被篡改。

## 仓库结构

```
Install.cmd                     双击入口（STA 文件夹选择器）
install/Invoke-Toolkit.ps1      唯一核心引擎（安装 / 升级 / 卸载）
payload/                        受管 Skill 文件
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

## 离线构建 Release

以下命令是**仅限源码 checkout 的维护者工具**。`tools/`、`tests/`、`uninstaller/src/` 与
`payload/` 源码都属于仓库产物：Release 包只包含构建好的安装引擎、薄 EXE、文档与 release
目录，不包含开发树。

```powershell
# 1. 薄卸载 EXE（依赖 Windows 自带 .NET Framework 的 csc.exe）
pwsh -File uninstaller/Build-Uninstaller.ps1

# 2. 打包 + zip（不联网、不 push、不产生任何 checksum 产物）
pwsh -File tools/Build-Release.ps1 -Version 1.0.0

# 3. 校验产物
pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.0.0.zip
```

payload 缺失时 `Build-Release.ps1` 会直接失败，除非显式传入 `-AllowMissingPayload`；
命中禁止路径，或在 payload 文本文件中发现未标注的高置信度 secret，构建失败。

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

## 许可证

MIT，见 [LICENSE](LICENSE)。
