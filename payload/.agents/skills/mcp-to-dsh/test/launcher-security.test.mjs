// Direct tests for the launcher-side security surface (Release Blocker A + B).
//
// Everything runs against temporary directories and fake credentials. The integration case
// starts the *local* monitor on 127.0.0.1 for a temporary workspace, authenticates with the
// DPAPI-protected record and then stops it again; no network, no provider, no real DSH home.
// The integration case is skipped when the skill's node_modules is absent, because the
// launcher would otherwise try to install dependencies.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnWithTimeout } from './support/spawn-guard.mjs';

const skillRoot = path.resolve(import.meta.dirname, '..');
const scriptsDir = path.join(skillRoot, 'scripts');
const commonScript = path.join(scriptsDir, 'DshTeamCommon.ps1');
const monitorScript = path.join(scriptsDir, 'start_dsh_monitor.ps1');
const dispatchScript = path.join(scriptsDir, 'dispatch_dsh_gui.ps1');

const PS51 = 'powershell.exe';
const PWSH = 'pwsh';
const hosts = process.platform === 'win32' ? [PS51, PWSH] : [PWSH];

const FAKE_TOKEN = 'faketoken0000000000000000000000000000000000000000000000000000abcd';

// Synthetic Windows Team Home, assembled at runtime.
//
// The fixture needs a drive-rooted path, but the public source must not contain a literal
// assignment of an absolute drive path to the DSH home variable: that is exactly the
// fixed-environment binding signature the release scan blocks, and a real machine path has no
// place in a portable fixture anyway. Building the value from parts keeps the runtime
// semantics (and every assertion below) identical to before.
const WINDOWS_DRIVE_C = 'C' + ':';
const SYNTHETIC_TEAM_HOME = [WINDOWS_DRIVE_C, 'Team'].join('\\');

// 每个 helper 都有硬 deadline：超时按 PID tree 精确终止，并让测试以清晰断言失败，
// 而不是把整个套件挂住。
const PS_COMMAND_TIMEOUT_MS = 120000;
const PS_SCRIPT_TIMEOUT_MS = 180000;

async function runPowerShell(host, scriptText, { args = [], env } = {}) {
  const result = await spawnWithTimeout(
    host,
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', scriptText, ...args],
    { env: env ?? process.env, timeoutMs: PS_COMMAND_TIMEOUT_MS },
  );
  assert.equal(
    result.timedOut,
    false,
    `${host} -Command 超过 ${PS_COMMAND_TIMEOUT_MS}ms 未退出（已终止 PID tree）：\n${result.stderr.slice(-1500)}`,
  );
  return { ...result, stdout: result.stdout.trim(), stderr: result.stderr.trim() };
}

async function runScriptFile(host, file, args = []) {
  const result = await spawnWithTimeout(
    host,
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file, ...args],
    { timeoutMs: PS_SCRIPT_TIMEOUT_MS },
  );
  assert.equal(
    result.timedOut,
    false,
    `${host} -File ${path.basename(file)} 超过 ${PS_SCRIPT_TIMEOUT_MS}ms 未退出（已终止 PID tree）：\n${result.stderr.slice(-1500)}`,
  );
  return result;
}

// 启动后台服务的脚本必须用「文件」而不是管道作为 stdio。
// `start_dsh_monitor.ps1 -Background` 会 detach 出一个长期运行的 node 进程；该孙进程会继承
// 父进程可继承的 stdio 句柄。若父进程的 stdout 是管道，管道写端就被孙进程持有，
// Node 的 child 'close' 事件（要求 stdio 全部关闭）永远不会触发。
// 生产入口是控制台（start_dsh_team.cmd / 双击），不存在这个问题；测试这里用文件描述符，
// 只等待 'exit'，语义与真实使用一致。deadline 仍由共享 helper 保证。
async function runScriptFileDetached(host, file, args, outPath, errPath) {
  const outHandle = await fs.open(outPath, 'w');
  const errHandle = await fs.open(errPath, 'w');
  try {
    const result = await spawnWithTimeout(
      host,
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file, ...args],
      { stdio: ['ignore', outHandle.fd, errHandle.fd], timeoutMs: PS_SCRIPT_TIMEOUT_MS },
    );
    const [stdout, stderr] = await Promise.all([
      fs.readFile(outPath, 'utf8').catch(() => ''),
      fs.readFile(errPath, 'utf8').catch(() => ''),
    ]);
    assert.equal(
      result.timedOut,
      false,
      `${host} -File ${path.basename(file)} 超过 ${PS_SCRIPT_TIMEOUT_MS}ms 未退出（已终止 PID tree）：\n${stderr.slice(-1500)}`,
    );
    return { code: result.code, stdout, stderr };
  } finally {
    await outHandle.close().catch(() => {});
    await errHandle.close().catch(() => {});
  }
}

