import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { request as httpRequest } from "node:http";
import { connect } from "node:net";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createMonitorServer } from "../src/server.mjs";

const TOKEN = "test-monitor-token";
const CONTRACT = "只读探测合同：不要修改任何文件。";

// --- monitor lifecycle isolation ------------------------------------------------
//
// Every monitor this file creates is tracked, because a `node:test` file only exits when no
// handle is left open: one failed assertion *before* a manual `await monitor.close()` used to
// strand a listening socket, and the whole file then hung until it was killed from outside.
//
// Two layers, both idempotent (`close()` resolves the same promise on every call):
//   * per-test `context.after` registration in `startMonitor` (runs on failure too),
//   * a file-level net that closes anything still tracked.
// The explicit closes inside individual tests keep their meaning — they are what the
// shutdown/lease assertions observe.
const trackedMonitors = new Set();

function createMonitorForTest(options) {
  const monitor = createMonitorServer(options);
  trackedMonitors.add(monitor);
  return monitor;
}

/** Register an idempotent close so a failing assertion can never leak a listening monitor. */
function closeMonitorAfter(context, monitor) {
  context.after(async () => {
    await monitor.close().catch(() => {});
  });
  return monitor;
}

test.after(async () => {
  await Promise.all([...trackedMonitors].map((monitor) => monitor.close().catch(() => {})));
  trackedMonitors.clear();
});

// Deterministic bridge double. DSH itself is not launched in unit tests; the seam only
// replaces process launch, while the monitor still owns artifacts, registry and projection.
function createFakeBridge() {
  let sessionCounter = 0;
  const calls = [];
  const nextSession = () => `session-${String(++sessionCounter).padStart(3, "0")}`;
  const spawnBridge = (args, spawnOptions, context) => {
    const artifactDir = args[args.indexOf("--artifact-dir") + 1];
    const resumeIndex = args.indexOf("--resume");
    const resume = resumeIndex === -1 ? null : args[resumeIndex + 1];
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.exitCode = null;
    child.kill = () => {
      if (child.exitCode === null) {
        child.exitCode = 1;
        child.emit("close", 1, null);
      }
      return true;
    };
    const call = {
      args,
      artifactDir,
      resume,
      context,
      env: spawnOptions?.env ?? null,
      child,
      async finish({ sessionId, exitCode = 0, emitSession = true } = {}) {
        const reported = sessionId === undefined ? (resume ?? nextSession()) : sessionId;
        await mkdir(artifactDir, { recursive: true });
        const lines = [];
        if (emitSession && reported) {
          lines.push({ ts: new Date().toISOString(), source: "dsh", kind: "initialized", response: { protocolVersion: 1 } });
          lines.push({
            ts: new Date().toISOString(),
            source: "dsh",
            kind: resume ? "session_resumed" : "session_created",
            sessionId: reported,
            response: { configOptions: [{ id: "reasoning_effort", currentValue: "high" }] },
          });
          const providerIndex = args.indexOf("--model-provider");
          const modelIndex = args.indexOf("--model");
          if (providerIndex !== -1 && modelIndex !== -1) {
            const selection = { provider: args[providerIndex + 1], model: args[modelIndex + 1] };
            lines.push({
              ts: new Date().toISOString(),
              source: "bridge",
              kind: "session_model_configured",
              sessionId: reported,
              configId: "model",
              selection,
              value: JSON.stringify([selection.provider, selection.model]),
              response: { configOptions: [{ id: "model", currentValue: JSON.stringify([selection.provider, selection.model]) }] },
            });
          }
        }
        lines.push({ ts: new Date().toISOString(), source: "codex", kind: "delegated_prompt", sessionId: reported, turn: 1, text: `${context.agentId} task` });
        lines.push({
          ts: new Date().toISOString(),
          source: "dsh",
          kind: "session_update",
          sessionId: reported,
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "done" } },
        });
        lines.push({ ts: new Date().toISOString(), source: "dsh", kind: "turn_stop", sessionId: reported, response: { stopReason: "end_turn" } });
        await writeFile(join(artifactDir, "events.jsonl"), `${lines.map((line) => JSON.stringify(line)).join("\n")}\n`, "utf8");
        await writeFile(
          join(artifactDir, "session-summary.json"),
          `${JSON.stringify({ schema_version: 1, session_id: reported, resumed: Boolean(resume), turns: 1, bridge_error: null })}\n`,
          "utf8",
        );
        child.exitCode = exitCode;
        child.emit("close", exitCode, null);
      },
    };
    calls.push(call);
    return child;
  };
  return { spawnBridge, calls, nextSession };
}

function post(origin, path, payload) {
  return fetch(`${origin}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN },
    body: JSON.stringify(payload),
  });
}

function dispatch(origin, payload) {
  return post(origin, "/api/runs", { contractText: CONTRACT, ...payload });
}

async function dispatchJson(origin, payload) {
  const response = await dispatch(origin, payload);
  return { status: response.status, body: await response.json() };
}

async function runs(origin) {
  const response = await fetch(`${origin}/api/runs`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  assert.equal(response.status, 200);
  return response.json();
}

// --- vNext control-plane helpers ----------------------------------------------

function send(origin, method, path, payload) {
  const options = { method, headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN } };
  if (payload !== undefined) options.body = JSON.stringify(payload);
  return fetch(`${origin}${path}`, options);
}

async function createTeam(origin, payload) {
  const response = await send(origin, "POST", "/api/teams", payload);
  return { status: response.status, body: await response.json() };
}

async function patchTeam(origin, teamId, payload) {
  const response = await send(origin, "PATCH", `/api/teams/${encodeURIComponent(teamId)}`, payload);
  return { status: response.status, body: await response.json() };
}

async function createTask(origin, payload) {
  const response = await send(origin, "POST", "/api/tasks", payload);
  return { status: response.status, body: await response.json() };
}

async function patchTask(origin, taskId, payload) {
  const response = await send(origin, "PATCH", `/api/tasks/${encodeURIComponent(taskId)}`, payload);
  return { status: response.status, body: await response.json() };
}

async function registerAgent(origin, payload) {
  const response = await send(origin, "POST", "/api/agents", payload);
  return { status: response.status, body: await response.json() };
}

async function patchAgent(origin, agentId, payload) {
  const response = await send(origin, "PATCH", `/api/agents/${encodeURIComponent(agentId)}`, payload);
  return { status: response.status, body: await response.json() };
}

async function teams(origin) {
  const response = await fetch(`${origin}/api/teams`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  assert.equal(response.status, 200);
  return response.json();
}

async function tasks(origin) {
  const response = await fetch(`${origin}/api/tasks`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  assert.equal(response.status, 200);
  return response.json();
}

async function waitForTask(origin, taskId, statuses, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const projection = await tasks(origin);
    const task = projection.tasks.find((item) => item.taskId === taskId);
    if (task && statuses.includes(task.status)) return task;
    if (Date.now() > deadline) throw new Error(`timeout waiting for task ${taskId} ${statuses}; current=${task?.status}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function waitForAgentState(origin, agentId, states, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const projection = await runs(origin);
    const agent = projection.agents.find((item) => item.agentId === agentId);
    if (agent && states.includes(agent.state)) return agent;
    if (Date.now() > deadline) throw new Error(`timeout waiting for agent ${agentId} ${states}; current=${agent?.state}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function waitForStatus(monitor, runId, statuses, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const run = monitor.runs.get(runId);
    if (run && statuses.includes(run.status)) return run;
    if (Date.now() > deadline) throw new Error(`timeout waiting for ${statuses}; current=${run?.status}`);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
}

async function startMonitor(context, { workspace, spawnBridge, ...serverOptions } = {}) {
  const root = workspace ?? await mkdtemp(join(tmpdir(), "dsh-agent-test-"));
  const monitor = createMonitorForTest({ workspace: root, dshHome: root, port: 0, token: TOKEN, spawnBridge, ...serverOptions });
  // Registered BEFORE start() and for the caller-supplied-workspace branch too: a failure in
  // `start()` or in any assertion can no longer strand the monitor's listening socket.
  // Close runs before the workspace removal below because hooks run in registration order.
  closeMonitorAfter(context, monitor);
  if (!workspace) {
    context.after(() => rm(root, { recursive: true, force: true }));
  }
  const address = await monitor.start();
  return { workspace: root, monitor, origin: `http://127.0.0.1:${address.port}` };
}

// --- lease / shutdown doubles -------------------------------------------------

function spawnExitedPid() {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(process.execPath, ["-e", "process.exit(0)"], { stdio: "ignore" });
    child.on("error", reject);
    child.on("exit", () => resolvePromise(child.pid));
  });
}

// A bridge double whose close timing is fully controlled by the test, so shutdown
// finalization and SIGTERM/SIGKILL escalation can be exercised deterministically.
function createControlledBridge({ closeOn = null, closeDelayMs = 0, sessionId = "shutdown-session-1" } = {}) {
  const calls = [];
  const spawnBridge = (args, _spawnOptions, _context) => {
    const artifactDir = args[args.indexOf("--artifact-dir") + 1];
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.exitCode = null;
    child.signalCode = null;
    let closed = false;
    const call = {
      child,
      artifactDir,
      signals: [],
      async closeAfter(delayMs, code = 0, signal = null) {
        await new Promise((resolvePromise) => setTimeout(resolvePromise, delayMs));
        if (closed) return;
        closed = true;
        await mkdir(artifactDir, { recursive: true });
        await writeFile(
          join(artifactDir, "events.jsonl"),
          `${JSON.stringify({ ts: new Date().toISOString(), source: "dsh", kind: "session_created", sessionId, response: {} })}\n`,
          "utf8",
        );
        await writeFile(
          join(artifactDir, "session-summary.json"),
          `${JSON.stringify({ schema_version: 1, session_id: sessionId, turns: 1, bridge_error: null })}\n`,
          "utf8",
        );
        child.exitCode = code;
        child.signalCode = signal;
        child.emit("close", code, signal);
      },
    };
    child.kill = (signal) => {
      call.signals.push(signal ?? "SIGTERM");
      if (closeOn && signal === closeOn) void call.closeAfter(closeDelayMs, 1, signal);
      return true;
    };
    calls.push(call);
    return child;
  };
  return { spawnBridge, calls };
}

test("serves the monitor and health endpoint on loopback", async (context) => {
  const { origin } = await startMonitor(context);

  const health = await fetch(`${origin}/api/health`).then((response) => response.json());
  assert.equal(health.ok, true);
  assert.equal(health.service, "dsh-team-monitor");
  assert.equal(health.agentRegistry.schemaVersion, 1);

  const page = await fetch(origin).then((response) => response.text());
  assert.match(page, /DSH Team Monitor/);
  assert.match(page, /DSH 子智能体/);
  assert.match(page, /agent-detail/);
  assert.match(page, /type="module" src="\/app\.js"/);
  const revisionModule = await fetch(`${origin}/model-revision.js`);
  assert.equal(revisionModule.status, 200);
  assert.match(revisionModule.headers.get("content-type"), /text\/javascript/);
  assert.match(await revisionModule.text(), /shouldAcceptModelProjection/);

  const projection = await runs(origin);
  assert.deepEqual(projection.runs, []);
  assert.deepEqual(projection.agents, []);
});

test("rejects an invalid dispatch contract", async (context) => {
  const { origin } = await startMonitor(context);
  const response = await post(origin, "/api/runs", { role: "worker", contractText: "" });
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /contractText/);
});

test("rejects unauthorised dispatch and a workspace outside the monitor project", async (context) => {
  const { origin } = await startMonitor(context);
  const otherWorkspace = await mkdtemp(join(tmpdir(), "dsh-monitor-other-"));
  context.after(() => rm(otherWorkspace, { recursive: true, force: true }));

  const unauthorized = await fetch(`${origin}/api/runs`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ role: "worker", contractText: "read only" }),
  });
  assert.equal(unauthorized.status, 403);

  const outside = await dispatch(origin, { workspace: otherWorkspace, agentId: "A1", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(outside.status, 400);
  assert.match((await outside.json()).error, /监视器启动项目一致/);
});

test("spawn creates a new session binding and turn 1 without resuming anything", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  const spawned = await dispatchJson(origin, {
    agentId: "AGENT-CODER-001",
    formalRole: "coder",
    lifecycleAction: "spawn",
    taskId: "WP-001",
    title: "DSH Coder · WP-001",
  });
  assert.equal(spawned.status, 202);
  assert.equal(spawned.body.agentId, "AGENT-CODER-001");
  assert.equal(spawned.body.formalRole, "coder");
  assert.equal(spawned.body.formalRoleLabel, "Coder");
  assert.equal(spawned.body.lifecycleAction, "spawn");
  assert.equal(spawned.body.turnIndex, 1);
  assert.equal(spawned.body.runId, spawned.body.id);
  assert.equal(fake.calls[0].resume, null);
  assert.equal(fake.calls[0].args.includes("--resume"), false);

  await fake.calls[0].finish({ sessionId: "11111111-1111-1111-1111-111111111111" });
  const settled = await waitForStatus(monitor, spawned.body.id, ["completed"]);
  assert.equal(settled.status, "completed");
  assert.equal(settled.turnIndex, 1);
  assert.equal(settled.sessionId, "11111111-1111-1111-1111-111111111111");

  const projection = await runs(origin);
  assert.equal(projection.agents.length, 1);
  const agent = projection.agents[0];
  assert.equal(agent.agentId, "AGENT-CODER-001");
  assert.equal(agent.bound, true);
  assert.equal(agent.sessionId, "11111111-1111-1111-1111-111111111111");
  assert.equal(agent.turnCount, 1);
  assert.deepEqual(agent.turns.map((turn) => turn.turnIndex), [1]);
  assert.equal(agent.latestTaskId, "WP-001");
});

test("follow_up resumes the bound session as turn 2 and never creates a new session", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  const base = { agentId: "AGENT-CODER-001", formalRole: "coder" };

  const first = await dispatchJson(origin, { ...base, lifecycleAction: "spawn", taskId: "WP-001" });
  await fake.calls[0].finish({ sessionId: "22222222-2222-2222-2222-222222222222" });
  await waitForStatus(monitor, first.body.id, ["completed"]);

  const second = await dispatchJson(origin, { ...base, lifecycleAction: "follow_up", taskId: "WP-001-FIX" });
  assert.equal(second.status, 202);
  assert.equal(second.body.lifecycleAction, "follow_up");
  assert.equal(second.body.turnIndex, 2);
  assert.equal(second.body.sessionId, "22222222-2222-2222-2222-222222222222");
  assert.notEqual(second.body.id, first.body.id);
  assert.equal(fake.calls[1].resume, "22222222-2222-2222-2222-222222222222");
  assert.equal(fake.calls[1].args[fake.calls[1].args.indexOf("--resume") + 1], "22222222-2222-2222-2222-222222222222");

  await fake.calls[1].finish();
  await waitForStatus(monitor, second.body.id, ["completed"]);

  const projection = await runs(origin);
  const agent = projection.agents.find((item) => item.agentId === "AGENT-CODER-001");
  assert.equal(agent.turnCount, 2);
  assert.equal(agent.sessionId, "22222222-2222-2222-2222-222222222222");
  assert.deepEqual(agent.turns.map((turn) => turn.turnIndex), [1, 2]);
  assert.deepEqual(agent.turns.map((turn) => turn.lifecycleAction), ["spawn", "follow_up"]);
  assert.equal(new Set(agent.turns.map((turn) => turn.runId)).size, 2);
});

// --- Team full-access permission mode -----------------------------------------

test("spawn and follow_up dispatch the DSH child with the Team full-access permission mode", async (context) => {
  const fake = createFakeBridge();
  const { workspace, monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  const sessionId = "99999999-0000-0000-0000-000000000009";
  const base = { agentId: "AGENT-FULL-ACCESS", formalRole: "coder" };

  const spawned = await dispatchJson(origin, { ...base, lifecycleAction: "spawn" });
  assert.equal(spawned.status, 202);
  // DSH's dsh-base bundle reads this override to pin sandbox danger-full-access + approval never.
  assert.equal(fake.calls[0].env.DSH_PERMISSION_MODE, "danger-full-access");
  assert.equal(fake.calls[0].env.DSH_HOME, workspace);

  await fake.calls[0].finish({ sessionId });
  await waitForStatus(monitor, spawned.body.id, ["completed"]);

  const followUp = await dispatchJson(origin, { ...base, lifecycleAction: "follow_up" });
  assert.equal(followUp.status, 202);
  assert.equal(followUp.body.sessionId, sessionId);
  assert.equal(fake.calls[1].resume, sessionId);
  // follow_up shares the exact same child-environment semantics as spawn.
  assert.equal(fake.calls[1].env.DSH_PERMISSION_MODE, "danger-full-access");
  assert.equal(fake.calls[1].env.DSH_HOME, workspace);
  await fake.calls[1].finish();
  await waitForStatus(monitor, followUp.body.id, ["completed"]);
});

test("an inherited parent DSH_PERMISSION_MODE never silently downgrades the Team default", async (context) => {
  const previous = process.env.DSH_PERMISSION_MODE;
  process.env.DSH_PERMISSION_MODE = "workspace-write";
  context.after(() => {
    if (previous === undefined) delete process.env.DSH_PERMISSION_MODE;
    else process.env.DSH_PERMISSION_MODE = previous;
  });

  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  const spawned = await dispatchJson(origin, { agentId: "AGENT-INHERITED-MODE", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(spawned.status, 202);
  assert.equal(process.env.DSH_PERMISSION_MODE, "workspace-write");
  assert.equal(fake.calls[0].env.DSH_PERMISSION_MODE, "danger-full-access");
  await fake.calls[0].finish();
  await waitForStatus(monitor, spawned.body.id, ["completed"]);
});

test("the permissionMode seam stays the single source of truth for the child environment", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge, permissionMode: "read-only" });
  const spawned = await dispatchJson(origin, { agentId: "AGENT-SEAM-MODE", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(spawned.status, 202);
  assert.equal(fake.calls[0].env.DSH_PERMISSION_MODE, "read-only");
  await fake.calls[0].finish();
  await waitForStatus(monitor, spawned.body.id, ["completed"]);
});

test("allowTools keeps its compatibility argv semantics without touching the permission mode", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  const withTools = await dispatchJson(origin, { agentId: "AGENT-TOOLS-DEFAULT", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(withTools.status, 202);
  assert.equal(fake.calls[0].args.filter((arg) => arg === "--allow-tools").length, 1, "the default still appends --allow-tools exactly once");
  await fake.calls[0].finish();
  await waitForStatus(monitor, withTools.body.id, ["completed"]);

  const withoutTools = await dispatchJson(origin, {
    agentId: "AGENT-TOOLS-DENIED",
    formalRole: "coder",
    lifecycleAction: "spawn",
    allowTools: false,
  });
  assert.equal(withoutTools.status, 202);
  assert.equal(fake.calls[1].args.includes("--allow-tools"), false);
  assert.equal(fake.calls[1].env.DSH_PERMISSION_MODE, "danger-full-access", "the permission preset is independent of the allowTools flag");
  await fake.calls[1].finish();
  await waitForStatus(monitor, withoutTools.body.id, ["completed"]);
});

test("a new agent gets its own session and the caller can never inject a session", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  const coder = await dispatchJson(origin, { agentId: "AGENT-CODER-001", formalRole: "coder", lifecycleAction: "spawn" });
  await fake.calls[0].finish({ sessionId: "aaaaaaa1-0000-0000-0000-000000000001" });
  await waitForStatus(monitor, coder.body.id, ["completed"]);

  const tester = await dispatchJson(origin, { agentId: "AGENT-TESTER-001", formalRole: "tester", lifecycleAction: "spawn" });
  await fake.calls[1].finish({ sessionId: "bbbbbbb2-0000-0000-0000-000000000002" });
  await waitForStatus(monitor, tester.body.id, ["completed"]);

  assert.equal(fake.calls[1].resume, null);
  const projection = await runs(origin);
  const sessions = projection.agents.map((agent) => agent.sessionId);
  assert.equal(new Set(sessions).size, 2);
  assert.deepEqual(projection.agents.map((agent) => agent.formalRole).sort(), ["coder", "tester"]);

  const spoof = await dispatchJson(origin, {
    agentId: "AGENT-CODER-001",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    resumeSessionId: "bbbbbbb2-0000-0000-0000-000000000002",
  });
  assert.equal(spoof.status, 400);
  assert.match(spoof.body.error, /resumeSessionId/);

  // The spoof must not have created an extra run or rebound the agent.
  const after = await runs(origin);
  assert.equal(after.runs.length, 2);
  assert.equal(after.agents.find((agent) => agent.agentId === "AGENT-CODER-001").turnCount, 1);

  // Even when DSH itself reports a foreign session, the monitor refuses to steal it.
  const thief = await dispatchJson(origin, { agentId: "AGENT-THIEF-001", formalRole: "coder", lifecycleAction: "spawn" });
  await fake.calls[2].finish({ sessionId: "aaaaaaa1-0000-0000-0000-000000000001", exitCode: 1 });
  const stolen = await waitForStatus(monitor, thief.body.id, ["failed"]);
  assert.equal(stolen.phase, "binding_mismatch");
  assert.match(stolen.error, /已绑定到 agent AGENT-CODER-001/);
  const guarded = await runs(origin);
  assert.equal(guarded.agents.find((agent) => agent.agentId === "AGENT-THIEF-001").sessionId, null);
  assert.equal(guarded.agents.find((agent) => agent.agentId === "AGENT-CODER-001").sessionId, "aaaaaaa1-0000-0000-0000-000000000001");
});

test("lifecycle violations are rejected deterministically", async (context) => {
  const fake = createFakeBridge();
  const { workspace, monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  // Legacy transport vocabulary is refused: agent identity is now explicit.
  const legacyRole = await dispatchJson(origin, { role: "worker", agentId: "AGENT-A", lifecycleAction: "spawn" });
  assert.equal(legacyRole.status, 400);
  assert.match(legacyRole.body.error, /formalRole/);

  const noAgent = await dispatchJson(origin, { role: "worker", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(noAgent.status, 400);
  assert.match(noAgent.body.error, /agentId/);

  const badAction = await dispatchJson(origin, { agentId: "AGENT-A", formalRole: "coder", lifecycleAction: "terminate" });
  assert.equal(badAction.status, 400);
  assert.match(badAction.body.error, /lifecycleAction/);

  const first = await dispatchJson(origin, { agentId: "AGENT-A", formalRole: "coder", lifecycleAction: "spawn" });

  const duplicate = await dispatchJson(origin, { agentId: "AGENT-A", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(duplicate.status, 400);
  assert.match(duplicate.body.error, /重复 spawn/);
  assert.equal(monitor.runs.size, 1);

  const conflict = await dispatchJson(origin, { agentId: "AGENT-A", formalRole: "coder", lifecycleAction: "follow_up" });
  assert.equal(conflict.status, 400);
  assert.match(conflict.body.error, /活跃 turn/);

  const unknown = await dispatchJson(origin, { agentId: "AGENT-MISSING", formalRole: "coder", lifecycleAction: "follow_up" });
  assert.equal(unknown.status, 400);
  assert.match(unknown.body.error, /未知 agent/);

  await fake.calls[0].finish({ sessionId: "ccccccc3-0000-0000-0000-000000000003" });
  await waitForStatus(monitor, first.body.id, ["completed"]);

  const roleDrift = await dispatchJson(origin, { agentId: "AGENT-A", formalRole: "tester", lifecycleAction: "follow_up" });
  assert.equal(roleDrift.status, 400);
  assert.match(roleDrift.body.error, /formalRole.*不一致/);

  // A spawn that never established a session has no binding: follow_up must fail, not guess.
  const unbound = await dispatchJson(origin, { agentId: "AGENT-NOSESSION", formalRole: "coder", lifecycleAction: "spawn" });
  await fake.calls[1].finish({ sessionId: null, exitCode: 1, emitSession: false });
  const unboundRun = await waitForStatus(monitor, unbound.body.id, ["failed"]);
  assert.equal(unboundRun.sessionId, null);
  const unboundFollowUp = await dispatchJson(origin, { agentId: "AGENT-NOSESSION", formalRole: "coder", lifecycleAction: "follow_up" });
  assert.equal(unboundFollowUp.status, 400);
  assert.match(unboundFollowUp.body.error, /没有可 resume 的 session binding/);

  // The registry holds no credential material.
  const registryText = await readFile(join(workspace, "artifacts", "dsh-monitor", "agent-registry.json"), "utf8");
  assert.equal(registryText.includes("access_token"), false);
  assert.equal(registryText.includes(TOKEN), false);
  assert.equal(registryText.includes("password"), false);
});

test("cancel stays available for the active turn and leaves the agent reusable", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  const spawned = await dispatchJson(origin, { agentId: "AGENT-CODER-002", formalRole: "coder", lifecycleAction: "spawn" });
  const cancelled = await post(origin, `/api/runs/${encodeURIComponent(spawned.body.id)}/cancel`, {});
  assert.equal(cancelled.status, 200);
  assert.equal((await cancelled.json()).status, "cancelling");

  await fake.calls[0].finish({ sessionId: "ddddddd4-0000-0000-0000-000000000004", exitCode: 1 });
  const settled = await waitForStatus(monitor, spawned.body.id, ["cancelled"]);
  assert.equal(settled.status, "cancelled");

  // Cancelling a turn does not terminate the child agent: follow_up still resumes its session.
  const followUp = await dispatchJson(origin, { agentId: "AGENT-CODER-002", formalRole: "coder", lifecycleAction: "follow_up" });
  assert.equal(followUp.status, 202);
  assert.equal(followUp.body.turnIndex, 2);
  assert.equal(fake.calls[1].resume, "ddddddd4-0000-0000-0000-000000000004");
  await fake.calls[1].finish();
  await waitForStatus(monitor, followUp.body.id, ["completed"]);

  const terminal = await post(origin, `/api/runs/${encodeURIComponent(followUp.body.id)}/cancel`, {});
  assert.equal(terminal.status, 400);
  assert.match((await terminal.json()).error, /不可取消/);
});

test("a bridge launch failure is recorded as evidence instead of a silent turn skip", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-agent-launch-"));
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: () => {
      throw new Error("spawn EPERM");
    },
  });
  context.after(async () => {
    await monitor.close();
    await rm(workspace, { recursive: true, force: true });
  });
  const address = await monitor.start();
  const origin = `http://127.0.0.1:${address.port}`;

  const failed = await dispatchJson(origin, { agentId: "AGENT-FAILED-001", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(failed.status, 202);
  assert.equal(failed.body.status, "failed");
  assert.equal(failed.body.phase, "launch_failed");
  assert.match(failed.body.error, /spawn EPERM/);
  assert.equal(failed.body.turnIndex, 1);

  const stored = JSON.parse(
    await readFile(join(workspace, "artifacts", "dsh-gui-runs", failed.body.id, "monitor-run.json"), "utf8"),
  );
  assert.equal(stored.status, "failed");
  assert.equal(stored.agentId, "AGENT-FAILED-001");
  assert.equal(stored.turnIndex, 1);

  // The identity stays reserved: replace it with a new agentId rather than reusing it.
  const duplicate = await dispatchJson(origin, { agentId: "AGENT-FAILED-001", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(duplicate.status, 400);
  const followUp = await dispatchJson(origin, { agentId: "AGENT-FAILED-001", formalRole: "coder", lifecycleAction: "follow_up" });
  assert.equal(followUp.status, 400);
  assert.match(followUp.body.error, /没有可 resume 的 session binding/);
});

test("agent bindings and turn indices survive a monitor restart", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-agent-restart-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));

  const firstFake = createFakeBridge();
  const first = await startMonitor(context, { workspace, spawnBridge: firstFake.spawnBridge });
  const spawned = await dispatchJson(first.origin, { agentId: "AGENT-REVIEWER-001", formalRole: "code_reviewer", lifecycleAction: "spawn", taskId: "REV-001" });
  await firstFake.calls[0].finish({ sessionId: "fffffff6-0000-0000-0000-000000000006" });
  await waitForStatus(first.monitor, spawned.body.id, ["completed"]);
  await first.monitor.close();

  // Restart on the same workspace with a fresh bridge double.
  const secondFake = createFakeBridge();
  const second = await startMonitor(context, { workspace, spawnBridge: secondFake.spawnBridge });

  const restored = await runs(second.origin);
  assert.equal(restored.runs.length, 1);
  assert.equal(restored.runs[0].status, "completed");
  assert.equal(restored.runs[0].agentId, "AGENT-REVIEWER-001");
  assert.equal(restored.runs[0].turnIndex, 1);
  assert.equal(restored.agents.length, 1);
  assert.equal(restored.agents[0].sessionId, "fffffff6-0000-0000-0000-000000000006");
  assert.deepEqual(restored.agents[0].turns.map((turn) => turn.turnIndex), [1]);

  // The restored binding drives the next resume, and the turn index stays monotonic.
  const followUp = await dispatchJson(second.origin, { agentId: "AGENT-REVIEWER-001", formalRole: "code_reviewer", lifecycleAction: "follow_up" });
  assert.equal(followUp.status, 202);
  assert.equal(followUp.body.turnIndex, 2);
  assert.equal(secondFake.calls[0].resume, "fffffff6-0000-0000-0000-000000000006");
  await secondFake.calls[0].finish();
  await waitForStatus(second.monitor, followUp.body.id, ["completed"]);

  const after = await runs(second.origin);
  assert.deepEqual(after.agents[0].turns.map((turn) => turn.turnIndex), [1, 2]);
  assert.equal(after.agents[0].sessionId, "fffffff6-0000-0000-0000-000000000006");
  await second.monitor.close();
});

test("SSE snapshot and /api/runs expose the Agent aggregation projection", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  const spawned = await dispatchJson(origin, { agentId: "AGENT-EXPLORER-001", formalRole: "code_explorer", lifecycleAction: "spawn" });
  await fake.calls[0].finish({ sessionId: "eeeeeee5-0000-0000-0000-000000000005" });
  await waitForStatus(monitor, spawned.body.id, ["completed"]);

  const response = await fetch(`${origin}/api/events`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (!buffer.includes("\n\n")) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
  }
  await reader.cancel();

  assert.match(buffer, /event: snapshot/);
  const dataLine = buffer.split("\n").find((line) => line.startsWith("data: "));
  const snapshot = JSON.parse(dataLine.slice("data: ".length));
  assert.equal(Array.isArray(snapshot.runs), true);
  assert.equal(Array.isArray(snapshot.agents), true);
  assert.equal(snapshot.agents.length, 1);
  assert.equal(snapshot.agents[0].agentId, "AGENT-EXPLORER-001");
  assert.equal(snapshot.agents[0].formalRoleLabel, "Explorer");
  assert.equal(snapshot.agents[0].turns.length, 1);
});

test("close() drains a live SSE connection without forcing and without hanging", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-http-teardown-sse-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: createFakeBridge().spawnBridge,
    // Small bound so the regression is fast; production default is HTTP_CLOSE_TIMEOUT_MS.
    httpCloseMs: 250,
  });
  const address = await monitor.start();
  const origin = `http://127.0.0.1:${address.port}`;

  const response = await fetch(`${origin}/api/events`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  try {
    const first = await reader.read();
    assert.equal(first.done, false, "SSE 必须先推送 snapshot");

    const startedAt = Date.now();
    await monitor.close();
    const elapsed = Date.now() - startedAt;

    // close() ends every SSE client itself, so the only thing left is an idle keep-alive
    // socket: closeIdleConnections() must drain it well inside the bound.
    assert.ok(elapsed < 200, `SSE 连接不得延迟关闭：${elapsed}ms`);
    assert.equal(monitor.teardown?.forced, false, "服务端已 end 的 SSE 连接不应走强制路径");

    const settled = await Promise.race([
      reader.read().then(() => "read", () => "closed"),
      new Promise((resolvePromise) => setTimeout(() => resolvePromise("timeout"), 3000)),
    ]);
    assert.notEqual(settled, "timeout", "关闭后客户端 SSE 读取必须结束");
  } finally {
    await reader.cancel().catch(() => {});
  }
});

test("close() bounds a lingering *active* request and records the forced teardown", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-http-teardown-active-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: createFakeBridge().spawnBridge,
    httpCloseMs: 250,
  });
  const address = await monitor.start();

  // A raw client that declares `Content-Length` and then never sends the body. The monitor's
  // handler is awaiting that body, so the connection is *active*, not idle:
  // `closeIdleConnections()` cannot drop it and a bare `server.close()` would wait forever.
  const socket = connect(address.port, "127.0.0.1");
  context.after(() => socket.destroy());
  await new Promise((resolvePromise, rejectPromise) => {
    socket.once("connect", resolvePromise);
    socket.once("error", rejectPromise);
  });
  socket.write([
    "POST /api/runs HTTP/1.1",
    `Host: 127.0.0.1:${address.port}`,
    `X-DSH-Monitor-Token: ${TOKEN}`,
    "Content-Type: application/json",
    "Content-Length: 4096",
    "",
    "{",
  ].join("\r\n"));
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));

  const startedAt = Date.now();
  await monitor.close();
  const elapsed = Date.now() - startedAt;

  assert.ok(elapsed >= 200, `close() 必须等满 httpCloseMs 才强制关闭：${elapsed}ms`);
  assert.ok(elapsed < 5000, `close() 在活动连接下仍然必须有界：${elapsed}ms`);
  assert.equal(monitor.teardown?.forced, true, "活动连接必须走强制关闭路径并留下机器证据");
  assert.equal(monitor.teardown.timeoutMs, 250);

  const settled = socket.destroyed ? "closed" : await Promise.race([
    new Promise((resolvePromise) => socket.once("close", () => resolvePromise("closed"))),
    new Promise((resolvePromise) => setTimeout(() => resolvePromise("timeout"), 3000)),
  ]);
  assert.equal(settled, "closed", "强制关闭后服务端必须断开该连接");
});

test("close() without lingering connections does not force anything", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-http-teardown-clean-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: createFakeBridge().spawnBridge,
    httpCloseMs: 50,
  });
  await monitor.start();
  await monitor.close();
  assert.equal(monitor.teardown?.forced, false, "干净关闭不得走强制路径");
  assert.equal(monitor.teardown.timeoutMs, 50);
});

test("legacy history migrates into stable legacy agents", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-agent-legacy-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const runRoot = join(workspace, "artifacts", "dsh-gui-runs");

  const legacyRun = (id, overrides) => ({
    id,
    title: `legacy ${id}`,
    taskId: id,
    role: "worker",
    status: "completed",
    phase: "complete",
    workspace,
    sessionId: null,
    startUtc: "2026-01-01T00:00:00.000Z",
    endUtc: "2026-01-01T00:01:00.000Z",
    exitCode: 0,
    events: [],
    ...overrides,
  });

  const fixtures = [
    legacyRun("20260101T000000000Z-aaaaaa", { sessionId: "legacy-session-1" }),
    legacyRun("20260101T000500000Z-bbbbbb", { sessionId: "legacy-session-1", startUtc: "2026-01-01T00:05:00.000Z", endUtc: "2026-01-01T00:06:00.000Z" }),
    legacyRun("20260102T000000000Z-cccccc", { role: "reviewer", status: "failed", sessionId: null, startUtc: "2026-01-02T00:00:00.000Z", endUtc: "2026-01-02T00:00:30.000Z", exitCode: 1 }),
  ];
  for (const fixture of fixtures) {
    const artifactDir = join(runRoot, fixture.id);
    await mkdir(artifactDir, { recursive: true });
    await writeFile(join(artifactDir, "monitor-run.json"), `${JSON.stringify(fixture, null, 2)}\n`, "utf8");
  }

  const first = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const projection = await runs(first.origin);
  assert.equal(projection.runs.length, 3);
  assert.equal(projection.agents.length, 2);

  const sessionAgent = projection.agents.find((agent) => agent.agentId === "legacy:session:legacy-session-1");
  assert.ok(sessionAgent, "runs sharing a sessionId aggregate into one legacy agent");
  assert.equal(sessionAgent.legacy, true);
  assert.equal(sessionAgent.formalRole, null);
  assert.equal(sessionAgent.sessionId, "legacy-session-1");
  assert.deepEqual(sessionAgent.turns.map((turn) => turn.turnIndex), [1, 2]);
  assert.deepEqual(sessionAgent.turns.map((turn) => turn.runId), ["20260101T000000000Z-aaaaaa", "20260101T000500000Z-bbbbbb"]);

  const failedAgent = projection.agents.find((agent) => agent.agentId === "legacy:run:20260102T000000000Z-cccccc");
  assert.ok(failedAgent, "a failed legacy run without a session becomes a single-run agent");
  assert.equal(failedAgent.legacy, true);
  assert.equal(failedAgent.legacyRole, "reviewer");
  assert.deepEqual(failedAgent.turns.map((turn) => turn.turnIndex), [1]);
  assert.equal(failedAgent.status, "failed");

  const legacyFollowUp = await dispatchJson(first.origin, {
    agentId: "legacy:session:legacy-session-1",
    formalRole: "coder",
    lifecycleAction: "follow_up",
  });
  assert.equal(legacyFollowUp.status, 400);
  assert.match(legacyFollowUp.body.error, /legacy agent/);

  const legacySpawn = await dispatchJson(first.origin, {
    agentId: "legacy:session:legacy-session-1",
    formalRole: "coder",
    lifecycleAction: "spawn",
  });
  assert.equal(legacySpawn.status, 400);
  assert.match(legacySpawn.body.error, /重复 spawn/);

  await first.monitor.close();

  // Restart must not renumber identity or turnIndex.
  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const afterRestart = await runs(second.origin);
  assert.deepEqual(
    afterRestart.agents.map((agent) => [agent.agentId, agent.turns.map((turn) => turn.turnIndex)]),
    projection.agents.map((agent) => [agent.agentId, agent.turns.map((turn) => turn.turnIndex)]),
  );
  const registry = JSON.parse(await readFile(join(workspace, "artifacts", "dsh-monitor", "agent-registry.json"), "utf8"));
  assert.equal(registry.nextTurnIndex["legacy:session:legacy-session-1"], 3);
  assert.equal(registry.turns["20260101T000000000Z-aaaaaa"], 1);
  assert.equal(registry.turns["20260101T000500000Z-bbbbbb"], 2);
  await second.monitor.close();
});

test("concurrent dispatches reserve one same-agent turn and allow distinct agents", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  const sameAgent = await Promise.all([
    dispatchJson(origin, { agentId: "AGENT-CONCURRENT", formalRole: "coder", lifecycleAction: "spawn" }),
    dispatchJson(origin, { agentId: "AGENT-CONCURRENT", formalRole: "coder", lifecycleAction: "spawn" }),
  ]);
  assert.deepEqual(sameAgent.map((result) => result.status).sort(), [202, 400]);
  assert.equal(fake.calls.length, 1);
  assert.equal(sameAgent.find((result) => result.status === 202).body.turnIndex, 1);

  const distinct = await Promise.all([
    dispatchJson(origin, { agentId: "AGENT-CONCURRENT-A", formalRole: "coder", lifecycleAction: "spawn" }),
    dispatchJson(origin, { agentId: "AGENT-CONCURRENT-B", formalRole: "tester", lifecycleAction: "spawn" }),
  ]);
  assert.deepEqual(distinct.map((result) => result.status).sort(), [202, 202]);
  assert.equal(fake.calls.length, 3);
  await Promise.all(fake.calls.map((call) => call.finish()));
  await monitor.close();
});

test("a second monitor explicitly refuses the workspace registry lease", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-registry-lease-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const first = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const second = createMonitorForTest({ workspace, dshHome: workspace, port: 0, token: TOKEN, spawnBridge: createFakeBridge().spawnBridge });
  await assert.rejects(() => second.start(), /registry lease owner cannot be proven inactive|无法安全读取 registry lease|registry 已被其他 monitor 占用/);
  await first.monitor.close();
});

test("repeated corrupt registries receive unique diagnostic backups", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-registry-corrupt-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const registryDir = join(workspace, "artifacts", "dsh-monitor");
  await mkdir(registryDir, { recursive: true });
  const registryPath = join(registryDir, "agent-registry.json");
  await writeFile(registryPath, "{broken", "utf8");
  const first = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const firstHealth = await fetch(`${first.origin}/api/health`).then((response) => response.json());
  assert.match(firstHealth.agentRegistry.warning, /已备份到/);
  await first.monitor.close();
  await writeFile(registryPath, "[broken", "utf8");
  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const backups = (await readdir(registryDir)).filter((name) => name.endsWith(".corrupt"));
  assert.equal(backups.length, 2);
  assert.notEqual(backups[0], backups[1]);
  await second.monitor.close();
});

// --- stale lease recovery / arbitration ---------------------------------------

async function writeStaleLease(monitor, workspace, owner) {
  const lockPath = `${monitor.registryPath}.lock`;
  await mkdir(join(workspace, "artifacts", "dsh-monitor"), { recursive: true });
  await writeFile(
    lockPath,
    `${JSON.stringify({ schemaVersion: 1, acquiredAt: new Date().toISOString(), workspace, ...owner })}\n`,
    "utf8",
  );
  return lockPath;
}

function freshMonitor(workspace) {
  return createMonitorForTest({ workspace, dshHome: workspace, port: 0, token: TOKEN, spawnBridge: createFakeBridge().spawnBridge });
}

test("a provably dead owner lease is quarantined on restart without deleting evidence", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-lease-dead-owner-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const deadPid = await spawnExitedPid();
  const monitor = freshMonitor(workspace);
  const lockPath = await writeStaleLease(monitor, workspace, { leaseId: "stale-lease-0001", pid: deadPid });

  // No age wait: the lease mtime is fresh, but the owner is provably dead.
  const address = await monitor.start();
  const lease = JSON.parse(await readFile(lockPath, "utf8"));
  assert.equal(lease.pid, process.pid);
  assert.notEqual(lease.leaseId, "stale-lease-0001");

  const monitorDir = join(workspace, "artifacts", "dsh-monitor");
  const quarantined = (await readdir(monitorDir)).filter((name) => name.startsWith("agent-registry.json.lock.stale-"));
  assert.equal(quarantined.length, 1);
  const preserved = JSON.parse(await readFile(join(monitorDir, quarantined[0]), "utf8"));
  assert.equal(preserved.pid, deadPid);
  assert.equal(preserved.leaseId, "stale-lease-0001");

  const health = await fetch(`http://127.0.0.1:${address.port}/api/health`).then((response) => response.json());
  assert.equal(health.ok, true);
  assert.equal(health.agentRegistry.failClosed, null);
  await monitor.close();
});

test("concurrent monitors arbitrate one stale takeover and never delete the new owner lease", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-lease-race-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const deadPid = await spawnExitedPid();
  const first = freshMonitor(workspace);
  const second = freshMonitor(workspace);
  const lockPath = await writeStaleLease(first, workspace, { leaseId: "stale-race-0001", pid: deadPid });

  const results = await Promise.allSettled([first.start(), second.start()]);
  const fulfilled = results.filter((result) => result.status === "fulfilled");
  assert.equal(fulfilled.length, 1, `expected exactly one winner: ${results.map((result) => result.status).join(",")}`);
  const winner = results[0].status === "fulfilled" ? first : second;
  const loser = results[0].status === "fulfilled" ? second : first;
  const rejected = fulfilled.length === 1 ? results.find((result) => result.status === "rejected") : null;
  assert.match(String(rejected?.reason?.message), /registry lease|recovery|抢占|占用|cannot be proven inactive/);

  // The loser must never remove or overwrite the winner's fresh lease.
  const lease = JSON.parse(await readFile(lockPath, "utf8"));
  assert.equal(lease.pid, process.pid);
  assert.notEqual(lease.leaseId, "stale-race-0001");
  const quarantined = (await readdir(join(workspace, "artifacts", "dsh-monitor"))).filter((name) => name.includes(".lock.stale-"));
  assert.equal(quarantined.length, 1);

  const address = fulfilled[0].value;
  const health = await fetch(`http://127.0.0.1:${address.port}/api/health`).then((response) => response.json());
  assert.equal(health.ok, true);
  assert.equal(health.agentRegistry.lease.held, true);

  await winner.close();
  await loser.close();
});

test("lease inspection and owner checks fail closed instead of taking over", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-lease-failclosed-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const deadPid = await spawnExitedPid();
  const monitorDir = join(workspace, "artifacts", "dsh-monitor");
  const lockPath = join(monitorDir, "agent-registry.json.lock");
  await mkdir(monitorDir, { recursive: true });
  const rejectStart = (expected) => assert.rejects(() => freshMonitor(workspace).start(), expected);

  // Unreadable lease (directory instead of file) -> fail closed.
  await mkdir(lockPath, { recursive: true });
  await rejectStart(/无法读取 registry lease|无法 stat registry lease|拒绝抢占/);
  await rm(lockPath, { recursive: true, force: true });

  // Unparseable lease -> fail closed.
  await writeFile(lockPath, "{not json", "utf8");
  await rejectStart(/registry lease 无法解析/);

  // Lease without a usable owner pid -> fail closed.
  await writeFile(lockPath, `${JSON.stringify({ schemaVersion: 1, acquiredAt: new Date().toISOString(), workspace })}\n`, "utf8");
  await rejectStart(/缺少有效 owner pid/);

  // Dead owner, but the lease belongs to another workspace -> fail closed.
  await writeFile(
    lockPath,
    `${JSON.stringify({ schemaVersion: 1, leaseId: "other-ws", pid: deadPid, acquiredAt: new Date().toISOString(), workspace: join(tmpdir(), "somewhere-else") })}\n`,
    "utf8",
  );
  await rejectStart(/不属于本 workspace/);

  // A live owner in another process is never taken over.
  const live = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
  try {
    await new Promise((resolvePromise) => live.once("spawn", resolvePromise));
    await writeFile(
      lockPath,
      `${JSON.stringify({ schemaVersion: 1, leaseId: "live-owner", pid: live.pid, acquiredAt: new Date().toISOString(), workspace })}\n`,
      "utf8",
    );
    await rejectStart(/已被其他 monitor 占用/);
  } finally {
    live.kill();
  }
});

// --- reservation persistence / phantom recovery -------------------------------

test("a failed Run preparation rolls back completely and leaves no durable phantom", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-prep-failure-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const failingFake = createFakeBridge();
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: failingFake.spawnBridge,
    writeRunManifest: async () => { throw new Error("injected manifest write failure"); },
  });
  const address = await monitor.start();
  const origin = `http://127.0.0.1:${address.port}`;

  const response = await dispatchJson(origin, { agentId: "AGENT-PREP-FAIL", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(response.status, 400);
  assert.match(response.body.error, /run preparation 持久化失败/);
  assert.equal(failingFake.calls.length, 0, "a rolled-back preparation must never launch a bridge");
  assert.equal(monitor.runs.size, 0);
  await monitor.close();

  // Restart: nothing durable was reserved, so the same agentId starts cleanly at turn 1.
  const secondFake = createFakeBridge();
  const second = await startMonitor(context, { workspace, spawnBridge: secondFake.spawnBridge });
  const restored = await runs(second.origin);
  assert.deepEqual(restored.runs, []);
  assert.deepEqual(restored.agents, []);
  const respawn = await dispatchJson(second.origin, { agentId: "AGENT-PREP-FAIL", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(respawn.status, 202);
  assert.equal(respawn.body.turnIndex, 1);
  await secondFake.calls[0].finish();
  await waitForStatus(second.monitor, respawn.body.id, ["completed"]);
  await second.monitor.close();
});

test("reservation persistence double failure fails closed and leaves no durable phantom", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-persist-double-"));
  const registryPath = join(workspace, "artifacts", "dsh-monitor", "agent-registry.json");
  context.after(async () => {
    await chmod(registryPath, 0o666).catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  let manifestWrites = 0;
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: createFakeBridge().spawnBridge,
    writeRunManifest: async (path, contents) => {
      manifestWrites += 1;
      if (manifestWrites >= 2) throw new Error("injected evidence write failure");
      await writeFile(path, contents, "utf8");
    },
  });
  const address = await monitor.start();
  const origin = `http://127.0.0.1:${address.port}`;

  // Renaming the registry temp file onto a read-only registry is denied on Windows,
  // so the identity reservation cannot be persisted.
  await chmod(registryPath, 0o444);

  const failed = await dispatchJson(origin, { agentId: "AGENT-DOUBLE", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(failed.status, 202);
  assert.equal(failed.body.status, "failed");
  assert.equal(failed.body.phase, "reservation_failed");
  assert.match(failed.body.error, /registry reservation 持久化失败/);

  const health = await fetch(`${origin}/api/health`).then((response) => response.json());
  assert.equal(health.ok, false);
  assert.equal(health.agentRegistry.failClosed.phase, "reservation_persist_double_failure");
  assert.match(health.agentRegistry.failClosed.message, /injected evidence write failure/);
  assert.match(health.agentRegistry.warning, /fail-closed/);

  const refused = await dispatchJson(origin, { agentId: "AGENT-OTHER", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(refused.status, 400);
  assert.match(refused.body.error, /fail-closed/);

  await monitor.close();
  await chmod(registryPath, 0o666);

  // Restart: the visible Run is restored and no agent without a visible Run survives.
  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const after = await runs(second.origin);
  assert.equal(after.runs.length, 1);
  assert.equal(after.runs[0].agentId, "AGENT-DOUBLE");
  assert.ok(after.agents.length >= 1);
  assert.ok(after.agents.every((agent) => agent.turnCount >= 1), "no agent may exist without a visible Run");
  const restartedHealth = await fetch(`${second.origin}/api/health`).then((response) => response.json());
  assert.equal(restartedHealth.agentRegistry.failClosed, null);
  await second.monitor.close();
});

test("restart drops a durable phantom reservation with no visible Run", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-phantom-reconcile-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const registryDir = join(workspace, "artifacts", "dsh-monitor");
  await mkdir(registryDir, { recursive: true });
  await writeFile(
    join(registryDir, "agent-registry.json"),
    `${JSON.stringify({
      schemaVersion: 1,
      workspace,
      nextTurnIndex: { "AGENT-PHANTOM": 4 },
      agents: {
        "AGENT-PHANTOM": {
          agentId: "AGENT-PHANTOM",
          formalRole: "coder",
          legacy: false,
          legacyRole: null,
          sessionId: null,
          createdAt: "2026-01-01T00:00:00.000Z",
          updatedAt: "2026-01-01T00:00:00.000Z",
          runIds: ["20260101T000000000Z-phantom"],
        },
      },
      turns: { "20260101T000000000Z-phantom": 3 },
    }, null, 2)}\n`,
    "utf8",
  );

  const fake = createFakeBridge();
  const monitor = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });
  const projection = await runs(monitor.origin);
  assert.deepEqual(projection.agents, []);
  assert.deepEqual(projection.runs, []);
  const health = await fetch(`${monitor.origin}/api/health`).then((response) => response.json());
  assert.match(health.agentRegistry.warning, /phantom/);

  // The phantom identity is gone, so the agentId can be spawned cleanly at turn 1.
  const spawned = await dispatchJson(monitor.origin, { agentId: "AGENT-PHANTOM", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(spawned.status, 202);
  assert.equal(spawned.body.turnIndex, 1);
  await fake.calls[0].finish();
  await waitForStatus(monitor.monitor, spawned.body.id, ["completed"]);
  await monitor.monitor.close();
});

// --- shutdown finalization and escalation evidence ----------------------------

test("shutdown waits for async child close and finalization before releasing the lease", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-shutdown-graceful-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const bridge = createControlledBridge();
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: bridge.spawnBridge,
    stopGraceMs: 2000,
    sigtermGraceMs: 100,
    sigkillGraceMs: 100,
  });
  const address = await monitor.start();
  const origin = `http://127.0.0.1:${address.port}`;
  const spawned = await dispatchJson(origin, { agentId: "AGENT-SHUT-GRACE", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(spawned.status, 202);

  // The bridge reacts to the cancel request only after a delay: shutdown must wait for it.
  const closing = bridge.calls[0].closeAfter(120);
  const startedAt = Date.now();
  await monitor.close();
  const elapsed = Date.now() - startedAt;
  await closing;

  assert.ok(elapsed >= 100, `shutdown resolved before finalization: ${elapsed}ms`);
  assert.deepEqual(bridge.calls[0].signals, [], "a graceful cancel must not escalate to signals");

  const stored = JSON.parse(await readFile(join(bridge.calls[0].artifactDir, "monitor-run.json"), "utf8"));
  assert.equal(stored.status, "cancelled");
  assert.equal(stored.shutdown.timedOut, false);
  assert.deepEqual(stored.shutdown.steps, ["cancel"]);
  assert.ok(stored.shutdown.closedAt);
  assert.equal(stored.summary.session_id, "shutdown-session-1");

  await assert.rejects(() => readFile(`${monitor.registryPath}.lock`, "utf8"), /ENOENT/);
});

test("shutdown escalates to SIGTERM and SIGKILL and records the escalation evidence", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-shutdown-escalate-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const bridge = createControlledBridge({ closeOn: "SIGKILL", closeDelayMs: 10 });
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: bridge.spawnBridge,
    stopGraceMs: 60,
    sigtermGraceMs: 60,
    sigkillGraceMs: 500,
  });
  const address = await monitor.start();
  const origin = `http://127.0.0.1:${address.port}`;
  await dispatchJson(origin, { agentId: "AGENT-SHUT-ESCALATE", formalRole: "coder", lifecycleAction: "spawn" });

  await monitor.close();

  assert.deepEqual(bridge.calls[0].signals, ["SIGTERM", "SIGKILL"]);
  const stored = JSON.parse(await readFile(join(bridge.calls[0].artifactDir, "monitor-run.json"), "utf8"));
  assert.equal(stored.status, "cancelled");
  assert.deepEqual(stored.shutdown.steps, ["cancel", "SIGTERM", "SIGKILL"]);
  assert.equal(stored.shutdown.timedOut, false);
  assert.ok(stored.shutdown.sigtermAt && stored.shutdown.sigkillAt && stored.shutdown.closedAt);
  await assert.rejects(() => readFile(`${monitor.registryPath}.lock`, "utf8"), /ENOENT/);
});

