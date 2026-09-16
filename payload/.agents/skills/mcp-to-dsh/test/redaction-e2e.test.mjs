// End-to-end confidentiality test through the real monitor, using only fake secrets.
//
// It drives `createMonitorServer` with a deterministic bridge double (the same seam the
// monitor's own suite uses) and asserts that a fake secret placed in the contract, the
// title and the bridge's own ACP events never reaches:
//
//   * the child process environment,
//   * the compiled instruction artefact,
//   * the monitor run manifest,
//   * the HTTP projection,
//   * the SSE stream.
//
// The same test also proves the Team Home ownership guard at the server boundary, because
// it starts the monitor with an installation id and a marked Team Home.

import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createMonitorServer } from "../src/server.mjs";
import { assertNoSecretLeak, findSecretLeaks, CHILD_ENV_ALLOWLIST, redactJson, redactValue } from "../src/security.mjs";
import {
  TOOLKIT_ID,
  buildTeamHomeMarker,
  writeTeamHomeMarker,
} from "../src/team-home.mjs";

const TOKEN = "test-monitor-token";
const INSTALL_ID = "redaction-e2e-install";

// Fake secrets only. Realistic shapes so the shape rules and the key rules are both covered.
const FAKE_BEARER = "fake-bearer-0123456789abcdef";
const FAKE_API_KEY = "sk-fake0123456789abcdefghij";
const FAKE_ENV_VALUE = "fake-env-secret-value-0001";
const FAKE_PASSWORD = "fake-password-value-0003";
const FAKE_SECRETS = [FAKE_BEARER, FAKE_API_KEY, FAKE_ENV_VALUE, FAKE_PASSWORD];

// A parent environment that carries every credential family the policy must strip.
const PARENT_SECRET_ENV = {
  DEMO_API_KEY: FAKE_ENV_VALUE,
  MY_TOKEN: FAKE_BEARER,
  APP_PASSWORD: FAKE_PASSWORD,
  SERVICE_SECRET: FAKE_ENV_VALUE,
  SESSION_COOKIE: FAKE_BEARER,
  AUTHORIZATION: `Bearer ${FAKE_BEARER}`,
  DSH_MONITOR_TOKEN: FAKE_BEARER,
};

// The contract text deliberately *mentions* sensitive words (so documentation survives) while
// also carrying real value positions (so they are removed).
const CONTRACT = [
  "只读探测合同：不要修改任何文件。",
  "说明：本项目禁止读取 .env、API key、token、password 或 Authorization 文本。",
  `调试时不得打印: Authorization: Bearer ${FAKE_BEARER}`,
  `DEMO_API_KEY=${FAKE_ENV_VALUE}`,
  `password = ${FAKE_PASSWORD}`,
  `provider key: ${FAKE_API_KEY}`,
].join("\n");

// `writer` mirrors the real bridge (src/cli.mjs): the product's own redaction helpers filter
// every durable artefact before it reaches disk. `hostile` skips them on purpose, which is
// how the "monitor must not propagate a poisoned artifact" case is exercised.
function createFakeBridge({ writer = "redacted" } = {}) {
  const calls = [];
  const spawnBridge = (args, spawnOptions, context) => {
    const artifactDir = args[args.indexOf("--artifact-dir") + 1];
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
      env: spawnOptions?.env ?? null,
      child,
      // A bridge whose ACP events, stderr and session summary all carry a fake secret, the
      // way a careless real caller would produce them.
      async finish({ exitCode = 0 } = {}) {
        const sessionId = "redaction-session-001";
        await mkdir(artifactDir, { recursive: true });
        const lines = [
          { ts: new Date().toISOString(), source: "dsh", kind: "initialized", response: { protocolVersion: 1, note: `token=${FAKE_ENV_VALUE}` } },
          { ts: new Date().toISOString(), source: "dsh", kind: "session_created", sessionId, response: { configOptions: [] } },
          {
            ts: new Date().toISOString(),
            source: "dsh",
            kind: "session_update",
            sessionId,
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: `agent said ${FAKE_API_KEY}` },
            },
          },
          { ts: new Date().toISOString(), source: "dsh", kind: "turn_stop", sessionId, response: { stopReason: "end_turn" } },
        ];
        const summary = {
          schema_version: 1,
          session_id: sessionId,
          bridge_error: { message: `Authorization: Bearer ${FAKE_BEARER}` },
        };
        if (writer === "redacted") {
          // 与 src/cli.mjs 完全一致：事件走 redactValue，summary 走 redactJson。
          const eventLines = lines.map((line) => JSON.stringify(redactValue(line))).join("\n");
          await writeFile(join(artifactDir, "events.jsonl"), `${eventLines}\n`, "utf8");
          await writeFile(join(artifactDir, "session-summary.json"), `${redactJson(summary, 2)}\n`, "utf8");
        }
        else {
          const eventLines = lines.map((line) => JSON.stringify(line)).join("\n");
          await writeFile(join(artifactDir, "events.jsonl"), `${eventLines}\n`, "utf8");
          await writeFile(join(artifactDir, "session-summary.json"), `${JSON.stringify(summary)}\n`, "utf8");
        }
        child.stdout.emit("data", Buffer.from(`[bridge] echo ${FAKE_ENV_VALUE}\n`, "utf8"));
        child.stderr.emit("data", Buffer.from(`[DSH:runtime] cookie=session=${FAKE_BEARER}\n`, "utf8"));
        child.exitCode = exitCode;
        child.emit("close", exitCode, null);
      },
    };
    calls.push(call);
    return child;
  };
  return { spawnBridge, calls };
}

async function startOwnedMonitor(context, bridgeOptions = {}) {
  const root = await mkdtemp(join(tmpdir(), "dsh-redaction-e2e-"));
  const teamHome = join(root, "team-home");
  const userHome = join(root, "user-home");
  await mkdir(teamHome, { recursive: true });
  await mkdir(userHome, { recursive: true });
  await writeFile(join(userHome, "settings.yaml"), "agent-default-model:\n  provider: fake-provider\n  model: fake-model\n");
  writeTeamHomeMarker(teamHome, buildTeamHomeMarker({ toolkitId: TOOLKIT_ID, installId: INSTALL_ID }));

  const bridge = createFakeBridge(bridgeOptions);
  const monitor = createMonitorServer({
    workspace: root,
    dshHome: teamHome,
    dshUserHome: userHome,
    toolkitInstallId: INSTALL_ID,
    port: 0,
    token: TOKEN,
    spawnBridge: bridge.spawnBridge,
  });
  const address = await monitor.start();
  context.after(async () => {
    await monitor.close();
    await rm(root, { recursive: true, force: true });
  });
  return { root, teamHome, userHome, bridge, monitor, origin: `http://127.0.0.1:${address.port}` };
}

test("fake secret 不进入 child env、instruction、run manifest、HTTP 投影与 SSE", { timeout: 60000 }, async (context) => {
  // 只在该测试进程里注入假凭据；测试结束前不会影响其它测试文件（每个测试文件独立进程）。
  const savedEnv = {};
  for (const [key, value] of Object.entries(PARENT_SECRET_ENV)) {
    savedEnv[key] = process.env[key];
    process.env[key] = value;
  }
  context.after(() => {
    for (const [key, value] of Object.entries(savedEnv)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });

  const { root, bridge, origin, monitor } = await startOwnedMonitor(context);

  // Collect the SSE stream so the Monitor projection is asserted too.
  const sseFrames = [];
  const sseController = new AbortController();
  const sseDone = (async () => {
    try {
      const response = await fetch(`${origin}/api/events`, {
        headers: { "X-DSH-Monitor-Token": TOKEN, Accept: "text/event-stream" },
        signal: sseController.signal,
      });
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        sseFrames.push(decoder.decode(value, { stream: true }));
      }
    } catch {
      // Aborted at the end of the test; the collected frames are what matters.
    }
  })();

  const dispatched = await fetch(`${origin}/api/runs`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN },
    body: JSON.stringify({
      contractText: CONTRACT,
      contractPath: ".dsh/contracts/redaction-e2e.md",
      agentId: "redaction-e2e-agent",
      formalRole: "coder",
      lifecycleAction: "spawn",
      taskId: "REDACTION-E2E",
      // The title is free text from the request and must be filtered as well.
      title: `leaky title ${FAKE_API_KEY}`,
      allowTools: false,
    }),
  });
  assert.equal(dispatched.ok, true, `dispatch 必须成功，实际 ${dispatched.status}`);
  const dispatchedBody = await dispatched.json();
  assertNoSecretLeak(dispatchedBody, FAKE_SECRETS, "dispatch HTTP response");

  // 1. Child environment: only the allowlist + the two confirmed DSH runtime fields.
  assert.equal(bridge.calls.length, 1);
  const call = bridge.calls[0];
  for (const key of Object.keys(PARENT_SECRET_ENV)) {
    assert.equal(Object.hasOwn(call.env, key), false, `${key} 不得进入 child env`);
  }
  assert.equal(Object.keys(call.env).some((key) => /TOKEN|KEY|SECRET|PASSW|COOKIE|AUTHORIZATION/i.test(key)), false);
  // child env 必须精确等于「allowlist ∩ 当前进程环境」+ 两个确认过的 DSH 字段，多一个都不行。
  const expectedChildEnvKeys = [
    ...CHILD_ENV_ALLOWLIST.filter((key) => process.env[key] !== undefined),
    "DSH_HOME",
    "DSH_PERMISSION_MODE",
  ].sort();
  assert.deepEqual(Object.keys(call.env).sort(), expectedChildEnvKeys, "child env 必须等于显式允许集");
  assert.equal(call.env.DSH_HOME, join(root, "team-home"));
  assert.equal(call.env.DSH_PERMISSION_MODE, "danger-full-access");
  assertNoSecretLeak(call.env, FAKE_SECRETS, "child env");

  // 2. Compiled instruction artefact (this is also the dispatched prompt source).
  const instruction = await readFile(join(call.artifactDir, "codex-compiled-instruction.txt"), "utf8");
  assertNoSecretLeak(instruction, FAKE_SECRETS, "codex-compiled-instruction.txt");
  assert.ok(instruction.includes("<REDACTED>"), "被承载的 secret 值必须以 <REDACTED> 取代");
  // 文档性文字必须保持可读，否则派发出去的合同会被破坏。
  assert.ok(instruction.includes("禁止读取 .env、API key、token、password"), "说明文字必须保持可读");
  // SECURITY BOUNDARY 必须真的进入派发指令，并且位于合同之后。
  assert.ok(instruction.includes("===== SECURITY BOUNDARY ====="), "instruction 必须包含 SECURITY BOUNDARY");
  assert.ok(instruction.includes("===== END SECURITY BOUNDARY ====="), "instruction 必须包含 END SECURITY BOUNDARY");
  assert.ok(instruction.indexOf("===== END CONTRACT =====") < instruction.indexOf("===== SECURITY BOUNDARY ====="),
    "SECURITY BOUNDARY 必须排在合同之后");
  assert.ok(instruction.includes("prompt injection"), "SECURITY BOUNDARY 必须点名 prompt injection");
  // workspace 绑定：指令里的 workspace 只能是本 Monitor 的 canonical workspace。
  assert.ok(instruction.includes(`WORKSPACE: ${root}`), "instruction 必须绑定当前 workspace");

  // 3. Bridge lifecycle, then re-read every persisted projection.
  await call.finish();
  await new Promise((resolve) => setTimeout(resolve, 400));

  const manifest = await readFile(join(call.artifactDir, "monitor-run.json"), "utf8");
  assertNoSecretLeak(manifest, FAKE_SECRETS, "monitor-run.json");
  // The raw bridge logs written by the monitor are filtered as well.
  const stdoutLog = await readFile(join(call.artifactDir, "bridge-stdout.log"), "utf8");
  const stderrLog = await readFile(join(call.artifactDir, "bridge-stderr.log"), "utf8");
  assertNoSecretLeak(stdoutLog, FAKE_SECRETS, "bridge-stdout.log");
  assertNoSecretLeak(stderrLog, FAKE_SECRETS, "bridge-stderr.log");
  // 其他 durable sink：control file、session summary、registry、monitor 控制文件。
  const controlFile = await readFile(join(call.artifactDir, "monitor-control.json"), "utf8").catch(() => "");
  assertNoSecretLeak(controlFile, FAKE_SECRETS, "monitor-control.json");
  const summaryFile = await readFile(join(call.artifactDir, "session-summary.json"), "utf8").catch(() => "");
  assertNoSecretLeak(summaryFile, FAKE_SECRETS, "session-summary.json");
  const registryFile = await readFile(join(root, "artifacts", "dsh-monitor", "agent-registry.json"), "utf8");
  assertNoSecretLeak(registryFile, FAKE_SECRETS, "agent-registry.json");
  assert.equal(registryFile.includes("access_token"), false, "registry 不得包含 access token");

  // 4. HTTP projection.
  const projection = await fetch(`${origin}/api/runs`, { headers: { "X-DSH-Monitor-Token": TOKEN } }).then((r) => r.json());
  assertNoSecretLeak(projection, FAKE_SECRETS, "GET /api/runs");

  // 5. SSE projection (the whole stream, not just one frame).
  sseController.abort();
  await sseDone;
  const sseText = sseFrames.join("");
  assert.ok(sseText.includes("event: run"), "SSE 必须真的推送过 run 事件");
  assert.deepEqual(findSecretLeaks(sseText, FAKE_SECRETS), [], `SSE 泄露: ${findSecretLeaks(sseText, FAKE_SECRETS).join(",")}`);

  // The monitor projection must show the redaction as machine evidence, without the value.
  const run = [...monitor.runs.values()][0];
  assert.ok(run.promptRedaction, "prompt redaction 必须作为机器证据记录");
  assert.ok(run.promptRedaction.categories["key-value"] >= 1, JSON.stringify(run.promptRedaction));
  assertNoSecretLeak(run.promptRedaction, FAKE_SECRETS, "promptRedaction evidence");

  // 6. The Team Home guard and the read-only user home are still intact.
  const marker = JSON.parse(await readFile(join(root, "team-home", ".codex-dsh-team-home.json"), "utf8"));
  assert.equal(marker.installId, INSTALL_ID);
  assert.deepEqual(await readdir(join(root, "user-home")), ["settings.yaml"], "用户 DSH Home 文件集必须不变");
  const userFiles = await readFile(join(root, "user-home", "settings.yaml"), "utf8");
  assert.match(userFiles, /fake-provider/);
});