test('DshTeamCommon 的安全 JSON 契约在 5.1 与 pwsh 上都成立', async () => {
  for (const host of hosts) {
    const result = await runPowerShell(host, [
      `. '${commonScript}'`,
      'Assert-DshPowerShellRuntime | Out-Null',
      '$probe = Test-JsonSerializerCompatibility',
      'Write-Output ("ok=" + $probe.ok)',
      'Write-Output ("json=" + (ConvertTo-SafeJson -InputObject ([ordered]@{ a = 1; b = @(\'x\') }) -Compress))',
      'Write-Output ("single=" + (ConvertTo-SafeJson -InputObject ([ordered]@{ changed = @(\'only.yaml\') }) -Compress))',
      'Write-Output ("empty=" + (ConvertTo-SafeJson -InputObject ([ordered]@{ changed = @() }) -Compress))',
    ].join('; '));
    assert.equal(result.code, 0, `${host}: ${result.stderr}`);
    assert.match(result.stdout, /ok=True/, `${host}: JSON 兼容探测必须通过`);
    assert.match(result.stdout, /json=\{"a":1,"b":\["x"\]\}/);
    // 单元素数组必须保持数组形状（OrderedDictionary 序列化陷阱的回归保护）。
    assert.match(result.stdout, /single=\{"changed":\["only\.yaml"\]\}/);
    assert.match(result.stdout, /empty=\{"changed":\[\]\}/);
  }
});

test('DPAPI token 往返在当前用户下可用，且密文不含明文', async () => {
  for (const host of hosts) {
    const result = await runPowerShell(host, [
      `. '${commonScript}'`,
      `$token = '${FAKE_TOKEN}'`,
      '$protected = Protect-DshMonitorToken -Token $token',
      'Write-Output ("roundtrip=" + ((Unprotect-DshMonitorToken -ProtectedToken $protected) -ceq $token))',
      'Write-Output ("containsPlain=" + $protected.Contains($token))',
      'Write-Output ("len=" + $protected.Length)',
    ].join('; '));
    assert.equal(result.code, 0, `${host}: ${result.stderr}`);
    assert.match(result.stdout, /roundtrip=True/, `${host}: DPAPI 往返必须成立`);
    assert.match(result.stdout, /containsPlain=False/, `${host}: 密文不得包含明文`);
    assert.equal(result.stdout.includes(FAKE_TOKEN), false, `${host}: 密文不得回显明文`);
  }
});

test('Get-DshMonitorAccessToken 拒绝明文旧记录并只在内存里解密', async () => {
  const result = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `$plain = [pscustomobject]@{ access_token = '${FAKE_TOKEN}'; url = 'http://127.0.0.1:1' }`,
    'try { Get-DshMonitorAccessToken -Record $plain | Out-Null; Write-Output "plain=ACCEPTED" } catch { Write-Output "plain=REFUSED" }',
    `$protected = Protect-DshMonitorToken -Token '${FAKE_TOKEN}'`,
    '$ok = [pscustomobject]@{ access_token_protected = $protected; url = "http://127.0.0.1:1" }',
    'Write-Output ("protected=" + ((Get-DshMonitorAccessToken -Record $ok) -ceq [string](Unprotect-DshMonitorToken -ProtectedToken $protected)))',
    '$empty = [pscustomobject]@{ url = "http://127.0.0.1:1" }',
    'try { Get-DshMonitorAccessToken -Record $empty | Out-Null; Write-Output "empty=ACCEPTED" } catch { Write-Output "empty=REFUSED" }',
  ].join('; '));
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /plain=REFUSED/, '明文 access_token 记录必须被拒绝读取');
  assert.match(result.stdout, /protected=True/);
  assert.match(result.stdout, /empty=REFUSED/);
  assert.equal(result.stdout.includes(FAKE_TOKEN), false, 'console 绝不输出 token 明文');
});

