import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { spawn } from "node:child_process";
import { Readable, Writable, PassThrough } from "node:stream";
import { createInterface } from "node:readline/promises";
import { fileURLToPath } from "node:url";
import { dirname, isAbsolute, resolve } from "node:path";
import {
  PROTOCOL_VERSION,
  client,
  methods,
  ndJsonStream,
} from "@agentclientprotocol/sdk";
import { applyAcpModelSelection } from "./model-settings.mjs";
import {
  SECURITY_POLICY_VERSION,
  buildChildEnv,
  createRedactingLineWriter,
  pickDshRuntimeEnv,
  redactForDispatch,
  redactJson,
  redactText,
  redactValue,
  registerDeniedEnvValues,
} from "./security.mjs";

const BRIDGE_VERSION = "0.1.0";

// The DSH ACP profile name. `acp` is a DSH protocol built-in (the ACP stdio server profile
// shipped by the DSH distribution), not a user/provider choice — the same category as the
// built-in `deepseek-official` provider id. It is named once here and can be overridden for
// forward compatibility instead of being repeated as a literal across the code base.
//
// The value is only *read* here and validated where it is used (`resolveDshProfile()` inside
// `main()`), so an invalid name fails through the bridge's normal redacted fatal path with a
// non-zero exit instead of throwing during module evaluation.
const DSH_ACP_PROFILE_ENV = "CODEX_DSH_ACP_PROFILE";

/**
 * Validate a DSH ACP profile name (mirrors `normalizeDshProfile` in src/server.mjs).
 *
 * The monitor spawns this bridge with `CODEX_DSH_ACP_PROFILE` set to a validated profile, so
 * this is a defense-in-depth check for direct/standalone use. An absent/empty value means the
 * documented default `acp`.
 */
function resolveDshProfile(value = process.env[DSH_ACP_PROFILE_ENV]) {
  const raw = typeof value === "string" ? value.trim() : value == null ? "" : String(value).trim();
  if (raw === "") return "acp";
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(raw)) {
    throw new Error(`${DSH_ACP_PROFILE_ENV} 非法：${raw}（只允许字母数字开头，后跟字母数字、点、下划线或连字符，最长 64 个字符）。`);
  }
  if (raw.toLowerCase() === "node_modules") {
    throw new Error(`${DSH_ACP_PROFILE_ENV} 非法：${raw} 是保留的目录名，不能作为 DSH ACP profile。`);
  }
  return raw;
}

/**
 * The only console writer in this file. Everything printed to stdout/stderr passes the
 * central redaction policy first, so a fatal stack, a git diff or a tool payload can never
 * reach a terminal (or the monitor's captured bridge logs) unfiltered.
 */
function writeRedacted(text, stream = process.stdout) {
  stream.write(redactText(text));
}

// 桥接进程看到的凭据家族值全部登记为 known secret：即使某条日志把它当成自由文本打印，
// 落盘前也会被按值 redaction 掉，而不是依赖它恰好长得像某种 key。
registerDeniedEnvValues(process.env);

function parseArgs(argv) {
  const result = {
    cwd: process.cwd(),
    prompts: [],
    promptFiles: [],
    controlFile: undefined,
    resume: undefined,
    allowTools: false,
    artifactDir: undefined,
    closeSession: false,
    modelProvider: undefined,
    model: undefined,
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--cwd") result.cwd = argv[++index];
    else if (arg === "--prompt") result.prompts.push(argv[++index]);
    else if (arg === "--prompt-file") result.promptFiles.push(resolve(argv[++index]));
    else if (arg === "--control-file") result.controlFile = resolve(argv[++index]);
    else if (arg === "--resume") result.resume = argv[++index];
    else if (arg === "--artifact-dir") result.artifactDir = argv[++index];
    else if (arg === "--model-provider") result.modelProvider = argv[++index];
    else if (arg === "--model") result.model = argv[++index];
    else if (arg === "--allow-tools") result.allowTools = true;
    else if (arg === "--close-session") result.closeSession = true;
    else if (arg === "--help" || arg === "-h") result.help = true;
    else throw new Error(`未知参数: ${arg}`);
  }

  result.cwd = resolve(result.cwd);
  if (result.artifactDir) result.artifactDir = resolve(result.artifactDir);
  if (Boolean(result.modelProvider) !== Boolean(result.model)) {
    throw new Error("--model-provider 与 --model 必须同时提供。");
  }
  return result;
}

