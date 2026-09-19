// Extraction-scope, generalization and redaction-wiring checks for the public payload.
//
// No hash anywhere: extraction fidelity is proven by path existence plus direct byte
// comparison against an OPTIONAL external baseline supplied by the maintainer. The payload
// itself ships no install manifest and hardcodes no internal development path — the approved
// install set lives in the toolkit inventory (`release/payload-inventory.json`).

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnWithTimeout } from './support/spawn-guard.mjs';

const skillRoot = path.resolve(import.meta.dirname, '..');
const payloadRoot = path.resolve(skillRoot, '..', '..', '..');
// Optional maintainer-only comparison baseline. It is an EXPLICIT external input, never an
// internal build/review path: the public payload must not depend on (or disclose) the
// development tree, so an absent baseline skips cleanly instead of failing.
const EXTERNAL_BASELINE_ROOT = (process.env.CODEX_DSH_TEAM_BASELINE_ROOT ?? '').trim();
const scriptsDir = path.join(skillRoot, 'scripts');
const srcDir = path.join(skillRoot, 'src');

// A standalone checkout (a git clone, or an extracted release) has no outer development tree.
// The location of the payload root therefore cannot be assumed: if this file is ever executed
// from an unexpected directory the scope checks below would silently walk an unrelated tree
// (for example %TEMP%), which is exactly the failure mode this guard prevents.
const exists = (target) => fs.stat(target).then(() => true, () => false);

async function assertPayloadLayout() {
  const problems = [];
  if (!(await exists(path.join(skillRoot, 'package.json')))) {
    problems.push(`skill root has no package.json: ${skillRoot}`);
  }
  if (!(await exists(path.join(skillRoot, 'SKILL.md')))) {
    problems.push(`skill root has no SKILL.md: ${skillRoot}`);
  }
  if (!(await exists(path.join(payloadRoot, '.agents', 'skills', 'mcp-to-dsh', 'package.json')))) {
    problems.push(`payload root does not contain .agents/skills/mcp-to-dsh/package.json: ${payloadRoot}`);
  }
  assert.equal(problems.length, 0,
    `payload layout guard failed (run this test from <payload>/.agents/skills/mcp-to-dsh/test): ${problems.join('; ')}`);
}

// Managed files this work package intentionally modified. Every other managed file must stay
// byte-identical to the external baseline; the managed list itself comes from the baseline
// manifest (an explicit external input), not from a hand-maintained payload whitelist.
const MODIFIED_MANAGED = new Set([
  '.agents/skills/codex-team/SKILL.md',
  '.agents/skills/codex-team/agents/openai.yaml',
  '.agents/skills/codex-team/assets/WORK_PACKAGE.md',
  '.agents/skills/codex-team/references/roles.md',
  '.agents/skills/codex-team/references/workflow.md',
  '.agents/skills/dsh-role-boundaries/SKILL.md',
  '.agents/skills/dsh-role-boundaries/agents/openai.yaml',
  '.agents/skills/dsh-role-boundaries/assets/WORK_PACKAGE.md',
  '.agents/skills/dsh-role-boundaries/references/dsh-execution-policy.md',
  '.agents/skills/dsh-role-boundaries/references/dsh-recovery-and-fallback.md',
  '.agents/skills/dsh-role-boundaries/references/model-validation-and-no-hash.md',
  '.agents/skills/dsh-role-boundaries/references/task-capability-routing.md',
  '.agents/skills/mcp-to-dsh/.gitignore',
  '.agents/skills/mcp-to-dsh/SKILL.md',
  '.agents/skills/mcp-to-dsh/package.json',
  '.agents/skills/mcp-to-dsh/references/operations.md',
  '.agents/skills/mcp-to-dsh/scripts/Sync-DshTeamConfig.ps1',
  '.agents/skills/mcp-to-dsh/scripts/dispatch_dsh_gui.ps1',
  '.agents/skills/mcp-to-dsh/scripts/start_dsh_monitor.ps1',
  '.agents/skills/mcp-to-dsh/scripts/start_dsh_team.ps1',
  '.agents/skills/mcp-to-dsh/src/cli.mjs',
  '.agents/skills/mcp-to-dsh/src/server.mjs',
  '.agents/skills/mcp-to-dsh/templates/DS_READY_WORK_PACKAGE.md',
  '.agents/skills/mcp-to-dsh/test/config-sync.test.mjs',
  '.agents/skills/mcp-to-dsh/test/server.test.mjs',
  'start_dsh_team.cmd',
  'sync_dsh_team_config.cmd',
]);

