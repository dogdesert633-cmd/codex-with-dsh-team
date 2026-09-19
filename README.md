# Codex × DSH Team Toolkit

**English** | [简体中文](README.zh-CN.md)

Codex quota never quite enough? Hand the repetitive implementation and review work to a team with
clear, written boundaries.

The toolkit ships **three independent Skills**:

| Skill | What it is |
| --- | --- |
| `$codex-team` | A universal multi-role template: role boundaries, task contracts, independent review, failure-returns-to-fix, evidence and final acceptance. Backend-independent — needs no DSH, Node or Monitor. |
| `$dsh-role-boundaries` | What DSH may and may not be given: non-visual code work, read-only exploration, code review and text work are eligible; drawing, image generation/editing, image understanding, OCR, screenshot analysis, GUI visual judgement/acceptance and long waits are not. |
| `$mcp-to-dsh` | The DSH call path and Monitor: delivers an already-decided work package to a real DSH session and streams public events plus session/turn/run evidence. It does not decide roles. |

```
$codex-team                                   # universal teamwork only
$dsh-role-boundaries $mcp-to-dsh              # DSH work; the universal template is optional
$codex-team $dsh-role-boundaries $mcp-to-dsh  # read together as peers, not loaded by each other
```

**The recommended way to install them is the complete Windows package**: one run of the package-root
installer writes all three Skills into the project you choose, and uninstalls them cleanly later.
Codex stays the coordinator and the final acceptance gate; DSH is used on demand to share the
ordinary implementation and review load, on the provider you configure (which may incur cost).

