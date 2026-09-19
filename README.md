# Codex × DSH Team

**English** · [简体中文](README.zh-CN.md) · Windows desktop app

## Codex leads. DSH shares the workload.

**Save your Codex allowance for planning, coordination and final review.** Hand suitable coding, debugging and code review tasks to DeepSeek Harness (DSH). External models you choose take on that work, helping reduce Codex usage and keep your project moving.

Codex breaks down tasks, leads the team and checks the results; DSH carries out its assigned work. Choose models that fit your budget, and use the desktop console to connect projects, synchronize settings and follow progress. An independent multi-role team Skill also works without DSH.

**[Download Windows v1.3.3](https://github.com/dogdesert633-cmd/codex-with-dsh-team/releases/download/v1.3.3/codex-dsh-desktop-v1.3.3-windows-x64.zip)** · [Release page](https://github.com/dogdesert633-cmd/codex-with-dsh-team/releases/tag/v1.3.3) · [Installation guide](docs/INSTALLATION.md)

> **Each project gets its own DSH installation and runtime dependencies, approximately 200 MB.** Initial preparation may need internet access. Your existing DSH installation stays intact; dependencies are installed separately for each project. Installation records, npm caches and task data use additional space.

## See your team at work

![Monitor with four agents, three running and one completed task, alongside task instructions and replies](docs/assets/monitor-active.png)

**4 agents · 3 running · 1 completed task.** Select a team member on the left to follow its instructions, replies and elapsed time on the right. Captured from the actual Monitor with demonstration tasks, models and sessions.

## Desktop console: installation, settings and project management

![Desktop console showing project, team and model status, with author credit at the bottom right](docs/assets/desktop-overview.png)

*Actual application interface with demonstration tasks and models. The desktop interface is currently in Simplified Chinese.*

## What you can do

- **Divide work into clear roles.** Codex coordinates exploration, implementation and review, then performs final acceptance.
- **Use external models to conserve Codex allowance.** Delegate suitable coding and review work to DSH; choose your own provider, model and budget.
- **Manage projects in one window.** Check installation status, install dependencies and start or stop Monitor. Each project has one team; no manual conversation linking is needed.
- **Follow the work.** View project and session summaries on the desktop, and detailed tasks, events and logs in the browser Monitor.

External model calls are billed by your provider. Results and costs depend on the task and chosen models.

## Get started

You need Windows 10/11, Node.js ≥ 22.19.0, and DSH configured with working model access and credentials. The desktop app bundles its GUI runtime; Python is not required. Empty project folders work without Git initialization.

1. Download the ZIP above, **extract the entire archive**, and open `CodexDshDesktop.exe`. Keep the adjacent `_internal` and `toolkit` folders.
2. Open **配置与模型** (Settings and models), click **自动查找 DSH 配置** (Find DSH configuration), and confirm the provider and model. Browse manually if needed.
3. **添加项目 → 安装工具包与依赖 → 启动 Monitor** (Add project → Install toolkit and dependencies → Start Monitor). Progress and results appear in the window.
4. Open the same folder in Codex and send this prompt, replacing the final line:

```text
Read these three Skills:
.agents/skills/codex-team/SKILL.md
.agents/skills/dsh-role-boundaries/SKILL.md
.agents/skills/mcp-to-dsh/SKILL.md
Coordinate and validate the work yourself. Delegate suitable exploration,
implementation and review tasks to DSH.
My task: Build a snake game with a score display and a restart button.
```

Download the desktop ZIP asset. GitHub's automatically generated `Source code` archives do not include a runnable EXE.

## Three independent Skills

| Skill | Purpose |
| --- | --- |
| `codex-team` | General rules for task breakdown, role assignment, independent review and repair. Works without DSH. |
| `dsh-role-boundaries` | DSH capability and role boundaries. Image generation, image understanding and visual judgment stay with a suitably capable Codex. |
| `mcp-to-dsh` | DSH invocation and a local Monitor for task progress and session status. |

Choose the Skills your task needs. To use only the team rules, ask Codex to read `codex-team/SKILL.md`; no DSH runtime dependencies are needed.

## Installation and removal

DSH and its dependencies live in the project's `.agents/skills/mcp-to-dsh/node_modules/`. The current dependency tree contains about 25,000 files with approximately 214 MiB of file contents: DSH modules, multiple provider SDKs and their dependencies. This is the scope of the “approximately 200 MB” estimate, not the total installed footprint.

Your existing DSH installation and source configuration remain unchanged. The toolkit synchronizes from your selected configuration into its managed runtime directory. It does not rewrite your project's `AGENTS.md` or system `PATH`.

Click **停止后台** (Stop background) when finished. Closing a browser tab or ending a Codex conversation does not stop the service.

To remove the toolkit, stop the background service and run `CodexDshTeamToolkit.Uninstall.exe` in the project root. It removes tracked, unchanged toolkit and dependency files, preserves edited or additional files and task records, and explains retained items. Legacy or manually installed dependencies without original-content records are preserved. The desktop's **卸载依赖** (Uninstall dependencies) button removes only runtime dependencies.

DSH calls your configured model service and can execute commands and modify project files. Make sure the task content is appropriate for that service. See the [security guide](docs/SECURITY.md).

## Help

[Installation](docs/INSTALLATION.md) · [Desktop guide](https://github.com/dogdesert633-cmd/codex-with-dsh-team/blob/main/desktop/README.md) · [Configuration](docs/CONFIGURATION.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Changelog](CHANGELOG.md)

This is a prerelease. Please report issues through [GitHub Issues](https://github.com/dogdesert633-cmd/codex-with-dsh-team/issues).

## Author and acknowledgements

**author: desertdog**

Development drew on [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams). Thanks to its author and contributors for sharing their DSH agent-team design and implementation.

The original toolkit uses [MIT](LICENSE); the desktop console uses [GPL-3.0](https://github.com/dogdesert633-cmd/codex-with-dsh-team/blob/main/desktop/LICENSE).
