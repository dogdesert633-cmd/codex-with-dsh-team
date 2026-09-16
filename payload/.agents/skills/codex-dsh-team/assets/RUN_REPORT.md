# Codex × DSH Team Run — <RUN-ID>

> 本报告正文由 DSH Progress Recorder / Reporter 基于机器证据生成；Codex Final Gate 负责核验。

## Verdict

`PASS | BLOCKED_INFRASTRUCTURE | DECOMPOSITION_FAILURE | IMPLEMENTATION_FAILURE | REVIEW_FAILURE | VALIDATION_FAILURE | ATTRIBUTION_INVALID`

## Agent lifecycle

| Agent ID | Role | DSH Session | Turns/Runs | Final state |
|---|---|---|---|---|

## Team and routing

- DSH Explorer agents/sessions:
- DSH Coder agents/sessions:
- DSH Tester agents/sessions:
- DSH Reviewer agents/sessions:
- DSH Reporter agent/session:
- Codex direct project-code edits (must be 0):

## Work packages

| WP | Agent ID | Lifecycle action | Session | Turn/Run | Attempts | Final |
|---|---|---|---|---|---:|---|

## Delegation / attribution

- DSH-executed code WPs / total:
- DSH-attributed target LOC / total:
- DSH-authored test/tool LOC:
- First-attempt successes / retries:

## Timing

| Phase | Duration ms | Machine evidence |
|---|---:|---|

## Reviews

- Reviewer verdict:
- Reviewer independent agent/session evidence:
- Findings routed to Coder:
- Review contamination:

## Reporting evidence

- Reporter source evidence:
- Missing/unknown machine facts:
- Report paths written by DSH Reporter:

## Final Gate

- Acceptance:
- Scope:
- Attribution:
- Remaining risks:
- Recommended next step:


## DSH recovery / fallback

| Role / Agent | Initial backend | Failure / Stop code | DSH local retry | Coordinator recovery | Attempts | Final backend | Final verdict |
|---|---|---|---:|---|---:|---|---|

- DSH failure episodes:
- DSH Stop-and-Return episodes:
- Native crash / uncontrolled-process stops:
- Parameter-fishing violations (must be 0):
- Unverified candidate incorrectly reported as PASS (must be 0):
- configured-model fallback count:
- Roles completed by configured-model:
- DSH role success rate:
- Fallback rate:

若使用 fallback，必须明确：

`model = <team-configured-fallback-model>`
`reasoning = medium`

## Team / Task DAG

- Team ID:
- Team final state:
- Awaiting user acceptance:
- Dissolved only after explicit user request:
- Agent pool:
- Role caps:

| Task | Status | Dependencies | Owner Agent | Attempt | Execution type | Backend |
|---|---|---|---|---|---|---|

## Scheduler

- Scheduler mode: `event_driven_simple`
- Scheduler runs:
- Idle Agent reuse:
- New agents created for parallel work:
- Tasks kept Ready due to cap:
- User direct Task assignment edits (must be 0):

## Capability routing

- DSH normal/non-visual tasks:
- Codex long-wait tasks:
- Codex visual tasks:
- Visual tasks incorrectly sent to DSH (must be 0):
- Long-wait tasks incorrectly sent to DSH (must be 0):

## Polling

- Minimum silence-before-check: 120s
- High-frequency polling violations:
- Events reset silence timer:


## DSH permission propagation

- Required execution mode: `full_access`
- Effective mode verified:
- Spawn propagation:
- Resume/follow-up propagation:
- Replacement propagation:
- Silent downgrade count (must be 0):
- Permission propagation failures:

Full Access 不改变角色/Work Package 的逻辑授权边界。


## DSH Context efficiency

- Scope: `DSH-backed roles only`

- Context mode: `bounded`
- Initial primary files:
- Extra files read:
- Full-file reads:
- Targeted symbol/range reads:
- Broad repo scan used:
- Context escalations:
- Tasks re-decomposed to reduce context:
- Repeated unchanged-file reads:

## Tester / Reviewer backend

- Tester backend: `Codex child / <team-configured-fallback-model> / medium`
- Tester session:
- Long-wait validation handled by Tester:
- Reviewer backend: `DSH`
- Reviewer scope: `change_scoped | broadened`
- Candidate diff reviewed:
- Changed files reviewed:
- One-hop related files reviewed:
- Review broadened:
- Broadening reason:
- Full-repo review used:
