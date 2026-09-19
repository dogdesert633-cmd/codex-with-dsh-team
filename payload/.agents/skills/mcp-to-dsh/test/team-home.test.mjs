// Direct tests for the Toolkit-owned Team Home policy (Release Blocker B).
//
// Every case uses temporary directories and fake credentials. The user's real DSH Home is
// never read or written, and no provider is contacted.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  INSTALL_MANIFEST_SCHEMA,
  TEAM_HOME_MARKER_NAME,
  TEAM_HOME_MARKER_PURPOSE,
  TEAM_HOME_MARKER_SCHEMA,
  TOOLKIT_ID,
  assertOutsideWorkspace,
  assertReparseFree,
  assertUserDshHomeReadOnlySource,
  buildTeamHomeMarker,
  defaultTeamHomeRoot,
  ensureInstallIdentity,
  findReparsePoint,
  inspectTeamHome,
  isOwnedTeamHome,
  looksLikeUserDshHome,
  markerPath,
  readTeamHomeMarker,
  resolveTeamHome,
  validateTeamHomeMarker,
  writeFileAtomic,
  writeTeamHomeMarker,
} from '../src/team-home.mjs';

const FAKE_CREDENTIAL = 'fake-credential-value-0002';

async function tempBase(label) {
  return await fsp.mkdtemp(path.join(os.tmpdir(), `dsh-team-home-${label}-`));
}

function snapshot(dir) {
  const entries = [];
  const walk = (current) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = path.join(current, entry.name);
      const stats = fs.statSync(full);
      entries.push(`${path.relative(dir, full)}|${stats.size}|${stats.mtimeMs}`);
      if (entry.isDirectory()) walk(full);
    }
  };
  walk(dir);
  return entries;
}

async function seedUserDshHome(dir) {
  await fsp.mkdir(path.join(dir, 'profiles', 'acp'), { recursive: true });
  await fsp.mkdir(path.join(dir, 'sessions'), { recursive: true });
  await fsp.writeFile(path.join(dir, 'settings.yaml'), 'agent-default-model:\n  provider: fake-provider\n  model: fake-model\n');
  await fsp.writeFile(path.join(dir, '.credentials.yaml'), `version: 1\nFAKE_API_KEY: ${FAKE_CREDENTIAL}\n`);
  await fsp.writeFile(path.join(dir, 'profiles', 'acp', 'package.json'), '{"name":"acp"}\n');
}

test('ensureInstallIdentity 复用同一个稳定 install id，且 manifest 无 secret', async (context) => {
  const base = await tempBase('identity');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const manifestPath = path.join(base, 'install.json');

  const first = ensureInstallIdentity({ manifestPath });
  assert.equal(first.created, true);
  assert.ok(first.installId);
  const second = ensureInstallIdentity({ manifestPath });
  assert.equal(second.created, false);
  assert.equal(second.installId, first.installId, 'install id 必须跨调用稳定');

  const raw = await fsp.readFile(manifestPath, 'utf8');
  const parsed = JSON.parse(raw);
  assert.equal(parsed.schema, INSTALL_MANIFEST_SCHEMA);
  assert.equal(parsed.toolkitId, TOOLKIT_ID);
  assert.equal(raw.includes(FAKE_CREDENTIAL), false);

  // 项目移动不影响 identity：manifest 在项目/Git 之外。
  assert.equal(manifestPath.startsWith(path.resolve(base)), true);
});

test('ensureInstallIdentity 拒绝被 reparse point 重定向的父目录', async (context) => {
  if (process.platform !== 'win32') return;
  const base = await tempBase('identity-reparse');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const real = path.join(base, 'real');
  const link = path.join(base, 'link');
  await fsp.mkdir(real, { recursive: true });
  fs.symlinkSync(real, link, 'junction');
  assert.throws(
    () => ensureInstallIdentity({ manifestPath: path.join(link, 'nested', 'install.json') }),
    /reparse point/,
  );
});

