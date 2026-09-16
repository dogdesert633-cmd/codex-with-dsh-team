// Regression tests for the direct-test spawn guard (test/support/spawn-guard.mjs).
//
// The guard exists so a hanging child cannot hang the suite. These tests prove both halves:
// the deadline really fires and kills the process tree, and a healthy spawn clears its timer
// instead of keeping the process alive until the deadline.

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnWithTimeout } from './support/spawn-guard.mjs';

function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function waitForExit(pid, timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!isProcessAlive(pid)) return true;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  return !isProcessAlive(pid);
}

test('spawnWithTimeout 在 deadline 上终止挂住的子进程并报告 timedOut', { timeout: 30000 }, async () => {
  const startedAt = Date.now();
  const result = await spawnWithTimeout(
    process.execPath,
    ['-e', 'setInterval(() => {}, 1000)'],
    { timeoutMs: 800 },
  );
  const elapsed = Date.now() - startedAt;

  assert.equal(result.timedOut, true, '挂住的子进程必须被判定为超时');
  assert.ok(result.pid, '必须能拿到被终止进程的 pid');
  assert.ok(elapsed >= 700 && elapsed < 20000, `超时必须在 deadline 附近生效（实际 ${elapsed}ms）`);
  // 精确终止：进程（树）真的死了，而不是留下孤儿。
  assert.equal(await waitForExit(result.pid, 10000), true, `子进程 ${result.pid} 未被终止`);
});

test('spawnWithTimeout 正常退出时清除计时器，不把 deadline 拖进退出路径', { timeout: 30000 }, async () => {
  const startedAt = Date.now();
  // deadline 远大于实际耗时：如果计时器没有被 clear，测试进程会被拖到 60s。
  const result = await spawnWithTimeout(
    process.execPath,
    ['-e', 'process.stdout.write("ok")'],
    { timeoutMs: 60000 },
  );
  const elapsed = Date.now() - startedAt;

  assert.equal(result.timedOut, false);
  assert.equal(result.code, 0);
  assert.equal(result.stdout.trim(), 'ok');
  assert.ok(elapsed < 10000, `计时器必须被清除（实际 ${elapsed}ms）`);
});