const FORBIDDEN_BASENAMES = new Set([
  'INSTALL.ps1',
  'README.zh-CN.md',
  'DELIVERY_SUMMARY.md',
  'COPY_FILE_LIST.json',
  'settings.yaml',
  '.credentials.yaml',
  'credentials.json',
  'secrets.json',
  '.npmrc',
]);

const FORBIDDEN_EXTENSIONS = ['.zip', '.log', '.pem', '.key', '.pfx', '.p12'];
const FORBIDDEN_DIR_SEGMENTS = ['artifacts', '.dsh', 'sessions', 'storages', 'logs', 'backups'];

async function listFiles(root, { skipNodeModules = true } = {}) {
  const results = [];
  async function walk(current) {
    for (const entry of await fs.readdir(current, { withFileTypes: true })) {
      if (skipNodeModules && entry.name === 'node_modules') continue;
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) await walk(full);
      else results.push(path.relative(root, full).replace(/\\/g, '/'));
    }
  }
  await walk(root);
  return results.sort();
}

const read = (relative) => fs.readFile(path.join(payloadRoot, relative), 'utf8');

test('payload 不含个人路径、凭据、runtime 或打包残留，也不携带安装清单', async () => {
  await assertPayloadLayout();
  const files = await listFiles(payloadRoot);
  for (const relative of files) {
    const base = path.basename(relative);
    assert.equal(FORBIDDEN_BASENAMES.has(base), false, `禁止的敏感/runtime/清单文件: ${relative}`);
    assert.equal(base.startsWith('.env'), false, `禁止的 .env 类文件: ${relative}`);
    assert.equal(FORBIDDEN_EXTENSIONS.some((extension) => base.toLowerCase().endsWith(extension)), false,
      `禁止的文件类型: ${relative}`);
    for (const segment of relative.split('/')) {
      assert.equal(FORBIDDEN_DIR_SEGMENTS.includes(segment), false, `禁止的 runtime 目录: ${relative}`);
    }
  }

  // 个人绝对路径 / 用户名 / 私有项目名：整棵树都不允许出现。
  // 模式由片段拼装（并对反斜杠做正则转义），避免扫描器命中自身源码里的模式字面量。
  const bs = String.fromCharCode(92);
  const esc = bs + bs;
  const personalPatterns = [
    new RegExp(['C:', esc, 'Users', esc].join(''), 'i'),                  // 单反斜杠形式
    new RegExp(['C:', esc, esc, 'Users', esc, esc].join(''), 'i'),        // 双反斜杠（源码转义）形式
    new RegExp(['token', '_save', '_plan'].join(''), 'i'),
    new RegExp(['Dog', '_o'].join(''), 'i'),
  ];
  // DSH 版本目录耦合只约束产品文件；测试本身要能提到这个模式才可能断言它不存在。
  const versionCouplingPatterns = [/home-acp-/i, /home-dsh-/i];
  for (const relative of files) {
    const text = await read(relative).catch(() => null);
    if (text === null) continue;
    for (const pattern of personalPatterns) {
      assert.equal(pattern.test(text), false, `${relative} 命中个人路径模式 ${pattern}`);
    }
    if (relative.includes('/test/')) continue;
    for (const pattern of versionCouplingPatterns) {
      assert.equal(pattern.test(text), false, `${relative} 命中 DSH 版本目录耦合 ${pattern}`);
    }
  }
});

