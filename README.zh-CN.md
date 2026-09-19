# Codex × DSH Team Toolkit（中文说明）

> 本分支新增 **v1.2.1 PyQt6 桌面控制台**：检测本机 Monitor、选择 DSH 配置、同步设置、关联对话。
> 双击 EXE 即可使用，详见[桌面版说明](desktop/README.md)。原有 v1.1.0 工具包实现保留。

[English](README.md) | **简体中文**

想让 Codex 带着一个小团队，把项目一步步做完？这个工具包把探索、实现和审查分成明确的角色：
Codex 负责协调与最终验收，需要时再接入 DeepSeek Harness（DSH），用你自己选择的外部模型分担代码
实现与检查。

三个 Skill 相互独立、可按需组合：只用通用团队规则也能工作；想要外部模型参与时，再加上 DSH 的边界
说明与调用路径。provider、model 与凭据都用你现有 DSH 里配置好的那一套。

## 你会得到什么

三个相互独立的 Skill，安装进你的项目：

| Skill | 用途 |
| --- | --- |
| `codex-team` | 团队规则：怎么把任务拆成角色、派活、独立审查、返修，以及把过程记录成证据。单独就能用，不需要 DSH 或 Node。 |
| `dsh-role-boundaries` | 明确 DSH 能做什么、不能做什么，避免把它看不见或判断不了的工作交过去。 |
| `mcp-to-dsh` | 连接 DSH 的调用路径，以及一个本地 Monitor，用来看任务的进度、轮次与证据。 |

三者互不加载、互不依赖：按任务需要读取其中一到三个，不会在背后自动启动别的 Skill。

## 两种用法

**一、只用团队规则（不需要 DSH）。** 只读取 `codex-team` 时，Codex 就按这套规则自己推进：先规划，
再按角色拆分，独立复查结果，最后用统一格式汇报。不装 Node 也能用。完整安装包默认已经把三个 Skill
都装好了，按需要读取即可，不必再单独安装某一个。

**二、把活分给 DSH。** 想让另一个模型参与时，让 Codex 同时读取三个 Skill：`dsh-role-boundaries`
告诉它 DSH 可以被信任到什么程度，`mcp-to-dsh` 连上你的 DSH 并打开 Monitor，`codex-team` 让协调
与最终验收仍然留在 Codex 这一侧。

下面两段提示可以直接发给 Codex：

```text
请读取 .agents/skills/codex-team/SKILL.md，把它当成一个小团队来推进，最终决定权留给你：<你的任务>
```

```text
请读取 .agents/skills/codex-team/SKILL.md、.agents/skills/dsh-role-boundaries/SKILL.md 和
.agents/skills/mcp-to-dsh/SKILL.md，用 DSH 分担探索、实现与审查，并把证据回报给我：<你的任务>
```

## 安装（Windows 完整安装包）

安装包一次装齐所有内容。除非你确实只想要纯规则部分，否则不建议手工复制 Skill 目录。

1. **下载** `codex-dsh-team-toolkit-v1.1.0.zip`：
   [直接下载](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/download/v1.1.0/codex-dsh-team-toolkit-v1.1.0.zip)；
   全部资产与说明见 [v1.1.0 Release 页](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.1.0)。
2. **完整解压**：安装器需要整棵目录，不是只要一个 EXE。
3. **运行解压目录里的 `CodexDshTeamToolkit.Install.exe`**；偏好脚本的话运行 `Install.cmd`。
4. **点击“浏览”，选择已有的项目目录。** 浏览器首次从安装程序所在目录打开，空白项目也可以。
5. **点击“检查安装”，检查通过后点击“开始安装”。** 窗口显示进度与日志，完成后会明确显示“安装完成”，并可打开项目文件夹。在你确认之前不会写入项目。

安装完成后，项目里会有：

- `.agents/skills/codex-team`、`.agents/skills/dsh-role-boundaries`、`.agents/skills/mcp-to-dsh`；
- 项目根目录的 `start_dsh_team.cmd`、`sync_dsh_team_config.cmd`，以及卸载器
  `CodexDshTeamToolkit.Uninstall.exe`。

项目自己的 `AGENTS.md` 不会被修改。以后想移除时，在项目根目录运行卸载器：它会移除可确认由工具包安装
的文件；你自己修改或新增的文件会保留。

## 首次运行

第一次把任务交给 DSH 之前，你需要：

- Windows 10 或 11；
- **Node ≥ 22.19.0**；Git 可选，普通文件夹不需要初始化仓库或创建提交；
- 一份已经能正常工作的 DSH，并且已配置好 provider、model 与凭据。

然后（路径请替换成你自己的项目）：

```powershell
# 只需一次：在已安装的 skill 目录里安装依赖
Set-Location 'D:\projects\my-project\.agents\skills\mcp-to-dsh'
npm ci

# 回到项目根目录，之后每次开始工作都在这里运行
Set-Location '..\..\..'
.\start_dsh_team.cmd
```

启动器使用工具包依赖中的 DSH，读取**你自己的配置**。找不到配置时，会弹出文件夹选择窗口：
选择包含 `settings.yaml` 的 DSH 配置目录即可，不需要选择文件或输入命令。程序会记住位置；
启动时同步，派发任务前检查变化，默认跟随你最新的 `agent-default-model`。
安装包不携带开发者的供应商设置或凭据。详细说明见 [docs/CONFIGURATION.md](docs/CONFIGURATION.md) 与
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 需要知道的几件事

- **任务内容会离开本机。** 完成任务所需的提示、指令与文件内容会发送给你配置的 provider，使用你
  自己的账号并受其条款约束，可能产生费用。具体发送与不发送什么，见 [docs/SECURITY.md](docs/SECURITY.md)。
- **DSH 可以执行命令并读写文件。** 运行权限默认为 Full Access，工具请求默认自动通过——这是为了让
  它能真正干活，不是操作系统级沙箱。请复查任务产生的改动，有 Git 时可查看 diff；细节见
  [docs/SECURITY.md](docs/SECURITY.md)。
- **运行产物不会自动被忽略。** 一次运行会在项目里写入 `artifacts/dsh-monitor/`、
  `artifacts/dsh-gui-runs/` 与 `.dsh/contracts/`。安装器不会修改你的 `.gitignore`；不想让它们进入
  版本管理，请在运行前自行把这些路径加进去。
- **早期版本。** v1.1.0 是预发布版本，欢迎试用并反馈问题。真实的模型调用，以及部分
  权限场景还需要更多验证，详见[安装说明](docs/INSTALLATION.md)与[安全说明](docs/SECURITY.md)。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/INSTALLATION.md](docs/INSTALLATION.md) | 安装、卸载与前置条件的详细说明 |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | 运行时配置、入口与退出码 |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | 常见报错与处理办法 |
| [docs/SECURITY.md](docs/SECURITY.md) | 数据流向、路径策略与保密边界 |
| [CHANGELOG.md](CHANGELOG.md) | 逐版本的技术变更历史 |

## 致谢

本项目在开发过程中参考了 [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams)，
这是 DeepSeek Harness 的 agent teams 插件。感谢该项目作者及贡献者公开分享其设计与实现。

## 许可证

MIT，见 [LICENSE](LICENSE)。