test('默认 Team Home 首次创建带完整 marker，之后被识别为 owned 且不重建', async (context) => {
  const base = await tempBase('default');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const root = path.join(base, 'runtimes');
  const workspace = path.join(base, 'project');
  await fsp.mkdir(workspace, { recursive: true });

  const created = resolveTeamHome({ root, workspace, installId: 'install-1', allowCreate: true });
  assert.equal(created.created, true);
  assert.equal(created.teamHome, path.join(root, 'install-1'));
  const marker = readTeamHomeMarker(created.teamHome);
  assert.equal(marker.schema, TEAM_HOME_MARKER_SCHEMA);
  assert.equal(marker.toolkitId, TOOLKIT_ID);
  assert.equal(marker.installId, 'install-1');
  assert.equal(marker.purpose, TEAM_HOME_MARKER_PURPOSE);
  assert.ok(marker.createdAt);
  assert.equal(isOwnedTeamHome(created.teamHome, { installId: 'install-1' }), true);
  assert.equal(created.teamHome.startsWith(path.resolve(root)), true);
  assert.equal(created.teamHome.startsWith(path.resolve(workspace)), false, 'Team Home 必须在项目之外');

  const reopened = resolveTeamHome({ root, workspace, installId: 'install-1', allowCreate: true });
  assert.equal(reopened.created, false);
  assert.equal(reopened.teamHome, created.teamHome);

  // 同一个 owned runtime 会随安装 manifest 的 install id 被重新定位，与项目路径无关。
  const movedWorkspace = path.join(base, 'moved-project');
  await fsp.mkdir(movedWorkspace, { recursive: true });
  const afterMove = resolveTeamHome({ root, workspace: movedWorkspace, installId: 'install-1', allowCreate: false });
  assert.equal(afterMove.teamHome, created.teamHome);
});

test('已有目标目录只有在 marker 完整匹配时才可写', async (context) => {
  const base = await tempBase('marker');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const root = path.join(base, 'runtimes');

  // 1) 无 marker 的普通目录：拒绝 adopt。
  const unowned = path.join(base, 'unowned');
  await fsp.mkdir(unowned, { recursive: true });
  await fsp.writeFile(path.join(unowned, 'keep.txt'), 'untouched\n');
  assert.equal(inspectTeamHome(unowned, { installId: 'install-1' }).state, 'unowned');
  assert.throws(
    () => resolveTeamHome({ requested: unowned, installId: 'install-1', allowCreate: true }),
    /没有合法 Team Home marker/,
  );
  assert.deepEqual(await fsp.readdir(unowned), ['keep.txt'], '被拒绝的目录必须完全不变');
  assert.equal(fs.existsSync(markerPath(unowned)), false);

  // 2) marker 属于别的 install：拒绝。
  const foreign = path.join(base, 'foreign');
  await fsp.mkdir(foreign, { recursive: true });
  writeTeamHomeMarker(foreign, buildTeamHomeMarker({ installId: 'other-install' }));
  assert.equal(inspectTeamHome(foreign, { installId: 'install-1' }).state, 'foreign-install');
  assert.throws(
    () => resolveTeamHome({ requested: foreign, installId: 'install-1', allowCreate: true }),
    /属于另一次安装/,
  );

  // 3) marker 属于别的 toolkit / 错误 purpose / 缺字段：一律拒绝。
  for (const bad of [
    { ...buildTeamHomeMarker({ installId: 'install-1' }), toolkitId: 'someone-else' },
    { ...buildTeamHomeMarker({ installId: 'install-1' }), purpose: 'generic-dsh-home' },
    { schema: TEAM_HOME_MARKER_SCHEMA, toolkitId: TOOLKIT_ID, installId: 'install-1', createdAt: '2026-01-01T00:00:00Z' },
    null,
  ]) {
    const dir = path.join(base, `bad-${Math.random().toString(36).slice(2)}`);
    await fsp.mkdir(dir, { recursive: true });
    await fsp.writeFile(markerPath(dir), `${JSON.stringify(bad)}\n`);
    assert.equal(validateTeamHomeMarker(bad, { installId: 'install-1' }).ok, false);
    assert.throws(() => resolveTeamHome({ requested: dir, installId: 'install-1', allowCreate: true }));
  }

  // 4) marker 完整匹配：允许复用。
  const owned = path.join(base, 'owned');
  await fsp.mkdir(owned, { recursive: true });
  writeTeamHomeMarker(owned, buildTeamHomeMarker({ installId: 'install-1' }));
  const resolved = resolveTeamHome({ requested: owned, installId: 'install-1', allowCreate: true });
  assert.equal(resolved.teamHome, path.resolve(owned));
  assert.equal(resolved.created, false);

  // 5) 默认路径 absence + allowCreate=false：明确阻断而不是静默创建。
  assert.throws(
    () => resolveTeamHome({ root: path.join(base, 'empty-root'), installId: 'install-9', allowCreate: false }),
    /Team Home 不存在/,
  );
});