test('受管文件与显式提供的外部基线逐字节一致（维护者可选）', async (t) => {
  await assertPayloadLayout();
  // Maintainer-only compatibility comparison. The baseline is an EXPLICIT external input: this
  // payload never hardcodes an internal build/review path, so a standalone clone and a release
  // package run cleanly and report the comparison as skipped instead of silently passing.
  if (!EXTERNAL_BASELINE_ROOT) {
    t.skip('maintainer-only: no external baseline provided (set CODEX_DSH_TEAM_BASELINE_ROOT to a package root holding COPY_FILE_LIST.json)');
    return;
  }
  const baselineManifestPath = path.join(EXTERNAL_BASELINE_ROOT, 'COPY_FILE_LIST.json');
  if (!await fs.stat(baselineManifestPath).then(() => true, () => false)) {
    t.skip(`maintainer-only: external baseline at ${EXTERNAL_BASELINE_ROOT} has no COPY_FILE_LIST.json`);
    return;
  }

  const inventory = JSON.parse(await fs.readFile(baselineManifestPath, 'utf8'));
  const managed = inventory.files.map((entry) => entry.path);
  assert.ok(managed.length > 0, '外部基线清单必须列出受管文件');

  // A baseline built before the three-independent-skill layout lists managed paths that the
  // current payload deliberately no longer contains (the removed mixed team skill). Reporting
  // those as "missing" would be a false failure, and treating them as matched would be a false
  // PASS. Record a real skip with the reason instead: this comparison needs a baseline built
  // from the current layout.
  const removedLayout = managed.filter((relative) => relative.includes('skills/codex-dsh-team/'));
  if (removedLayout.length > 0) {
    t.skip(`maintainer-only: external baseline uses the pre-3-skill layout (${removedLayout.length} path(s) under skills/codex-dsh-team/ no longer exist); rebuild the baseline from the current layout to compare`);
    return;
  }

  let identical = 0;
  for (const relative of managed) {
    const inPayload = path.join(payloadRoot, relative);
    const inBaseline = path.join(EXTERNAL_BASELINE_ROOT, relative);
    assert.equal(await fs.stat(inBaseline).then(() => true, () => false), true, `外部基线缺少 ${relative}`);
    assert.equal(await fs.stat(inPayload).then(() => true, () => false), true, `payload 缺少受管文件 ${relative}`);
    if (MODIFIED_MANAGED.has(relative)) continue;
    const [left, right] = await Promise.all([fs.readFile(inPayload), fs.readFile(inBaseline)]);
    assert.equal(Buffer.compare(left, right), 0, `${relative} 与外部基线不一致`);
    identical += 1;
  }
  assert.ok(identical >= 15, `应有足够多未修改受管文件参与逐字节比较（实际 ${identical}）`);
});