test("an unresponsive bridge leaves explicit shutdown_timeout evidence instead of hanging", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-shutdown-timeout-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const bridge = createControlledBridge();
  const monitor = createMonitorForTest({
    workspace,
    dshHome: workspace,
    port: 0,
    token: TOKEN,
    spawnBridge: bridge.spawnBridge,
    stopGraceMs: 40,
    sigtermGraceMs: 40,
    sigkillGraceMs: 40,
  });
  const address = await monitor.start();
  const origin = `http://127.0.0.1:${address.port}`;
  await dispatchJson(origin, { agentId: "AGENT-SHUT-TIMEOUT", formalRole: "coder", lifecycleAction: "spawn" });

  const startedAt = Date.now();
  await monitor.close();
  const elapsed = Date.now() - startedAt;
  assert.ok(elapsed >= 100, `shutdown did not wait for the escalation deadlines: ${elapsed}ms`);
  assert.ok(elapsed < 5000, `shutdown hung for ${elapsed}ms`);

  assert.deepEqual(bridge.calls[0].signals, ["SIGTERM", "SIGKILL"]);
  const stored = JSON.parse(await readFile(join(bridge.calls[0].artifactDir, "monitor-run.json"), "utf8"));
  assert.equal(stored.status, "failed");
  assert.equal(stored.phase, "shutdown_timeout");
  assert.equal(stored.shutdown.timedOut, true);
  assert.deepEqual(stored.shutdown.steps, ["cancel", "SIGTERM", "SIGKILL"]);
  assert.ok(stored.shutdown.evidenceAt);
  await assert.rejects(() => readFile(`${monitor.registryPath}.lock`, "utf8"), /ENOENT/);
});

// --- vNext Team / Task DAG / Attempt / permission evidence ---------------------

test("Team lifecycle is explicit: completion awaits user acceptance and only an action dissolves", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  const created = await createTeam(origin, { teamId: "TEAM-LIFE", title: "Team lifecycle" });
  assert.equal(created.status, 201);
  assert.equal(created.body.status, "ACTIVE");
  assert.equal((await teams(origin)).teams.length, 1);

  // A status field alone can never dissolve a Team.
  const direct = await patchTeam(origin, "TEAM-LIFE", { status: "DISSOLVED" });
  assert.equal(direct.status, 400);
  assert.match(direct.body.error, /action: "dissolve"/);

  await createTask(origin, { taskId: "TASK-LIFE", teamId: "TEAM-LIFE", title: "work", ownerAgentId: "AGENT-LIFE" });
  const spawned = await dispatchJson(origin, {
    agentId: "AGENT-LIFE",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-LIFE",
    taskId: "TASK-LIFE",
    attemptId: "LIFE-A1",
  });
  assert.equal(spawned.status, 202);
  await fake.calls[0].finish({ sessionId: "life-session-1" });
  await waitForTask(origin, "TASK-LIFE", ["COMPLETED"]);

  // Finishing the work never auto-dissolves the Team.
  const awaiting = await patchTeam(origin, "TEAM-LIFE", { action: "complete" });
  assert.equal(awaiting.status, 200);
  assert.equal(awaiting.body.status, "AWAITING_USER_ACCEPTANCE");
  assert.equal((await teams(origin)).teams[0].status, "AWAITING_USER_ACCEPTANCE");
  const health = await fetch(`${origin}/api/health`).then((response) => response.json());
  assert.equal(health.controlPlane.awaitingUserAcceptance, 1);

  const dissolved = await patchTeam(origin, "TEAM-LIFE", { action: "dissolve" });
  assert.equal(dissolved.status, 200);
  assert.equal(dissolved.body.status, "DISSOLVED");

  const terminal = await patchTeam(origin, "TEAM-LIFE", { action: "dissolve" });
  assert.equal(terminal.status, 400);
  assert.match(terminal.body.error, /终态/);
  await monitor.close();
});

test("task DAG readiness is re-derived on dependency edits and dependency completion", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-DAG", title: "DAG" });

  const first = await createTask(origin, { taskId: "TASK-A", teamId: "TEAM-DAG", ownerAgentId: "AGENT-DAG" });
  assert.equal(first.status, 201);
  assert.equal(first.body.status, "READY");
  const second = await createTask(origin, {
    taskId: "TASK-B",
    teamId: "TEAM-DAG",
    dependencies: ["TASK-A"],
    ownerAgentId: "AGENT-DAG",
  });
  assert.equal(second.body.status, "BLOCKED");

  const unknownDependency = await createTask(origin, { taskId: "TASK-C", teamId: "TEAM-DAG", dependencies: ["TASK-MISSING"] });
  assert.equal(unknownDependency.status, 400);
  assert.match(unknownDependency.body.error, /不存在/);

  // Dynamic dependency edits re-derive readiness in both directions.
  const cleared = await patchTask(origin, "TASK-B", { dependencies: [] });
  assert.equal(cleared.status, 200);
  assert.equal(cleared.body.status, "READY");
  const restored = await patchTask(origin, "TASK-B", { dependencies: ["TASK-A"] });
  assert.equal(restored.body.status, "BLOCKED");

  // A dependency cycle is refused instead of deadlocking the graph.
  const cyclic = await patchTask(origin, "TASK-A", { dependencies: ["TASK-B"] });
  assert.equal(cyclic.status, 400);
  assert.match(cyclic.body.error, /环/);

  // Completing the dependency promotes the blocked task, event-driven.
  const spawned = await dispatchJson(origin, {
    agentId: "AGENT-DAG",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-DAG",
    taskId: "TASK-A",
    attemptId: "DAG-A1",
  });
  assert.equal(spawned.status, 202);
  await fake.calls[0].finish({ sessionId: "dag-session-1" });
  await waitForTask(origin, "TASK-A", ["COMPLETED"]);
  const promoted = await waitForTask(origin, "TASK-B", ["READY"]);
  assert.equal(promoted.status, "READY");
  await monitor.close();
});

test("an Agent returns to IDLE after its terminal run and can then take the next READY task", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-POOL", title: "Pool" });
  await createTask(origin, { taskId: "POOL-1", teamId: "TEAM-POOL", ownerAgentId: "AGENT-POOL" });
  await createTask(origin, { taskId: "POOL-2", teamId: "TEAM-POOL", ownerAgentId: "AGENT-POOL" });

  const started = await dispatchJson(origin, {
    agentId: "AGENT-POOL",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-POOL",
    taskId: "POOL-1",
    attemptId: "POOL-1-A1",
  });
  assert.equal(started.status, 202);
  assert.equal(started.body.task.status, "RUNNING");
  const running = await waitForAgentState(origin, "AGENT-POOL", ["RUNNING"]);
  assert.equal(running.currentTaskId, "POOL-1");
  assert.equal(running.teamId, "TEAM-POOL");

  // Coordinator bookkeeping stays available while the attempt is active, but nothing that
  // would break the fence or the one-active-task invariant may change.
  const bookkeeping = await patchTask(origin, "POOL-1", { recovery: { note: "in progress" } });
  assert.equal(bookkeeping.status, 200);
  assert.equal(bookkeeping.body.status, "RUNNING");
  assert.deepEqual(bookkeeping.body.recovery, { note: "in progress" });
  assert.equal((await patchTask(origin, "POOL-1", { action: "retry" })).status, 400);
  assert.equal((await patchTask(origin, "POOL-1", { ownerAgentId: "AGENT-OTHER" })).status, 400);
  assert.equal((await patchTask(origin, "POOL-1", { dependencies: [] })).status, 400);

  const conflict = await dispatchJson(origin, {
    agentId: "AGENT-POOL",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-POOL",
    taskId: "POOL-2",
    attemptId: "POOL-2-A1",
  });
  assert.equal(conflict.status, 400);
  assert.match(conflict.body.error, /活跃 turn|active Task/);

  await fake.calls[0].finish({ sessionId: "pool-session-1" });
  await waitForTask(origin, "POOL-1", ["COMPLETED"]);
  const idle = await waitForAgentState(origin, "AGENT-POOL", ["IDLE"]);
  assert.equal(idle.currentTaskId, null);

  const next = await dispatchJson(origin, {
    agentId: "AGENT-POOL",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-POOL",
    taskId: "POOL-2",
    attemptId: "POOL-2-A1",
  });
  assert.equal(next.status, 202);
  assert.equal(next.body.task.status, "RUNNING");
  assert.equal(next.body.sessionId, "pool-session-1");
  assert.equal(fake.calls[1].resume, "pool-session-1");
  await fake.calls[1].finish();
  await waitForTask(origin, "POOL-2", ["COMPLETED"]);
  assert.equal((await waitForTask(origin, "POOL-2", ["COMPLETED"])).attempts[0].status, "COMPLETED");
  await monitor.close();
});

test("an Agent with an active Task cannot be assigned a second Task", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-one-active-task-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const registryDir = join(workspace, "artifacts", "dsh-monitor");
  await mkdir(registryDir, { recursive: true });
  const timestamp = "2026-03-01T00:00:00.000Z";
  await writeFile(
    join(registryDir, "agent-registry.json"),
    `${JSON.stringify({
      schemaVersion: 1,
      workspace,
      nextTurnIndex: { "AGENT-BUSY": 2 },
      agents: {
        "AGENT-BUSY": {
          agentId: "AGENT-BUSY",
          formalRole: "coder",
          legacy: false,
          legacyRole: null,
          sessionId: "busy-session",
          createdAt: timestamp,
          updatedAt: timestamp,
          runIds: [],
        },
      },
      turns: {},
      teams: {
        "TEAM-BUSY": { teamId: "TEAM-BUSY", title: "Busy", status: "ACTIVE", createdAt: timestamp, updatedAt: timestamp },
      },
      tasks: {
        "BUSY-ACTIVE": {
          taskId: "BUSY-ACTIVE",
          teamId: "TEAM-BUSY",
          title: "active",
          status: "RUNNING",
          ownerAgentId: "AGENT-BUSY",
          dependencies: [],
          attemptId: "S1",
          attempts: [
            { attemptId: "S1", agentId: "AGENT-BUSY", runId: "missing-run", status: "RUNNING", startedAt: timestamp, endedAt: null },
          ],
          executionType: "normal",
          result: null,
          failure: null,
          recovery: null,
          createdAt: timestamp,
          updatedAt: timestamp,
        },
        "BUSY-NEXT": {
          taskId: "BUSY-NEXT",
          teamId: "TEAM-BUSY",
          title: "next",
          status: "READY",
          ownerAgentId: "AGENT-BUSY",
          dependencies: [],
          attemptId: null,
          attempts: [],
          executionType: "normal",
          result: null,
          failure: null,
          recovery: null,
          createdAt: timestamp,
          updatedAt: timestamp,
        },
      },
    }, null, 2)}\n`,
    "utf8",
  );

  const fake = createFakeBridge();
  const monitor = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });

  const blocked = await dispatchJson(monitor.origin, {
    agentId: "AGENT-BUSY",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-BUSY",
    taskId: "BUSY-NEXT",
    attemptId: "NEXT-A1",
  });
  assert.equal(blocked.status, 400);
  assert.match(blocked.body.error, /最多一个 active Task/);
  assert.equal(fake.calls.length, 0, "a rejected assignment must never launch a bridge");
  assert.equal(monitor.monitor.runs.size, 0);

  const agent = (await runs(monitor.origin)).agents.find((item) => item.agentId === "AGENT-BUSY");
  assert.equal(agent.state, "RUNNING");
  assert.equal(agent.currentTaskId, "BUSY-ACTIVE");
  await monitor.monitor.close();
});

test("spawn, follow_up and replacement attempts all carry verified full-access evidence", async (context) => {
  const previous = process.env.DSH_PERMISSION_MODE;
  process.env.DSH_PERMISSION_MODE = "workspace-write";
  context.after(() => {
    if (previous === undefined) delete process.env.DSH_PERMISSION_MODE;
    else process.env.DSH_PERMISSION_MODE = previous;
  });

  const fake = createFakeBridge();
  const { workspace, monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-PERM", title: "Permission evidence" });
  await createTask(origin, { taskId: "PERM-1", teamId: "TEAM-PERM", ownerAgentId: "AGENT-PERM-1" });
  await createTask(origin, { taskId: "PERM-2", teamId: "TEAM-PERM", ownerAgentId: "AGENT-PERM-1" });
  await createTask(origin, { taskId: "PERM-3", teamId: "TEAM-PERM", ownerAgentId: "AGENT-PERM-2" });

  const spawned = await dispatchJson(origin, {
    agentId: "AGENT-PERM-1",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-PERM",
    taskId: "PERM-1",
    attemptId: "PERM-1-A1",
  });
  assert.equal(spawned.status, 202);
  assert.equal(spawned.body.requestedPermissionMode, "danger-full-access");
  assert.equal(spawned.body.effectivePermissionMode, "danger-full-access");
  assert.equal(spawned.body.permissionVerification.enforced, true);
  assert.equal(spawned.body.permissionVerification.mismatch, false);
  assert.equal(spawned.body.permissionVerification.parentEnvValue, "workspace-write");
  assert.equal(spawned.body.permissionVerification.childEnvValue, "danger-full-access");
  assert.equal(spawned.body.permissionVerification.inheritedParentOverride, true);
  assert.equal(fake.calls[0].env.DSH_PERMISSION_MODE, "danger-full-access");
  assert.equal(spawned.body.task.attempts[0].requestedPermissionMode, "danger-full-access");
  assert.equal(spawned.body.task.attempts[0].permissionVerification.childEnvValue, "danger-full-access");

  // The same machine evidence is durable on disk.
  const manifest = JSON.parse(
    await readFile(join(workspace, "artifacts", "dsh-gui-runs", spawned.body.id, "monitor-run.json"), "utf8"),
  );
  assert.equal(manifest.teamId, "TEAM-PERM");
  assert.equal(manifest.attemptId, "PERM-1-A1");
  assert.equal(manifest.effectivePermissionMode, "danger-full-access");
  assert.equal(manifest.permissionVerification.enforced, true);

  await fake.calls[0].finish({ sessionId: "perm-session-1" });
  await waitForTask(origin, "PERM-1", ["COMPLETED"]);

  // follow_up reuses the bound session and the same verified preset.
  const followUp = await dispatchJson(origin, {
    agentId: "AGENT-PERM-1",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-PERM",
    taskId: "PERM-2",
    attemptId: "PERM-2-A1",
  });
  assert.equal(followUp.status, 202);
  assert.equal(followUp.body.sessionId, "perm-session-1");
  assert.equal(fake.calls[1].resume, "perm-session-1");
  assert.equal(fake.calls[1].env.DSH_PERMISSION_MODE, "danger-full-access");
  assert.equal(followUp.body.permissionVerification.enforced, true);
  await fake.calls[1].finish();
  await waitForTask(origin, "PERM-2", ["COMPLETED"]);

  // A replacement Agent is a fresh spawn: new agentId, new session, same verified preset.
  const replacement = await dispatchJson(origin, {
    agentId: "AGENT-PERM-2",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-PERM",
    taskId: "PERM-3",
    attemptId: "PERM-3-A1",
  });
  assert.equal(replacement.status, 202);
  assert.equal(replacement.body.sessionId, null);
  assert.equal(fake.calls[2].resume, null);
  assert.equal(fake.calls[2].env.DSH_PERMISSION_MODE, "danger-full-access");
  assert.equal(replacement.body.permissionVerification.enforced, true);
  await fake.calls[2].finish({ sessionId: "perm-session-2" });
  await waitForTask(origin, "PERM-3", ["COMPLETED"]);

  // A mismatching request is rejected, never silently downgraded.
  const mismatch = await dispatchJson(origin, {
    agentId: "AGENT-PERM-3",
    formalRole: "coder",
    lifecycleAction: "spawn",
    requestedPermissionMode: "workspace-write",
  });
  assert.equal(mismatch.status, 400);
  assert.match(mismatch.body.error, /不一致|静默降级/);
  await monitor.close();
});

test("attempt fencing preserves history and rejects a reused attempt id", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-FENCE", title: "Fence" });
  await createTask(origin, { taskId: "FENCE-1", teamId: "TEAM-FENCE", ownerAgentId: "AGENT-FENCE" });

  const first = await dispatchJson(origin, {
    agentId: "AGENT-FENCE",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-FENCE",
    taskId: "FENCE-1",
    attemptId: "FENCE-A1",
  });
  assert.equal(first.status, 202);

  await fake.calls[0].finish({ sessionId: "fence-session-1", exitCode: 1 });
  const failed = await waitForTask(origin, "FENCE-1", ["FAILED"]);
  assert.equal(failed.attempts.length, 1);
  assert.equal(failed.attempts[0].status, "FAILED");
  assert.equal(failed.attempts[0].fenced, false);

  const retried = await patchTask(origin, "FENCE-1", { action: "retry" });
  assert.equal(retried.status, 200);
  assert.equal(retried.body.status, "READY");
  assert.equal(retried.body.attemptId, null);

  // Reusing the settled attempt id is fenced off even though the Task is READY again.
  const reused = await dispatchJson(origin, {
    agentId: "AGENT-FENCE",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-FENCE",
    taskId: "FENCE-1",
    attemptId: "FENCE-A1",
  });
  assert.equal(reused.status, 400);
  assert.match(reused.body.error, /attempt FENCE-A1 已存在|fencing/);

  const second = await dispatchJson(origin, {
    agentId: "AGENT-FENCE",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-FENCE",
    taskId: "FENCE-1",
    attemptId: "FENCE-A2",
  });
  assert.equal(second.status, 202);
  assert.equal(second.body.task.attempts.length, 2);
  await fake.calls[1].finish({ sessionId: "fence-session-1" });
  const completed = await waitForTask(origin, "FENCE-1", ["COMPLETED"]);
  assert.deepEqual(completed.attempts.map((attempt) => attempt.attemptId), ["FENCE-A1", "FENCE-A2"]);
  assert.deepEqual(completed.attempts.map((attempt) => attempt.status), ["FAILED", "COMPLETED"]);
  await monitor.close();
});

test("restart reconciliation settles tasks under the taskId+attemptId fence", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-task-fence-restart-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const runRoot = join(workspace, "artifacts", "dsh-gui-runs");
  const registryDir = join(workspace, "artifacts", "dsh-monitor");
  await mkdir(registryDir, { recursive: true });

  const manifest = (id, overrides) => ({
    id,
    runId: id,
    agentId: "AGENT-RESTORE",
    formalRole: "coder",
    role: "coder",
    lifecycleAction: "spawn",
    turnIndex: 1,
    legacy: false,
    title: id,
    status: "completed",
    phase: "complete",
    workspace,
    sessionId: "restore-session",
    startUtc: "2026-02-01T00:00:00.000Z",
    endUtc: "2026-02-01T00:01:00.000Z",
    exitCode: 0,
    events: [],
    ...overrides,
  });
  const writeRun = async (value) => {
    const artifactDir = join(runRoot, value.id);
    await mkdir(artifactDir, { recursive: true });
    await writeFile(join(artifactDir, "monitor-run.json"), `${JSON.stringify(value, null, 2)}\n`, "utf8");
  };
  // A1 completed late, but the Task was already taken over by A2.
  await writeRun(manifest("20260201T000000000Z-old001", { teamId: "TEAM-RESTORE", taskId: "TASK-FENCED", attemptId: "A1" }));
  await writeRun(manifest("20260201T000100000Z-new002", {
    teamId: "TEAM-RESTORE",
    taskId: "TASK-FENCED",
    attemptId: "A2",
    status: "failed",
    exitCode: 1,
    endUtc: "2026-02-01T00:02:00.000Z",
  }));
  await writeRun(manifest("20260201T000200000Z-ok003", { teamId: "TEAM-RESTORE", taskId: "TASK-RESTORE", attemptId: "B1" }));

  const timestamp = "2026-02-01T00:00:00.000Z";
  const attempt = (attemptId, runId) => ({
    attemptId,
    agentId: "AGENT-RESTORE",
    runId,
    status: "RUNNING",
    startedAt: timestamp,
    endedAt: null,
  });
  await writeFile(
    join(registryDir, "agent-registry.json"),
    `${JSON.stringify({
      schemaVersion: 1,
      workspace,
      nextTurnIndex: { "AGENT-RESTORE": 4 },
      agents: {
        "AGENT-RESTORE": {
          agentId: "AGENT-RESTORE",
          formalRole: "coder",
          legacy: false,
          legacyRole: null,
          sessionId: "restore-session",
          createdAt: timestamp,
          updatedAt: timestamp,
          runIds: ["20260201T000000000Z-old001", "20260201T000100000Z-new002", "20260201T000200000Z-ok003"],
        },
      },
      turns: {
        "20260201T000000000Z-old001": 1,
        "20260201T000100000Z-new002": 2,
        "20260201T000200000Z-ok003": 3,
      },
      teams: {
        "TEAM-RESTORE": { teamId: "TEAM-RESTORE", title: "Restore", status: "ACTIVE", createdAt: timestamp, updatedAt: timestamp },
      },
      tasks: {
        "TASK-FENCED": {
          taskId: "TASK-FENCED",
          teamId: "TEAM-RESTORE",
          title: "Fenced",
          status: "FAILED",
          ownerAgentId: "AGENT-RESTORE",
          dependencies: [],
          attemptId: "A2",
          attempts: [
            attempt("A1", "20260201T000000000Z-old001"),
            attempt("A2", "20260201T000100000Z-new002"),
          ],
          executionType: "normal",
          result: null,
          failure: null,
          recovery: null,
          createdAt: timestamp,
          updatedAt: timestamp,
        },
        "TASK-RESTORE": {
          taskId: "TASK-RESTORE",
          teamId: "TEAM-RESTORE",
          title: "Restore",
          status: "RUNNING",
          ownerAgentId: "AGENT-RESTORE",
          dependencies: [],
          attemptId: "B1",
          attempts: [attempt("B1", "20260201T000200000Z-ok003")],
          executionType: "normal",
          result: null,
          failure: null,
          recovery: null,
          createdAt: timestamp,
          updatedAt: timestamp,
        },
      },
    }, null, 2)}\n`,
    "utf8",
  );

  const monitor = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const projection = await tasks(monitor.origin);

  const fenced = projection.tasks.find((task) => task.taskId === "TASK-FENCED");
  assert.equal(fenced.status, "FAILED", "a late superseded attempt must not resurrect the Task");
  assert.equal(fenced.attemptId, "A2");
  assert.equal(fenced.attempts.length, 2);
  assert.equal(fenced.attempts[0].status, "COMPLETED");
  assert.equal(fenced.attempts[0].fenced, true);
  assert.match(fenced.attempts[0].fencedReason, /未覆盖 Task 状态/);
  assert.equal(fenced.attempts[1].status, "FAILED");
  assert.equal(fenced.attempts[1].fenced, false);

  const restored = projection.tasks.find((task) => task.taskId === "TASK-RESTORE");
  assert.equal(restored.status, "COMPLETED");
  assert.equal(restored.attempts[0].status, "COMPLETED");
  assert.equal(restored.failure, null);
  await monitor.monitor.close();
});

test("teams and tasks persist across a monitor restart", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-task-restart-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));

  const firstFake = createFakeBridge();
  const first = await startMonitor(context, { workspace, spawnBridge: firstFake.spawnBridge });
  await createTeam(first.origin, { teamId: "TEAM-PERSIST", title: "Persist" });
  await createTask(first.origin, { taskId: "PERSIST-1", teamId: "TEAM-PERSIST", ownerAgentId: "AGENT-PERSIST" });
  await createTask(first.origin, {
    taskId: "PERSIST-2",
    teamId: "TEAM-PERSIST",
    dependencies: ["PERSIST-1"],
    ownerAgentId: "AGENT-PERSIST",
  });
  const spawned = await dispatchJson(first.origin, {
    agentId: "AGENT-PERSIST",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-PERSIST",
    taskId: "PERSIST-1",
    attemptId: "P1-A1",
  });
  await firstFake.calls[0].finish({ sessionId: "persist-session-1" });
  await waitForTask(first.origin, "PERSIST-1", ["COMPLETED"]);
  await waitForTask(first.origin, "PERSIST-2", ["READY"]);
  await first.monitor.close();

  const registry = JSON.parse(await readFile(join(workspace, "artifacts", "dsh-monitor", "agent-registry.json"), "utf8"));
  assert.equal(registry.teams["TEAM-PERSIST"].status, "ACTIVE");
  assert.equal(registry.tasks["PERSIST-1"].status, "COMPLETED");
  assert.equal(registry.tasks["PERSIST-1"].attempts.length, 1);

  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  const restoredTeams = await teams(second.origin);
  assert.equal(restoredTeams.teams.length, 1);
  assert.equal(restoredTeams.teams[0].teamId, "TEAM-PERSIST");
  const restoredTasks = await tasks(second.origin);
  const restoredOne = restoredTasks.tasks.find((task) => task.taskId === "PERSIST-1");
  assert.equal(restoredOne.status, "COMPLETED");
  assert.equal(restoredOne.attempts.length, 1);
  assert.equal(restoredOne.attempts[0].status, "COMPLETED");
  assert.equal(restoredTasks.tasks.find((task) => task.taskId === "PERSIST-2").status, "READY");

  const agent = (await runs(second.origin)).agents.find((item) => item.agentId === "AGENT-PERSIST");
  assert.equal(agent.state, "IDLE");
  assert.equal(agent.teamId, "TEAM-PERSIST");
  assert.equal(agent.currentTaskId, null);
  await second.monitor.close();
});