function printHelp() {
  writeRedacted(`DSH Agent Bridge ${BRIDGE_VERSION}\n\n`);
  writeRedacted("用法: node src/cli.mjs [options]\n\n");
  writeRedacted("  --cwd PATH           DSH 工作目录，必须是绝对路径或可解析路径\n");
  writeRedacted("  --prompt TEXT        执行一轮输入；可重复，用于连续性验证\n");
  writeRedacted("  --prompt-file PATH   读取 Codex 编译的完整指令并发送给 DSH\n");
  writeRedacted("  --control-file PATH  接收本地监视器发出的 cancel 控制\n");
  writeRedacted("  --resume SESSION_ID  恢复已有 DSH 原生 session\n");
  writeRedacted("  --artifact-dir PATH  保存语义事件、原始 ACP 帧、stderr 和摘要\n");
  writeRedacted("  --model-provider ID  在发送 prompt 前设置 DSH session 的模型供应商\n");
  writeRedacted("  --model ID           与 --model-provider 配套的 DSH 模型 ID\n");
  writeRedacted("  --allow-tools        自动选择 DSH 提供的 allow_once 权限选项\n");
  writeRedacted("  --close-session      退出前显式关闭 session；默认保留以便恢复\n");
  writeRedacted("\n交互命令: /session, /diff, /cancel, /quit\n");
  writeRedacted("生成期间按 Ctrl+C 会先请求取消当前 DSH turn；再次按下才退出。\n");
}

function timestamp() {
  return new Date().toISOString();
}

function jsonSafe(value) {
  try {
    return JSON.stringify(value);
  } catch {
    return JSON.stringify({ unserializable: String(value) });
  }
}

function textFromContent(content) {
  if (!content) return "";
  if (content.type === "text") return content.text ?? "";
  return jsonSafe(content);
}

function summarizeTool(update) {
  const compact = {
    toolCallId: update.toolCallId,
    title: update.title,
    kind: update.kind,
    status: update.status,
    locations: update.locations,
    content: update.content,
  };
  return Object.fromEntries(Object.entries(compact).filter(([, value]) => value !== undefined));
}

async function runGit(cwd, commandArgs) {
  return new Promise((resolvePromise) => {
    const git = spawn("git", commandArgs, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
    });
    let stdout = "";
    let stderr = "";
    git.stdout.setEncoding("utf8");
    git.stderr.setEncoding("utf8");
    git.stdout.on("data", (chunk) => { stdout += chunk; });
    git.stderr.on("data", (chunk) => { stderr += chunk; });
    git.on("close", (code) => resolvePromise({ code, stdout, stderr }));
    git.on("error", (error) => resolvePromise({ code: -1, stdout, stderr: error.message }));
  });
}

