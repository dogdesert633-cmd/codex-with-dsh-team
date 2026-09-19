# Codex × DSH Team Toolkit

> This branch adds a **v1.3.1 PyQt6 desktop console** for local Monitor discovery, DSH settings,
> synchronization and one team per project. Installation and startup are separate; previous releases remain available through Git tags.
> See the [desktop guide](desktop/README.md).

**English** | [简体中文](README.zh-CN.md)

Want Codex to run a project with a small team around it? This toolkit splits exploration,
implementation and review into explicit roles: Codex coordinates and performs the final acceptance,
and — when you want it — DeepSeek Harness (DSH) takes a share of the implementation and the checking
with an external model you choose yourself.

The three Skills are independent and combinable: the universal team rules work on their own, and you
add the DSH boundary and call-path Skills when you want an external model to take part. The provider,
model and credentials are the ones already configured in your own DSH.

## What you get

Three independent Skills, installed into your project:

| Skill | What it is for |
| --- | --- |
| `codex-team` | The team rules: how to split a task into roles, hand work out, review it independently, send it back for repair, and record what happened. Works on its own — no DSH, no Node. |
| `dsh-role-boundaries` | What DSH may and may not be asked to do, so you never hand it work it cannot see or judge. |
| `mcp-to-dsh` | The call path to DSH, plus a local monitor where you can watch a task's progress, turns and evidence. |

They do not load or depend on each other. Read the one a task needs; nothing runs behind your back.

## Two ways to use it

**1. Just the team rules — no DSH needed.** Reading `codex-team` on its own, Codex works to those
rules by itself: it plans, splits the work into roles, reviews the result, and reports back in a
consistent shape. Useful even if you never install Node. The complete package already installs all
three Skills, so you just read the ones a task needs — there is nothing to install separately.

**2. Share the work with DSH.** When you want another model to take part, ask Codex to read all
three Skills. `dsh-role-boundaries` tells it what DSH can be trusted with, `mcp-to-dsh` connects to
your DSH and opens the monitor, and `codex-team` keeps the coordination and the final acceptance
with Codex.

You can send these prompts to Codex as they are:

```text
Read .agents/skills/codex-team/SKILL.md and run this as a small team. Keep the final decision with
you: <your task>
```

```text
Read .agents/skills/codex-team/SKILL.md, .agents/skills/dsh-role-boundaries/SKILL.md and
.agents/skills/mcp-to-dsh/SKILL.md. Use DSH for the exploration, implementation and review, and
report the evidence back to me: <your task>
```

## Install (Windows desktop edition)

1. Open the [v1.3.1 release page](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.3.1) and download `codex-dsh-desktop-v1.3.1-windows-x64.zip` under **Assets**.
2. **Extract the complete archive** into a convenient tools folder and open `CodexDshDesktop.exe`. Keep its `_internal` and `toolkit` folders alongside it. Python is not required.
3. Open “配置与模型” (Settings and models) and click “自动查找 DSH 配置” (Find DSH configuration). Confirm the detected default provider and model. Choose among multiple results, or browse manually if nothing is found.
4. Click “添加项目” (Add project) and choose your project folder. An empty folder works; Git initialization is not required.
5. Review the automatic project check and click “安装工具包与依赖” (Install toolkit and dependencies). Project files install offline; missing DSH dependencies are downloaded through npm. After installation, click “启动 Monitor” (Start Monitor). Existing projects are offered a toolkit update. Each project has one team; no manual conversation association is needed.
6. Open the same project folder in Codex and use the DSH team prompt above.

The `Source code (zip)` and `Source code (tar.gz)` assets contain source files, not the desktop EXE.
The desktop app can live outside your project. See the [desktop guide](desktop/README.md) for details.

Before deleting or moving a project, click **“停止后台” (Stop background)** and wait for file handles to be released.
Closing a Codex conversation or browser tab does not stop the background service. When closing the desktop app, you can choose “停止后台并退出” (Stop background and exit).

### Install project files only (optional)

The package installs everything in one pass. Please do not copy Skill folders by hand unless you
deliberately want only the rules-only part.

