# Changelog

All notable changes to the Codex × DSH Team Toolkit are recorded here.
This project adheres to [Semantic Versioning](https://semver.org/).

## [1.0.0] — 2026-09-15

First public, GitHub-ready release of the installer infrastructure. The `payload/`
directory holds the managed skill files and is a
read-only build input here.

### Hardening round (audit repairs)

- **Durable-journal recovery.** A transaction killed by a crash or power loss is now replayed
  under the exclusive lock *before* any ownership decision, so a half-applied file can no
  longer be mistaken for a user edit and block installs forever. Recovery is idempotent,
  reports what it did, and stops with exit `7` (keeping evidence) instead of guessing.
- **Reinstall after a killed run.** A state directory that holds only toolkit-owned leftovers
  and no ledger is recovered and reused; a directory with unknown content is still refused.
  Lock release always happens before any state-directory cleanup.
- **In-lock TOCTOU guard.** Immediately before applying, the engine re-proves that `create`
  destinations still do not exist, that `replace` destinations are still byte-identical to their
  pristine baseline, and that the ledger itself is unchanged. A change aborts with exit `4` and
  preserves the file.
- **Rollback completeness.** Rollback also sweeps stray same-directory temp files (only those
  matching our own naming pattern *and* the bytes this run was going to install), re-checks for
  reparse points before removing a directory, and never deletes a file that appeared at a
  quarantined path during an interrupted uninstall: that file is preserved, the recovered
  original is kept as evidence, and the run stops.
- **Preflight before the plan.** The full read-only package preflight now runs before the plan
  is displayed and also in `-PlanOnly`, so a dry run validates exactly what a real run does.
- **Stricter stale-lock proof.** Breaking a lock now requires a valid lock identity, a
  plausible recorded pid, that process actually gone, and ≥10 minutes of age; an anomalous lock
  stays fail-closed.
- **Test-only gate.** Fault injection and transaction-evidence retention now require
  `CODEX_DSH_TOOLKIT_TEST=1` in addition to the switches, so a release install cannot be steered
  into test behaviour by a stray command line.
- **No absolute personal path in the ledger.** The ledger is self-locating: it records the
  relative state-directory layout (`stateDir` + `pristineRoot`) and never an absolute project
  path, so relocation needs no migration. The state directory also carries a
  self-ignoring `.gitignore`, so the project's own `.gitignore` is never edited.
- **`stateDirectory` is validated** in the release manifest instead of being ignored.

### Release tooling hardening

- **Inventory-driven payload.** `release/payload-inventory.json` is the single, current
  inventory source: its `files` array is the managed install set (runtime only) and its
  `releaseDevelopmentPaths` array is packaged for auditability but never installed. The
  inventory itself is never installed, and undeclared payload files are reported and excluded
  (`-IncludeUndeclaredPayload` overrides, loudly). A payload-side `COPY_FILE_LIST.json` is
  deprecated and does not exist: it is never packaged, installed or consulted, and no build
  step may treat it as an inventory.
- **Owned staging.** The package is built in a private staging directory and moved into place
  only when complete: a failed build leaves the previous artifacts untouched, removes only its
  own staging directory, and never recursively deletes an arbitrary `-OutputDir`.
- **Whole-package scanning.** Secret and fixed-environment binding scanning covers every text
  file in the package, not just the payload. Findings are printed as `path:line` only, and the
  fake/example exception applies to the matched value itself rather than to the whole line.
  Fixed DSH home/version bindings block; fixed provider/model pinning is reported for review.
- **No release checksum artefact (no-hash contract).** The build writes no `SHA256SUMS.txt` and
  no `.sha256` sidecar, the release manifest carries `path`/`source` only, and the verifier
  consumes no digest and fails closed if a checksum artefact is smuggled into a package. Zip
  entry names and managed install paths keep the full relative-path validator (traversal,
  absolute/UNC/device paths, drive letters, alternate data streams, reserved names, case-folded
  duplicates, symlink entries) and are validated before anything is expanded; the managed
  install set is proven runtime-only. Integrity of the release *transport* belongs to the
  distribution channel: the toolkit never claims to detect a tampered package.
- The release package now also ships the thin uninstaller's C# source and build recipe.

### Release integration round (v1.0.0 candidate)

- **One Team Home marker contract.** The installer and the Node runtime now share a single
  marker (`.codex-dsh-team-home.json`, `codex-dsh-team-home/v1`, fields `schema`, `toolkitId`,
  `installId`, `createdAt`, `purpose`) plus a shared install identity (`install.json`,
  `codex-dsh-team-install/v1`). The superseded `.codex-dsh-team-runtime.json` is refused as
  unowned, a dual-marker directory is refused outright, and there is no migration. Cross
  implementation tests prove the installer accepts runtime-written markers and the runtime
  accepts installer-written markers.
- **Untrusted journal evidence.** Before any restore, move or delete, every path in a journal is
  validated for strict relative syntax, deny policy, canonical containment, case-folded
  duplicates and reparse points. Journal `kind`/`state` are checked against an explicit
  allowlist, unknown values stop the run with the evidence kept, staged paths must follow the
  toolkit temporary naming pattern, and JSON documents (manifest, ledger, layout, marker,
  identity, journal) with duplicate keys are refused instead of silently keeping the last value.
- **Plan before confirmation before writes.** Install and uninstall now print the plan and ask
  for confirmation while still at absolute zero writes: no state directory, `.gitignore`, lock,
  log or runtime directory is created before consent. `-Yes` confirms in automation; a
  non-interactive run without it exits `8`. `-PlanOnly` remains a strict dry run, even when an
  interrupted transaction is waiting. If automatic recovery changes the plan after confirmation,
  the updated plan is shown and confirmed again.
- **Rollback restores timestamps.** A rolled-back file is now byte-identical *and* carries its
  original last-write time, so an aborted transaction leaves the tree indistinguishable from
  before it started.
- **Runtime-only install set.** `release/payload-inventory.json` declares only the 50 runtime
  payload paths; payload development tests, release metadata, credentials, ownership markers,
  runtime state and artifacts are never packaged and never installed. Build and Verify both
  enforce this contract explicitly.
- **Release gates.** `releaseMustContain` now covers both READMEs, the changelog and all four
  documents; Verify reads the packaged layout (and requires it to agree with the repository
  copy), runs the secret/binding scan by default (`-SkipContentScan` opts out explicitly), and
  proves the managed install set is runtime-only. Build refuses to reuse a thin
  uninstaller EXE older than its own source or recipe (`-BuildUninstaller` rebuilds it,
  `-AllowStaleUninstaller` is loud).
- **Windows hygiene.** All `*.cmd` entry points are CRLF and pure ASCII, pinned by
  `.gitattributes`; the thin EXE is built with `/langversion:5` (and `/deterministic` when the
  compiler supports it) and carries file version 1.0.0.0.
- **Bounded Node gate.** The payload Node suite is executed by the core test suite in a
  standalone temporary copy with read-only offline dependencies and a hard time bound, so an
  open handle or teardown bug fails visibly instead of hanging. The optional byte comparison
  against a v3.2.0 package is an explicit maintainer-only input
  (`CODEX_DSH_TEAM_BASELINE_ROOT`) that skips cleanly when absent: no public file hardcodes or
  depends on an internal development path.
- **Windows PowerShell 5.1 parity.** All 106 core test cases pass on both PowerShell 7 and the
  in-box Windows PowerShell 5.1; native Node probes avoid `-e` quoting and JSON argv values
  (5.1 strips embedded double quotes).
- **Documentation truth pass.** The Team Home marker fields, the shared install identity, the
  confirmation gate, Node ≥ 22.19.0 / first `npm ci` / offline boundaries, the ACL-failure
  behaviour of credential copies, environment-only credentials not being forwarded, and the
  fact that ownership is proved by direct comparison with the `pristine/<path>` baseline rather
  than by any digest are all documented
  consistently in both READMEs and the four documents.

### Added

- `install/Invoke-Toolkit.ps1` — one core engine for install, upgrade and uninstall with:
  - a per-file Install/Uninstall Plan and a provably zero-write `-PlanOnly` mode;
  - release-manifest ownership: only listed files are managed, unknown same-name files
    block the whole operation instead of being overwritten;
  - upgrade replacement only while the current bytes are identical to the recorded `pristine/`
    baseline;
  - a transactional pipeline (exclusive lock → durable journal + backup → same-directory
    temp → atomic replace → verify → atomic manifest commit) with reverse, verified
    rollback on any failure;
  - fail-closed handling of missing/corrupt/foreign manifests and of every unsafe path
    shape (traversal, absolute, UNC, device, root, over-long, reserved device names,
    case-fold duplicates, file/directory type conflicts);
  - full per-segment symlink / junction / reparse-point refusal;
  - relocation support: the ledger is anchored on its own location, and the advisory
    location metadata is refreshed only when every recorded file still matches;
  - uninstall via a toolkit-owned quarantine: only ownership-proven files are removed,
    user-modified/user-added/unknown content and `node_modules` are kept and reported,
    directories are removed only when provably empty, and a minimal residual (an in-use
    uninstaller) is reported instead of triggering a recursive delete;
  - deny-by-default path policy and redaction of secret-shaped values in every plan,
    journal, manifest, log and message;
  - test-only fault injection (`-TestFault` + `-TestMode`) at documented transaction points.
- `Install.cmd` — double-click entry point with an STA Windows folder picker; cancelling
  exits safely with zero writes; non-interactive sessions get a clear error instead of a
  prompt.
- `uninstaller/` — thin C# 5 WinForms shell built by the Windows in-box `csc.exe`
  (framework-dependent, ~13 KB), plus `Build-Uninstaller.ps1` which is fail-visible about
  missing compiler prerequisites. The EXE only locates the project, shows the plan,
  confirms, calls the same PowerShell engine and forwards its exit code.
- `tools/Build-Release.ps1` / `tools/Verify-Release.ps1` / `release/` — offline packaging
  with a location-only (`path`/`source`) release manifest, no checksum artefact, payload
  content scan and deny-by-default path scanning. No network access, no push.
- `docs/` — installation, configuration, security and troubleshooting guides, including
  the Agent Context / redaction / prompt-injection policy and the owned Team Home rules.
- `tests/` — a temporary-directory test suite (install, ownership, transaction, uninstall,
  path/policy, confidentiality, relocation, release tooling, thin EXE) using fake
  credentials only.

### Security

- Agent Context is minimal by design: only the minimal necessary configuration may be read,
  redaction happens before dispatch and before persistence, and project text or prompt
  injection is never an authorization to read secrets.
- The user DSH Home is read-only. All writable runtime state belongs to a toolkit-owned Team
  Home (`%LOCALAPPDATA%\CodexDshTeam\runtimes\<toolkit-install-id>\`) that must carry a valid
  marker; an existing directory without a valid marker is refused, never adopted.
- Credentials are never copied into the project. Where the payload needs one inside the owned
  Team Home the copy is opaque and one-directional (user DSH Home -> owned Team Home); if the
  target ACL cannot be tightened to the current user only, the copy is refused and deleted
  again, and the run stops. Environment-only credentials (`*_TOKEN`/`*_KEY`/`*_PASSWORD`/
  `*_SECRET`/`*_COOKIE`/`AUTHORIZATION`) are never forwarded to a child process, and no
  credential value ever reaches Monitor output, logs, evidence, Agent context or a release.

### Notes

- Windows only. No Linux/macOS support and no multi-project control plane.
- The payload is not included in this repository; `Build-Release.ps1` fails visibly when it
  is missing unless `-AllowMissingPayload` is passed explicitly.
