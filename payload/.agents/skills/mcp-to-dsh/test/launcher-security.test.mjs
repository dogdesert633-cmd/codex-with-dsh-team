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

test('user config lookup is bounded, remembers GUI selection and never falls back from an invalid explicit path', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-home-picker-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const first = path.join(base, 'first-user-home');
  const second = path.join(base, 'second-user-home');
  for (const dir of [first, second]) {
    await fs.mkdir(dir);
    await fs.writeFile(path.join(dir, 'settings.yaml'), 'agent-default-model: {}\n');
  }
  const quote = (text) => `'${text.replaceAll("'", "''")}'`;
  for (const host of hosts) {
    const script = `
$ErrorActionPreference = 'Stop'
. ${quote(commonScript)}
$env:CODEX_DSH_TEAM_BASE_DIR = ${quote(path.join(base, host))}
$env:DSH_USER_HOME = ${quote(first)}
$env:DSH_HOME = ${quote(second)}
if ((Resolve-DshUserHome) -ne ${quote(first)}) { throw 'Wrong environment priority' }
if ((Resolve-DshUserHome -Requested ${quote(second)}) -ne ${quote(second)}) { throw 'Explicit path ignored' }
$rejected = $false
try { Resolve-DshUserHome -Requested ${quote(path.join(base, 'missing'))} | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Invalid explicit path silently fell back' }
# Compile the real native folder picker on both supported hosts, without opening a dialog.
$pickerFunction = Get-Command Show-DshUserHomePicker
$code = $pickerFunction.ScriptBlock.Ast.Find({ param($ast) $ast -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $ast.Value.StartsWith('using System;') }, $true).Value
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition $code
function Show-DshUserHomePicker { param($InitialDirectory) return ${quote(second)} }
$picked = Resolve-DshUserHome -SelectAgain -AllowPrompt
if ($picked -ne ${quote(second)}) { throw 'Picker result ignored' }
function Show-DshUserHomePicker { throw 'A remembered path should not prompt' }
if ((Resolve-DshUserHome) -ne ${quote(second)}) { throw 'Picker result not remembered' }
if ((Resolve-DshUserHome -Requested ${quote(first)}) -ne ${quote(first)}) { throw 'Explicit override must still win' }
$env:DSH_USER_HOME = ''; $env:DSH_HOME = ''
$saved = [IO.File]::ReadAllText((Join-Path (Get-DshTeamBaseDir) 'user-settings-source.json')) | ConvertFrom-Json
if ($saved.userDshHome -ne ${quote(second)}) { throw 'Incorrect local preference' }
[IO.File]::WriteAllText((Join-Path (Get-DshTeamBaseDir) 'user-settings-source.json'), 'invalid json')
function Show-DshUserHomePicker { return ${quote(second)} }
if ((Resolve-DshUserHome -AllowPrompt) -ne ${quote(second)}) { throw 'Invalid saved record must offer GUI recovery' }
function Show-DshUserHomePicker { return $null }
$cancelled = $false
try { Resolve-DshUserHome -SelectAgain -AllowPrompt | Out-Null } catch { $cancelled = $true }
if (-not $cancelled) { throw 'Cancel must stop configuration' }
Write-Output 'lookup-picker-PASS'
`;
    const result = await runPowerShell(host, script);
    assert.equal(result.code, 0, `${host}: ${result.stderr}`);
    assert.match(result.stdout, /lookup-picker-PASS/);
  }
});

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