async function runGitEvidence(cwd) {
  const [status, stat, numstat, patch, untracked] = await Promise.all([
    runGit(cwd, ["status", "--short"]),
    runGit(cwd, ["diff", "HEAD", "--stat"]),
    runGit(cwd, ["diff", "HEAD", "--numstat"]),
    runGit(cwd, ["diff", "HEAD", "--binary"]),
    runGit(cwd, ["ls-files", "--others", "--exclude-standard"]),
  ]);
  return { status, stat, numstat, patch, untracked };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }
  if (!isAbsolute(args.cwd)) throw new Error("--cwd 必须能解析为绝对路径");
  // The raw environment read becomes the validated launch parameter here: everything below
  // (the DSH `--profile` argument) uses this one value, and a bad name fails through the
  // bridge's redacted fatal path with a non-zero exit.
  const dshProfile = resolveDshProfile(process.env[DSH_ACP_PROFILE_ENV]);

  const startedAt = timestamp();
  if (args.artifactDir) await mkdir(args.artifactDir, { recursive: true });
  const eventPath = args.artifactDir ? resolve(args.artifactDir, "events.jsonl") : undefined;
  const rawPath = args.artifactDir ? resolve(args.artifactDir, "acp-frames.jsonl") : undefined;
  const stderrPath = args.artifactDir ? resolve(args.artifactDir, "dsh-stderr.log") : undefined;
  const summaryPath = args.artifactDir ? resolve(args.artifactDir, "session-summary.json") : undefined;
  const transcriptPath = args.artifactDir ? resolve(args.artifactDir, "delegation-transcript.log") : undefined;
  const handoffPath = args.artifactDir ? resolve(args.artifactDir, "codex-to-dsh.txt") : undefined;
  const rawStream = rawPath ? createWriteStream(rawPath, { flags: "a" }) : undefined;
  const stderrStream = stderrPath ? createWriteStream(stderrPath, { flags: "a" }) : undefined;
  const transcriptStream = transcriptPath ? createWriteStream(transcriptPath, { flags: "a" }) : undefined;
  // Every log sink is redacted per complete line before it reaches disk. Raw ACP frames and
  // child stderr arrive in arbitrary chunks, so the writer buffers a partial trailing line
  // instead of guessing; an unbounded single frame is flushed redacted rather than kept.
  const rawLog = rawStream ? createRedactingLineWriter(rawStream) : undefined;
  const stderrLog = stderrStream ? createRedactingLineWriter(stderrStream) : undefined;
  const transcriptLog = transcriptStream ? createRedactingLineWriter(transcriptStream) : undefined;
  const emit = (text, stream = process.stdout) => {
    // Console output is a sink too: the monitor captures the bridge's stdout/stderr and an
    // operator reads them in a terminal, so the same policy is applied before the write.
    // There is deliberately no un-redacted console writer in this file.
    writeRedacted(text, stream);
    transcriptLog?.write(text);
  };
  const writeConsole = writeRedacted;
  const filePrompts = await Promise.all(args.promptFiles.map((path) => readFile(path, "utf8")));
  const delegatedPrompts = [...args.prompts, ...filePrompts];
  if (handoffPath && delegatedPrompts.length > 0) {
    await writeFile(
      handoffPath,
      redactText(delegatedPrompts.map((prompt, index) => `===== CODEX -> DSH TURN ${index + 1} =====\n${prompt}\n`).join("\n")),
      "utf8",
    );
  }
  const gitBefore = await runGitEvidence(args.cwd);
  if (args.artifactDir) {
    await Promise.all([
      writeFile(resolve(args.artifactDir, "git-before-status.txt"), redactText(gitBefore.status.stdout || gitBefore.status.stderr), "utf8"),
      writeFile(resolve(args.artifactDir, "git-before-diff-stat.txt"), redactText(gitBefore.stat.stdout || gitBefore.stat.stderr), "utf8"),
      writeFile(resolve(args.artifactDir, "git-before-numstat.txt"), redactText(gitBefore.numstat.stdout || gitBefore.numstat.stderr), "utf8"),
      writeFile(resolve(args.artifactDir, "git-before-diff.patch"), redactText(gitBefore.patch.stdout || gitBefore.patch.stderr), "utf8"),
      writeFile(resolve(args.artifactDir, "git-before-untracked.txt"), redactText(gitBefore.untracked.stdout || gitBefore.untracked.stderr), "utf8"),
    ]);
  }

  const recordEvent = async (kind, payload = {}, source = "bridge") => {
    const event = { ts: timestamp(), source, kind, ...payload };
    // Durable evidence boundary: the JSONL never receives a secret-bearing value, even when
    // a single caller forgets to pre-filter its payload.
    if (eventPath) await appendFile(eventPath, `${jsonSafe(redactValue(event))}\n`, "utf8");
    return event;
  };

  const executableDir = dirname(fileURLToPath(import.meta.url));
  const dshEntryPoint = resolve(executableDir, "..", "node_modules", "@deepseek-ai", "dsh", "lib", "bin.js");
  // Release Blocker A: the DSH runtime process does not inherit the bridge's whole
  // environment. Only the non-sensitive allowlist plus the two confirmed DSH runtime fields
  // are forwarded, so a parent *_TOKEN/*_KEY/*_PASSWORD/*_SECRET/*_COOKIE/AUTHORIZATION can
  // never reach the provider-authenticated process.
  const child = spawn(process.execPath, [dshEntryPoint, "--profile", dshProfile], {
    cwd: args.cwd,
    env: buildChildEnv({ source: process.env, explicit: pickDshRuntimeEnv(process.env) }),
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });

  const acpOutput = new PassThrough();
  child.stdout.pipe(acpOutput);
  child.stdout.on("data", (chunk) => {
    if (rawLog) rawLog.write(chunk);
  });
  child.stderr.on("data", (chunk) => {
    const text = chunk.toString("utf8");
    if (stderrLog) stderrLog.write(chunk);
    emit(`[DSH:runtime] ${text}`, process.stderr);
  });

  let childExit = undefined;
  child.on("exit", (code, signal) => {
    childExit = { code, signal };
  });

  let activeSession;
  let agentContext;
  let controlTimer;
  let lastControlRequest;
  let turnRunning = false;
  let cancelRequested = false;
  let forceExit = false;
  const onSigint = () => {
    if (turnRunning && activeSession && !cancelRequested) {
      cancelRequested = true;
      writeConsole("\n[DSH:cancel] 已向当前 turn 发送取消请求。\n");
      void agentContext?.notify(methods.agent.session.cancel, { sessionId: activeSession.sessionId });
      return;
    }
    forceExit = true;
    writeConsole("\n[bridge] 正在退出。\n");
    child.kill("SIGTERM");
  };
  process.on("SIGINT", onSigint);

  const app = client({ name: "codex-dsh-agent-bridge" })
    .onRequest(methods.client.session.requestPermission, async (context) => {
      const request = context.params;
      await recordEvent("permission_request", request, "dsh");
      emit(`\n[DSH:permission] ${request.toolCall?.title ?? "工具调用"}\n`);
      const allowed = request.options?.find((option) => option.kind === "allow_once")
        ?? request.options?.find((option) => option.kind?.startsWith("allow"));
      const rejected = request.options?.find((option) => option.kind === "reject_once")
        ?? request.options?.find((option) => option.kind?.startsWith("reject"));
      const choice = args.allowTools ? allowed : rejected;
      if (!choice) return { outcome: { outcome: "cancelled" } };
      emit(`[bridge:permission] ${args.allowTools ? "ALLOW_ONCE" : "REJECT_ONCE"}: ${choice.name}\n`);
      await recordEvent("permission_response", { optionId: choice.optionId, optionKind: choice.kind });
      return { outcome: { outcome: "selected", optionId: choice.optionId } };
    });

  const stream = ndJsonStream(
    Writable.toWeb(child.stdin),
    Readable.toWeb(acpOutput),
  );

  let sessionId;
  let turns = 0;
  let stopReason;
  let failure;

  const showUpdate = async (message) => {
    const update = message.update;
    const type = update.sessionUpdate;
    await recordEvent("session_update", { sessionId, update }, "dsh");
    if (type === "agent_thought_chunk") {
      emit(`[DSH:thought] ${textFromContent(update.content)}\n`);
    } else if (type === "agent_message_chunk") {
      emit(`[DSH:assistant] ${textFromContent(update.content)}\n`);
    } else if (type === "tool_call") {
      emit(`[DSH:tool:start] ${jsonSafe(summarizeTool(update))}\n`);
    } else if (type === "tool_call_update") {
      emit(`[DSH:tool:update] ${jsonSafe(summarizeTool(update))}\n`);
    } else if (type === "plan") {
      emit(`[DSH:plan] ${jsonSafe(update.entries ?? update)}\n`);
    } else if (type === "config_option_update" || type === "current_mode_update") {
      emit(`[DSH:${type}] ${jsonSafe(update)}\n`);
    } else if (type !== "user_message_chunk") {
      emit(`[DSH:event:${type}] ${jsonSafe(update)}\n`);
    }
  };

  const runTurn = async (session, prompt) => {
    turns += 1;
    turnRunning = true;
    cancelRequested = false;
    // Release Blocker A: redact immediately before the prompt is dispatched to DSH, and
    // record the disclosure evidence (categories + counts only, never the removed value).
    const prepared = redactForDispatch(prompt);
    const dispatchPrompt = prepared.text;
    if (prepared.changed) {
      await recordEvent("prompt_redacted", {
        sessionId,
        turn: turns,
        policyVersion: SECURITY_POLICY_VERSION,
        categories: prepared.categories,
      });
    }
    emit(`\n[CODEX -> DSH:${turns}]\n${dispatchPrompt}\n`);
    await recordEvent("delegated_prompt", { sessionId, turn: turns, text: dispatchPrompt }, "codex");
    const responsePromise = session.prompt(dispatchPrompt);
    for (;;) {
      const message = await session.nextUpdate();
      if (message.kind === "stop") {
        stopReason = message.stopReason;
        emit(`[DSH:stop] ${message.stopReason}\n`);
        await recordEvent("turn_stop", { sessionId, turn: turns, response: message.response }, "dsh");
        break;
      }
      await showUpdate(message);
    }
    await responsePromise;
    turnRunning = false;
  };

  try {
    await app.connectWith(stream, async (agent) => {
      agentContext = agent;
      const init = await agent.request(methods.agent.initialize, {
        protocolVersion: PROTOCOL_VERSION,
        clientCapabilities: {
          fs: { readTextFile: false, writeTextFile: false },
          terminal: false,
        },
        clientInfo: { name: "codex-dsh-agent-bridge", version: BRIDGE_VERSION },
      });
      await recordEvent("initialized", { response: init }, "dsh");
      emit(`[DSH:connected] protocol=${init.protocolVersion} agent=${init.agentInfo?.name ?? "DeepSeek Harness"}\n`);

      if (args.resume) {
        const resumed = await agent.request(methods.agent.session.resume, {
          sessionId: args.resume,
          cwd: args.cwd,
          mcpServers: [],
        });
        activeSession = agent.attachSession({ sessionId: args.resume, ...resumed });
      } else {
        activeSession = await agent.buildSession({ cwd: args.cwd, mcpServers: [] }).start();
      }
      sessionId = activeSession.sessionId;
      emit(`[DSH:session] ${sessionId}${args.resume ? " (resumed)" : " (new)"}\n`);
      emit(`[bridge] workspace=${args.cwd}\n`);
      emit(`[bridge] 权限策略=${args.allowTools ? "ALLOW_ONCE" : "REJECT_ONCE"}\n`);
      await recordEvent(args.resume ? "session_resumed" : "session_created", {
        sessionId,
        response: activeSession.newSessionResponse,
      });

      // Apply the monitor selection after new/resume and before the first delegated prompt.
      // ACP rejection is fatal: a requested model must never silently fall back to another one.
      if (args.modelProvider && args.model) {
        const selection = { provider: args.modelProvider, model: args.model };
        const { value, response } = await applyAcpModelSelection({
          request: agent.request.bind(agent),
          method: methods.agent.session.setConfigOption,
          sessionId,
          configOptions: activeSession.newSessionResponse?.configOptions,
          selection,
        });
        await recordEvent("session_model_configured", {
          sessionId,
          configId: "model",
          selection,
          value,
          response,
        });
        emit(`[bridge:model] ${selection.provider} / ${selection.model}\n`);
      }

      if (args.controlFile) {
        controlTimer = setInterval(async () => {
          try {
            const control = JSON.parse(await readFile(args.controlFile, "utf8"));
            if (control.request_id === lastControlRequest) return;
            lastControlRequest = control.request_id;
            if (control.command === "cancel") {
              await agent.notify(methods.agent.session.cancel, { sessionId });
              await recordEvent("cancel_forwarded", { sessionId, requestId: control.request_id });
              emit(`[BRIDGE -> DSH] cancel ${control.request_id}\n`);
            }
          } catch (error) {
            if (error?.code !== "ENOENT" && error?.name !== "SyntaxError") {
              await recordEvent("control_error", { message: error.message });
            }
          }
        }, 250);
      }

      for (const prompt of delegatedPrompts) await runTurn(activeSession, prompt);

      if (delegatedPrompts.length === 0) {
        const readline = createInterface({ input: process.stdin, output: process.stdout });
        // `try/finally` is load-bearing: an open readline interface keeps `process.stdin`
        // referenced, so a throw inside the loop (or a rejected question) would leave the
        // bridge alive after its turn finished. The interface is always closed exactly once.
        try {
          writeConsole("[bridge] 输入消息并按 Enter。命令: /session /diff /cancel /quit\n");
          while (!forceExit) {
            const input = (await readline.question("you> ")).trim();
            if (!input) continue;
            if (input === "/quit") break;
            if (input === "/session") {
              writeConsole(`[DSH:session] ${sessionId}\n`);
              continue;
            }
            if (input === "/cancel") {
              await agent.notify(methods.agent.session.cancel, { sessionId });
              writeConsole("[DSH:cancel] 已发送。\n");
              continue;
            }
            if (input === "/diff") {
              const diff = await runGit(args.cwd, ["diff", "--stat"]);
              writeConsole(`[GIT:diff] exit=${diff.code}\n${diff.stdout || diff.stderr || "(clean)\n"}`);
              continue;
            }
            await runTurn(activeSession, input);
          }
        } finally {
          readline.close();
        }
      }

      if (args.closeSession) {
        await agent.request(methods.agent.session.close, { sessionId });
        await recordEvent("session_closed", { sessionId });
      }
      activeSession.dispose();
    });
  } catch (error) {
    failure = error instanceof Error ? { name: error.name, message: error.message, stack: error.stack } : { message: String(error) };
    await recordEvent("bridge_error", failure);
    throw error;
  } finally {
    if (controlTimer) clearInterval(controlTimer);
    process.off("SIGINT", onSigint);
    if (!child.killed && childExit === undefined) child.stdin.end();
    await new Promise((resolvePromise) => {
      if (childExit !== undefined) resolvePromise();
      else {
        const timeout = setTimeout(() => {
          child.kill("SIGTERM");
          resolvePromise();
        }, 5000);
        child.once("exit", () => {
          clearTimeout(timeout);
          resolvePromise();
        });
      }
    });
    const endedAt = timestamp();
    const git = await runGitEvidence(args.cwd);
    if (args.artifactDir) {
      await Promise.all([
        writeFile(resolve(args.artifactDir, "git-status.txt"), redactText(git.status.stdout || git.status.stderr), "utf8"),
        writeFile(resolve(args.artifactDir, "git-diff-stat.txt"), redactText(git.stat.stdout || git.stat.stderr), "utf8"),
        writeFile(resolve(args.artifactDir, "git-numstat.txt"), redactText(git.numstat.stdout || git.numstat.stderr), "utf8"),
        writeFile(resolve(args.artifactDir, "git-diff.patch"), redactText(git.patch.stdout || git.patch.stderr), "utf8"),
        writeFile(resolve(args.artifactDir, "git-untracked.txt"), redactText(git.untracked.stdout || git.untracked.stderr), "utf8"),
      ]);
    }
    const summary = {
      schema_version: 1,
      bridge_version: BRIDGE_VERSION,
      source: "external_dsh_acp_process",
      workspace: args.cwd,
      session_id: sessionId,
      resumed: Boolean(args.resume),
      requested_model: args.modelProvider && args.model
        ? { provider: args.modelProvider, model: args.model }
        : null,
      turns,
      start_utc: startedAt,
      end_utc: endedAt,
      stop_reason: stopReason,
      dsh_process_exit: childExit,
      bridge_error: failure,
      git_before_status_short: gitBefore.status.stdout,
      git_before_untracked: gitBefore.untracked.stdout,
      git_before_diff_stat: gitBefore.stat.stdout,
      git_before_diff_numstat: gitBefore.numstat.stdout,
      git_status_short: git.status.stdout,
      git_untracked: git.untracked.stdout,
      git_diff_stat: git.stat.stdout,
      git_diff_numstat: git.numstat.stdout,
      git_diff_exit_code: git.patch.code,
      git_state_changed:
        gitBefore.status.stdout !== git.status.stdout
        || gitBefore.untracked.stdout !== git.untracked.stdout
        || gitBefore.patch.stdout !== git.patch.stdout,
    };
    if (summaryPath) await writeFile(summaryPath, `${redactJson(summary, 2)}\n`, "utf8");
    rawLog?.end();
    stderrLog?.end();
    transcriptLog?.end();
    rawStream?.end();
    stderrStream?.end();
    transcriptStream?.end();
    writeConsole(`[bridge:exit] dsh=${jsonSafe(childExit)} session=${sessionId ?? "none"}\n`);
    const clean = git.status.code === 0 && git.status.stdout.trim() === "";
    writeConsole(`[GIT:state] ${clean ? "clean" : "dirty"}\n`);
    if (!clean) writeConsole(`${git.status.stdout || git.status.stderr}`);
    if (git.stat.stdout.trim()) writeConsole(`[GIT:diff] ${git.stat.stdout}`);
  }
}

main().catch((error) => {
  process.stderr.write(redactText(`[bridge:fatal] ${error.stack ?? error}\n`));
  process.exitCode = 1;
});