test("SSE team/task events and the read-only GET projections stay complete", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  const response = await fetch(`${origin}/api/events`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  const readUntil = async (needle) => {
    const deadline = Date.now() + 5000;
    while (!buffer.includes(needle)) {
      if (Date.now() > deadline) throw new Error(`SSE timeout waiting for ${needle}: ${buffer}`);
      const { value, done } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
    }
  };

  await readUntil("\n\n");
  assert.match(buffer, /event: snapshot/);
  const snapshot = JSON.parse(buffer.split("\n").find((line) => line.startsWith("data: ")).slice("data: ".length));
  assert.deepEqual(snapshot.teams, []);
  assert.deepEqual(snapshot.tasks, []);

  await createTeam(origin, { teamId: "TEAM-SSE", title: "SSE" });
  await readUntil("event: team");
  const teamEvent = JSON.parse(buffer.split("event: team\ndata: ")[1].split("\n")[0]);
  assert.equal(teamEvent.teamId, "TEAM-SSE");
  assert.equal(teamEvent.status, "ACTIVE");

  await createTask(origin, { taskId: "SSE-1", teamId: "TEAM-SSE" });
  await readUntil("event: task");
  const taskEvent = JSON.parse(buffer.split("event: task\ndata: ")[1].split("\n")[0]);
  assert.equal(taskEvent.taskId, "SSE-1");
  assert.equal(taskEvent.status, "READY");
  await reader.cancel();

  // The same projection is available to the token-less UI through the read APIs.
  const combined = await runs(origin);
  assert.equal(combined.teams.length, 1);
  assert.equal(combined.tasks.length, 1);
  assert.equal((await teams(origin)).teams[0].teamId, "TEAM-SSE");
  assert.equal((await tasks(origin)).tasks[0].taskId, "SSE-1");

  const cookieOnly = await fetch(`${origin}/api/teams`);
  assert.equal(cookieOnly.status, 401, "an unauthenticated read is refused");
  const writeAttempt = await fetch(`${origin}/api/tasks`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ teamId: "TEAM-SSE", taskId: "SSE-2" }),
  });
  assert.equal(writeAttempt.status, 403, "a token-less client cannot write the control plane");
  await monitor.close();
});

// --- T007: Coordinator-driven lifecycle for non-DSH Team members ---------------

test("an external Team member starts IDLE and completes a Task through assign/start/complete", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-EXT", title: "External pool" });
  await createTask(origin, { taskId: "EXT-1", teamId: "TEAM-EXT", title: "external work" });

  const registered = await registerAgent(origin, {
    agentId: "codex-tester-01",
    formalRole: "tester",
    teamId: "TEAM-EXT",
    backend: "codex",
  });
  assert.equal(registered.status, 201);
  assert.equal(registered.body.agentId, "codex-tester-01");
  assert.equal(registered.body.state, "IDLE");
  assert.equal(registered.body.status, "idle");
  assert.equal(registered.body.teamId, "TEAM-EXT");
  assert.equal(registered.body.backend, "codex");
  assert.equal(registered.body.sessionId, null);
  assert.equal(registered.body.bound, false);
  assert.equal(registered.body.terminated, false);
  assert.deepEqual(registered.body.turns, []);

  const projected = await waitForAgentState(origin, "codex-tester-01", ["IDLE"]);
  assert.equal(projected.currentTaskId, null);
  assert.equal(projected.teamId, "TEAM-EXT");
  assert.equal(projected.backend, "codex");

  // assign reserves the Agent but must not start it: only `start` moves it to RUNNING.
  const assigned = await patchTask(origin, "EXT-1", {
    action: "assign",
    agentId: "codex-tester-01",
    attemptId: "EXT-1-A1",
  });
  assert.equal(assigned.status, 200);
  assert.equal(assigned.body.status, "ASSIGNED");
  assert.equal(assigned.body.ownerAgentId, "codex-tester-01");
  assert.equal(assigned.body.attemptId, "EXT-1-A1");
  assert.equal(assigned.body.attempts.length, 1);
  const attempt = assigned.body.attempts[0];
  assert.equal(attempt.attemptId, "EXT-1-A1");
  assert.equal(attempt.agentId, "codex-tester-01");
  assert.equal(attempt.backend, "codex");
  assert.equal(attempt.status, "ASSIGNED");
  assert.equal(attempt.runId, null, "an external Attempt has no DSH run");
  assert.equal(attempt.sessionId, null);
  assert.equal(attempt.fenced, false);
  assert.equal(typeof attempt.startedAt, "string");
  assert.equal(attempt.endedAt, null);
  assert.equal(attempt.result, null);
  assert.equal(attempt.failure, null);

  const reserved = await waitForAgentState(origin, "codex-tester-01", ["IDLE"]);
  assert.equal(reserved.currentTaskId, "EXT-1", "the ASSIGNED Task is visible while the Agent is still IDLE");

  const started = await patchTask(origin, "EXT-1", { action: "start", attemptId: "EXT-1-A1" });
  assert.equal(started.status, 200);
  assert.equal(started.body.status, "RUNNING");
  assert.equal(started.body.attempts[0].status, "RUNNING");
  assert.equal(typeof started.body.attempts[0].runningSince, "string");
  const running = await waitForAgentState(origin, "codex-tester-01", ["RUNNING"]);
  assert.equal(running.status, "running");
  assert.equal(running.currentTaskId, "EXT-1");

  const completed = await patchTask(origin, "EXT-1", {
    action: "complete",
    attemptId: "EXT-1-A1",
    result: { summary: "12 checks passed" },
  });
  assert.equal(completed.status, 200);
  assert.equal(completed.body.status, "COMPLETED");
  assert.deepEqual(completed.body.result, { summary: "12 checks passed" });
  assert.equal(completed.body.failure, null);
  assert.equal(completed.body.attempts.length, 1, "terminal settlement keeps the Attempt history");
  assert.equal(completed.body.attempts[0].status, "COMPLETED");
  assert.equal(typeof completed.body.attempts[0].endedAt, "string");
  assert.deepEqual(completed.body.attempts[0].result, { summary: "12 checks passed" });

  const idle = await waitForAgentState(origin, "codex-tester-01", ["IDLE"]);
  assert.equal(idle.currentTaskId, null);
  assert.equal(idle.status, "idle");
});

test("the external Task lifecycle enforces Team membership, IDLE compatibility and one active Task", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-A", title: "A" });
  // This fixture needs two Teams that both accept work at the same time, so it opts out of
  // the default soft archive. The production default is covered by the T027 archive tests.
  await createTeam(origin, { teamId: "TEAM-B", title: "B", archiveExisting: false });
  await createTask(origin, { taskId: "A-1", teamId: "TEAM-A" });
  await createTask(origin, { taskId: "A-2", teamId: "TEAM-A" });
  await registerAgent(origin, { agentId: "EXT-A", formalRole: "tester", teamId: "TEAM-A", backend: "codex" });
  await registerAgent(origin, { agentId: "EXT-B", formalRole: "tester", teamId: "TEAM-B", backend: "codex" });
  await registerAgent(origin, { agentId: "DSH-A", formalRole: "coder", teamId: "TEAM-A", backend: "dsh" });

  const duplicate = await registerAgent(origin, { agentId: "EXT-A", formalRole: "coder", teamId: "TEAM-A", backend: "codex" });
  assert.equal(duplicate.status, 400);
  assert.match(duplicate.body.error, /已存在/);

  const unknown = await patchTask(origin, "A-1", { action: "assign", agentId: "EXT-MISSING", attemptId: "A-1-A1" });
  assert.equal(unknown.status, 400);
  assert.match(unknown.body.error, /未注册/);

  const wrongTeam = await patchTask(origin, "A-1", { action: "assign", agentId: "EXT-B", attemptId: "A-1-A1" });
  assert.equal(wrongTeam.status, 400);
  assert.match(wrongTeam.body.error, /不是 task A-1 所属的 TEAM-A/);

  const dshBackend = await patchTask(origin, "A-1", { action: "assign", agentId: "DSH-A", attemptId: "A-1-A1" });
  assert.equal(dshBackend.status, 400);
  assert.match(dshBackend.body.error, /backend 是 dsh/);

  const badAttemptId = await patchTask(origin, "A-1", { action: "assign", agentId: "EXT-A", attemptId: "bad attempt id" });
  assert.equal(badAttemptId.status, 400);
  assert.match(badAttemptId.body.error, /attemptId/);

  const missingAttemptId = await patchTask(origin, "A-1", { action: "assign", agentId: "EXT-A" });
  assert.equal(missingAttemptId.status, 400);
  assert.match(missingAttemptId.body.error, /唯一的 attemptId/);

  assert.equal((await patchTask(origin, "A-1", { action: "assign", agentId: "EXT-A", attemptId: "A-1-A1" })).status, 200);

  // ASSIGNED already counts as active, so the Agent cannot take a second Task.
  const second = await patchTask(origin, "A-2", { action: "assign", agentId: "EXT-A", attemptId: "A-2-A1" });
  assert.equal(second.status, 400);
  assert.match(second.body.error, /最多一个 active Task/);

  assert.equal((await patchTask(origin, "A-1", { action: "cancel", attemptId: "A-1-A1" })).body.status, "CANCELLED");
  assert.equal((await waitForAgentState(origin, "EXT-A", ["IDLE"])).currentTaskId, null);

  const notReady = await patchTask(origin, "A-1", { action: "assign", agentId: "EXT-A", attemptId: "A-1-A2" });
  assert.equal(notReady.status, 400);
  assert.match(notReady.body.error, /assign 需要 READY task/);

  // retry returns the Task to READY, and a reused attemptId stays fenced even then.
  assert.equal((await patchTask(origin, "A-1", { action: "retry" })).body.status, "READY");
  const reused = await patchTask(origin, "A-1", { action: "assign", agentId: "EXT-A", attemptId: "A-1-A1" });
  assert.equal(reused.status, 400);
  assert.match(reused.body.error, /attempt A-1-A1 已存在/);

  // a bare attemptId must never look like a fence while changing nothing
  const bareFence = await patchTask(origin, "A-1", { attemptId: "A-1-A2" });
  assert.equal(bareFence.status, 400);
  assert.match(bareFence.body.error, /只能与 action/);

  assert.equal((await patchTask(origin, "A-2", { action: "assign", agentId: "EXT-A", attemptId: "A-2-A1" })).status, 200);
  assert.equal((await patchTask(origin, "A-2", { action: "start" })).body.status, "RUNNING");

  const blockedTerminate = await patchAgent(origin, "EXT-A", { action: "terminate" });
  assert.equal(blockedTerminate.status, 400);
  assert.match(blockedTerminate.body.error, /active Task A-2/);

  // a DISSOLVED Team accepts no new assignment, but its in-flight work stays settleable
  await createTask(origin, { taskId: "B-1", teamId: "TEAM-B" });
  await registerAgent(origin, { agentId: "EXT-B2", formalRole: "tester", teamId: "TEAM-B", backend: "codex" });
  assert.equal((await patchTeam(origin, "TEAM-B", { action: "dissolve" })).body.status, "DISSOLVED");
  const dissolved = await patchTask(origin, "B-1", { action: "assign", agentId: "EXT-B2", attemptId: "B-1-A1" });
  assert.equal(dissolved.status, 400);
  assert.match(dissolved.body.error, /DISSOLVED/);
  assert.equal((await patchTask(origin, "A-2", { action: "cancel", attemptId: "A-2-A1" })).body.status, "CANCELLED");
});

test("an external terminal action is fenced against late or wrong attempts", async (context) => {
  const fake = createFakeBridge();
  const { origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-FENCE", title: "Fence" });
  await createTask(origin, { taskId: "F-1", teamId: "TEAM-FENCE" });
  await registerAgent(origin, { agentId: "EXT-F", formalRole: "tester", teamId: "TEAM-FENCE", backend: "external" });
  assert.equal((await patchTask(origin, "F-1", { action: "assign", agentId: "EXT-F", attemptId: "F-1-A1" })).status, 200);

  const wrong = await patchTask(origin, "F-1", { action: "complete", attemptId: "F-1-A0" });
  assert.equal(wrong.status, 400);
  assert.match(wrong.body.error, /fencing 拒绝 complete/);
  const untouched = (await tasks(origin)).tasks.find((task) => task.taskId === "F-1");
  assert.equal(untouched.status, "ASSIGNED", "a refused terminal action changes nothing");
  assert.equal(untouched.attempts[0].status, "ASSIGNED");

  await patchTask(origin, "F-1", { action: "start", attemptId: "F-1-A1" });
  const failed = await patchTask(origin, "F-1", { action: "fail", attemptId: "F-1-A1", reason: "vision mismatch" });
  assert.equal(failed.status, 200);
  assert.equal(failed.body.status, "FAILED");
  assert.equal(failed.body.failure.reason, "vision mismatch");
  assert.equal(failed.body.attempts[0].status, "FAILED");
  assert.equal(failed.body.attempts[0].failure.reason, "vision mismatch");

  // a late terminal action against the already settled attempt is refused
  const late = await patchTask(origin, "F-1", { action: "complete", attemptId: "F-1-A1" });
  assert.equal(late.status, 400);
  assert.match(late.body.error, /需要 active attempt/);

  // DSH Attempts keep the run path: these actions never advance them.
  await createTask(origin, { taskId: "F-2", teamId: "TEAM-FENCE" });
  const dispatched = await dispatchJson(origin, {
    agentId: "DSH-F",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-FENCE",
    taskId: "F-2",
    attemptId: "F-2-A1",
  });
  assert.equal(dispatched.status, 202);
  const dshComplete = await patchTask(origin, "F-2", { action: "complete", attemptId: "F-2-A1" });
  assert.equal(dshComplete.status, 400);
  assert.match(dshComplete.body.error, /由 DSH run 驱动/);
  assert.equal((await patchTask(origin, "F-2", { action: "start" })).status, 400);
  assert.equal((await patchTask(origin, "F-2", { action: "cancel" })).status, 400);
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "F-2").status, "RUNNING");

  // The durable Team Attempt F-2-A1 binds DSH-F as a Team member, so terminate is now refused for
  // the correct reason: its Task is still active. The refused action changes nothing.
  const activeMemberTerminate = await patchAgent(origin, "DSH-F", { action: "terminate" });
  assert.equal(activeMemberTerminate.status, 400);
  assert.match(activeMemberTerminate.body.error, /active Task F-2/);
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "F-2").status, "RUNNING");

  await fake.calls[0].finish({ sessionId: "dsh-fence-session" });
  await waitForTask(origin, "F-2", ["COMPLETED"]);

  // Settled and IDLE, the same Team-bound member is retirable, proving the earlier refusal was
  // only about the active Task and not about missing Team membership.
  const retiredMember = await patchAgent(origin, "DSH-F", { action: "terminate" });
  assert.equal(retiredMember.status, 200);
  assert.equal(retiredMember.body.terminated, true);
});

test("an external terminal action promotes dependents and emits SSE task/agent events", async (context) => {
  const { monitor, origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-SSE-EXT", title: "SSE external" });
  await createTask(origin, { taskId: "SSE-EXT-1", teamId: "TEAM-SSE-EXT" });
  await createTask(origin, { taskId: "SSE-EXT-2", teamId: "TEAM-SSE-EXT", dependencies: ["SSE-EXT-1"] });
  await registerAgent(origin, { agentId: "EXT-SSE", formalRole: "tester", teamId: "TEAM-SSE-EXT", backend: "codex" });
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "SSE-EXT-2").status, "BLOCKED");

  // A raw client instead of fetch: the test must be able to destroy the SSE socket, otherwise
  // monitor.close() waits out the HTTP keep-alive timeout on the half-open connection.
  let buffer = "";
  const sse = httpRequest(`${origin}/api/events`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  const sseResponse = await new Promise((resolvePromise, rejectPromise) => {
    sse.on("response", resolvePromise);
    sse.on("error", rejectPromise);
    sse.end();
  });
  assert.equal(sseResponse.statusCode, 200);
  sseResponse.setEncoding("utf8");
  sseResponse.on("data", (chunk) => { buffer += chunk; });
  const readUntil = async (needle) => {
    const deadline = Date.now() + 5000;
    while (!buffer.includes(needle)) {
      if (Date.now() > deadline) throw new Error(`SSE timeout waiting for ${needle}: ${buffer}`);
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
    }
  };
  await readUntil("\n\n");
  assert.match(buffer, /event: snapshot/, "the snapshot opens the stream");
  buffer = "";

  await patchTask(origin, "SSE-EXT-1", { action: "assign", agentId: "EXT-SSE", attemptId: "SSE-EXT-1-A1" });
  await patchTask(origin, "SSE-EXT-1", { action: "start", attemptId: "SSE-EXT-1-A1" });
  const completed = await patchTask(origin, "SSE-EXT-1", {
    action: "complete",
    attemptId: "SSE-EXT-1-A1",
    result: { ok: true },
  });
  assert.equal(completed.status, 200);
  await readUntil('"taskId":"SSE-EXT-2"');
  sse.destroy();

  const events = buffer.split("\n\n").filter((chunk) => chunk.startsWith("event: ")).map((chunk) => {
    const lines = chunk.split("\n");
    return { name: lines[0].slice("event: ".length), data: JSON.parse(lines[1].slice("data: ".length)) };
  });
  const taskEvents = events.filter((event) => event.name === "task");
  assert.ok(
    taskEvents.some((event) => event.data.taskId === "SSE-EXT-1" && event.data.status === "COMPLETED"),
    "the completed external Task is streamed",
  );
  assert.ok(
    taskEvents.some((event) => event.data.taskId === "SSE-EXT-2" && event.data.status === "READY"),
    "the dependency readiness pass is streamed",
  );
  const agentEvents = events.filter((event) => event.name === "agent" && event.data.agentId === "EXT-SSE");
  assert.ok(agentEvents.some((event) => event.data.state === "RUNNING"), "the started Agent is streamed as RUNNING");
  assert.ok(
    agentEvents.some((event) => event.data.state === "IDLE" && event.data.currentTaskId === null),
    "the settled Agent is streamed back to IDLE",
  );
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "SSE-EXT-2").status, "READY");
  await monitor.close();
});

test("external Agents and Tasks survive a monitor restart and stay settleable", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-external-restart-"));
  const monitors = [];
  // Both monitors share one workspace, so cleanup must close whatever was started even when
  // an assertion fails midway; an unclosed listener would keep the runner alive.
  context.after(async () => {
    for (const monitor of monitors) await monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  const first = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(first.monitor);
  await createTeam(first.origin, { teamId: "TEAM-PERSIST", title: "Persist" });
  await createTask(first.origin, { taskId: "PERSIST-1", teamId: "TEAM-PERSIST" });
  await registerAgent(first.origin, {
    agentId: "EXT-PERSIST",
    formalRole: "tester",
    teamId: "TEAM-PERSIST",
    backend: "codex",
  });
  await patchTask(first.origin, "PERSIST-1", { action: "assign", agentId: "EXT-PERSIST", attemptId: "PERSIST-1-A1" });
  await patchTask(first.origin, "PERSIST-1", { action: "start", attemptId: "PERSIST-1-A1" });
  await first.monitor.close();

  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(second.monitor);
  const restoredTask = (await tasks(second.origin)).tasks.find((task) => task.taskId === "PERSIST-1");
  assert.equal(restoredTask.status, "RUNNING");
  assert.equal(restoredTask.attemptId, "PERSIST-1-A1");
  assert.equal(restoredTask.attempts.length, 1);
  assert.equal(restoredTask.attempts[0].status, "RUNNING");
  assert.equal(restoredTask.attempts[0].backend, "codex");
  assert.equal(restoredTask.attempts[0].runId, null);
  const restoredAgent = (await runs(second.origin)).agents.find((agent) => agent.agentId === "EXT-PERSIST");
  assert.equal(restoredAgent.state, "RUNNING");
  assert.equal(restoredAgent.status, "running");
  assert.equal(restoredAgent.currentTaskId, "PERSIST-1");
  assert.equal(restoredAgent.teamId, "TEAM-PERSIST");
  assert.equal(restoredAgent.backend, "codex");
  assert.equal(restoredAgent.terminated, false);

  const completed = await patchTask(second.origin, "PERSIST-1", { action: "complete", attemptId: "PERSIST-1-A1" });
  assert.equal(completed.status, 200);
  assert.equal(completed.body.status, "COMPLETED");
  assert.equal(completed.body.attempts.length, 1);
  assert.equal((await waitForAgentState(second.origin, "EXT-PERSIST", ["IDLE"])).currentTaskId, null);
  await second.monitor.close();
});

test("only an explicit terminate retires an external member, and the API stays coordinator-only", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-TERM", title: "Terminate" });
  await createTask(origin, { taskId: "TERM-1", teamId: "TEAM-TERM" });
  await registerAgent(origin, { agentId: "EXT-TERM", formalRole: "tester", teamId: "TEAM-TERM", backend: "codex" });

  await patchTask(origin, "TERM-1", { action: "assign", agentId: "EXT-TERM", attemptId: "TERM-1-A1" });
  await patchTask(origin, "TERM-1", { action: "complete", attemptId: "TERM-1-A1" });
  const afterWork = (await runs(origin)).agents.find((agent) => agent.agentId === "EXT-TERM");
  assert.equal(afterWork.terminated, false, "a finished Task never terminates its member");
  assert.equal(afterWork.state, "IDLE");
  assert.equal(afterWork.teamId, "TEAM-TERM");

  assert.equal((await patchAgent(origin, "EXT-TERM", {})).status, 400);
  assert.equal((await patchAgent(origin, "EXT-MISSING", { action: "terminate" })).status, 400);

  const terminated = await patchAgent(origin, "EXT-TERM", { action: "terminate", reason: "pool retired" });
  assert.equal(terminated.status, 200);
  assert.equal(terminated.body.terminated, true);
  assert.equal(terminated.body.terminationReason, "pool retired");
  assert.equal(terminated.body.state, "IDLE");
  assert.equal(terminated.body.status, "cancelled");
  assert.equal(typeof terminated.body.terminatedAt, "string");
  assert.equal((await patchAgent(origin, "EXT-TERM", { action: "terminate" })).status, 400);

  await createTask(origin, { taskId: "TERM-2", teamId: "TEAM-TERM" });
  const refused = await patchTask(origin, "TERM-2", { action: "assign", agentId: "EXT-TERM", attemptId: "TERM-2-A1" });
  assert.equal(refused.status, 400);
  assert.match(refused.body.error, /已 terminate/);

  const tokenlessRegister = await fetch(`${origin}/api/agents`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ agentId: "EXT-NOPE", formalRole: "tester", teamId: "TEAM-TERM", backend: "codex" }),
  });
  assert.equal(tokenlessRegister.status, 403, "a token-less client cannot register Team members");
  const tokenlessTerminate = await fetch(`${origin}/api/agents/EXT-TERM`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "terminate" }),
  });
  assert.equal(tokenlessTerminate.status, 403, "a token-less client cannot terminate a member");
  const tokenlessTaskWrite = await fetch(`${origin}/api/tasks/TERM-2`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action: "assign", agentId: "EXT-TERM", attemptId: "TERM-2-A2" }),
  });
  assert.equal(tokenlessTaskWrite.status, 403, "a token-less client cannot drive the Task lifecycle");

  assert.equal((await registerAgent(origin, { agentId: "EXT-X", formalRole: "tester", teamId: "TEAM-MISSING" })).status, 400);
  assert.equal((await registerAgent(origin, { agentId: "EXT-X", formalRole: "wizard", teamId: "TEAM-TERM" })).status, 400);
  assert.equal(
    (await registerAgent(origin, { agentId: "EXT-X", formalRole: "tester", teamId: "TEAM-TERM", backend: "magic" })).status,
    400,
  );
  assert.equal((await registerAgent(origin, { agentId: "bad id", formalRole: "tester", teamId: "TEAM-TERM" })).status, 400);
  assert.equal((await registerAgent(origin, { agentId: "EXT-X", formalRole: "tester" })).status, 400);
});

// --- T027 soft Team archive ----------------------------------------------------

