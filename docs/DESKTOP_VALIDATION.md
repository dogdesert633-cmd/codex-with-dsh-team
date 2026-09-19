# v1.2.0 桌面版验证记录

验证日期：2026-09-19。执行方式：Codex 单代理；未发起真实 DSH 模型任务。

## 版本保留

- 原工具包基线：`825ff0d`，位于原工作目录和 `codex/installer-ui` 分支。
- 桌面版：独立 worktree，分支 `codex/desktop-console-v1.2.0`。
- 对比基线，`payload/`、`install/`、`installer/`、`uninstaller/` 源码没有修改。
- 桌面版号为 `1.2.0`；内附兼容工具包版本为 `1.1.0`。既有 GitHub 发布标签没有改动。

## 已完成验证

27 项自动测试通过，覆盖：

- 从用户选定目录读取默认模型，供应商顺序不改变选择；源设置保持原内容。
- 保存配置目录、项目去重、对话标记、损坏记录保护、文件写入失败反馈。
- HTTP 身份验证、项目与运行目录一致性、禁止远程地址与重定向、忽略代理。
- 同步前核对配置来源，模型偏好使用 revision 防止覆盖并发修改。
- 旧式 Monitor 提供只读地址概览，禁用配置与停止操作。
- 窗口持续响应、刷新保留未提交的模型选择、中文分段日志、进度和失败反馈。
- 在含中文与方括号的空白非 Git 项目中安装完整工具包，保留原有用户文件。
- Windows PowerShell 5.1 和 PowerShell 7 参数传递：使用所选配置目录，跳过模型调用，不打开额外浏览器。
- 使用临时 Node 服务验证进程发现、连接复用、精确停止；错误 PID 拒绝停止。
- Windows 当前用户 DPAPI 加解密验证，使用假 token。

另完成本机只读检查：发现两个运行中的 Monitor。旧版连接展示概览；新版连接成功读取任务与 DSH 会话。未修改或停止这些真实服务。

## 发行包验证

完整 ZIP：`dist/release-v1.2.0/codex-dsh-desktop-v1.2.0-windows-x64.zip`。

- 解压到新的中文、带空格目录，通过 EXE 的离线界面测试。
- 测试进程 PATH 仅含 Windows 目录，移除 Python、Conda、Qt 环境变量；退出码为 0。
- 工作台与配置页面截图检查通过，截图使用明确标记的示例数据。
- 确认包含 EXE、Qt 运行库、PowerShell 适配器、完整工具包、中文说明、桌面源码与许可证。
- 确认未包含用户 `settings.yaml`、凭据文件、桌面项目记录或 Monitor 访问记录。
- EXE 的文件版本、产品版本和窗口显示均为 `1.2.0`。
- 构建显式包含 Conda 的 ffi 依赖，并限制 DLL 搜索位置，避免混入其他软件的 ICU 库。

## 验证边界与复现

此次验证覆盖桌面适配器、现有服务读取和安装流程。真实供应商连通性、账号额度以及完整模型任务仍由用户的 DSH 配置决定；没有为验证界面消耗模型额度。

在项目声明的 Python 环境中执行：

```powershell
$env:DESKTOP_TEST_TOOLKIT_PACKAGE = '完整工具包目录'
python -m unittest discover -s desktop/tests -v
python desktop/build.py --toolkit-package '完整工具包目录' --output '新的输出目录'
.\CodexDshDesktop.exe --smoke-test '新的测试输出目录'
```

不设置 `DESKTOP_TEST_TOOLKIT_PACKAGE` 时，只跳过完整安装包测试。
