# 桌面控制台开发

此分支在独立 worktree 中维护 PyQt6 桌面控制台。
根据用户要求，使用 Codex 单代理开发，不委派 DSH 或其他代理。

保留旧 worktree 和历史版本。根据用户后续要求，此版同时修复 payload 的启动入口：
自动选择受管运行目录、同一项目复用一支团队；同步更新相关 Skill 说明。
安装器和 Monitor 协议保持现有结构，桌面通过 desktop/ 中的适配器调用入口。
桌面功能代码、测试、打包脚本位于 desktop/。旧版本基线为 825ff0d。

## Runtime environment

Preferred environment: `RL_env_app`

Interpreter:

`G:\data_save\conda_data\envs\RL_env_app\python.exe`

使用全局环境注册表和共享环境安全规则。已确认 PyQt6、PyInstaller、PyYAML 可用。
不安装或升级共享环境依赖。使用 unittest 和 Qt 自带测试设施。

验证使用临时项目、假凭据与本地测试服务；不修改或停止用户正在使用的 Monitor。
不执行 hash、checksum 或 digest 校验。