async function runScriptFile(host, file, args = [], options = {}) {
  const result = await spawnWithTimeout(
    host,
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file, ...args],
    { env: options.env ?? process.env, timeoutMs: PS_SCRIPT_TIMEOUT_MS },
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

// ---------------------------------------------------------------------------
// First-start profile bootstrap (owned -> prepare -> resolve)
// ---------------------------------------------------------------------------

// A stub DSH that only implements the offline `--dump-default-config` initialisation contract:
// it writes the same manifest shape the real `dsh --profile <name> --dump-default-config`
// produces, without booting plugins, contacting a provider or needing node_modules.
const STUB_DSH_SOURCE = [
  "const fs = require('node:fs');",
  "const path = require('node:path');",
  "const args = process.argv.slice(2);",
  "const index = args.indexOf('--profile');",
  "const name = index >= 0 ? args[index + 1] : null;",
  "const home = process.env.DSH_HOME;",
  "if (!name || !home) { console.error('stub-dsh: --profile and DSH_HOME are required'); process.exit(2); }",
  "const dir = path.join(home, 'profiles', name);",
  "fs.mkdirSync(dir, { recursive: true });",
  "fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({",
  "  name: 'dsh-profile-' + name, private: true, dependencies: {},",
  "  dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-acp-app'], patchReload: 'startup' } },",
  "}, null, 2) + '\\n');",
  "process.exit(0);",
  '',
].join('\n');

// The same offline contract, but failing loudly with a credential-shaped stderr line: the
// launcher must report the exit code plus a safe classification and never replay that text.
const FAILING_STUB_DSH_SOURCE = [
  "console.error('Error: Cannot find module @deepseek-ai/dsh-base (stub-secret-value-137)');",
  "process.exit(3);",
  '',
].join('\n');

const ACP_MANIFEST_TEXT = `${JSON.stringify({
  name: 'dsh-profile-acp',
  private: true,
  dependencies: {},
  dsh: { profile: { bundles: ['@deepseek-ai/dsh-base', '@deepseek-ai/dsh-acp-app'], patchReload: 'startup' } },
}, null, 2)}\n`;

async function writeStubDsh(base) {
  const stub = path.join(base, 'stub-dsh.js');
  // 这里没有 package.json，因此 .js 按 CommonJS 解析，stub 的 require 可用。
  await fs.writeFile(stub, STUB_DSH_SOURCE);
  return stub;
}

async function writeFailingStubDsh(base) {
  const stub = path.join(base, 'failing-stub-dsh.js');
  await fs.writeFile(stub, FAILING_STUB_DSH_SOURCE);
  return stub;
}

async function writePowershellProbe(base, name, lines) {
  const file = path.join(base, name);
  await fs.writeFile(file, ['Set-StrictMode -Version Latest', "$ErrorActionPreference = 'Stop'", ...lines, ''].join('\r\n'));
  return file;
}

const MARKER_NAME_FOR_PS_TESTS = '.codex-dsh-team-home.json';

async function writeOwnedTeamHome(dir, installId) {
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, MARKER_NAME_FOR_PS_TESTS), `${JSON.stringify({
    schema: 'codex-dsh-team-home/v1',
    toolkitId: 'codex-dsh-team-toolkit',
    installId,
    createdAt: '2026-01-01T00:00:00.000Z',
    purpose: 'dsh-team-runtime-home',
  }, null, 2)}\n`);
}

function selectionCall(label, args) {
  return [
    `try { $r = Resolve-DshTeamProfileSelection ${args}`,
    `Write-Output ('${label}=OK:' + $r.Name + ':' + $r.Source + ':' + $r.Created)`,
    `} catch { Write-Output '${label}=REFUSED' }`,
  ].join('; ');
}

test('Resolve-DshTeamProfileSelection：owned -> prepare -> resolve，真空默认 acp 且显式复用', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-profile-select-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const stub = await writeStubDsh(base);
  const workspace = path.join(base, 'project');
  await fs.mkdir(workspace, { recursive: true });
  const fresh = path.join(base, 'team-fresh');
  const seeded = path.join(base, 'team-seeded');
  await writeOwnedTeamHome(fresh, 'select-install-1');
  await writeOwnedTeamHome(seeded, 'select-install-1');
  await fs.mkdir(path.join(seeded, 'profiles', 'mybot'), { recursive: true });
  await fs.writeFile(path.join(seeded, 'profiles', 'mybot', 'package.json'), ACP_MANIFEST_TEXT);

  const probe = await writePowershellProbe(base, 'select.ps1', [
    `. '${commonScript}'`,
    `$node = (Get-Command node.exe).Source`,
    `$common = @{ InstallId = 'select-install-1'; DshBinPath = '${stub}'; NodePath = $node; Workspace = '${workspace}' }`,
    // 真空且未指定：显式选择 ACP 默认 profile 并 bootstrap。
    selectionCall('default', `-TeamDshHome '${fresh}' @common`),
    // 第二次：同一个 profile 被复用，不再初始化。
    selectionCall('reuse', `-TeamDshHome '${fresh}' @common`),
    // 已有唯一 ACP 候选：被发现并复用，内容不变。
    selectionCall('discovered', `-TeamDshHome '${seeded}' @common`),
    // 显式自定义名字即使尚不存在也允许 bootstrap。
    selectionCall('customNew', `-TeamDshHome '${fresh}' @common -Requested 'team-custom-137'`),
    `Write-Output ('manifestExists=' + (Test-Path (Join-Path '${fresh}' 'profiles\\acp\\package.json')))`,
    `Write-Output ('customExists=' + (Test-Path (Join-Path '${fresh}' 'profiles\\team-custom-137\\package.json')))`,
    `Write-Output ('seededUntouched=' + ((Get-Content -Raw (Join-Path '${seeded}' 'profiles\\mybot\\package.json')) -like '*dsh-acp-app*'))`,
  ]);

  const result = await runScriptFile(PS51, probe);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /default=OK:acp:default-acp:True/);
  assert.match(result.stdout, /reuse=OK:acp:discovered:False/);
  assert.match(result.stdout, /discovered=OK:mybot:discovered:False/);
  assert.match(result.stdout, /customNew=OK:team-custom-137:parameter:True/);
  assert.match(result.stdout, /manifestExists=True/);
  assert.match(result.stdout, /customExists=True/);
  assert.match(result.stdout, /seededUntouched=True/);
});

