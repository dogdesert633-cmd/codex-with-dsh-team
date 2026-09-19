// Startup profile routing (WP-135).
//
// The DSH ACP profile is a *launch parameter*: the launcher, the monitor, the bridge child and
// the one-click configuration sync must all see the same value. This file verifies the wiring
// that the runtime tests cannot reach without starting a real monitor:
//
//   * the console launcher accepts `-TeamProfile`, defaults to the built-in `acp`, validates the
//     name with the SAME grammar as src/server.mjs / src/cli.mjs, and forwards it to the server
//     on both the foreground and the background branch;
//   * both monitor records carry the profile, and reuse requires workspace + home + profile to
//     match (a legacy record without the field is interpreted as the historical `acp`);
//   * the Windows launcher still starts the monitor hidden.
//
// No process is started here: a launcher run would create the toolkit install identity under
// %LOCALAPPDATA%, which a unit test must never do.

import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";

const skillRoot = path.resolve(import.meta.dirname, "..");
const launcherPath = path.join(skillRoot, "scripts", "start_dsh_monitor.ps1");
const serverPath = path.join(skillRoot, "src", "server.mjs");
const cliPath = path.join(skillRoot, "src", "cli.mjs");

const read = (target) => fs.readFile(target, "utf8");

/** Extract the profile-name pattern body from a JS regex literal or a PowerShell quoted regex. */
function extractPattern(text, label) {
  const jsLiteral = text.match(/\/\^\[A-Za-z0-9\]\[A-Za-z0-9\._-\]\{0,63\}\$\//);
  if (jsLiteral) return jsLiteral[0].slice(1, -1);
  const psLiteral = text.match(/'(\^\[A-Za-z0-9\]\[A-Za-z0-9\._-\]\{0,63\}\$)'/);
  if (psLiteral) return psLiteral[1];
  assert.fail(`${label} 必须使用统一的 profile 语法正则`);
}

test("启动器接受 -TeamProfile，且与 server/cli 使用同一套名字语法", async () => {
  const [launcher, server, cli] = await Promise.all([read(launcherPath), read(serverPath), read(cliPath)]);

  // 参数存在且未传时默认内置 acp（既有调用完全兼容）
  assert.match(launcher, /\[string\]\$TeamProfile/, "start_dsh_monitor 必须接受 -TeamProfile");
  assert.match(launcher, /if \(-not \$profileName\) \{ \$profileName = 'acp' \}/, "未传 profile 必须默认 acp");

  // 三处语法一致（同一正则字面量），并共同拒绝保留目录名 node_modules
  const launcherPattern = extractPattern(launcher, "start_dsh_monitor.ps1");
  assert.equal(extractPattern(server, "src/server.mjs"), launcherPattern, "server 与启动器语法必须一致");
  assert.equal(extractPattern(cli, "src/cli.mjs"), launcherPattern, "cli 与启动器语法必须一致");
  for (const [label, text] of [["launcher", launcher], ["server", server], ["cli", cli]]) {
    assert.match(text, /node_modules/, `${label} 必须拒绝 node_modules 这一保留目录名`);
  }
});

test("启动器把 profile 传给前台与后台两条分支，并写入两份记录", async () => {
  const launcher = await read(launcherPath);

  // 后台分支：Start-Process 的实参行必须带 --dsh-profile
  assert.match(launcher, /\$profileArgument/, "后台分支必须拼出 --dsh-profile 参数");
  assert.match(
    launcher,
    /--toolkit-install-id `"\$InstallId`"\$profileArgument\$userHomeArgument/,
    "后台 Start-Process 实参必须包含 profile",
  );
  // 前台分支：数组形式同样带 --dsh-profile
  assert.match(launcher, /@profileArgs @userHomeArgs/, "前台分支必须传 --dsh-profile");
  assert.match(launcher, /\$profileArgs = @\('--dsh-profile', \$profileName\)/, "profile 参数必须由同一个变量拼装");

  // 记录：本地 server.json（New-MonitorTokenRecord）与公开 record 都带 dsh_profile
  const occurrences = launcher.match(/dsh_profile = \$profileName/g) ?? [];
  assert.equal(occurrences.length, 2, "公开 record 与本地 token record 都必须带 dsh_profile");

  // Windows 启动必须隐藏窗口
  assert.match(launcher, /Start-Process[^\n]*-WindowStyle Hidden/, "Windows Start-Process 必须使用 -WindowStyle Hidden");
});

test("复用判定要求 workspace、home、profile 三者一致，旧 record 只在 acp 下可复用", async () => {
  const launcher = await read(launcherPath);

  // health 匹配包含 profile
  assert.match(launcher, /function Test-MonitorHealthMatch/, "必须有统一的 health 匹配函数");
  const healthMatch = launcher.slice(launcher.indexOf("function Test-MonitorHealthMatch"));
  assert.match(healthMatch, /Get-HealthProfile -Health \$Health\) -eq \$profileName/, "health 匹配必须比较 profile");
  assert.match(healthMatch, /\$Health\.workspace -ne \$workspacePath/, "health 匹配必须比较 workspace");
  assert.match(healthMatch, /\$Health\.dshHome -ne \$dshHomePath/, "health 匹配必须比较 home");

  // 旧 health 缺字段按历史 acp 解释
  assert.match(launcher, /if \(\[string\]::IsNullOrWhiteSpace\(\$value\)\) \{ return 'acp' \}/, "health 缺 profile 必须按 acp 解释");

  // 旧 record 缺字段按 acp，并且只允许请求 acp 时复用
  assert.match(launcher, /return \(\$profileName -eq 'acp'\)/, "record 缺 profile 时只有请求 acp 才可复用");
  assert.match(launcher, /\(Test-MonitorHealthMatch -Health \$existingHealth\) -and \(Test-MonitorRecordProfileMatch -Record \$existingRecord\)/, "reuse 必须同时通过 health 与 record 的 profile 判定");

  // 参数不同：不得复用错误的 monitor，而是明确拒绝
  assert.match(launcher, /occupied by a DSH monitor for profile/, "profile 不一致必须报错而不是复用");
  assert.match(launcher, /Use -AutoPort or choose another port/, "错误必须给出可执行的下一步");
});

test("health 暴露 dshProfile，bridge 子进程与配置同步使用同一个 profile", async () => {
  const server = await read(serverPath);

  // health 投影带 dshProfile
  assert.match(server, /\n\s+dshProfile,\n/, "health 必须暴露 dshProfile");
  // bridge 子进程注入 profile（在既有 explicit 环境之上追加，不改动原有字段）
  assert.match(server, /spawnEnv\.CODEX_DSH_ACP_PROFILE = dshProfile/, "bridge 子进程必须收到 CODEX_DSH_ACP_PROFILE");
  assert.match(server, /explicit: \{ DSH_HOME: dshHome, DSH_PERMISSION_MODE: permissionMode \}/, "既有 explicit 字段必须保持不变");
  // 一键配置同步参数一致
  assert.match(server, /"-TeamProfile", dshProfile/, "配置同步子进程必须收到 -TeamProfile");
  // CLI 解析并校验
  assert.match(server, /else if \(arg === "--dsh-profile"\) options\.dshProfile = normalizeDshProfile/, "CLI 必须解析并校验 --dsh-profile");
  // 工厂校验
  assert.match(server, /const dshProfile = normalizeDshProfile\(options\.dshProfile, "Monitor --dsh-profile"\)/, "工厂必须校验 dshProfile");
});
