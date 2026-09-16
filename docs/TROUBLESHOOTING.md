# Troubleshooting

Always start with a plan-only run — it writes nothing and explains the decision:

```powershell
.\Install.cmd -Target "D:\projects\my-project" -PlanOnly
& "D:\projects\my-project\CodexDshTeamToolkit.Uninstall.exe" --plan-only --target "D:\projects\my-project"
```

## Exit codes at a glance

`0` success · `2` usage · `3` blocked · `4` conflict · `5` manifest · `6` transaction failed
and rolled back · `7` rollback incomplete · `8` uninstall needs `-Yes`.

## "The target project root must already exist as a directory"

The toolkit never creates the target root. Create the folder first, or fix the `-Target`
path. Relative paths are rejected on purpose — pass an absolute local path.

## "Another toolkit install/uninstall is in progress (lock file present)"

A previous run was killed and left `.codex-dsh-team-toolkit/.install.lock`. The lock is
fail-closed: the toolkit will not break it silently.

1. Confirm no PowerShell/toolkit process is still running.
2. Re-run with `-ClearStaleLock`. The lock is removed **only** when it is provably stale: a
   valid lock schema and toolkit identity, a plausible recorded process id, that process no
   longer running, and an age of at least 10 minutes. A corrupt lock, a lock without a valid
   process id, or a younger lock is refused again — inspect and remove it by hand only when you
   are certain no run is active.

A leftover lock (and a leftover `install.log`) never permanently blocks a reinstall once the
lock is cleared: a state directory that contains only toolkit-owned leftovers and no ledger is
recovered and reused.

## "Recovering an interrupted … transaction"

Not an error. A previous run was killed mid-transaction, so the durable journal is being
replayed under the exclusive lock before anything new happens. The message says whether the
transaction had already committed. No action is required.

## Exit code 7 — "refusing to continue so nothing is overwritten"

Automatic recovery could not complete safely (an unreadable journal, or a concurrent file
appeared at a path an interrupted uninstall had quarantined). The engine kept the transaction
evidence and stopped instead of guessing.

1. Inspect `.codex-dsh-team-toolkit/txn/<id>/journal.json` plus its `backup/` and `quarantine/`
   directories. The journal records relative paths only.
2. Reconcile by hand, then move the transaction directory aside (or delete it).
3. Re-run. The toolkit never deletes that evidence for you.

## "A managed file was modified by the user. Upgrade is blocked"

Working as designed. Choose one:

- keep your version and skip the upgrade for that file;
- restore the original content so the file is byte-identical to its `pristine/<path>` baseline
  again, after which the upgrade proceeds normally;
- if the upstream content really should win, remove the file **and** let the toolkit re-create
  it: run the installer again after the ledger entry is gone (a reinstall re-creates missing
  managed files from the release). Deleting the file alone does **not** turn it into a "new"
  file — the ledger still records the path and its pristine baseline, so the next run simply
  restores the release content and keeps that baseline as the ownership proof.

Never hand-edit `.codex-dsh-team-toolkit/manifest.json` to force progress: a ledger whose
recorded paths and pristine copies do not match reality only causes the same refusal later.

## "An unknown file with the same name already exists"

A file with a managed name exists but is not in the ledger. The toolkit will not overwrite it.
Move, rename or delete it yourself if the toolkit version should be installed.

## "Managed source is missing from the package"

The extracted package is incomplete: a file listed in `release-manifest.json` is no longer on
disk. Re-extract the release package and retry. Never regenerate the manifest by hand.

Note the honest boundary: the release manifest is a **location list**, so editing a packaged
file's *contents* is not detected by the toolkit at all. Verifying that the download itself was
not altered is the distribution channel's job (for example the release page's own integrity
metadata), not something `Verify-Release.ps1` claims to do.

## "A toolkit state directory exists without an ownership manifest"

Fail-closed state. Inspect `.codex-dsh-team-toolkit/`. If it is a leftover from a killed run
that never wrote a ledger, move it aside (do not delete your project files) and re-run.

## "The pristine baseline for a managed file is missing"

Ownership is proved by comparing the target file byte for byte with its recorded
`pristine/<path>` copy. If that baseline is missing or unreadable, the toolkit cannot prove
anything about the file, so it **fails closed**: the run stops, and **your content is retained
untouched**. Nothing is overwritten and nothing is deleted. Recover by re-installing the same
release (which rewrites the baselines from the package) or by removing a file you are sure is
toolkit-owned, then re-run.

## "A path traverses a symlink / junction / reparse point"

The project (or the package) contains a link on the managed path. This is refused because a
write through a link can land outside the project. Typical causes: a OneDrive/`Documents`
junction, a symlinked `.agents`, or a redirected profile folder. Install into a real
directory, or replace the junction with a real directory, then retry.

## "The path is inside a VCS, runtime or credential directory and is denied"

Deny-by-default. A manifest listed something the toolkit refuses to touch (`.env`, key
material, `node_modules`, `.git`, ...). The package is wrong; report it rather than bypassing
the policy.

## "The user DSH Home is read-only / without a valid toolkit marker"