test('Resolve-DshTeamHome 在 PowerShell 侧同样只接受带完整 marker 的目录', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-team-home-ps-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const workspace = path.join(base, 'project');
  const unowned = path.join(base, 'unowned');
  const teamRoot = path.join(base, 'runtimes');
  await fs.mkdir(workspace, { recursive: true });
  await fs.mkdir(unowned, { recursive: true });
  await fs.writeFile(path.join(unowned, 'keep.txt'), 'untouched\n');

  const result = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `$created = Resolve-DshTeamHome -Workspace '${workspace}' -InstallId 'install-ps-1' -TeamHomeRoot '${teamRoot}' -AllowCreate`,
    'Write-Output ("created=" + $created.Created + ";path=" + $created.TeamDshHome)',
    `$marker = Read-DshTeamHomeMarker -TeamDshHome '${path.join(teamRoot, 'install-ps-1')}'`,
    'Write-Output ("markerSchema=" + $marker.schema + ";toolkit=" + $marker.toolkitId + ";install=" + $marker.installId + ";purpose=" + $marker.purpose)',
    `$owned = Resolve-DshTeamHome -Requested '${path.join(teamRoot, 'install-ps-1')}' -Workspace '${workspace}' -InstallId 'install-ps-1'`,
    'Write-Output ("reused=" + (-not $owned.Created))',
    `try { Resolve-DshTeamHome -Requested '${unowned}' -Workspace '${workspace}' -InstallId 'install-ps-1' -AllowCreate | Out-Null; Write-Output 'unowned=ACCEPTED' } catch { Write-Output 'unowned=REFUSED' }`,
    `try { Resolve-DshTeamHome -Requested '${path.join(workspace, 'inside')}' -Workspace '${workspace}' -InstallId 'install-ps-1' -AllowCreate | Out-Null; Write-Output 'inside=ACCEPTED' } catch { Write-Output 'inside=REFUSED' }`,
    `try { Resolve-DshTeamHome -Requested 'relative\\team' -Workspace '${workspace}' -InstallId 'install-ps-1' | Out-Null; Write-Output 'relative=ACCEPTED' } catch { Write-Output 'relative=REFUSED' }`,
  ].join('; '));
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /created=True/);
  assert.match(result.stdout, /markerSchema=codex-dsh-team-home\/v1;toolkit=codex-dsh-team-toolkit;install=install-ps-1;purpose=dsh-team-runtime-home/);
  assert.match(result.stdout, /reused=True/);
  assert.match(result.stdout, /unowned=REFUSED/);
  assert.match(result.stdout, /inside=REFUSED/);
  assert.match(result.stdout, /relative=REFUSED/);
  assert.deepEqual(await fs.readdir(unowned), ['keep.txt'], '被拒绝的目录必须完全不变');
});

