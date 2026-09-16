# Installation

## Prerequisites

| Requirement | Notes |
| --- | --- |
| Windows 10 / 11 | Windows only. No Linux/macOS support. |
| PowerShell 5.1 **or** PowerShell 7+ | `Install.cmd` prefers `pwsh.exe` and falls back to the in-box Windows PowerShell. |
| An existing project directory | The toolkit never creates the target root. |
| .NET Framework 4.x | Only needed to **build** the thin uninstaller EXE, not to run a release. |
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

Boundaries to be aware of:

- `npm ci` is the only step that needs the network. Everything else in this project — install,
  upgrade, uninstall, tests, release build and release verify — is offline.
- Node ≥ 22.19.0 is required (see `engines.node`). An older Node fails visibly instead of
  running with an unsupported runtime.
- `node_modules/**` is never part of a release package, is never installed by the installer and
  is never deleted by the uninstaller (it is untracked content, reported and kept).
- The installer and the runtime share the Team Home marker contract, so an install prepared by
  either side is recognised by the other without migration.

## Install with the folder picker (recommended)

1. Extract the release package anywhere (for example `%USERPROFILE%\Downloads\codex-dsh-team-toolkit-v1.0.0`).
2. Double-click **`Install.cmd`**.
3. A Windows folder picker opens. Select the **existing** project root you want the toolkit
   installed into, then confirm.
4. Read the per-file **Install Plan** that is printed before anything is written — no state
   directory, lock, runtime directory or other write happens before this point.
5. Type `YES` to proceed (automation passes `-Yes`; a non-interactive run without it exits `8`
   and writes nothing).
6. The install finishes with a summary of the managed files.

Cancelling the folder picker exits immediately and writes nothing.

## Install / upgrade from the command line

```powershell
# always start here: a plan with zero writes
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly

# install or upgrade
.\Install.cmd -Target "D:\projects\my-project"
```

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
| the payload paths (for example `.agents/skills/codex-dsh-team/...`, `start_dsh_team.cmd`, ...) | the skills themselves |

Plus one ledger: `.codex-dsh-team-toolkit/manifest.json` (not a managed file — it *is* the
record of the managed files).

Nothing else is created: no `PATH` change, no registry key, no global PowerShell profile, no
`AGENTS.md` edit, no source modification, no dependency install.

## Upgrading

Run the same command with a newer release package. An upgrade:

- replaces only files that are still byte-identical to their **pristine baseline** (the exact
  bytes the toolkit installed, kept under `.codex-dsh-team-toolkit/pristine/`);
- **blocks the whole upgrade** if any managed file was modified by hand (your file is kept);
- keeps managed files that are no longer part of the release, still marked as owned;
- reports the new version in the ledger.

Re-running the *same* release is a verified no-op: nothing is rewritten.

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

These commands are **maintainer tools for a source checkout only**: `tools/`, `tests/` and
`uninstaller/src/` are repository artifacts and are not shipped inside a release package, so
they do not exist in an extracted release.

```powershell
pwsh -File uninstaller/Build-Uninstaller.ps1                 # thin EXE (needs in-box csc.exe)
pwsh -File tests/Run-Tests.ps1                               # full safety suite
pwsh -File tools/Build-Release.ps1 -Version 1.0.0            # dist/ package + zip (no checksum artefact)
pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.0.0.zip
```

The build is offline and never pushes anywhere. Useful properties:

- `release/payload-inventory.json` is the **single, current inventory source** (`files` = runtime only), so a stray file in
  `payload/` can never be installed by accident (it is reported and excluded). A payload-side
  `COPY_FILE_LIST.json` is deprecated and does not exist in this toolkit: it is never packaged,
  never installed and never consulted as an inventory;
- everything is produced in a private staging directory and moved into place only when the
  package is complete: a failed build leaves the previous `dist/` artifacts untouched and
  removes only its own staging directory;
- the whole package (not just the payload) is scanned for secrets and fixed-environment
  bindings. If a reviewed fixture legitimately contains a key-shaped value, allowlist that file
  explicitly — the use is printed in the build output and recorded in `dist/build-report.json`:

  ```powershell
  pwsh -File tools/Build-Release.ps1 -Version 1.0.0 `
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
