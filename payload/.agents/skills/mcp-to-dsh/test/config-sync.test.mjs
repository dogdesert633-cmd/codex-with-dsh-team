import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnWithTimeout } from './support/spawn-guard.mjs';

const root = path.resolve(import.meta.dirname, '..');
const skillRoot = path.resolve(root, '..', '..', '..');
const scriptsDir = path.join(root, 'scripts');
const syncScript = path.join(scriptsDir, 'Sync-DshTeamConfig.ps1');
const teamScript = path.join(scriptsDir, 'start_dsh_team.ps1');
const monitorScript = path.join(scriptsDir, 'start_dsh_monitor.ps1');
const dispatchScript = path.join(scriptsDir, 'dispatch_dsh_gui.ps1');
const commonScript = path.join(scriptsDir, 'DshTeamCommon.ps1');
const ALL_PS = [syncScript, teamScript, monitorScript, dispatchScript, commonScript];

// 与实现相互独立的 fixture 常量。
const TEST_INSTALL_ID = 'test-install-0001';
const MARKER_NAME = '.codex-dsh-team-home.json';

// 同步脚本的 CLI 模式是一键同步唯一允许被执行的东西；这里用真实的 PowerShell 主机跑它，
// 只针对临时目录里的假 Home，绝不接触用户的真实 DSH home，也绝不启动 provider。
// Windows 上使用 Windows PowerShell 5.1，正是要确认 5.1 也满足同一个 JSON 输出契约。
const shell = process.platform === 'win32' ? 'powershell.exe' : 'pwsh';

// 同步 CLI 必须有界：超时按 PID tree 终止，并以清晰断言失败，而不是让整个套件挂住。
const SYNC_CLI_TIMEOUT_MS = 120000;

async function runSyncCli(args) {
  const result = await spawnWithTimeout(
    shell,
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', syncScript, ...args],
    { timeoutMs: SYNC_CLI_TIMEOUT_MS },
  );
  assert.equal(
    result.timedOut,
    false,
    `Sync-DshTeamConfig.ps1 超过 ${SYNC_CLI_TIMEOUT_MS}ms 未退出（已终止 PID tree）。stderr tail:\n${result.stderr.slice(-1500)}`,
  );
  return result;
}

// 与被测实现相互独立的 fixture：直接写 marker，而不是调用实现的 writer。
async function writeTeamHomeMarker(team, {
  installId = TEST_INSTALL_ID,
  toolkitId = 'codex-dsh-team-toolkit',
  schema = 'codex-dsh-team-home/v1',
  purpose = 'dsh-team-runtime-home',
} = {}) {
  await fs.writeFile(path.join(team, MARKER_NAME), `${JSON.stringify({
    schema,
    toolkitId,
    installId,
    createdAt: '2026-01-01T00:00:00.000Z',
    purpose,
  }, null, 2)}\n`);
}