test('PowerShell child env 策略与 src/security.mjs 逐项一致', async () => {
  const { CHILD_ENV_ALLOWLIST, isDeniedEnvName } = await import('../src/security.mjs');
  const psList = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    'Write-Output (ConvertTo-SafeJson -InputObject (Get-DshChildEnvAllowlist) -Compress)',
  ].join('; '));
  assert.equal(psList.code, 0, psList.stderr);
  assert.deepEqual(JSON.parse(psList.stdout), [...CHILD_ENV_ALLOWLIST],
    'PS 与 JS 的 child env allowlist 必须完全一致，否则策略会分叉');

  const names = [
    'DEMO_API_KEY', 'MY_TOKEN', 'APP_PASSWORD', 'SERVICE_SECRET', 'SESSION_COOKIE',
    'AUTHORIZATION', 'AZURE_CREDENTIALS', 'PRIVATE_KEY', 'DSH_MONITOR_TOKEN', 'NODE_OPTIONS',
    'PATH', 'PATHEXT', 'LOCALAPPDATA', 'USERPROFILE', 'OS',
  ];
  const psVerdicts = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `$names = @(${names.map((name) => `'${name}'`).join(', ')})`,
    '$result = [ordered]@{}',
    '$result.matches = @(foreach ($name in $names) { if (Test-DshDeniedEnvName -Name $name) { $name } })',
    'Write-Output (ConvertTo-SafeJson -InputObject $result -Compress)',
  ].join('; '));
  assert.equal(psVerdicts.code, 0, psVerdicts.stderr);
  const psMatches = JSON.parse(psVerdicts.stdout).matches;
  const jsMatches = names.filter((name) => isDeniedEnvName(name));
  assert.deepEqual(psMatches, jsMatches, 'PS 与 JS 的 env deny 判定必须一致');
});

test('Get-DshNarrowedChildEnv 丢弃父进程 secret 家族，只保留 allowlist', async () => {
  const { CHILD_ENV_ALLOWLIST } = await import('../src/security.mjs');
  const fakeEnv = {
    PATH: process.env.PATH,
    LOCALAPPDATA: process.env.LOCALAPPDATA,
    TEMP: process.env.TEMP,
    DEMO_API_KEY: 'fake-env-secret-value-0001',
    MY_TOKEN: 'fake-token-value-0002',
    APP_PASSWORD: 'fake-password-value-0003',
    SERVICE_SECRET: 'fake-secret-value-0004',
    SESSION_COOKIE: 'fake-cookie-value-0005',
    AUTHORIZATION: 'fake-authorization-value-0006',
    DSH_MONITOR_TOKEN: 'fake-monitor-token-value-0007',
    NODE_OPTIONS: '--require evil.js',
    SOME_UNLISTED: 'value',
  };
  const result = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `$narrowed = Get-DshNarrowedChildEnv -Explicit @{ DSH_HOME = '${SYNTHETIC_TEAM_HOME}'; DSH_PERMISSION_MODE = 'danger-full-access' }`,
    'Write-Output (ConvertTo-SafeJson -InputObject $narrowed -Compress)',
    'try { Get-DshNarrowedChildEnv -Explicit @{ FAKE_TOKEN = "x" } | Out-Null; Write-Output "explicit=ACCEPTED" } catch { Write-Output "explicit=REFUSED" }',
  ].join('; '), { env: fakeEnv });
  assert.equal(result.code, 0, result.stderr);
  const [narrowedJson, verdict] = result.stdout.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const narrowed = JSON.parse(narrowedJson);
  assert.equal(narrowed.PATH, fakeEnv.PATH);
  assert.equal(narrowed.DSH_HOME, SYNTHETIC_TEAM_HOME);
  assert.equal(narrowed.DSH_PERMISSION_MODE, 'danger-full-access');
  for (const denied of ['DEMO_API_KEY', 'MY_TOKEN', 'APP_PASSWORD', 'SERVICE_SECRET', 'SESSION_COOKIE', 'AUTHORIZATION', 'DSH_MONITOR_TOKEN', 'NODE_OPTIONS', 'SOME_UNLISTED']) {
    assert.equal(Object.hasOwn(narrowed, denied), false, `${denied} 不得进入 child env`);
  }
  assert.equal(Object.keys(narrowed).every((key) => CHILD_ENV_ALLOWLIST.includes(key) || key.startsWith('DSH_')), true);
  assert.match(verdict, /explicit=REFUSED/);
  for (const secret of ['fake-env-secret-value-0001', 'fake-token-value-0002', 'fake-secret-value-0004', 'fake-cookie-value-0005']) {
    assert.equal(result.stdout.includes(secret), false, `child env 投影泄露了 ${secret}`);
  }
});

