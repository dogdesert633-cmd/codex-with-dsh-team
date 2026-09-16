# Configuration

The **installer engine** has no config file of its own: everything is an explicit command-line
parameter or a documented project file. The only environment variable that changes *installer*
behaviour is the test gate `CODEX_DSH_TOOLKIT_TEST` (see below); a normal install/uninstall
never needs it. This statement is scoped to the installer engine only — the installed Node
Team/Monitor runtime reads its own environment (`LOCALAPPDATA`/`APPDATA` for the toolkit base
directory, `CODEX_DSH_TEAM_BASE_DIR` as an explicit override, plus the user's DSH
configuration), and that runtime is documented in the payload's own references.

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

- One contract, one marker file. The superseded `.codex-dsh-team-runtime.json`
  (`codex-dsh-team-toolkit/runtime-marker/v1`) is **not** ownership proof: a directory that
  carries it alone is refused as unowned, and a directory carrying both markers is refused
  outright. There is no migration and no dual-marker state.
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
- A payload-side `COPY_FILE_LIST.json` is **deprecated and does not exist** in this toolkit: it is never packaged, never installed and never consulted. Do not treat it as an inventory; `release/payload-inventory.json` is the only one.
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