test('看起来是普通 DSH Home 的目录绝不被 adopt', async (context) => {
  const base = await tempBase('userhome');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const userHome = path.join(base, 'user-dsh');
  await seedUserDshHome(userHome);
  assert.equal(looksLikeUserDshHome(userHome), true);
  const inspection = inspectTeamHome(userHome, { installId: 'install-1' });
  assert.equal(inspection.state, 'user-dsh-home');
  assert.throws(
    () => resolveTeamHome({ requested: userHome, installId: 'install-1', allowCreate: true }),
    /用户 DSH Home 只作为只读配置来源/,
  );
  // 拒绝之后目录内容与 marker 都不变。
  assert.equal(fs.existsSync(markerPath(userHome)), false);
  assert.equal(await fsp.readFile(path.join(userHome, '.credentials.yaml'), 'utf8'), `version: 1\nFAKE_API_KEY: ${FAKE_CREDENTIAL}\n`);
});

test('用户 DSH Home 作为只读来源：内容/mtime/文件集合全程不变', async (context) => {
  const base = await tempBase('readonly');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const userHome = path.join(base, 'user-dsh');
  const teamHome = path.join(base, 'team');
  await seedUserDshHome(userHome);
  const before = snapshot(userHome);
  const beforeStats = fs.statSync(path.join(userHome, '.credentials.yaml'));

  const created = resolveTeamHome({ requested: teamHome, installId: 'install-1', allowCreate: true });
  assert.equal(created.created, true);
  writeFileAtomic(path.join(created.teamHome, 'settings.yaml'), 'agent-default-model:\n  provider: fake-provider\n');
  assertUserDshHomeReadOnlySource(userHome, created.teamHome);

  assert.deepEqual(snapshot(userHome), before, '用户 DSH Home 的文件集合/大小/mtime 必须不变');
  assert.equal(fs.statSync(path.join(userHome, '.credentials.yaml')).mtimeMs, beforeStats.mtimeMs);
  // 同步方向单向：用户 Home 里绝不出现 Team Home 的产物。
  assert.equal(fs.existsSync(path.join(userHome, TEAM_HOME_MARKER_NAME)), false);
  assert.equal(fs.existsSync(path.join(userHome, 'team')), false);
});

test('assertUserDshHomeReadOnlySource 拒绝相同、包含与被包含', async (context) => {
  const base = await tempBase('direction');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const userHome = path.join(base, 'user');
  const teamHome = path.join(base, 'team');
  await fsp.mkdir(userHome, { recursive: true });
  await fsp.mkdir(teamHome, { recursive: true });

  assert.throws(() => assertUserDshHomeReadOnlySource(userHome, userHome), /同一目录/);
  assert.throws(() => assertUserDshHomeReadOnlySource(userHome, path.join(userHome, 'team')), /位于用户 DSH Home/);
  assert.throws(() => assertUserDshHomeReadOnlySource(path.join(teamHome, 'user'), teamHome), /位于 Team Home/);
  assert.doesNotThrow(() => assertUserDshHomeReadOnlySource(userHome, teamHome));
});