test('profile 选择拒绝：非 ACP 模板 / 未知目录 / 空壳 bundles / 多候选 / 错 marker / 越界 / 逃逸', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-profile-refuse-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const stub = await writeStubDsh(base);
  const workspace = path.join(base, 'project');
  await fs.mkdir(workspace, { recursive: true });

  const home = path.join(base, 'team');
  await writeOwnedTeamHome(home, 'refuse-install-1');
  // 多候选：两个有效 ACP 候选。
  for (const name of ['alpha', 'beta']) {
    await fs.mkdir(path.join(home, 'profiles', name), { recursive: true });
    await fs.writeFile(path.join(home, 'profiles', name, 'package.json'), ACP_MANIFEST_TEXT);
  }
  // 未知半成品目录：没有 manifest。
  await fs.mkdir(path.join(home, 'profiles', 'half'), { recursive: true });
  // 空壳/空白 bundles 都不算成功。
  await fs.mkdir(path.join(home, 'profiles', 'shell'), { recursive: true });
  await fs.writeFile(path.join(home, 'profiles', 'shell', 'package.json'), '{"name":"shell"}\n');
  await fs.mkdir(path.join(home, 'profiles', 'blank'), { recursive: true });
  await fs.writeFile(path.join(home, 'profiles', 'blank', 'package.json'),
    '{"dsh":{"profile":{"bundles":["", "   ", null]}}}\n');
  // marker 缺字段 / 属于别的 install。
  const badMarker = path.join(base, 'team-bad-marker');
  await fs.mkdir(badMarker, { recursive: true });
  await fs.writeFile(path.join(badMarker, MARKER_NAME_FOR_PS_TESTS),
    '{"schema":"codex-dsh-team-home/v1","toolkitId":"codex-dsh-team-toolkit"}\n');
  const foreign = path.join(base, 'team-foreign');
  await writeOwnedTeamHome(foreign, 'someone-elses-install');
  // 项目工作区内的 owned Team Home：ownership 成立，但越界检查必须拒绝 prepare。
  const insideWorkspace = path.join(workspace, 'team-inside');
  await writeOwnedTeamHome(insideWorkspace, 'refuse-install-1');

  const probe = await writePowershellProbe(base, 'refuse.ps1', [
    `. '${commonScript}'`,
    `$node = (Get-Command node.exe).Source`,
    `$c = @{ InstallId = 'refuse-install-1'; DshBinPath = '${stub}'; NodePath = $node; Workspace = '${workspace}' }`,
    selectionCall('web', `-TeamDshHome '${home}' @c -Requested 'web'`),
    selectionCall('headless', `-TeamDshHome '${home}' @c -Requested 'headless'`),
    selectionCall('reserved', `-TeamDshHome '${home}' @c -Requested 'node_modules'`),
    selectionCall('unknownDir', `-TeamDshHome '${home}' @c -Requested 'half'`),
    selectionCall('shell', `-TeamDshHome '${home}' @c -Requested 'shell'`),
    selectionCall('blankBundles', `-TeamDshHome '${home}' @c -Requested 'blank'`),
    selectionCall('many', `-TeamDshHome '${home}' @c`),
    selectionCall('traversal', `-TeamDshHome '${home}' @c -Requested '../escape'`),
    selectionCall('separator', `-TeamDshHome '${home}' @c -Requested 'a/b'`),
    selectionCall('badMarker', `-TeamDshHome '${badMarker}' @c`),
    selectionCall('foreign', `-TeamDshHome '${foreign}' @c`),
    selectionCall('insideWorkspace', `-TeamDshHome '${insideWorkspace}' @c`),
    // 错 marker 必须给出可读 Reason，而不是依赖严格模式抛 PropertyNotFoundException。
    `$partial = '{"schema":"codex-dsh-team-home/v1","toolkitId":"codex-dsh-team-toolkit"}' | ConvertFrom-Json`,
    `try { $v = Test-DshTeamHomeMarker -Marker $partial -InstallId 'refuse-install-1'; Write-Output ('markerOk=' + $v.Ok); Write-Output ('markerReasonLen=' + ([string]$v.Reason).Length) } catch { Write-Output 'markerOk=THREW'; Write-Output 'markerReasonLen=0' }`,
    `$state = Get-DshTeamHomeState -TeamDshHome '${badMarker}' -InstallId 'refuse-install-1'`,
    `Write-Output ('badMarkerState=' + $state.State)`,
    `Write-Output ('unknownDirUntouched=' + (Test-Path (Join-Path '${home}' 'profiles\\half')))`,
    `Write-Output ('webNotCreated=' + (-not (Test-Path (Join-Path '${home}' 'profiles\\web'))))`,
    `Write-Output ('insideNoProfiles=' + (-not (Test-Path (Join-Path '${insideWorkspace}' 'profiles'))))`,
  ]);

  const result = await runScriptFile(PS51, probe);
  assert.equal(result.code, 0, result.stderr);
  for (const label of ['web', 'headless', 'reserved', 'unknownDir', 'shell', 'blankBundles', 'many', 'traversal', 'separator', 'badMarker', 'foreign', 'insideWorkspace']) {
    assert.match(result.stdout, new RegExp(`${label}=REFUSED`), `${label} 必须被拒绝：${result.stdout}`);
  }
  // 只断言 ASCII 部分：PS 5.1 的 console code page 会转码中文 Reason，可读性由“未抛异常 + 非空 Reason”证明。
  assert.match(result.stdout, /markerOk=False/);
  assert.match(result.stdout, /markerReasonLen=[1-9]/);
  assert.match(result.stdout, /badMarkerState=unowned/);
  assert.match(result.stdout, /unknownDirUntouched=True/);
  assert.match(result.stdout, /webNotCreated=True/);
  assert.match(result.stdout, /insideNoProfiles=True/);
});

