# Codex × DSH Team Toolkit

A GitHub-ready, Windows-only, offline installer for the **Codex × DSH team skills**
(`codex-dsh-team` + `mcp-to-dsh`). It installs a small set of files into an existing
project, keeps a per-project ownership ledger plus a pristine byte copy of exactly what it
installed, and can undo that install
without ever touching your own work.

> Status: v1.0.0 source project. The `payload/` directory holds the managed skill files;
> this repository also holds the installer engine, the
> thin uninstaller, the release tooling, documentation and tests.

---

## Why it exists

The previous v3.2.0 installer that shipped with the earlier internal package (it is not part
of this repository) only ever *copied* files. It could not answer three questions that matter:

| Question | Old installer | This toolkit |
| --- | --- | --- |
| Is this file ours, or did the user write it? | unknown | ownership ledger with the exact installed bytes kept as a `pristine/` copy per managed file |
| What happens if the install dies halfway? | half-installed project | transactional: durable journal, backup, atomic replace, reverse rollback |
| Can it be undone? | no | transactional uninstall that only deletes ownership-proven files |

---

## Quick start

1. Download / extract a release package (or build one, see below).
2. **Install:** double-click `Install.cmd`, pick your project folder in the Windows folder
   picker. Nothing is written until you see the per-file plan and confirm.
3. **Uninstall:** double-click `CodexDshTeamToolkit.Uninstall.exe` inside the project, read
   the plan, confirm.

Command line (CI or power users):

```powershell
# plan only - provably zero writes
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly

# install / upgrade
.\Install.cmd -Target "D:\projects\my-project"

# unattended uninstall
& "D:\projects\my-project\CodexDshTeamToolkit.Uninstall.exe" --target "D:\projects\my-project" --yes
```

`Install.cmd` never requires elevation, never uses the network, and never touches `PATH`,
the registry, global PowerShell profiles, Git configuration, your `AGENTS.md` or your source
files.

---

## Guarantees

**Manifest-owned.** Only files listed in the release manifest are managed. An unknown file
with the same name blocks the whole operation — it is never overwritten.

**Proof before change.** An upgrade replaces a managed file only while it is byte-identical to
its pristine baseline (the exact bytes the toolkit installed, kept under the project's
`.codex-dsh-team-toolkit/pristine/`). If you edited a managed file, the upgrade is blocked and
your file is preserved.

**Transactional.** Plan → complete preflight → exclusive lock → durable journal + backup →
same-directory temp + atomic replace → verify → atomic manifest commit. Any failure rolls the
project back in reverse order, and the rollback itself is verified.

**Fail-closed.** Missing, corrupt, foreign or unsafe manifests, unsafe paths, symlinks,
junctions, reparse points, `..`, absolute/UNC/device paths, drive roots, case-folded
duplicates and file/directory type conflicts all stop the run with **zero writes**.

**Uninstall respects your work.** Only files still byte-identical to their pristine baseline are
deleted; user-modified files, files you added, `node_modules`, other skills and unknown
content are kept and reported. Directories are removed only when provably empty.

**No secrets in evidence.** Plans, journals, backups and logs never contain file contents or
credential values, and secret-shaped path segments are redacted before anything is printed
or persisted. See [docs/SECURITY.md](docs/SECURITY.md).

---

## What a release needs

- **Node ≥ 22.19.0** for the installed Team/Monitor runtime (declared in the payload's
  `engines.node`). The installer itself only needs PowerShell.
- `npm ci` once inside `<project>\.agents\skills\mcp-to-dsh` before the first Team run: that is
  the **only** step that uses the network. Install, upgrade, uninstall, tests, release build and
  release verify are all offline.
- Both install and uninstall show a plan and ask for confirmation. Automation passes `-Yes`;
  a non-interactive run without it exits `8` and writes nothing.
- The Team Home marker contract (`.codex-dsh-team-home.json`, `codex-dsh-team-home/v1`) is shared
  verbatim with the Node runtime, so installer-created and runtime-created Team Homes are
  mutually recognised. The superseded `.codex-dsh-team-runtime.json` is refused, never migrated.
- Ownership is proven by **direct byte comparison** with the `pristine/<path>` copy under the
  project's state directory: no checksum, hash or digest is computed, stored or trusted, and a
  match never means "who produced it". Team attribution stays with the Git evidence model.
- Integrity of the release *transport* (the download, the mirror, the archive in transit)
  belongs to the distribution channel: the toolkit creates and consumes no checksum list or
  sidecar and does not claim to detect a tampered package.

## Repository layout

```
Install.cmd                     double-click entry point (STA folder picker)
install/Invoke-Toolkit.ps1      the single core engine (install / upgrade / uninstall)
payload/                        the managed skill files
uninstaller/src/Uninstaller.cs  thin C# 5 WinForms shell
uninstaller/Build-Uninstaller.ps1  builds the EXE with the in-box csc.exe
release/                        release manifest schemas + package layout
tools/Build-Release.ps1         offline release builder
tools/Verify-Release.ps1        offline release verifier
docs/                           installation, configuration, security, troubleshooting
tests/                          safety / transaction / install+uninstall test suite
dist/                           generated by the build (git-ignored)
```

---

## Building a release (offline)

These commands are **maintainer tools for a source checkout only**. `tools/`, `tests/`,
`uninstaller/src/` and the `payload/` sources are repository artifacts: the release package
ships the built installer engine, the thin EXE, the docs and the release folder, not the
development tree.

```powershell
# 1. thin uninstaller EXE (needs the Windows in-box .NET Framework csc.exe)
pwsh -File uninstaller/Build-Uninstaller.ps1

# 2. package + zip (no network, no push, no checksum artefact)
pwsh -File tools/Build-Release.ps1 -Version 1.0.0

# 3. verify the produced package
pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.0.0.zip
```

`Build-Release.ps1` refuses to run when the payload is missing unless you pass
`-AllowMissingPayload`, and it fails the build on forbidden paths and on unmarked
high-confidence secrets found in payload text files.

---

## Documentation

- [docs/INSTALLATION.md](docs/INSTALLATION.md) — install, upgrade, verify, roll back
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — command line, exit codes, owned runtime
- [docs/SECURITY.md](docs/SECURITY.md) — threat model, deny-by-default, redaction, Team Home
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — locks, corrupt ledgers, csc.exe, reparse

## Tests

Repository-only as well: the suite lives in `tests/` inside this source project and is not
part of a release package.

```powershell
pwsh -File tests/Run-Tests.ps1            # everything, temporary directories only
pwsh -File tests/Run-Tests.ps1 -Filter '04-*' -KeepTemp
```

The suite uses temporary directories and fake credentials exclusively; it never reads a real
DSH configuration, credential store or runtime directory, and never uses the network.

## License

MIT — see [LICENSE](LICENSE).
