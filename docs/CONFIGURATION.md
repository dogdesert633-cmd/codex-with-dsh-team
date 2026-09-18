# Configuration

The **installer engine** has no config file of its own: everything is an explicit command-line
parameter or a documented project file. The only environment variable that changes *installer*
behaviour is the test gate `CODEX_DSH_TOOLKIT_TEST` (see below); a normal install/uninstall
never needs it. This statement is scoped to the installer engine only — the installed Node
Team/Monitor runtime reads its own environment (`LOCALAPPDATA`/`APPDATA` for the toolkit base
directory, `CODEX_DSH_TEAM_BASE_DIR` as an explicit override, plus the user's DSH
configuration), and that runtime is documented in the payload's own references. It requires
**Node ≥ 22.19.0** and its DSH dependency is pinned and tested against
**`@deepseek-ai/dsh 0.1.5-rc.1`**; other DSH versions are untested rather than unsupported.

## Entry points

| Entry | Role |
| --- | --- |
| `CodexDshTeamToolkit.Install.exe` (package root) | The normal installer entry. Flags: `--target <project>` (or a positional path), `--package <dir>` (default: the EXE's own directory), `--yes`, `--no-ui`, `--plan-only`, `--help`. It is a thin framework-dependent shell: it locates the package and the project, shows the plan produced by the engine below, confirms, calls the engine and forwards its exit code. It holds no ownership, transaction or path logic, is never installed into a project, never enters the ownership ledger, never elevates and adds no network use or persistent system state. |
| `Install.cmd` (package root) | The zero-dependency CLI/CI and advanced entry: engine parameters pass straight through. It prefers `pwsh.exe` and falls back to the in-box Windows PowerShell. |
| `install/Invoke-Toolkit.ps1` | The single engine behind both launchers. Call it directly for engine-level switches (`-Action`, `-TestMode`, `-TestFault`, ...). |
| `CodexDshTeamToolkit.Uninstall.exe` (project root after install) | Thin framework-dependent WinForms launcher for the uninstall path: `--target`, `--plan-only`, `--yes`, `--no-ui`. Unlike the package-root installer launcher, this one **is** installed into the target project root as a managed file and **is** recorded in the ownership ledger (see `managed` in `release/package-layout.json`), so the project can uninstall itself later. Like the installer it never elevates, uses no network and adds no persistent system state. |

None of these entries require elevation, and none of them touch `PATH`, the registry, global
PowerShell profiles, Git configuration or your source files. The two package-root launchers are
framework-dependent and run on the .NET Framework 4.x that ships with Windows 10/11.

## Engine parameters

`install/Invoke-Toolkit.ps1`

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Action Install\|Uninstall` | `Install` | operation to perform |
| `-Target <path>` | folder picker on install; derived from the engine location on uninstall | existing project root (absolute path) |
| `-PackageRoot <path>` | derived from the engine location | extracted release package root |
| `-ReleaseManifest <path>` | `<PackageRoot>/release-manifest.json` | explicit release manifest |
| `-PlanOnly` | off | show the plan and write nothing; the full read-only package preflight still runs |
| `-Yes` | off | explicit confirmation for unattended install **and** uninstall runs |
| `-NonInteractive` | off | never prompt; missing input is an error |
| `-Quiet` | off | suppress progress output (the plan is still produced) |
| `-OutputFile <path>` | off | also write the collected output to a file (used by the thin EXE) |
| `-TeamDshHome <path>` | off | existing toolkit-owned Team Home to adopt (see below) |
| `-RuntimeRootBase <path>` | `%LOCALAPPDATA%\CodexDshTeam` | base for the owned runtime root |
| `-InitializeRuntime` | off | create/validate the owned runtime root for this install |
| `-UninstallerSelf <path>` | off | the in-use EXE path, reported as a minimal residual |
| `-ClearStaleLock` | off | break the lock **only** when it is provably stale (valid schema/identity + plausible pid + that process gone + ≥10 min). An anomalous lock stays fail-closed |
| `-TestMode` + `-TestFault <point>` | off | test-only fault injection; refused unless `-TestMode` **and** `CODEX_DSH_TOOLKIT_TEST=1` |
| `-TestConfirmation <yes\|no>` | off | test-only: inject the interactive confirmation answer (same gate) |
| `-TestKeepTransaction` | off | test-only: keep the transaction directory for inspection (same gate) |
| `-Library` | off | dot-source the engine as a function library (used by tests and tools) |

## Exit codes

| Code | Meaning | Safe next step |
| --- | --- | --- |
| `0` | success (also: user cancelled the picker/plan) | — |
| `2` | usage error: missing/invalid target, or a test-only feature without its gate | pass `-Target`; set `CODEX_DSH_TOOLKIT_TEST=1` only in tests |
| `3` | blocked: unsafe path, reparse point, denied credential path, existing lock, unowned Team Home | read the message; nothing was written |
| `4` | conflict: unknown same-name file, user-modified managed file, in-lock TOCTOU change, type/case-fold conflict | resolve the file yourself |
| `5` | manifest problem: missing/corrupt/foreign release or ownership manifest, a managed source missing from the package, unknown state content | re-extract the release package |
| `6` | transaction failed; the project was rolled back | inspect the message, retry |
| `7` | recovery/rollback was incomplete; transaction evidence was kept | inspect `.codex-dsh-team-toolkit/txn/<id>` |
| `8` | install or uninstall needs explicit confirmation (interactive `YES`, or `-Yes` in automation) | re-run with `-Yes` |

## Network and data flow

The installer engine and the release tooling are offline: install, upgrade, uninstall, the
maintainer build and Verify make no network call and send no telemetry. Two other paths are
different and are documented here so they are not confused with that promise:

- **First `npm ci`** in `<project>\.agents\skills\mcp-to-dsh` contacts the npm registry once to
  materialise the pinned dependency tree.
- **Running actual AI tasks** through the installed Team/Monitor runtime sends your prompt,
  repository context and task text to the **model provider configured in your DSH setup**. That
  traffic is governed by your provider account and terms and **may incur third-party cost**; it
  is your configuration, not toolkit telemetry.

State and evidence remain local: the ownership ledger, `pristine/` baselines, transaction
journal/backups and the Team Home all live under your project and the toolkit's owned runtime
directory. See [SECURITY.md](SECURITY.md) for what is never recorded.

## Project state

```
<target>/
  .codex-dsh-team-toolkit/
    .gitignore         self-ignoring marker ('*'): the project's .gitignore is never edited
    manifest.json      ownership ledger (install id + managed paths + pristine baselines)
    engine/            installed engine copy
    install.log        append-only, redacted, never contains file contents
    .install.lock      exclusive lock while a transaction runs
    txn/<id>/          per-transaction journal + backups + quarantine (removed on success)
```

The ledger is the only source of truth about ownership. Ownership is proved by the **pristine
byte copies** kept under `.codex-dsh-team-toolkit/pristine/<same relative path>`: a managed file
may be replaced or deleted only while it is byte-identical to that baseline. No checksum, hash or
digest is ever computed, stored, compared or trusted, and none appears anywhere in the ledger.
The ledger is self-locating — it describes the state directory layout, never an absolute project
path — so a moved project keeps working, and it never contains an absolute personal path.

## Interrupted runs

An interrupted run (power loss, killed process) can leave a lock, a log and a `txn/<id>/`
directory. The next run:

1. takes the exclusive lock (or refuses if the lock is still provably live),
2. replays the durable journal before making any ownership decision,
3. re-reads the ledger and rebuilds the plan, and
4. only then applies.

A killed run therefore never permanently blocks a reinstall: a state directory that contains
only toolkit-owned leftovers (with no ledger) is recovered and reused, while a state directory
with unknown content is still refused. If a replay cannot be completed safely the run stops
with exit `7` and keeps the evidence instead of guessing.

## Test-only feature gate

Fault injection and transaction-evidence retention are gated twice:

```powershell
$env:CODEX_DSH_TOOLKIT_TEST = '1'   # explicit, per-process, never set by the toolkit
pwsh -File install/Invoke-Toolkit.ps1 -Action Install -Target <project> -TestMode -TestFault install.after-stage
```

Without the environment variable the engine refuses with exit `2` and writes nothing, so a
release binary cannot be steered into test behaviour by a stray command line.

## Owned runtime / Team Home

All writable runtime state must live outside the project and outside Git, in a toolkit-owned
directory:

```
%LOCALAPPDATA%\CodexDshTeam\                       toolkit base directory
  install.json                                     shared install identity
                                                   (schema codex-dsh-team-install/v1, toolkitId,
                                                    installId, createdAt, purpose)
  runtimes\<toolkit-install-id>\
    .codex-dsh-team-home.json                      Team Home ownership marker, shared verbatim
                                                   with the Node runtime:
                                                     schema   codex-dsh-team-home/v1
                                                     toolkitId codex-dsh-team-toolkit
                                                     installId <same id as install.json>
                                                     createdAt ISO-8601 UTC
                                                     purpose  dsh-team-runtime-home
```

Rules enforced by the engine:

- One contract, one marker file. Ownership proof is `.codex-dsh-team-home.json`
  (`codex-dsh-team-home/v1`) only. A directory that carries `.codex-dsh-team-runtime.json`
  (`codex-dsh-team-toolkit/runtime-marker/v1`) alone is refused as unowned, and a directory
  carrying both markers is refused outright: the engine never adopts, converts or merges such a
  directory.
- The `installId` comes from the shared `install.json`, never from a directory name, and the
  project ledger, the Team Home marker and the runtime root all use that same id.
- An existing directory **without** a valid marker is refused — never adopted.
- A marker whose `installId` belongs to a different installation, or a directory that looks
  like a plain user DSH Home (`settings.yaml`, `.credentials.yaml`, `sessions/`, `storages/`,
  ...), is refused.
- The parent chain must be free of symlinks/junctions/reparse points.
- `-TeamDshHome` must be an absolute local path; `-RuntimeRootBase` moves the base for
  tests or unusual layouts.

The **user DSH Home is read-only**: the toolkit never patches, migrates, cleans up,
overwrites or reconfigures it.

## Confidentiality rules applied to every output

- Deny-by-default path policy: `.env*`, credential stores, `id_rsa*`, `*.key|*.pem|*.pfx|*.p12|*.ppk|*.kdbx|*.jks`,
  `settings.yaml`, `secrets/`, `tokens/`, `cookies`, `sessions/`, `*.log`, `*.jsonl`,
  `.git/`, `.dsh/`, `node_modules/`, `artifacts/` and browser profiles are refused even if a
  manifest claims them.
- Plans, journals, backups and logs never contain file contents or credential values.
- Secret-shaped path segments are rendered as `<redacted>`, and bearer/basic tokens, JWTs,
  API keys, private key blocks and `key = "value"` pairs are redacted from every message.
- The journal stores relative managed paths only: it never persists the absolute personal path,
  and no digest is computed or stored.

## Release manifest (package side)

`release-manifest.json` (schema: `release/release-manifest.schema.json`):

```json
{
  "schema": "codex-dsh-team-toolkit/release-manifest/v1",
  "name": "codex-dsh-team-toolkit",
  "version": "1.0.0",
  "stateDirectory": ".codex-dsh-team-toolkit",
  "fileCount": 2,
  "files": [
    { "path": ".agents/skills/codex-dsh-team/SKILL.md",
      "source": "payload/.agents/skills/codex-dsh-team/SKILL.md" }
  ]
}
```

`path` is relative to the target project root, `source` is relative to the package root, and
both must stay relative and normalized. The manifest's `stateDirectory` must be exactly
`.codex-dsh-team-toolkit`; anything else is refused.

The manifest is a **location list**: no entry carries a digest, and no digest is read, validated
or stored from it. Release transport integrity belongs to the distribution channel — the toolkit
does not detect package tampering. Post-install protection is a separate mechanism: the
ownership manifest below stores a **pristine byte copy** per managed file, so the installer can
tell a user edit from toolkit content by comparing bytes.

### What the release build packages

The managed payload set is **declared**, not discovered:

- `release/payload-inventory.json` is the **single, current inventory source**. Its `files` array is the managed install set: each declared `path` becomes a
  managed payload entry (`payload/<path>` → `<path>`, the flatten contract).
- `releaseDevelopmentPaths` in the same inventory lists the public payload tests: they are packaged so the release is an auditable snapshot, but they are **never installed**. Build metadata (inventory, layout, build report) is never packaged and never installed.
- A payload-side `COPY_FILE_LIST.json` **does not exist** in this toolkit and is never packaged,
  never installed and never consulted. Do not treat such a file as an inventory;
  `release/payload-inventory.json` is the only one.
- Files present in `payload/` but not declared are reported and excluded; only
  `-IncludeUndeclaredPayload` includes them, loudly.
- A declared file that is missing stops the build.
- The package additionally contains the toolkit infrastructure (`Install.cmd`, the engine, the
  thin EXE **and its C# source and build recipe**, docs, licence, schemas) per
  `release/package-layout.json`, plus `release-manifest.json`. No checksum artefact is produced:
  there is no `SHA256SUMS.txt` and no `.sha256` sidecar, and the verifier fails closed if one
  appears in a package.

## Ownership manifest (project side)

`.codex-dsh-team-toolkit/manifest.json`
(schema: `release/ownership-manifest.schema.json`) records `installId`, `version`, `location`
(the self-locating `stateDir` + `pristineRoot` layout — never an absolute path and never a
location digest), and one `{ path, pristine, state }` entry per managed file, where `pristine`
is the baseline path of the exact installed bytes. The manifest contains **no checksum, hash or
digest field**, and never file contents, credentials or an absolute personal path.