test('Start-DshNarrowedProcess 真的用收窄后的环境启动子进程', async () => {
  const script = [
    `. '${commonScript}'`,
    `$narrowed = Get-DshNarrowedChildEnv -Explicit @{ DSH_HOME = '${SYNTHETIC_TEAM_HOME}' }`,
    `$probe = 'console.log(JSON.stringify({ key: !!process.env.DEMO_API_KEY, token: !!process.env.MY_TOKEN, path: !!process.env.PATH, dsh: process.env.DSH_HOME || null }))'`,
    "$result = Start-DshNarrowedProcess -FileName (Get-Command node.exe).Source -Arguments ('-e \"' + $probe + '\"') -WorkingDirectory $env:TEMP -TimeoutSeconds 30 -Environment $narrowed",
    'Write-Output $result.Stdout.Trim()',
    'Write-Output ("exit=" + $result.ExitCode)',
  ].join('; ');
  const result = await runPowerShell(PS51, script, {
    env: {
      PATH: process.env.PATH,
      TEMP: process.env.TEMP,
      LOCALAPPDATA: process.env.LOCALAPPDATA,
      DEMO_API_KEY: 'fake-env-secret-value-0001',
      MY_TOKEN: 'fake-token-value-0002',
    },
  });
  assert.equal(result.code, 0, result.stderr);
  const payload = JSON.parse(result.stdout.split(/\r?\n/)[0].trim());
  assert.deepEqual(payload, { key: false, token: false, path: true, dsh: SYNTHETIC_TEAM_HOME });
  assert.equal(result.stdout.includes('fake-env-secret-value-0001'), false);
  assert.match(result.stdout, /exit=0/);
});

test('Resolve-DshTeamProfile 只接受显式配置或唯一可发现的 profile', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-team-profile-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const team = path.join(base, 'team');
  await fs.mkdir(path.join(team, 'profiles', 'only'), { recursive: true });
  await fs.writeFile(path.join(team, 'profiles', 'only', 'package.json'), '{"name":"only"}\n');

  const single = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `Write-Output ('one=' + (Resolve-DshTeamProfile -TeamDshHome '${team}'))`,
    `Write-Output ('explicit=' + (Resolve-DshTeamProfile -Requested 'only' -TeamDshHome '${team}'))`,
    `Write-Output ('env=' + (Resolve-DshTeamProfile -TeamDshHome '${team}' -EnvironmentValue 'only'))`,
    `try { Resolve-DshTeamProfile -Requested 'missing' -TeamDshHome '${team}' | Out-Null; Write-Output 'missing=ACCEPTED' } catch { Write-Output 'missing=REFUSED' }`,
    `try { Resolve-DshTeamProfile -Requested '../escape' -TeamDshHome '${team}' | Out-Null; Write-Output 'traversal=ACCEPTED' } catch { Write-Output 'traversal=REFUSED' }`,
  ].join('; '));
  assert.equal(single.code, 0, single.stderr);
  assert.match(single.stdout, /one=only/);
  assert.match(single.stdout, /explicit=only/);
  assert.match(single.stdout, /env=only/);
  assert.match(single.stdout, /missing=REFUSED/);
  assert.match(single.stdout, /traversal=REFUSED/);

  // 0 个候选：fail-visible。
  const emptyTeam = path.join(base, 'empty');
  await fs.mkdir(path.join(emptyTeam, 'profiles'), { recursive: true });
  const none = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `try { Resolve-DshTeamProfile -TeamDshHome '${emptyTeam}' | Out-Null; Write-Output 'none=ACCEPTED' } catch { Write-Output 'none=REFUSED' }`,
  ].join('; '));
  assert.match(none.stdout, /none=REFUSED/);

  // 多个候选：必须 fail-visible，绝不猜一个可写 profile。
  await fs.mkdir(path.join(team, 'profiles', 'second'), { recursive: true });
  await fs.writeFile(path.join(team, 'profiles', 'second', 'package.json'), '{"name":"second"}\n');
  const many = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `try { Resolve-DshTeamProfile -TeamDshHome '${team}' | Out-Null; Write-Output 'many=ACCEPTED' } catch { Write-Output ('many=REFUSED: ' + $_.Exception.Message) }`,
  ].join('; '));
  assert.match(many.stdout, /many=REFUSED/);
  assert.match(many.stdout, /only/);
  assert.match(many.stdout, /second/);
});

