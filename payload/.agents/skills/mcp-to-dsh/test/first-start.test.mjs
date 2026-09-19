// First-start regression suite for the Team runtime profile bootstrap.
//
// Layer 1 — real DSH bootstrap:
//   the *locked* DSH runtime performs the offline profile bootstrap
//   (`--profile <name> [--from-default-profile acp] --dump-default-config`) for a brand-new owned
//   Team Home, and the bootstrap is idempotent.
//
// Layer 2 — real launcher:
//   `start_dsh_team.ps1 -SkipDshCheck -NoBrowser` runs end to end in an isolated temporary Git
//   project for two scenarios:
//     (a) default `acp` selection, including the offline `--profile headless --dump-default-config`
//         step that a user's *first non-skip self check* actually performs, which must not hijack
//         the default ACP selection nor break Monitor reuse;
//     (b) an explicit custom `-TeamProfile`.
//   Both scenarios assert a healthy Monitor, the persisted record's `dsh_profile`, the real
//   profile bundles, and a second launch that *reuses* the same Monitor pid/URL/profile.
//
// Isolation: every spawned process receives a synthetic USERPROFILE / HOME / LOCALAPPDATA /
// APPDATA / TEMP plus `CODEX_DSH_TEAM_BASE_DIR` under the temporary base, so no install identity,
// cache or Toolkit base directory is written into the real user profile. Only PATH and the
// Windows system variables a child needs in order to start are inherited from this process.
//
// No provider is contacted, no credential is real, `node_modules` is only ever linked read-only,
// and cleanup unlinks (never follows, never deletes) that link. Scripts, source and fixtures are
// all temporary.
//
// `CODEX_DSH_TEAM_TEST_NODE_MODULES` / `CODEX_DSH_TEAM_TEST_DSH_BIN` are explicit external inputs
// (same contract as the maintainer baseline input); without them the suite skips with a diagnostic
// instead of silently passing.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnWithTimeout } from './support/spawn-guard.mjs';

const skillRoot = path.resolve(import.meta.dirname, '..');
const scriptsDir = path.join(skillRoot, 'scripts');
const commonScript = path.join(scriptsDir, 'DshTeamCommon.ps1');

const PS51 = 'powershell.exe';
const PWSH = 'pwsh';
const hosts = process.platform === 'win32' ? [PS51, PWSH] : [PWSH];
const HOST_LABELS = new Map([[PS51, 'ps51'], [PWSH, 'pwsh']]);

const BOOTSTRAP_TIMEOUT_MS = 240000;
const LAUNCH_TIMEOUT_MS = 300000;
const MARKER_NAME = '.codex-dsh-team-home.json';
const FAKE_CREDENTIAL = 'local-only-fake-credential-137';
const LAUNCH_CUSTOM_PROFILE = 'acp-team-140';

// 与 src/security.mjs 的 CHILD_ENV_ALLOWLIST 同源：子进程只继承“能启动”所需的系统变量，
// 其余（尤其安装身份/缓存位置）一律重定向到临时 base。
const CHILD_ENV_KEEP = [
  'PATH', 'PATHEXT', 'SYSTEMROOT', 'SYSTEMDRIVE', 'WINDIR', 'COMSPEC',
  'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'OS', 'LANG', 'LC_ALL', 'TZ',
  'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)',
];

// Layer 2 场景矩阵：默认 acp + 显式自定义 profile。workspace 路径与端口都由矩阵推导，
// 这样清理钩子可以在没有任何运行时状态的情况下重新算出每个 workspace。
const SCENARIOS = [
  { key: 'default', teamProfile: null, profile: 'acp', injectHeadless: true },
  { key: 'custom', teamProfile: LAUNCH_CUSTOM_PROFILE, profile: LAUNCH_CUSTOM_PROFILE, injectHeadless: false },
];

const exists = (target) => fs.stat(target).then(() => true, () => false);

async function tempBase(label) {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), `dsh-first-start-${label}-`));
  return await fs.realpath(base);
}