// Reads one SSE frame of `event: team` off an /api/events stream in arrival order.
async function openTeamEventStream(context, origin) {
  const TEAM_FRAME = "event: team\ndata: ";
  const response = await fetch(`${origin}/api/events`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  assert.equal(response.status, 200);
  const reader = response.body.getReader();
  // Always release the stream, so a failing assertion cannot keep the test runner alive.
  context.after(async () => { await reader.cancel().catch(() => {}); });
  const decoder = new TextDecoder();
  let buffer = "";
  const readMore = async () => {
    const { value, done } = await reader.read();
    if (!done) buffer += decoder.decode(value, { stream: true });
    return done;
  };
  const waitFor = async (predicate, label) => {
    const deadline = Date.now() + 5000;
    while (!predicate()) {
      if (Date.now() > deadline) throw new Error(`SSE timeout waiting for ${label}: ${buffer}`);
      if (await readMore()) break;
    }
  };
  await waitFor(() => buffer.includes("event: snapshot"), "the snapshot frame");
  return {
    async nextTeam() {
      const frameEnd = () => {
        const start = buffer.indexOf(TEAM_FRAME);
        return start === -1 ? -1 : buffer.indexOf("\n", start + TEAM_FRAME.length);
      };
      await waitFor(() => frameEnd() !== -1, "a team event");
      const start = buffer.indexOf(TEAM_FRAME) + TEAM_FRAME.length;
      const end = frameEnd();
      const parsed = JSON.parse(buffer.slice(start, end));
      buffer = buffer.slice(end);
      return parsed;
    },
  };
}

test("creating a Team soft-archives the previous Team and preserves every record it owns", async (context) => {
  const { origin, workspace } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  const first = await createTeam(origin, { teamId: "TEAM-OLD", title: "Old" });
  assert.equal(first.status, 201);
  assert.deepEqual(first.body.archivedTeamIds, []);
  assert.equal(first.body.archivedAt, null);
  assert.equal(first.body.archivedByTeamId, null);

  // A full external lifecycle leaves Task + Attempt + Agent evidence behind before the archive.
  await createTask(origin, { taskId: "OLD-1", teamId: "TEAM-OLD" });
  await registerAgent(origin, { agentId: "EXT-OLD", formalRole: "tester", teamId: "TEAM-OLD", backend: "codex" });
  await patchTask(origin, "OLD-1", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-1-A1" });
  await patchTask(origin, "OLD-1", { action: "start", attemptId: "OLD-1-A1" });
  await patchTask(origin, "OLD-1", { action: "complete", attemptId: "OLD-1-A1", result: { note: "kept" } });
  await patchTeam(origin, "TEAM-OLD", { action: "complete" });
  const before = (await tasks(origin)).tasks.find((task) => task.taskId === "OLD-1");

  const second = await createTeam(origin, { teamId: "TEAM-NEW", title: "New" });
  assert.equal(second.status, 201);
  assert.deepEqual(second.body.archivedTeamIds, ["TEAM-OLD"]);
  // The new Team keeps the existing top-level response shape and is itself not archived.
  assert.equal(second.body.status, "ACTIVE");
  assert.equal(second.body.title, "New");
  assert.equal(second.body.archivedAt, null);
  assert.equal(second.body.archivedByTeamId, null);

  const projection = (await teams(origin)).teams;
  const old = projection.find((team) => team.teamId === "TEAM-OLD");
  const active = projection.find((team) => team.teamId === "TEAM-NEW");
  // The archived Team keeps its own status fact; archive is never rewritten to DISSOLVED.
  assert.equal(old.status, "AWAITING_USER_ACCEPTANCE");
  assert.equal(typeof old.archivedAt, "string");
  assert.equal(old.archivedByTeamId, "TEAM-NEW");
  assert.equal(active.status, "ACTIVE");
  assert.equal(active.archivedAt, null);

  // Tasks, Attempts and results are unchanged, not deleted and not auto-settled.
  assert.deepEqual((await tasks(origin)).tasks.find((task) => task.taskId === "OLD-1"), before);
  assert.equal(before.status, "COMPLETED");
  assert.equal(before.attempts.length, 1);
  assert.equal(before.attempts[0].status, "COMPLETED");
  assert.equal(before.result.note, "kept");
  // No DSH Run exists, and the archived Team's Agent stays visible in the projection.
  const runsProjection = await runs(origin);
  assert.equal(runsProjection.runs.length, 0);
  assert.equal(runsProjection.agents.find((agent) => agent.agentId === "EXT-OLD").teamId, "TEAM-OLD");

  const registry = JSON.parse(await readFile(join(workspace, "artifacts", "dsh-monitor", "agent-registry.json"), "utf8"));
  assert.equal(registry.teams["TEAM-OLD"].status, "AWAITING_USER_ACCEPTANCE");
  assert.equal(registry.teams["TEAM-OLD"].archivedByTeamId, "TEAM-NEW");
  assert.equal(registry.teams["TEAM-OLD"].archivedAt, old.archivedAt);
  assert.equal(registry.teams["TEAM-NEW"].archivedAt, null);
  assert.equal(registry.tasks["OLD-1"].status, "COMPLETED");
  assert.equal(registry.agents["EXT-OLD"].teamId, "TEAM-OLD");
});

test("archiveExisting:false keeps parallel Teams unarchived and is validated as a boolean", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  assert.equal((await createTeam(origin, { teamId: "TEAM-P1", title: "P1" })).status, 201);
  const parallel = await createTeam(origin, { teamId: "TEAM-P2", title: "P2", archiveExisting: false });
  assert.equal(parallel.status, 201);
  assert.deepEqual(parallel.body.archivedTeamIds, []);

  const projection = (await teams(origin)).teams;
  assert.equal(projection.length, 2);
  for (const team of projection) {
    assert.equal(team.archivedAt, null);
    assert.equal(team.archivedByTeamId, null);
  }
  // Both Teams still accept work, which is the whole point of the escape hatch.
  await createTask(origin, { taskId: "P1-1", teamId: "TEAM-P1" });
  await createTask(origin, { taskId: "P2-1", teamId: "TEAM-P2" });
  assert.equal((await tasks(origin)).tasks.length, 2);

  const invalid = await createTeam(origin, { teamId: "TEAM-P3", archiveExisting: "no" });
  assert.equal(invalid.status, 400);
  assert.match(invalid.body.error, /archiveExisting 必须是布尔值/);
  assert.equal((await teams(origin)).teams.length, 2);
});

test("a non-terminal Task blocks the whole create instead of silently interrupting work", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-OLD", title: "Old" });
  await createTask(origin, { taskId: "OLD-DONE", teamId: "TEAM-OLD" });
  await registerAgent(origin, { agentId: "EXT-OLD", formalRole: "tester", teamId: "TEAM-OLD", backend: "codex" });
  await patchTask(origin, "OLD-DONE", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-DONE-A1" });
  await patchTask(origin, "OLD-DONE", { action: "complete", attemptId: "OLD-DONE-A1" });
  await createTask(origin, { taskId: "OLD-OPEN", teamId: "TEAM-OLD" });

  const blocked = await createTeam(origin, { teamId: "TEAM-NEW" });
  assert.equal(blocked.status, 400);
  assert.match(blocked.body.error, /未结算工作/);
  assert.match(blocked.body.error, /team TEAM-OLD/);
  assert.match(blocked.body.error, /未结算 Task: OLD-OPEN\(READY\)/);
  assert.match(blocked.body.error, /archiveExisting:false/);

  // Atomic: the new Team does not exist and no archive field was written.
  const projection = (await teams(origin)).teams;
  assert.equal(projection.length, 1);
  assert.equal(projection[0].teamId, "TEAM-OLD");
  assert.equal(projection[0].archivedAt, null);
  assert.equal(projection[0].archivedByTeamId, null);
  assert.deepEqual((await tasks(origin)).tasks.map((task) => `${task.taskId}:${task.status}`).sort(), ["OLD-DONE:COMPLETED", "OLD-OPEN:READY"]);

  // An ACTIVE Task is a blocker too, not just READY.
  await patchTask(origin, "OLD-OPEN", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-OPEN-A1" });
  await patchTask(origin, "OLD-OPEN", { action: "start", attemptId: "OLD-OPEN-A1" });
  const blockedActive = await createTeam(origin, { teamId: "TEAM-NEW" });
  assert.equal(blockedActive.status, 400);
  assert.match(blockedActive.body.error, /未结算 Task: OLD-OPEN\(RUNNING\)/);

  // Settling the work releases the block, and the escape hatch stays available meanwhile.
  await patchTask(origin, "OLD-OPEN", { action: "cancel", attemptId: "OLD-OPEN-A1" });
  const released = await createTeam(origin, { teamId: "TEAM-NEW" });
  assert.equal(released.status, 201);
  assert.deepEqual(released.body.archivedTeamIds, ["TEAM-OLD"]);
  assert.equal((await teams(origin)).teams.length, 2);
});

test("DISSOLVED Teams are neither archived nor treated as blockers", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-DIS", title: "Dissolved" });
  // A DISSOLVED Team may still own a READY Task; that must not block the next Team.
  await createTask(origin, { taskId: "DIS-1", teamId: "TEAM-DIS" });
  await patchTeam(origin, "TEAM-DIS", { action: "dissolve" });

  const next = await createTeam(origin, { teamId: "TEAM-NEXT", title: "Next" });
  assert.equal(next.status, 201);
  assert.deepEqual(next.body.archivedTeamIds, []);

  const dissolved = (await teams(origin)).teams.find((team) => team.teamId === "TEAM-DIS");
  assert.equal(dissolved.status, "DISSOLVED");
  assert.equal(dissolved.archivedAt, null);
  assert.equal(dissolved.archivedByTeamId, null);
  // DISSOLVED keeps its own terminal semantics, unchanged by the archive feature.
  const refused = await createTask(origin, { taskId: "DIS-2", teamId: "TEAM-DIS" });
  assert.equal(refused.status, 400);
  assert.match(refused.body.error, /已 DISSOLVED/);
  // And it is never re-archived by a later create.
  const third = await createTeam(origin, { teamId: "TEAM-THIRD" });
  assert.deepEqual(third.body.archivedTeamIds, ["TEAM-NEXT"]);
});

test("a soft-archived Team refuses new work but keeps read-only projections and explicit dissolve", async (context) => {
  const fake = createFakeBridge();
  const { origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-OLD", title: "Old" });
  await createTask(origin, { taskId: "OLD-1", teamId: "TEAM-OLD" });
  await createTask(origin, { taskId: "OLD-2", teamId: "TEAM-OLD" });
  await registerAgent(origin, { agentId: "EXT-OLD", formalRole: "tester", teamId: "TEAM-OLD", backend: "codex" });
  await patchTask(origin, "OLD-1", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-1-A1" });
  await patchTask(origin, "OLD-1", { action: "complete", attemptId: "OLD-1-A1" });
  await patchTask(origin, "OLD-2", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-2-A1" });
  await patchTask(origin, "OLD-2", { action: "fail", attemptId: "OLD-2-A1" });
  assert.deepEqual((await createTeam(origin, { teamId: "TEAM-NEW" })).body.archivedTeamIds, ["TEAM-OLD"]);

  const archived = (await teams(origin)).teams.find((team) => team.teamId === "TEAM-OLD");
  assert.equal(archived.status, "ACTIVE");

  // Every work-creating entry point is refused with the archive reason.
  const newTask = await createTask(origin, { taskId: "OLD-3", teamId: "TEAM-OLD" });
  assert.equal(newTask.status, 400);
  assert.match(newTask.body.error, /已软归档/);
  assert.match(newTask.body.error, /新建 task/);

  const newAgent = await registerAgent(origin, { agentId: "EXT-NEW", formalRole: "tester", teamId: "TEAM-OLD", backend: "codex" });
  assert.equal(newAgent.status, 400);
  assert.match(newAgent.body.error, /已软归档/);
  assert.match(newAgent.body.error, /注册新 member/);

  const reassign = await patchTask(origin, "OLD-2", { action: "reassign", ownerAgentId: "EXT-OLD" });
  assert.equal(reassign.status, 400);
  assert.match(reassign.body.error, /已软归档/);
  assert.match(reassign.body.error, /reassign/);

  const retry = await patchTask(origin, "OLD-2", { action: "retry" });
  assert.equal(retry.status, 400);
  assert.match(retry.body.error, /已软归档/);

  const assign = await patchTask(origin, "OLD-1", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-1-A2" });
  assert.equal(assign.status, 400);
  assert.match(assign.body.error, /已软归档/);

  // DSH dispatch/resume is refused before any run reservation is attempted.
  const dispatched = await dispatchJson(origin, {
    agentId: "AGENT-OLD",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-OLD",
    taskId: "OLD-1",
    attemptId: "OLD-1-A2",
  });
  assert.equal(dispatched.status, 400);
  assert.match(dispatched.body.error, /已软归档/);
  assert.equal(fake.calls.length, 0, "no DSH child was launched for an archived Team");

  // The archived Team is never re-activated, and the new Team is the only writable one.
  const reactivate = await patchTeam(origin, "TEAM-OLD", { status: "ACTIVE" });
  assert.equal(reactivate.status, 400);
  assert.match(reactivate.body.error, /不能重新激活为 ACTIVE/);
  assert.equal((await createTask(origin, { taskId: "NEW-1", teamId: "TEAM-NEW" })).status, 201);

  // Read-only projections stay complete for the archived Team.
  assert.equal((await tasks(origin)).tasks.filter((task) => task.teamId === "TEAM-OLD").length, 2);
  const archivedProjection = await runs(origin);
  assert.equal(archivedProjection.runs.length, 0);
  assert.equal(archivedProjection.agents.find((agent) => agent.agentId === "EXT-OLD").teamId, "TEAM-OLD");
  const health = await fetch(`${origin}/api/health`).then((response) => response.json());
  assert.equal(health.controlPlane.archived, 1);
  assert.equal(health.controlPlane.teams, 2);

  // The archive is not a brick: the explicit dissolve action still works.
  const dissolved = await patchTeam(origin, "TEAM-OLD", { action: "dissolve" });
  assert.equal(dissolved.status, 200);
  assert.equal(dissolved.body.status, "DISSOLVED");
  assert.equal(dissolved.body.archivedByTeamId, "TEAM-NEW");
});

test("an archived Team refuses start/retry/reassign on seeded open work and still allows settlement", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-archive-seeded-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  const registryDir = join(workspace, "artifacts", "dsh-monitor");
  await mkdir(registryDir, { recursive: true });
  const timestamp = "2026-03-01T00:00:00.000Z";
  const seededAttempt = (attemptId, status, taskId) => ({
    attemptId,
    taskId,
    teamId: "TEAM-ARCH",
    agentId: "EXT-ARCH",
    backend: "codex",
    runId: null,
    sessionId: null,
    status,
    startedAt: timestamp,
    endedAt: status === "ASSIGNED" || status === "RUNNING" ? null : timestamp,
  });
  const seededTask = (taskId, status, attemptId, attemptStatus) => ({
    taskId,
    teamId: "TEAM-ARCH",
    title: taskId,
    status,
    ownerAgentId: "EXT-ARCH",
    dependencies: [],
    attemptId,
    attempts: [seededAttempt(attemptId, attemptStatus, taskId)],
    executionType: "normal",
    result: null,
    failure: null,
    recovery: null,
    createdAt: timestamp,
    updatedAt: timestamp,
  });
  // A hand-written v1 registry: no archive fields at all, plus a deliberately inconsistent
  // record (a terminal Task whose Attempt never settled) to isolate the Attempt blocker.
  await writeFile(
    join(registryDir, "agent-registry.json"),
    `${JSON.stringify({
      schemaVersion: 1,
      controlPlaneSchemaVersion: 1,
      agents: {
        "EXT-ARCH": {
          agentId: "EXT-ARCH",
          formalRole: "tester",
          legacy: false,
          legacyRole: null,
          sessionId: null,
          teamId: "TEAM-ARCH",
          backend: "codex",
          state: "IDLE",
          status: "idle",
          runIds: [],
          createdAt: timestamp,
          updatedAt: timestamp,
        },
      },
      turns: {},
      nextTurnIndex: {},
      teams: {
        "TEAM-ARCH": { teamId: "TEAM-ARCH", title: "Archived", status: "ACTIVE", createdAt: timestamp, updatedAt: timestamp },
        "TEAM-V1": { teamId: "TEAM-V1", title: "V1", status: "ACTIVE", createdAt: timestamp, updatedAt: timestamp },
      },
      tasks: {
        "ARCH-RUN": seededTask("ARCH-RUN", "ASSIGNED", "ARCH-RUN-A1", "ASSIGNED"),
        "ARCH-FAIL": seededTask("ARCH-FAIL", "FAILED", "ARCH-FAIL-A1", "FAILED"),
      },
    }, null, 2)}\n`,
    "utf8",
  );
  const { monitor, origin } = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  context.after(() => monitor.close().catch(() => {}));

  // A v1 Team without archive fields projects null instead of undefined.
  const seeded = (await teams(origin)).teams;
  assert.equal(seeded.length, 2);
  for (const team of seeded) {
    assert.equal(team.archivedAt, null);
    assert.equal(team.archivedByTeamId, null);
  }
  // The unsettled Attempt blocks the archive even though its Task already looks terminal.
  const blocked = await createTeam(origin, { teamId: "TEAM-NEXT" });
  assert.equal(blocked.status, 400);
  assert.match(blocked.body.error, /未结算 Attempt: ARCH-RUN\/ARCH-RUN-A1\(ASSIGNED\)/);
  assert.equal((await teams(origin)).teams.length, 2);

  // Archive through the escape hatch is not how production archives; use the real path after
  // settling the inconsistent record, then assert the guards on genuinely archived open work.
  await patchTask(origin, "ARCH-RUN", { action: "complete", attemptId: "ARCH-RUN-A1" });
  const archivedNow = await createTeam(origin, { teamId: "TEAM-NEXT" });
  assert.equal(archivedNow.status, 201);
  assert.deepEqual(archivedNow.body.archivedTeamIds, ["TEAM-ARCH", "TEAM-V1"]);
  // The archived Team keeps its Task history: nothing was deleted or auto-settled.
  assert.deepEqual(
    (await tasks(origin)).tasks.map((task) => `${task.taskId}:${task.status}`).sort(),
    ["ARCH-FAIL:FAILED", "ARCH-RUN:COMPLETED"],
  );
  const reArchived = await createTeam(origin, { teamId: "TEAM-LAST" });
  assert.deepEqual(reArchived.body.archivedTeamIds, ["TEAM-NEXT"]);
  // start is refused by the archive guard rather than by the attempt-state check.
  const started = await patchTask(origin, "ARCH-RUN", { action: "start", attemptId: "ARCH-RUN-A1" });
  assert.equal(started.status, 400);
  assert.match(started.body.error, /已软归档/);
  assert.match(started.body.error, /start/);
  const retried = await patchTask(origin, "ARCH-FAIL", { action: "retry" });
  assert.equal(retried.status, 400);
  assert.match(retried.body.error, /已软归档/);
});

test("soft archive announces archived Teams before the new ACTIVE Team on the existing team event", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  const stream = await openTeamEventStream(context, origin);
  const created = await createTeam(origin, { teamId: "TEAM-OLD", title: "Old" });
  assert.equal(created.status, 201);
  assert.equal((await stream.nextTeam()).teamId, "TEAM-OLD");

  assert.equal((await createTeam(origin, { teamId: "TEAM-NEW", title: "New" })).status, 201);
  const archivedEvent = await stream.nextTeam();
  const activeEvent = await stream.nextTeam();
  assert.equal(archivedEvent.teamId, "TEAM-OLD");
  assert.equal(typeof archivedEvent.archivedAt, "string");
  assert.equal(archivedEvent.archivedByTeamId, "TEAM-NEW");
  assert.equal(archivedEvent.status, "ACTIVE");
  assert.equal(activeEvent.teamId, "TEAM-NEW");
  assert.equal(activeEvent.archivedAt, null);
  assert.equal(activeEvent.status, "ACTIVE");
});

test("soft archive state survives a monitor restart and keeps refusing new work", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-archive-restart-"));
  const monitors = [];
  context.after(async () => {
    for (const monitor of monitors) await monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  const first = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(first.monitor);
  await createTeam(first.origin, { teamId: "TEAM-OLD", title: "Old" });
  await createTask(first.origin, { taskId: "OLD-1", teamId: "TEAM-OLD" });
  await registerAgent(first.origin, { agentId: "EXT-OLD", formalRole: "tester", teamId: "TEAM-OLD", backend: "codex" });
  await patchTask(first.origin, "OLD-1", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-1-A1" });
  await patchTask(first.origin, "OLD-1", { action: "complete", attemptId: "OLD-1-A1" });
  assert.deepEqual((await createTeam(first.origin, { teamId: "TEAM-NEW" })).body.archivedTeamIds, ["TEAM-OLD"]);
  const archivedAt = (await teams(first.origin)).teams.find((team) => team.teamId === "TEAM-OLD").archivedAt;
  await first.monitor.close();

  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(second.monitor);
  const restored = (await teams(second.origin)).teams.find((team) => team.teamId === "TEAM-OLD");
  assert.equal(restored.archivedAt, archivedAt);
  assert.equal(restored.archivedByTeamId, "TEAM-NEW");
  assert.equal(restored.status, "ACTIVE");
  const health = await fetch(`${second.origin}/api/health`).then((response) => response.json());
  assert.equal(health.controlPlane.archived, 1);
  assert.equal(health.controlPlane.awaitingUserAcceptance, 0);

  // The guard survives the restart, and the already-archived Team is not archived twice.
  const refused = await createTask(second.origin, { taskId: "OLD-2", teamId: "TEAM-OLD" });
  assert.equal(refused.status, 400);
  assert.match(refused.body.error, /已软归档/);
  const third = await createTeam(second.origin, { teamId: "TEAM-THIRD" });
  assert.equal(third.status, 201);
  assert.deepEqual(third.body.archivedTeamIds, ["TEAM-NEW"]);
  assert.equal((await teams(second.origin)).teams.find((team) => team.teamId === "TEAM-OLD").archivedAt, archivedAt);
});

test("a persist failure rolls back the new Team and every archive field together", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-archive-persist-"));
  const registryPath = join(workspace, "artifacts", "dsh-monitor", "agent-registry.json");
  context.after(async () => {
    await chmod(registryPath, 0o666).catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  const { monitor, origin } = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  context.after(() => monitor.close().catch(() => {}));
  await createTeam(origin, { teamId: "TEAM-OLD", title: "Old" });
  await createTask(origin, { taskId: "OLD-1", teamId: "TEAM-OLD" });
  await registerAgent(origin, { agentId: "EXT-OLD", formalRole: "tester", teamId: "TEAM-OLD", backend: "codex" });
  await patchTask(origin, "OLD-1", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-1-A1" });
  await patchTask(origin, "OLD-1", { action: "complete", attemptId: "OLD-1-A1" });

  // Renaming the registry temp file onto a read-only registry is denied on Windows, so the
  // create transaction cannot be persisted.
  await chmod(registryPath, 0o444);
  const failed = await createTeam(origin, { teamId: "TEAM-NEW", title: "New" });
  assert.equal(failed.status, 400);
  assert.match(failed.body.error, /旧 Team archive 字段已回滚/);
  await chmod(registryPath, 0o666);

  const projection = (await teams(origin)).teams;
  assert.equal(projection.length, 1);
  assert.equal(projection[0].teamId, "TEAM-OLD");
  assert.equal(projection[0].archivedAt, null);
  assert.equal(projection[0].archivedByTeamId, null);
  // The rolled back archive is genuinely open for work again, and the transaction is retryable.
  assert.equal((await createTask(origin, { taskId: "OLD-2", teamId: "TEAM-OLD" })).status, 201);
  await patchTask(origin, "OLD-2", { action: "assign", agentId: "EXT-OLD", attemptId: "OLD-2-A1" });
  await patchTask(origin, "OLD-2", { action: "complete", attemptId: "OLD-2-A1" });
  const retried = await createTeam(origin, { teamId: "TEAM-NEW", title: "New" });
  assert.equal(retried.status, 201);
  assert.deepEqual(retried.body.archivedTeamIds, ["TEAM-OLD"]);
});

test("a Team-bound Agent can never degrade to a legacy dispatch, and an archived Team fences it before any run exists", async (context) => {
  const fake = createFakeBridge();
  const { origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-BOUND-A", title: "Bound A" });
  await createTask(origin, { taskId: "BOUND-1", teamId: "TEAM-BOUND-A", ownerAgentId: "AGENT-BOUND" });

  // A normal Team-managed dispatch binds the Agent to the Team through its Attempt.
  const started = await dispatchJson(origin, {
    agentId: "AGENT-BOUND",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-BOUND-A",
    taskId: "BOUND-1",
    attemptId: "BOUND-1-A1",
  });
  assert.equal(started.status, 202);
  await fake.calls[0].finish({ sessionId: "bound-session-1" });
  await waitForTask(origin, "BOUND-1", ["COMPLETED"]);
  const idle = await waitForAgentState(origin, "AGENT-BOUND", ["IDLE"]);
  const turnsBefore = idle.turnCount;
  const runIdsBefore = [...idle.runIds];
  const callsBefore = fake.calls.length;

  // While the Team is live, dropping the Team fields is already a refused downgrade: a bound
  // Agent always travels with teamId + taskId + attemptId.
  const degradedLive = await dispatchJson(origin, { agentId: "AGENT-BOUND", formalRole: "coder", lifecycleAction: "follow_up" });
  assert.equal(degradedLive.status, 400);
  assert.match(degradedLive.body.error, /已绑定 team TEAM-BOUND-A/);

  // A new Team soft-archives the bound Team.
  const replacement = await createTeam(origin, { teamId: "TEAM-BOUND-B", title: "Bound B" });
  assert.equal(replacement.status, 201);
  assert.deepEqual(replacement.body.archivedTeamIds, ["TEAM-BOUND-A"]);
  // A live Task in the new Team exists for the bound Agent itself, so a forged Team field could
  // otherwise look legitimate (owner + Team + status would all line up).
  await createTask(origin, { taskId: "BOUND-2", teamId: "TEAM-BOUND-B", ownerAgentId: "AGENT-BOUND" });
  await createTask(origin, { taskId: "BOUND-4", teamId: "TEAM-BOUND-B", ownerAgentId: "AGENT-FRESH" });

  // 1) Omitting every Team field after the archive is rejected as legacy degradation.
  const degraded = await dispatchJson(origin, { agentId: "AGENT-BOUND", formalRole: "coder", lifecycleAction: "follow_up", taskId: "BOUND-1-FIX" });
  assert.equal(degraded.status, 400);
  assert.match(degraded.body.error, /已软归档/);

  // 2) Forging a live Team field does not move the Agent out of its archived Team.
  const forged = await dispatchJson(origin, {
    agentId: "AGENT-BOUND",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-BOUND-B",
    taskId: "BOUND-2",
    attemptId: "BOUND-2-A1",
  });
  assert.equal(forged.status, 400);
  assert.match(forged.body.error, /已软归档|已绑定 team TEAM-BOUND-A/);

  // 3) Control: a managed dispatch straight into the archived Team is refused by the Team guard
  //    instead of by the binding guard. The Team check runs before any Task lookup, so the
  //    archived Team is refused even though the Task carries a terminal status.
  const managed = await dispatchJson(origin, {
    agentId: "AGENT-FRESH",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-BOUND-A",
    taskId: "BOUND-1",
    attemptId: "BOUND-1-A2",
  });
  assert.equal(managed.status, 400);
  assert.match(managed.body.error, /已软归档/);

  // Every refused dispatch is inert: no bridge call, no Run/Turn, no turnCount/runIds change and
  // no Task/Attempt mutation.
  assert.equal(fake.calls.length, callsBefore);
  const after = await waitForAgentState(origin, "AGENT-BOUND", ["IDLE"]);
  assert.equal(after.turnCount, turnsBefore);
  assert.deepEqual(after.runIds, runIdsBefore);
  assert.equal(after.currentTaskId, null);
  assert.equal((await runs(origin)).runs.filter((run) => run.agentId === "AGENT-BOUND").length, runIdsBefore.length);
  const bound = (await tasks(origin)).tasks.find((task) => task.taskId === "BOUND-1");
  assert.equal(bound.status, "COMPLETED");
  assert.equal(bound.attempts.length, 1);
  assert.equal(bound.attempts[0].status, "COMPLETED");
  const untouched = (await tasks(origin)).tasks.find((task) => task.taskId === "BOUND-2");
  assert.equal(untouched.status, "READY");
  assert.equal(untouched.attempts.length, 0);
  assert.equal(untouched.ownerAgentId, "AGENT-BOUND");

  // A fresh Agent may still work in the new Team, so the guard is a binding fence and not a
  // blanket refusal of live Teams.
  const live = await dispatchJson(origin, {
    agentId: "AGENT-FRESH",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-BOUND-B",
    taskId: "BOUND-4",
    attemptId: "BOUND-4-A1",
  });
  assert.equal(live.status, 202);
  assert.equal(live.body.task.status, "RUNNING");
  await fake.calls[callsBefore].finish();
  await waitForTask(origin, "BOUND-4", ["COMPLETED"]);
});

test("a bound Team's lifecycle decision survives a monitor restart", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-bound-restart-"));
  const monitors = [];
  context.after(async () => {
    for (const monitor of monitors) await monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  const fake = createFakeBridge();
  const first = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });
  monitors.push(first.monitor);
  await createTeam(first.origin, { teamId: "TEAM-R-A", title: "R A" });
  await createTask(first.origin, { taskId: "R-1", teamId: "TEAM-R-A", ownerAgentId: "AGENT-R" });
  const started = await dispatchJson(first.origin, {
    agentId: "AGENT-R",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-R-A",
    taskId: "R-1",
    attemptId: "R-1-A1",
  });
  assert.equal(started.status, 202);
  await fake.calls[0].finish({ sessionId: "r-session-1" });
  await waitForTask(first.origin, "R-1", ["COMPLETED"]);
  assert.deepEqual((await createTeam(first.origin, { teamId: "TEAM-R-B", title: "R B" })).body.archivedTeamIds, ["TEAM-R-A"]);
  await first.monitor.close();

  // The binding is re-derived from the persisted Attempt, not from in-memory state.
  const second = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });
  monitors.push(second.monitor);
  const degraded = await dispatchJson(second.origin, { agentId: "AGENT-R", formalRole: "coder", lifecycleAction: "follow_up" });
  assert.equal(degraded.status, 400);
  assert.match(degraded.body.error, /已软归档/);
  assert.equal(fake.calls.length, 1);
});

// --- workspace-scoped model selection ---------------------------------------

const MODEL_SETTINGS_YAML = `
llm-pi-ai:
  providers:
    provider-a:
      apiKeyEnv: PROVIDER_A_TOKEN
      headers:
        Authorization: should-never-be-returned
      models:
        - id: model-a
    provider-b:
      baseURL: http://private.internal/v1
      models:
        - id: model-b
agent-default-model:
  provider: provider-a
  model: model-a
`;

test("model settings API is authenticated, revisioned, persisted and injected into spawn/follow_up", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-model-server-"));
  const fake = createFakeBridge();
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const started = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });
  context.after(async () => {
    await started.monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });

  const unauthorized = await fetch(`${started.origin}/api/model-settings`);
  assert.equal(unauthorized.status, 401);
  const initialResponse = await send(started.origin, "GET", "/api/model-settings");
  assert.equal(initialResponse.status, 200);
  const initial = await initialResponse.json();
  assert.equal(initial.revision, 0);
  assert.deepEqual(initial.effective, { provider: "provider-a", model: "model-a" });
  assert.equal(JSON.stringify(initial).includes("should-never-be-returned"), false);
  assert.equal(JSON.stringify(initial).includes("private.internal"), false);

  const selectedResponse = await send(started.origin, "PATCH", "/api/model-settings", {
    selection: { provider: "provider-b", model: "model-b" },
    expectedRevision: 0,
  });
  assert.equal(selectedResponse.status, 200);
  const selected = await selectedResponse.json();
  assert.equal(selected.revision, 1);
  assert.equal(selected.mode, "override");

  const staleResponse = await send(started.origin, "PATCH", "/api/model-settings", {
    selection: { provider: "provider-a", model: "model-a" },
    expectedRevision: 0,
  });
  assert.equal(staleResponse.status, 400);
  assert.match((await staleResponse.json()).error, /其他页面更新/);

  const base = { agentId: "AGENT-MODEL", formalRole: "coder" };
  const spawned = await dispatchJson(started.origin, { ...base, lifecycleAction: "spawn" });
  assert.equal(spawned.status, 202);
  assert.deepEqual(spawned.body.requestedModelSelection, {
    provider: "provider-b",
    model: "model-b",
    revision: 1,
    source: "monitor_override",
  });
  assert.deepEqual(fake.calls[0].args.slice(fake.calls[0].args.indexOf("--model-provider"), -1), [
    "--model-provider", "provider-b", "--model", "model-b",
  ]);
  await fake.calls[0].finish({ sessionId: "model-session-1" });
  const settled = await waitForStatus(started.monitor, spawned.body.id, ["completed"]);
  assert.equal(settled.reasoningEffort, null, "model response without reasoning_effort clears stale evidence");

  const secondSelection = await send(started.origin, "PATCH", "/api/model-settings", {
    selection: { provider: "provider-a", model: "model-a" },
    expectedRevision: 1,
  });
  assert.equal(secondSelection.status, 200);
  const followed = await dispatchJson(started.origin, { ...base, lifecycleAction: "follow_up" });
  assert.equal(followed.status, 202);
  assert.equal(fake.calls[1].resume, "model-session-1");
  assert.equal(fake.calls[1].args[fake.calls[1].args.indexOf("--model-provider") + 1], "provider-a");
  assert.equal(fake.calls[1].args[fake.calls[1].args.indexOf("--model") + 1], "model-a");
  await fake.calls[1].finish();
  await waitForStatus(started.monitor, followed.body.id, ["completed"]);

  const stored = JSON.parse(await readFile(join(workspace, "artifacts", "dsh-monitor", "model-preference.json"), "utf8"));
  assert.equal(stored.revision, 2);
  assert.deepEqual(stored.selection, { provider: "provider-a", model: "model-a" });
});

test("stale model overrides fail before creating a Run or launching a bridge", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-model-stale-"));
  const fake = createFakeBridge();
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const started = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });
  context.after(async () => {
    await started.monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  const selected = await send(started.origin, "PATCH", "/api/model-settings", {
    selection: { provider: "provider-b", model: "model-b" },
    expectedRevision: 0,
  });
  assert.equal(selected.status, 200);
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML.replace("        - id: model-b\n", ""), "utf8");

  const rejected = await dispatchJson(started.origin, {
    agentId: "AGENT-STALE-MODEL",
    formalRole: "coder",
    lifecycleAction: "spawn",
  });
  assert.equal(rejected.status, 400);
  assert.match(rejected.body.error, /未配置模型/);
  assert.equal(fake.calls.length, 0);
  assert.equal(started.monitor.runs.size, 0);
});

