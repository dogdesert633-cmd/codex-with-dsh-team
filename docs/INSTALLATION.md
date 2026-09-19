# Installation

> **Current status: v1.1.0 development preview / pre-release; a source checkout contains no compiled
> `.exe`.** v1.1.0 is published as a **pre-release**, not a stable release: download
> `codex-dsh-team-toolkit-v1.1.0.zip` from
> [releases/tag/v1.1.0](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.1.0),
> then start at [Install from the complete package](#install-from-the-complete-package-recommended).
> Maintainers can also build the package locally with `tools/Build-Release.ps1` (output in `dist/`)
> — see [Building a release yourself](#building-a-release-yourself).

## Install from the complete package (recommended)

One run installs all three Skills into an existing project:

1. **Get the package.** Use a built zip you already have (a maintainer's `dist/` output), or — once
   the GitHub Release is published — the zip attached to that release. It is **not** on GitHub
   Releases yet.
2. **Extract it completely.** The installer needs the whole package tree, not just the EXE.
3. **Run `CodexDshTeamToolkit.Install.exe`** in the package root, or `Install.cmd` for the
   zero-dependency script.
4. **Pick your existing project root** in the folder picker.
5. **Review the per-file plan and confirm.** Nothing is written before that point.

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
`AGENTS.md`.

Before the first real DSH run, install the runtime dependencies once (`npm ci` inside
`<project>\.agents\skills\mcp-to-dsh`). The first launch then prepares the DSH ACP profile itself:
see [First start: the ACP profile is prepared at runtime](#first-start-the-acp-profile-is-prepared-at-runtime).

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Windows 10 / 11 | Windows only. No Linux/macOS support. |
| PowerShell 5.1 **or** PowerShell 7+ | `Install.cmd` prefers `pwsh.exe` and falls back to the in-box Windows PowerShell. |
| An existing project directory | The toolkit never creates the target root. |
| .NET Framework 4.x | Ships with Windows 10/11. Needed to **build** the two thin launchers, and it is the framework the shipped launchers run on (they are framework-dependent). Not needed for the PowerShell engine itself. |
| Node **≥ 22.19.0** | Only needed for the installed Team/Monitor runtime (the payload skills), not for the installer itself. `payload/.agents/skills/mcp-to-dsh/package.json` declares this in `engines.node`. |

The installer engine needs no administrator rights, no network access and no package restore.

## Payload dependencies (Team/Monitor runtime)

The installer copies the payload; it never installs Node dependencies for you. Before the first
run of the Team/Monitor skills, install their dependencies **once** from inside the installed
skill directory:

```powershell
cd <project>\.agents\skills\mcp-to-dsh
npm ci           # first install: uses package-lock.json for a reproducible tree
```

That single `npm ci` is the only dependency step. The **ACP profile is not part of the installer**
and needs no dependencies of its own: after this step the launcher prepares the profile at runtime
inside the owned Team Home (see
[First start](#first-start-the-acp-profile-is-prepared-at-runtime)).

Boundaries to be aware of:

- The installer engine, the maintainer tools and the tests are offline. `npm ci` contacts the
  npm registry once to materialise the pinned dependency tree.
- The DSH runtime dependency is pinned and tested against **`@deepseek-ai/dsh 0.1.5-rc.1`**
  (declared in the payload's `package.json`). Other DSH versions are untested rather than
  unsupported: pin the version you validated.
- Node ≥ 22.19.0 is required (see `engines.node`). An older Node fails visibly instead of
  running with an unsupported runtime.
- `node_modules/**` is never part of a release package, is never installed by the installer and
  is never deleted by the uninstaller (it is untracked content, reported and kept).
- The installer and the runtime share the Team Home marker (`.codex-dsh-team-home.json`,
  `codex-dsh-team-home/v1`), so an install prepared by either side is recognised by the other.
  Any other marker file makes the directory refuse ownership rather than being adopted.

### What leaves the machine during real AI work

Installing, upgrading and uninstalling never use the network. When you actually run Team/Monitor
AI tasks, your prompt, repository context and task text are sent to the **model provider
configured in your DSH setup** — that traffic follows your provider account and terms and **may
incur third-party cost**. That is your configuration, not toolkit telemetry: the toolkit itself
sends nothing.

What the toolkit records locally is **not** all content-free: plans, journals and logs are
path/status metadata (secrets in messages are redacted), while `pristine/` baselines and the
transaction `backup/` and `quarantine/` copies hold **real byte copies of managed files**, and the
owned Team Home may hold a credential copy. See
[docs/SECURITY.md](SECURITY.md) for the exact split.

## Install with the folder picker (step by step)

1. Extract the package anywhere (for example `%USERPROFILE%\Downloads\codex-dsh-team-toolkit-v1.1.0`).
2. Double-click **`CodexDshTeamToolkit.Install.exe`** in the package root (the normal GUI entry),
   or **`Install.cmd`** if you prefer the zero-dependency script.
3. A Windows folder picker opens. Select the **existing** project root you want the toolkit
   installed into, then confirm.
4. Read the per-file **Install Plan** that is printed before anything is written — no state
   directory, lock, runtime directory or other write happens before this point.
5. Confirm to proceed (unattended runs pass `--yes` / `-Yes`; a non-interactive run without it
   exits `8` and writes nothing).
6. The install finishes with a summary of the managed files.

Cancelling the folder picker exits immediately and writes nothing.

## Install / upgrade from the command line

```powershell
# always start here: a plan with zero writes
.\CodexDshTeamToolkit.Install.exe --target "D:\projects\my-project" --plan-only
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly

# install or upgrade
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

Nothing else is created: no `PATH` change, no registry key, no global PowerShell profile, no
`AGENTS.md` edit, no source modification, no dependency install.

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

Requirements and caveats:

- the universal template needs **native sub-agent capability** on the host; with only a single
  executor you get self-check instead of independent review, and that must be reported as such;
- the DSH transport is different: copying its directory does **not** remove its own runtime
  dependencies (Node, the DSH runtime, its configuration and the local Monitor) — those still apply;
- a hand copy is **not** tracked by the installer's ownership ledger, so the toolkit does not know
  it exists;
- if you later switch to the full package installer, a file that already exists at the same path
  and is *not* in the ledger is **refused, never overwritten** — move or remove your hand copy
  first. The installer has no per-component selection screen today.

Installing the **full toolkit** still goes through the original installer, and it installs all
three skills from the manifest. The DSH part currently runs on Windows
with the prerequisites listed above; the universal part is not DSH-specific, but the DSH runtime
itself has only been validated on Windows — this generalisation does not mean DSH has been
validated on other platforms.

## First start: the ACP profile is prepared at runtime

After `npm ci` in the installed `mcp-to-dsh` skill directory, the first launch of
`start_dsh_team.cmd` (or `scripts/start_dsh_team.ps1`) prepares the rest by itself:

1. The toolkit resolves (or creates, with the marker) the **owned Team Home** outside the project
   and outside Git; your user DSH Home is only a read-only sync source.
2. The **ACP profile** is prepared *inside that owned Team Home* using the installed, pinned DSH's
   own ACP template — a custom `-TeamProfile` name is initialised with that DSH's
   `--from-default-profile acp`. Nothing is downloaded for this step beyond the dependencies you
   already installed, and no second dependency tree is created inside the profile directory.
3. The same profile name is then routed to the Monitor (`--dsh-profile`), to the bridge child
   (`CODEX_DSH_ACP_PROFILE`) and to the one-click configuration sync (`-TeamProfile`).

What this means in practice:

- You do **not** hand-write a profile `package.json`, and the installer does **not** pre-place a
  profile: it stays an offline file copy, and profiles are a *runtime* concern.
- The profile name comes from `-TeamProfile`, then `CODEX_DSH_TEAM_PROFILE`, then the one optional
  profile already present in the owned Team Home; with **no** profile at all, the default `acp` is
  used and prepared. Only **several** existing optional profiles are an ambiguity: nothing is
  guessed, and you are asked to choose with `-TeamProfile` / `CODEX_DSH_TEAM_PROFILE`.
- A missing or half-finished profile directory is reported instead of being adopted, and a profile
  directory, its `package.json` and the plugins inside it are never replaced, moved or deleted. The
  configuration sync writes exactly one file inside the *selected* profile
  (`profiles/<name>/cordis.patch.yml`, with a timestamped `.bak`) to pin it to your configured
  provider/model.
- The DSH built-in helper templates `web`, `headless`, `sdk` and `sdk-minimal` are not ACP entries:
  they are ignored when the toolkit looks for an optional profile and refused as the Team profile;
  `node_modules` is refused as a profile name.

## Upgrading

Run the same command with a newer release package. An upgrade:

- replaces only files that are still byte-identical to their **pristine baseline** (the exact
  bytes the toolkit installed, kept under `.codex-dsh-team-toolkit/pristine/`);
- **blocks the whole upgrade** if any managed file was modified by hand (your file is kept);
- keeps managed files that the new release does not contain, still marked as owned;
- reports the new version in the ledger.

Re-running the *same* release is a verified no-op: nothing is rewritten.

## Migrating from the older mixed team skill

Earlier packages installed a single mixed team skill at `.agents/skills/codex-dsh-team/`. The
current release replaces it with three independent skills (`codex-team`, `dsh-role-boundaries`,
`mcp-to-dsh`).

**A plain upgrade does *not* remove the old entry.** The installer keeps managed files that the
new release no longer contains and reports them as `retained (still owned, not part of this
release)`, so after an ordinary upgrade the project would have **four** skill directories, with
the stale mixed one still present. To migrate:

1. **Uninstall the old managed files first**, using the uninstaller already inside the project
   (`CodexDshTeamToolkit.Uninstall.exe --target <project>`), which removes only files proven
   against the ownership ledger.
2. **Confirm the old entry is gone**: `<project>\.agents\skills\codex-dsh-team\SKILL.md` must not
   exist. Uninstall deliberately keeps anything you modified or added, so user content survives.
3. **If the old entry was kept** because it had local modifications, the installer will not force
   it: back it up yourself and move the whole `.agents/skills/codex-dsh-team` directory outside
   `.agents/skills` before installing the new package. No script deletes your edits.
4. **Install the new package** as usual; it installs the three current skills from the manifest.

Nothing in this release performs the removal automatically, and an upgrade must not be expected
to delete the old entry on its own.

## Known limitations

This is a source project under development; these items are open and are documented rather than
fixed here:

- **First start prepares the ACP profile automatically**: the installer pre-places no profile, and
  the launcher prepares it in the owned Team Home from the installed pinned DSH's own template
  after you run `npm ci` once. See
  [First start](#first-start-the-acp-profile-is-prepared-at-runtime) for the resolution rules.
- **Test results can look greener than they are**: the PowerShell entry can count a
  missing-dependency skip as a pass. Install the payload dependencies and read the Node suite's
  real results and SKIP count before treating the suite as fully executed.
- **Not fully verified**: the GUI folder picker, real provider runs, and some ACL / credential /
  partial-permission edge cases.

These do not have to block publishing the source, but they mean this is not a mature, formally
released product.

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

The uninstaller prints an Uninstall Plan, then deletes only ownership-proven files. See
[docs/SECURITY.md](SECURITY.md) for exactly what is kept.

`--plan-only` (EXE) and `-PlanOnly` (engine) show the plan and write nothing.

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
pwsh -File tests/Run-Tests.ps1                               # full safety suite
pwsh -File tools/Build-Release.ps1 -Version 1.1.0            # dist/ package + zip (no checksum artefact)
pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.1.0.zip
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
  pwsh -File tools/Build-Release.ps1 -Version 1.1.0 `
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