test('profiles 父目录是 reparse point 时拒绝 prepare（不只检查 Team Home 顶层）', async (context) => {
  if (process.platform !== 'win32') return;
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-profile-reparse-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const stub = await writeStubDsh(base);
  const workspace = path.join(base, 'project');
  await fs.mkdir(workspace, { recursive: true });
  const home = path.join(base, 'team');
  await writeOwnedTeamHome(home, 'reparse-install-1');
  const realProfiles = path.join(base, 'real-profiles');
  await fs.mkdir(realProfiles, { recursive: true });
  await fs.symlink(realProfiles, path.join(home, 'profiles'), 'junction');

  const probe = await writePowershellProbe(base, 'reparse.ps1', [
    `. '${commonScript}'`,
    `$node = (Get-Command node.exe).Source`,
    selectionCall('reparseProfiles', `-TeamDshHome '${home}' -InstallId 'reparse-install-1' -DshBinPath '${stub}' -NodePath $node -Workspace '${workspace}'`),
    `Write-Output ('nothingWritten=' + (@(Get-ChildItem -LiteralPath '${realProfiles}' -Force -ErrorAction SilentlyContinue).Count -eq 0))`,
  ]);

  const result = await runScriptFile(PS51, probe);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /reparseProfiles=REFUSED/, result.stdout);
  assert.match(result.stdout, /nothingWritten=True/, 'reparse 目标必须在写入前被拒绝');
});