test("a requested model without applied evidence cannot settle as completed", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-model-unconfirmed-"));
  const fake = createFakeBridge();
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const started = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });
  context.after(async () => {
    await started.monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });

  const spawned = await dispatchJson(started.origin, {
    agentId: "AGENT-UNCONFIRMED",
    formalRole: "coder",
    lifecycleAction: "spawn",
  });
  assert.equal(spawned.status, 202);
  await fake.calls[0].finish({ sessionId: null, emitSession: false });
  const failed = await waitForStatus(started.monitor, spawned.body.id, ["failed"]);
  assert.equal(failed.phase, "model_config_unconfirmed");
  assert.equal(failed.modelSelectionStatus, "failed");
  assert.match(failed.error, /没有 session_model_configured 证据/);
});

test("model preference survives a monitor restart", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-model-restart-"));
  const monitors = [];
  context.after(async () => {
    for (const monitor of monitors) await monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const first = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(first.monitor);
  const saved = await send(first.origin, "PATCH", "/api/model-settings", {
    selection: { provider: "provider-b", model: "model-b" },
    expectedRevision: 0,
  });
  assert.equal(saved.status, 200);
  await first.monitor.close();

  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(second.monitor);
  const response = await send(second.origin, "GET", "/api/model-settings");
  assert.equal(response.status, 200);
  const restored = await response.json();
  assert.equal(restored.revision, 1);
  assert.equal(restored.mode, "override");
  assert.deepEqual(restored.selection, { provider: "provider-b", model: "model-b" });
});

// --- one-click settings sync (POST /api/sync-settings) ------------------------
//
// The sync child is only a process seam (same pattern as `spawnBridge`): the monitor still owns
// the argv, the safe-summary allow-list, the bounded timeout/output and the model refresh.

const SYNCED_SETTINGS_YAML = `
llm-pi-ai:
  providers:
    provider-a:
      apiKeyEnv: PROVIDER_A_TOKEN
      models:
        - id: model-a
    provider-c:
      apiKeyEnv: PROVIDER_C_TOKEN
      models:
        - id: model-c
agent-default-model:
  provider: provider-c
  model: model-c
`;

const SYNC_SUMMARY_FIXTURE = {
  status: "success",
  provider: "provider-c",
  model: "model-c",
  changed: ["settings.yaml", ".credentials.yaml", "profiles/acp/cordis.patch.yml"],
  notes: ["profiles/acp/cordis.patch.yml 已固定为当前配置的模型。"],
  syncedAt: "2026-01-01T00:00:00.000Z",
  // Deliberate non-summary noise: the allow-list must keep these out of the browser response.
  settingsBody: "apiKeyEnv: LEAKED_SETTINGS_BODY",
  credentialValue: "LEAKED_CREDENTIAL_VALUE",
};

function fakeSyncChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.killed = [];
  child.kill = (signal) => {
    child.killed.push(signal ?? "SIGTERM");
    return true;
  };
  const call = {
    child,    emitStdout(text) { child.stdout.emit("data", Buffer.from(text)); },
    emitStderr(text) { child.stderr.emit("data", Buffer.from(text)); },
    close(code = 0) { child.emit("close", code); },
    succeed(summary = SYNC_SUMMARY_FIXTURE) {
      this.emitStdout(`${JSON.stringify(summary)}\n`);
      this.close(0);
    },
    fail(stderr = "同步失败: injected sync failure") {
      this.emitStderr(`${stderr}\n`);
      this.close(1);
    },
  };
  return { child, call };
}

// `auto` picks the deterministic outcomes; "hold" leaves the child to the test so concurrency,
// timeout and oversized output can be driven explicitly.
function createFakeSettingsSync({ auto = "success" } = {}) {
  const calls = [];
  const spawnSettingsSync = (args, options) => {
    const { child, call } = fakeSyncChild();
    call.args = args;
    call.options = options;
    calls.push(call);
    if (auto === "success") queueMicrotask(() => call.succeed());
    if (auto === "failure") queueMicrotask(() => call.fail());
    if (auto === "garbage") queueMicrotask(() => { call.emitStdout("not json at all\n"); call.close(0); });
    return child;
  };
  return { spawnSettingsSync, calls };
}

function syncSettingsRequest(origin, { token = true, origin: originHeader, cookie } = {}) {
  const headers = {};
  if (token) headers["X-DSH-Monitor-Token"] = TOKEN;
  if (originHeader !== undefined) headers.Origin = originHeader;
  if (cookie) headers.Cookie = cookie;
  return fetch(`${origin}/api/sync-settings`, { method: "POST", headers });
}

async function startSyncMonitor(context, { workspace, userHome, spawnSettingsSync, ...rest }) {
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const started = await startMonitor(context, {
    workspace,
    spawnBridge: createFakeBridge().spawnBridge,
    dshUserHome: userHome,
    spawnSettingsSync,
    ...rest,
  });
  return started;
}

test("sync-settings API keeps the cookie+same-origin write rule and the header token path", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-sync-auth-"));
  const userHome = await mkdtemp(join(tmpdir(), "dsh-sync-auth-user-"));
  const fake = createFakeSettingsSync();
  const started = await startSyncMonitor(context, { workspace, userHome, spawnSettingsSync: fake.spawnSettingsSync });
  context.after(async () => {
    await started.monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
    await rm(userHome, { recursive: true, force: true });
  });

  const anonymous = await fetch(`${started.origin}/api/sync-settings`, { method: "POST" });
  assert.equal(anonymous.status, 403);

  // A stolen cookie is not enough without a same-origin request: a foreign Origin must be refused.
  const crossOriginCookie = await fetch(`${started.origin}/api/sync-settings`, {
    method: "POST",
    headers: { Cookie: `dsh_monitor=${TOKEN}`, Origin: "http://evil.example" },
  });
  assert.equal(crossOriginCookie.status, 403);

  const crossOriginToken = await syncSettingsRequest(started.origin, { origin: "http://evil.example" });
  assert.equal(crossOriginToken.status, 403);

  // Origin-less non-browser callers (Coordinator, curl, tests) keep working through the header token.
  const headerToken = await syncSettingsRequest(started.origin);
  assert.equal(headerToken.status, 200);

  // The browser path: the HttpOnly cookie index.html sets, plus its own Origin.
  const viaCookie = await syncSettingsRequest(started.origin, { token: false, cookie: `dsh_monitor=${TOKEN}`, origin: started.origin });
  assert.equal(viaCookie.status, 200);

  assert.equal(fake.calls.length, 2, "只有被授权的两次请求可以真正启动同步脚本");
});

test("sync-settings launches only the Sync-DshTeamConfig CLI and answers with the safe summary", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-sync-summary-"));
  const userHome = await mkdtemp(join(tmpdir(), "dsh-sync-summary-user-"));
  const fake = createFakeSettingsSync();
  const started = await startSyncMonitor(context, { workspace, userHome, spawnSettingsSync: fake.spawnSettingsSync });
  context.after(async () => {
    await started.monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
    await rm(userHome, { recursive: true, force: true });
  });

  const response = await syncSettingsRequest(started.origin);
  const body = await response.json();
  assert.equal(response.status, 200);
  assert.equal(body.status, "success");
  assert.equal(body.provider, "provider-c");
  assert.equal(body.model, "model-c");
  assert.deepEqual(body.changed, ["settings.yaml", ".credentials.yaml", "profiles/acp/cordis.patch.yml"]);
  assert.deepEqual(body.notes, ["profiles/acp/cordis.patch.yml 已固定为当前配置的模型。"]);
  assert.equal(body.syncedAt, "2026-01-01T00:00:00.000Z");
  assert.equal(Number.isInteger(body.durationMs), true);

  const { args, options } = fake.calls[0];
  assert.equal(args[args.indexOf("-File") + 1].endsWith("Sync-DshTeamConfig.ps1"), true);
  assert.equal(args[args.indexOf("-UserDshHome") + 1], userHome);
  assert.equal(args[args.indexOf("-TeamDshHome") + 1], workspace);
  assert.equal(args.some((arg) => String(arg).includes("start_dsh_team")), false,
    "同步绝不能调用会停掉 Monitor 的 start_dsh_team.ps1");
  assert.equal(args.some((arg) => String(arg).includes("-SkipSync")), false);

  // 子进程环境只允许非敏感变量：Monitor 自己携带的 home 覆盖与 provider token 都不下发。
  const childEnvKeys = Object.keys(options.env ?? {});
  assert.equal(childEnvKeys.some((key) => /TOKEN|KEY|SECRET|PASSW|DSH_HOME|REMOTE_TO_DSH/i.test(key)), false);
  assert.equal(childEnvKeys.includes("PATH"), true);

  // 安全摘要 allow-list：脚本万一多吐了设置正文或凭据值，也不能进入浏览器响应。
  const text = JSON.stringify(body);
  assert.equal(text.includes("LEAKED_SETTINGS_BODY"), false);
  assert.equal(text.includes("LEAKED_CREDENTIAL_VALUE"), false);

  // 一键同步不重启/停止当前 server：同一个实例继续提供 health 与投影。
  const health = await fetch(`${started.origin}/api/health`).then((value) => value.json());
  assert.equal(health.service, "dsh-team-monitor");
  assert.equal(health.ok, true);
  assert.equal(health.dshHome, workspace);
});

test("sync-settings refreshes and broadcasts model settings so the next dispatch sees them", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-sync-refresh-"));
  const userHome = await mkdtemp(join(tmpdir(), "dsh-sync-refresh-user-"));
  const bridge = createFakeBridge();
  const calls = [];
  const spawnSettingsSync = (args, options) => {
    const { child, call } = fakeSyncChild();
    call.args = args;
    call.options = options;
    calls.push(call);
    queueMicrotask(async () => {
      // 真实同步脚本的效果就是把主 Home 的运行配置复制进 Team Home；这里用重写 settings.yaml
      // 来代表同一结果，以便证明刷新来自磁盘而不是缓存。
      await writeFile(join(workspace, "settings.yaml"), SYNCED_SETTINGS_YAML, "utf8");
      call.succeed({ ...SYNC_SUMMARY_FIXTURE, notes: [] });
    });
    return child;
  };
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const started = await startMonitor(context, {
    workspace,
    spawnBridge: bridge.spawnBridge,
    dshUserHome: userHome,
    spawnSettingsSync,
  });
  context.after(async () => {
    await started.monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
    await rm(userHome, { recursive: true, force: true });
  });

  // SSE 客户端先就位，才能真正验证同步完成后广播了 model-settings。
  // 与既有 Team/Task SSE 测试相同：用 raw client，测试必须能 destroy socket，否则
  // monitor.close() 会等满 HTTP keep-alive 超时。
  let streamText = "";
  const sse = httpRequest(`${started.origin}/api/events`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  const sseResponse = await new Promise((resolvePromise, rejectPromise) => {
    sse.on("response", resolvePromise);
    sse.on("error", rejectPromise);
    sse.end();
  });
  assert.equal(sseResponse.statusCode, 200);
  sseResponse.setEncoding("utf8");
  sseResponse.on("data", (chunk) => { streamText += chunk; });
  const readUntil = async (needle, timeoutMs = 5000) => {
    const deadline = Date.now() + timeoutMs;
    while (!streamText.includes(needle)) {
      if (Date.now() > deadline) throw new Error(`SSE timeout waiting for ${needle}: ${streamText}`);
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
    }
  };
  await readUntil("event: snapshot");

  const beforeResponse = await send(started.origin, "GET", "/api/model-settings");
  const before = await beforeResponse.json();
  assert.deepEqual(before.effective, { provider: "provider-a", model: "model-a" });
  assert.equal(before.settingsSync.available, true);
  assert.equal(before.settingsSync.reason, null);
  assert.equal(before.lastSync, null);

  const body = await (await syncSettingsRequest(started.origin)).json();
  assert.deepEqual(body.modelSettings.effective, { provider: "provider-c", model: "model-c" });
  assert.equal(calls.length, 1);

  await readUntil("event: model-settings");
  const broadcastBlock = streamText.slice(streamText.indexOf("event: model-settings"));
  const broadcastData = JSON.parse(broadcastBlock.split("\n").find((line) => line.startsWith("data: ")).slice("data: ".length));
  assert.deepEqual(broadcastData.dshDefault, { provider: "provider-c", model: "model-c" });

  const after = await (await send(started.origin, "GET", "/api/model-settings")).json();
  assert.deepEqual(after.effective, { provider: "provider-c", model: "model-c" });
  assert.deepEqual(after.dshDefault, { provider: "provider-c", model: "model-c" });
  assert.equal(after.lastSync.provider, "provider-c");
  assert.equal(after.lastSync.model, "model-c");
  sse.destroy();

  // 关键验收：同一个 server 实例、没有任何重启，下一次 dispatch 就用上了新的默认模型。
  const spawned = await dispatchJson(started.origin, {
    agentId: "AGENT-AFTER-SYNC",
    formalRole: "coder",
    lifecycleAction: "spawn",
  });
  assert.equal(spawned.status, 202);
  assert.deepEqual(spawned.body.requestedModelSelection, {
    provider: "provider-c",
    model: "model-c",
    revision: 0,
    source: "dsh_default",
  });
  await bridge.calls[0].finish({ sessionId: "sync-session-1" });
  await waitForStatus(started.monitor, spawned.body.id, ["completed"]);
});