test("contractPath 逃逸 / 绝对 / 非 .md 一律 fail-closed，且不产生 artifact", { timeout: 60000 }, async (context) => {
  const { root, bridge, origin } = await startOwnedMonitor(context);
  const attempts = [
    ["/etc/passwd.md", "绝对 POSIX 路径"],
    ["C:\\outside\\contract.md", "绝对 Windows 路径"],
    ["../../outside.md", "'..' 逃逸"],
    [".dsh/contracts/../outside.md", "内嵌 '..' 逃逸"],
    [".dsh/contracts/not-a-contract.txt", "非 .md"],
    ["", "空路径"],
  ];
  for (const [contractPath, label] of attempts) {
    const response = await fetch(`${origin}/api/runs`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN },
      body: JSON.stringify({
        contractText: "只读合同：不得修改任何文件。",
        contractPath,
        agentId: "contract-bound-agent",
        formalRole: "coder",
        lifecycleAction: "spawn",
        taskId: "CONTRACT-BOUND",
        allowTools: false,
      }),
    });
    assert.equal(response.ok, false, `${label} 必须被拒绝，实际 ${response.status}`);
  }
  // 没有任何 Run 被创建，也没有 bridge 被启动，更没有 run 目录。
  assert.equal(bridge.calls.length, 0, "被拒绝的 dispatch 不得启动 bridge");
  const emptyProjection = await fetch(`${origin}/api/runs`, { headers: { "X-DSH-Monitor-Token": TOKEN } })
    .then((response) => response.json());
  assert.equal(emptyProjection.runs.length, 0, "被拒绝的 dispatch 不得创建 Run");
  // Monitor 启动时会创建 runRoot 容器目录；关键是里面不能出现任何 run 目录。
  assert.deepEqual(await readdir(join(root, "artifacts", "dsh-gui-runs")).catch(() => []), [],
    "被拒绝的 dispatch 不得创建 run 目录");

  // workspace 也必须绑定：另一个工作区不能借用本 Monitor。
  const otherWorkspace = await mkdtemp(join(tmpdir(), "dsh-redaction-other-"));
  context.after(() => rm(otherWorkspace, { recursive: true, force: true }));
  const foreign = await fetch(`${origin}/api/runs`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN },
    body: JSON.stringify({
      workspace: otherWorkspace,
      contractText: "只读合同。",
      contractPath: ".dsh/contracts/ok.md",
      agentId: "contract-bound-agent",
      formalRole: "coder",
      lifecycleAction: "spawn",
      taskId: "CONTRACT-BOUND",
      allowTools: false,
    }),
  });
  assert.equal(foreign.ok, false, "workspace 必须与 Monitor 的 canonical workspace 一致");
  assert.equal(await stat(join(otherWorkspace, "artifacts")).then(() => true, () => false), false,
    "外来 workspace 不得出现 artifact");
});