> **Status: v1.1.0 development preview / pre-release; a source checkout contains no compiled
> `.exe`.** The v1.1.0 package is available as a **pre-release** (it is not a stable release):
> download it from
> [releases/tag/v1.1.0](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.1.0),
> or see [Quick start](#quick-start) for the steps with a package in hand. Open items are listed
> under [Known limitations](#known-limitations).

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

**Install everything with the complete package (recommended).**

1. **Download the package**:
   [codex-dsh-team-toolkit-v1.1.0.zip](https://github.com/dogdesert633-cmd/codex-dsh-team-toolkit/releases/tag/v1.1.0)
   from the v1.1.0 pre-release. (Maintainers can also build it locally with
   `tools/Build-Release.ps1`; output lands in `dist/`.)
2. **Extract it completely** — the installer needs the whole package tree, not just the EXE.
3. **Run `CodexDshTeamToolkit.Install.exe`** in the package root (the normal GUI entry), or
   `Install.cmd` if you prefer the zero-dependency script.
4. **Pick your existing project root** in the Windows folder picker.
5. **Review the per-file plan and confirm.** Nothing is written before that point.
6. All three Skills land in one pass, at `<project>/.agents/skills/codex-team`,
   `<project>/.agents/skills/dsh-role-boundaries` and `<project>/.agents/skills/mcp-to-dsh`.
   The project root also receives `start_dsh_team.cmd`, `sync_dsh_team_config.cmd` and the thin
   uninstaller. Those files are tracked by the package inventory and the project's ownership
   ledger — you do not copy anything by hand, and the installer does **not** edit your project's
   `AGENTS.md`.

Before the first real DSH run, install the runtime dependencies once
(`npm ci` inside `<project>\.agents\skills\mcp-to-dsh`). The first launch then prepares everything
else itself: inside the toolkit-owned Team Home it initialises the DSH **ACP profile** from the
installed, pinned DSH's own template. You do **not** hand-write a profile `package.json`, and the
profile directory does not need a second dependency tree — see
[ACP profile](#acp-profile-the-dsh-entry-profile) below.

Command line (CI or power users, from an extracted package):

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

## ACP profile (the DSH entry profile)

The "profile" here is a **DSH launch configuration and module declaration** (`profiles/<name>/`
holding a `package.json` that declares the ACP bundles DSH loads), not a personal profile, account,
provider or model choice. The toolkit's default is the DSH built-in **`acp`**; that value is what
the launcher, the Monitor and the bridge child all use.

| You set | Meaning |
| --- | --- |
| `-TeamProfile <name>` (launcher / `start_dsh_team.cmd`) | The ACP profile to use; `CODEX_DSH_TEAM_PROFILE` is the environment equivalent. A custom name that does not exist yet is created for you. |
| nothing | The one optional profile already present in the owned Team Home, if there is exactly one; otherwise the built-in `acp`, which is then prepared automatically. |
| `-TeamProfile <new-name>` | A custom name is **created** in the owned Team Home from the installed DSH's own ACP template (`dsh --from-default-profile acp`). A profile directory and its plugins are never replaced, moved or deleted; the configuration sync only rewrites the **selected** profile's `cordis.patch.yml` (keeping a timestamped `.bak`) so that profile is pinned to your configured provider/model. |
| Monitor `--dsh-profile <name>` | The same name the Monitor records and forwards to the bridge as `CODEX_DSH_ACP_PROFILE`. `dshProfile` in `/api/health` and `dsh_profile` in the local Monitor record expose it; reuse requires workspace, Team Home **and** profile to match. |

How the name is chosen, in order:

1. `-TeamProfile <name>`;
2. `CODEX_DSH_TEAM_PROFILE`;
3. the one optional profile already present in the owned Team Home;
4. otherwise the default `acp`, prepared automatically.

- **Several candidates must be chosen explicitly.** If the Team Home already holds more than one
  optional profile, nothing is guessed: pass `-TeamProfile` / `CODEX_DSH_TEAM_PROFILE`. Having no
  profile at all is not an ambiguity — the default `acp` is used and prepared.
- **Your profiles are yours.** Existing profiles are kept; user plugins inside them are not moved,
  merged or overwritten by the toolkit.
- **The built-in helper templates are not entries.** `web`, `headless`, `sdk` and `sdk-minimal` are
  ignored when the toolkit looks for an optional profile, and are refused as the Team ACP entry;
  `node_modules` is refused as a profile name.
- **A half-finished profile is refused.** If the target directory already exists without a valid
  profile manifest, nothing is adopted or overwritten: repair it or pick another name.
- **One name end to end.** The launcher, the Monitor, the configuration sync and the bridge child
  receive the same profile, so a task can never be planned under one profile while DSH runs another.
- **Installed vs prepared.** The installer only copies files (offline); the ACP profile is prepared
  at runtime inside the owned Team Home, never by the installer and never inside your user DSH Home
  (which stays a read-only sync source). What the sync *does* copy there — `settings.yaml`,
  provider/model selection and an `.credentials.yaml` copy with a current-user ACL — is unchanged.

## Optional: rules-only manual copy

If you want *only* the two rules-only Skills and no installer, copy their directories by hand
instead of using the package:

```text
<repo>/payload/.agents/skills/codex-team            -> <project>/.agents/skills/codex-team
<repo>/payload/.agents/skills/dsh-role-boundaries   -> <project>/.agents/skills/dsh-role-boundaries
```

This is a lightweight path, not the recommended one: a hand copy is not tracked by the ownership
ledger, and the DSH runtime needs its own prerequisites (Node, the DSH runtime, its configuration
and the owned Team Home the installer prepares). To actually call DSH, use the complete package and
its documented prerequisites rather than hand-copying `mcp-to-dsh`. Uninstalling later is also not
managed for hand copies.

> Upgrading from an older package that shipped the single mixed `codex-dsh-team` skill? A plain
> upgrade keeps that old directory as `retained`, so uninstall the old managed files first — see
> [Migrating from the older mixed team skill](docs/INSTALLATION.md#migrating-from-the-older-mixed-team-skill).

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

**What is stored locally, and what is not.** The toolkit *does* keep byte copies of the files it
manages: `pristine/<path>` holds the exact installed bytes (that is what ownership comparison
and uninstall use), and a transaction keeps `backup/` and `quarantine/` copies so it can roll
back or restore. Plans, journals and logs record **paths and status**, not file bodies, and
secret-shaped path segments are redacted before anything is printed or persisted. That is a
redaction guarantee about messages, not a claim that no copy of your content exists anywhere.
See [docs/SECURITY.md](docs/SECURITY.md) for the full picture, including the Monitor's own
prompt/event/Git evidence and the credential copy in the owned Team Home.

**DSH executes with real permissions.** The Monitor pins `danger-full-access` and the ACP bridge
answers permission requests automatically (`ALLOW_ONCE`), so DSH tools run without an interactive
approval prompt. The role allowlist in a work package is an **instruction boundary, not an OS
sandbox**. `dispatch_dsh_gui.ps1 -RejectTools` (equivalently `allowTools:false`) makes the bridge
answer `REJECT_ONCE` — it refuses tools, and is **not** an added approval UI.

**Runtime output is not ignored for you.** The toolkit does not edit your project's root
`.gitignore`, and the installed skill's own `.gitignore` only covers that skill directory. Before
running DSH, add these exact directories to your project's `.gitignore` or `.git/info/exclude`
if you do not want them tracked: `artifacts/dsh-monitor/`, `artifacts/dsh-gui-runs/`,
`.dsh/contracts/`. Files already tracked are unaffected by ignore rules, so check with
`git status` first.

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
   pwsh -File tools/Build-Release.ps1 -Version 1.1.0             # package + zip, offline
   pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.1.0.zip
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

## Known limitations

This is a source project under development, not a finished release. Open items, stated plainly:

- **First run of the owned Team Home is prepared automatically.** After `npm ci` in the installed
  `mcp-to-dsh` skill directory, the launcher initialises the ACP profile inside the owned Team Home
  from the installed, pinned DSH's own template. The installer itself stays an offline file copy
  and pre-places no profile; a custom `-TeamProfile` name is created the same way.
- **Test coverage is not as green as it looks**: the PowerShell suite can count a
  missing-dependency skip as a pass. Install the payload dependencies and read the Node suite's
  real results and SKIP count before treating the suite as fully executed.
- **Not fully verified**: the GUI folder picker, real provider runs, and some ACL / credential /
  partial-permission edge cases.

Evidence gathered so far (rules review, a targeted 9 pass / 1 skip slice, and an isolated package
install plus migration exercise) is real but limited; it does not make this a mature, formally
released product.

## References and acknowledgements

This project referenced [NanmiCoder/dsh-agent-teams](https://github.com/NanmiCoder/dsh-agent-teams)
during development, a DeepSeek Harness plugin for AgentTeams. Thanks to that project's author and
contributors for sharing their design and implementation publicly.

The referenced project uses the MIT License; see its
[LICENSE](https://github.com/NanmiCoder/dsh-agent-teams/blob/main/LICENSE).

## License

MIT — see [LICENSE](LICENSE).