test('server.mjs 与 cli.mjs 不再把完整父环境交给子进程', async () => {
  const server = await fs.readFile(path.join(srcDir, 'server.mjs'), 'utf8');
  const cli = await fs.readFile(path.join(srcDir, 'cli.mjs'), 'utf8');

  assert.match(server, /from "\.\/security\.mjs"/);
  assert.match(cli, /from "\.\/security\.mjs"/);

  assert.equal(/\{\s*\.\.\.process\.env/.test(server), false, 'server.mjs 不得整体继承 process.env');
  assert.equal(/env:\s*process\.env\b/.test(cli), false, 'cli.mjs 不得整体继承 process.env');

  assert.match(server, /buildChildEnv\(\{/);
  assert.match(server, /explicit: \{ DSH_HOME: dshHome, DSH_PERMISSION_MODE: permissionMode \}/);
  assert.match(cli, /buildChildEnv\(\{ source: process\.env, explicit: pickDshRuntimeEnv\(process\.env\) \}\)/);
  assert.match(server, /lastChildEnvAudit = auditChildEnv\(process\.env, spawnEnv\)/);
  assert.match(server, /buildPermissionVerification\(\{/);

  // credential env 家族对 child 一律拒绝：不得出现按 apiKeyEnv 名字“窄放行”的实现。
  assert.equal(/apiKeyEnv/.test(server), false, 'server.mjs 不得按 apiKeyEnv 放行 child env');
  const common = await fs.readFile(path.join(scriptsDir, 'DshTeamCommon.ps1'), 'utf8');
  assert.equal(/apiKeyEnv[\s\S]{0,40}(Allow|Forward|Pass|Include)/i.test(common), false,
    'DshTeamCommon.ps1 不得按 apiKeyEnv 放行 child env');
});

test('落盘 / SSE / HTTP / console / ACP 投影前都经过集中 redaction', async () => {
  const server = await fs.readFile(path.join(srcDir, 'server.mjs'), 'utf8');
  const cli = await fs.readFile(path.join(srcDir, 'cli.mjs'), 'utf8');

  // HTTP 与 SSE。
  assert.match(server, /JSON\.stringify\(redactValue\(value\)\)/, 'json()/broadcast() 必须 redaction');
  assert.match(server, /event: snapshot\\ndata: \$\{JSON\.stringify\(redactValue\(/);
  // run manifest / registry / model preference / control file。
  assert.match(server, /redactJson\(publicRun\(run\), 2\)/);
  assert.match(server, /redactJson\(registry, 2\)/);
  assert.match(server, /redactJson\(value, 2\)/);
  assert.match(server, /writeControlFile/);
  assert.equal(/writeFile\(run\.controlPath, JSON\.stringify/.test(server), false);
  // 事件读取与 bridge 日志。
  assert.match(server, /const event = redactValue\(JSON\.parse\(completeLines\[index\]\)\)/);
  assert.match(server, /redactText\(Buffer\.concat\(stdout\)\.toString\("utf8"\)\)/);
  assert.match(server, /redactText\(Buffer\.concat\(stderr\)\.toString\("utf8"\)\)/);
  // prompt 派发与 title。
  assert.match(server, /redactForDispatch\(/);
  assert.match(server, /promptRedaction: dispatchRedaction\.changed/);
  assert.match(server, /title: redactText\(payload\.title/);
  // 值级 defense in depth：被拒绝转发的凭据值与 Monitor token 都登记为 known secret。
  assert.match(server, /registerDeniedEnvValues\(process\.env\)/);
  assert.match(server, /registerKnownSecrets\(\[accessToken\]\)/);
  assert.match(server, /knownSecretValues: knownSecretCount\(\)/);
  assert.match(cli, /registerDeniedEnvValues\(process\.env\)/);

  // 负向守卫：server.mjs 里不允许存在未经 redaction 的 JSON.stringify 出口。
  const rawStringify = server.split('\n')
    .filter((line) => line.includes('JSON.stringify('))
    .filter((line) => !line.includes('JSON.stringify(redactValue('));
  assert.deepEqual(rawStringify, [], `server.mjs 存在未脱敏 JSON 出口:\n${rawStringify.join('\n')}`);

  // 负向守卫：cli.mjs 里不允许存在绕过 redaction 的 console 写入。
  const rawConsoleWrites = cli.split('\n')
    .filter((line) => /process\.(stdout|stderr)\.write\(/.test(line))
    .filter((line) => !/redactText\(|writeRedacted\(/.test(line));
  assert.deepEqual(rawConsoleWrites, [], `cli.mjs 存在未脱敏 console 写入:\n${rawConsoleWrites.join('\n')}`);
  assert.match(cli, /const prepared = redactForDispatch\(prompt\)/);
  assert.match(cli, /session\.prompt\(dispatchPrompt\)/);
  assert.match(cli, /jsonSafe\(redactValue\(event\)\)/);
  assert.equal((cli.match(/createRedactingLineWriter\(/g) ?? []).length, 3, 'raw/stderr/transcript 三个 sink 都要 redaction');
  assert.match(cli, /redactJson\(summary, 2\)/);
  assert.equal((cli.match(/redactText\(git\./g) ?? []).length >= 4, true, 'git evidence 必须 redaction');
  assert.match(cli, /function writeRedacted\(/, 'cli.mjs 必须有唯一的 redacted console writer');
});

test('workspace 与 contractPath 绑定守卫存在，并在产生 artifact 前 fail-closed', async () => {
  const server = await fs.readFile(path.join(srcDir, 'server.mjs'), 'utf8');
  assert.match(server, /function assertContractPathBound\(/);
  assert.match(server, /const boundContractPath = assertContractPathBound\(payload\.contractPath, defaultWorkspace\)/);
  assert.match(server, /contractPath 必须指向 \.md 合同文件/);
  assert.match(server, /contractPath 逃出了 workspace/);
  assert.match(server, /contractPath: boundContractPath,/);
  // 拒绝必须发生在 run/artifact 创建之前。
  const guardIndex = server.indexOf('const boundContractPath = assertContractPathBound');
  const artifactIndex = server.indexOf('const artifactDir = resolve(workspace, "artifacts", "dsh-gui-runs", id)');
  assert.ok(guardIndex > 0 && artifactIndex > 0 && guardIndex < artifactIndex,
    'workspace/contract 绑定必须早于 artifact 目录创建');

  const dispatch = await fs.readFile(path.join(scriptsDir, 'dispatch_dsh_gui.ps1'), 'utf8');
  assert.match(dispatch, /Assert-DshContractPathBound -ContractRelativePath \$ContractRelativePath -Workspace \$workspacePath/);
  assert.match(dispatch, /Monitor 记录的 workspace/);
  const common = await fs.readFile(path.join(scriptsDir, 'DshTeamCommon.ps1'), 'utf8');
  assert.match(common, /function Assert-DshContractPathBound \{/);
  assert.match(common, /Assert-DshReparseFreePath -Path \$absolute -Label 'contractPath'/);
});

test('provider / model 仍然只来自用户配置或可验证发现，缺失时 fail-visible', async (context) => {
  const syncScript = path.join(scriptsDir, 'Sync-DshTeamConfig.ps1');
  const probe = await spawnWithTimeout('powershell.exe', [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command',
    `. '${syncScript}'; try { Get-DshModelSelection -Text "llm-pi-ai:\n  providers: {}\n" | Out-Null; Write-Output 'RESULT=accepted' } catch { Write-Output ('RESULT=refused:' + $_.Exception.Message) }`,
  ], { timeoutMs: 60000 });
  assert.equal(probe.timedOut, false, `PowerShell 探测必须有界返回：\n${probe.stderr.slice(-1500)}`);
  assert.match(probe.stdout, /RESULT=refused:/, '缺少 agent-default-model 必须 fail-visible');
  assert.match(probe.stdout, /agent-default-model/);

  const dependencyAvailable = await fs.stat(path.join(skillRoot, 'node_modules', 'yaml'))
    .then(() => true, () => false);
  if (!dependencyAvailable) {
    context.diagnostic('node_modules/yaml 缺失：跳过 readDshModelCatalog 的 Node 侧断言（安装依赖后由 npm test 覆盖）');
    return;
  }
  const { readDshModelCatalog } = await import('../src/model-settings.mjs');
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-model-generalization-'));
  try {
    await assert.rejects(() => readDshModelCatalog(base), /ENOENT|settings\.yaml/);
    await assert.rejects(() => readDshModelCatalog(null), /DSH_HOME|未配置/);
  } finally {
    await fs.rm(base, { recursive: true, force: true });
  }
});

test('没有固定 model id 与固定 profile 名耦合', async () => {
  await assertPayloadLayout();
  const files = await listFiles(payloadRoot);
  // 模式同样由片段拼装，避免扫描器命中自身源码里的模式字面量。
  const modelPatterns = [
    new RegExp(['gpt', '-\\d'].join(''), 'i'),
    new RegExp(['claude', '-\\d'].join(''), 'i'),
    new RegExp(['gemini', '-\\d'].join(''), 'i'),
    new RegExp(['lu', 'na'].join(''), 'i'),
  ];
  for (const relative of files) {
    const text = await read(relative).catch(() => null);
    if (text === null) continue;
    for (const pattern of modelPatterns) {
      assert.equal(pattern.test(text), false, `${relative} 仍带有固定 model 耦合 ${pattern}`);
    }
  }

  // 可写 Team profile 不再有静默默认值；必须发现或显式配置。
  const team = await fs.readFile(path.join(scriptsDir, 'start_dsh_team.ps1'), 'utf8');
  const sync = await fs.readFile(path.join(scriptsDir, 'Sync-DshTeamConfig.ps1'), 'utf8');
  for (const [name, text] of [['start_dsh_team.ps1', team], ['Sync-DshTeamConfig.ps1', sync]]) {
    assert.equal(/\$TeamProfile\s*=\s*'/.test(text), false, `${name} 不得给 TeamProfile 静默默认值`);
    assert.match(text, /Resolve-DshTeamProfile/, `${name} 必须通过 Resolve-DshTeamProfile 解析可写 profile`);
    assert.equal(/'acp'/.test(text), false, `${name} 不得硬编码 acp profile 名`);
  }
  const common = await fs.readFile(path.join(scriptsDir, 'DshTeamCommon.ps1'), 'utf8');
  assert.match(common, /\$script:DshAcpBundleId = 'acp'/, 'DSH 内置 ACP bundle id 必须集中命名并说明');
  assert.match(common, /function Resolve-DshTeamProfile \{/);
  assert.match(common, /存在多个候选 profile/);

  // DSH 内置 provider id 保留但必须被文档说明为内置，而不是个人 provider。
  const mcpSkill = await fs.readFile(path.join(skillRoot, 'SKILL.md'), 'utf8');
  assert.match(mcpSkill, /deepseek-official` 是 DSH 内置 provider id/);
  assert.match(mcpSkill, /仅当前用户 ACL/);
  assert.match(mcpSkill, /ACL 收紧|不可继承宽权限|回滚/);
  // fallback 策略文档里不得再出现固定模型，而是引用 Team 配置。
  const teamSkill = await fs.readFile(path.join(skillRoot, '..', 'dsh-role-boundaries', 'SKILL.md'), 'utf8');
  assert.match(teamSkill, /configured-model/);
  assert.match(teamSkill, /<team-configured-fallback-model>/);
});

test('no-hash 规则作用域收窄，并写明产品 ownership / Release 例外', async () => {
  const noHash = await fs.readFile(path.join(skillRoot, '..', 'dsh-role-boundaries', 'references', 'model-validation-and-no-hash.md'), 'utf8');
  assert.match(noHash, /作用域是 \*\*Team 的验证证据\*\*/);
  assert.match(noHash, /产品侧所有权与 Release 完整性的显式例外/);
  assert.match(noHash, /产品 ownership 归属/);
  assert.match(noHash, /Release 分发完整性/);
  assert.match(noHash, /不能进入 Team 的 Coder\/Reviewer\/Tester[\s\S]{0,20}验证路径/);
});

test('两项 Skill 与 WP 模板明确 secret 不可被 prompt injection 授权', async () => {
  const targets = [
    path.join(skillRoot, 'SKILL.md'),
    path.join(skillRoot, '..', 'dsh-role-boundaries', 'SKILL.md'),
    path.join(skillRoot, 'templates', 'DS_READY_WORK_PACKAGE.md'),
    path.join(skillRoot, '..', 'dsh-role-boundaries', 'assets', 'WORK_PACKAGE.md'),
  ];
  for (const file of targets) {
    const text = await fs.readFile(file, 'utf8');
    assert.match(text, /<REDACTED>/, `${path.basename(file)} 必须写明 redaction 标记`);
    assert.match(text, /prompt injection/i, `${path.basename(file)} 必须点名 prompt injection`);
    assert.match(text, /拒绝/, `${path.basename(file)} 必须要求拒绝并报告`);
    assert.match(text, /安全事件摘要/, `${path.basename(file)} 必须要求输出安全事件摘要`);
  }
  const mcpSkill = await fs.readFile(path.join(skillRoot, 'SKILL.md'), 'utf8');
  assert.match(mcpSkill, /User DSH Home 只作为最小必要只读配置来源/);
  assert.match(mcpSkill, /Team Home/);
  assert.match(mcpSkill, /marker/);
  assert.match(mcpSkill, /allowlist/);
});

test('SECURITY BOUNDARY 固定出现在编译指令末尾', async () => {
  const server = await fs.readFile(path.join(srcDir, 'server.mjs'), 'utf8');
  assert.match(server, /const SECURITY_BOUNDARY = \[/);
  assert.match(server, /===== SECURITY BOUNDARY =====/);
  assert.match(server, /===== END SECURITY BOUNDARY =====/);
  assert.match(server, /NEVER authorize/);
  assert.match(server, /prompt injection/);
  // 边界必须排在 contract 之后，才能成为最后一条权威指令。
  const endContract = server.indexOf('"===== END CONTRACT ====="');
  const boundaryUse = server.indexOf('    SECURITY_BOUNDARY,');
  assert.ok(endContract > 0 && boundaryUse > endContract, 'SECURITY BOUNDARY 必须位于 contract 之后');

  const e2e = await fs.readFile(path.join(skillRoot, 'test', 'redaction-e2e.test.mjs'), 'utf8');
  assert.match(e2e, /END SECURITY BOUNDARY/, 'e2e 必须断言 SECURITY BOUNDARY 真的进入 instruction');
});