function runTag() {
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`;
}

function hostLabel(host) {
  return HOST_LABELS.get(host) ?? host;
}

function scenarioWorkspace(base, host, scenario) {
  return path.join(base, `project-${hostLabel(host)}-${scenario.key}`);
}

function scenarioInstallId(host, scenario, tag) {
  return `launch-install-${hostLabel(host)}-${scenario.key}-${tag}`;
}

// 隔离环境：把可能承载“安装身份 / 缓存 / Toolkit base dir”的位置全部指向临时 base，
// 同时保留 PATH 与 Windows 启动必需的系统变量。绝不整体继承父进程环境。
async function buildIsolatedEnv(base) {
  const home = path.join(base, 'home');
  const temp = path.join(base, 'temp');
  await fs.mkdir(path.join(home, 'AppData', 'Local'), { recursive: true });
  await fs.mkdir(path.join(home, 'AppData', 'Roaming'), { recursive: true });
  await fs.mkdir(temp, { recursive: true });

  const env = {};
  for (const name of CHILD_ENV_KEEP) {
    const value = process.env[name];
    if (value && String(value).trim()) env[name] = String(value);
  }
  const root = path.parse(home).root;
  return {
    ...env,
    USERPROFILE: home,
    HOME: home,
    HOMEDRIVE: root.replace(/[\\/]+$/, ''),
    HOMEPATH: home.slice(Math.max(0, root.length - 1)),
    LOCALAPPDATA: path.join(home, 'AppData', 'Local'),
    APPDATA: path.join(home, 'AppData', 'Roaming'),
    TEMP: temp,
    TMP: temp,
    // 即使某条代码路径忽略显式 -InstallId，安装身份也只会写进临时 base。
    CODEX_DSH_TEAM_BASE_DIR: path.join(base, 'team-base'),
  };
}

async function writeOwnedTeamHome(dir, installId) {
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(path.join(dir, MARKER_NAME), `${JSON.stringify({
    schema: 'codex-dsh-team-home/v1',
    toolkitId: 'codex-dsh-team-toolkit',
    installId,
    createdAt: '2026-09-19T00:00:00.000Z',
    purpose: 'dsh-team-runtime-home',
  }, null, 2)}\n`);
  return dir;
}

// A fake user DSH Home: credentials are synthetic, the provider is DSH's built-in one, and the
// `-SkipDshCheck` launch never performs a provider round trip.
async function writeFakeUserDshHome(dir) {
  await fs.mkdir(path.join(dir, 'profiles', 'acp'), { recursive: true });
  await fs.writeFile(path.join(dir, 'settings.yaml'), [
    'agent-default-model:',
    '  provider: deepseek-official',
    '  model: deepseek-v4-flash',
    '',
  ].join('\n'));
  await fs.writeFile(path.join(dir, '.credentials.yaml'), `version: 1\nFAKE_API_KEY: ${FAKE_CREDENTIAL}\n`);
  await fs.writeFile(path.join(dir, 'profiles', 'acp', 'package.json'), '{"name":"user-acp"}\n');
  return dir;
}

async function initGitProject(dir) {
  await fs.mkdir(dir, { recursive: true });
  const git = await spawnWithTimeout('git.exe', ['init', '-q'], { cwd: dir, timeoutMs: 60000 }).catch(() => null);
  if (!git || git.timedOut || git.code !== 0) {
    // The launcher only requires a `.git` directory; keep the fixture usable without Git.
    await fs.mkdir(path.join(dir, '.git'), { recursive: true });
  }
  return dir;
}

// The locked DSH entry point. `CODEX_DSH_TEAM_TEST_DSH_BIN` is an explicit external input; the
// skill's own dependency root (or the explicitly provided dependency root) is the only fallback.
// A machine-level DSH installation is deliberately NOT used: the toolkit is pinned to the DSH
// version it ships, and another version may not implement the shipped-template bootstrap.
async function resolveDshBin() {
  const candidates = [];
  const explicit = (process.env.CODEX_DSH_TEAM_TEST_DSH_BIN ?? '').trim();
  if (explicit) candidates.push(explicit);
  const dependencyRoot = (process.env.CODEX_DSH_TEAM_TEST_NODE_MODULES ?? '').trim();
  if (dependencyRoot) candidates.push(path.join(dependencyRoot, '@deepseek-ai', 'dsh', 'lib', 'bin.js'));
  candidates.push(path.join(skillRoot, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'));
  for (const candidate of candidates) {
    if (await exists(candidate)) return candidate;
  }
  return null;
}

// An installed dependency root must contain everything the Monitor bridge imports.
async function resolveDependencyRoot() {
  const candidates = [];
  const explicit = (process.env.CODEX_DSH_TEAM_TEST_NODE_MODULES ?? '').trim();
  if (explicit) candidates.push(explicit);
  candidates.push(path.join(skillRoot, 'node_modules'));
  const required = [
    path.join('@deepseek-ai', 'dsh', 'lib', 'bin.js'),
    'yaml',
    'zod',
    path.join('@agentclientprotocol', 'sdk'),
  ];
  for (const candidate of candidates) {
    let complete = true;
    for (const entry of required) {
      if (!await exists(path.join(candidate, entry))) { complete = false; break; }
    }
    if (complete) return candidate;
  }
  return null;
}

// Build a throw-away "installed skill root": the scripts/src/public under test are real copies and
// node_modules is a junction to the dependency root. Node resolves bare specifiers from the
// importing file's real path, so src/ must be a real copy rather than a link.
async function buildInstalledSkillRoot(base, dependencyRoot) {
  const installed = path.join(base, 'installed-skill');
  for (const directory of ['scripts', 'src', 'public']) {
    await fs.cp(path.join(skillRoot, directory), path.join(installed, directory), { recursive: true });
  }
  await fs.cp(path.join(skillRoot, 'package.json'), path.join(installed, 'package.json'));
  await fs.symlink(dependencyRoot, path.join(installed, 'node_modules'), 'junction');
  return installed;
}

async function killProcessTree(pid) {
  if (!pid) return;
  await spawnWithTimeout('taskkill.exe', ['/PID', String(pid), '/T', '/F'], { timeoutMs: 30000 }).catch(() => null);
}

async function readMonitorRecord(workspace) {
  const recordPath = path.join(workspace, 'artifacts', 'dsh-monitor', 'server.json');
  if (!await exists(recordPath)) return null;
  const text = await fs.readFile(recordPath, 'utf8');
  // 记录含 DPAPI 密文；只解析，绝不把它写进任何断言消息或输出。
  return { path: recordPath, record: JSON.parse(text) };
}

// A launcher that starts a detached background Monitor must be spawned with FILE descriptors,
// not pipes: the detached grandchild would otherwise keep our pipe's write end open and the
// 'close' event would never fire. The deadline still comes from the shared spawn guard.
async function runLauncher(host, args, outPath, errPath, env) {
  const outHandle = await fs.open(outPath, 'w');
  const errHandle = await fs.open(errPath, 'w');
  try {
    const result = await spawnWithTimeout(host, args, {
      env,
      stdio: ['ignore', outHandle.fd, errHandle.fd],
      timeoutMs: LAUNCH_TIMEOUT_MS,
    });
    const [stdout, stderr] = await Promise.all([
      fs.readFile(outPath, 'utf8').catch(() => ''),
      fs.readFile(errPath, 'utf8').catch(() => ''),
    ]);
    return { code: result.code, stdout, stderr, timedOut: result.timedOut, forced: result.forced };
  } finally {
    await outHandle.close().catch(() => {});
    await errHandle.close().catch(() => {});
  }
}

// Foreground helper (no detached grandchild), used for the offline DSH probes.
async function runPowershellScript(host, scriptPath, env, timeoutMs) {
  const result = await spawnWithTimeout(
    host,
    ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', scriptPath],
    { env, timeoutMs },
  );
  return { code: result.code, stdout: result.stdout, stderr: result.stderr, timedOut: result.timedOut };
}

async function monitorHealth(url) {
  const response = await fetch(`${url}/api/health`);
  assert.equal(response.status, 200, `health 必须返回 200：${url}`);
  return await response.json();
}

async function readBundles(manifestPath) {
  const manifest = JSON.parse(await fs.readFile(manifestPath, 'utf8'));
  const bundles = manifest?.dsh?.profile?.bundles;
  return Array.isArray(bundles) ? bundles.filter((entry) => typeof entry === 'string' && entry.trim()) : [];
}

// 只在确认目录确实由本测试创建时删除：必须在 os.tmpdir() 之下且带本套件的前缀。
// 依赖 junction 只解除链接本身，绝不跟随删除外部只读依赖树。
async function removeOwnedTempBase(base, label) {
  const resolved = await fs.realpath(base).catch(() => null);
  if (!resolved) return;
  const tempRoot = await fs.realpath(os.tmpdir());
  const isInsideTemp = resolved.toLowerCase().startsWith((tempRoot + path.sep).toLowerCase());
  const hasOwnPrefix = path.basename(resolved).toLowerCase().startsWith(`dsh-first-start-${label}-`.toLowerCase());
  if (!isInsideTemp || !hasOwnPrefix) {
    throw new Error(`拒绝删除非本测试创建的目录：${resolved}`);
  }
  const junction = path.join(resolved, 'installed-skill', 'node_modules');
  const junctionStat = await fs.lstat(junction).catch(() => null);
  if (junctionStat?.isSymbolicLink()) {
    try { await fs.rm(junction, { force: true }); }
    catch { await fs.rmdir(junction).catch(() => {}); }
  }
  await fs.rm(resolved, { recursive: true, force: true });
}

// `node_modules` 是外部只读复用：清理前后都必须完好。
async function assertDependencyRootIntact(dependencyRoot) {
  assert.equal(await exists(path.join(dependencyRoot, '@deepseek-ai', 'dsh', 'lib', 'bin.js')), true,
    '清理不得跟随依赖 junction 删除外部依赖树');
  assert.equal(await exists(path.join(dependencyRoot, 'yaml')), true);
}

// 用户第一次“非 -SkipDshCheck”自检会让 DSH 在同一个 Team Home 里生成 headless profile。
// 这里用官方离线入口复现同一步（--dump-default-config 只组合 patch，不启动插件、不联系
// provider），并通过生产同款 Get-DshNarrowedChildEnv + Start-DshNarrowedProcess 执行。
async function runOfflineHeadlessBootstrap(host, dshBin, teamHome, base, label, env) {
  const probe = path.join(base, `headless-probe-${label}.ps1`);
  await fs.writeFile(probe, [
    'Set-StrictMode -Version Latest',
    "$ErrorActionPreference = 'Stop'",
    `. '${commonScript}'`,
    `$dshBin = '${dshBin}'`,
    `$node = (Get-Command node.exe).Source`,
    `$narrowed = Get-DshNarrowedChildEnv -Explicit @{ DSH_HOME = '${teamHome}' }`,
    `$r = Start-DshNarrowedProcess -FileName $node -Arguments ('"' + $dshBin + '" --profile headless --dump-default-config') -WorkingDirectory '${teamHome}' -TimeoutSeconds 180 -Environment $narrowed`,
    `Write-Output ('headlessExit=' + $r.ExitCode + ';timedOut=' + $r.TimedOut)`,
  ].join('\r\n'));
  return await runPowershellScript(host, probe, env, BOOTSTRAP_TIMEOUT_MS);
}

test('真实 DSH 为新 owned Team Home 初始化 ACP profile，且重复调用幂等', { timeout: 300000 }, async (context) => {
  const dshBin = await resolveDshBin();
  if (!dshBin) {
    context.skip('未找到已锁定的 DSH 运行时：设置 CODEX_DSH_TEAM_TEST_DSH_BIN，或安装 node_modules');
    return;
  }
  const base = await tempBase('bootstrap');
  const env = await buildIsolatedEnv(base);
  context.after(() => removeOwnedTempBase(base, 'bootstrap'));
  const workspace = path.join(base, 'project');
  await fs.mkdir(workspace, { recursive: true });
  const defaultHome = await writeOwnedTeamHome(path.join(base, 'team-default'), 'first-start-install-1');
  const customHome = await writeOwnedTeamHome(path.join(base, 'team-custom'), 'first-start-install-1');

  const probe = path.join(base, 'bootstrap.ps1');
  await fs.writeFile(probe, [
    'Set-StrictMode -Version Latest',
    "$ErrorActionPreference = 'Stop'",
    `[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)`,
    `. '${commonScript}'`,
    `$node = (Get-Command node.exe).Source`,
    `$common = @{ InstallId = 'first-start-install-1'; DshBinPath = '${dshBin}'; NodePath = $node; Workspace = '${workspace}'; TimeoutSeconds = 180 }`,
    `$a = Resolve-DshTeamProfileSelection -TeamDshHome '${defaultHome}' @common`,
    `Write-Output ('default=' + $a.Name + ';source=' + $a.Source + ';created=' + $a.Created + ';bundles=' + (@($a.Bundles) -join '+' ))`,
    `$b = Resolve-DshTeamProfileSelection -TeamDshHome '${defaultHome}' @common`,
    `Write-Output ('again=' + $b.Name + ';source=' + $b.Source + ';created=' + $b.Created)`,
    `$c = Resolve-DshTeamProfileSelection -TeamDshHome '${customHome}' @common -Requested 'acp-firststart-137'`,
    `Write-Output ('custom=' + $c.Name + ';source=' + $c.Source + ';created=' + $c.Created)`,
    `$customManifest = Join-Path '${customHome}' 'profiles\\acp-firststart-137\\package.json'`,
    `Write-Output ('customManifest=' + (Test-Path $customManifest))`,
    `Write-Output ('customBundles=' + (((Get-Content -Raw $customManifest | ConvertFrom-Json).dsh.profile.bundles) -join '+'))`,
    `Write-Output ('defaultFiles=' + (@(Get-ChildItem -LiteralPath (Join-Path '${defaultHome}' 'profiles\\acp') -Force | ForEach-Object { $_.Name } | Sort-Object) -join ','))`,
  ].join('\r\n'));

  const result = await runPowershellScript(PS51, probe, env, BOOTSTRAP_TIMEOUT_MS);
  assert.equal(result.timedOut, false, `真实 DSH bootstrap 超时：\n${result.stderr.slice(-1500)}`);
  assert.equal(result.code, 0, `stdout=${result.stdout}\nstderr=${result.stderr}`);

  assert.match(result.stdout, /default=acp;source=default-acp;created=True/);
  // 真实 DSH 的 ACP 模板必须同时声明 base 与 ACP app bundle。
  assert.match(result.stdout, /default=.*bundles=@deepseek-ai\/dsh-base\+@deepseek-ai\/dsh-acp-app/);
  assert.match(result.stdout, /again=acp;source=discovered;created=False/, '重复调用必须复用且不重新初始化');
  assert.match(result.stdout, /custom=acp-firststart-137;source=parameter;created=True/);
  assert.match(result.stdout, /customManifest=True/);
  assert.match(result.stdout, /customBundles=@deepseek-ai\/dsh-base\+@deepseek-ai\/dsh-acp-app/);
  // 官方初始化会写出 profile 的 cordis 层，而不仅仅是 package.json。
  assert.match(result.stdout, /defaultFiles=.*package\.json/);

  // 用户 DSH Home 从未参与：临时 fixture 里根本没有真实 Home。
  assert.equal(result.stdout.includes(FAKE_CREDENTIAL), false);
});

test('真实 start_dsh_team：默认 acp（含真实 headless 生成）与显式自定义 profile 均可健康复用', { timeout: 900000 }, async (context) => {
  const dependencyRoot = await resolveDependencyRoot();
  const dshBin = await resolveDshBin();
  if (!dependencyRoot || !dshBin) {
    context.skip('缺少 skill 依赖或已锁定 DSH：设置 CODEX_DSH_TEAM_TEST_NODE_MODULES / CODEX_DSH_TEAM_TEST_DSH_BIN，或安装 node_modules');
    return;
  }
  const base = await tempBase('launch');
  const env = await buildIsolatedEnv(base);
  const installedSkillRoot = await buildInstalledSkillRoot(base, dependencyRoot);
  const installedTeamScript = path.join(installedSkillRoot, 'scripts', 'start_dsh_team.ps1');
  const tag = runTag();
  const realLocalAppData = (process.env.LOCALAPPDATA ?? '').trim();
  const startedPids = new Set();

  context.after(async () => {
    // 自己启动的 monitor 进程：先用已记录/已发现的 pid，再移除临时目录。
    for (const pid of startedPids) await killProcessTree(pid);
    for (const host of hosts) {
      for (const scenario of SCENARIOS) {
        const found = await readMonitorRecord(scenarioWorkspace(base, host, scenario)).catch(() => null);
        if (found?.record?.pid && !startedPids.has(found.record.pid)) await killProcessTree(found.record.pid);
      }
    }
    await removeOwnedTempBase(base, 'launch');
    // 外部只读依赖树必须完好：清理绝不允许跟随 junction。
    await assertDependencyRootIntact(dependencyRoot);
  });

  let portCursor = 46510;
  for (const host of hosts) {
    const label = hostLabel(host);
    await context.test(`${label}: 默认 acp（含 headless 生成）与自定义 profile`, { timeout: 600000 }, async (t) => {
      // pwsh 不可用时明确 SKIP，而不是让断言以“进程不存在”失败后看起来像 PASS。
      const available = await spawnWithTimeout(host, ['-NoProfile', '-NonInteractive', '-Command', 'exit 0'], { timeoutMs: 60000 });
      if (available.timedOut || available.code !== 0) {
        t.skip(`${host} 不可用（timedOut=${available.timedOut} code=${available.code} error=${available.error?.code ?? 'none'}）`);
        return;
      }

      for (const scenario of SCENARIOS) {
        const scenarioLabel = `${label}-${scenario.key}`;
        const workspace = await initGitProject(scenarioWorkspace(base, host, scenario));
        const userHome = await writeFakeUserDshHome(path.join(base, `user-${scenarioLabel}`));
        const installId = scenarioInstallId(host, scenario, tag);
        const teamHome = await writeOwnedTeamHome(path.join(base, `team-${scenarioLabel}`), installId);
        const portBase = portCursor;
        portCursor += 80;

        const launchArgs = [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', installedTeamScript,
          '-Workspace', workspace,
          '-UserDshHome', userHome,
          '-TeamDshHome', teamHome,
          '-InstallId', installId,
          '-Port', String(portBase),
          '-SkipDshCheck',
          '-NoBrowser',
        ];
        if (scenario.teamProfile) launchArgs.push('-TeamProfile', scenario.teamProfile);

        // --- 第一次启动：真实 bootstrap + 健康 Monitor -----------------------------------
        const first = await runLauncher(host, launchArgs, path.join(base, `${scenarioLabel}-first.out`), path.join(base, `${scenarioLabel}-first.err`), env);
        assert.equal(first.timedOut, false, `${scenarioLabel}: start_dsh_team 超时：\n${(first.stderr || first.stdout).slice(-1500)}`);
        assert.equal(first.code, 0, `${scenarioLabel}: stdout=${first.stdout}\nstderr=${first.stderr}`);

        const firstRecord = await readMonitorRecord(workspace);
        assert.ok(firstRecord, `${scenarioLabel}: Monitor 必须写下 server.json 记录`);
        const url = firstRecord.record.url;
        assert.match(url, /^http:\/\/127\.0\.0\.1:\d+$/, `${scenarioLabel}: 必须返回本机 Monitor URL`);
        assert.ok(firstRecord.record.pid, `${scenarioLabel}: 记录必须包含 monitor pid`);
        // 公开记录必须带上最终 profile 与本次 install id（身份来自临时 base，不是真实用户 profile）。
        assert.equal(firstRecord.record.dsh_profile, scenario.profile, `${scenarioLabel}: record.dsh_profile 必须等于最终 profile`);
        assert.equal(firstRecord.record.install_id, installId, `${scenarioLabel}: record.install_id 必须等于传入的 install id`);
        startedPids.add(firstRecord.record.pid);

        const health = await monitorHealth(url);
        assert.equal(health.service, 'dsh-team-monitor');
        assert.equal((health.workspace ?? '').toLowerCase(), workspace.toLowerCase(), `${scenarioLabel}: health 必须绑定本工作区`);
        assert.equal((health.dshHome ?? '').toLowerCase(), teamHome.toLowerCase(), `${scenarioLabel}: health 必须绑定 owned Team Home`);
        assert.equal(health.dshProfile, scenario.profile, `${scenarioLabel}: health 必须报告最终 profile`);

        // profile 由真实 DSH bootstrap，manifest 必须是官方 ACP 模板（真实 bundles）。
        const profileManifestPath = path.join(teamHome, 'profiles', scenario.profile, 'package.json');
        const profileBundles = await readBundles(profileManifestPath);
        assert.equal(profileBundles.includes('@deepseek-ai/dsh-acp-app'), true,
          `${scenarioLabel}: profile 必须由官方 ACP 模板初始化（bundles=${profileBundles.join('+')}）`);
        // 用户 Home 只读：Team runtime 不得回写。
        assert.equal(await exists(path.join(userHome, MARKER_NAME)), false, `${scenarioLabel}: 用户 DSH Home 必须保持只读`);
        assert.equal(await exists(path.join(userHome, 'profiles', 'acp', 'cordis.patch.yml')), false);

        // 隔离证明：本次 install id 绝不能在真实用户 %LOCALAPPDATA% 下产生 Team runtime。
        if (realLocalAppData) {
          assert.equal(await exists(path.join(realLocalAppData, 'CodexDshTeam', 'runtimes', installId)), false,
            `${scenarioLabel}: 不得在真实用户 LocalAppData 下创建安装身份/runtime`);
        }

        const patchPath = path.join(teamHome, 'profiles', scenario.profile, 'cordis.patch.yml');
        const patchStatBefore = (await fs.stat(patchPath)).mtimeMs;

        // --- 第一次自检产物：真实 headless（仅默认场景）----------------------------------
        if (scenario.injectHeadless) {
          const headless = await runOfflineHeadlessBootstrap(host, dshBin, teamHome, base, scenarioLabel, env);
          assert.equal(headless.timedOut, false, `${scenarioLabel}: headless dump-config 超时`);
          assert.match(headless.stdout, /headlessExit=0;timedOut=False/,
            `${scenarioLabel}: headless dump-config 必须 exit 0：${headless.stdout}\n${headless.stderr}`);
          const headlessManifest = path.join(teamHome, 'profiles', 'headless', 'package.json');
          assert.equal(await exists(headlessManifest), true, `${scenarioLabel}: 真实 headless package 必须生成`);
          const headlessBundles = await readBundles(headlessManifest);
          assert.ok(headlessBundles.length > 0, `${scenarioLabel}: headless manifest 必须声明非空 bundles`);
          // 关键回归：多出一个非 ACP 内置模板后，默认选择仍必须是 acp（第二次启动会证明），
          // 且 headless 与 acp 同时存在。
          const profileDirs = await fs.readdir(path.join(teamHome, 'profiles'));
          assert.equal(profileDirs.includes('acp'), true, `${scenarioLabel}: acp profile 必须仍在`);
          assert.equal(profileDirs.includes('headless'), true, `${scenarioLabel}: headless profile 必须已生成`);
        }

        // --- 第二次启动：同一个 Monitor 必须被复用 ---------------------------------------
        const second = await runLauncher(host, launchArgs, path.join(base, `${scenarioLabel}-second.out`), path.join(base, `${scenarioLabel}-second.err`), env);
        assert.equal(second.timedOut, false, `${scenarioLabel}: 第二次 start_dsh_team 超时`);
        assert.equal(second.code, 0, `${scenarioLabel}: stdout=${second.stdout}\nstderr=${second.stderr}`);
        const secondRecord = await readMonitorRecord(workspace);
        assert.equal(secondRecord.record.url, url, `${scenarioLabel}: 复用必须返回同一个 Monitor URL`);
        assert.equal(secondRecord.record.pid, firstRecord.record.pid, `${scenarioLabel}: 复用不得启动第二个 Monitor 进程`);
        assert.equal(secondRecord.record.start_utc, firstRecord.record.start_utc, `${scenarioLabel}: 复用不得重置启动时间`);
        assert.equal(secondRecord.record.dsh_profile, scenario.profile, `${scenarioLabel}: 复用记录必须保持同一个 profile`);

        const reusedHealth = await monitorHealth(url);
        assert.equal(reusedHealth.service, 'dsh-team-monitor');
        assert.equal(reusedHealth.dshProfile, scenario.profile, `${scenarioLabel}: 复用后 health profile 必须不变`);

        // 已有 profile 与 patch 不得被重写；headless 也不得被清理或接管。
        assert.equal((await fs.stat(patchPath)).mtimeMs, patchStatBefore, `${scenarioLabel}: 未变化的 cordis.patch.yml 不得被重写`);
        assert.equal(await exists(path.join(teamHome, 'profiles', scenario.profile, 'package.json')), true);
        if (scenario.injectHeadless) {
          assert.equal(await exists(path.join(teamHome, 'profiles', 'headless', 'package.json')), true,
            `${scenarioLabel}: headless package 不得被第二次启动删除`);
        }
        else {
          // 显式自定义 profile 不会顺带创建 acp。
          assert.equal(await exists(path.join(teamHome, 'profiles', 'acp')), false,
            `${scenarioLabel}: 显式自定义 profile 不应创建 acp`);
        }
        // 第二次启动同样不得在真实用户 LocalAppData 下留下安装身份。
        if (realLocalAppData) {
          assert.equal(await exists(path.join(realLocalAppData, 'CodexDshTeam', 'runtimes', installId)), false,
            `${scenarioLabel}: 复用启动同样不得写入真实用户 LocalAppData`);
        }

        await killProcessTree(firstRecord.record.pid);
        startedPids.delete(firstRecord.record.pid);
      }
    });
  }
});
