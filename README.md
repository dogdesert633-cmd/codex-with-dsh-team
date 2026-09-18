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

Copying files into a project is easy. Copying files into a project *safely* means being able to
answer three questions at any later point:

| Question | This toolkit |
| --- | --- |
| Is this file ours, or did the user write it? | ownership ledger with the exact installed bytes kept as a `pristine/` copy per managed file |
| What happens if the install dies halfway? | transactional: durable journal, backup, atomic replace, reverse rollback |
| Can it be undone? | transactional uninstall that only deletes ownership-proven files |

---

## Quick start

1. Download / extract a release package (or build one, see [Fork workflow](#fork-workflow)).
2. **Install:** double-click `CodexDshTeamToolkit.Install.exe` in the package root (the normal GUI
   entry), or `Install.cmd` if you prefer the zero-dependency script. Pick your project folder in
   the Windows folder picker. Nothing is written until you see the per-file plan and confirm.
3. **Uninstall:** double-click `CodexDshTeamToolkit.Uninstall.exe` inside the project, read
   the plan, confirm.

Command line (CI or power users):

```powershell
# plan only - provably zero writes
.\CodexDshTeamToolkit.Install.exe --target "D:\projects\my-project" --plan-only
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly

# install / upgrade (unattended)
.\CodexDshTeamToolkit.Install.exe --target "D:\projects\my-project" --yes

# unattended uninstall
& "D:\projects\my-project\CodexDshTeamToolkit.Uninstall.exe" --target "D:\projects\my-project" --yes
```

### Entry points

| Entry | Role |
| --- | --- |
| `CodexDshTeamToolkit.Install.exe` (package root) | The normal entry: double-click for the folder picker, or drive it unattended. Flags: `--target <project>` (or a positional path), `--package <dir>` (default: the EXE's own directory), `--yes`, `--no-ui`, `--plan-only`, `--help`. It is a thin framework-dependent shell — it locates the package and the project, shows the plan produced by the shared engine, asks for confirmation, then calls that engine and forwards its exit code. It holds no ownership, transaction or path logic of its own. |
| `Install.cmd` (package root) | The zero-dependency CLI/CI entry and the advanced path: it passes engine parameters straight through, and prefers `pwsh.exe` with a fallback to the in-box Windows PowerShell. Use it when you cannot or do not want to run an EXE. |
| `install/Invoke-Toolkit.ps1` | The single engine behind both launchers. Call it directly for engine-level switches (`-Action`, `-TestMode`, `-TestFault`, ...). |
| `CodexDshTeamToolkit.Uninstall.exe` (project root after install) | Thin launcher for the uninstall path, with `--plan-only` / `--yes` / `--no-ui`. |

The two package-root launchers are **not** installed into your project, do **not** enter the
ownership ledger, never elevate, and add no network use or persistent system state. They are
framework-dependent and run on the .NET Framework 4.x that ships with Windows 10/11. Exit codes
are stable and documented in
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#exit-codes): `0` success, `8` needs explicit
confirmation, and non-zero values are fail-closed with the rollback state reported.

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
- The DSH runtime dependency is pinned and tested against **`@deepseek-ai/dsh 0.1.5-rc.1`**
  (see the payload's `package.json`). Other DSH versions are not claimed to be compatible: a
  different version is untested rather than forbidden, so pin the one you validated.
- `npm ci` once inside `<project>\.agents\skills\mcp-to-dsh` before the first Team run.
- Both install and uninstall show a plan and ask for confirmation. Automation passes `-Yes`;
  a non-interactive run without it exits `8` and writes nothing.
- The Team Home marker is `.codex-dsh-team-home.json` (`codex-dsh-team-home/v1`), shared verbatim
  with the Node runtime, so installer-created and runtime-created Team Homes are mutually
  recognised. Any other marker file — including `.codex-dsh-team-runtime.json` — makes the
  directory refuse ownership instead of being adopted.
- Ownership is proven by **direct byte comparison** with the `pristine/<path>` copy under the
  project's state directory: no checksum, hash or digest is computed, stored or trusted, and a
  match never means "who produced it". Team attribution stays with the Git evidence model.
- Integrity of the release *transport* (the download, the mirror, the archive in transit)
  belongs to the distribution channel: the toolkit creates and consumes no checksum list or
  sidecar and does not claim to detect a tampered package.

### What leaves the machine, and what stays local

These are separate paths and are not the same promise:

| Path | Network behavior |
| --- | --- |
| Installer, upgrade, uninstall | Fully offline. No toolkit telemetry, no phone-home, no package restore, no elevation. |
| Maintainer build / Verify / tests | Fully offline. No push, no publish. |
| First `npm ci` in the payload skill | Contacts the npm registry once, to materialise the pinned dependency tree. |
| Running actual Team/Monitor AI tasks | Your prompt, repository context and task text are sent to the **model provider you configured** in DSH. That traffic is governed by your provider account and its terms, and it **may incur third-party cost**. This is your configuration, not toolkit telemetry. |

State and evidence stay local: the ownership ledger, `pristine/` baselines, transaction
journal/backups and the Team Home all live under your project and the toolkit's owned runtime
directory. Plans, journals and logs record paths and outcomes, never file contents or credential
values (see [docs/SECURITY.md](docs/SECURITY.md)).

## Repository layout

```
CodexDshTeamToolkit.Install.exe  package-root GUI/CLI installer launcher (built, not source)
Install.cmd                     zero-dependency CLI/CI entry (STA folder picker)
install/Invoke-Toolkit.ps1      the single core engine (install / upgrade / uninstall)
payload/                        the managed skill files
installer/src/Installer.cs      thin C# 5 installer shell
installer/Build-Installer.ps1   builds the installer EXE with the in-box csc.exe
uninstaller/src/Uninstaller.cs  thin C# 5 WinForms shell
uninstaller/Build-Uninstaller.ps1  builds the EXE with the in-box csc.exe
release/                        release manifest schemas + package layout
tools/Build-Release.ps1         offline release builder
tools/Verify-Release.ps1        offline release verifier
docs/                           installation, configuration, security, troubleshooting
tests/                          safety / transaction / install+uninstall test suite
dist/                           generated by the build (git-ignored)
```

### Repository materials vs the release package

`release/package-layout.json` is the authority on what ships. Today:

- **Repository-only** (not in the package): `tools/`, `tests/`, and `dist/`. These are
  maintainer materials — you need a source checkout to run them.
- **Shipped in the package**: `Install.cmd`, `CodexDshTeamToolkit.Install.exe`, the engine
  (`install/Invoke-Toolkit.ps1`), the built `uninstaller/CodexDshTeamToolkit.Uninstall.exe`,
  both READMEs, `CHANGELOG.md`, `LICENSE`, the four `docs/`, and the `release/`
  schemas/layout.
- **Shipped for auditability**: the build recipe and source of both thin launchers
  (`installer/Build-Installer.ps1` + `installer/src/Installer.cs`, and
  `uninstaller/Build-Uninstaller.ps1` + `uninstaller/src/Uninstaller.cs`) are included on
  purpose, so a reader can verify exactly what each EXE does and rebuild it with the Windows
  in-box compiler. They are not needed to install or uninstall.

---

## Fork workflow

Everything a fork needs happens in the source tree, and the result is a package:

1. **Edit the source tree.** The runtime skill files live under `payload/`; the installer engine
   is `install/Invoke-Toolkit.ps1`; the thin launchers are `installer/src/Installer.cs` and
   `uninstaller/src/Uninstaller.cs`. The managed install set is declared in
   `release/payload-inventory.json` — add a new payload file there as well as on disk, or the
   build will report it as undeclared and exclude it.
2. **Run the maintainer tools from a source checkout.** The full workflow below needs one:
   `tools/`, `tests/` and `dist/` are repository materials, not package contents. The two
   launcher build recipes and their sources are the exception — they ship with the package, so
   the EXEs can also be audited and rebuilt from an extracted release:

   ```powershell
   pwsh -File installer/Build-Installer.ps1                      # rebuild the installer EXE (in-box csc.exe)
   pwsh -File uninstaller/Build-Uninstaller.ps1                  # rebuild the thin EXE (in-box csc.exe)
   pwsh -File tests/Run-Tests.ps1                                # safety / transaction suite
   pwsh -File tools/Build-Release.ps1 -Version 1.0.0             # package + zip, offline
   pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.0.0.zip
   ```

   `Build-Release.ps1` refuses to run when the payload is missing unless you pass
   `-AllowMissingPayload`, and it fails the build on forbidden paths and on unmarked
   high-confidence secrets found in packaged text files.
3. **Inspect the tests.** `tests/` covers install, ownership, transactions, uninstall, path
   policy, confidentiality, relocation, recovery/TOCTOU, Windows hygiene, release tooling and
   the thin EXE. The suite uses temporary directories and fake credentials only.
4. **Publish the resulting package.** The build never pushes anywhere: publish
   `dist/codex-dsh-team-toolkit-v<version>/` (and the zip) yourself, through whatever channel
   you use. Release transport integrity is that channel's responsibility — see the note above.

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

## References and acknowledgements

This project referenced [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams)
during development, a DeepSeek Harness plugin for AgentTeams. Thanks to that project's author and
contributors for sharing their design and implementation publicly.

The referenced project uses the MIT License; see its
[LICENSE](https://github.com/NanmiCoder/dsh-agent-teams/blob/main/LICENSE).

## License

MIT — see [LICENSE](LICENSE).
