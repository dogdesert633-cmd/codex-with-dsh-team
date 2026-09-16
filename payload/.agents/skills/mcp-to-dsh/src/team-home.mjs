// team-home.mjs
//
// Release Blocker B: the user's own DSH Home is a read-only configuration source, and the
// Team runtime lives in a Toolkit-owned, marked Team Home outside the project/Git tree.
//
// This module is the single authority for
//   * where the default Team Home lives (stable per installation, not per project path),
//   * whether an existing directory may be adopted as a Team Home,
//   * proving Toolkit ownership through an explicit marker file,
//   * refusing reparse points (symlink/junction) anywhere on the created parent chain.
//
// It never writes into a user DSH Home and never guesses ownership from a directory name.
// Dependency free (node: builtins only) so it can be unit tested with temporary
// directories and fake credential files.

import {
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { randomUUID } from "node:crypto";
import { homedir, tmpdir } from "node:os";
import { dirname, isAbsolute, join, parse, resolve, sep } from "node:path";

export const TEAM_HOME_MARKER_NAME = ".codex-dsh-team-home.json";
export const TEAM_HOME_MARKER_SCHEMA = "codex-dsh-team-home/v1";
export const TEAM_HOME_MARKER_PURPOSE = "dsh-team-runtime-home";
export const INSTALL_MANIFEST_SCHEMA = "codex-dsh-team-install/v1";
export const TOOLKIT_ID = "codex-dsh-team-toolkit";
export const TEAM_HOME_POLICY_VERSION = "team-home-policy/v1";

const MARKER_REQUIRED_FIELDS = Object.freeze(["schema", "toolkitId", "installId", "createdAt", "purpose"]);

function portable(path) {
  return process.platform === "win32" ? path.toLowerCase() : path;
}

function isInside(parent, child) {
  const normalizedParent = portable(resolve(parent));
  const normalizedChild = portable(resolve(child));
  if (normalizedParent === normalizedChild) return true;
  return normalizedChild.startsWith(normalizedParent.endsWith(sep) ? normalizedParent : `${normalizedParent}${sep}`);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/** Atomic UTF-8 write (no BOM), so a half-written marker can never be observed. */
export function writeFileAtomic(path, contents) {
  const temporary = `${path}.${process.pid}.${Date.now()}.tmp`;
  writeFileSync(temporary, contents, { encoding: "utf8" });
  try {
    renameSync(temporary, path);
  } catch (error) {
    try { unlinkSync(temporary); } catch { /* best effort */ }
    throw error;
  }
}

// ---------------------------------------------------------------------------
// 1. Reparse / boundary checks
// ---------------------------------------------------------------------------

/**
 * Walk every existing component of `path` from the filesystem root downwards and report
 * the first symlink/junction. A Team Home must never be reached through a reparse point:
 * that is what makes "outside the project" and "owned by this install" enforceable.
 */
export function findReparsePoint(path) {
  const target = resolve(path);
  const chain = [];
  let current = target;
  for (;;) {
    chain.unshift(current);
    const parent = dirname(current);
    if (parent === current) break;
    current = parent;
  }
  for (const candidate of chain) {
    try {
      if (lstatSync(candidate).isSymbolicLink()) return candidate;
    } catch {
      // Not created yet: nothing to follow.
    }
  }
  return null;
}

/** Throws unless every existing component of `path` is a real directory. */
export function assertReparseFree(path, { label = "path" } = {}) {
  const reparse = findReparsePoint(path);
  if (reparse) {
    throw new Error(`${label} 的路径链上存在 reparse point（符号链接/junction）：${reparse}；拒绝在可被重定向的路径上创建或写入 Team Home。`);
  }
  return resolve(path);
}

/** The Team Home must live outside the project/Git workspace it serves. */
export function assertOutsideWorkspace(teamHome, workspace) {
  if (!workspace) return resolve(teamHome);
  if (isInside(workspace, teamHome)) {
    throw new Error(`Team Home ${resolve(teamHome)} 位于项目工作区 ${resolve(workspace)} 内；Team runtime 必须写在项目/Git 之外。`);
  }
  return resolve(teamHome);
}

// ---------------------------------------------------------------------------
// 2. Ownership marker
// ---------------------------------------------------------------------------

export function markerPath(teamHome) {
  return join(resolve(teamHome), TEAM_HOME_MARKER_NAME);
}

export function buildTeamHomeMarker({ toolkitId = TOOLKIT_ID, installId, createdAt, purpose = TEAM_HOME_MARKER_PURPOSE } = {}) {
  if (!installId) throw new Error("buildTeamHomeMarker 需要 installId。");
  return {
    schema: TEAM_HOME_MARKER_SCHEMA,
    toolkitId,
    installId,
    createdAt: createdAt ?? new Date().toISOString(),
    purpose,
  };
}

/** Validate a marker against this toolkit id and this installation id. Never guesses. */
export function validateTeamHomeMarker(marker, { toolkitId = TOOLKIT_ID, installId } = {}) {
  if (!marker || typeof marker !== "object" || Array.isArray(marker)) {
    return { ok: false, reason: "marker 缺失或不是对象" };
  }
  for (const field of MARKER_REQUIRED_FIELDS) {
    if (typeof marker[field] !== "string" || marker[field].trim() === "") {
      return { ok: false, reason: `marker 缺少必需字段 ${field}` };
    }
  }
  if (marker.schema !== TEAM_HOME_MARKER_SCHEMA) {
    return { ok: false, reason: `marker schema ${marker.schema} 不受支持（期望 ${TEAM_HOME_MARKER_SCHEMA}）` };
  }
  if (marker.toolkitId !== toolkitId) {
    return { ok: false, reason: `marker 属于 toolkit ${marker.toolkitId}，不是 ${toolkitId}` };
  }
  if (marker.purpose !== TEAM_HOME_MARKER_PURPOSE) {
    return { ok: false, reason: `marker purpose ${marker.purpose} 不是 ${TEAM_HOME_MARKER_PURPOSE}` };
  }
  if (installId && marker.installId !== installId) {
    return { ok: false, reason: `marker 属于 install ${marker.installId}，不是本次安装的 ${installId}` };
  }
  return { ok: true, marker };
}

export function readTeamHomeMarker(teamHome) {
  return readJson(markerPath(teamHome));
}

export function writeTeamHomeMarker(teamHome, marker) {
  writeFileAtomic(markerPath(teamHome), `${JSON.stringify(marker, null, 2)}\n`);
  return marker;
}

/**
 * A directory that carries DSH's own runtime state. Such a directory is a *user* DSH Home
 * and may only ever be read from — it is never adopted as a Team Home.
 */
export function looksLikeUserDshHome(dir) {
  if (!existsSync(dir)) return false;
  for (const probe of ["settings.yaml", ".credentials.yaml", "sessions", "storages"]) {
    if (existsSync(join(dir, probe))) return true;
  }
  if (existsSync(join(dir, "profiles"))) {
    // A bare profile directory alone is ambiguous; only count it when there is no marker
    // AND a credential/settings artefact exists somewhere below it.
    try {
      const children = ["acp", "headless", "default"];
      for (const child of children) {
        if (existsSync(join(dir, "profiles", child, "package.json")) && existsSync(join(dir, "profiles", child, "node_modules"))) {
          return true;
        }
      }
    } catch {
      return false;
    }
  }
  return false;
}

/**
 * Classify an existing Team Home candidate without ever modifying it.
 *
 * states:
 *   missing          nothing there yet (creation is allowed only when explicitly requested)
 *   not-a-directory  a file/other object occupies the path
 *   owned            marker present and fully matched this toolkit + install
 *   foreign-install  marker valid for this toolkit but a different install id
 *   unowned          directory exists without a valid marker
 *   user-dsh-home    directory looks like a real DSH Home
 */
export function inspectTeamHome(teamHome, { toolkitId = TOOLKIT_ID, installId } = {}) {
  const target = resolve(teamHome);
  if (!existsSync(target)) return { state: "missing", teamHome: target, marker: null, reason: "目录不存在" };
  let stats;
  try {
    stats = statSync(target);
  } catch (error) {
    return { state: "not-a-directory", teamHome: target, marker: null, reason: error.message };
  }
  if (!stats.isDirectory()) {
    return { state: "not-a-directory", teamHome: target, marker: null, reason: "目标已存在且不是目录" };
  }
  const marker = readTeamHomeMarker(target);
  const validation = validateTeamHomeMarker(marker, { toolkitId, installId });
  if (validation.ok) return { state: "owned", teamHome: target, marker, reason: "marker 完整匹配" };
  if (marker && marker.schema === TEAM_HOME_MARKER_SCHEMA && marker.toolkitId === toolkitId && installId && marker.installId !== installId) {
    return { state: "foreign-install", teamHome: target, marker, reason: validation.reason };
  }
  if (looksLikeUserDshHome(target)) {
    return { state: "user-dsh-home", teamHome: target, marker, reason: "目录内容看起来是普通 DSH Home" };
  }
  return { state: "unowned", teamHome: target, marker, reason: validation.reason };
}

// ---------------------------------------------------------------------------
// 3. Install identity (stable across project moves)
// ---------------------------------------------------------------------------

export function toolkitBaseDir(env = process.env) {
  const override = env.CODEX_DSH_TEAM_BASE_DIR;
  if (override && override.trim()) return resolve(override.trim());
  const localAppData = env.LOCALAPPDATA && env.LOCALAPPDATA.trim();
  if (localAppData) return join(localAppData, "CodexDshTeam");
  const appData = env.APPDATA && env.APPDATA.trim();
  if (appData) return join(appData, "CodexDshTeam");
  return join(tmpdir(), "CodexDshTeam");
}

export function defaultTeamHomeRoot(env = process.env) {
  return join(toolkitBaseDir(env), "runtimes");
}

export function defaultInstallManifestPath(env = process.env) {
  return join(toolkitBaseDir(env), "install.json");
}

/**
 * Read, or create once, the stable install identity. The manifest lives outside the
 * project on purpose: moving/renaming the project must still find the same owned runtime.
 */
export function ensureInstallIdentity({ manifestPath = defaultInstallManifestPath(), toolkitId = TOOLKIT_ID, env = process.env } = {}) {
  const path = resolve(manifestPath);
  const existing = readJson(path);
  if (existing
    && existing.schema === INSTALL_MANIFEST_SCHEMA
    && typeof existing.installId === "string" && existing.installId.trim()
    && existing.toolkitId === toolkitId) {
    return { installId: existing.installId, toolkitId, manifestPath: path, created: false };
  }
  assertReparseFree(dirname(path), { label: "install manifest 父目录" });
  mkdirSync(dirname(path), { recursive: true });
  const manifest = {
    schema: INSTALL_MANIFEST_SCHEMA,
    toolkitId,
    installId: randomUUID(),
    createdAt: new Date().toISOString(),
    purpose: "codex-dsh-team-install-identity",
  };
  writeFileAtomic(path, `${JSON.stringify(manifest, null, 2)}\n`);
  void env;
  return { installId: manifest.installId, toolkitId, manifestPath: path, created: true };
}

// ---------------------------------------------------------------------------
// 4. Resolution
// ---------------------------------------------------------------------------

/**
 * Resolve the Team Home that all Team-owned runtime configuration may be written to.
 *
 * Existing directories are adopted **only** with a fully matching marker. Anything else —
 * an unowned directory, a marker from another installation, or a directory that looks
 * like a normal DSH Home — stops the caller instead of being patched.
 */
export function resolveTeamHome({
  requested,
  workspace,
  toolkitId = TOOLKIT_ID,
  installId,
  root = defaultTeamHomeRoot(),
  allowCreate = false,
} = {}) {
  if (!installId) throw new Error("resolveTeamHome 需要 installId（安装 manifest 提供的稳定标识）。");
  if (requested && !isAbsolute(requested)) {
    throw new Error(`Team Home 必须是绝对路径：${requested}`);
  }
  const explicit = Boolean(requested);
  const target = explicit ? resolve(requested) : join(resolve(root), installId);

  assertReparseFree(target, { label: explicit ? "-TeamDshHome/REMOTE_TO_DSH_HOME" : "默认 Team Home 路径" });
  if (workspace) assertOutsideWorkspace(target, workspace);

  const inspection = inspectTeamHome(target, { toolkitId, installId });
  if (inspection.state === "owned") {
    return { teamHome: target, created: false, explicit, marker: inspection.marker, inspection };
  }
  if (inspection.state === "missing") {
    if (!allowCreate) {
      throw new Error(`Team Home 不存在：${target}。请先由安装器准备该 Toolkit-owned runtime，或用 -TeamDshHome 指向一个带合法 marker 的 Team Home。`);
    }
    mkdirSync(target, { recursive: true });
    const marker = writeTeamHomeMarker(target, buildTeamHomeMarker({ toolkitId, installId }));
    return { teamHome: target, created: true, explicit, marker, inspection };
  }
  if (inspection.state === "user-dsh-home") {
    throw new Error(`拒绝把 ${target} 当作 Team Home：${inspection.reason}。用户 DSH Home 只作为只读配置来源，绝不被 adopt/patch/覆盖。`);
  }
  if (inspection.state === "foreign-install") {
    throw new Error(`拒绝写入 ${target}：${inspection.reason}。它属于另一次安装；请使用本安装 manifest 记录的 install id。`);
  }
  if (inspection.state === "unowned") {
    throw new Error(`拒绝写入 ${target}：目录已存在但没有合法 Team Home marker（${inspection.reason}）。本工具绝不 adopt 无 marker 的目录。`);
  }
  throw new Error(`拒绝写入 ${target}：${inspection.reason}。`);
}

/**
 * Guard for every sync direction: user DSH Home is a read-only source, Team Home is the
 * only write target, and the two must not overlap in either direction.
 */
export function assertUserDshHomeReadOnlySource(userHome, teamHome) {
  if (!userHome) throw new Error("缺少用户 DSH Home；Team 同步必须以用户 DSH Home 为只读来源。");
  const source = resolve(userHome);
  const target = resolve(teamHome);
  if (portable(source) === portable(target)) {
    throw new Error(`用户 DSH Home 与 Team Home 是同一目录（${source}）；拒绝把配置同步到它自己。`);
  }
  if (isInside(source, target)) {
    throw new Error(`Team Home ${target} 位于用户 DSH Home ${source} 内；禁止向用户 DSH Home 写入任何内容。`);
  }
  if (isInside(target, source)) {
    throw new Error(`用户 DSH Home ${source} 位于 Team Home ${target} 内；同步方向必须单向 User DSH -> Team Home。`);
  }
  return { source, target };
}

/** True when `dir` is (or is inside) a path that a marker proves to be Toolkit-owned. */
export function isOwnedTeamHome(dir, options = {}) {
  return inspectTeamHome(dir, options).state === "owned";
}

export const teamHomeInternals = Object.freeze({
  isInside,
  readJson,
  filesystemRoot: (path) => parse(resolve(path)).root,
  realpathOrNull: (path) => { try { return realpathSync(path); } catch { return null; } },
  homedir,
});