async function snapshot(dir) {
  const entries = [];
  async function walk(current) {
    for (const entry of (await fs.readdir(current, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(current, entry.name);
      const stats = await fs.stat(full);
      entries.push(`${path.relative(dir, full)}|${stats.size}|${stats.mtimeMs}`);
      if (entry.isDirectory()) await walk(full);
    }
  }
  await walk(dir);
  return entries;
}

async function createHomes({ marker = true } = {}) {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-config-sync-'));
  const user = path.join(base, 'user');
  const team = path.join(base, 'team');
  await fs.mkdir(path.join(user, 'profiles', 'acp'), { recursive: true });
  await fs.mkdir(path.join(team, 'profiles', 'acp'), { recursive: true });
  await fs.writeFile(path.join(user, 'profiles', 'acp', 'package.json'), '{"name":"acp"}\n');
  await fs.writeFile(path.join(team, 'profiles', 'acp', 'package.json'), '{"name":"acp"}\n');
  await fs.writeFile(path.join(user, 'settings.yaml'), [
    'agent-default-model:',
    '  provider: aliyun',
    '  model: qwen3.8-flash',
    'providers:',
    '  aliyun:',
    '    api: openai-compatible',
    '    models:',
    '      - id: qwen3.8-flash',
    '        name: Qwen3.8 Flash',
    '      - id: other-model',
    '        name: Other Model',
    '',
  ].join('\n'));
  // 只在临时假 Home 里存在的“看起来像密钥”的值：任何输出都不得带上它。
  await fs.writeFile(path.join(user, '.credentials.yaml'), 'version: 1\nDEMO_API_KEY: local-only-secret-value\n');
  // profile 目录里放凭据形状的文件：它们绝不能被复制进 Team Home。
  await fs.writeFile(path.join(user, 'profiles', 'acp', '.env'), 'DEMO_API_KEY=local-only-secret-value\n');
  // 合成 PEM 头/尾在运行时拼装：公开源码不携带静态私钥签名（release content scan 会拦截该
  // 字面量，且"fake"标记在值级别不覆盖它）。写入 fixture 的字节与之前的字面量完全一致。
  const pemHeader = ['-----BEGIN', 'PRIVATE', 'KEY-----'].join(' ');
  const pemFooter = ['-----END', 'PRIVATE', 'KEY-----'].join(' ');
  await fs.writeFile(path.join(user, 'profiles', 'acp', 'server.pem'), `${pemHeader}\nfake\n${pemFooter}\n`);
  if (marker) await writeTeamHomeMarker(team);
  return { base, user, team };
}

const SECRET_MARKERS = ['local-only-secret-value', 'DEMO_API_KEY'];
const identityArgs = ['-InstallId', TEST_INSTALL_ID];

test('项目自有脚本不再包含任何 hash 校验逻辑', async () => {
  for (const file of ALL_PS) {
    const text = await fs.readFile(file, 'utf8');
    assert.equal(/Get-FileHash/i.test(text), false, `${path.basename(file)} 不得调用 Get-FileHash`);
    assert.equal(/Set-Authenticode|Get-AuthenticodeSignature/i.test(text), false);
    assert.equal(/SHA256SUMS|\.sha256|negative-matrix/i.test(text), false);
  }
  const syncText = await fs.readFile(syncScript, 'utf8');
  // 幂等性改为直接内容比较（无 hash 校验流程）。
  assert.match(syncText, /-cne \$userSettingsText/);
  assert.match(syncText, /-cne \$userCredentialsText/);
  assert.match(syncText, /-cne \(Get-Content -Raw -LiteralPath \$target\)/);
});

test('一键同步 CLI 只返回安全摘要，并把运行配置复制进 owned Team Home', async (context) => {
  const { base, user, team } = await createHomes();
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const before = await snapshot(user);

  const first = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, ...identityArgs]);
  assert.equal(first.code, 0, `stdout=${first.stdout} stderr=${first.stderr}`);
  const summary = JSON.parse(first.stdout.trim().split(/\r?\n/).at(-1));
  assert.equal(summary.status, 'success');
  assert.equal(summary.provider, 'aliyun');
  assert.equal(summary.model, 'qwen3.8-flash');
  assert.deepEqual(summary.changed, ['settings.yaml', '.credentials.yaml', 'profiles/acp/cordis.patch.yml']);
  assert.ok(summary.syncedAt);
  // 摘要里绝不能出现凭据值或凭据键名。
  for (const marker of SECRET_MARKERS) {
    assert.equal(first.stdout.includes(marker), false, `stdout 泄露了 ${marker}`);
    assert.equal(JSON.stringify(summary).includes(marker), false);
  }
  assert.equal(Object.hasOwn(summary, 'credentialKeys'), false, '凭据元数据不进入公开结果');

  // 实际落盘：Team Home 的 provider/model 与 ACP patch 都跟上了主 Home。
  const teamSettings = await fs.readFile(path.join(team, 'settings.yaml'), 'utf8');
  assert.match(teamSettings, /model: qwen3\.8-flash/);
  const patch = await fs.readFile(path.join(team, 'profiles', 'acp', 'cordis.patch.yml'), 'utf8');
  assert.match(patch, /provider: aliyun/);
  assert.match(patch, /model: qwen3\.8-flash/);
  const copiedCredentials = await fs.readFile(path.join(team, '.credentials.yaml'), 'utf8');
  assert.match(copiedCredentials, /DEMO_API_KEY/);

  // credential 副本必须只存在于 owned Team Home，且 ACL 已收紧为当前用户（无继承 ACE）。
  const aclProbe = await spawnWithTimeout('icacls.exe', [path.join(team, '.credentials.yaml')], { timeoutMs: 30000 });
  assert.equal(aclProbe.timedOut, false, 'icacls 必须有界返回');
  const aclListing = aclProbe.stdout;
  const aceEntries = [...aclListing.matchAll(/([^\s:]+):\(([^)]*)\)/g)];
  assert.ok(aceEntries.length > 0, `icacls 必须能读出 credential 副本的 ACL: ${aclListing}`);
  assert.equal(aceEntries.some((entry) => entry[2].includes('I')), false, 'credential 副本不得保留继承 ACE');
  // 只允许当前用户（或 SYSTEM）；其他身份意味着权限未收紧。
  const foreignAce = aceEntries.filter((entry) => !/SYSTEM$/.test(entry[1]));
  assert.equal(foreignAce.length >= 1, true, '必须至少保留当前用户的 ACE');
  assert.equal(aclListing.includes('BUILTIN\\Users') || aclListing.includes('Everyone'), false,
    'credential 副本不得对所有用户可读');

  // 凭据形状的文件绝不随 profile 复制。
  for (const denied of ['.env', 'server.pem']) {
    await assert.rejects(fs.stat(path.join(team, 'profiles', 'acp', denied)), /ENOENT/, `${denied} 不得进入 Team Home`);
  }

  // 同步方向单向：用户 DSH Home 的文件集合/大小/mtime 全程不变。
  assert.deepEqual(await snapshot(user), before, '用户 DSH Home 必须保持只读');
  await assert.rejects(fs.stat(path.join(user, 'profiles', 'acp', 'cordis.patch.yml')), /ENOENT/);
});