`-TeamDshHome` pointed at a directory that is not a toolkit-owned Team Home. The toolkit never
adopts, patches or reconfigures a real DSH Home. Use the default owned location
(`%LOCALAPPDATA%\CodexDshTeam\runtimes\<toolkit-install-id>\`) or point `-TeamDshHome` at a
directory that already carries a valid `.codex-dsh-team-home.json` marker.

## Uninstall kept some files

The plan lists them. Anything reported as `keep` was either modified by you, added by you or
untracked (for example `node_modules`). This is intentional. If a kept file is a genuine
toolkit leftover, the ledger still lists it together with its pristine baseline, so a later
uninstall run can remove it once the file is byte-identical to that baseline again.

A partial uninstall keeps everything needed for a later, honest re-proof: the ledger, the
`pristine/` baselines and the state directory's self-ignoring `.gitignore` all stay in place,
so the next run can still prove (or refuse) ownership instead of guessing.

## "Residual (cannot be removed while in use): CodexDshTeamToolkit.Uninstall.exe"

A running EXE cannot delete itself. The uninstaller reports this minimal residual, then
schedules its own deletion after it exits (a few seconds). Verify the file is gone a moment
later; if not, delete it manually. The toolkit never recursively deletes a directory to work
around this.

Because a minimal residual is still *provable*, the toolkit also keeps a tiny ownership record
(`.codex-dsh-team-toolkit/manifest.json`) listing it. Once the EXE is gone, either re-run the
uninstaller from a release package or delete that record by hand — it is the only file left,
and it is safe to remove at that point. Deleting it earlier would throw away the proof of what
the toolkit installed, so the toolkit will not do that for you.

## Building the thin uninstaller fails

`uninstaller/Build-Uninstaller.ps1` is fail-visible:

> Note: every `Build-*.ps1` / `Verify-*.ps1` command in this section is a **maintainer tool for a
> source checkout**. `tools/` and `tests/` are not shipped inside a release package, so these
> commands do not exist in an extracted release.

```
No C# compiler found; the thin uninstaller EXE cannot be built.
Prerequisites:
  * Windows with the .NET Framework 4.x installed (ships with Windows 10/11).
  * Expected compiler: %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
  * Or put csc.exe on PATH.
```

Install the .NET Framework (or desktop development features) and retry. `tools/Build-Release.ps1`
cannot produce a package while the EXE is missing, and it will not substitute a placeholder.

## `Build-Release.ps1` refuses because the payload is missing

The `payload/` directory holds the managed skill files. Populate it first, or
pass `-AllowMissingPayload` knowingly to produce an infrastructure-only package (the release
manifest will then only contain the engine and the uninstaller).

## `Build-Release.ps1` reports a content-scan hit

A high-confidence secret pattern was found in a text file **anywhere in the package** (not only
the payload). The build prints `path:line` and stops. Three options:

1. remove the value;
2. make the **matched value itself** self-identify as synthetic — the exception is applied to
   the matched value only, so a `fake`/`example`/`dummy`/`redacted` marker on another line does
   not exempt it;
3. allowlist the reviewed file explicitly, which is printed loudly and recorded in
   `dist/build-report.json`:

   ```powershell
   pwsh -File tools/Build-Release.ps1 -ContentScanAllowlist '.agents/skills/mcp-to-dsh/test/redaction.test.mjs'
   # several reviewed files: a comma-separated list works too
   pwsh -File tools/Build-Release.ps1 -ContentScanAllowlist 'path/one.test.mjs,path/two.test.mjs'
   ```

`-SkipContentScan` exists for maintainers but disables the check entirely — prefer the
allowlist. A fixed DSH home/version binding is a hard failure; fixed provider/model pinning is
reported for review.

## `Verify-Release.ps1` fails on a layout, scan or smuggled-path problem

The verifier checks the package **as a whole**. There is no checksum set to be inconsistent with
any more, so a failure means one of these:

- "required by the layout" → a file listed in `release/package-layout.json`
  (`releaseMustContain`) is missing;
- "Managed source is missing from the package" → the manifest lists a file that is not there;
- "must never be installed" / "outside the runtime layout" → a path was smuggled into the
  managed install set, which is fail-closed;
- "checksum artefact must never be packaged" → a `SHA256SUMS.txt` or `.sha256` sidecar was added
  to the package; the toolkit produces none and refuses to verify one;
- "case-folded duplicate" / "alternate data stream" / "Unsafe managed path" → a hostile zip
  entry was refused before anything was expanded, which is the intended behaviour.

Rebuild the package instead of editing it by hand.

## Antivirus / "Controlled folder access" blocks writes

The toolkit writes only inside the target project and the owned runtime root. A Windows
Controlled Folder Access policy can still block those writes; add the project folder to the
allowed list or install into a non-protected directory. The engine reports the failing path
(redacted) and rolls back.

## The project was moved

Nothing to do. Run the toolkit from the new location: the ledger is located from its own
position and describes the state directory layout only — no absolute path and no location
digest is ever persisted. A copied ledger in an unrelated project proves
nothing and removes nothing.

## A test-only feature is refused

Fault injection and transaction-evidence retention need **both** `-TestMode`/`-TestKeepTransaction`
and `CODEX_DSH_TOOLKIT_TEST=1` in the environment. The gate exists so a release install cannot be
steered into test behaviour by a stray command line. Only set it inside a test session.

## Collecting diagnostics for a report

```powershell
.\Install.cmd -Target "<project>" -PlanOnly        # includes the refusal reason and runs the full package preflight
Get-Content .\.codex-dsh-team-toolkit\install.log -Tail 50
Get-ChildItem .\.codex-dsh-team-toolkit\txn -Recurse -ErrorAction SilentlyContinue
```

Attach the redacted output plus the exit code. Never attach credentials, `settings.yaml`, a
full environment dump or unreviewed raw logs.