test("Monitor 不传播被投毒的 bridge 事件与 session summary", { timeout: 60000 }, async (context) => {
  // 这个 double 故意绕过产品自己的 writer：它写出未脱敏的 events.jsonl / session-summary.json。
  // Monitor 的职责是"读取边界"防御——即使 durable 文件被别的写入者污染，也不得把 secret
  // 传播到 monitor-run.json、HTTP 投影或 SSE。文件级脱敏由 bridge (src/cli.mjs) 负责，
  // 已由前一个用例与 static guard 覆盖。
  const { bridge, origin, monitor } = await startOwnedMonitor(context, { writer: "hostile" });
  const dispatched = await fetch(`${origin}/api/runs`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN },
    body: JSON.stringify({
      contractText: "只读合同：不得修改任何文件。",
      contractPath: ".dsh/contracts/hostile.md",
      agentId: "hostile-writer-agent",
      formalRole: "coder",
      lifecycleAction: "spawn",
      taskId: "HOSTILE-WRITER",
      allowTools: false,
    }),
  });
  assert.equal(dispatched.ok, true, `dispatch 必须成功，实际 ${dispatched.status}`);
  const call = bridge.calls[0];
  await new Promise((resolve) => setTimeout(resolve, 300));
  await call.finish();
  await new Promise((resolve) => setTimeout(resolve, 400));

  // 投毒文件确实存在于磁盘（证明这不是一个"干净输入"的假阳性）。
  const hostileEvents = await readFile(join(call.artifactDir, "events.jsonl"), "utf8");
  assert.equal(findSecretLeaks(hostileEvents, FAKE_SECRETS).length > 0, true,
    "该用例要求 events.jsonl 确实被投毒");
  // 但 monitor 自己的投影必须干净。
  const manifest = await readFile(join(call.artifactDir, "monitor-run.json"), "utf8");
  assertNoSecretLeak(manifest, FAKE_SECRETS, "monitor-run.json（读取边界）");
  const projection = await fetch(`${origin}/api/runs`, { headers: { "X-DSH-Monitor-Token": TOKEN } })
    .then((response) => response.json());
  assertNoSecretLeak(projection, FAKE_SECRETS, "GET /api/runs（读取边界）");
  const run = [...monitor.runs.values()][0];
  assert.equal(run.events.some((event) => JSON.stringify(event).includes(FAKE_API_KEY)), false,
    "内存中的事件投影必须已脱敏");
});