test('reparse point / 越界检查', async (context) => {
  const base = await tempBase('reparse');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const workspace = path.join(base, 'project');
  await fsp.mkdir(workspace, { recursive: true });

  // 项目内路径必须被拒绝。
  assert.throws(() => assertOutsideWorkspace(path.join(workspace, 'team'), workspace), /项目\/Git 之外/);

  if (process.platform === 'win32') {
    const real = path.join(base, 'real');
    const link = path.join(base, 'junction');
    await fsp.mkdir(real, { recursive: true });
    fs.symlinkSync(real, link, 'junction');
    assert.equal(findReparsePoint(path.join(link, 'child')), link);
    assert.throws(() => assertReparseFree(path.join(link, 'child'), { label: 'x' }), /reparse point/);
    assert.throws(
      () => resolveTeamHome({ requested: path.join(link, 'team'), installId: 'install-1', allowCreate: true }),
      /reparse point/,
    );
  }
  assert.equal(findReparsePoint(path.join(base, 'not-created-yet', 'deep')), null);
});

test('相对路径的 Team Home 被拒绝，默认根目录位于 LOCALAPPDATA', async (context) => {
  const base = await tempBase('relative');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  assert.throws(
    () => resolveTeamHome({ requested: 'relative\\team', installId: 'install-1', allowCreate: true }),
    /必须是绝对路径/,
  );
  assert.equal(defaultTeamHomeRoot({ LOCALAPPDATA: 'D:\\Sandbox\\LocalAppData' }),
    path.join('D:\\Sandbox\\LocalAppData', 'CodexDshTeam', 'runtimes'));
  assert.equal(resolveTeamHome({ root: path.join(base, 'r'), installId: 'x', allowCreate: true }).created, true);
});

test('writeFileAtomic 不留下临时文件', async (context) => {
  const base = await tempBase('atomic');
  context.after(() => fsp.rm(base, { recursive: true, force: true }));
  const target = path.join(base, 'marker.json');
  writeFileAtomic(target, '{}\n');
  assert.deepEqual(await fsp.readdir(base), ['marker.json']);
});

test('marker 字段必须是非空字符串：空白字段/标量/数组都不是合法 marker', () => {
  // 与 PowerShell 侧 Test-DshTeamHomeMarker 同一策略：缺字段、空白字段、标量或数组 JSON 都
  // 只返回 ok=false + 可读 reason，绝不把“空白当成功”，也不依赖严格模式抛异常。
  const blank = { ...buildTeamHomeMarker({ installId: 'install-1' }), installId: '   ' };
  assert.equal(validateTeamHomeMarker(blank, { installId: 'install-1' }).ok, false);

  const wrongType = { ...buildTeamHomeMarker({ installId: 'install-1' }), purpose: 7 };
  assert.equal(validateTeamHomeMarker(wrongType, { installId: 'install-1' }).ok, false);

  for (const scalar of [42, 'marker', true, [], [{ installId: 'install-1' }]]) {
    const verdict = validateTeamHomeMarker(scalar, { installId: 'install-1' });
    assert.equal(verdict.ok, false, `${JSON.stringify(scalar)} 不得被当作 marker`);
    assert.equal(typeof verdict.reason, 'string');
    assert.ok(verdict.reason.length > 0);
  }

  // 空 installId 的契约要求：没有 install id 时只校验其余字段，仍然拒绝空白字段。
  const good = buildTeamHomeMarker({ installId: 'install-1' });
  assert.equal(validateTeamHomeMarker(good).ok, true);
  assert.equal(validateTeamHomeMarker({ ...good, createdAt: '' }, { installId: 'install-1' }).ok, false);
});
