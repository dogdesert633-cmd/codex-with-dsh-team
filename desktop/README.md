# Codex × DSH 桌面控制台 v1.2.1

把项目、模型设置和正在运行的团队放在一个窗口里。
桌面负责连接和设置，网页 Monitor 继续展示详细任务、日志与事件。

## 开始使用

1. 完整解压桌面发行包，双击 `CodexDshDesktop.exe`。不需要安装 Python 或 PyQt6；请保留同目录的 `_internal` 和 `toolkit` 文件夹。
2. 打开“配置与模型”，点击“检测本机 DSH”或“浏览目录”，选择包含 `settings.yaml` 的 DSH 配置文件夹。
3. 点击“添加项目”，选择已有或空白项目文件夹。
4. 点击“启动 Monitor”。如果项目尚未准备好，界面会提示安装随附工具包及依赖。
5. 回到 Codex 使用项目的 DSH Skill。控制台自动刷新状态，可随时打开对应的网页 Monitor。

第一次运行项目仍需要 Node ≥ 22.19.0，以及用户自己已经配置好的 DSH 账号、模型和凭据。
首次准备依赖需要联网；启动 Monitor 本身不发起模型任务。

## 结束工作与删除项目

结束 Codex 对话或关闭网页窗口后，Monitor 的后台服务仍会运行。
准备删除或移动项目时，在桌面选中项目，点击“停止后台”，等日志显示“文件占用已释放”再操作。

关闭桌面控制台时，若已添加的项目仍有后台运行，可以选择“停止后台并退出”或“保留后台”。
停止操作会结束相应 Monitor 及其子进程，未完成任务会被中断。

即使 `server.json` 已被删除或网页没有响应，控制台也能按项目定位残留后台。
只有核对进程已经退出、日志文件不再被占用后，才会报告停止成功。

## 配置与同步

- 自动检测只查看已经保存的位置、`DSH_USER_HOME` / `DSH_HOME` 和用户目录中的 `.dsh`。
- 手动选择的是目录，不需要选择 `settings.yaml` 文件，也不需要输入命令。
- 源配置只读。点击“同步配置”调用所选 Monitor 的同步接口，不复制其他用户的配置。
- 如果 Monitor 绑定另一份配置，控制台会拒绝同步。先确认任务已完成，再停止该 Monitor 并重新启动。
- 桌面可为所选 Monitor 设置后续任务的模型偏好，或恢复“跟随 DSH 默认”。正在运行的任务不会因此换模型。

## Monitor 与对话

“检测 Monitor”检查运行中的本机 Node Monitor 进程及其项目记录，不扫描硬盘、不遍历端口范围。
连接前核对项目、运行目录和 Windows 当前用户加密凭证；只连接 `127.0.0.1`，不通过代理发送凭证。

- DSH 会话 ID、任务状态、模型来自 Monitor 的公开接口。
- Codex 对话名称可点击“关联对话”设置。未知归属显示“尚未关联”，不会猜测或读取 Codex 聊天正文。
- 由 Codex 启动桌面时，可以同时传入项目与对话标记，免去手动关联：

```powershell
.\CodexDshDesktop.exe --project "D:\projects\my-project" --conversation-label "贪吃蛇开发" --conversation-id "对话ID"
```

`--project` 已提供时，也会使用调用进程明确提供的 `CODEX_THREAD_ID`。
已有旧 Monitor 没有保存 Codex 对话 ID，不能自动恢复这项信息。
使用旧式明文凭据记录的 Monitor 仅显示项目与地址概览；用新版启动器启动后才能读取会话和修改配置。

“停止后台”按项目核对本机进程身份，不依赖网页连接或访问记录。旧版 Monitor 同样可以在桌面停止。

## 本地数据

桌面项目列表与对话标签保存在 `%LOCALAPPDATA%\CodexDshTeam\desktop\state.json`。
DSH 配置位置保存在同一根目录的 `user-settings-source.json`。
配置了 `CODEX_DSH_TEAM_BASE_DIR` 时，使用对应的根目录。桌面记录不保存 API Key、访问 token 或聊天正文。
日志只在窗口中显示，并做凭据字段脱敏。

## 版本与源码

桌面版使用独立的 `codex/desktop-console-v1.2.0` 分支与工作目录，基线为 `825ff0d`。
原有工具包目录和发布标签保持不变。此版本附加 PyQt6 界面，随附兼容工具包 v1.1.0；
其安装器、DSH 路由与网页 Monitor 源码沿用基线。

开发依赖见 `requirements.txt`。使用项目声明的 Python 环境：

```powershell
python desktop/main.py
python -m unittest discover -s desktop/tests -v
python desktop/build.py --toolkit-package "完整工具包目录" --output "新的构建输出目录"
```

发行包附带桌面源码及第三方许可证。桌面代码采用 GPL-3.0，原工具包的 MIT 许可证保留。
PyQt6 使用其 GPL 发行版；Qt、PyInstaller、PyYAML 的许可证见随附 `licenses/`。

本项目仍感谢 [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams) 提供的参考与启发。