test("合法的相对 .md 合同路径仍然可用", { timeout: 60000 }, async (context) => {
  const { bridge, origin } = await startOwnedMonitor(context);
  const response = await fetch(`${origin}/api/runs`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-DSH-Monitor-Token": TOKEN },
    body: JSON.stringify({
      contractText: "只读合同：不得修改任何文件。",
      contractPath: ".dsh/contracts/ok.md",
      agentId: "contract-ok-agent",
      formalRole: "coder",
      lifecycleAction: "spawn",
      taskId: "CONTRACT-OK",
      allowTools: false,
    }),
  });
  assert.equal(response.ok, true, `合法合同路径必须被接受，实际 ${response.status}`);
  assert.equal(bridge.calls.length, 1);
  const instruction = await readFile(join(bridge.calls[0].artifactDir, "codex-compiled-instruction.txt"), "utf8");
  assert.ok(instruction.includes("CONTRACT_SOURCE: .dsh/contracts/ok.md"));
  await bridge.calls[0].finish();
});

test("Monitor 拒绝在没有合法 marker 的 Team Home 上启动", async () => {
  const root = await mkdtemp(join(tmpdir(), "dsh-redaction-unowned-"));
  try {
    const teamHome = join(root, "unowned");
    await mkdir(teamHome, { recursive: true });
    await writeFile(join(teamHome, "keep.txt"), "untouched\n");
    assert.throws(
      () => createMonitorServer({
        workspace: root,
        dshHome: teamHome,
        port: 0,
        token: TOKEN,
        toolkitInstallId: INSTALL_ID,
        spawnBridge: () => { throw new Error("must not spawn"); },
      }),
      /未证明 Toolkit ownership/,
    );
    assert.equal(await readFile(join(teamHome, "keep.txt"), "utf8"), "untouched\n");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("用户 DSH Home 不会收到任何 Monitor 写入", async (context) => {
  const { root, userHome } = await startOwnedMonitor(context);
  const entries = await readFile(join(userHome, "settings.yaml"), "utf8");
  assert.match(entries, /fake-provider/);
  // Monitor 只把状态写进 workspace 的 artifacts 目录。
  const artifacts = await readFile(join(root, "artifacts", "dsh-monitor", "agent-registry.json"), "utf8");
  assert.equal(artifacts.includes("access_token"), false);
  assert.equal(artifacts.includes("fake-provider"), false);
});
