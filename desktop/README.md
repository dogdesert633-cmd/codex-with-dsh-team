# Codex × DSH 桌面控制台

把项目、模型和团队进度放在一个窗口里。Codex 负责协调和验收，DSH 使用你配置的外部模型完成适合它的任务；桌面负责安装与连接，网页 Monitor 展示详细过程。

**v1.3.2 · author: desertdog**

[项目首页](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/blob/main/README.zh-CN.md) · [下载与发布说明](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.3.2)

## 安装前准备

- Windows 10/11、Node.js ≥ 22.19.0。
- 已配置好模型和凭据的 DSH。工具包使用你自己的配置，不附带账号或 API Key。
- 一个已有或空白项目文件夹，无需先初始化 Git。

**每个项目会独立安装一份 DSH 及运行依赖，约 200 MB。** 当前依赖文件内容约 214 MiB，安装记录、npm 缓存和任务数据另占空间。它不会覆盖你原本的 DSH；多个项目分别安装依赖。

桌面 EXE 不需要另装 Python 或 PyQt6。项目工具包文件可以离线安装；DSH 依赖通过 npm 准备，优先复用缓存，缺少时需要联网。下载 ZIP 不是完整离线依赖包。

## 第一次使用

1. 完整解压下载的 ZIP，双击 `CodexDshDesktop.exe`。保留旁边的 `_internal` 和 `toolkit` 文件夹；桌面程序可以放在项目之外。
2. 打开“配置与模型”，点击 **自动查找 DSH 配置**。确认默认供应商和模型；多份配置时选择一份，未找到时再手动选择包含 `settings.yaml` 的目录。
3. 点击 **添加项目**，选择准备工作的文件夹。控制台会自动检查工具包、依赖和 Node。
4. 点击 **安装工具包与依赖**，等待完成提示，再点击 **启动 Monitor**。
5. 在 Codex 中打开同一个项目，发送：

```text
请读取 .agents/skills/codex-team/SKILL.md、
.agents/skills/dsh-role-boundaries/SKILL.md 和
.agents/skills/mcp-to-dsh/SKILL.md。
由你协调和验收，让 DSH 分担适合的工作。
我的任务：<填写你要完成的项目或功能>
```

一个项目对应一支团队，团队内可以有多个角色与会话。无需填写 Codex 对话 ID；桌面自动显示 Monitor 地址、任务状态和 DSH 会话。点击“打开网页”查看详细进度。

## 模型与配置

配置自动查找会检查已保存的位置、DSH 环境变量和约定的用户目录，不扫描整块硬盘。原始配置保持只读，运行时使用工具包自己的受管副本。

默认跟随你在 DSH 中选择的模型。连接 Monitor 后，可以在“配置与模型”选择后续任务的模型，或恢复“跟随 DSH 默认”。正在执行的任务不会中途换模型；未连接时只能预览模型列表。

修改原始 DSH 设置后，可在桌面点击“同步配置”。如果项目绑定了另一份配置，先停止该项目后台，再按正确的配置重新启动。

## 结束工作

点击 **停止后台**，等待日志提示文件占用已释放。关闭网页或结束 Codex 对话不会停止后台服务。

退出桌面时，若仍有后台运行，可以选择“停止后台并退出”或保留后台。停止会中断尚未完成的任务；删除或移动项目之前应先停止。

## 卸载与更新

- **只移除 DSH 依赖：** 先停止后台，再点击“卸载依赖”。
- **移除整个工具包：** 先停止后台，再运行项目根目录的 `CodexDshTeamToolkit.Uninstall.exe`。检查清单后确认，窗口会显示进度、日志和完成提示。
- **更新已有项目：** 解压新桌面包并运行，选中项目、停止后台，点击“更新工具包”。遇到被修改的文件会提示冲突，不会强制覆盖。

卸载清理已登记且内容未修改的文件，保留用户修改、新增文件及任务记录，并说明保留原因。点击“完成”后，卸载器自身和不再需要的安装记录会自动清理。旧版或手动安装、没有原始内容记录的依赖会保留。

## 数据与帮助

DSH 调用你配置的模型服务，可能产生该服务的费用，也会向它发送完成任务所需的内容。DSH 可以执行命令并读写项目文件，请复查任务产生的改动。

桌面项目列表和配置来源位置保存在 `%LOCALAPPDATA%\\CodexDshTeam\\`；指定 `CODEX_DSH_TEAM_BASE_DIR` 时使用对应目录。桌面记录不保存 API Key 或聊天正文，窗口日志会对凭据字段脱敏。

[常见问题](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/blob/main/docs/TROUBLESHOOTING.md) · [安全说明](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/blob/main/docs/SECURITY.md) · [反馈问题](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/issues)

当前为预发布版本。桌面代码采用 GPL-3.0，原工具包采用 MIT；发行包随附桌面源码及第三方许可证。开发与构建入口为 `desktop/main.py`、`desktop/build.py`，依赖见 `desktop/requirements.txt`。

感谢 [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams) 提供的设计参考与启发。