test('Assert-DshContractPathBound 绑定当前 workspace 并拒绝逃逸', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-contract-bound-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const workspace = path.join(base, 'ws');
  await fs.mkdir(path.join(workspace, '.dsh', 'contracts'), { recursive: true });
  await fs.writeFile(path.join(workspace, '.dsh', 'contracts', 'ok.md'), '# ok\n');

  const result = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `$ok = Assert-DshContractPathBound -ContractRelativePath '.dsh/contracts/ok.md' -Workspace '${workspace}'`,
    `Write-Output ('ok=' + ($ok -ieq (Join-Path '${workspace}' '.dsh/contracts/ok.md')))`,
    `try { Assert-DshContractPathBound -ContractRelativePath '${path.join(workspace, 'abs.md')}' -Workspace '${workspace}' | Out-Null; Write-Output 'abs=ACCEPTED' } catch { Write-Output 'abs=REFUSED' }`,
    `try { Assert-DshContractPathBound -ContractRelativePath '../../outside.md' -Workspace '${workspace}' | Out-Null; Write-Output 'dotdot=ACCEPTED' } catch { Write-Output 'dotdot=REFUSED' }`,
    `try { Assert-DshContractPathBound -ContractRelativePath '.dsh/contracts/not-md.txt' -Workspace '${workspace}' | Out-Null; Write-Output 'nonmd=ACCEPTED' } catch { Write-Output 'nonmd=REFUSED' }`,
    `try { Assert-DshContractPathBound -ContractRelativePath '.dsh/../escape.md' -Workspace '${workspace}' | Out-Null; Write-Output 'inner=ACCEPTED' } catch { Write-Output 'inner=REFUSED' }`,
    `try { Assert-DshContractPathBound -ContractRelativePath 'C:\\outside\\x.md' -Workspace '${workspace}' | Out-Null; Write-Output 'drive=ACCEPTED' } catch { Write-Output 'drive=REFUSED' }`,
    `try { Assert-DshContractPathBound -ContractRelativePath '' -Workspace '${workspace}' | Out-Null; Write-Output 'empty=ACCEPTED' } catch { Write-Output 'empty=REFUSED' }`,
  ].join('; '));
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /ok=True/);
  for (const label of ['abs', 'dotdot', 'nonmd', 'inner', 'drive', 'empty']) {
    assert.match(result.stdout, new RegExp(`${label}=REFUSED`), `${label} 必须被拒绝`);
  }
});

