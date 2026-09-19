# Installation

> **v1.3.3.** Download the **complete desktop ZIP** — `codex-dsh-desktop-v1.3.3-windows-x64.zip` — from
> [releases/tag/v1.3.3](https://github.com/dogdesert633-cmd/codex-with-dsh-team/releases/tag/v1.3.3),
> extract it completely and open `CodexDshDesktop.exe`. Add a project, install the toolkit and
> dependencies using the installation button, then start Monitor. For the file-only installer,
> open the bundled `toolkit` directory; the instructions below describe that separate option.
> No administrator rights are needed. The desktop installation button prepares Node dependencies;
> the separate file-only installer does not.
> Take the ZIP asset attached to the release, **not** the automatically generated "Source code"
> archive: the installer needs the whole package tree, not just the sources.
> A source checkout contains no compiled `.exe`; to produce the package from sources see
> [Building a release yourself](#building-a-release-yourself).

## Prerequisites

**Each project gets its own DSH installation and runtime dependencies, approximately 200 MB.**
They live in `.agents/skills/mcp-to-dsh/node_modules/`. The current dependency file contents
measure about 214 MiB; installation records, npm caches and task data use additional space.
Different projects install their own copies. Your existing DSH installation and source settings
remain unchanged. Initial dependency preparation may need internet access; the desktop ZIP does
not include the full offline dependency tree.

| Requirement | Notes |
| --- | --- |
| Windows 10 / 11 | Windows only. No Linux/macOS support. |
| PowerShell 5.1 **or** PowerShell 7+ | `Install.cmd` prefers `pwsh.exe` and falls back to the in-box Windows PowerShell. |
| An existing project directory | The toolkit never creates the target root. |
| .NET Framework 4.x | Ships with Windows 10/11. Needed to **build** the two thin launchers, and it is the framework the shipped launchers run on (they are framework-dependent). Not needed for the PowerShell engine itself. |
| Node **≥ 22.19.0** | Only needed for the installed Team/Monitor runtime (the payload skills), not for the installer itself. `payload/.agents/skills/mcp-to-dsh/package.json` declares this in `engines.node`. |

The installer engine needs no administrator rights, no network access and no package restore.

## Install from the complete package (recommended)

One run installs all three Skills into an existing project:

1. **Download the release ZIP.** Use the `codex-dsh-desktop-v1.3.3-windows-x64.zip` asset attached to the
   [v1.3.3 release](https://github.com/dogdesert633-cmd/codex-with-dsh-team/releases/tag/v1.3.3)
   (or a `dist/` zip built by a maintainer).
2. **Extract it completely and open the bundled `toolkit` directory.** The installer needs the whole package tree, not just the EXE.
3. **Run `CodexDshTeamToolkit.Install.exe`** in the package root — the normal GUI entry — or
   `Install.cmd` if you prefer the zero-dependency script.
4. **Click Browse and pick your existing project root.** The picker starts from the EXE directory.
   Cancelling the picker keeps the installer open and leaves the selection unchanged.
5. **Click Check Installation, review the plan, then click Start Installation.** Nothing is written before that point: no state
   directory, lock, runtime directory or other write happens earlier. Unattended runs pass `--yes` /
   `-Yes`; a non-interactive run without it exits `8` and writes nothing.

The window shows live phase progress and a scrollable log. Successful installation ends with
an explicit success message and an Open Project button. Errors stay visible in the window.

What lands in the project, in one pass:

| Installed path | What it is |
| --- | --- |
| `.agents/skills/codex-team/` | the universal multi-role template Skill |
| `.agents/skills/dsh-role-boundaries/` | the DSH role/capability boundary Skill |
| `.agents/skills/mcp-to-dsh/` | the DSH call path and Monitor Skill |
| `start_dsh_team.cmd`, `sync_dsh_team_config.cmd` | launcher entry points at the project root |
| `CodexDshTeamToolkit.Uninstall.exe` | the thin uninstaller |
| `.codex-dsh-team-toolkit/` | the engine, ownership ledger and pristine baselines |

All of it is declared by the package inventory and tracked in the ownership ledger, so you do not
copy anything by hand and a later uninstall is clean. The installer does **not** edit the project's
`AGENTS.md`, does not change `PATH`, does not add a registry key or a global PowerShell profile, and
does not install dependencies.

## What gets installed

Only the files listed in the package's `release-manifest.json`:

| Installed path | Purpose |
| --- | --- |
| `.codex-dsh-team-toolkit/engine/Invoke-Toolkit.ps1` | the engine, so the project can repair/uninstall itself |
| `CodexDshTeamToolkit.Uninstall.exe` | the thin, double-click uninstaller |
| the payload paths (for example `.agents/skills/codex-team/...`, `.agents/skills/dsh-role-boundaries/...`, `.agents/skills/mcp-to-dsh/...`, `start_dsh_team.cmd`, ...) | the skills themselves |

Plus one ledger: `.codex-dsh-team-toolkit/manifest.json` (not a managed file — it *is* the
record of the managed files).

The package-root launchers (`CodexDshTeamToolkit.Install.exe`, `Install.cmd`) are deliberately
**not** in that table: they live only in the extracted package, are never copied into your
project and are never recorded in the ledger.

## First start: the ACP profile is prepared at runtime

The installer only copies files. Before the first Team/Monitor run, three things must be ready on
the machine:

1. **Node ≥ 22.19.0.** Git is optional. An ordinary or empty project directory works; the toolkit
   does not require or create a repository or an initial commit.
2. **Your own working DSH setup.** A user DSH Home containing `settings.yaml` and
   `.credentials.yaml`, i.e. the provider, model and credentials you already use interactively.
   The Team runtime is synced *from* that Home, which stays read-only, and the toolkit never
   configures a provider or writes credentials for you. `npm ci` alone is not enough to run a
   model: the DSH child agents use the provider and model configured in your DSH Home.
   If automatic detection cannot find that Home, double-clicking the launcher opens a folder
   picker labelled **Choose the DSH configuration folder containing settings.yaml**. Select the
   folder, not the file. The validated location is remembered in current-user local state.
   No whole-disk search is performed. Future starts sync from that location; dispatch checks for
   changes and blocks on sync failure instead of silently using an old default.
3. **The payload dependencies, once.** Replace the example path `D:\projects\my-project` with the
   project root you picked in the installer — the quotes keep paths with spaces working — then
   install the pinned tree, go back to the project root and start the launcher:

   ```powershell
   Set-Location 'D:\projects\my-project\.agents\skills\mcp-to-dsh'
   npm ci                                 # first install: uses package-lock.json for a reproducible tree
   Set-Location '..\..\..'                # back to the project root ('D:\projects\my-project')
   .\start_dsh_team.cmd
   ```

   Later runs only need the last line, run from the project root.

The first launch prepares the ACP profile **by itself** inside the owned Team Home (kept outside
the project and outside Git), then starts or reuses this project's Monitor and prints its URL. You
do not hand-write a profile `package.json`, no second dependency tree is created inside the profile
directory, and with no profile present the default `acp` is prepared. An existing profile
directory, its `package.json` and the plugins inside it are never replaced, moved or deleted.

- Advanced profile selection, configuration and the exact resolution rules:
  [docs/CONFIGURATION.md](CONFIGURATION.md) — see
  [ACP profile](CONFIGURATION.md#acp-profile-runtime-inside-the-owned-team-home).
- If the first start fails: [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md), in particular
  [First start and ACP profile problems](TROUBLESHOOTING.md#first-start-and-acp-profile-problems).

Runtime notes:

- The installer copies the payload; it never installs Node dependencies for you.
- The DSH runtime dependency is pinned and tested against **`@deepseek-ai/dsh 0.1.5-rc.1`**
  (declared in the payload's `package.json`). Other DSH versions are untested rather than
  unsupported: pin the version you validated. Node ≥ 22.19.0 is required (see `engines.node`); an
  older Node fails visibly instead of running with an unsupported runtime.
- `npm ci` contacts the npm registry once to materialise the pinned tree. The installer engine, the
  maintainer tools and the tests are offline.
- `node_modules/**` is never part of a release package, is never installed by the installer and is
  retained when installed manually or by an older version without ownership records. Dependencies prepared through the v1.3.3 desktop are recorded with original-byte baselines in one compressed archive and are removed on uninstall if unchanged. User edits and additional files are preserved.
- Later runs reuse the running Monitor for this project instead of starting a second one;
  `sync_dsh_team_config.cmd` re-syncs provider/model/credentials from your DSH Home on demand. The
  install and the runtime share one Team Home marker (`.codex-dsh-team-home.json`,
  `codex-dsh-team-home/v1`), and a directory carrying any other marker is refused rather than
  adopted — see [docs/CONFIGURATION.md](CONFIGURATION.md).

## What leaves the machine during real AI work

Copying/removing toolkit files and uninstalling dependencies are offline. Preparing runtime dependencies may contact npm when the required packages are not cached. When you actually run Team/Monitor AI tasks, your
prompt, repository context and task text are sent to the **model provider configured in your DSH
setup** — that traffic follows your provider account and terms and **may incur third-party cost**.
That is your configuration, not toolkit telemetry: the toolkit itself sends nothing.

What the toolkit records locally is **not** all content-free: plans, journals and logs are
path/status metadata (secrets in messages are redacted), while `pristine/` baselines and the
transaction `backup/` and `quarantine/` copies hold **real byte copies of managed files**, and the
owned Team Home may hold a credential copy. See
[docs/SECURITY.md](SECURITY.md) for the exact split.

## Runtime output is not ignored for you

The installed skill's own `.gitignore` applies **only inside that skill directory**. A DSH run can
still write to the project root:

- `artifacts/dsh-monitor/` — Monitor run evidence
- `artifacts/dsh-gui-runs/` — GUI dispatch records
- `.dsh/contracts/` — dispatch contract text

If you do not want those tracked, add these exact directories to your project's `.gitignore` or to
its local `.git/info/exclude` **before** running DSH. The installer never edits your project root
`.gitignore`, and it will not blanket-ignore your own `artifacts/`. Ignore rules do not affect files
that are already tracked, so run `git status` first and clean up manually if needed.

## Using only a rules-only skill

The payload ships **three independent skills**: the universal multi-role template, the DSH role
boundaries, and the DSH transport (see the README). The two rules-only skills need no installer,
no DSH, no npm and no Monitor — copy the directory you want:

```text
<payload>/.agents/skills/codex-team            ->   <your-project>/.agents/skills/codex-team
<payload>/.agents/skills/dsh-role-boundaries   ->   <your-project>/.agents/skills/dsh-role-boundaries
```

- the universal template needs **native sub-agent capability** on the host; with only a single
  executor you get self-check instead of independent review, and that must be reported as such;
- the DSH transport is different: copying its directory does **not** remove its own runtime
  dependencies (Node, the DSH runtime, its configuration and the local Monitor) — those still apply;
- a hand copy is **not** tracked by the installer's ownership ledger, and if you later switch to the
  full package installer, a file that already exists at the same path and is *not* in the ledger is
  **refused, never overwritten** — move or remove your hand copy first.

Installing the **full toolkit** always goes through the package installer, which installs all three
skills from the manifest.

## Install from the command line (optional)

```powershell
# always start here: a plan with zero writes
.\CodexDshTeamToolkit.Install.exe --target "D:\projects\my-project" --plan-only
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly

# install
.\CodexDshTeamToolkit.Install.exe --target "D:\projects\my-project" --yes
.\Install.cmd -Target "D:\projects\my-project"
```

The installer EXE takes `--target <project>` (or a positional path), `--package <dir>` (default:
its own directory), `--yes`, `--no-ui`, `--plan-only` and `--help`. It is a thin shell over the
same engine and forwards the engine's exit code unchanged.

Equivalent direct engine call:

```powershell
pwsh -NoProfile -STA -File .\install\Invoke-Toolkit.ps1 -Action Install -Target "D:\projects\my-project"
```

In a non-interactive session (`CI`, redirected stdin, `-NonInteractive`) the engine never
prompts: it exits with code `2` and tells you to pass `-Target` explicitly.

## Verify an install

```powershell
$ledger = Get-Content .\.codex-dsh-team-toolkit\manifest.json -Raw | ConvertFrom-Json
$ledger.version
$ledger.files | Select-Object path, pristine, state
```

Every entry in `files` is a normalized relative path plus the `pristine` baseline path of the
exact installed bytes and its `state`. The ledger contains no checksum, hash or digest field:
ownership is decided by comparing a managed file byte for byte with its pristine copy.

## Roll back / repair

Nothing special is required: run `Install.cmd -PlanOnly` first. A blocked plan tells you
exactly which file is unknown or modified, and a full run only ever replaces ownership-proven
files. If an install fails mid-way the engine rolls back automatically and reports
`Rollback complete`; a failed rollback keeps its transaction directory as evidence and exits
with code `7`.

## Uninstall

```powershell
# double-click inside the project, or:
& "D:\projects\my-project\CodexDshTeamToolkit.Uninstall.exe" --target "D:\projects\my-project" --yes
# or
.\install\Invoke-Toolkit.ps1 -Action Uninstall -Target "D:\projects\my-project" -Yes
```

The uninstaller opens a light window with a read-only plan, progress, scrollable logs and completion feedback. It deletes only ownership-proven, unchanged files, including dependencies prepared by this desktop version. Click Finish to close the window and clean up the executable and its final ownership records. Original project directories are preserved. Task records and user-created project content remain user data. See
[docs/SECURITY.md](SECURITY.md) for exactly what is kept.

`--plan-only` (EXE) and `-PlanOnly` (engine) show the plan and write nothing.

## Known limitations

- The installer GUI has local checks for planning, installation, progress, success feedback and
  conflict handling. Real provider runs, desktop/DPI variations and some ACL / credential /
  partial-permission edge cases still need broader testing.
- First start prepares the ACP profile automatically and the installer pre-places none; see
  [First start](#first-start-the-acp-profile-is-prepared-at-runtime) for what must be ready first.

## Building a release yourself

Most of these commands are **maintainer tools that need a source checkout**: `tools/`, `tests/`
and `dist/` are repository artifacts and are not shipped inside a release package, so those
commands do not exist in an extracted release. The launcher build recipes are the exception —
`installer/Build-Installer.ps1` and `uninstaller/Build-Uninstaller.ps1`, together with their
sources, ship with the package (see
[release/package-layout.json](../release/package-layout.json)) so a reader can audit and rebuild
the EXEs from an extracted package.

```powershell
pwsh -File installer/Build-Installer.ps1                     # installer EXE (needs in-box csc.exe)
pwsh -File uninstaller/Build-Uninstaller.ps1                 # thin EXE (needs in-box csc.exe)
pwsh -File tools/Build-Release.ps1 -Version 1.3.3            # dist/ package + zip (no checksum artefact)
pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.3.3.zip
```

The build is offline and never pushes anywhere. Useful properties:

- `release/payload-inventory.json` is the **single, current inventory source** (`files` = runtime only), so a stray file in
  `payload/` can never be installed by accident (it is reported and excluded). A payload-side
  `COPY_FILE_LIST.json` **does not exist** in this toolkit: it is never packaged,
  never installed and never consulted as an inventory;
- everything is produced in a private staging directory and moved into place only when the
  package is complete: a failed build leaves the previous `dist/` artifacts untouched and
  removes only its own staging directory;
- the whole package (not just the payload) is scanned for secrets and fixed-environment
  bindings. If a reviewed fixture legitimately contains a key-shaped value, allowlist that file
  explicitly — the use is printed in the build output and recorded in `dist/build-report.json`:

  ```powershell
  pwsh -File tools/Build-Release.ps1 -Version 1.3.3 `
    -ContentScanAllowlist '.agents/skills/mcp-to-dsh/test/redaction.test.mjs'
  ```

- it fails visibly when the payload, the inventory or the built EXE is missing instead of
  producing an incomplete package.

## Interrupted installs

If a run is killed (crash, power loss, task manager), the next run recovers automatically: the
durable journal is replayed under the exclusive lock *before* any new ownership decision,
staged temporary files and created directories are cleaned up, and the previous file contents
are restored. You only need to act when the engine reports exit `7`: it kept the transaction
evidence and refused to guess — see [docs/TROUBLESHOOTING.md](TROUBLESHOOTING.md).