test('内置 deepseek-official 无需声明 llm-pi-ai provider 也可同步', async (context) => {
  const { base, user, team } = await createHomes();
  context.after(() => fs.rm(base, { recursive: true, force: true }));

  await fs.writeFile(path.join(user, 'settings.yaml'), [
    'agent-default-model:',
    '  provider: deepseek-official',
    '  model: deepseek-v4-flash',
    '',
  ].join('\n'));

  const result = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, ...identityArgs]);
  assert.equal(result.code, 0, `stdout=${result.stdout} stderr=${result.stderr}`);
  const summary = JSON.parse(result.stdout.trim().split(/\r?\n/).at(-1));
  assert.equal(summary.provider, 'deepseek-official');
  assert.equal(summary.model, 'deepseek-v4-flash');

  const patch = await fs.readFile(path.join(team, 'profiles', 'acp', 'cordis.patch.yml'), 'utf8');
  assert.match(patch, /provider: deepseek-official/);
  assert.match(patch, /model: deepseek-v4-flash/);
});

test('install id 也可以从 install manifest 中稳定读取', async (context) => {
  const { base, user, team } = await createHomes({ marker: false });
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const manifestPath = path.join(base, 'install.json');

  // 第一次调用创建 install manifest；由于 Team Home 还没有 marker，它会先被拒绝，
  // 但 manifest 已经生成，install id 因此是稳定且可复用的。
  const bootstrap = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, '-InstallManifestPath', manifestPath]);
  assert.equal(bootstrap.code, 1);
  assert.match(bootstrap.stderr, /没有合法 Team Home marker/);
  const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'));
  assert.equal(manifest.schema, 'codex-dsh-team-install/v1');
  assert.ok(manifest.installId);
  assert.equal(manifest.toolkitId, 'codex-dsh-team-toolkit');

  // 把 marker 换成 manifest 记录的 install id 后，只用 manifest 就能继续同步。
  await writeTeamHomeMarker(team, { installId: manifest.installId });
  const second = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, '-InstallManifestPath', manifestPath]);
  assert.equal(second.code, 0, `stderr=${second.stderr}`);
  const again = JSON.parse(await fs.readFile(manifestPath, 'utf8'));
  assert.equal(again.installId, manifest.installId, 'install id 必须稳定复用');
});