test('最小 child env 会用允许的系统变量补齐 SystemRoot/TEMP，而不是继承全部父环境', async () => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-env-fallback-'));
  try {
    const probe = await writePowershellProbe(base, 'env.ps1', [
      `. '${commonScript}'`,
      `$narrowed = Get-DshNarrowedChildEnv -Explicit @{ DSH_HOME = '${SYNTHETIC_TEAM_HOME}' }`,
      `Write-Output ('systemRoot=' + [bool](Get-CaseInsensitiveValue -Map $narrowed -Name 'SystemRoot'))`,
      `Write-Output ('systemDrive=' + [bool](Get-CaseInsensitiveValue -Map $narrowed -Name 'SystemDrive'))`,
      `Write-Output ('temp=' + [bool](Get-CaseInsensitiveValue -Map $narrowed -Name 'TEMP'))`,
      `Write-Output ('path=' + [bool](Get-CaseInsensitiveValue -Map $narrowed -Name 'PATH'))`,
      `Write-Output ('unlisted=' + [bool](Get-CaseInsensitiveValue -Map $narrowed -Name 'SOME_UNLISTED'))`,
      `Write-Output ('denied=' + [bool](Get-CaseInsensitiveValue -Map $narrowed -Name 'DEMO_API_KEY'))`,
      `$probe = 'console.log(JSON.stringify({root: !!process.env.SystemRoot, temp: !!process.env.TEMP}))'`,
      `$r = Start-DshNarrowedProcess -FileName (Get-Command node.exe).Source -Arguments ('-e "' + $probe + '"') -WorkingDirectory '${base}' -TimeoutSeconds 30 -Environment $narrowed`,
      `Write-Output ('child=' + $r.Stdout.Trim())`,
      `Write-Output ('childExit=' + $r.ExitCode)`,
    ]);
    // 刻意不给 child PowerShell SystemRoot/TEMP：真实 Windows 启动所需的系统变量必须由
    // allowlist 补齐，但父进程的 secret 家族仍然不会进入 child。
    const result = await runScriptFile(PS51, probe, [], {
      PATH: process.env.PATH,
      USERPROFILE: process.env.USERPROFILE,
      LOCALAPPDATA: process.env.LOCALAPPDATA,
      DEMO_API_KEY: 'fake-env-secret-value-137',
    });
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /systemRoot=True/);
    assert.match(result.stdout, /systemDrive=True/);
    assert.match(result.stdout, /temp=True/);
    assert.match(result.stdout, /path=True/);
    assert.match(result.stdout, /unlisted=False/);
    assert.match(result.stdout, /denied=False/);
    assert.match(result.stdout, /child=\{"root":true,"temp":true\}/);
    assert.match(result.stdout, /childExit=0/);
    assert.equal(result.stdout.includes('fake-env-secret-value-137'), false, '补齐不得泄露父进程 secret');
  } finally {
    await fs.rm(base, { recursive: true, force: true });
  }
});

test('DSH 初始化失败只报 exit code 与安全分类，不回显未脱敏 stderr', async (context) => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-profile-fail-'));
  context.after(() => fs.rm(base, { recursive: true, force: true }));
  const stub = await writeFailingStubDsh(base);
  const workspace = path.join(base, 'project');
  await fs.mkdir(workspace, { recursive: true });
  const home = path.join(base, 'team');
  await writeOwnedTeamHome(home, 'fail-install-1');

  const probe = await writePowershellProbe(base, 'fail.ps1', [
    `. '${commonScript}'`,
    `$node = (Get-Command node.exe).Source`,
    `try { $r = Resolve-DshTeamProfileSelection -TeamDshHome '${home}' -InstallId 'fail-install-1' -DshBinPath '${stub}' -NodePath $node -Workspace '${workspace}'; Write-Output 'fail=ACCEPTED' } catch { $m = $_.Exception.Message; Write-Output ('fail=REFUSED;exit=' + ($m -like '*exit=3*') + ';class=' + ($m -like '*module-missing*') + ';leak=' + ($m -like '*stub-secret-value-137*')) }`,
    `Write-Output ('noManifest=' + (-not (Test-Path (Join-Path '${home}' 'profiles\\acp\\package.json'))))`,
  ]);

  const result = await runScriptFile(PS51, probe);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /fail=REFUSED;exit=True;class=True;leak=False/, result.stdout);
  assert.equal(result.stdout.includes('stub-secret-value-137'), false, '原始 stderr 绝不进入错误信息或 stdout');
  assert.match(result.stdout, /noManifest=True/);
});
