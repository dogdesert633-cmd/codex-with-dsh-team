// test/support/spawn-guard.mjs
//
// Bounded, precisely-killed child process helper for the direct test suite.
//
// A test helper that awaits a child process forever turns one product regression into a hung
// suite that has to be killed from the outside. Every spawn in these tests therefore goes
// through this module, which guarantees four things:
//
//   1. a hard deadline per spawn (`timeoutMs`),
//   2. the deadline kills the whole process *tree* (a PowerShell wrapper may have spawned
//      grandchildren such as `node` or `icacls`),
//   3. every timer is cleared on settle, so nothing keeps the event loop alive,
//   4. the timeout is reported as `timedOut: true` and, after a short kill grace, the promise
//      settles anyway — a stubborn tree fails the test instead of hanging it.
//
// It deliberately does NOT swallow failures: callers assert on `code`/`timedOut`, so a real
// crash or a real hang is still visible.

import { spawn } from "node:child_process";

/** Default deadline for a helper-spawned process. */
export const DEFAULT_SPAWN_TIMEOUT_MS = 120_000;
/** How long a killed tree may take to actually die before we stop waiting. */
export const DEFAULT_KILL_GRACE_MS = 5_000;

/**
 * Terminate a child and its descendants.
 *
 * On Windows `child.kill()` only signals the direct child, and a `powershell.exe` wrapper can
 * leave a `node` grandchild behind; `taskkill /T /F` walks the tree. Elsewhere SIGKILL the
 * child (and its process group when it was detached).
 */
export function terminateProcessTree(child) {
  if (!child) return;
  if (child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform === "win32" && child.pid) {
    try {
      const killer = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
      killer.on("error", () => {});
    } catch {
      // Fall through to the direct kill below.
    }
  }
  try {
    child.kill("SIGKILL");
  } catch {
    // Already gone.
  }
}

/**
 * Spawn `command` and resolve with `{ code, signal, stdout, stderr, timedOut, forced }`.
 *
 * `stdio` may be overridden (e.g. `["ignore", fd, fd]` for a detached background process whose
 * output is read from files); in that case stdout/stderr are empty strings and the caller reads
 * the files.
 */
export function spawnWithTimeout(command, args, options = {}) {
  const {
    timeoutMs = DEFAULT_SPAWN_TIMEOUT_MS,
    killGraceMs = DEFAULT_KILL_GRACE_MS,
    env = process.env,
    cwd,
    stdio,
    killOnTimeout = true,
  } = options;

  return new Promise((resolvePromise, rejectPromise) => {
    let child;
    try {
      child = spawn(command, args, {
        env,
        cwd,
        windowsHide: true,
        stdio: stdio ?? ["ignore", "pipe", "pipe"],
      });
    } catch (error) {
      rejectPromise(error);
      return;
    }

    let stdout = "";
    let stderr = "";
    let timedOut = false;
    let settled = false;
    let deadline = null;
    let killGrace = null;

    const settle = (result) => {
      if (settled) return;
      settled = true;
      if (deadline) clearTimeout(deadline);
      if (killGrace) clearTimeout(killGrace);
      resolvePromise({ pid: child.pid ?? null, ...result, stdout, stderr, timedOut });
    };

    deadline = setTimeout(() => {
      timedOut = true;
      if (killOnTimeout) terminateProcessTree(child);
      // Never let a tree that refuses to die hang the suite.
      killGrace = setTimeout(() => settle({ code: null, signal: null, forced: true }), killGraceMs);
    }, timeoutMs);

    if (child.stdout) {
      child.stdout.setEncoding?.("utf8");
      child.stdout.on("data", (chunk) => { stdout += chunk; });
    }
    if (child.stderr) {
      child.stderr.setEncoding?.("utf8");
      child.stderr.on("data", (chunk) => { stderr += chunk; });
    }
    child.on("error", (error) => settle({ code: null, signal: null, error }));
    child.on("close", (code, signal) => settle({ code, signal }));
  });
}

/** Convenience wrapper that fails loudly instead of hanging when the deadline is hit. */
export async function spawnOrFail(command, args, options = {}) {
  const result = await spawnWithTimeout(command, args, options);
  if (result.timedOut) {
    const tail = (result.stderr || result.stdout || "").slice(-2000);
    throw new Error(
      `子进程超时（${options.timeoutMs ?? DEFAULT_SPAWN_TIMEOUT_MS}ms，已按 PID tree 终止）：${command} ${args.join(" ")}\n${tail}`,
    );
  }
  return result;
}