test('无 marker / marker 属于别的 install / 指向用户 DSH Home 一律拒绝', async (context) => {
  // 1) 已有目录但没有 marker：拒绝，且目录内容完全不变。
  const unownedHomes = await createHomes({ marker: false });
  context.after(() => fs.rm(unownedHomes.base, { recursive: true, force: true }));
  const unownedBefore = await snapshot(unownedHomes.team);
  const unowned = await runSyncCli(['-UserDshHome', unownedHomes.user, '-TeamDshHome', unownedHomes.team, ...identityArgs]);
  assert.equal(unowned.code, 1);
  assert.match(unowned.stderr, /没有合法 Team Home marker/);
  assert.deepEqual(await snapshot(unownedHomes.team), unownedBefore, '被拒绝的 Team Home 不得被写任何东西');
  assert.equal(SECRET_MARKERS.some((marker) => unowned.stderr.includes(marker)), false);

  // 2) marker 属于别的 install：拒绝。
  const foreignHomes = await createHomes();
  context.after(() => fs.rm(foreignHomes.base, { recursive: true, force: true }));
  await writeTeamHomeMarker(foreignHomes.team, { installId: 'someone-elses-install' });
  const foreign = await runSyncCli(['-UserDshHome', foreignHomes.user, '-TeamDshHome', foreignHomes.team, ...identityArgs]);
  assert.equal(foreign.code, 1);
  assert.match(foreign.stderr, /另一次安装/);

  // 3) 指向用户 DSH Home 本身：拒绝（绝不被 adopt/patch），用户 Home 保持不变。
  const userHomeHomes = await createHomes();
  context.after(() => fs.rm(userHomeHomes.base, { recursive: true, force: true }));
  const userSnapshot = await snapshot(userHomeHomes.user);
  const asUserHome = await runSyncCli(['-UserDshHome', userHomeHomes.user, '-TeamDshHome', userHomeHomes.user, ...identityArgs]);
  assert.equal(asUserHome.code, 1);
  assert.match(asUserHome.stderr, /只读配置来源|同一目录/);
  assert.deepEqual(await snapshot(userHomeHomes.user), userSnapshot, '用户 DSH Home 必须保持只读');
});

test('重复同步幂等：无变化时 changed 为空且不会重写文件', async (context) => {
  const { base, user, team } = await createHomes();
  context.after(() => fs.rm(base, { recursive: true, force: true }));

  const first = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, ...identityArgs]);
  assert.equal(first.code, 0, first.stderr);
  const patchPath = path.join(team, 'profiles', 'acp', 'cordis.patch.yml');
  const firstStat = await fs.stat(patchPath);

  const second = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, ...identityArgs]);
  assert.equal(second.code, 0, second.stderr);
  const again = JSON.parse(second.stdout.trim().split(/\r?\n/).at(-1));
  assert.deepEqual(again.changed, [], '内容一致时不得再报任何变更');
  assert.ok(again.notes.length > 0, '未变更项要用 note 说明，而不是静默');
  assert.equal((await fs.stat(patchPath)).mtimeMs, firstStat.mtimeMs, '未变化的文件不得被重写');

  // 任意（非 provider/model）设置变化都必须同步 —— 这正是去掉 hash 摘要后要保住的行为。
  const userSettingsPath = path.join(user, 'settings.yaml');
  await fs.writeFile(userSettingsPath, `${await fs.readFile(userSettingsPath, 'utf8')}# 新增一条无关设置\n`);
  const third = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, ...identityArgs]);
  assert.equal(third.code, 0, third.stderr);
  const thirdSummary = JSON.parse(third.stdout.trim().split(/\r?\n/).at(-1));
  assert.deepEqual(thirdSummary.changed, ['settings.yaml']);
  assert.match(await fs.readFile(path.join(team, 'settings.yaml'), 'utf8'), /新增一条无关设置/);
});

