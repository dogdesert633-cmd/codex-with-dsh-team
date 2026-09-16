# Team / Agent / Task Scheduler Contract

## Core model

The team is long-lived; Agents are long-lived team members; Tasks are short-lived work units; Attempts/Runs are execution evidence. Codex Coordinator owns the Task DAG and assignment.

## Team lifecycle

- User asks to form a team for a goal.
- Coordinator creates the Team.
- When the current goal is finished, Team enters `AWAITING_USER_ACCEPTANCE`.
- Team does **not** auto-dissolve when Tasks finish.
- The same Team may continue to accept follow-up work.
- Only an explicit user request to dissolve the Team ends and archives it.

## Agent Pool

- Coordinator creates Agents on demand according to current work.
- Multiple Agents may be created in the same scheduling round.
- Same-role growth policy is `capacity_aware_parallel_first`; there is no hardcoded single-Agent-per-role default.
- Respect user-defined role caps.
- Prefer reusing an existing compatible `IDLE` Agent.
- Do not create a new Worker for every Task.
- One Agent may execute at most one Active Task at a time.
- Completing a Task returns the Agent to `IDLE`; it does not terminate the Agent.
- Task completion, temporary lack of work, and `AWAITING_USER_ACCEPTANCE` never auto-retire an Agent.
- Agent identity and Session binding remain available for later compatible Tasks.
- Agent lifetime ends only on explicit user retirement/Team dissolve, or after Coordinator records a concrete assessment that the Agent has no reasonable future reuse.

Coordinator must not use “Task completed” or “no Ready Task right now” as a retirement justification. Valid Coordinator-driven retirement reasons are bounded: the role has left the remaining plan, the Agent is damaged and has been replaced, capacity must be reclaimed for a known need, or another concrete condition makes future reuse unreasonable.

## Capacity-aware parallel-first scheduling

Scheduling is parallel-first, not serial-by-default. `maxMembers` is a required Team parameter that Coordinator writes when creating the Team (a control-plane projection); this Skill introduces no new hardcoded default number. The member cap counts **all Team members that are not `TERMINATED`** — Running + Idle is the normal example, not an exhaustive list, so WAITING/RECOVERING/FALLBACK/FAILED also count — and it is not an active-Task count; user role caps are still honored. An existing but unused compatible Idle Agent counts as a free capacity slot that must be used before any new Agent is created.

Order:

1. **Fill every compatible Idle Agent** — give each compatible Idle Agent one Active Task and reuse its existing Session. Never leave an Idle compatible Agent unused while a compatible Ready Task waits, and never spawn a new Agent while a Ready Task can still be placed into a compatible Idle slot.
2. **Spawn same-role Agents in parallel** — start Phase 2 only after all compatible Idle slots are full and independent Ready Tasks still remain, and Team member capacity (`maxMembers`) and the user role cap still allow; then spawn additional same-role DSH Agents so those Tasks run in parallel.
3. **Wait only on capacity** — when `maxMembers` or the user role cap is exhausted, keep the remaining Tasks `READY`/`WAITING`. Do not unnecessarily serialize an independent Task behind a busy Agent.

All three safety gates must hold before Phase 2 spawns another Agent:

1. the Task is independently acceptable (own contract, own verdict — not a fragment of another Task);
2. write scopes do not conflict, or each Agent gets an isolated workspace;
3. never invent pseudo-Tasks merely to raise parallelism.

Real parallelism also never authorizes changing a role's configured model/provider, and never weakens role independence or the one-Active-Task-per-Agent rule.

Suggested Agent states:

`CREATED / IDLE / RUNNING / WAITING / RECOVERING / FALLBACK / FAILED / TERMINATED`

## Dynamic Task DAG

The DAG grows as work reveals new facts.

Only Codex Coordinator may:

- create Task;
- add/change dependencies;
- assign/reassign owner;
- create retry/recovery Task;
- cancel Task;
- mark current goal awaiting acceptance;
- dissolve Team.

DSH Agents may suggest new Tasks/dependencies but do not mutate the DAG themselves.

The user's Task DAG UI is read-only. User changes direction through natural-language instructions to Coordinator.

Suggested Task states:

`BLOCKED / READY / ASSIGNED / RUNNING / COMPLETED / FAILED / CANCELLED`

Minimum Task fields:

`task_id / title / status / owner_agent_id / dependencies[] / attempt_id / execution_type / result`

## Attempts / Runs

Each actual execution is an Attempt.

`Task -> Attempt -> Agent -> Session -> Turn/Run`

Retry, replacement, or configured-model fallback creates a new Attempt. Keep old Attempts as evidence. Use `task_id + attempt_id` fencing so late results from an obsolete attempt cannot overwrite a newer attempt.

## Simple event-driven scheduler

Do not use fixed frequent polling for assignment.

Any relevant Task/Agent state change triggers a scheduler pass:

- Task completed/failed/cancelled;
- Task created;
- dependency resolved;
- Agent became idle;
- Agent created;
- recovery/fallback changed availability.

Scheduler (`capacity_aware_parallel_first`):

- On every pass: collect all READY Tasks and all compatible IDLE Agents.
- **Phase 1** — Coordinator explicitly assigns one Active Task to every compatible IDLE Agent and reuses that Agent's Session. Never leave an Idle compatible Agent unused while a compatible Ready Task waits, and never spawn a new Agent while any Ready Task can still be placed into a compatible Idle slot.
- **Phase 2** — only after all compatible Idle slots are full, and while independent READY Tasks remain and `maxMembers` / the user role cap still allow, create additional same-role Agents and assign those Tasks in parallel. All three safety gates must hold: independently acceptable Task; non-conflicting write scope or an isolated workspace; no invented pseudo-Tasks.
- **Phase 3** — if capacity is exhausted, leave the remaining Tasks `READY`/`WAITING`; do not queue an independent Task behind a busy Agent merely to avoid creating an Agent.
- An Agent with no compatible Task stays `IDLE`; it is never retired or spawned-around gratuitously.

**Reviewer parallel growth**: multiple independent changes may await review; when existing Reviewer slots are already occupied and the role cap still has room, Coordinator may create an additional same-role Reviewer (new `agent_id` -> new DSH session). Reviewer independence boundaries do not change: still no Coder private transcript, still an independent read-only/disposable workspace, still an independent verdict.

For the next version, keep scheduling deliberately simple and predictable. Do **not** implement critical-path prediction, context-affinity scoring, resource reservation, global optimization, autonomous Agent task claiming, or automatic priority inference.

## UI semantics for the future Monitor

- `Agents` view: who is in the Team, current state, current Task, ongoing multi-turn conversation.
- `Tasks` view: read-only dynamic Task DAG, dependencies, owner, Attempt, result/recovery.
- User must not see Assign/Reassign/Edit Dependency/Create Task controls.

## Acceptance

The future implementation should prove:

1. user-created Team persists after current Tasks complete;
2. multiple Agents can be created in one round;
3. Task completion returns Agent to IDLE;
4. later Tasks can reuse the same Agent/session;
5. DAG can grow dynamically;
6. Coordinator is the only assignment authority;
7. UI DAG is read-only;
8. one Agent has at most one Active Task;
9. Task/Agent state changes trigger immediate simple scheduling;
10. current goal completion enters `AWAITING_USER_ACCEPTANCE`;
11. completed/idle Agents remain in the pool and keep their Session binding;
12. no Agent is retired merely because its Task completed or no immediate work exists;
13. Coordinator-driven retirement includes an explicit no-future-reuse reason;
14. only explicit user dissolve archives the Team;
15. Phase 1 leaves no compatible Idle Agent unused while a compatible Ready Task waits, and never spawns an Agent while a Ready Task can still fill a compatible Idle slot;
16. Phase 2 starts only after all compatible Idle slots are full, and then only when the three safety gates hold and `maxMembers` / role caps still have room;
17. Phase 3 keeps independent Tasks `READY`/`WAITING` on exhausted capacity instead of queueing them behind a busy Agent;
18. `maxMembers` comes from the required Team parameter that Coordinator writes at Team creation, has no new hardcoded default, and counts all Team members that are not `TERMINATED` (Running + Idle is the normal example, not an exhaustive state list) rather than active Tasks.