test("sync-settings serialises concurrent syncs into a single child process", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-sync-concurrent-"));
  const userHome = await mkdtemp(join(tmpdir(), "dsh-sync-concurrent-user-"));
  const fake = createFakeSettingsSync({ auto: "hold" });
  const started = await startSyncMonitor(context, { workspace, userHome, spawnSettingsSync: fake.spawnSettingsSync });
  context.after(async () => {
    await started.monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
    await rm(userHome, { recursive: true, force: true });
  });

  const inFlight = syncSettingsRequest(started.origin);
  for (let attempt = 0; attempt < 100 && fake.calls.length === 0; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(fake.calls.length, 1);

  const blocked = await syncSettingsRequest(started.origin);
  assert.equal(blocked.status, 409);
  assert.match((await blocked.json()).error, /正在进行/);
  assert.equal(fake.calls.length, 1, "并发请求绝不能启动第二个同步进程");

  fake.calls[0].succeed();
  const first = await inFlight;
  assert.equal(first.status, 200);
  assert.equal((await first.json()).status, "success");

  // 锁随请求结束而释放：之后的请求可以再次同步。
  const followUp = syncSettingsRequest(started.origin);
  for (let attempt = 0; attempt < 100 && fake.calls.length < 2; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.equal(fake.calls.length, 2);
  fake.calls[1].succeed();
  const followUpResponse = await followUp;
  assert.equal(followUpResponse.status, 200);
});

test("sync-settings surfaces script failure, timeout and oversized output as bounded errors", async (context) => {
  const workspaces = [];
  const userHomes = [];
  const makeHomes = async (prefix) => {
    const workspace = await mkdtemp(join(tmpdir(), `${prefix}-home-`));
    const userHome = await mkdtemp(join(tmpdir(), `${prefix}-user-`));
    workspaces.push(workspace);
    userHomes.push(userHome);
    return { workspace, userHome };
  };
  context.after(async () => {
    for (const path of [...workspaces, ...userHomes]) await rm(path, { recursive: true, force: true });
  });

  // 1. 脚本非零退出：502 + 有界错误消息，Monitor 继续服务。
  const failureHomes = await makeHomes("dsh-sync-fail");
  const failure = createFakeSettingsSync({ auto: "failure" });
  const failureMonitor = await startSyncMonitor(context, { ...failureHomes, spawnSettingsSync: failure.spawnSettingsSync });
  const failureResponse = await syncSettingsRequest(failureMonitor.origin);
  assert.equal(failureResponse.status, 502);
  assert.match((await failureResponse.json()).error, /injected sync failure/);
  assert.equal((await (await fetch(`${failureMonitor.origin}/api/health`)).json()).ok, true,
    "同步失败不能影响 Monitor 自身");
  await failureMonitor.monitor.close();

  // 2. 超时：504，被终止的是同步子进程，不是 Monitor。
  const timeoutHomes = await makeHomes("dsh-sync-timeout");
  const timeout = createFakeSettingsSync({ auto: "hold" });
  const timeoutMonitor = await startSyncMonitor(context, {
    ...timeoutHomes,
    spawnSettingsSync: timeout.spawnSettingsSync,
    settingsSyncTimeoutMs: 40,
  });
  const timeoutResponse = await syncSettingsRequest(timeoutMonitor.origin);
  assert.equal(timeoutResponse.status, 504);
  assert.match((await timeoutResponse.json()).error, /没有完成/);
  assert.deepEqual(timeout.calls[0].child.killed, ["SIGKILL"]);
  assert.equal((await (await fetch(`${timeoutMonitor.origin}/api/health`)).json()).ok, true);
  await timeoutMonitor.monitor.close();

  // 3. 超大输出：拒绝结果，且响应体本身被限长，绝不回吐整段输出。
  const overflowHomes = await makeHomes("dsh-sync-overflow");
  const overflow = createFakeSettingsSync({ auto: "hold" });
  const overflowMonitor = await startSyncMonitor(context, {
    ...overflowHomes,
    spawnSettingsSync: overflow.spawnSettingsSync,
    settingsSyncMaxOutputBytes: 64,
  });
  const overflowPromise = syncSettingsRequest(overflowMonitor.origin);
  for (let attempt = 0; attempt < 100 && overflow.calls.length === 0; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  overflow.calls[0].emitStdout(`{"status":"success","provider":"a","model":"b","marker":"${"OVERFLOW_".repeat(40)}"`);
  const overflowResponse = await overflowPromise;
  const overflowText = await overflowResponse.text();
  assert.equal(overflowResponse.status >= 500, true);
  assert.equal(overflowText.includes("OVERFLOW_"), false);
  assert.equal(overflowText.length < 400, true);
  await overflowMonitor.monitor.close();
});

test("sync-settings refuses when the main and Team DSH homes are not a usable pair", async (context) => {
  const workspaces = [];
  context.after(async () => {
    for (const path of workspaces) await rm(path, { recursive: true, force: true });
  });

  // 没有主 DSH Home（例如直接由 start_dsh_monitor.ps1 启动）：按钮不可用，请求也被拒绝。
  // 本用例依赖 `createMonitorServer` 只读取显式配置：环境回退由 CLI 入口（parseArgs）负责，
  // 因此这里不继承开发机 shell 里的 DSH_USER_HOME，也不需要在用例里清理 process.env。
  const unconfiguredWorkspace = await mkdtemp(join(tmpdir(), "dsh-sync-nouser-"));
  workspaces.push(unconfiguredWorkspace);
  const unconfiguredSync = createFakeSettingsSync();
  await writeFile(join(unconfiguredWorkspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const unconfigured = await startMonitor(context, {
    workspace: unconfiguredWorkspace,
    spawnBridge: createFakeBridge().spawnBridge,
    spawnSettingsSync: unconfiguredSync.spawnSettingsSync,
  });
  const unconfiguredProjection = await (await send(unconfigured.origin, "GET", "/api/model-settings")).json();
  assert.equal(unconfiguredProjection.settingsSync.available, false);
  assert.match(unconfiguredProjection.settingsSync.reason, /--dsh-user-home/);
  const unconfiguredResponse = await syncSettingsRequest(unconfigured.origin);
  assert.equal(unconfiguredResponse.status, 409);
  assert.match((await unconfiguredResponse.json()).error, /--dsh-user-home/);
  assert.equal(unconfiguredSync.calls.length, 0);
  await unconfigured.monitor.close();

  // 主 Home 与 Team Home 相同：拒绝把配置同步到它自己。
  const sameWorkspace = await mkdtemp(join(tmpdir(), "dsh-sync-same-"));
  workspaces.push(sameWorkspace);
  const sameSync = createFakeSettingsSync();
  await writeFile(join(sameWorkspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");
  const same = await startMonitor(context, {
    workspace: sameWorkspace,
    spawnBridge: createFakeBridge().spawnBridge,
    dshUserHome: sameWorkspace,
    spawnSettingsSync: sameSync.spawnSettingsSync,
  });
  const sameProjection = await (await send(same.origin, "GET", "/api/model-settings")).json();
  assert.equal(sameProjection.settingsSync.available, false);
  assert.match(sameProjection.settingsSync.reason, /同一目录/);
  const sameResponse = await syncSettingsRequest(same.origin);
  assert.equal(sameResponse.status, 409);
  assert.match((await sameResponse.json()).error, /同一目录/);
  assert.equal(sameSync.calls.length, 0);
  await same.monitor.close();
});

test("createMonitorServer ignores ambient DSH environment configuration", async (context) => {
  // Regression for the isolation defect that made this file environment-dependent: the factory
  // used to fall back to REMOTE_TO_DSH_HOME / DSH_HOME / DSH_USER_HOME / CODEX_DSH_TEAM_INSTALL_ID
  // from `process.env`, so a developer shell with DSH_USER_HOME exported changed the monitor
  // under test (the "not a usable pair" case above then failed and leaked a listening socket).
  // The environment fallbacks belong to the CLI entry point (parseArgs); the factory must use
  // explicit options only.
  const workspace = await mkdtemp(join(tmpdir(), "dsh-env-isolation-"));
  const ambientHome = await mkdtemp(join(tmpdir(), "dsh-env-isolation-ambient-"));
  context.after(() => rm(workspace, { recursive: true, force: true }));
  context.after(() => rm(ambientHome, { recursive: true, force: true }));
  await writeFile(join(workspace, "settings.yaml"), MODEL_SETTINGS_YAML, "utf8");

  const saved = {
    DSH_HOME: process.env.DSH_HOME,
    REMOTE_TO_DSH_HOME: process.env.REMOTE_TO_DSH_HOME,
    DSH_USER_HOME: process.env.DSH_USER_HOME,
    CODEX_DSH_TEAM_INSTALL_ID: process.env.CODEX_DSH_TEAM_INSTALL_ID,
  };
  const restore = () => {
    for (const [key, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  };
  context.after(restore);
  process.env.DSH_HOME = ambientHome;
  process.env.REMOTE_TO_DSH_HOME = ambientHome;
  process.env.DSH_USER_HOME = ambientHome;
  process.env.CODEX_DSH_TEAM_INSTALL_ID = "ambient-install-id";
  try {
    const monitor = closeMonitorAfter(context, createMonitorForTest({
      workspace,
      dshHome: workspace,
      port: 0,
      token: TOKEN,
      spawnBridge: createFakeBridge().spawnBridge,
    }));
    const address = await monitor.start();
    const origin = `http://127.0.0.1:${address.port}`;

    // 显式 dshHome 生效：环境里的 REMOTE_TO_DSH_HOME/DSH_HOME 不得覆盖它。
    const health = await fetch(`${origin}/api/health`).then((response) => response.json());
    assert.equal(health.dshHome, workspace);
    // 环境里的 install id 不得把 monitor 变成"必须证明 ownership"：本用例能构造成功本身
    // 就说明 ambient install id 未被采纳，这里再断言证据字段。
    assert.notEqual(health.security.teamHomeOwnership.state, "owned");
    assert.equal(health.security.teamHomeOwnership.installId, null);
    // 环境里的 DSH_USER_HOME 不得成为一键同步来源。
    const projection = await (await send(origin, "GET", "/api/model-settings")).json();
    assert.equal(projection.settingsSync.available, false);
    assert.match(projection.settingsSync.reason, /--dsh-user-home/);
  } finally {
    restore();
  }
});

// --- Agent control plane: Coordinator recruit / stop / retire + GUI auth + member cap ---
//
// Authoritative contract: `.dsh/contracts/WP-CTRL-CODER-BACKEND.md` (backend in flight) and
// `.dsh/contracts/WP-CTRL-CODER-FRONTEND.md` (GUI). These deterministic tests are written
// against that API contract and only become green once the backend lands. No real DSH is
// launched anywhere: the existing `createFakeBridge` double drives every Run path.

// Coordinator-side agent stop/retire (header token). `payload` may carry the stale fence
// fields `expectedTaskId` / `expectedRunId` / `reason`; when provided they must exactly match
// the current projection or the request is refused.
function agentStop(origin, agentId, payload) {
  return patchAgent(origin, agentId, { action: "stop", ...payload });
}

function agentRetire(origin, agentId, payload) {
  return patchAgent(origin, agentId, { action: "retire", ...payload });
}

// Browser session emulation: GET / acquires the HttpOnly monitor cookie exactly like a real
// browser does, then every request re-sends it together with its own same-origin Origin header.
async function browserCookie(origin) {
  const response = await fetch(origin);
  const setCookie = response.headers.get("set-cookie") ?? "";
  const match = setCookie.match(/dsh_monitor=([^;]+)/);
  assert.ok(match, `GET / must set the monitor cookie (got: ${setCookie})`);
  assert.match(setCookie, /HttpOnly/, "the monitor cookie must stay HttpOnly");
  return `dsh_monitor=${match[1]}`;
}

// Reader-only GUI request: cookie + same-origin by default; `sameOrigin: false` drops the
// Origin header and `crossOrigin` substitutes a foreign Origin for the denial cases.
async function guiRequest(origin, method, path, payload, { cookie, sameOrigin = true, crossOrigin } = {}) {
  const options = { method, headers: { "Content-Type": "application/json" } };
  if (cookie) options.headers.Cookie = cookie;
  const originValue = crossOrigin ?? (sameOrigin ? origin : undefined);
  if (originValue !== undefined) options.headers.Origin = originValue;
  if (payload !== undefined) options.body = JSON.stringify(payload);
  return fetch(`${origin}${path}`, options);
}

test("CTA-1: Coordinator header recruit/stop/retire normal chain and error chain", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-CTRL", title: "Control" });
  await createTask(origin, { taskId: "CTRL-1", teamId: "TEAM-CTRL" });
  await createTask(origin, { taskId: "CTRL-2", teamId: "TEAM-CTRL" });

  // recruit (POST /api/agents) is Coordinator-only and starts IDLE, never terminated.
  const recruited = await registerAgent(origin, {
    agentId: "EXT-CTRL",
    formalRole: "tester",
    teamId: "TEAM-CTRL",
    backend: "codex",
  });
  assert.equal(recruited.status, 201);
  assert.equal(recruited.body.state, "IDLE");
  assert.equal(recruited.body.terminated, false);

  // validation errors: unknown agent and unknown action.
  const missing = await agentStop(origin, "EXT-MISSING");
  assert.equal(missing.status, 400);
  assert.match(missing.body.error, /未知 agent/);
  assert.equal((await patchAgent(origin, "EXT-CTRL", { action: "frobnicate" })).status, 400);

  // normal work chain: assign -> start -> RUNNING.
  await patchTask(origin, "CTRL-1", { action: "assign", agentId: "EXT-CTRL", attemptId: "CTRL-1-A1" });
  await patchTask(origin, "CTRL-1", { action: "start", attemptId: "CTRL-1-A1" });
  assert.equal((await waitForAgentState(origin, "EXT-CTRL", ["RUNNING"])).currentTaskId, "CTRL-1");

  // an active member cannot be retired: stop first, wait for IDLE, then retire.
  const activeRetire = await agentRetire(origin, "EXT-CTRL");
  assert.equal(activeRetire.status, 400);
  assert.match(activeRetire.body.error, /active Task/);

  // stale UI fence: a stop for a task that is not the current one is refused and changes nothing.
  const stale = await agentStop(origin, "EXT-CTRL", { expectedTaskId: "CTRL-OTHER" });
  assert.equal(stale.status, 400);
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "CTRL-1").status, "RUNNING");

  const stopped = await agentStop(origin, "EXT-CTRL", { expectedTaskId: "CTRL-1", reason: "coordinator stop" });
  assert.equal(stopped.status, 200);
  assert.equal((await waitForAgentState(origin, "EXT-CTRL", ["IDLE"])).currentTaskId, null);
  const cancelled = (await tasks(origin)).tasks.find((task) => task.taskId === "CTRL-1");
  assert.equal(cancelled.status, "CANCELLED");
  assert.equal(cancelled.attempts[0].status, "CANCELLED");

  // duplicate stop on an idle member is an idempotent no-op success.
  assert.equal((await agentStop(origin, "EXT-CTRL")).status, 200);

  const retired = await agentRetire(origin, "EXT-CTRL", { reason: "pool retired" });
  assert.equal(retired.status, 200);
  assert.equal(retired.body.terminated, true);
  assert.equal(retired.body.terminationReason, "pool retired");
  assert.equal(typeof retired.body.terminatedAt, "string");

  // duplicate retire is an explicit 400, not an idempotent success.
  const retiredAgain = await agentRetire(origin, "EXT-CTRL");
  assert.equal(retiredAgain.status, 400);
  assert.match(retiredAgain.body.error, /terminated|退役|终态/);
  // legacy terminate stays compatible and is equally refused on the retired member.
  assert.equal((await patchAgent(origin, "EXT-CTRL", { action: "terminate" })).status, 400);

  // a retired member cannot be reused by the external path.
  const refusedAssign = await patchTask(origin, "CTRL-2", { action: "assign", agentId: "EXT-CTRL", attemptId: "CTRL-2-A1" });
  assert.equal(refusedAssign.status, 400);
  assert.match(refusedAssign.body.error, /terminate|退役/);
});

test("CTA-2: browser HttpOnly cookie + same-origin may stop/retire but never recruit or edit the Task DAG", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-GUI", title: "GUI" });
  await createTask(origin, { taskId: "GUI-1", teamId: "TEAM-GUI" });
  await createTask(origin, { taskId: "GUI-DSH", teamId: "TEAM-GUI" });
  await createTask(origin, { taskId: "GUI-2", teamId: "TEAM-GUI", dependencies: ["GUI-1"] });
  await registerAgent(origin, { agentId: "EXT-GUI", formalRole: "tester", teamId: "TEAM-GUI", backend: "codex" });
  await patchTask(origin, "GUI-1", { action: "assign", agentId: "EXT-GUI", attemptId: "GUI-1-A1" });
  await patchTask(origin, "GUI-1", { action: "start", attemptId: "GUI-1-A1" });

  const cookie = await browserCookie(origin);

  // recruit stays Coordinator-only: the browser can never register members.
  const recruit = await guiRequest(origin, "POST", "/api/agents", {
    agentId: "EXT-GUI-2",
    formalRole: "tester",
    teamId: "TEAM-GUI",
    backend: "codex",
  }, { cookie });
  assert.equal(recruit.status, 403);

  // Task DAG writes stay Coordinator-only: assign / reassign / dependency edit are refused.
  const assign = await guiRequest(origin, "PATCH", "/api/tasks/GUI-2", {
    action: "assign",
    agentId: "EXT-GUI",
    attemptId: "GUI-2-A1",
  }, { cookie });
  assert.equal(assign.status, 403);
  const reassign = await guiRequest(origin, "PATCH", "/api/tasks/GUI-1", { action: "reassign", ownerAgentId: "EXT-GUI" }, { cookie });
  assert.equal(reassign.status, 403);
  const dependencyEdit = await guiRequest(origin, "PATCH", "/api/tasks/GUI-2", { dependencies: [] }, { cookie });
  assert.equal(dependencyEdit.status, 403);

  // stop with the same-origin cookie is allowed for an external member.
  const stopped = await guiRequest(origin, "PATCH", "/api/agents/EXT-GUI", { action: "stop", expectedTaskId: "GUI-1" }, { cookie });
  assert.equal(stopped.status, 200);
  assert.equal((await waitForAgentState(origin, "EXT-GUI", ["IDLE"])).currentTaskId, null);
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "GUI-1").status, "CANCELLED");

  // retire with the same-origin cookie is allowed too.
  const retired = await guiRequest(origin, "PATCH", "/api/agents/EXT-GUI", { action: "retire", reason: "gui retire" }, { cookie });
  assert.equal(retired.status, 200);
  assert.equal((await runs(origin)).agents.find((agent) => agent.agentId === "EXT-GUI").terminated, true);

  // the same browser path stops a live DSH member through the existing cancel control.
  const spawned = await dispatchJson(origin, {
    agentId: "DSH-GUI",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-GUI",
    taskId: "GUI-DSH",
    attemptId: "GUI-DSH-A1",
  });
  assert.equal(spawned.status, 202);
  const guiStop = await guiRequest(origin, "PATCH", "/api/agents/DSH-GUI", {
    action: "stop",
    expectedTaskId: "GUI-DSH",
    expectedRunId: spawned.body.id,
  }, { cookie });
  assert.equal(guiStop.status, 200);
  await waitForStatus(monitor, spawned.body.id, ["cancelling"]);
  await fake.calls[0].finish({ sessionId: "gui-dsh-session-1", exitCode: 1 });
  await waitForStatus(monitor, spawned.body.id, ["cancelled"]);
  assert.equal((await waitForTask(origin, "GUI-DSH", ["CANCELLED"])).attempts[0].status, "CANCELLED");
  const dshAgent = await waitForAgentState(origin, "DSH-GUI", ["IDLE"]);
  assert.equal(dshAgent.sessionId, "gui-dsh-session-1", "stop must not delete the session binding");
  await monitor.close();
});

test("CTA-3: tokenless and cross-origin stop/retire/recruit are refused", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-DENY", title: "Deny" });
  await createTask(origin, { taskId: "DENY-1", teamId: "TEAM-DENY" });
  await registerAgent(origin, { agentId: "EXT-DENY", formalRole: "tester", teamId: "TEAM-DENY", backend: "codex" });
  await patchTask(origin, "DENY-1", { action: "assign", agentId: "EXT-DENY", attemptId: "DENY-1-A1" });
  const cookie = await browserCookie(origin);

  const bare = (method, path, payload) => fetch(`${origin}${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });

  // tokenless: no header token, no cookie.
  assert.equal((await bare("PATCH", "/api/agents/EXT-DENY", { action: "stop" })).status, 403);
  assert.equal((await bare("PATCH", "/api/agents/EXT-DENY", { action: "retire" })).status, 403);
  assert.equal((await bare("POST", "/api/agents", { agentId: "EXT-NOPE", formalRole: "tester", teamId: "TEAM-DENY", backend: "codex" })).status, 403);

  // cookie without an Origin header is not a browser request and is refused.
  assert.equal((await guiRequest(origin, "PATCH", "/api/agents/EXT-DENY", { action: "stop" }, { cookie, sameOrigin: false })).status, 403);

  // a stolen cookie across a foreign Origin is refused.
  assert.equal((await guiRequest(origin, "PATCH", "/api/agents/EXT-DENY", { action: "stop" }, { cookie, crossOrigin: "http://evil.example" })).status, 403);
  assert.equal((await guiRequest(origin, "PATCH", "/api/agents/EXT-DENY", { action: "retire" }, { cookie, crossOrigin: "http://evil.example" })).status, 403);

  // even a valid header token is refused when the request claims a foreign Origin.
  const tokenCross = (method, path, payload) => fetch(`${origin}${path}`, {
    method,
    headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN, Origin: "http://evil.example" },
    body: JSON.stringify(payload),
  });
  assert.equal((await tokenCross("PATCH", "/api/agents/EXT-DENY", { action: "stop" })).status, 403);
  assert.equal((await tokenCross("PATCH", "/api/agents/EXT-DENY", { action: "retire" })).status, 403);
  assert.equal((await tokenCross("POST", "/api/agents", { agentId: "EXT-NOPE2", formalRole: "tester", teamId: "TEAM-DENY", backend: "codex" })).status, 403);

  // every denied request is inert: nothing stopped, retired or recruited.
  const after = await runs(origin);
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "DENY-1").status, "ASSIGNED");
  assert.equal(after.agents.find((agent) => agent.agentId === "EXT-DENY").terminated, false);
  assert.deepEqual(after.agents.map((agent) => agent.agentId), ["EXT-DENY"]);
});

test("CTA-4: stopping a DSH Team Task settles Run/Task/Attempt CANCELLED, IDLE Agent and a reusable session", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-DSH-STOP", title: "DSH stop" });
  await createTask(origin, { taskId: "DSTOP-1", teamId: "TEAM-DSH-STOP" });
  await createTask(origin, { taskId: "DSTOP-2", teamId: "TEAM-DSH-STOP" });

  const spawned = await dispatchJson(origin, {
    agentId: "AGENT-DSH-STOP",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-DSH-STOP",
    taskId: "DSTOP-1",
    attemptId: "DSTOP-1-A1",
  });
  assert.equal(spawned.status, 202);
  assert.equal(spawned.body.task.status, "RUNNING");
  const runId = spawned.body.id;

  // stale run fence: a stop for a different run is refused and leaves the run running.
  const wrongRun = await agentStop(origin, "AGENT-DSH-STOP", { expectedTaskId: "DSTOP-1", expectedRunId: "not-the-run" });
  assert.equal(wrongRun.status, 400);
  assert.equal((await waitForAgentState(origin, "AGENT-DSH-STOP", ["RUNNING"])).currentTaskId, "DSTOP-1");

  const stopped = await agentStop(origin, "AGENT-DSH-STOP", { expectedTaskId: "DSTOP-1", expectedRunId: runId, reason: "dsh stop" });
  assert.equal(stopped.status, 200);
  const cancelling = await waitForStatus(monitor, runId, ["cancelling"]);
  assert.equal(cancelling.phase, "cancel_requested");

  // the bridge observes the cancel control, closes, and the run settles as cancelled.
  await fake.calls[0].finish({ sessionId: "dstop-session-1", exitCode: 1 });
  assert.equal((await waitForStatus(monitor, runId, ["cancelled"])).status, "cancelled");
  const settledTask = await waitForTask(origin, "DSTOP-1", ["CANCELLED"]);
  assert.equal(settledTask.attempts[0].status, "CANCELLED");
  const agent = await waitForAgentState(origin, "AGENT-DSH-STOP", ["IDLE"]);
  assert.equal(agent.currentTaskId, null);
  assert.equal(agent.sessionId, "dstop-session-1", "stop must not delete the session binding");
  assert.equal(agent.terminated, false);

  // the same session remains reusable: follow_up resumes the same session as turn 2.
  const followUp = await dispatchJson(origin, {
    agentId: "AGENT-DSH-STOP",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-DSH-STOP",
    taskId: "DSTOP-2",
    attemptId: "DSTOP-2-A1",
  });
  assert.equal(followUp.status, 202);
  assert.equal(followUp.body.sessionId, "dstop-session-1");
  assert.equal(fake.calls[1].resume, "dstop-session-1");
  await fake.calls[1].finish({ sessionId: "dstop-session-1" });
  await waitForTask(origin, "DSTOP-2", ["COMPLETED"]);
  assert.equal((await waitForAgentState(origin, "AGENT-DSH-STOP", ["IDLE"])).turnCount, 2);
  await monitor.close();
});

test("CTA-5: external ASSIGNED and RUNNING stops settle CANCELLED; stale fences and duplicate stops stay safe", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-EXT-STOP", title: "External stop" });
  await createTask(origin, { taskId: "ES-ASSIGNED", teamId: "TEAM-EXT-STOP" });
  await createTask(origin, { taskId: "ES-RUNNING", teamId: "TEAM-EXT-STOP" });
  await createTask(origin, { taskId: "ES-LATER", teamId: "TEAM-EXT-STOP" });
  await registerAgent(origin, { agentId: "EXT-STOP", formalRole: "tester", teamId: "TEAM-EXT-STOP", backend: "codex" });

  // ASSIGNED stop: the attempt is CANCELLED without ever starting.
  await patchTask(origin, "ES-ASSIGNED", { action: "assign", agentId: "EXT-STOP", attemptId: "ES-ASSIGNED-A1" });
  const wrongTaskFence = await agentStop(origin, "EXT-STOP", { expectedTaskId: "ES-LATER" });
  assert.equal(wrongTaskFence.status, 400);
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "ES-ASSIGNED").status, "ASSIGNED", "a refused stop changes nothing");
  // an external member has no active run, so a provided expectedRunId can never match its null projection.
  assert.equal((await agentStop(origin, "EXT-STOP", { expectedTaskId: "ES-ASSIGNED", expectedRunId: "some-run" })).status, 400);

  const stoppedAssigned = await agentStop(origin, "EXT-STOP", { expectedTaskId: "ES-ASSIGNED" });
  assert.equal(stoppedAssigned.status, 200);
  const assignedTask = (await tasks(origin)).tasks.find((task) => task.taskId === "ES-ASSIGNED");
  assert.equal(assignedTask.status, "CANCELLED");
  assert.equal(assignedTask.attempts[0].status, "CANCELLED");

  // RUNNING stop: start first, then stop.
  await patchTask(origin, "ES-RUNNING", { action: "assign", agentId: "EXT-STOP", attemptId: "ES-RUNNING-A1" });
  await patchTask(origin, "ES-RUNNING", { action: "start", attemptId: "ES-RUNNING-A1" });
  assert.equal((await waitForAgentState(origin, "EXT-STOP", ["RUNNING"])).currentTaskId, "ES-RUNNING");
  const stoppedRunning = await agentStop(origin, "EXT-STOP", { expectedTaskId: "ES-RUNNING" });
  assert.equal(stoppedRunning.status, 200);
  const runningTask = (await tasks(origin)).tasks.find((task) => task.taskId === "ES-RUNNING");
  assert.equal(runningTask.status, "CANCELLED");
  assert.equal(runningTask.attempts[0].status, "CANCELLED");
  assert.equal((await waitForAgentState(origin, "EXT-STOP", ["IDLE"])).currentTaskId, null);

  // duplicate stop on the now-idle member is an idempotent success.
  assert.equal((await agentStop(origin, "EXT-STOP")).status, 200);

  // the stops never resurrected or duplicated attempts: exactly one CANCELLED attempt per task.
  const projection = await tasks(origin);
  for (const taskId of ["ES-ASSIGNED", "ES-RUNNING"]) {
    const task = projection.tasks.find((item) => item.taskId === taskId);
    assert.equal(task.attempts.length, 1);
    assert.equal(task.attempts[0].status, "CANCELLED");
  }
});

test("CTA-6: active retire is refused; stop→idle→retire keeps history, fences reuse and survives restart", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-agent-ctrl-retire-"));
  const monitors = [];
  context.after(async () => {
    for (const monitor of monitors) await monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  const fake = createFakeBridge();
  const first = await startMonitor(context, { workspace, spawnBridge: fake.spawnBridge });
  monitors.push(first.monitor);
  const { origin } = first;
  await createTeam(origin, { teamId: "TEAM-RETIRE", title: "Retire" });
  await createTask(origin, { taskId: "RETIRE-1", teamId: "TEAM-RETIRE" });
  await createTask(origin, { taskId: "RETIRE-2", teamId: "TEAM-RETIRE" });
  await registerAgent(origin, { agentId: "EXT-RETIRE", formalRole: "tester", teamId: "TEAM-RETIRE", backend: "codex" });

  // a RUNNING member cannot be retired.
  await patchTask(origin, "RETIRE-1", { action: "assign", agentId: "EXT-RETIRE", attemptId: "RETIRE-1-A1" });
  await patchTask(origin, "RETIRE-1", { action: "start", attemptId: "RETIRE-1-A1" });
  const activeRetire = await agentRetire(origin, "EXT-RETIRE");
  assert.equal(activeRetire.status, 400);
  assert.match(activeRetire.body.error, /active Task/);

  // stop → wait for IDLE → retire.
  assert.equal((await agentStop(origin, "EXT-RETIRE", { expectedTaskId: "RETIRE-1" })).status, 200);
  await waitForAgentState(origin, "EXT-RETIRE", ["IDLE"]);
  const retired = await agentRetire(origin, "EXT-RETIRE", { reason: "retired by coordinator" });
  assert.equal(retired.status, 200);
  assert.equal(retired.body.terminated, true);
  assert.equal(retired.body.terminationReason, "retired by coordinator");
  const retiredAt = retired.body.terminatedAt;
  assert.equal(typeof retiredAt, "string");

  // a retired member is fenced from every reuse entry and nothing launches a bridge.
  assert.equal((await patchTask(origin, "RETIRE-2", { action: "assign", agentId: "EXT-RETIRE", attemptId: "RETIRE-2-A1" })).status, 400);
  assert.equal((await registerAgent(origin, { agentId: "EXT-RETIRE", formalRole: "tester", teamId: "TEAM-RETIRE", backend: "codex" })).status, 400);
  assert.equal((await dispatchJson(origin, { agentId: "EXT-RETIRE", formalRole: "tester", lifecycleAction: "follow_up", teamId: "TEAM-RETIRE", taskId: "RETIRE-2", attemptId: "RETIRE-2-A1" })).status, 400);
  assert.equal((await dispatchJson(origin, { agentId: "EXT-RETIRE", formalRole: "tester", lifecycleAction: "spawn", teamId: "TEAM-RETIRE", taskId: "RETIRE-2", attemptId: "RETIRE-2-A1" })).status, 400);
  assert.equal(fake.calls.length, 0, "retired reuse must never launch a bridge");

  // Task/Attempt history and the terminated evidence are preserved, not deleted.
  const history = (await runs(origin)).agents.find((agent) => agent.agentId === "EXT-RETIRE");
  assert.equal(history.terminated, true);
  assert.equal(history.terminationReason, "retired by coordinator");
  assert.equal(history.terminatedAt, retiredAt);
  assert.equal(history.teamId, "TEAM-RETIRE");
  assert.equal(history.backend, "codex");
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "RETIRE-1").attempts.length, 1);

  // restart keeps the retired evidence and the fenced reuse decision.
  await first.monitor.close();
  const second = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(second.monitor);
  const restored = (await runs(second.origin)).agents.find((agent) => agent.agentId === "EXT-RETIRE");
  assert.equal(restored.terminated, true);
  assert.equal(restored.terminationReason, "retired by coordinator");
  assert.equal(restored.terminatedAt, retiredAt);
  assert.equal(restored.teamId, "TEAM-RETIRE");
  const restoredTask = (await tasks(second.origin)).tasks.find((task) => task.taskId === "RETIRE-1");
  assert.equal(restoredTask.status, "CANCELLED");
  assert.equal(restoredTask.attempts[0].status, "CANCELLED");
  assert.equal((await patchTask(second.origin, "RETIRE-2", { action: "assign", agentId: "EXT-RETIRE", attemptId: "RETIRE-2-A1" })).status, 400);
  await second.monitor.close();
});

test("CTA-6b: stop and retire broadcast agent/task SSE evidence", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-SSE-CTRL", title: "SSE ctrl" });
  await createTask(origin, { taskId: "SSE-CTRL-1", teamId: "TEAM-SSE-CTRL" });
  await createTask(origin, { taskId: "SSE-CTRL-2", teamId: "TEAM-SSE-CTRL", dependencies: ["SSE-CTRL-1"] });
  await registerAgent(origin, { agentId: "EXT-SSE-CTRL", formalRole: "tester", teamId: "TEAM-SSE-CTRL", backend: "codex" });
  await patchTask(origin, "SSE-CTRL-1", { action: "assign", agentId: "EXT-SSE-CTRL", attemptId: "SSE-CTRL-1-A1" });
  await patchTask(origin, "SSE-CTRL-1", { action: "start", attemptId: "SSE-CTRL-1-A1" });

  // Raw client so the test can destroy the SSE socket and never block monitor.close().
  let buffer = "";
  const sse = httpRequest(`${origin}/api/events`, { headers: { "X-DSH-Monitor-Token": TOKEN } });
  const sseResponse = await new Promise((resolvePromise, rejectPromise) => {
    sse.on("response", resolvePromise);
    sse.on("error", rejectPromise);
    sse.end();
  });
  assert.equal(sseResponse.statusCode, 200);
  sseResponse.setEncoding("utf8");
  sseResponse.on("data", (chunk) => { buffer += chunk; });
  const readUntil = async (needle) => {
    const deadline = Date.now() + 5000;
    while (!buffer.includes(needle)) {
      if (Date.now() > deadline) throw new Error(`SSE timeout waiting for ${needle}: ${buffer}`);
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
    }
  };
  await readUntil("event: snapshot");
  buffer = "";

  await agentStop(origin, "EXT-SSE-CTRL", { expectedTaskId: "SSE-CTRL-1" });
  await readUntil('"status":"CANCELLED"');
  await readUntil('"state":"IDLE"');
  assert.equal((await agentRetire(origin, "EXT-SSE-CTRL", { reason: "sse retire" })).status, 200);
  await readUntil('"terminated":true');
  sse.destroy();

  const events = buffer.split("\n\n").filter((chunk) => chunk.startsWith("event: ")).map((chunk) => {
    const lines = chunk.split("\n");
    return { name: lines[0].slice("event: ".length), data: JSON.parse(lines[1].slice("data: ".length)) };
  });
  const agentEvents = events.filter((event) => event.name === "agent" && event.data.agentId === "EXT-SSE-CTRL");
  assert.ok(agentEvents.some((event) => event.data.state === "IDLE" && event.data.currentTaskId === null), "the stopped Agent is streamed back to IDLE");
  assert.ok(agentEvents.some((event) => event.data.terminated === true), "the retired Agent is streamed with its terminated evidence");
  const taskEvents = events.filter((event) => event.name === "task");
  assert.ok(taskEvents.some((event) => event.data.taskId === "SSE-CTRL-1" && event.data.status === "CANCELLED"), "the stopped Task is streamed as CANCELLED");
  // a CANCELLED dependency never promotes its dependent: SSE-CTRL-2 stays BLOCKED.
  assert.equal((await tasks(origin)).tasks.find((task) => task.taskId === "SSE-CTRL-2").status, "BLOCKED");
});

test("CTA-7: a pre-registered backend=dsh Agent spawns once; wrong role/team and duplicate spawn are rejected", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-PRE", title: "Pre-register" });
  await createTask(origin, { taskId: "PRE-1", teamId: "TEAM-PRE" });
  await createTask(origin, { taskId: "PRE-2", teamId: "TEAM-PRE" });

  // pre-register a dsh backend member: Coordinator-only recruit, IDLE, unbound, not retired.
  const pre = await registerAgent(origin, { agentId: "DSH-PRE", formalRole: "coder", teamId: "TEAM-PRE", backend: "dsh" });
  assert.equal(pre.status, 201);
  assert.equal(pre.body.backend, "dsh");
  assert.equal(pre.body.state, "IDLE");
  assert.equal(pre.body.sessionId, null);
  assert.equal(pre.body.terminated, false);
  assert.deepEqual(pre.body.turns, []);

  // The first-spawn allowance only covers the registered role+team, so every other spawn shape is
  // rejected. The rejection must be atomic: no bridge, no session and no turn reservation.
  const assertInertPreSpawn = async (result) => {
    assert.equal(result.status, 400);
    assert.equal(fake.calls.length, 0, "a refused first spawn must never launch a bridge");
    const agent = (await runs(origin)).agents.find((item) => item.agentId === "DSH-PRE");
    assert.equal(agent.sessionId, null);
    assert.equal(agent.turnCount, 0);
  };

  // a Team-bound member cannot degrade to a team-less legacy dispatch.
  await assertInertPreSpawn(await dispatchJson(origin, { agentId: "DSH-PRE", formalRole: "coder", lifecycleAction: "spawn", taskId: "PRE-1" }));

  // wrong role: the registered formalRole is coder, so spawning as tester is refused.
  await assertInertPreSpawn(await dispatchJson(origin, {
    agentId: "DSH-PRE",
    formalRole: "tester",
    lifecycleAction: "spawn",
    teamId: "TEAM-PRE",
    taskId: "PRE-1",
    attemptId: "PRE-1-WRONG",
  }));

  // wrong team: the binding stays with TEAM-PRE and a forged Team field is refused.
  await createTeam(origin, { teamId: "TEAM-PRE-OTHER", title: "Other", archiveExisting: false });
  await createTask(origin, { taskId: "PRE-OTHER-1", teamId: "TEAM-PRE-OTHER" });
  await assertInertPreSpawn(await dispatchJson(origin, {
    agentId: "DSH-PRE",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-PRE-OTHER",
    taskId: "PRE-OTHER-1",
    attemptId: "PRE-OTHER-A1",
  }));

  // the first spawn with the same team/role is not a duplicate and succeeds.
  const spawned = await dispatchJson(origin, {
    agentId: "DSH-PRE",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-PRE",
    taskId: "PRE-1",
    attemptId: "PRE-1-A1",
  });
  assert.equal(spawned.status, 202);
  assert.equal(fake.calls[0].resume, null);
  await fake.calls[0].finish({ sessionId: "pre-session-1" });
  await waitForTask(origin, "PRE-1", ["COMPLETED"]);
  const idle = await waitForAgentState(origin, "DSH-PRE", ["IDLE"]);
  assert.equal(idle.sessionId, "pre-session-1");
  assert.equal(idle.backend, "dsh");
  assert.equal(idle.terminated, false);

  // once the Agent has a run/session, a second spawn is a duplicate and stays refused.
  const duplicate = await dispatchJson(origin, {
    agentId: "DSH-PRE",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-PRE",
    taskId: "PRE-2",
    attemptId: "PRE-2-A1",
  });
  assert.equal(duplicate.status, 400);
  assert.match(duplicate.body.error, /重复 spawn|已存在/);
  assert.equal(fake.calls.length, 1, "the rejected duplicate must not launch a bridge");

  // follow_up still resumes the pre-registered Agent after its first spawn.
  const followUp = await dispatchJson(origin, {
    agentId: "DSH-PRE",
    formalRole: "coder",
    lifecycleAction: "follow_up",
    teamId: "TEAM-PRE",
    taskId: "PRE-2",
    attemptId: "PRE-2-A1",
  });
  assert.equal(followUp.status, 202);
  assert.equal(followUp.body.sessionId, "pre-session-1");
  await fake.calls[1].finish({ sessionId: "pre-session-1" });
  await waitForTask(origin, "PRE-2", ["COMPLETED"]);
  await monitor.close();
});

test("CTA-8: the Team member cap defaults to 8, counts non-retired members on register and dispatch, and retire frees slots", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-CAP", title: "Cap" });
  assert.equal((await teams(origin)).teams[0].maxMembers, 8);

  for (let index = 1; index <= 8; index += 1) {
    const registered = await registerAgent(origin, { agentId: `EXT-CAP-${index}`, formalRole: "tester", teamId: "TEAM-CAP", backend: "codex" });
    assert.equal(registered.status, 201, `member ${index} must fit under the default cap`);
  }
  assert.equal((await registerAgent(origin, { agentId: "EXT-CAP-9", formalRole: "tester", teamId: "TEAM-CAP", backend: "codex" })).status, 400);

  // the dispatch entry point is capped atomically too: a 9th member is refused before any Run.
  await createTask(origin, { taskId: "CAP-1", teamId: "TEAM-CAP" });
  const dispatchCapped = await dispatchJson(origin, {
    agentId: "DSH-CAP-9",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-CAP",
    taskId: "CAP-1",
    attemptId: "CAP-1-A1",
  });
  assert.equal(dispatchCapped.status, 400);
  assert.equal(fake.calls.length, 0, "a full pool must never launch a bridge");

  // retiring a member frees a slot for the dispatch entry point.
  assert.equal((await agentRetire(origin, "EXT-CAP-1", { reason: "frees a slot" })).status, 200);
  const dispatched = await dispatchJson(origin, {
    agentId: "DSH-CAP-9",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-CAP",
    taskId: "CAP-1",
    attemptId: "CAP-1-A1",
  });
  assert.equal(dispatched.status, 202);
  await fake.calls[0].finish({ sessionId: "cap-session-1" });
  await waitForTask(origin, "CAP-1", ["COMPLETED"]);

  // the pool is full again (8 non-retired members), so the register entry is capped too.
  assert.equal((await registerAgent(origin, { agentId: "EXT-CAP-9", formalRole: "tester", teamId: "TEAM-CAP", backend: "codex" })).status, 400);
  // a second retirement frees the slot for the register entry again.
  assert.equal((await agentRetire(origin, "EXT-CAP-2", { reason: "frees another slot" })).status, 200);
  assert.equal((await registerAgent(origin, { agentId: "EXT-CAP-9", formalRole: "tester", teamId: "TEAM-CAP", backend: "codex" })).status, 201);
  await monitor.close();
});

test("CTA-9: maxMembers is validated and configurable per Team, and concurrent entries stay under the cap", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });

  // non-integer maxMembers is rejected at create and leaves no Team behind.
  assert.equal((await createTeam(origin, { teamId: "TEAM-BAD", maxMembers: "eight" })).status, 400);
  assert.equal((await teams(origin)).teams.length, 0);

  await createTeam(origin, { teamId: "TEAM-CAP-2", title: "Cap 2", archiveExisting: false, maxMembers: 2 });
  assert.equal((await teams(origin)).teams[0].maxMembers, 2);
  await createTask(origin, { taskId: "CAP2-1", teamId: "TEAM-CAP-2" });
  await createTask(origin, { taskId: "CAP2-2", teamId: "TEAM-CAP-2" });

  // concurrent register: exactly two members fit under the custom cap.
  const registered = await Promise.all([
    registerAgent(origin, { agentId: "EXT-2A", formalRole: "tester", teamId: "TEAM-CAP-2", backend: "codex" }),
    registerAgent(origin, { agentId: "EXT-2B", formalRole: "tester", teamId: "TEAM-CAP-2", backend: "codex" }),
    registerAgent(origin, { agentId: "EXT-2C", formalRole: "tester", teamId: "TEAM-CAP-2", backend: "codex" }),
  ]);
  assert.deepEqual(registered.map((result) => result.status).sort(), [201, 201, 400]);
  assert.equal((await runs(origin)).agents.filter((agent) => agent.teamId === "TEAM-CAP-2").length, 2);

  // concurrent dispatch of brand-new members is capped through the same control-plane lock.
  const concurrent = await Promise.all([
    dispatchJson(origin, { agentId: "DSH-2A", formalRole: "coder", lifecycleAction: "spawn", teamId: "TEAM-CAP-2", taskId: "CAP2-1", attemptId: "CAP2-1-A1" }),
    dispatchJson(origin, { agentId: "DSH-2B", formalRole: "coder", lifecycleAction: "spawn", teamId: "TEAM-CAP-2", taskId: "CAP2-2", attemptId: "CAP2-2-A1" }),
  ]);
  assert.deepEqual(concurrent.map((result) => result.status).sort(), [400, 400]);
  assert.equal(fake.calls.length, 0, "a full pool must never launch a bridge");
  await monitor.close();
});

test("CTA-10: the existing run cancel endpoint and read-only GET projections stay unchanged", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-REG", title: "Regression" });
  await createTask(origin, { taskId: "REG-1", teamId: "TEAM-REG" });

  // /api/runs/:id/cancel still works end to end on the legacy turn path.
  const spawned = await dispatchJson(origin, { agentId: "AGENT-REG", formalRole: "coder", lifecycleAction: "spawn", taskId: "REG-1" });
  assert.equal(spawned.status, 202);
  const cancelled = await post(origin, `/api/runs/${encodeURIComponent(spawned.body.id)}/cancel`, {});
  assert.equal(cancelled.status, 200);
  assert.equal((await cancelled.json()).status, "cancelling");
  await fake.calls[0].finish({ sessionId: "reg-session-1", exitCode: 1 });
  assert.equal((await waitForStatus(monitor, spawned.body.id, ["cancelled"])).status, "cancelled");

  // read-only GET projections still expose the complete shape.
  const projection = await runs(origin);
  assert.equal(Array.isArray(projection.runs), true);
  assert.equal(Array.isArray(projection.agents), true);
  assert.equal(Array.isArray(projection.teams), true);
  assert.equal(Array.isArray(projection.tasks), true);
  assert.equal(projection.runs[0].id, spawned.body.id);
  const agent = projection.agents.find((item) => item.agentId === "AGENT-REG");
  assert.equal(agent.turnCount, 1);
  assert.equal(agent.sessionId, "reg-session-1");
  assert.equal((await teams(origin)).teams[0].teamId, "TEAM-REG");

  // the read-only GETs stay authenticated.
  assert.equal((await fetch(`${origin}/api/runs`)).status, 401);
  assert.equal((await fetch(`${origin}/api/teams`)).status, 401);
  assert.equal((await fetch(`${origin}/api/tasks`)).status, 401);
  await monitor.close();
});

test("CTA-11: a restored Agent without its own teamId stays Team-bound through its durable Attempt for projection, cap and retire", async (context) => {
  const workspace = await mkdtemp(join(tmpdir(), "dsh-team-binding-restore-"));
  const monitors = [];
  context.after(async () => {
    for (const monitor of monitors) await monitor.close().catch(() => {});
    await rm(workspace, { recursive: true, force: true });
  });
  const timestamp = "2026-03-01T00:00:00.000Z";
  const bindRunId = "20260301T000000000Z-bind01";
  const registryDir = join(workspace, "artifacts", "dsh-monitor");
  const runDir = join(workspace, "artifacts", "dsh-gui-runs", bindRunId);
  await mkdir(registryDir, { recursive: true });
  await mkdir(runDir, { recursive: true });

  // The durable Run + Attempt bind the Agent to TEAM-BIND; the Agent registry record deliberately
  // carries no `teamId` of its own, which is the historic Team-dispatch shape this regression
  // protects. The second record is a pure legacy run agent with no Team/Attempt affiliation.
  await writeFile(join(runDir, "monitor-run.json"), `${JSON.stringify({
    id: bindRunId,
    runId: bindRunId,
    agentId: "AGENT-BOUND-NO-TEAM",
    formalRole: "coder",
    role: "coder",
    lifecycleAction: "spawn",
    turnIndex: 1,
    legacy: false,
    title: "bound",
    teamId: "TEAM-BIND",
    taskId: "BIND-TASK",
    attemptId: "BIND-A1",
    status: "completed",
    phase: "complete",
    workspace,
    sessionId: "bound-no-team-session",
    startUtc: timestamp,
    endUtc: timestamp,
    exitCode: 0,
    events: [],
  }, null, 2)}\n`, "utf8");
  await writeFile(join(registryDir, "agent-registry.json"), `${JSON.stringify({
    schemaVersion: 1,
    controlPlaneSchemaVersion: 1,
    agents: {
      "AGENT-BOUND-NO-TEAM": {
        agentId: "AGENT-BOUND-NO-TEAM",
        formalRole: "coder",
        legacy: false,
        legacyRole: null,
        sessionId: "bound-no-team-session",
        createdAt: timestamp,
        updatedAt: timestamp,
        runIds: [bindRunId],
      },
      "legacy:session:legacy-boundless": {
        agentId: "legacy:session:legacy-boundless",
        formalRole: null,
        legacy: true,
        legacyRole: "worker",
        sessionId: "legacy-boundless-session",
        createdAt: timestamp,
        updatedAt: timestamp,
        runIds: [],
      },
    },
    turns: { [bindRunId]: 1 },
    nextTurnIndex: { "AGENT-BOUND-NO-TEAM": 2 },
    teams: {
      "TEAM-BIND": {
        teamId: "TEAM-BIND",
        title: "Bound",
        status: "ACTIVE",
        maxMembers: 2,
        createdAt: timestamp,
        updatedAt: timestamp,
      },
    },
    tasks: {
      "BIND-TASK": {
        taskId: "BIND-TASK",
        teamId: "TEAM-BIND",
        title: "bound task",
        status: "COMPLETED",
        ownerAgentId: "AGENT-BOUND-NO-TEAM",
        dependencies: [],
        attemptId: "BIND-A1",
        attempts: [{
          attemptId: "BIND-A1",
          taskId: "BIND-TASK",
          teamId: "TEAM-BIND",
          agentId: "AGENT-BOUND-NO-TEAM",
          backend: "dsh",
          runId: bindRunId,
          status: "COMPLETED",
          startedAt: timestamp,
          endedAt: timestamp,
        }],
        executionType: "normal",
        result: null,
        failure: null,
        recovery: null,
        createdAt: timestamp,
        updatedAt: timestamp,
      },
    },
  }, null, 2)}\n`, "utf8");

  const first = await startMonitor(context, { workspace, spawnBridge: createFakeBridge().spawnBridge });
  monitors.push(first.monitor);
  const { origin } = first;

  // 1) the public projection recovers the Team from the durable Attempt even without agent.teamId.
  const bound = (await runs(origin)).agents.find((agent) => agent.agentId === "AGENT-BOUND-NO-TEAM");
  assert.equal(bound.teamId, "TEAM-BIND");
  assert.equal(bound.state, "IDLE");
  assert.equal(bound.terminated, false);
  assert.equal(bound.sessionId, "bound-no-team-session");
  assert.equal(bound.turnCount, 1);
  assert.equal((await teams(origin)).teams.find((team) => team.teamId === "TEAM-BIND").maxMembers, 2);

  // ...and the member cap counts that Attempt-bound Agent as one of the two seats.
  assert.equal((await registerAgent(origin, { agentId: "EXT-BIND-1", formalRole: "tester", teamId: "TEAM-BIND", backend: "codex" })).status, 201);
  assert.equal((await registerAgent(origin, { agentId: "EXT-BIND-2", formalRole: "tester", teamId: "TEAM-BIND", backend: "codex" })).status, 400);

  // 2) idle retire succeeds and keeps session/run/turn/attempt history.
  const retired = await agentRetire(origin, "AGENT-BOUND-NO-TEAM", { reason: "attempt-bound retire" });
  assert.equal(retired.status, 200);
  assert.equal(retired.body.terminated, true);
  assert.equal(retired.body.terminationReason, "attempt-bound retire");
  assert.equal(typeof retired.body.terminatedAt, "string");
  const afterRetire = (await runs(origin)).agents.find((agent) => agent.agentId === "AGENT-BOUND-NO-TEAM");
  assert.equal(afterRetire.terminated, true);
  assert.equal(afterRetire.sessionId, "bound-no-team-session", "retire must keep the session binding");
  assert.equal(afterRetire.turnCount, 1, "retire must keep the turn history");
  assert.equal(afterRetire.runIds.length, 1, "retire must keep the run history");
  const bindTask = (await tasks(origin)).tasks.find((task) => task.taskId === "BIND-TASK");
  assert.equal(bindTask.status, "COMPLETED");
  assert.equal(bindTask.attempts.length, 1, "retire must keep the attempt history");
  assert.equal(bindTask.attempts[0].status, "COMPLETED");
  assert.equal(bindTask.attempts[0].agentId, "AGENT-BOUND-NO-TEAM");

  // the retired member no longer occupies a seat: the freed slot can be filled.
  assert.equal((await registerAgent(origin, { agentId: "EXT-BIND-2", formalRole: "tester", teamId: "TEAM-BIND", backend: "codex" })).status, 201);

  // 3) an agent with neither a Team nor an Attempt binding is still refused.
  const boundless = await agentRetire(origin, "legacy:session:legacy-boundless");
  assert.equal(boundless.status, 400);
  assert.match(boundless.body.error, /Team 归属|legacy|Team-managed/);
  await first.monitor.close();
});

test("CTA-12: publicAgent.teamId stays consistent with the durable Attempt binding when the Task owner is reassigned away; owner labels never fabricate membership", async (context) => {
  const fake = createFakeBridge();
  const { monitor, origin } = await startMonitor(context, { spawnBridge: fake.spawnBridge });
  await createTeam(origin, { teamId: "TEAM-PROJ", title: "Projection", maxMembers: 2, archiveExisting: false });
  await createTask(origin, { taskId: "PROJ-1", teamId: "TEAM-PROJ" });

  // A DSH member created by a Team dispatch has no registry `teamId`: its only membership
  // evidence is the durable Attempt on PROJ-1.
  const spawned = await dispatchJson(origin, {
    agentId: "AGENT-PROJ",
    formalRole: "coder",
    lifecycleAction: "spawn",
    teamId: "TEAM-PROJ",
    taskId: "PROJ-1",
    attemptId: "PROJ-1-A1",
  });
  assert.equal(spawned.status, 202);
  await fake.calls[0].finish({ sessionId: "proj-session-1", exitCode: 1 });
  await waitForTask(origin, "PROJ-1", ["FAILED"]);

  // Re-assign PROJ-1 away from AGENT-PROJ: afterwards no Task owns AGENT-PROJ, so only the
  // durable Attempt can still prove its Team membership.
  const reassigned = await patchTask(origin, "PROJ-1", { action: "reassign", ownerAgentId: "AGENT-PROJ-HEIR" });
  assert.equal(reassigned.status, 200);
  assert.equal(reassigned.body.ownerAgentId, "AGENT-PROJ-HEIR");

  // 1) the projection still reports the Team (shared effective binding), never "unaffiliated".
  const projected = (await runs(origin)).agents.find((agent) => agent.agentId === "AGENT-PROJ");
  assert.equal(projected.teamId, "TEAM-PROJ");
  assert.equal(projected.state, "IDLE");
  assert.equal(projected.terminated, false);

  // 2) cap and retire use that same Attempt-derived binding: the member occupies one of the two
  //    seats and is retirable, so the GUI projection and the enforcement never diverge.
  assert.equal((await registerAgent(origin, { agentId: "EXT-PROJ-1", formalRole: "tester", teamId: "TEAM-PROJ", backend: "codex" })).status, 201);
  assert.equal((await registerAgent(origin, { agentId: "EXT-PROJ-2", formalRole: "tester", teamId: "TEAM-PROJ", backend: "codex" })).status, 400);
  const retired = await agentRetire(origin, "AGENT-PROJ", { reason: "projection consistency" });
  assert.equal(retired.status, 200);
  assert.equal(retired.body.terminated, true);

  // 3) a Team-less DSH agent (legacy dispatch) whose Task ownerAgentId merely labels it must never
  //    be projected as a retirable Team member: an owner label alone is not a binding.
  const labelSource = await dispatchJson(origin, { agentId: "AGENT-NO-TEAM", formalRole: "coder", lifecycleAction: "spawn" });
  assert.equal(labelSource.status, 202);
  await fake.calls[1].finish({ sessionId: "no-team-session-1" });
  await waitForStatus(monitor, labelSource.body.id, ["completed"]);
  await createTask(origin, { taskId: "PROJ-LABEL", teamId: "TEAM-PROJ", ownerAgentId: "AGENT-NO-TEAM" });
  const labeled = (await runs(origin)).agents.find((agent) => agent.agentId === "AGENT-NO-TEAM");
  assert.equal(labeled.teamId ?? null, null, "an owner label must not fabricate Team membership");
  assert.equal((await agentRetire(origin, "AGENT-NO-TEAM")).status, 400);
  assert.equal(fake.calls.length, 2, "the refused retire never launches a bridge");
  await monitor.close();
});

test("CTA-13: PATCH /api/agents/:id gates auth before parsing the body; cookie stop/retire and header terminate stay intact", async (context) => {
  const { origin } = await startMonitor(context, { spawnBridge: createFakeBridge().spawnBridge });
  await createTeam(origin, { teamId: "TEAM-AUTH", title: "Auth gate" });
  await registerAgent(origin, { agentId: "EXT-AUTH", formalRole: "tester", teamId: "TEAM-AUTH", backend: "codex" });
  const cookie = await browserCookie(origin);
  const MALFORMED = "{ this is not json";

  const rawAgentPatch = (headers, body = MALFORMED) => fetch(`${origin}/api/agents/EXT-AUTH`, {
    method: "PATCH",
    headers: { "Content-Type": "application/json", ...headers },
    body,
  });

  // tokenless and cross-origin malformed bodies are refused by the broad auth gate BEFORE any JSON
  // parsing, so the answer is 403, never a 400 parse error.
  assert.equal((await rawAgentPatch({})).status, 403, "tokenless malformed body must be 403");
  assert.equal((await rawAgentPatch({ Cookie: cookie, Origin: "http://evil.example" })).status, 403, "cross-origin cookie must be 403");
  // A cookie without an Origin header passes the broad same-origin gate (authorized + no Origin)
  // and is refused by the stop/retire origin-less rule only after parsing, so a malformed body
  // surfaces as a 400 parse error and can never mutate anything.
  assert.equal((await rawAgentPatch({ Cookie: cookie })).status, 400, "cookie-without-Origin malformed body is a 400 parse error");

  // after the gate, a malformed body from an authorized caller is a 400 parse error, not 403.
  assert.equal((await rawAgentPatch({ Cookie: cookie, Origin: origin })).status, 400, "authorized same-origin malformed body is a 400 parse error");
  assert.equal((await rawAgentPatch({ "X-DSH-Monitor-Token": TOKEN })).status, 400, "header token malformed body is a 400 parse error");

  // none of the denied / parse-failed attempts changed the member.
  const untouched = (await runs(origin)).agents.find((agent) => agent.agentId === "EXT-AUTH");
  assert.equal(untouched.terminated, false);
  assert.equal(untouched.state, "IDLE");

  // non-regression: cookie+same-origin stop/retire and header terminate keep working.
  assert.equal((await guiRequest(origin, "PATCH", "/api/agents/EXT-AUTH", { action: "stop" }, { cookie })).status, 200);
  const retire = await guiRequest(origin, "PATCH", "/api/agents/EXT-AUTH", { action: "retire", reason: "auth regression" }, { cookie });
  assert.equal(retire.status, 200);
  assert.equal((await retire.json()).terminated, true);
  assert.equal((await registerAgent(origin, { agentId: "EXT-AUTH-2", formalRole: "tester", teamId: "TEAM-AUTH", backend: "codex" })).status, 201);
  const terminate = await patchAgent(origin, "EXT-AUTH-2", { action: "terminate" });
  assert.equal(terminate.status, 200);
  assert.equal(terminate.body.terminated, true);
});