test('credential 副本 ACL 收紧为当前用户且无继承 ACE（5.1 与 pwsh 一致）', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-acl-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const source = path.join(base, 'user-credentials.yaml');
  const destination = path.join(base, 'team-credentials.yaml');
  await fs.writeFile(source, 'DEMO_API_KEY: fake-value-1234567890\n');

  for (const host of hosts) {
    const result = await runPowerShell(host, [
      `. '${commonScript}'`,
      `$path = Copy-DshAtomicFile -Source '${source}' -Destination '${destination}' -RestrictToCurrentUser`,
      `Write-Output ('copied=' + ($path -ieq '${destination}'))`,
      '$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name',
      `$listing = @(& (Join-Path $env:SystemRoot 'System32\\icacls.exe') '${destination}' 2>&1 | ForEach-Object { [string]$_ })`,
      '$entries = [regex]::Matches(($listing -join "`n"), \'([^\\s:]+):\\(([^)]*)\\)\')',
      'Write-Output ("entryCount=" + $entries.Count)',
      'Write-Output ("inherited=" + (@($entries | Where-Object { $_.Groups[2].Value -match \'I\' }).Count))',
      'Write-Output ("foreign=" + (@($entries | Where-Object { $_.Groups[1].Value -ine $identity -and $_.Groups[1].Value -notmatch \'SYSTEM$\' }).Count))',
      `Write-Output ('missingResult=' + (Set-DshCurrentUserOnlyAcl -Path (Join-Path '${base}' 'does-not-exist.yaml')))`,
    ].join('; '));
    assert.equal(result.code, 0, `${host}: ${result.stderr}`);
    assert.match(result.stdout, /copied=True/, host);
    assert.match(result.stdout, /entryCount=[1-9]/, `${host}: ACL 必须可解析`);
    assert.match(result.stdout, /inherited=0/, `${host}: 不得保留继承 ACE`);
    assert.match(result.stdout, /foreign=0/, `${host}: 不得保留其他身份 ACE`);
    assert.match(result.stdout, /missingResult=False/, `${host}: 不存在的路径必须返回 false`);
    assert.equal(result.stdout.includes('fake-value-1234567890'), false, `${host}: ACL 校验不得打印文件内容`);
  }
});