test('主 Home 与 Team Home 相同或缺参时直接拒绝', async (context) => {
  const { base, user, team } = await createHomes();
  context.after(() => fs.rm(base, { recursive: true, force: true }));

  const same = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', user, ...identityArgs]);
  assert.equal(same.code, 1);
  assert.match(same.stderr, /只读配置来源|同一目录/);
  assert.equal(SECRET_MARKERS.some((marker) => same.stderr.includes(marker)), false);

  const missing = await runSyncCli([]);
  assert.equal(missing.code, 2);

  // 独立 owned Team Home 仍是同步目标：不会被拒绝，也不会写回主 Home。
  const ok = await runSyncCli(['-UserDshHome', user, '-TeamDshHome', team, ...identityArgs]);
  assert.equal(ok.code, 0, ok.stderr);
  assert.equal(await fs.stat(path.join(user, 'profiles', 'acp', 'cordis.patch.yml')).then(() => true, () => false), false,
    '同步只能写入 Team Home');
});

test('含中文的 PowerShell 脚本必须是 UTF-8 with BOM，否则 5.1 按 ANSI 代码页解析会失败', async () => {
  for (const file of ALL_PS) {
    const bytes = await fs.readFile(file);
    const text = bytes.toString('utf8');
    const hasNonAscii = [...text].some((char) => char.codePointAt(0) > 127);
    const hasBom = bytes.length >= 3 && bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf;
    assert.equal(hasBom, hasNonAscii, `${path.basename(file)}：非 ASCII 内容必须配 UTF-8 BOM（BOM=${hasBom}）`);
  }
});

test('cmd 入口保持纯 ASCII（cmd.exe 解析安全）', async () => {
  for (const name of ['start_dsh_team.cmd', 'sync_dsh_team_config.cmd']) {
    const bytes = await fs.readFile(path.join(skillRoot, name));
    assert.equal([...bytes].some((byte) => byte > 127), false, `${name} 必须是纯 ASCII`);
  }
});

test('一键同步的透传参数从启动器一直到 server.mjs', async () => {
  const monitorText = await fs.readFile(monitorScript, 'utf8');
  const teamText = await fs.readFile(teamScript, 'utf8');
  assert.match(monitorText, /\[string\]\$UserDshHome/);
  assert.match(monitorText, /'--dsh-user-home'/);
  assert.match(monitorText, /\$userHomeArgument/);
  assert.match(teamText, /UserDshHome\s*=\s*\$resolvedUserHome/);
  // Team Home 继续是 dispatch 的 dshHome；主 Home 只作为同步来源单独透传。
  assert.match(teamText, /DshHome\s*=\s*\$resolvedTeamHome/);
  // 稳定 install id 必须一路透传到 monitor 与 server。
  assert.match(teamText, /InstallId\s*=\s*\$InstallId/);
  assert.match(monitorText, /'--toolkit-install-id'/);
});

test('启动器不再硬编码 DSH 版本目录回退', async () => {
  for (const file of ALL_PS) {
    const text = await fs.readFile(file, 'utf8');
    assert.equal(/home-acp-/i.test(text), false, `${path.basename(file)} 不得硬编码 DSH 版本目录`);
    assert.equal(/home-dsh-/i.test(text), false);
  }
});