1. **Download** the same [v1.3.1 complete desktop archive](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/download/v1.3.1/codex-dsh-desktop-v1.3.1-windows-x64.zip).
2. **Extract the whole archive.** The installer needs the complete folder, not just the EXE.
3. **Open the extracted `toolkit` folder and run `CodexDshTeamToolkit.Install.exe`.** If you prefer a script, run `Install.cmd` from that folder instead.
4. **Click Browse and choose an existing project folder.** The picker initially opens at the installer's directory; an empty project is fine.
5. **Click Check Installation, then Start Installation.** The window shows progress, logs and an explicit success message, with a button to open your project. Nothing is written to the project before confirmation.

Afterwards the project contains:

- `.agents/skills/codex-team`, `.agents/skills/dsh-role-boundaries` and
  `.agents/skills/mcp-to-dsh`;
- `start_dsh_team.cmd` and `sync_dsh_team_config.cmd` in the project root, plus the uninstaller
  `CodexDshTeamToolkit.Uninstall.exe`.

The uninstaller matches the installer's light interface, with progress, logs and completion feedback. Dependencies installed by this version are tracked and removed when unchanged; edited, additional and legacy unrecorded files are preserved and explained. Closing the completed window also cleans up the uninstaller and its remaining ownership records.

Your project's `AGENTS.md` is not modified. To remove it later, run the uninstaller from the project
root: it removes the files it can confirm were installed by the toolkit, and keeps the files you
modified or added yourself.

## First run

Before the first DSH-backed task you need:

- Windows 10 or 11;
- **Node ≥ 22.19.0**; Git is optional, with no repository initialization or initial commit required;
- a DSH installation that already works, with your provider, model and credentials configured.

The desktop app has separate installation and startup buttons. Install missing dependencies first, then click “启动 Monitor” (Start Monitor); no manual commands are needed.
If you use only the project installer, run the following instead (replace the path with your own project):

```powershell
# once, inside the installed skill directory
Set-Location 'D:\projects\my-project\.agents\skills\mcp-to-dsh'
npm ci

# back at the project root, where you start work from now on
Set-Location '..\..\..'
.\start_dsh_team.cmd
```

The launcher uses the toolkit's pinned DSH dependency and **your own settings**. If it cannot
find your configuration, a folder picker asks for the DSH configuration directory containing
`settings.yaml`. Choose the folder once; there is no path or command to type. The location is
remembered, settings are synced at startup and checked before dispatch, and new tasks follow your
latest `agent-default-model`. Developer provider settings and credentials are never packaged.
See [docs/CONFIGURATION.md](docs/CONFIGURATION.md) and
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## Things worth knowing

- **Your task context leaves the machine.** The prompts, instructions and file content needed for a
  task are sent to the provider you configured, under your own account and its terms, and that may
  cost money. See [docs/SECURITY.md](docs/SECURITY.md) for exactly what is and is not sent.
- **DSH can run commands and read or write files.** Runs default to Full Access and tool requests
  are approved automatically — that is what lets it do real work, and it is not an OS-level sandbox.
  Review the changes afterwards, using a Git diff when available; details in
  [docs/SECURITY.md](docs/SECURITY.md).
- **Run output is not ignored for you.** A run writes `artifacts/dsh-monitor/`,
  `artifacts/dsh-gui-runs/` and `.dsh/contracts/` in the project. The installer never edits your
  `.gitignore`; add those paths yourself before running DSH if you do not want them tracked.
- **Early version.** v1.3.1 is a pre-release offered for evaluation — feedback and issue reports are
  welcome. Real model calls and some permission scenarios still need more
  validation; see [docs/INSTALLATION.md](docs/INSTALLATION.md) and
  [docs/SECURITY.md](docs/SECURITY.md).

## Documentation

| Document | Contents |
| --- | --- |
| [docs/INSTALLATION.md](docs/INSTALLATION.md) | Install, uninstall and prerequisites in detail |
| [docs/CONFIGURATION.md](docs/CONFIGURATION.md) | Runtime configuration, entry points, exit codes |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Error messages and what to do about them |
| [docs/SECURITY.md](docs/SECURITY.md) | Data flow, path policy, confidentiality boundaries |
| [CHANGELOG.md](CHANGELOG.md) | Version-by-version technical history |

## Acknowledgements

This project referenced [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams)
during development, a DeepSeek Harness plugin for agent teams. Thanks to its author and contributors
for sharing their design and implementation publicly.

## License

The original toolkit is MIT — see [LICENSE](LICENSE). The desktop console is GPL-3.0 — see [desktop/LICENSE](desktop/LICENSE).