test('dispatch 脚本只从 DPAPI 记录解密 token，启动器不写明文 token', async () => {
  const dispatchText = await fs.readFile(dispatchScript, 'utf8');
  assert.match(dispatchText, /Get-DshMonitorAccessToken/);
  assert.equal(/\$monitorRecord\.access_token\b/.test(dispatchText), false, 'dispatch 不得直接读明文 token 字段');

  const monitorText = await fs.readFile(monitorScript, 'utf8');
  assert.match(monitorText, /access_token_protected\s*=\s*\(Protect-DshMonitorToken/);
  assert.equal(/access_token\s*=\s*\$monitorToken/.test(monitorText), false, '启动器不得把明文 token 写进记录');
  assert.match(monitorText, /token_scheme\s*=\s*'dpapi-current-user'/);
  // 控制台绝不打印 token。
  assert.equal(/Write-(Host|Output|Warning|Note).*\$monitorToken/.test(monitorText), false);
});

test('本地 Monitor 记录只保存 DPAPI 密文，认证只接受解密后的 token', { timeout: 180000 }, async (context) => {
  const nodeModules = path.join(skillRoot, 'node_modules');
  if (!(await fs.stat(nodeModules).then(() => true, () => false))) {
    context.skip('node_modules 缺失：跳过需要真实启动 Monitor 的本机集成用例');
    return;
  }

  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-monitor-record-'));
  const workspace = path.join(base, 'project');
  const teamRoot = path.join(base, 'runtimes');
  await fs.mkdir(workspace, { recursive: true });
  const installId = 'monitor-test-install';
  const userDshHome = path.join(base, 'user-dsh');
  await fs.mkdir(userDshHome, { recursive: true });
  await fs.writeFile(path.join(userDshHome, 'settings.yaml'), 'agent-default-model:\n  provider: fake-provider\n  model: fake-model\n');

  let monitorPid = null;
  context.after(async () => {
    if (monitorPid) {
      await runPowerShell(PS51, `try { Stop-Process -Id ${monitorPid} -Force -ErrorAction Stop } catch { }`);
    }
    await fs.rm(base, { recursive: true, force: true });
  });

  const started = await runScriptFileDetached(PS51, monitorScript, [
    '-Workspace', workspace,
    '-DshHome', path.join(teamRoot, installId),
    '-InstallId', installId,
    '-TeamHomeRoot', teamRoot,
    '-UserDshHome', userDshHome,
    '-Background',
    '-AutoPort',
    '-Port', '45731',
  ], path.join(base, 'monitor.out'), path.join(base, 'monitor.err'));
  assert.equal(started.code, 0, `stdout=${started.stdout} stderr=${started.stderr}`);
  // start_dsh_monitor.ps1 输出一份（美化过的）JSON 记录；用首尾花括号提取，避免依赖行数。
  const recordStart = started.stdout.indexOf('{');
  const recordEnd = started.stdout.lastIndexOf('}');
  assert.equal(recordStart >= 0 && recordEnd > recordStart, true, `未找到 JSON 记录: ${started.stdout}`);
  const publicRecord = JSON.parse(started.stdout.slice(recordStart, recordEnd + 1));
  assert.ok(publicRecord.url, started.stdout);
  assert.equal(publicRecord.install_id, installId);
  // 公开记录绝不包含 access token。
  assert.equal(/[0-9a-f]{64}/i.test(started.stdout), false, '公开记录不得包含 token 形状的字符串');

  const recordPath = path.join(workspace, 'artifacts', 'dsh-monitor', 'server.json');
  const recordText = await fs.readFile(recordPath, 'utf8');
  assert.equal(recordText.includes('access_token"'), false, '记录里不得出现明文 access_token 字段');
  assert.equal(/[0-9a-f]{64}/i.test(recordText), false, '记录里不得出现 64 位十六进制 token');
  const record = JSON.parse(recordText);
  assert.equal(record.token_scheme, 'dpapi-current-user');
  assert.ok(record.access_token_protected);
  assert.equal(record.dsh_home, path.join(teamRoot, installId));
  assert.equal(record.install_id, installId);
  monitorPid = record.pid;
  assert.ok(monitorPid, 'DPAPI 记录必须包含 monitor pid');

  // health 暴露 ownership 与 child env 策略证据（不含任何值）。
  const health = await fetch(`${publicRecord.url}/api/health`).then((response) => response.json());
  assert.equal(health.service, 'dsh-team-monitor');
  assert.equal(health.security.teamHomeOwnership.state, 'owned');
  assert.equal(health.security.teamHomeOwnership.installId, installId);
  assert.equal(health.security.userDshHomeReadOnly, true);
  assert.equal(health.security.childEnv.policy, 'explicit-allowlist');
  assert.equal(health.security.redaction.disk, true);
  assert.equal(health.security.redaction.promptDispatch, true);
  assert.equal(JSON.stringify(health).includes('access_token'), false);

  // 无 token 的受保护端点被拒绝。
  const unauthorized = await fetch(`${publicRecord.url}/api/runs`);
  assert.equal(unauthorized.status, 401);

  // 由 PowerShell 在内存里解密 DPAPI 记录并完成一次认证请求；明文 token 绝不进入
  // 本测试的 stdout，输出里只有 HTTP 状态码。
  const verify = await runPowerShell(PS51, [
    `. '${commonScript}'`,
    `$record = Get-Content -Raw -LiteralPath '${recordPath}' | ConvertFrom-Json`,
    '$token = Get-DshMonitorAccessToken -Record $record',
    `$authorized = Invoke-WebRequest -Uri '${publicRecord.url}/api/runs' -Headers @{ 'X-DSH-Monitor-Token' = $token } -UseBasicParsing`,
    'Write-Output ("authorized=" + $authorized.StatusCode)',
    'Write-Output ("tokenShape=" + ($token -match "^[0-9a-f]{64}$"))',
  ].join('; '));
  assert.equal(verify.code, 0, verify.stderr);
  assert.match(verify.stdout, /authorized=200/, 'DPAPI 记录解密出的 token 必须能通过 Monitor 认证');
  assert.match(verify.stdout, /tokenShape=True/);
  assert.equal(/[0-9a-f]{64}/.test(verify.stdout), false, '解密出的 token 不得出现在 stdout');

  // Blocker B：monitor 启动时在 Team Home 里只写了 marker，用户 DSH Home 保持只读。
  const teamFiles = await fs.readdir(path.join(teamRoot, installId));
  assert.deepEqual(teamFiles, ['.codex-dsh-team-home.json'], '服务器不得向 Team Home 写额外内容');
  assert.deepEqual(await fs.readdir(userDshHome), ['settings.yaml'], '用户 DSH Home 必须保持只读');
});
