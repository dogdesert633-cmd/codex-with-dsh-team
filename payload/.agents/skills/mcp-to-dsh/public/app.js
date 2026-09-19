import { shouldAcceptModelProjection, modelFormSelection } from "./model-revision.js";

// DSH Team Monitor frontend.
//
// Every structure below is a view projection over the authoritative monitor data. Raw
// `runs.events`, SSE events and artifacts are never mutated or dropped here: conversation
// folding and tool-call merging only exist while rendering, so the evidence stays intact.

const runs = new Map();
const agents = new Map();
const teams = new Map();
const tasks = new Map();

const list = document.getElementById("agent-list");
const teamSummary = document.getElementById("team-summary");
const dagBody = document.getElementById("task-dag-body");
const dagMeta = document.getElementById("task-dag-meta");
const empty = document.getElementById("empty-state");
const sidebarEmpty = document.getElementById("sidebar-empty");
const detailPane = document.getElementById("detail-pane");
const agentDetail = document.getElementById("agent-detail");
const connection = document.getElementById("connection");
const connectionText = document.getElementById("connection-text");
// 单条状态栏的摘要位：Live（connection）、Agent、Task、更新时间。
const agentMetric = document.getElementById("agent-metric");
const taskMetric = document.getElementById("task-metric");
const updatedMetric = document.getElementById("updated-metric");
// 一键同步：idle / syncing / success / error 四态都在这个按钮与其 aria-live 摘要上表达。
const syncButton = document.getElementById("sync-settings");
const syncMessage = document.getElementById("sync-message");
const dagPanel = document.getElementById("task-dag-panel");
// 归档页的 DAG 面板是独立 DOM：它不复用 current 页的 #task-dag-* 节点。
const archiveDagPanel = document.getElementById("archive-task-dag-panel");
const archiveDagMeta = document.getElementById("archive-task-dag-meta");
const archiveDagBody = document.getElementById("archive-task-dag-body");
const panelCurrent = document.getElementById("panel-current");
const panelArchive = document.getElementById("panel-archive");
const panelTasks = document.getElementById("panel-tasks");
const archiveTeamList = document.getElementById("archive-team-list");
const archiveAgentList = document.getElementById("archive-agent-list");
const archiveEmpty = document.getElementById("archive-empty");
const archiveAgentEmpty = document.getElementById("archive-agent-empty");
const archivePane = document.getElementById("archive-detail-pane");
const archiveDetail = document.getElementById("archive-agent-detail");
const archiveEmptyState = document.getElementById("archive-empty-state");
const teamCards = document.getElementById("team-cards");
const taskGroups = document.getElementById("task-groups");
const tasksEmpty = document.getElementById("tasks-empty");
const modelControl = document.getElementById("model-control");
const modelCurrent = document.getElementById("model-current");
const modelForm = document.getElementById("model-form");
const modelProvider = document.getElementById("model-provider");
const modelName = document.getElementById("model-name");
const modelProviderMeta = document.getElementById("model-provider-meta");
const modelMessage = document.getElementById("model-message");
const modelFollowDefault = document.getElementById("model-follow-default");
const tabButtons = Array.from(document.querySelectorAll('[role="tab"][data-tab]'));
let renderTimer;
let modelSettings = null;

const ACTIVE_STATUSES = ["starting", "running", "cancelling"];
const SCROLL_BOTTOM_THRESHOLD = 28;
const ACTIVE_TASK_STATUSES = ["ASSIGNED", "RUNNING"];
const FAILURE_TOOL_STATUSES = ["failed", "error", "errored", "rejected", "cancelled"];
const TOOL_UPDATE_KINDS = ["tool_call", "tool_call_update"];
const MAX_TIMELINE_ITEMS = 24;
const MAX_AGENT_TASK_CHIPS = 6;
// Fixed DAG geometry: one JS model computes both the node positions and the SVG path/viewBox,
// so the layout never depends on DOM measurement. These numbers are mirrored by `.dag-col`
// (width + gap) and `.dag-node` (width/height) in styles.css.
const DAG_NODE_WIDTH = 168;
const DAG_NODE_HEIGHT = 66;
const DAG_COLUMN_GAP = 56;
const DAG_ROW_GAP = 18;
const TEAM_STATUS_ORDER = { ACTIVE: 0, AWAITING_USER_ACCEPTANCE: 1, DISSOLVED: 2 };

// Selection is frontend-only presentation state: the selected Agent never triggers
// a fetch, dispatch, session resume or Git operation.
let selectedAgentId = null;
// A second, equally presentation-only selection: the Task chip highlighted in the sidebar.
// T016 consumes `selectedTaskId` / `selectTask` / `selectedTaskView` for DAG <-> Task linking.
let selectedTaskId = null;
let renderedAgentId = null;
let renderedAgents = [];
let selectedTab = "current";
// The archive page owns a fully separate browsing state: its Team/Agent selection, its
// conversation scroll offsets and its fold overrides. Selecting an archived conversation can
// therefore never disturb the current page's selection, scroll or fold state.
let selectedArchiveTeamId = null;
let selectedArchiveAgentId = null;
let renderedArchiveAgentId = null;
// T018-F04: the SSE snapshot is the authoritative projection once it has arrived, so a bootstrap
// response that resolves later (or a stale one from an earlier call) must not overwrite it.
let snapshotApplied = false;
let bootstrapGeneration = 0;
const scrollPositions = new Map();
const archiveScrollPositions = new Map();
// 归档任务依赖图的独立状态：开合不再复用 current 页的 dagUserToggled，滚动偏移按归档 Team 分别
// 记录，所以同一 Team 的实时重渲染不跳位，切换 Team 也不会把上一个 Team 的偏移套给新 Team。
let archiveDagUserToggled = false;
let renderedArchiveDagTeamId = null;
const archiveDagScrollPositions = new Map();
// 与 currentPaneLive / archivePaneLive 同构：只有“DOM 属于本次归档 visit 且仍在屏幕上”时才允许
// 从 `.dag-scroll` 读取偏移。切离归档 tab 时复位，因此隐藏期间遗留的、没有布局盒的旧 DOM 不会被
// 当成真实位置写回（那会把已保存值覆盖成 0）。
let archiveDagLive = false;
// Fold state survives live rerenders because keys are stable (run id + block identity).
// Both maps are written only by an explicit summary activation, never by a streaming
// auto open/close, so the streaming machine cannot pollute a manual override.
const foldState = new Map();
const archiveFoldState = new Map();
// The shared conversation renderers (foldBlock/timelineHtml/detailHtml) are used by both pages,
// so the page currently being rendered selects which fold map they read.
let renderTarget = "current";
// Prompt/Reply 默认展开；Thought/Plan/Tool 与所有 Details 默认折叠。
const FOLD_DEFAULTS = { prompt: true, reply: true, thought: false, plan: false, tool: false, task: false, details: false };
// 每个块的首字类别标识：颜色由 CSS 按 fold-kind 决定，字号层级区分 Prompt/Reply/Thought/Tool。
const FOLD_MARKERS = { prompt: "P", reply: "R", thought: "T", plan: "P", tool: ">", details: "…" };
// Tool statuses that end a Tool block's streaming window. A failed Tool stays fully available
// for manual inspection but is never auto-expanded.
const TERMINAL_TOOL_STATUSES = ["completed", ...FAILURE_TOOL_STATUSES];

const phaseOrder = {
  routing: 1,
  executing: 2,
  reasoning: 2,
  tool: 2,
  responding: 2,
  finalizing: 3,
  complete: 4,
  launch_failed: 4,
  binding_mismatch: 4,
  cancel_requested: 3,
};

const phaseLabels = {
  routing: "启动 ACP",
  executing: "DSH 执行",
  reasoning: "DSH reasoning",
  tool: "DSH 工具调用",
  responding: "DSH 回复",
  finalizing: "保存证据",
  complete: "运行完成",
  launch_failed: "启动失败",
  binding_mismatch: "binding 冲突",
  cancel_requested: "正在取消",
  // Agent-status fallbacks for an Agent with no visible Run. An external (Codex-backed) Agent is
  // idle until a turn is dispatched, so the fallback must stay neutral: only a real DSH dispatch
  // phase may be labelled as DSH.
  idle: "空闲",
  completed: "已完成",
  failed: "失败",
  cancelled: "已取消",
  interrupted: "已中断",
};

const statusLabels = {
  starting: "启动中",
  running: "运行中",
  idle: "空闲",
  cancelling: "取消中",
  completed: "已完成",
  failed: "失败",
  cancelled: "已取消",
  interrupted: "已中断",
};

const taskStatusLabels = {
  BLOCKED: "阻塞",
  READY: "就绪",
  ASSIGNED: "已派发",
  RUNNING: "运行中",
  COMPLETED: "已完成",
  FAILED: "失败",
  CANCELLED: "已取消",
};

const teamStatusLabels = {
  ACTIVE: "进行中",
  AWAITING_USER_ACCEPTANCE: "等待用户验收",
  DISSOLVED: "已解散",
};

const MAX_EVENT_TEXT = 4000;

function displayText(value) {
  const text = String(value ?? "");
  return text.length > MAX_EVENT_TEXT ? `${text.slice(0, MAX_EVENT_TEXT)}\n… 页面显示已截断；完整内容保存在运行证据中。` : text;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function cssEscape(value) {
  return window.CSS && CSS.escape ? CSS.escape(String(value)) : String(value).replace(/["\\]/g, "\\$&");
}

function shortSession(value) {
  if (!value) return "等待创建";
  return value.length > 18 ? `${value.slice(0, 8)}…${value.slice(-6)}` : value;
}

function shortId(value, head = 10, tail = 4) {
  const text = String(value ?? "");
  if (!text) return "—";
  return text.length > head + tail + 1 ? `${text.slice(0, head)}…${text.slice(-tail)}` : text;
}

// The registry records which runtime actually owns an Agent: `dsh` (ACP bridge + Session),
// `codex` (a Codex child agent driven directly by the Coordinator) or another external
// backend. The UI must never describe a non-DSH Agent as a DSH ACP process, and a legacy
// payload without `backend` must not promise a Session that may not exist.
function backendView(agent) {
  const backend = typeof agent?.backend === "string" ? agent.backend.trim() : "";
  const hasSession = Boolean(agent?.sessionId);
  if (backend === "dsh") {
    return {
      key: "dsh",
      label: "DSH",
      chip: "DSH ACP",
      session: "session 等待创建",
      route: hasSession ? "DSH ACP session" : "等待 DSH session",
      ownership: "DSH ACP 外部进程，不是 Codex 子模型",
    };
  }
  if (backend === "codex") {
    return {
      key: "codex",
      label: "Codex",
      chip: "Codex child",
      session: "Codex child（无 DSH session）",
      route: "Codex child agent（无 DSH session）",
      ownership: "Codex child agent，由 Coordinator 直接驱动，不是 DSH ACP session",
    };
  }
  if (backend) {
    return {
      key: "external",
      label: "External",
      chip: `external · ${backend}`,
      session: `external · ${backend}（无 DSH session）`,
      route: `external Agent（backend ${backend}）`,
      ownership: `非 DSH external Agent（backend ${backend}），由 Coordinator 通过 Team API 驱动`,
    };
  }
  return {
    key: "unknown",
    label: "backend 未标注",
    chip: "backend 未标注",
    session: "session 未创建",
    route: hasSession ? "DSH ACP session（历史投影）" : "路由未标注",
    ownership: "历史投影未标注 backend，不推断执行路由",
  };
}

function timeLabel(value) {
  if (!value) return "--:--:--";
  return new Intl.DateTimeFormat("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(new Date(value));
}

function runTime(value) {
  const milliseconds = new Date(value || 0).getTime();
  return Number.isFinite(milliseconds) ? milliseconds : 0;
}

function laterIso(left, right) {
  if (!left) return right ?? null;
  if (!right) return left;
  return runTime(left) >= runTime(right) ? left : right;
}

// mm:ss 的唯一格式化实现：Agent 累计、Run、当前 Task 三个计时器共用一套规则（分钟位不截断）。
function formatElapsedSeconds(seconds) {
  const safe = Math.max(0, Math.floor(seconds));
  return `${String(Math.floor(safe / 60)).padStart(2, "0")}:${String(safe % 60).padStart(2, "0")}`;
}

function durationFrom(startUtc, endUtc) {
  if (!startUtc) return "--:--";
  const end = endUtc ? runTime(endUtc) : Date.now();
  return formatElapsedSeconds((end - runTime(startUtc)) / 1000);
}

function durationLabel(run) {
  return durationFrom(run.startUtc, run.endUtc);
}

function agentDurationLabel(agent) {
  return durationFrom(agent.startUtc, isActiveStatus(agent.status) ? null : agent.lastUpdatedUtc);
}

function isActiveStatus(status) {
  return ACTIVE_STATUSES.includes(status);
}

function isActive(run) {
  return isActiveStatus(run.status);
}

// True while the Agent owns an active Task record. The lookup uses the same in-memory Task
// projection that drives the sidebar chips and the DAG, so stop/retire never disagrees with the
// page. A `currentTaskId` whose Task record is missing counts as busy: a destructive retire must
// fail closed rather than guess.
function agentHasActiveTask(agent) {
  if (!agent?.currentTaskId) return false;
  const task = tasks.get(agent.currentTaskId);
  if (!task) return true;
  return ACTIVE_TASK_STATUSES.includes(task.status);
}

// --- Agent 管理动作：中止任务 / 退役 Agent -------------------------------------
//
// 只有当前 Team 页发出这些控件；归档页严格只读。pending 状态保存在 JS Map 而非 DOM，
// 因此实时重绘（SSE）不会丢失进行中的动作；反馈按 Agent 暂存并在数秒后自动清理。

const pendingAgentActions = new Map(); // `${agentId}:${action}` -> true（in-flight）
const agentActionFeedback = new Map(); // agentId -> { level, text }
const agentActionFeedbackTimers = new Map();

function setAgentActionFeedback(agentId, level, text) {
  clearTimeout(agentActionFeedbackTimers.get(agentId));
  agentActionFeedback.set(agentId, { level, text });
  agentActionFeedbackTimers.set(agentId, setTimeout(() => {
    agentActionFeedback.delete(agentId);
    agentActionFeedbackTimers.delete(agentId);
    render();
  }, 12000));
}

// pending 标志只在仍然符合事实时保留：stop 等到 Agent 不再 active，retire 等到 terminated
// 事实到达；请求失败则在自己的 catch 路径里清除。
function prunePendingAgentActions() {
  for (const key of [...pendingAgentActions.keys()]) {
    const separator = key.lastIndexOf(":");
    const agentId = key.slice(0, separator);
    const action = key.slice(separator + 1);
    const agent = renderedAgents.find((item) => item.agentId === agentId) ?? agents.get(agentId) ?? null;
    if (!agent) {
      pendingAgentActions.delete(key);
      continue;
    }
    if (action === "stop" && !isActiveStatus(agent.status) && !agent.activeRunId && !agentHasActiveTask(agent)) {
      pendingAgentActions.delete(key);
    }
    if (action === "retire" && agent.terminated) {
      pendingAgentActions.delete(key);
    }
  }
}

// active/starting/running（或有活动 Task/Run）才提供“中止任务”；cancelling 时禁用并显示处理中。
function stopButtonHtml(agent) {
  const pending = pendingAgentActions.has(`${agent.agentId}:stop`);
  const visible = pending || isActiveStatus(agent.status) || Boolean(agent.activeRunId) || agentHasActiveTask(agent);
  if (!visible) return "";
  const cancelling = agent.status === "cancelling";
  const disabled = pending || cancelling;
  const label = pending ? "中止中…" : cancelling ? "中止处理中…" : "中止任务";
  const hint = disabled
    ? "取消流程进行中；最终状态以实时投影为准"
    : "中止当前 Task 与活动 Run（带确认）";
  return `<button type="button" class="action-button danger" data-agent-action="stop" data-agent-id="${escapeHtml(agent.agentId)}"${disabled ? " disabled" : ""}${pending ? ' data-pending="true"' : ""} title="${escapeHtml(hint)}">${escapeHtml(label)}</button>`;
}

// 仅在 Team-bound、未退役、无 active Run/Task 时允许退役；active 时保留一个禁用提示而不是隐藏。
function retireButtonHtml(agent) {
  if (agent.terminated || !agent.teamId) return "";
  const pending = pendingAgentActions.has(`${agent.agentId}:retire`);
  const busy = isActiveStatus(agent.status) || Boolean(agent.activeRunId) || agentHasActiveTask(agent);
  const allowed = !busy && !pending;
  const label = pending ? "退役中…" : "退役 Agent";
  const hint = busy
    ? "Agent 仍有活动 Run 或 Task；请先“中止任务”并等待 Idle 后再退役"
    : "退役后该 Agent 从当前 Team 移入「归档对话」（带确认）";
  return `<button type="button" class="action-button" data-agent-action="retire" data-agent-id="${escapeHtml(agent.agentId)}"${allowed ? "" : " disabled"}${pending ? ' data-pending="true"' : ""} title="${escapeHtml(hint)}">${escapeHtml(label)}</button>`;
}

function agentActionsHtml(agent) {
  if (agent.terminated) return "";
  const buttons = `${stopButtonHtml(agent)}${retireButtonHtml(agent)}`;
  if (!buttons) return "";
  const feedback = agentActionFeedback.get(agent.agentId);
  const feedbackHtml = feedback
    ? `<p class="agent-action-feedback" data-level="${escapeHtml(feedback.level)}" role="status" aria-live="polite">${escapeHtml(feedback.text)}</p>`
    : "";
  return `<div class="agent-actions"><span class="agent-actions-label">操作</span>${buttons}${feedbackHtml}</div>`;
}

// 确认 → pending → PATCH →（成功等 SSE 投影 / 失败立即清除并显示错误）。请求始终携带
// 点击时刻的 expectedTaskId / expectedRunId（可为 null），陈旧页面无法误操作新 Task。
async function runAgentAction(agent, kind) {
  if (kind !== "stop" && kind !== "retire") return;
  const key = `${agent.agentId}:${kind}`;
  if (pendingAgentActions.has(key)) return;
  const label = kind === "stop" ? "中止任务" : "退役 Agent";
  const confirmed = kind === "stop"
    ? window.confirm(`确认中止 Agent ${agent.agentId} 的当前任务？活动 Run 会被取消，最终状态以实时投影为准。`)
    : window.confirm(`确认退役 Agent ${agent.agentId}？退役后它将从当前 Team 移入「归档对话」，历史 Turns 与 evidence 会保留，且不可撤销。`);
  if (!confirmed) return;
  pendingAgentActions.set(key, true);
  setAgentActionFeedback(agent.agentId, "pending", `${label}请求已发出，等待 Monitor 确认…`);
  render();
  try {
    const response = await fetch(`/api/agents/${encodeURIComponent(agent.agentId)}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: kind,
        expectedTaskId: agent.currentTaskId ?? null,
        expectedRunId: agent.activeRunId ?? null,
        reason: kind === "stop" ? "Monitor UI 手动中止" : "Monitor UI 手动退役",
      }),
    });
    const value = await response.json().catch(() => ({}));
    if (!response.ok) {
      throw new Error(typeof value?.error === "string" && value.error ? value.error : `HTTP ${response.status}`);
    }
    setAgentActionFeedback(agent.agentId, "success", `${label}已受理；最终状态以实时投影为准。`);
  } catch (error) {
    pendingAgentActions.delete(key);
    setAgentActionFeedback(agent.agentId, "error", `${label}失败：${error.message}`);
  }
  render();
}

// --- folding -----------------------------------------------------------------

function activeFoldState() {
  return renderTarget === "archive" ? archiveFoldState : foldState;
}

// Resolution order: a manual override always wins, then the streaming auto state, then the
// per-kind default. Because the auto state is recomputed from the live projection on every
// render, a streaming block collapses by itself as soon as a newer block starts or the turn
// reaches a terminal state, without ever writing to the override map.
function resolveFold(key, kind, autoExpand) {
  const override = activeFoldState().get(key);
  if (override !== undefined) return override;
  if (autoExpand) return true;
  return Boolean(FOLD_DEFAULTS[kind]);
}

// `meta` is trusted, already-escaped HTML supplied by the caller.
function foldBlock({ key, kind, label, meta = "", body, autoExpand = false, streaming = false, failed = false }) {
  const open = resolveFold(key, kind, autoExpand);
  const metaHtml = meta ? `<span class="fold-meta">${meta}</span>` : "";
  // 类别首字标识：每个块保留一个彩色的类型字母（Prompt/Reply/Thought/Plan/Tool/Details），
  // 具体颜色与字号层级由 styles.css 按 `.fold-<kind>` 决定。
  const marker = FOLD_MARKERS[kind] ?? "•";
  // A low-key streaming hint replaces the old static expansion note: a terminal block stays silent.
  const streamHtml = streaming ? `<span class="fold-stream" title="该块仍在流式输出">输出中</span>` : "";
  return `<details class="fold fold-${kind}" data-fold-key="${escapeHtml(key)}" data-fold-streaming="${streaming}"${failed ? ' data-fold-failed="true"' : ""}${open ? " open" : ""}>
      <summary><span class="fold-chevron" aria-hidden="true"></span><span class="fold-marker" aria-hidden="true">${escapeHtml(marker)}</span><span class="fold-label">${escapeHtml(label)}</span>${metaHtml}${streamHtml}</summary>
      <div class="fold-body">${body}</div>
    </details>`;
}

// Only an explicit activation of a summary records an override. The `toggle` event is
// deliberately not used: it also fires for state the streaming machine derives, and honouring
// that would freeze an automatic expansion into a permanent manual choice.
function foldDetailsOf(target) {
  if (!target || typeof target.closest !== "function") return null;
  const summary = target.closest("summary");
  const details = summary?.parentElement ?? null;
  if (!details || details.tagName !== "DETAILS" || !details.dataset.foldKey) return null;
  return details;
}

document.addEventListener("click", (event) => {
  const details = foldDetailsOf(event.target);
  if (!details) return;
  // The browser flips `open` as the default action after this handler, so the recorded
  // override is the state the user is asking for.
  const map = details.closest("#panel-archive") ? archiveFoldState : foldState;
  map.set(details.dataset.foldKey, !details.open);
}, true);

// --- agent state projection ---------------------------------------------------

// The monitor exposes the vNext `state` (RUNNING/IDLE). Activity always wins, but the IDLE
// projection must not swallow `failed`/`interrupted` (Recovering) or a legacy payload
// (Fallback); only a genuinely plain Agent falls through to Idle.
function agentStateView(agent) {
  if (agent?.state === "RUNNING" || isActiveStatus(agent?.status)) return { key: "running", label: "Running" };
  if (agent?.status === "failed" || agent?.status === "interrupted") return { key: "recovering", label: "Recovering" };
  if (agent?.legacy) return { key: "fallback", label: "Fallback" };
  return { key: "idle", label: "Idle" };
}

function agentGroups() {
  const grouped = new Map();
  for (const run of runs.values()) {
    if (!run.agentId) continue;
    if (!grouped.has(run.agentId)) grouped.set(run.agentId, []);
    grouped.get(run.agentId).push(run);
  }
  for (const agentId of agents.keys()) {
    if (!grouped.has(agentId)) grouped.set(agentId, []);
  }

  const values = [];
  const seen = new Set();
  for (const [agentId, agentRuns] of grouped) {
    seen.add(agentId);
    agentRuns.sort((left, right) => (left.turnIndex ?? 0) - (right.turnIndex ?? 0) || runTime(left.startUtc) - runTime(right.startUtc));
    const meta = agents.get(agentId) ?? null;
    const latest = agentRuns.at(-1) ?? null;
    const activeRun = agentRuns.find(isActive) ?? null;
    values.push({
      agentId,
      formalRole: meta?.formalRole ?? latest?.formalRole ?? latest?.role ?? "legacy",
      status: activeRun ? (activeRun.status === "starting" ? "starting" : activeRun.status) : (latest?.status ?? meta?.status ?? "interrupted"),
      legacy: Boolean(meta?.legacy),
      state: meta?.state ?? null,
      teamId: meta?.teamId ?? latest?.teamId ?? null,
      currentTaskId: meta?.currentTaskId ?? null,
      sessionId: meta?.sessionId ?? latest?.sessionId ?? null,
      // 退役事实与执行路由透传：terminated 是终态事实，归档页必须仍能找到这些 Agent。
      terminated: Boolean(meta?.terminated),
      terminatedAt: meta?.terminatedAt ?? null,
      terminationReason: meta?.terminationReason ?? null,
      backend: meta?.backend ?? null,
      // Runs win when present; the Agent projection exposes `startUtc`/`lastUpdatedUtc`, so a
      // registry-only Agent still yields a real timestamp instead of a `--:--` elapsed label.
      startUtc: agentRuns[0]?.startUtc ?? meta?.startUtc ?? null,
      lastUpdatedUtc: agentRuns.reduce((accumulator, run) => laterIso(accumulator, run.endUtc || run.startUtc), meta?.lastUpdatedUtc ?? null),
      activeRunId: activeRun?.id ?? null,
      latestTaskId: latest?.taskId ?? null,
      latestTitle: latest?.title ?? null,
      turnCount: meta?.turnCount ?? agentRuns.length,
      turns: agentRuns,
    });
  }
  for (const agentId of agents.keys()) {
    if (seen.has(agentId)) continue;
    const meta = agents.get(agentId);
    values.push({
      agentId,
      formalRole: meta?.formalRole ?? "legacy",
      status: meta?.status ?? "interrupted",
      legacy: Boolean(meta?.legacy),
      state: meta?.state ?? null,
      teamId: meta?.teamId ?? null,
      currentTaskId: meta?.currentTaskId ?? null,
      sessionId: meta?.sessionId ?? null,
      terminated: Boolean(meta?.terminated),
      terminatedAt: meta?.terminatedAt ?? null,
      terminationReason: meta?.terminationReason ?? null,
      backend: meta?.backend ?? null,
      startUtc: meta?.startUtc ?? null,
      lastUpdatedUtc: meta?.lastUpdatedUtc ?? null,
      activeRunId: null,
      latestTaskId: null,
      latestTitle: null,
      turnCount: meta?.turnCount ?? 0,
      turns: [],
    });
  }
  values.sort(compareAgentViews);
  return values;
}

function compareAgentViews(left, right) {
  const activeDelta = Number(isActiveStatus(right.status)) - Number(isActiveStatus(left.status));
  if (activeDelta !== 0) return activeDelta;
  const timeDelta = runTime(right.lastUpdatedUtc) - runTime(left.lastUpdatedUtc);
  if (timeDelta !== 0) return timeDelta;
  return String(left.agentId).localeCompare(String(right.agentId));
}

// --- conversation timeline projection ----------------------------------------

function toolFailureStatus(update) {
  return FAILURE_TOOL_STATUSES.includes(String(update?.status ?? "").toLowerCase());
}

// Only explicit status values or a structured error count as failure. Plain successful
// output that merely contains the word "error" must stay collapsed and green.
function toolHasStructuredError(update) {
  if (!update || typeof update !== "object") return false;
  if (update.error) return true;
  if (Array.isArray(update.content)) {
    return update.content.some((entry) => entry?.type === "error" || entry?.content?.type === "error");
  }
  return Boolean(update.rawOutput && typeof update.rawOutput === "object" && update.rawOutput.error);
}

function toolIsFailed(item) {
  return item.failedStatus === true || item.failedStructured === true;
}

function toolFailureReason(update) {
  if (typeof update?.error === "string" && update.error) return update.error;
  if (update?.error && typeof update.error === "object") return update.error.message ?? JSON.stringify(update.error);
  if (toolHasStructuredError(update) && Array.isArray(update?.content)) {
    const entry = update.content.find((item) => item?.type === "error" || item?.content?.type === "error");
    const text = entry?.text ?? entry?.content?.text ?? entry?.content?.content?.text;
    if (text) return String(text);
  }
  if (toolFailureStatus(update)) return `status: ${update.status}`;
  return null;
}

function toolContentText(update) {
  const parts = [];
  if (Array.isArray(update?.content)) {
    for (const entry of update.content) {
      const text = entry?.text ?? entry?.content?.text;
      if (typeof text === "string" && text) parts.push(text);
    }
  }
  if (typeof update?.rawOutput === "string" && update.rawOutput) parts.push(update.rawOutput);
  return displayText(parts.join("\n"));
}

function toolTitle(update) {
  if (typeof update?.title === "string" && update.title) return update.title;
  if (typeof update?.kind === "string" && update.kind) return update.kind;
  return "tool";
}

function createToolItem(eventIndex, event, update, toolCallId) {
  return {
    kind: "tool",
    toolCallId,
    fallbackOpen: toolCallId === null,
    eventIndex,
    label: "Tool",
    ts: event?.ts,
    title: toolTitle(update),
    status: update?.status ?? null,
    updateCount: 1,
    content: toolContentText(update),
    failedStatus: toolFailureStatus(update),
    failedStructured: toolHasStructuredError(update),
    failureReason: toolFailureReason(update),
  };
}

function mergeToolItem(item, event, update) {
  item.ts = event?.ts ?? item.ts;
  item.updateCount += 1;
  if (update?.status) item.status = update.status;
  if (update?.title || update?.kind) item.title = toolTitle(update);
  const extra = toolContentText(update);
  if (extra) item.content = item.content ? `${item.content}\n${extra}` : extra;
  if (toolFailureStatus(update)) item.failedStatus = true;
  if (toolHasStructuredError(update)) item.failedStructured = true;
  const reason = toolFailureReason(update);
  if (reason) item.failureReason = reason;
}

// Tool calls merge only with the immediately preceding block, only inside one Turn, and
// only when the `toolCallId` matches. Without an id, merging requires the previous block
// to be an id-less tool call that is still the adjacent item, which keeps unrelated tools
// from ever collapsing into one another.
function timeline(events) {
  const items = [];
  for (let index = 0; index < (events || []).length; index += 1) {
    const event = events[index];
    const update = event?.kind === "session_update" ? (event.update ?? {}) : null;
    if (update && TOOL_UPDATE_KINDS.includes(update.sessionUpdate)) {
      const toolCallId = typeof update.toolCallId === "string" && update.toolCallId ? update.toolCallId : null;
      const previous = items.at(-1);
      const mergeable = previous?.kind === "tool"
        && (toolCallId
          ? previous.toolCallId === toolCallId
          : previous.toolCallId === null && previous.fallbackOpen);
      if (mergeable) {
        mergeToolItem(previous, event, update);
        continue;
      }
      const item = createToolItem(index, event, update, toolCallId);
      items.push(item);
      continue;
    }

    const view = eventView(event);
    if (!view || !view.text) continue;
    const previous = items.at(-1);
    if (previous?.kind === view.kind && previous.label === view.label) {
      previous.text = displayText(previous.text + view.text);
      previous.ts = event.ts;
      previous.fallbackOpen = false;
    } else {
      items.push({ ...view, text: displayText(view.text), ts: event.ts, eventIndex: index, fallbackOpen: false });
    }
  }
  return items.slice(-MAX_TIMELINE_ITEMS);
}

function eventView(event) {
  if (!event || typeof event !== "object") return null;
  switch (event.kind) {
    case "initialized":
      return { kind: "system", label: "ACP", text: "ACP 连接已初始化" };
    case "session_created":
      return { kind: "system", label: "Session", text: `新 session：${event.sessionId ?? "未知"}` };
    case "session_resumed":
      return { kind: "system", label: "Session", text: `resume session：${event.sessionId ?? "未知"}` };
    case "delegated_prompt":
      return { kind: "system", label: "CODEX", text: event.text ? displayText(event.text) : "已发送委派指令" };
    case "turn_stop":
      return { kind: "system", label: "Turn", text: `turn 结束：${event.response?.stopReason ?? "stop"}` };
    case "cancel_requested":
      return { kind: "system", label: "Cancel", text: "已请求取消当前 turn" };
    case "session_update": {
      const update = event.update ?? {};
      if (update.sessionUpdate === "agent_thought_chunk") {
        return { kind: "thought", label: "Thought", text: update.content?.text ?? "" };
      }
      if (update.sessionUpdate === "agent_message_chunk") {
        return { kind: "reply", label: "Reply", text: update.content?.text ?? "" };
      }
      if (update.sessionUpdate === "plan") {
        const entries = Array.isArray(update.entries) ? update.entries : [];
        const text = entries
          .map((entry) => `${entry.status ? `[${entry.status}] ` : ""}${entry.content ?? ""}`)
          .join("\n");
        return { kind: "plan", label: "Plan", text };
      }
      return null;
    }
    default:
      return null;
  }
}

function timelineHtml(run, items) {
  // Streaming window: only the live turn's newest block may auto-expand. The moment a newer
  // block appears this flips to false and the previous block collapses on the next render.
  const turnActive = isActive(run);
  const blocks = items.map((item, index) => {
    const streaming = turnActive && index === items.length - 1;
    if (item.kind === "system") {
      return `<div class="event" data-kind="system">
        <time class="event-time">${escapeHtml(timeLabel(item.ts))}</time>
        <span class="event-kind">${escapeHtml(item.label)}</span>
        <span class="event-copy">${escapeHtml(item.text)}</span>
      </div>`;
    }
    if (item.kind === "tool") {
      // The first event index keeps the fold key unique and stable even when the same
      // toolCallId shows up in two non-adjacent blocks.
      const key = `${run.id}:tool:${item.toolCallId ?? "fallback"}:${item.eventIndex}`;
      const failed = toolIsFailed(item);
      const status = item.status ?? "in_progress";
      // A Tool auto-expands only while it is the live streaming tail and not yet terminal.
      // completed/failed/error/rejected/cancelled all collapse immediately, and a failed Tool
      // keeps its full body available for manual inspection instead of opening itself.
      const toolStreaming = streaming && !TERMINAL_TOOL_STATUSES.includes(status) && !failed;
      const meta = [
        escapeHtml(shortSession(item.title)),
        escapeHtml(status),
        item.updateCount > 1 ? `${item.updateCount} updates` : null,
      ].filter(Boolean).join(" · ");
      const body = [
        item.content ? `<pre class="event-pre">${escapeHtml(item.content)}</pre>` : `<p class="fold-hint">该 tool 事件没有文本内容。</p>`,
        item.failureReason ? `<p class="fold-failure">失败原因：${escapeHtml(item.failureReason)}</p>` : "",
      ].join("");
      return foldBlock({ key, kind: "tool", label: "Tool", meta, body, autoExpand: toolStreaming, streaming: toolStreaming, failed });
    }
    if (item.kind === "thought") {
      const key = `${run.id}:thought:${item.eventIndex}`;
      return foldBlock({
        key,
        kind: "thought",
        label: "Thought",
        meta: "DSH 公开 summary · 非隐藏 CoT",
        body: `<pre class="event-pre">${escapeHtml(item.text)}</pre>`,
        // Only the live turn's tail Thought streams open; a later block or a terminal turn
        // collapses it again.
        autoExpand: streaming,
        streaming,
      });
    }
    if (item.kind === "plan") {
      const key = `${run.id}:plan:${item.eventIndex}`;
      return foldBlock({ key, kind: "plan", label: "Plan", body: `<pre class="event-pre">${escapeHtml(item.text)}</pre>`, streaming });
    }
    const key = `${run.id}:reply:${item.eventIndex}`;
    return foldBlock({
      key,
      kind: "reply",
      label: "Reply",
      meta: escapeHtml(timeLabel(item.ts)),
      body: `<pre class="event-pre">${escapeHtml(item.text)}</pre>`,
      streaming,
    });
  });
  if (blocks.length === 0) {
    return `<p class="turn-empty">${isActive(run) ? "等待 DSH 事件…" : "该 turn 没有可投影的对话事件（原始 events 仍保存在运行证据中）。"}</p>`;
  }
  return blocks.join("");
}

// --- agent rendering ---------------------------------------------------------

// The prompt is read back from the durable `delegated_prompt` event, never re-sent.
function delegatedPrompt(run) {
  return (run.events || []).find((event) => event.kind === "delegated_prompt")?.text || "指令正在写入 DSH session…";
}

// Route/Git/exit proof, unchanged in meaning from the previous monitor UI. A Turn only exists
// for a dispatched run, so the transport is the DSH ACP bridge; when the owning Agent declares
// another backend the proof states both facts instead of relabelling the Agent as DSH.
function runEvidence(run, agent) {
  const summary = run.summary || {};
  const status = summary.git_status_short?.trim();
  const stateChanged = summary.git_state_changed ?? (
    summary.git_before_status_short !== undefined
    && (
      summary.git_before_status_short !== summary.git_status_short
      || summary.git_before_untracked !== summary.git_untracked
      || summary.git_before_diff_numstat !== summary.git_diff_numstat
    )
  );
  let git = "运行中";
  if (run.status === "completed" || run.status === "cancelled" || run.status === "failed") {
    git = stateChanged ? "运行前后 Git 状态有变化" : "运行前后无 Git 变化";
  }
  const owner = agent ?? agents.get(run.agentId) ?? null;
  const backend = backendView(owner);
  const transport = run.sessionId ? "DSH ACP session" : "等待 DSH session";
  return {
    route: backend.key === "dsh" || backend.key === "unknown"
      ? transport
      : `${transport}（agent backend ${backend.label}）`,
    backend: backend.chip,
    git,
    workspace: status || "工作区 clean",
    exit: run.exitCode === null || run.exitCode === undefined ? "运行中" : String(run.exitCode),
  };
}

function evidenceHtml(run, agent) {
  const proof = runEvidence(run, agent);
  return `<div class="evidence">
    <div><span>真实执行路由</span><strong>${escapeHtml(proof.route)}</strong><small>${escapeHtml(proof.backend)}</small></div>
    <div><span>本次运行前后</span><strong>${escapeHtml(proof.git)}</strong><small>${escapeHtml(proof.workspace)}</small></div>
    <div><span>DSH bridge exit</span><strong>${escapeHtml(proof.exit)}</strong></div>
  </div>`;
}

function roleInitial(role) {
  return String(role ?? "A").replace(/[^A-Za-z0-9]/g, "").slice(0, 1).toUpperCase() || "A";
}

// --- sidebar Task attribution projection (Agent -> participating Tasks) --------
// Everything below is derived from the in-memory `teams`/`tasks`/`runs` projections that
// already arrive through the snapshot and SSE. No extra request is ever issued here.

// The two participation kinds a Task can have with an Agent. They must stay distinguishable:
// an owner chip describes the current ownerAgentId, a history chip only records a durable
// Attempt by this Agent on a Task that has since been reassigned elsewhere.
const TASK_PARTICIPATION_OWNER = "owner";
const TASK_PARTICIPATION_HISTORY = "history";

// Participation is ownership OR a durable Attempt by this Agent (`attempts[].agentId`). Same
// taskId is counted once because the source is the taskId-keyed `tasks` map, not a run list.
function taskParticipationOf(task, agentId) {
  if (!task || !agentId) return null;
  const ownsTask = task.ownerAgentId === agentId;
  const attemptedTask = (Array.isArray(task.attempts) ? task.attempts : [])
    .some((attempt) => attempt?.agentId === agentId);
  if (!ownsTask && !attemptedTask) return null;
  return ownsTask ? TASK_PARTICIPATION_OWNER : TASK_PARTICIPATION_HISTORY;
}

// Team scope is exact: `task.teamId === teamId`. A null/empty selection is NOT "all Teams" and
// the UNASSIGNED sentinel matches no real Task, so an unowned Team can never surface another
// Team's work (and an archived Team's Task can never leak back into the current page).
function tasksForAgent(agentId, teamId) {
  if (!agentId || !teamId) return [];
  return [...tasks.values()].filter((task) => task?.teamId === teamId && taskParticipationOf(task, agentId) !== null);
}

// current Task first, then owned active work, then owned leftovers, then history-only.
function agentTaskRank(task, currentTaskId, participation = null) {
  if (currentTaskId && task.taskId === currentTaskId) return 0;
  if (participation === TASK_PARTICIPATION_OWNER) return ACTIVE_TASK_STATUSES.includes(task.status) ? 1 : 2;
  return 3;
}

function sortedAgentTasks(agent, teamId = null) {
  const agentId = agent?.agentId ?? null;
  const currentTaskId = agent?.currentTaskId ?? null;
  return tasksForAgent(agentId, teamId).sort((left, right) => {
    const rankDelta = agentTaskRank(left, currentTaskId, taskParticipationOf(left, agentId))
      - agentTaskRank(right, currentTaskId, taskParticipationOf(right, agentId));
    if (rankDelta !== 0) return rankDelta;
    const timeDelta = runTime(right.updatedAt ?? right.createdAt) - runTime(left.updatedAt ?? left.createdAt);
    if (timeDelta !== 0) return timeDelta;
    return String(left.taskId).localeCompare(String(right.taskId));
  });
}

// 完成数按“这个 Agent 自己”的 Attempt 记，绝不按 Task 终态记：只有自己名下的 Attempt
// 存在 COMPLETED 才算完成；Task 终态只在完全没有 Attempt 的 legacy owner 上作显式降级，
// 因此另一个 Agent 的成功永远不会被算到旧 Agent 头上。
function agentCompletedTaskCount(agentId, agentTasks) {
  if (!agentId) return 0;
  return agentTasks.filter((task) => {
    const attempts = Array.isArray(task.attempts) ? task.attempts : [];
    const ownAttempts = attempts.filter((attempt) => attempt?.agentId === agentId);
    if (ownAttempts.length > 0) return ownAttempts.some((attempt) => attempt.status === "COMPLETED");
    return attempts.length === 0 && task.ownerAgentId === agentId && task.status === "COMPLETED";
  }).length;
}

// Team-scoped reuse: only this Agent's own turns carrying this exact Team and a `follow_up`
// lifecycle action. `turnCount` is a lifetime number and is never substituted for a Team value.
function agentTeamReuseCount(agent, teamId) {
  if (!teamId) return 0;
  return (Array.isArray(agent?.turns) ? agent.turns : [])
    .filter((turn) => turn?.teamId === teamId && turn?.lifecycleAction === "follow_up").length;
}

// External Codex / no-session Agents have no DSH Team-scoped turn at all; they must show `—`
// instead of a lifetime count that would misrepresent Team reuse as a real measurement.
function agentReuseView(agent, teamId) {
  const backend = backendView(agent);
  const dshOwned = backend.key === "dsh" || (backend.key === "unknown" && Boolean(agent?.sessionId));
  if (!dshOwned) {
    return {
      count: null,
      label: "—",
      available: false,
      title: `${backend.chip} 没有 DSH session，因此没有 Team-scoped follow_up turn；此处不复用 lifetime turnCount 冒充 Team 复用值。`,
    };
  }
  const count = agentTeamReuseCount(agent, teamId);
  return {
    count,
    label: String(count),
    available: true,
    title: `同一 DSH Agent/Session 在本 Team（${teamId ?? "未选择"}）内的 Team-scoped follow_up turn 次数。`,
  };
}

function agentTaskStats(agent, teamId, agentTasks = sortedAgentTasks(agent, teamId)) {
  return {
    participated: agentTasks.length,
    completed: agentCompletedTaskCount(agent?.agentId ?? null, agentTasks),
    reuse: agentReuseView(agent, teamId),
  };
}

// Stable chip presentation for a Task status; shared by the sidebar chips and (T016) the DAG.
function taskChipStatusView(status) {
  const key = typeof status === "string" && status ? status : "UNKNOWN";
  return { key, label: taskStatusLabels[key] ?? key, active: ACTIVE_TASK_STATUSES.includes(key) };
}

// Single entry point for the Task selection so T016 can reuse it without touching the DOM.
function selectTask(taskId) {
  selectedTaskId = typeof taskId === "string" && tasks.has(taskId) ? taskId : null;
  render();
}

function selectedTaskView() {
  return selectedTaskId ? tasks.get(selectedTaskId) ?? null : null;
}

// The archive page and the sidebar render task chips as plain markers: no selection affordance
// and no way for an archived conversation to change the current page's Task selection. A static
// chip never carries `data-task-id`; `data-participation` only records owner vs history-only.
function taskChipHtml(task, readOnly = false, participation = null) {
  const view = taskChipStatusView(task.status);
  const title = task.title ?? task.taskId;
  const participationAttr = participation ? ` data-participation="${escapeHtml(participation)}"` : "";
  if (readOnly) {
    return `<span class="task-chip task-chip-static" data-task-status="${escapeHtml(view.key)}"${participationAttr} title="${escapeHtml(`${task.taskId} · ${title}`)}"><code>${escapeHtml(task.taskId)}</code><span class="task-chip-status">${escapeHtml(view.label)}</span></span>`;
  }
  const selected = task.taskId === selectedTaskId;
  return `<button type="button" class="task-chip" data-task-id="${escapeHtml(task.taskId)}" data-task-status="${escapeHtml(view.key)}"${participationAttr} aria-pressed="${selected}" title="${escapeHtml(`${task.taskId} · ${title}`)}" aria-label="${escapeHtml(`Task ${task.taskId}，${view.label}：${title}`)}"><code>${escapeHtml(task.taskId)}</code><span class="task-chip-status">${escapeHtml(view.label)}</span></button>`;
}

// `showStats` adds the sidebar attribution line 参与/完成/复用; `omitWhenEmpty` keeps an Agent
// with no participating Task from rendering an empty block in the compact sidebar, while the
// default (Details) call keeps its existing empty state and interactive current chips intact.
function agentTasksHtml(agent, { teamId = null, readOnly = false, omitWhenEmpty = false, showStats = false } = {}) {
  const agentTasks = sortedAgentTasks(agent, teamId);
  if (agentTasks.length === 0) {
    return omitWhenEmpty ? "" : `<div class="nav-tasks"><p class="nav-tasks-empty">暂无 assigned Task</p></div>`;
  }
  const stats = agentTaskStats(agent, teamId, agentTasks);
  const shown = agentTasks.slice(0, MAX_AGENT_TASK_CHIPS);
  const hidden = agentTasks.slice(MAX_AGENT_TASK_CHIPS);
  const more = hidden.length > 0
    ? `<span class="task-chip-more" title="${escapeHtml(`另有 ${hidden.length} 个 Task：${hidden.map((task) => task.taskId).join("、")}`)}">+${hidden.length}</span>`
    : "";
  const head = showStats
    ? `<p class="nav-tasks-head">
      <span class="nav-tasks-stat">参与 <strong>${escapeHtml(String(stats.participated))}</strong></span>
      <span class="nav-tasks-stat">完成 <strong>${escapeHtml(String(stats.completed))}</strong></span>
      <span class="nav-tasks-stat" title="${escapeHtml(stats.reuse.title)}">复用 <strong>${escapeHtml(stats.reuse.label)}</strong></span>
    </p>`
    : `<p class="nav-tasks-head"><span>assigned Tasks</span><span class="nav-tasks-count">${stats.completed}/${agentTasks.length} completed</span></p>`;
  return `<div class="nav-tasks">
    ${head}
    <div class="task-chips">${shown.map((task) => taskChipHtml(task, readOnly, taskParticipationOf(task, agent?.agentId))).join("")}${more}</div>
  </div>`;
}

// The card visual lives on the wrapper so the Task chips stay valid, focusable buttons
// instead of becoming interactive content nested inside the Agent card button.
// 紧凑左栏项：一个 Agent 就是一张卡片 + 其 Task 归因块。Task 汇总位于 `.nav-card` button 之后、
// 仍属于同一个 `.nav-item`，因此 chip 始终是并列的静态只读标记，不会被嵌套进 Agent button。
function navItemHtml(agent, { selectedId = selectedAgentId, teamId = null } = {}) {
  return `<div class="nav-item" data-nav-agent-id="${escapeHtml(agent.agentId)}" data-selected="${agent.agentId === selectedId}">
    ${navCardHtml(agent, selectedId)}
    ${agentTasksHtml(agent, { teamId, readOnly: true, omitWhenEmpty: true, showStats: true })}
  </div>`;
}

// --- sidebar Team summary ------------------------------------------------------

// --- Team classification: current page vs archive page -------------------------
//
// `archivedAt` is the authoritative soft-archive fact (T027). A DISSOLVED Team is terminal, and
// any Team that is not the current one is history the archive page owns. The current page is
// therefore driven by the data, never by what the user happens to be browsing.

function teamIsArchived(team) {
  return Boolean(team?.archivedAt);
}

// The current Team is the newest Team that is neither soft-archived nor DISSOLVED.
function currentTeamOf() {
  return [...teams.values()]
    .filter((team) => !teamIsArchived(team) && team.status !== "DISSOLVED")
    .sort((left, right) => runTime(right.createdAt) - runTime(left.createdAt) || String(left.teamId).localeCompare(String(right.teamId)))[0] ?? null;
}

// Pseudo-Team that owns legacy Agents without any Team binding. They must never mix back into
// the current page.
const UNASSIGNED_TEAM_ID = "__unassigned";

function archiveTeamView(team) {
  if (teamIsArchived(team)) return { key: "archived", label: "已归档", meta: team.archivedAt };
  if (team.status === "DISSOLVED") return { key: "dissolved", label: "已解散", meta: team.updatedAt };
  return { key: "previous", label: "旧团队", meta: team.updatedAt };
}

// Every Team except the current one, plus the unassigned-legacy pseudo entry. The list reuses the
// documented Team status order (still-live → awaiting acceptance → DISSOLVED) and, inside one
// status, reads oldest-first like the history it is; the unassigned legacy Agents come last.
function archiveTeamEntries() {
  const current = currentTeamOf();
  const entries = [...teams.values()]
    .filter((team) => team.teamId !== current?.teamId)
    .sort(compareTeams)
    .map((team) => ({ teamId: team.teamId, team, taskCount: teamTasksOf(team.teamId).length }));
  // 当前 Team 的退役成员入口：只放 retired members，不能把当前 Team 的活跃成员重复放入归档页。
  if (current) {
    const retired = renderedAgents.filter((agent) => agent.teamId === current.teamId && agent.terminated);
    if (retired.length > 0) {
      entries.unshift({
        teamId: current.teamId,
        team: { teamId: current.teamId, title: `${current.title ?? current.teamId} · 已退役 Agent`, status: "RETIRED", archivedAt: null },
        taskCount: teamTasksOf(current.teamId).length,
        retiredOnly: true,
        retiredCount: retired.length,
      });
    }
  }
  const unassigned = renderedAgents.filter((agent) => !agent.teamId).length;
  if (unassigned > 0) {
    entries.push({
      teamId: UNASSIGNED_TEAM_ID,
      team: { teamId: UNASSIGNED_TEAM_ID, title: "未归属历史", status: "LEGACY", archivedAt: null },
      taskCount: 0,
      unassigned: true,
    });
  }
  return entries;
}

// `entry` 是 archiveTeamEntries() 的一项：未归属历史与“当前 Team · 已退役 Agent”入口都要各自
// 过滤成员列表，保证归档页绝不重复当前 Team 的活跃成员。
function archiveAgentsOf(entry) {
  if (!entry?.teamId) return [];
  if (entry.teamId === UNASSIGNED_TEAM_ID) return renderedAgents.filter((agent) => !agent.teamId);
  if (entry.retiredOnly) return renderedAgents.filter((agent) => agent.teamId === entry.teamId && agent.terminated);
  return renderedAgents.filter((agent) => agent.teamId === entry.teamId);
}

// The current page always describes the current Team: the current/archive split is a data fact,
// not a browsing choice. A degraded orphan Team is still rendered so no projection disappears.
// T032-R1: only a Task whose Team record is entirely absent may build that degraded context. A
// Task that points at a Team which exists but is archived or DISSOLVED is history, so the current
// page returns null (sidebar/detail/Tasks/DAG all show their empty state) and the Team stays on
// the archive page; otherwise archived work would silently flow back into the current view.
function currentTeamContext() {
  const team = currentTeamOf();
  if (team) return { team, degraded: false };
  const orphanTeamId = [...new Set([...tasks.values()].map((task) => task.teamId).filter(Boolean))]
    .find((teamId) => !teams.has(teamId));
  if (orphanTeamId) return { team: { teamId: orphanTeamId, title: orphanTeamId, status: "ACTIVE", degraded: true }, degraded: true };
  return null;
}

// Shared "current Team" projection used by both the sidebar summary and the Task DAG:
// the Task set is never filtered by status or owner, so no Task can disappear from the view.
function teamTasksOf(teamId) {
  return [...tasks.values()].filter((task) => task.teamId === teamId);
}

function teamTaskStats(teamTasks) {
  return {
    total: teamTasks.length,
    completed: teamTasks.filter((task) => task.status === "COMPLETED").length,
    active: teamTasks.filter((task) => ACTIVE_TASK_STATUSES.includes(task.status)).length,
    blocked: teamTasks.filter((task) => task.status === "BLOCKED").length,
    failed: teamTasks.filter((task) => task.status === "FAILED" || task.status === "CANCELLED").length,
  };
}

function teamSummaryHtml(views) {
  const context = currentTeamContext();
  if (!context) return `<p class="team-summary-empty">暂无 Team 投影</p>`;
  const { team, degraded } = context;
  const teamTasks = teamTasksOf(team.teamId);
  const { completed, active, blocked, failed } = teamTaskStats(teamTasks);
  const members = views.filter((agent) => agent.teamId === team.teamId && !agent.terminated).length;
  const segments = teamTasks.slice(0, 20)
    .map((task) => `<span class="progress-seg" data-done="${task.status === "COMPLETED"}"></span>`)
    .join("");
  return `<section class="team-summary-card" data-team-id="${escapeHtml(team.teamId)}" data-team-status="${escapeHtml(team.status)}"${degraded ? ' data-degraded="true"' : ""}>
    <header class="team-summary-head">
      <h3 title="${escapeHtml(team.title ?? team.teamId)}">${escapeHtml(team.title ?? team.teamId)}</h3>
      <span class="team-status" data-team-status="${escapeHtml(team.status)}">${escapeHtml(teamStatusLabels[team.status] ?? team.status)}</span>
    </header>
    <div class="team-progress" role="progressbar" aria-valuemin="0" aria-valuemax="${teamTasks.length}" aria-valuenow="${completed}" aria-label="${escapeHtml(team.teamId)} 完成进度">
      <span class="progress-track">${segments || `<span class="progress-seg" data-done="false"></span>`}</span>
      <span class="progress-count">${completed} / ${teamTasks.length} 完成</span>
    </div>
    <p class="team-summary-legend">成员 ${members} · 运行 ${active} · 阻塞 ${blocked} · 未完成终态 ${failed}</p>
  </section>`;
}

// Launch evidence（A.3）：Model / Reasoning 只承认该 Agent 最新 run 的真实启动证据。
//   1) `effectiveModelSelection` —— session_model_configured 已由 DSH 确认的实际选择；
//   2) 其次才是 session config 报告的 `run.model`（可能是 [provider, model] JSON 或裸字符串）；
// 只有 requested / pending 的选择绝不当作最终值显示（那属于 Details 里的诊断字段）。
// 没有证据时明确显示 `Model —` / `Reasoning —`，不按角色、Team 或默认值猜测。
function launchEvidenceView(run) {
  const effective = run?.effectiveModelSelection;
  const hasEffective = typeof effective?.provider === "string" && typeof effective?.model === "string";
  let model = hasEffective ? `${effective.provider} / ${effective.model}` : null;
  if (!model && typeof run?.model === "string" && run.model.trim()) {
    const reported = run.model.trim();
    try {
      const pair = JSON.parse(reported);
      if (Array.isArray(pair) && typeof pair[0] === "string" && typeof pair[1] === "string") {
        model = `${pair[0]} / ${pair[1]}`;
      }
    } catch {
      model = reported;
    }
  }
  const reasoning = typeof run?.reasoningEffort === "string" && run.reasoningEffort.trim()
    ? run.reasoningEffort.trim()
    : null;
  return {
    model,
    reasoning,
    source: hasEffective ? "effective" : (model ? "session-config" : null),
  };
}

function launchEvidenceLabel(run) {
  const view = launchEvidenceView(run);
  return `Model ${view.model ?? "—"} · Reasoning ${view.reasoning ?? "—"}`;
}

// --- 当前 Task 用时（纯投影，无 DOM / 无网络 / 可注入 nowMs） -------------------
//
// 这是一个与「Agent 累计运行时间」（data-agent-elapsed = agent.startUtc → now/lastUpdatedUtc）
// 完全独立的数字：只描述 currentTaskId 指向的那个 Task 的「当前 Attempt」用了多久。
// 绝不用 Agent 创建时间、lifetime turn 或上一个 Task 的用时兜底。
const TASK_TIMER_STATES = Object.freeze({ LIVE: "live", TERMINAL: "terminal", UNKNOWN: "unknown" });

// 当前 attempt 的唯一口径与 taskProgress 保持一致：task.attemptId 对齐 attempts[]，绝不取
// attempts.at(-1)（历史/重试 attempt 可能更晚写入）。fenced 的 attempt 永不等于 task.attemptId
// （服务端保证），这里仍显式排除以防御 legacy 载荷。
function currentTaskAttempt(task) {
  if (!task) return null;
  const attempt = taskProgress(task).current;
  if (!attempt || attempt.fenced === true) return null;
  return attempt;
}

// 开始时间优先级（Explorer 批准）：runningSince → startedAt → 绑定 run.startUtc → null。
// runningSince 只有 external 的 start 会写（真实开始执行）；startedAt 两个 backend 都写
// （DSH 等于 run.startUtc，external 是派发时刻）；绑定 run 只在 1、2 都缺失时兜底。
function taskTimerStartUtc(agent, task, attempt) {
  if (!attempt) return { startUtc: null, source: null };
  if (attempt.runningSince) return { startUtc: attempt.runningSince, source: "runningSince" };
  if (attempt.startedAt) return { startUtc: attempt.startedAt, source: "startedAt" };
  const boundRun = (agent?.turns ?? []).find((run) => run?.attemptId === attempt.attemptId
    && (!run.taskId || run.taskId === task?.taskId)) ?? null;
  if (boundRun?.startUtc) return { startUtc: boundRun.startUtc, source: "run.startUtc" };
  return { startUtc: null, source: null };
}

// live 只在「Task 仍活动 + 有当前非 fenced attempt」时成立。终态用 attempt.endedAt 冻结；
// 无法解析开始时间时为 unknown，label 走 durationFrom 的既有 `--:--` 约定（绝不伪装成 00:00）。
function taskTimerView(agent, task, nowMs = Date.now()) {
  const attempt = currentTaskAttempt(task);
  const status = typeof task?.status === "string" && task.status ? task.status : "UNKNOWN";
  const start = taskTimerStartUtc(agent, task, attempt);
  const live = Boolean(task) && ACTIVE_TASK_STATUSES.includes(task.status) && attempt !== null;
  const endUtc = live ? null : (attempt?.endedAt ?? null);
  const endMs = live ? nowMs : (endUtc ? runTime(endUtc) : nowMs);
  const seconds = start.startUtc ? Math.max(0, Math.floor((endMs - runTime(start.startUtc)) / 1000)) : null;
  // state 是「显示状态」：开始时间无法解析时一律 unknown（fail-visible），绝不被 live 掩盖成
  // 一个假数字；live 只表示活动证据，能否计时看 startUtc。
  const state = !start.startUtc ? TASK_TIMER_STATES.UNKNOWN : (live ? TASK_TIMER_STATES.LIVE : TASK_TIMER_STATES.TERMINAL);
  return {
    state,
    phase: status === "RUNNING" ? "running" : "assigned",
    live,
    status,
    attemptId: attempt?.attemptId ?? null,
    startUtc: start.startUtc,
    startSource: start.source,
    endUtc,
    seconds,
    label: seconds === null ? "--:--" : formatElapsedSeconds(seconds),
  };
}

// 返回 null = 该 Agent 没有当前 Task（none），整段不渲染；否则 task 缺失也要渲染成 unknown
// （fail-visible，与 agentHasActiveTask 的 fail-closed 一致，绝不静默消失）。
function agentTaskTimerView(agent, nowMs = Date.now()) {
  if (!agent?.currentTaskId) return null;
  return taskTimerView(agent, tasks.get(agent.currentTaskId) ?? null, nowMs);
}

function taskTimerTitle(timer, agent) {
  if (!timer.startUtc) return `无法解析当前 Task ${agent?.currentTaskId ?? ""} 的开始时间（不会用 Agent 累计运行时间兜底）`;
  return `当前 Task ${agent?.currentTaskId ?? ""} 用时（开始来源：${timer.startSource ?? "未知"}；与 Agent 累计运行时间无关）`;
}

// ticker 每秒写 textContent，所以 data-task-elapsed 必须落在「只含时间文本」的最内层节点上；
// 「当前任务用时」这个标签留在父层，否则会被每秒覆写擦掉。
function taskTimerAttrs(agent, timer) {
  const attrs = [
    ` data-task-elapsed="${escapeHtml(agent.agentId)}"`,
    ` data-task-timer-task="${escapeHtml(agent.currentTaskId ?? "")}"`,
    ` data-task-timer-attempt="${escapeHtml(timer.attemptId ?? "")}"`,
    ` data-task-timer-status="${escapeHtml(timer.status)}"`,
    ` data-task-timer-state="${escapeHtml(timer.state)}"`,
    ` data-task-timer-phase="${escapeHtml(timer.phase)}"`,
    ` data-task-timer-has-start="${timer.startUtc ? "true" : "false"}"`,
  ];
  if (timer.startUtc) attrs.push(` data-task-timer-start="${escapeHtml(timer.startUtc)}"`);
  if (timer.startSource) attrs.push(` data-task-timer-source="${escapeHtml(timer.startSource)}"`);
  return attrs.join("");
}

// 侧栏卡片 / 详情头共用的两种形状：wrapper class 不同，最内层承载时间的节点标签不同。
function taskTimerHtml(agent, { wrapperClass = "nav-task-timer", timeTag = "strong" } = {}) {
  const timer = agentTaskTimerView(agent);
  if (!timer) return "";
  return `<span class="${wrapperClass}" data-task-timer-state="${escapeHtml(timer.state)}" data-task-timer-phase="${escapeHtml(timer.phase)}" title="${escapeHtml(taskTimerTitle(timer, agent))}">当前任务用时 <${timeTag} class="task-elapsed"${taskTimerAttrs(agent, timer)}>${escapeHtml(timer.label)}</${timeTag}></span>`;
}

// 当前 Task 摘要：紧凑列表只讲“哪个 Task、什么进度”，不讲 Team/Session。
function agentTaskSummary(agent) {
  const task = agent.currentTaskId ? tasks.get(agent.currentTaskId) ?? null : null;
  if (task) {
    const view = taskChipStatusView(task.status);
    return { label: `${task.taskId} · ${view.label}`, active: view.active };
  }
  if (agent.latestTaskId) return { label: `最近 ${agent.latestTaskId}`, active: false };
  return { label: "无 Task", active: false };
}

function navCardHtml(agent, selectedId = selectedAgentId) {
  const state = agentStateView(agent);
  const latestRun = agent.turns.at(-1) ?? null;
  const task = agentTaskSummary(agent);
  const progress = phaseLabels[latestRun?.phase] ?? phaseLabels[agent.status] ?? statusLabels[agent.status] ?? "未知阶段";
  const selected = agent.agentId === selectedId;
  return `<button type="button" class="nav-card" data-agent-id="${escapeHtml(agent.agentId)}" data-selected="${selected}" aria-pressed="${selected}">
    <span class="nav-line nav-head">
      <span class="nav-avatar" aria-hidden="true">${escapeHtml(roleInitial(agent.formalRole))}</span>
      <span class="nav-name">${escapeHtml(agent.agentId)}</span>
      <span class="state" data-state="${state.key}">${escapeHtml(state.label)}</span>
    </span>
    <span class="nav-line nav-model">${escapeHtml(launchEvidenceLabel(latestRun))}</span>
    <span class="nav-line nav-task">
      <code>${escapeHtml(task.label)}</code>
      <span class="nav-progress">${escapeHtml(progress)}</span>
    </span>
    <span class="nav-line nav-timers">
      ${taskTimerHtml(agent, { wrapperClass: "nav-task-timer", timeTag: "strong" })}
      <span class="nav-elapsed" title="Agent 累计运行时间（registry 生命周期，与当前 Task 用时无关）">Agent 累计 <strong data-agent-elapsed="${escapeHtml(agent.agentId)}">${escapeHtml(agentDurationLabel(agent))}</strong></span>
    </span>
  </button>`;
}

// `readOnly` drops the Run cancel control, which is the only write affordance the conversation
// renderer owns. The archive page therefore renders the identical conversation with no actions.
//
// 轻量 timeline：一个 Turn 只保留「一行头 + CODEX → DSH + 事件流 + 默认折叠的 Details」。
// Turn 卡片背景/边框去掉，只留一条左侧时间轴；诊断字段（route/Git/exit/session/run id/
// requested 模型）全部进 Details，原始 events 与 evidence 一个字节都没有删除。
function turnHtml(run, agent = null, readOnly = false) {
  const items = timeline(run.events ?? []);
  const events = run.events ?? [];
  const launch = launchEvidenceView(run);
  const requested = run.requestedModelSelection;
  const cancelHtml = readOnly || !isActive(run)
    ? ""
    : `<button type="button" class="action-button danger" data-cancel-run="${escapeHtml(run.id)}">取消运行</button>`;
  const detailsBody = [
    `<p class="detail-line"><span>launch evidence</span><code>${escapeHtml(launch.source ?? "无（只有 requested/pending 时不显示为最终值）")}</code></p>`,
    requested?.provider && requested?.model
      ? `<p class="detail-line"><span>requested</span><code>${escapeHtml(`${requested.provider} / ${requested.model}`)} · ${escapeHtml(run.modelSelectionStatus ?? "pending")}</code></p>`
      : `<p class="detail-line"><span>requested</span><code>跟随 DSH 默认</code></p>`,
    `<p class="detail-line"><span>session</span><code>${escapeHtml(shortSession(run.sessionId))}</code> · events <code>${events.length}</code> · run <code>${escapeHtml(shortId(run.id))}</code></p>`,
    `<p class="detail-line"><span>contract</span><code>${escapeHtml(run.contractPath ?? "—")}</code></p>`,
    evidenceHtml(run, agent),
  ].join("");
  return `<article class="turn" data-run-id="${escapeHtml(run.id)}" data-phase="${phaseOrder[run.phase] ?? 1}">
    <header class="turn-head">
      <span class="turn-index">Turn ${run.turnIndex ?? "?"}</span>
      <span class="status" data-status="${escapeHtml(run.status)}">${escapeHtml(statusLabels[run.status] ?? run.status)}</span>
      <span class="turn-phase">${escapeHtml(phaseLabels[run.phase] ?? run.phase ?? "")}</span>
      <span class="turn-model">${escapeHtml(launchEvidenceLabel(run))}</span>
      <span class="turn-elapsed" data-run-elapsed="${escapeHtml(run.id)}">${escapeHtml(durationLabel(run))}</span>
      ${cancelHtml}
    </header>
    <div class="turn-body">
      ${foldBlock({
        key: `${run.id}:prompt`,
        kind: "prompt",
        label: "CODEX → DSH",
        meta: `${timeLabel(run.startUtc)} · 实际发送的完整指令 · 已发送`,
        body: `<pre>${escapeHtml(displayText(delegatedPrompt(run)))}</pre>`,
      })}
      <div class="timeline-label">DSH → CODEX · 实时公开事件</div>
      <div class="timeline">${timelineHtml(run, items)}</div>
      ${foldBlock({ key: `${run.id}:details`, kind: "details", label: "Details", meta: "session / route / Git / exit / contract", body: detailsBody })}
      ${run.error ? `<p class="turn-error">${escapeHtml(run.error)}</p>` : ""}
    </div>
  </article>`;
}

// --- 非 DSH 外部执行提示（详情区，折叠 Details 之外） ---------------------------
//
// 只有「一个可见 DSH Turn 都没有、且执行主体不是 DSH ACP」时才出现：告诉用户谁在执行、
// 当前生命周期状态、对应的 Task/Attempt，并解释“Monitor 没有对应的 DSH ACP Turn 可回放”
// 是正常的外部执行，不是卡死。纯展示：无按钮、无 fetch、无定时器；字段缺失时逐项降级。

// 终态一律用过去时；绝不允许把 completed/failed/interrupted/terminated 写成进行时。
const NOTICE_PAST_TENSE = {
  completed: "已完成执行",
  cancelled: "已取消执行",
  failed: "本次执行失败",
  interrupted: "执行已中断",
  terminated: "已退役",
};

// 把原始 backend 值收敛成提示用的固定集合，绝不把未知值推断成 Codex。
function noticeBackendKeyOf(rawValue) {
  const value = typeof rawValue === "string" ? rawValue.trim() : "";
  if (value === "dsh") return "dsh";
  if (value === "codex") return "codex";
  if (value) return "external";
  return "unknown";
}

function noticeBackendLabel(key) {
  if (key === "codex") return "Codex 子智能体";
  if (key === "dsh") return "DSH ACP";
  if (key === "external") return "外部执行器";
  return "执行者未标注";
}

function noticeSideLabel(key) {
  if (key === "codex") return "Codex";
  if (key === "dsh") return "DSH ACP";
  if (key === "external") return "external";
  return "未标注的执行侧";
}

// 活动证据只能来自真实投影：Agent 生命周期属于 starting/running/cancelling、Agent state 为
// RUNNING，或当前 Task 记录本身仍是活动态。刻意不使用 fail-closed 的 agentHasActiveTask()
// （Task 记录缺失也算 busy），也绝不因为 backend=codex 就声明“正在执行”。
function noticeHasActivityEvidence(agent, taskRecord) {
  if (ACTIVE_STATUSES.includes(agent?.status)) return true;
  if (agent?.state === "RUNNING") return true;
  return Boolean(taskRecord && ACTIVE_TASK_STATUSES.includes(taskRecord.status));
}

// Attempt 的执行者是更权威的事实：当 Attempt 的 agentId 与所选 Agent 不同时，标题必须使用
// Attempt 的真实执行者与 backend，不能让所选 Agent 冒领。若这个异主体 Attempt 自己也没有
// 标注 backend，则执行主体不可识别，必须收敛为 unknown，绝不能继承所选 Agent 的 backend
// 把别人的执行挂到所选 Agent 的执行侧上。
function noticeExecutorOf(agent, backend, attempt) {
  const attemptAgentId = typeof attempt?.agentId === "string" && attempt.agentId.trim() ? attempt.agentId.trim() : null;
  const selectedAgentId = agent?.agentId ?? null;
  const attemptBackend = noticeBackendKeyOf(attempt?.backend);
  const impersonated = Boolean(attemptAgentId && selectedAgentId && attemptAgentId !== selectedAgentId);
  const effectiveBackend = impersonated && attemptBackend === "unknown"
    ? "unknown"
    : (attemptBackend !== "unknown" ? attemptBackend : backend.key);
  return {
    effectiveBackend,
    executorAgentId: attemptAgentId ?? selectedAgentId,
    selectedAgentId,
    impersonated,
  };
}

function agentExecutionNoticeHtml(agent, readOnly) {
  if (!agent || (agent.turns?.length ?? 0) > 0) return "";
  const backend = backendView(agent);
  // DSH Agent 即使暂时 0 Turn 也保留原有 turn-empty 对话渲染，绝不替换成外部提示。
  if (backend.key === "dsh") return "";

  const state = agentStateView(agent);
  const lifecycleKey = agent.terminated ? "terminated" : (typeof agent.status === "string" && agent.status ? agent.status : "unknown");
  const lifecycleLabel = lifecycleKey === "terminated" ? "已退役" : (statusLabels[lifecycleKey] ?? lifecycleKey);
  const taskRecord = (agent.currentTaskId ? tasks.get(agent.currentTaskId) ?? null : null)
    ?? (agent.latestTaskId ? tasks.get(agent.latestTaskId) ?? null : null);
  const attempt = taskRecord ? taskProgress(taskRecord).current : null;
  const running = noticeHasActivityEvidence(agent, taskRecord);
  const executor = noticeExecutorOf(agent, backend, attempt);
  // data-state 是视觉状态：任一合法活动证据成立即 running，否则回落真实 agentStateView。
  // facts 里的 Agent 生命周期文本仍是真实投影，用来暴露瞬时差异（例如 Task 活动而 Agent 记录 idle）。
  const visualStateKey = running ? "running" : state.key;
  const executorId = executor.executorAgentId ?? "未知 Agent";
  const executorText = executor.effectiveBackend === "unknown"
    ? `执行者未标注（${executorId}）`
    : `${noticeBackendLabel(executor.effectiveBackend)} ${executorId}`;

  // 归档详情一律历史措辞：即使旧投影 status 仍写着 running，也不能使用现在进行时。
  let head;
  if (readOnly) {
    if (running) head = `归档记录：当时由 ${executorText} 执行`;
    else if (NOTICE_PAST_TENSE[lifecycleKey]) head = `归档记录：由 ${executorText} ${NOTICE_PAST_TENSE[lifecycleKey]}`;
    else head = `归档记录：由 ${executorText} 驱动，当前记录状态「${lifecycleLabel}」`;
  } else if (running) {
    head = `正在由 ${executorText} 执行`;
  } else if (NOTICE_PAST_TENSE[lifecycleKey]) {
    head = `${executorText} ${NOTICE_PAST_TENSE[lifecycleKey]}`;
  } else {
    head = `${executorText} 当前空闲`;
  }

  const facts = [`<span class="agent-notice-fact">Agent 状态 <code>${escapeHtml(lifecycleLabel)}</code></span>`];
  if (executor.impersonated) {
    facts.push(`<span class="agent-notice-fact">所选 Agent <code>${escapeHtml(executor.selectedAgentId)}</code> 不是本次执行者</span>`);
  }
  if (taskRecord) {
    const participation = taskParticipationOf(taskRecord, executor.executorAgentId);
    facts.push(`<span class="agent-notice-fact">Task ${taskChipHtml(taskRecord, true, participation)} <span class="agent-notice-task-title">${escapeHtml(taskRecord.title ?? taskRecord.taskId)}</span></span>`);
  } else {
    facts.push(`<span class="agent-notice-fact">Task <code>无当前/最近 Task 记录</code></span>`);
  }
  if (attempt) {
    facts.push(`<span class="agent-notice-fact">Attempt <code>${escapeHtml(attempt.attemptId ?? "—")}</code> ${escapeHtml(taskStatusLabels[attempt.status] ?? attempt.status ?? "状态未知")} · backend <code>${escapeHtml(attempt.backend ?? "未标注")}</code> · agent <code>${escapeHtml(attempt.agentId ?? "未标注")}</code></span>`);
  }
  // 说明分三类，避免在没有活动证据时预设“本次执行已经发生”：
  // running 保留进行中意图；归档保留历史意图；当前页非活动场景只陈述“该 Agent 由外部侧驱动、
  // 没有 DSH ACP Turn 可回放、当前没有活动执行”，既不断言执行已发生，也不暗示卡死。
  const sideLabel = noticeSideLabel(executor.effectiveBackend);
  let note;
  if (readOnly) {
    note = `该执行发生在 ${sideLabel} 侧；归档页没有对应的 DSH ACP Turn 可回放，这并不代表当时没有执行，也不代表卡死。`;
  } else if (running) {
    note = `该执行发生在 ${sideLabel} 侧，Monitor 没有对应的 DSH ACP Turn 可回放；这是正常的外部执行，不代表卡死。`;
  } else {
    note = `该 Agent 由 ${sideLabel} 侧驱动，Monitor 没有对应的 DSH ACP Turn 可回放；当前没有活动执行，不代表卡死。`;
  }

  return `<div class="agent-notice" data-backend="${escapeHtml(executor.effectiveBackend)}" data-lifecycle="${escapeHtml(lifecycleKey)}" data-readonly="${readOnly ? "true" : "false"}" data-state="${escapeHtml(visualStateKey)}">
    <p class="agent-notice-head">${escapeHtml(head)}</p>
    <p class="agent-notice-facts">${facts.join("")}</p>
    <p class="agent-notice-note">${escapeHtml(note)}</p>
  </div>`;
}

// 右侧 Agent 头（A.4）：名称/状态、角色、launch evidence 的 model/reasoning、当前 task/turn/
// elapsed。backend、session、team、workspace、Git、退出码等诊断字段全部放进默认折叠的
// Details；原始 events 与 artifacts 仍由 monitor 持有，这里只是换一层显示。
// `teamId` is the explicit Team scope of the pane that owns this conversation: current render()
// passes the current Team, renderArchive() passes the selected archive Team (or the UNASSIGNED
// sentinel). A null scope therefore means “no Team”, never “all Teams”.
function detailHtml(agent, readOnly = false, teamId = agent?.teamId ?? null) {
  const state = agentStateView(agent);
  const backend = backendView(agent);
  const latestRun = agent.turns.at(-1) ?? null;
  const task = agentTaskSummary(agent);
  const workspace = latestRun?.workspace ?? null;
  const projectionNote = agent.turns.length > 0
    ? "本面板只投影 ACP 主动公开的事件：Thought 是 DSH 公开 summary，不是隐藏 CoT；折叠与 Tool 合并只发生在显示层，原始 events 与 artifacts 保持不变。"
    : `该 Agent 当前没有 visible run（${backend.chip}），因此没有 ACP 事件可投影；Team/Task 归属见下方 Details，原始 events 与 artifacts 保持不变。`;
  const detailsBody = [
    `<p class="detail-line"><span>backend</span><code>${escapeHtml(backend.chip)}</code> — ${escapeHtml(backend.ownership)}</p>`,
    `<p class="detail-line"><span>session</span><code>${escapeHtml(agent.sessionId ?? backend.session)}</code></p>`,
    `<p class="detail-line"><span>team</span><code>${escapeHtml(agent.teamId ?? "未绑定")}</code> · current task <code>${escapeHtml(agent.currentTaskId ?? "无")}</code> · turn <code>${agent.turnCount}</code></p>`,
    `<p class="detail-line"><span>workspace</span><code>${escapeHtml(workspace ?? "—")}</code></p>`,
    latestRun
      ? (() => {
        const proof = runEvidence(latestRun, agent);
        return `<p class="detail-line"><span>最近 run 证据</span><code>${escapeHtml(proof.route)} · ${escapeHtml(proof.git)} · ${escapeHtml(proof.workspace)} · exit ${escapeHtml(proof.exit)}</code></p>`;
      })()
      : `<p class="detail-line"><span>最近 run 证据</span><code>尚无 visible run</code></p>`,
    `<p class="detail-line"><span>最近 run</span><code>${escapeHtml(latestRun ? shortId(latestRun.id) : "—")}</code> · contract <code>${escapeHtml(latestRun?.contractPath ?? "—")}</code></p>`,
    `<div class="nav-tasks detail-tasks">${agentTasksHtml(agent, { teamId, readOnly })}</div>`,
    `<p class="timeline-note">${escapeHtml(projectionNote)}</p>`,
  ].join("");
  return `<section class="agent-card" data-agent-id="${escapeHtml(agent.agentId)}" data-phase="${phaseOrder[latestRun?.phase] ?? 1}">
    <header class="agent-head">
      <span class="agent-avatar" aria-hidden="true">${escapeHtml(roleInitial(agent.formalRole))}</span>
      <h3 class="agent-name">${escapeHtml(agent.agentId)}</h3>
      <span class="agent-role">${escapeHtml(agent.formalRole)}</span>
      <span class="state" data-state="${state.key}">${escapeHtml(state.label)}</span>
      <span class="status" data-status="${escapeHtml(agent.status)}">${escapeHtml(statusLabels[agent.status] ?? agent.status)}</span>
      <span class="agent-model">${escapeHtml(launchEvidenceLabel(latestRun))}</span>
      <span class="agent-task"><code>${escapeHtml(task.label)}</code></span>
      <span>Turn <code>${escapeHtml(String(agent.turnCount))}</code></span>
      <span>Agent 累计 <code data-agent-elapsed="${escapeHtml(agent.agentId)}">${escapeHtml(agentDurationLabel(agent))}</code></span>
      ${taskTimerHtml(agent, { wrapperClass: "agent-task-timer", timeTag: "code" })}
    </header>
    ${readOnly ? "" : agentActionsHtml(agent)}
    ${agentExecutionNoticeHtml(agent, readOnly)}
    ${foldBlock({ key: `agent:${agent.agentId}:details`, kind: "details", label: "Details", meta: "backend / session / team / workspace / git / exit / tasks", body: detailsBody })}
    <div class="turns">
      ${agent.turns.length > 0 ? agent.turns.map((run) => turnHtml(run, agent, readOnly)).join("") : `<p class="turn-empty">该 Agent 暂无可见 Turn（可能只有历史 registry 记录）。</p>`}
    </div>
  </section>`;
}

// --- tasks rendering (read-only projection) ----------------------------------

function compareTeams(left, right) {
  const orderDelta = (TEAM_STATUS_ORDER[left.status] ?? 9) - (TEAM_STATUS_ORDER[right.status] ?? 9);
  if (orderDelta !== 0) return orderDelta;
  const timeDelta = runTime(left.createdAt) - runTime(right.createdAt);
  if (timeDelta !== 0) return timeDelta;
  return String(left.teamId).localeCompare(String(right.teamId));
}

function compareTasks(left, right) {
  const timeDelta = runTime(left.createdAt) - runTime(right.createdAt);
  if (timeDelta !== 0) return timeDelta;
  return String(left.taskId).localeCompare(String(right.taskId));
}

// Dependencies first, then the remaining tasks, so a compact row list reads like the DAG.
function orderTasksByDependencies(teamTasks) {
  const byId = new Map(teamTasks.map((task) => [task.taskId, task]));
  const emitted = new Set();
  const ordered = [];
  const remaining = [...teamTasks].sort(compareTasks);
  let progressed = true;
  while (remaining.length > 0 && progressed) {
    progressed = false;
    for (let index = 0; index < remaining.length; index += 1) {
      const task = remaining[index];
      const dependencies = (task.dependencies ?? []).filter((dependencyId) => byId.has(dependencyId));
      if (!dependencies.every((dependencyId) => emitted.has(dependencyId))) continue;
      ordered.push(task);
      emitted.add(task.taskId);
      remaining.splice(index, 1);
      index -= 1;
      progressed = true;
    }
  }
  return [...ordered, ...remaining];
}

function taskProgress(task) {
  const attempts = task.attempts ?? [];
  const currentAttemptId = task.attemptId ?? null;
  const current = currentAttemptId ? attempts.find((attempt) => attempt.attemptId === currentAttemptId) ?? null : null;
  const active = ACTIVE_TASK_STATUSES.includes(task.status);
  return {
    attempts,
    current,
    attemptLabel: currentAttemptId ?? "—",
    attemptStatus: current?.status ?? (active ? task.status : null),
    historical: attempts.length,
  };
}

function dependencyChipHtml(task, tasksById) {
  const dependencies = task.dependencies ?? [];
  if (dependencies.length === 0) return `<span class="deps-none">无依赖</span>`;
  return dependencies.map((dependencyId) => {
    const dependency = tasksById.get(dependencyId);
    const satisfied = dependency?.status === "COMPLETED";
    const label = dependency ? `${dependencyId} · ${taskStatusLabels[dependency.status] ?? dependency.status}` : `${dependencyId} · 缺失`;
    return `<span class="dep-chip" data-satisfied="${satisfied}"><code>${escapeHtml(label)}</code></span>`;
  }).join("");
}

function detailValue(value) {
  if (value === null || value === undefined) return `<span class="detail-empty">—</span>`;
  return `<pre class="event-pre">${escapeHtml(displayText(JSON.stringify(value, null, 2)))}</pre>`;
}

function attemptRowsHtml(task) {
  const attempts = task.attempts ?? [];
  if (attempts.length === 0) return `<p class="detail-empty">尚无 attempt。</p>`;
  return `<ul class="attempt-list">${attempts.map((attempt) => {
    const current = attempt.attemptId === task.attemptId;
    const permission = attempt.requestedPermissionMode || attempt.effectivePermissionMode
      ? `<span>permission <code>${escapeHtml(attempt.requestedPermissionMode ?? "—")} → ${escapeHtml(attempt.effectivePermissionMode ?? "—")}</code>${attempt.permissionVerification?.enforced ? " · verified" : ""}</span>`
      : "";
    return `<li class="attempt-row"${current ? ' data-current="true"' : ""}>
      <span class="attempt-id"><code>${escapeHtml(attempt.attemptId ?? "—")}</code>${current ? `<span class="attempt-badge">当前</span>` : ""}</span>
      <span class="attempt-status">${escapeHtml(taskStatusLabels[attempt.status] ?? attempt.status ?? "—")}</span>
      <span>agent <code>${escapeHtml(attempt.agentId ?? "—")}</code></span>
      <span>run <code>${escapeHtml(shortId(attempt.runId))}</code></span>
      <span>${escapeHtml(attempt.lifecycleAction ?? "—")}</span>
      <span>${escapeHtml(timeLabel(attempt.startedAt))} → ${escapeHtml(attempt.endedAt ? timeLabel(attempt.endedAt) : "…")}</span>
      ${permission}
      ${attempt.fenced ? `<span class="attempt-fenced" title="${escapeHtml(attempt.fencedReason ?? "")}">fenced</span>` : ""}
    </li>`;
  }).join("")}</ul>`;
}

function taskRowHtml(task, tasksById) {
  const progress = taskProgress(task);
  const meta = [
    `<span>execution <code>${escapeHtml(task.executionType ?? "normal")}</code></span>`,
    `<span>owner <code>${escapeHtml(task.ownerAgentId ?? "未指定")}</code></span>`,
    `<span>attempt <code>${escapeHtml(progress.attemptLabel)}</code>${progress.attemptStatus ? ` · ${escapeHtml(taskStatusLabels[progress.attemptStatus] ?? progress.attemptStatus)}` : ""}</span>`,
    `<span>attempts <code>${progress.historical}</code></span>`,
  ].join("");
  const details = [
    `<h4>Dependencies</h4><p class="detail-line">${dependencyChipHtml(task, tasksById)}</p>`,
    `<h4>Attempts</h4>${attemptRowsHtml(task)}`,
    `<h4>Result</h4>${detailValue(task.result)}`,
    `<h4>Failure</h4>${detailValue(task.failure)}`,
    `<h4>Recovery</h4>${detailValue(task.recovery)}`,
  ].join("");
  const depends = (task.dependencies ?? []).length > 0;
  // A FAILED/CANCELLED Task is the one case where the evidence must be visible without a click;
  // a manual collapse is still remembered by foldState.
  const terminalUnhappy = task.status === "FAILED" || task.status === "CANCELLED";
  // The header doubles as the presentational selection area shared with the sidebar chips and
  // the DAG nodes: it only writes `selectedTaskId`, it never schedules anything.
  const view = taskChipStatusView(task.status);
  const selected = task.taskId === selectedTaskId;
  const label = `${task.title ?? task.taskId}`;
  return `<article class="task-row" data-task-id="${escapeHtml(task.taskId)}" data-task-status="${escapeHtml(task.status)}" data-has-deps="${depends}"${selected ? ' data-task-selected="true"' : ""}>
    <button type="button" class="task-row-head task-select" data-task-id="${escapeHtml(task.taskId)}" data-task-status="${escapeHtml(task.status)}" aria-pressed="${selected}" title="${escapeHtml(`选择 Task ${task.taskId} · ${label}`)}" aria-label="${escapeHtml(`选择 Task ${task.taskId}，${view.label}：${label}`)}">
      <span class="task-status" data-task-status="${escapeHtml(task.status)}">${escapeHtml(taskStatusLabels[task.status] ?? task.status)}</span>
      <span class="task-title">${escapeHtml(task.title ?? task.taskId)}</span>
      <code class="task-id">${escapeHtml(task.taskId)}</code>
    </button>
    <div class="task-meta">${meta}</div>
    <div class="task-deps"><span class="deps-label">dependencies</span>${dependencyChipHtml(task, tasksById)}</div>
    ${foldBlock({
      key: `task:${task.taskId}`,
      kind: "task",
      label: "Result / Failure / Recovery / Attempt 历史",
      meta: `${progress.historical} attempt${progress.historical === 1 ? "" : "s"}${terminalUnhappy ? " · 失败/取消，默认展开" : ""}`,
      autoExpand: terminalUnhappy,
      body: details,
    })}
  </article>`;
}

function teamCardHtml(team, teamTaskList) {
  const completed = teamTaskList.filter((task) => task.status === "COMPLETED").length;
  const active = teamTaskList.filter((task) => ACTIVE_TASK_STATUSES.includes(task.status)).length;
  const blocked = teamTaskList.filter((task) => task.status === "BLOCKED").length;
  const failed = teamTaskList.filter((task) => task.status === "FAILED" || task.status === "CANCELLED").length;
  const segments = teamTaskList.slice(0, 20).map((task) => `<span class="progress-seg" data-done="${task.status === "COMPLETED"}"></span>`).join("");
  const notice = team.status === "AWAITING_USER_ACCEPTANCE"
    ? `<p class="team-notice">目标已完成，等待用户验收；只有 Coordinator 的显式动作才会解散该 Team。</p>`
    : "";
  return `<article class="team-card" data-team-id="${escapeHtml(team.teamId)}" data-team-status="${escapeHtml(team.status)}">
    <header class="team-card-head">
      <h3>${escapeHtml(team.title ?? team.teamId)}</h3>
      <code class="team-id">${escapeHtml(team.teamId)}</code>
      <span class="team-status" data-team-status="${escapeHtml(team.status)}">${escapeHtml(teamStatusLabels[team.status] ?? team.status)}</span>
    </header>
    <div class="team-progress" role="progressbar" aria-valuemin="0" aria-valuemax="${teamTaskList.length}" aria-valuenow="${completed}" aria-label="${escapeHtml(team.teamId)} 完成进度">
      <span class="progress-track">${segments || `<span class="progress-seg" data-done="false"></span>`}</span>
      <span class="progress-count">${completed} / ${teamTaskList.length} 完成</span>
      <span class="progress-side">运行 ${active} · 阻塞 ${blocked} · 未完成终态 ${failed}</span>
    </div>
    ${notice}
  </article>`;
}

function renderTasks() {
  // The Tasks page describes the current Team only: archived/DISSOLVED history lives on the
  // archive page, so the two views can never show the same Task group at the same time.
  const context = currentTeamContext();
  const teamList = context ? [context.team] : [];
  const tasksById = new Map([...tasks.values()].map((task) => [task.taskId, task]));
  const grouped = new Map(teamList.map((team) => [team.teamId, []]));
  for (const task of tasks.values()) {
    if (!grouped.has(task.teamId)) grouped.set(task.teamId, []);
    grouped.get(task.teamId).push(task);
  }
  // Only Tasks whose Team record is entirely missing get a degraded group: a Task that belongs to
  // a non-current Team is history and must not leak into the current page.
  const orphanTeamIds = context ? [...grouped.keys()].filter((teamId) => !teams.has(teamId)) : [];
  const groups = [
    ...teamList.map((team) => ({ team, teamTasks: grouped.get(team.teamId) ?? [] })),
    ...orphanTeamIds.map((teamId) => ({
      team: { teamId, title: teamId, status: "ACTIVE", degraded: true },
      teamTasks: grouped.get(teamId) ?? [],
    })),
  ];

  tasksEmpty.hidden = groups.length > 0;
  teamCards.innerHTML = groups.map(({ team, teamTasks }) => teamCardHtml(team, teamTasks)).join("");
  taskGroups.innerHTML = groups.map(({ team, teamTasks }) => {
    const ordered = orderTasksByDependencies(teamTasks);
    const rows = ordered.length > 0
      ? ordered.map((task) => taskRowHtml(task, tasksById)).join("")
      : `<p class="tasks-empty">该 Team 暂无 Task。</p>`;
    return `<section class="task-group" data-team-id="${escapeHtml(team.teamId)}">
      <h3 class="task-group-title">${escapeHtml(team.title ?? team.teamId)} <code>${escapeHtml(team.teamId)}</code></h3>
      <div class="task-rows">${rows}</div>
    </section>`;
  }).join("");

  const allTeams = [...teams.values()];
  const currentTasks = context ? teamTasksOf(context.team.teamId) : [];
  const completed = currentTasks.filter((task) => task.status === "COMPLETED").length;
  const awaiting = allTeams.filter((team) => team.status === "AWAITING_USER_ACCEPTANCE").length;
  const archivedCount = allTeams.filter(teamIsArchived).length;
  // Task 摘要只讲当前 Team 的完成度；其他 Team 的数量属于「归档对话」/「Tasks」。
  taskMetric.textContent = context
    ? `${completed} / ${currentTasks.length}${awaiting > 0 ? ` · 待验收 ${awaiting}` : ""}${archivedCount > 0 ? ` · 归档 ${archivedCount}` : ""}`
    : "—";
}

// --- Task dependency DAG (read-only projection) -------------------------------
// Ranks come from Kahn's algorithm with longest-path relaxation, so every normal edge points
// from a lower rank to a higher rank. A dependency outside the current Team becomes an explicit
// missing marker, and a node trapped in a cycle is released deterministically: the layout always
// terminates and no Task is ever dropped or hidden.

function dagModel(teamTasks) {
  const ordered = orderTasksByDependencies(teamTasks);
  const taskIds = ordered.map((task) => task.taskId);
  const taskSet = new Set(taskIds);
  const orderIndex = new Map(taskIds.map((taskId, index) => [taskId, index]));
  const byId = new Map(ordered.map((task) => [task.taskId, task]));
  const missingDependencies = new Set();
  const depsOf = new Map(taskIds.map((taskId) => [taskId, []]));
  const seenEdges = new Set();
  const edges = [];
  for (const task of ordered) {
    for (const dependencyId of task.dependencies ?? []) {
      depsOf.get(task.taskId).push(dependencyId);
      const missing = !taskSet.has(dependencyId);
      if (missing) missingDependencies.add(dependencyId);
      const key = `${dependencyId}->${task.taskId}`;
      if (seenEdges.has(key)) continue;
      seenEdges.add(key);
      edges.push({ from: dependencyId, to: task.taskId, missing });
    }
  }
  const missingIds = [...missingDependencies].sort();
  for (const missingId of missingIds) depsOf.set(missingId, []);
  const allIds = [...taskIds, ...missingIds];

  const rank = new Map();
  const resolved = new Set();
  const released = new Set();
  let guard = 0;
  while (resolved.size < allIds.length && guard <= allIds.length * 2 + 4) {
    guard += 1;
    const ready = allIds.filter((id) => !resolved.has(id) && depsOf.get(id).every((dependencyId) => resolved.has(dependencyId)));
    if (ready.length === 0) {
      // Every remaining node sits in (or behind) a cycle. Release the smallest id so the walk
      // continues and the node stays visible instead of vanishing.
      const chosen = allIds.filter((id) => !resolved.has(id)).sort()[0];
      const known = depsOf.get(chosen).filter((dependencyId) => resolved.has(dependencyId));
      rank.set(chosen, known.length > 0 ? Math.max(...known.map((dependencyId) => rank.get(dependencyId) + 1)) : 0);
      resolved.add(chosen);
      released.add(chosen);
      continue;
    }
    for (const id of ready) {
      const known = depsOf.get(id).filter((dependencyId) => resolved.has(dependencyId));
      rank.set(id, known.length > 0 ? Math.max(...known.map((dependencyId) => rank.get(dependencyId) + 1)) : 0);
      resolved.add(id);
    }
  }
  // Cycle membership comes from reachability, not from the deterministic release order above, so
  // every node of a cycle is marked (`released` only records where the walk had to be broken).
  const outgoing = new Map(allIds.map((id) => [id, []]));
  for (const edge of edges) outgoing.get(edge.from)?.push(edge.to);
  const cyclic = new Set();
  for (const start of allIds) {
    const stack = [...(outgoing.get(start) ?? [])];
    const seen = new Set();
    while (stack.length > 0) {
      const next = stack.pop();
      if (next === start) { cyclic.add(start); break; }
      if (seen.has(next)) continue;
      seen.add(next);
      stack.push(...(outgoing.get(next) ?? []));
    }
  }
  // An edge that does not increase the rank is a back edge, i.e. part of a dependency cycle.
  const placedEdges = edges.map((edge) => ({ ...edge, cyclic: !((rank.get(edge.to) ?? 0) > (rank.get(edge.from) ?? 0)) }));
  return { ordered, byId, orderIndex, taskIds, allIds, missingDependencies, missingIds, rank, cyclic, released, depsOf, edges: placedEdges };
}

function dagLayout(model) {
  const columns = new Map();
  for (const id of model.allIds) {
    const rank = model.rank.get(id) ?? 0;
    if (!columns.has(rank)) columns.set(rank, []);
    columns.get(rank).push(id);
  }
  for (const ids of columns.values()) {
    ids.sort((left, right) => {
      const leftMissing = model.missingDependencies.has(left) ? 1 : 0;
      const rightMissing = model.missingDependencies.has(right) ? 1 : 0;
      if (leftMissing !== rightMissing) return leftMissing - rightMissing;
      if (leftMissing === 1) return String(left).localeCompare(String(right));
      return (model.orderIndex.get(left) ?? 0) - (model.orderIndex.get(right) ?? 0);
    });
  }
  const ranks = [...columns.keys()].sort((left, right) => left - right);
  const columnCount = ranks.length > 0 ? ranks[ranks.length - 1] + 1 : 0;
  const positions = new Map();
  let maxRows = 0;
  for (const rank of ranks) {
    const ids = columns.get(rank);
    maxRows = Math.max(maxRows, ids.length);
    ids.forEach((id, row) => {
      positions.set(id, { rank, row, x: rank * (DAG_NODE_WIDTH + DAG_COLUMN_GAP), y: row * (DAG_NODE_HEIGHT + DAG_ROW_GAP) });
    });
  }
  return {
    columns,
    ranks,
    positions,
    columnCount,
    maxRows,
    width: columnCount > 0 ? columnCount * DAG_NODE_WIDTH + (columnCount - 1) * DAG_COLUMN_GAP : 0,
    height: maxRows > 0 ? maxRows * DAG_NODE_HEIGHT + (maxRows - 1) * DAG_ROW_GAP : 0,
  };
}

// `dependency -> dependent`, drawn as a cubic bezier between facing node borders.
function dagEdgePath(from, to) {
  if (from.x === to.x && from.y === to.y) {
    const startX = from.x + DAG_NODE_WIDTH;
    const startY = from.y + DAG_NODE_HEIGHT / 2;
    return `M ${startX} ${startY} C ${startX + 46} ${startY - 40}, ${startX + 46} ${from.y - 26}, ${from.x + DAG_NODE_WIDTH / 2} ${from.y}`;
  }
  const x1 = from.x + DAG_NODE_WIDTH;
  const y1 = from.y + DAG_NODE_HEIGHT / 2;
  const x2 = to.x;
  const y2 = to.y + DAG_NODE_HEIGHT / 2;
  const bend = Math.max(24, Math.abs(x2 - x1) / 2);
  return `M ${x1} ${y1} C ${x1 + bend} ${y1}, ${x2 - bend} ${y2}, ${x2} ${y2}`;
}

function dagEdgesHtml(model, layout) {
  const paths = model.edges.map((edge) => {
    const from = layout.positions.get(edge.from);
    const to = layout.positions.get(edge.to);
    if (!from || !to) return "";
    const className = ["dag-edge", edge.missing ? "dag-edge-missing" : "", edge.cyclic ? "dag-edge-cyclic" : ""].filter(Boolean).join(" ");
    const flags = `${edge.missing ? ' data-missing="true"' : ""}${edge.cyclic ? ' data-cyclic="true"' : ""}`;
    return `<path class="${className}" d="${dagEdgePath(from, to)}" data-edge-from="${escapeHtml(edge.from)}" data-edge-to="${escapeHtml(edge.to)}"${flags}></path>`;
  }).join("");
  return `<svg class="dag-edges" width="${layout.width}" height="${layout.height}" viewBox="0 0 ${layout.width} ${layout.height}" aria-hidden="true" focusable="false">${paths}</svg>`;
}

function dagNodeHtml(task, model, layout) {
  const position = layout.positions.get(task.taskId);
  const view = taskChipStatusView(task.status);
  const cyclic = model.cyclic.has(task.taskId);
  const owner = task.ownerAgentId ?? "未指定";
  const title = task.title ?? task.taskId;
  const selected = task.taskId === selectedTaskId;
  const full = `Task ${task.taskId}，${view.label}，${title}，owner ${owner}，rank ${position.rank}${cyclic ? "，处于依赖环中" : ""}`;
  return `<button type="button" class="dag-node" data-task-id="${escapeHtml(task.taskId)}" data-task-status="${escapeHtml(view.key)}" data-task-rank="${position.rank}" data-task-row="${position.row}"${cyclic ? ' data-cyclic="true"' : ""} aria-pressed="${selected}" title="${escapeHtml(full)}" aria-label="${escapeHtml(full)}">
    <span class="dag-node-head"><code>${escapeHtml(task.taskId)}</code><span class="dag-node-status" data-task-status="${escapeHtml(view.key)}">${escapeHtml(view.label)}</span>${cyclic ? `<span class="dag-node-cyclic">cyclic</span>` : ""}</span>
    <span class="dag-node-title">${escapeHtml(title)}</span>
    <span class="dag-node-owner">owner <code>${escapeHtml(owner)}</code></span>
  </button>`;
}

// A dependency that is not part of the current Team stays visible as a marker, never as a real
// selectable node, so the node set is exactly the Team Task set.
function dagMissingHtml(dependencyId, layout) {
  const title = `依赖 ${dependencyId} 不在当前 Team 的 Task 投影中`;
  const rank = layout.positions.get(dependencyId)?.rank ?? 0;
  return `<span class="dag-node dag-missing" data-missing-dep="${escapeHtml(dependencyId)}" data-task-rank="${rank}" title="${escapeHtml(title)}" aria-label="${escapeHtml(title)}"><code>${escapeHtml(dependencyId)}</code><span class="dag-node-status">缺失</span></span>`;
}

// `nodeHtml` 默认就是 current 页的可交互节点渲染器；归档页传入自己的静态渲染器，从而复用同一
// 套列/边几何，却不会继承 current 页的选择语义。
function dagColumnsHtml(model, layout, nodeHtml = dagNodeHtml) {
  return layout.ranks.map((rank) => {
    const nodes = layout.columns.get(rank).map((id) => (
      model.missingDependencies.has(id) ? dagMissingHtml(id, layout) : nodeHtml(model.byId.get(id), model, layout)
    )).join("");
    return `<div class="dag-col" data-rank="${rank}">${nodes}</div>`;
  }).join("");
}

function dagDetailHtml(teamTasksById) {
  const selected = selectedTaskView();
  if (!selected) return `<p class="dag-detail-empty">未选择 Task：点击上方节点、左栏 Agent 的 Task chip，或 Tasks 视图中的 Task 标题查看只读详情。</p>`;
  if (!teamTasksById.has(selected.taskId)) {
    return `<p class="dag-detail-empty">选中的 Task <code>${escapeHtml(selected.taskId)}</code> 不属于当前 Team，暂无 DAG 详情。切换 Team 或重新选择一个 Task。</p>`;
  }
  const progress = taskProgress(selected);
  const view = taskChipStatusView(selected.status);
  const owner = selected.ownerAgentId ?? "未指定";
  return `<section class="dag-detail" data-task-id="${escapeHtml(selected.taskId)}" data-task-status="${escapeHtml(view.key)}">
    <header class="dag-detail-head">
      <span class="task-status" data-task-status="${escapeHtml(view.key)}">${escapeHtml(view.label)}</span>
      <h4>${escapeHtml(selected.title ?? selected.taskId)}</h4>
      <code class="task-id">${escapeHtml(selected.taskId)}</code>
    </header>
    <p class="dag-detail-meta">
      <span>owner <code>${escapeHtml(owner)}</code></span>
      <span>execution <code>${escapeHtml(selected.executionType ?? "normal")}</code></span>
      <span>attempt <code>${escapeHtml(progress.attemptLabel)}</code>${progress.attemptStatus ? ` · ${escapeHtml(taskStatusLabels[progress.attemptStatus] ?? progress.attemptStatus)}` : ""}</span>
      <span>attempts <code>${progress.historical}</code></span>
    </p>
    <h5>Dependencies</h5><p class="detail-line">${dependencyChipHtml(selected, teamTasksById)}</p>
    <h5>Attempts</h5>${attemptRowsHtml(selected)}
    <h5>Result</h5>${detailValue(selected.result)}
    <h5>Failure</h5>${detailValue(selected.failure)}
    <h5>Recovery</h5>${detailValue(selected.recovery)}
  </section>`;
}

function dagBodyHtml(context, teamTasks) {
  if (!context) return `<p class="dag-empty">暂无 Team/Task 投影：Coordinator 创建 Team 后这里会显示依赖 DAG。</p>`;
  if (teamTasks.length === 0) {
    return `<p class="dag-empty">当前 Team（${escapeHtml(context.team.teamId)}）暂无 Task。</p>${dagDetailHtml(new Map())}`;
  }
  const model = dagModel(teamTasks);
  const layout = dagLayout(model);
  const teamTasksById = new Map(teamTasks.map((task) => [task.taskId, task]));
  return `<div class="dag-scroll" tabindex="0" role="group" aria-label="${escapeHtml(`${context.team.teamId} 的任务依赖 DAG，横向滚动区域`)}">
      <div class="dag-canvas">
        ${dagEdgesHtml(model, layout)}
        <div class="dag-columns">${dagColumnsHtml(model, layout)}</div>
      </div>
    </div>
    ${dagDetailHtml(teamTasksById)}`;
}

function renderDag() {
  // 视觉降级（A.6）：任务依赖是一个默认折叠的辅助面板。空 Team、空 DAG 或完全没有依赖边时
  // 不占空间；只有真的存在依赖关系时 Auto 展开。用户手动开合过后就完全听用户的。
  if (!dagUserToggled) {
    const context = currentTeamContext();
    const contextTasks = context ? teamTasksOf(context.team.teamId) : [];
    const hasEdge = contextTasks.some((task) => (task.dependencies ?? []).length > 0);
    dagPanel.open = hasEdge;
  }
  // Remember whether the focused control was a DAG node: the innerHTML refresh below would
  // otherwise drop keyboard focus on every live update.
  const active = document.activeElement;
  const focusedTaskId = active && typeof active.closest === "function" && active.closest("#task-dag-body")
    ? active.dataset?.taskId ?? null
    : null;
  // The `.dag-scroll` container is focusable (tabindex=0) and owns the horizontal/vertical scroll
  // position, and its subtree is replaced below. Capture both before the write so a render (plain
  // or SSE-triggered) neither jumps back to the origin nor loses container focus.
  const previousScroll = dagBody.querySelector(".dag-scroll");
  const scrollOffsets = previousScroll ? { left: previousScroll.scrollLeft, top: previousScroll.scrollTop } : null;
  const scrollHadFocus = Boolean(previousScroll) && active === previousScroll;
  const context = currentTeamContext();
  const teamTasks = context ? teamTasksOf(context.team.teamId) : [];
  if (context) {
    const { total, completed, active: running, blocked, failed } = teamTaskStats(teamTasks);
    dagMeta.textContent = `${context.team.title ?? context.team.teamId} · ${total} Task · 完成 ${completed} · 运行 ${running} · 阻塞 ${blocked} · 未完成终态 ${failed}`;
  } else {
    dagMeta.textContent = "暂无 Team 投影";
  }
  dagBody.innerHTML = dagBodyHtml(context, teamTasks);
  // Empty states render no scroll container, so both restores degrade to a no-op.
  const nextScroll = dagBody.querySelector(".dag-scroll");
  if (nextScroll && scrollOffsets) {
    nextScroll.scrollLeft = scrollOffsets.left;
    nextScroll.scrollTop = scrollOffsets.top;
  }
  if (scrollHadFocus && nextScroll && typeof nextScroll.focus === "function") nextScroll.focus({ preventScroll: true });
  if (focusedTaskId) {
    const restored = dagBody.querySelector(`[data-task-id="${cssEscape(focusedTaskId)}"]`);
    if (restored && typeof restored.focus === "function") restored.focus({ preventScroll: true });
  }
}

// --- archived Task dependency DAG (read-only, one selected archive Team) -------
// 归档页的依赖图与 current 页共享纯模型与几何（dagModel / dagLayout / dagEdgesHtml /
// dagColumnsHtml），但节点是静态标记：不读取也不写入 `selectedTaskId`，不注册点击 handler，
// 没有 owner 行与 Task 详情面板，因此它不可能触发 selectTask() 或任何写路径。

// 归档节点：只显示 taskId、状态与最多两行的标题；保留 cyclic 语义，但不带选择语义。
function archiveDagNodeHtml(task, model, layout) {
  const position = layout.positions.get(task.taskId);
  const view = taskChipStatusView(task.status);
  const cyclic = model.cyclic.has(task.taskId);
  const title = task.title ?? task.taskId;
  const full = `归档 Task ${task.taskId}，${view.label}，${title}${cyclic ? "，处于依赖环中" : ""}（只读）`;
  return `<span class="dag-node dag-node-static" data-archive-task-id="${escapeHtml(task.taskId)}" data-task-status="${escapeHtml(view.key)}" data-task-rank="${position.rank}" data-task-row="${position.row}"${cyclic ? ' data-cyclic="true"' : ""} title="${escapeHtml(full)}">
    <span class="dag-node-head"><code>${escapeHtml(task.taskId)}</code><span class="dag-node-status" data-task-status="${escapeHtml(view.key)}">${escapeHtml(view.label)}</span>${cyclic ? `<span class="dag-node-cyclic">cyclic</span>` : ""}</span>
    <span class="dag-node-title">${escapeHtml(title)}</span>
  </span>`;
}

// 真伪条目的分界：只有真实 Team（soft archived / DISSOLVED / previous）才拥有一一对应的 Task 图。
// `unassigned` 与 `retiredOnly` 都必须走专门空态，绝不能把当前 Team 的 Task 泄漏进归档页。
function archiveDagBodyHtml(entry, teamTasks) {
  if (!entry) return `<p class="dag-empty">未选择归档 Team：在左侧选择一个归档 Team 后，这里显示该 Team 的只读任务依赖图。</p>`;
  if (entry.unassigned) return `<p class="dag-empty">未归属历史 Agent 没有 Team / Task 投影，因此没有依赖图。</p>`;
  if (entry.retiredOnly) return `<p class="dag-empty">「当前 Team · 已退役 Agent」只是成员归档入口，不代表该 Team 的历史状态；当前 Team 的任务依赖图见「当前团队」页。</p>`;
  if (teamTasks.length === 0) return `<p class="dag-empty">归档 Team（${escapeHtml(entry.teamId)}）暂无 Task。</p>`;
  const model = dagModel(teamTasks);
  const layout = dagLayout(model);
  const label = `${entry.teamId} 的归档任务依赖 DAG，只读横向滚动区域`;
  return `<div class="dag-scroll" tabindex="0" role="group" aria-label="${escapeHtml(label)}">
      <div class="dag-canvas">
        ${dagEdgesHtml(model, layout)}
        <div class="dag-columns">${dagColumnsHtml(model, layout, archiveDagNodeHtml)}</div>
      </div>
    </div>`;
}

function archiveDagMetaText(entry, teamTasks) {
  if (!entry) return "未选择归档 Team";
  if (entry.unassigned) return "未归属历史 · 无 Task 投影";
  if (entry.retiredOnly) return "当前 Team · 已退役 Agent · 无独立 Task 图";
  const { total, completed, active: running, blocked, failed } = teamTaskStats(teamTasks);
  return `${entry.team.title ?? entry.teamId} · ${total} Task · 完成 ${completed} · 运行 ${running} · 阻塞 ${blocked} · 未完成终态 ${failed}`;
}

// 把“当前归档 DAG DOM”的滚动位置写回它所属 Team 的 key。只有同时满足以下条件才写：
//   - 本次 visit 的 DOM 仍然 live（`archiveDagLive`，离开归档 tab 即复位）；
//   - 面板展开：折叠时 `.dag-scroll` 没有布局盒，偏移读作 0，写回会毁掉真实位置；
//   - 正在渲染的是一个真实 Team（伪条目 / 未选择时 `renderedArchiveDagTeamId` 为 null）；
//   - 容器确实存在且有可滚动内容。
// 因此折叠、隐藏 tab 的遗留 DOM、伪条目和空态都不会用 0 覆盖已保存值。
function captureArchiveDagScroll() {
  if (!archiveDagLive || !renderedArchiveDagTeamId) return;
  if (!archiveDagPanel?.open) return;
  const node = archiveDagBody?.querySelector(".dag-scroll");
  if (!node) return;
  if (typeof node.closest === "function" && node.closest("[hidden]")) return;
  if (!node.scrollHeight && !node.clientHeight) return;
  archiveDagScrollPositions.set(renderedArchiveDagTeamId, { left: node.scrollLeft, top: node.scrollTop });
}

// 只恢复“本次正在渲染的 Team”的偏移：新 Team 没有记录时保持原点，绝不套用上一个 Team 的值。
function restoreArchiveDagScroll() {
  if (!renderedArchiveDagTeamId) return;
  const saved = archiveDagScrollPositions.get(renderedArchiveDagTeamId);
  const node = archiveDagBody?.querySelector(".dag-scroll");
  if (!saved || !node) return;
  node.scrollLeft = saved.left;
  node.scrollTop = saved.top;
}

// 归档 DAG 的唯一渲染入口：在 renderArchive() 里随所选 Team 一起重建。
function renderArchiveDag(entry) {
  if (!archiveDagPanel || !archiveDagMeta || !archiveDagBody) return;
  // 顺序是修复的关键：先用仍在屏幕上的旧 DOM 保存“正在离开/正在重渲染”的那个 Team 的滚动位置，
  // 再按新 entry 决定自动开合。反过来的话，从有边 Team 切到无边 Team/伪条目时，自动折叠会先把
  // 面板关掉，旧 DOM 随即失去布局盒、偏移读作 0，最后一次真实位置就丢了。
  captureArchiveDagScroll();

  // 只有真实 Team 才有图；伪条目与未选择状态一律算空。
  const realTeamId = entry && !entry.unassigned && !entry.retiredOnly ? entry.teamId : null;
  const teamTasks = realTeamId ? teamTasksOf(realTeamId) : [];
  const hasEdge = teamTasks.some((task) => (task.dependencies ?? []).length > 0);
  // 自动展开只服从数据形状，且仅在用户从未手动开合过归档面板时生效。
  if (!archiveDagUserToggled) archiveDagPanel.open = hasEdge;

  const active = document.activeElement;
  const previousScroll = archiveDagBody.querySelector(".dag-scroll");
  const scrollHadFocus = Boolean(previousScroll) && active === previousScroll;

  archiveDagMeta.textContent = archiveDagMetaText(entry, teamTasks);
  archiveDagBody.innerHTML = archiveDagBodyHtml(entry, teamTasks);
  renderedArchiveDagTeamId = realTeamId;

  restoreArchiveDagScroll();
  const nextScroll = archiveDagBody.querySelector(".dag-scroll");
  if (scrollHadFocus && nextScroll && typeof nextScroll.focus === "function") nextScroll.focus({ preventScroll: true });
  // 重建后的 DOM 属于本次归档 visit；离开归档 tab 时由 selectTab() 复位为 false。
  archiveDagLive = selectedTab === "archive";
}

// --- shell / render ----------------------------------------------------------

// DAG 面板的自动折叠只服从数据形状；用户一旦手动开合，就永远以用户的选择为准。
let dagUserToggled = false;
dagPanel?.querySelector(".task-dag-summary")?.addEventListener("click", () => {
  dagUserToggled = true;
});

// 归档面板有自己的手动开合标记：current 页的 DAG 开合与归档页互不影响，反之亦然。
archiveDagPanel?.querySelector(".task-dag-summary")?.addEventListener("click", () => {
  archiveDagUserToggled = true;
});

// 折叠期间不会有 render，所以“重新展开”必须自己把该 Team 的已保存偏移贴回 DOM。这里只读不写：
// 展开不是一次真实的用户滚动，绝不能覆盖 archiveDagScrollPositions。
archiveDagPanel?.addEventListener("toggle", () => {
  if (!archiveDagPanel.open) return;
  restoreArchiveDagScroll();
});

function setConnection(state, note) {
  connection.dataset.state = state;
  connectionText.textContent = note;
}

// 状态栏的“更新时间”是纯展示摘要：任何一次投影变化都算一次更新，包括一键同步成功。
function markUpdated(label) {
  updatedMetric.textContent = label ?? timeLabel(new Date().toISOString());
}

// --- 一键同步设置 -------------------------------------------------------------
// 按钮只做四件事：进入 syncing、POST /api/sync-settings、按响应进入 success/error、
// 成功后刷新模型设置与更新时间。同步本身在 server 侧跑 Sync-DshTeamConfig.ps1 的安全 CLI，
// 绝不重启 Monitor，所以这里也不做任何重连或页面刷新。

let syncState = "idle";
let syncResetTimer = null;

function syncIdleHint() {
  const availability = modelSettings?.settingsSync ?? null;
  if (availability && availability.available === false) return availability.reason ?? "";
  const last = modelSettings?.lastSync;
  if (!last?.syncedAt) return "";
  return `上次同步 ${timeLabel(last.syncedAt)}${last.provider && last.model ? ` · ${last.provider} / ${last.model}` : ""}`;
}

function setSyncState(state, message) {
  syncState = state;
  syncButton.dataset.state = state;
  syncButton.disabled = state === "syncing";
  syncButton.setAttribute("aria-busy", state === "syncing" ? "true" : "false");
  const unavailable = modelSettings?.settingsSync?.available === false;
  if (unavailable && state !== "syncing") syncButton.disabled = true;
  if (message !== undefined) syncMessage.textContent = message;
  if (syncResetTimer) {
    clearTimeout(syncResetTimer);
    syncResetTimer = null;
  }
  // 成功/失败提示只是短暂反馈，8 秒后回到 idle 并恢复常态摘要。
  if (state === "success" || state === "error") {
    syncResetTimer = setTimeout(() => {
      syncResetTimer = null;
      syncState = "idle";
      syncButton.dataset.state = unavailable ? "unavailable" : "idle";
      syncButton.disabled = unavailable;
      syncMessage.textContent = syncIdleHint();
    }, 8000);
  }
}

function describeSyncResult(value) {
  const model = value?.provider && value?.model ? `${value.provider} / ${value.model}` : "模型设置";
  const changed = Array.isArray(value?.changed) ? value.changed.length : 0;
  return changed > 0 ? `已同步 ${model} · ${changed} 项变更` : `${model} 已是最新`;
}

async function syncSettingsFromUi() {
  if (syncState === "syncing") return;
  setSyncState("syncing", "正在同步 DSH 设置…");
  try {
    const response = await fetch("/api/sync-settings", { method: "POST" });
    const value = await response.json().catch(() => ({}));
    if (!response.ok) {
      const reason = typeof value?.error === "string" ? value.error : `HTTP ${response.status}`;
      throw new Error(reason);
    }
    // server 已重新读取 catalog 并广播 model-settings；这里再按响应刷新一次，保证即使 SSE
    // 尚未到达，模型控件与更新时间也立刻反映同步结果。
    if (value.modelSettings) renderModelSettings(value.modelSettings);
    else await refreshModelSettings();
    markUpdated();
    setSyncState("success", describeSyncResult(value));
  } catch (error) {
    setSyncState("error", `同步失败：${error.message}`);
  }
}

async function refreshModelSettings() {
  try {
    const response = await fetch("/api/model-settings");
    if (!response.ok) return;
    renderModelSettings(await response.json());
  } catch {
    // 广播仍然会修正显示；这里不需要额外噪音。
  }
}

syncButton.addEventListener("click", () => void syncSettingsFromUi());

const TAB_IDS = ["current", "archive", "tasks"];

// T032-R3: a detail pane may only be used as a scroll *source* while its own tab is on screen and
// its DOM still belongs to that visit. Hiding a tab makes the pane report a clamped (zero) offset,
// so re-entering a page must never re-capture from that stale DOM before restoring the saved value.
let currentPaneLive = false;
let archivePaneLive = false;

// Saves the active page's offset while its pane is still visible and live, i.e. before `hidden` is
// flipped. This must run for a same-tab reselect too: on a quiet page nothing has saved the offset
// the user scrolled to since the last render, so skipping the save would restore that stale value
// and visibly jump the conversation back.
function saveActiveTabScroll() {
  if (selectedTab === "current" && currentPaneLive) {
    captureScrollPosition(detailPane, scrollPositions, renderedAgentId);
  } else if (selectedTab === "archive") {
    // 归档页有两个独立滚动容器：Agent 对话详情与归档 Task DAG。两者各有自己的 live 守卫，
    // 所以离开归档 tab 前会在这里把 DAG 的最后位置一并保存（此刻它仍在屏幕上）。
    if (archivePaneLive) captureScrollPosition(archivePane, archiveScrollPositions, renderedArchiveAgentId);
    captureArchiveDagScroll();
  }
}

// Tab switching is purely a frontend state change: it never fetches, never re-binds a session
// and never forces the user away from the page they are reading.
function selectTab(tab) {
  if (!TAB_IDS.includes(tab)) return;
  // Order matters: remember the active reading position first (a no-op while the pane is not live,
  // so the very first selection cannot capture stale DOM), then swap visibility, then let the
  // incoming page restore its own Agent's position during the render below.
  saveActiveTabScroll();
  selectedTab = tab;
  currentPaneLive = false;
  archivePaneLive = false;
  // 归档 DAG 的 DOM 从此不再属于任何可见 visit：重进归档页时旧的隐藏 DOM 不得被当作 live 源。
  archiveDagLive = false;
  for (const button of tabButtons) {
    const active = button.dataset.tab === tab;
    button.setAttribute("aria-selected", active ? "true" : "false");
    button.tabIndex = active ? 0 : -1;
  }
  panelCurrent.hidden = tab !== "current";
  panelArchive.hidden = tab !== "archive";
  panelTasks.hidden = tab !== "tasks";
  render();
}

for (const button of tabButtons) {
  button.addEventListener("click", () => selectTab(button.dataset.tab));
}

document.querySelector(".view-tabs")?.addEventListener("keydown", (event) => {
  const keys = { ArrowRight: 1, ArrowLeft: -1, Home: "first", End: "last" };
  if (!(event.key in keys)) return;
  event.preventDefault();
  const current = tabButtons.findIndex((button) => button.dataset.tab === selectedTab);
  const step = keys[event.key];
  const next = step === "first" ? 0 : step === "last" ? tabButtons.length - 1 : (current + step + tabButtons.length) % tabButtons.length;
  selectTab(tabButtons[next].dataset.tab);
  tabButtons[next].focus();
});

// Scroll offsets are tracked per page and per Agent, so scrolling an archived conversation never
// moves the current page's reading position (and vice versa).
function captureScrollPosition(pane, map, agentId) {
  if (!pane || !agentId) return;
  // A pane inside a hidden tab has no layout, so its metrics read as zero. Capturing that would
  // silently replace the real offsets of the page the user returns to.
  if (typeof pane.closest === "function" && pane.closest("[hidden]")) return;
  if (!pane.scrollHeight && !pane.clientHeight) return;
  const nearBottom = pane.scrollHeight - pane.scrollTop - pane.clientHeight <= SCROLL_BOTTOM_THRESHOLD;
  map.set(agentId, { top: pane.scrollTop, nearBottom });
}

function restoreScrollPosition(pane, map, agentId) {
  if (!pane) return;
  const saved = map.get(agentId);
  if (!saved) {
    pane.scrollTop = pane.scrollHeight;
    return;
  }
  pane.scrollTop = saved.nearBottom ? pane.scrollHeight : saved.top;
}

// Renders the whole archive page. It is a pure projection of the existing state: no fetch, no
// session work, and the only controls it emits are selection buttons.
function archiveTeamButtonHtml(entry) {
  const view = entry.unassigned
    ? { key: "legacy", label: "未归属", meta: null }
    : entry.retiredOnly
      ? { key: "retired", label: "已退役", meta: null }
      : archiveTeamView(entry.team);
  const selected = entry.teamId === selectedArchiveTeamId;
  const meta = [
    entry.unassigned ? "teamId 缺失" : entry.teamId,
    `Task ${entry.taskCount}`,
    entry.retiredOnly ? `退役成员 ${entry.retiredCount}` : (view.meta ? timeLabel(view.meta) : null),
  ].filter(Boolean).join(" · ");
  return `<button type="button" class="archive-team" data-archive-team-id="${escapeHtml(entry.teamId)}" data-archive-team-status="${escapeHtml(view.key)}" data-selected="${selected}" aria-pressed="${selected}">
    <span class="archive-team-head">
      <span class="archive-team-title">${escapeHtml(entry.team.title ?? entry.team.teamId)}</span>
      <span class="archive-team-badge" data-archive-team-status="${escapeHtml(view.key)}">${escapeHtml(view.label)}</span>
    </span>
    <span class="archive-team-meta">${escapeHtml(meta)}</span>
  </button>`;
}

function renderArchive() {
  renderTarget = "archive";
  // T032-R4: only called while the archive tab is on screen (or from the first entry into it), so
  // the whole page is rebuilt fresh here and a hidden archive is never reconstructed.
  const entries = archiveTeamEntries();
  if (selectedArchiveTeamId && !entries.some((entry) => entry.teamId === selectedArchiveTeamId)) {
    selectedArchiveTeamId = null;
  }
  if (!selectedArchiveTeamId && entries.length > 0) selectedArchiveTeamId = entries[0].teamId;
  const selectedArchiveEntry = entries.find((entry) => entry.teamId === selectedArchiveTeamId) ?? null;
  const views = archiveAgentsOf(selectedArchiveEntry);
  if (selectedArchiveAgentId && !views.some((agent) => agent.agentId === selectedArchiveAgentId)) {
    selectedArchiveAgentId = null;
  }
  if (!selectedArchiveAgentId && views.length > 0) selectedArchiveAgentId = views[0].agentId;
  const selected = views.find((agent) => agent.agentId === selectedArchiveAgentId) ?? null;

  // T032-R3: capture only from a live pane, never from the stale DOM left by a previous visit.
  if (archivePaneLive) captureScrollPosition(archivePane, archiveScrollPositions, renderedArchiveAgentId);
  archiveTeamList.innerHTML = entries.map(archiveTeamButtonHtml).join("");
  archiveEmpty.hidden = entries.length > 0;
  // The archive list is the same compact 3-line projection, and its Details stay read-only: no
  // selection affordance and no write path can reach the current page from an archived Team.
  // 归档列表与归档 Details 共享同一个显式 Team scope：真实/退役 Team 传所选 Team ID，
  // 未归属伪条目传 sentinel，因此 null 永远不会退化成“跨 Team 全部 Task”。
  const archiveTaskTeamId = selectedArchiveEntry?.teamId === UNASSIGNED_TEAM_ID
    ? UNASSIGNED_TEAM_ID
    : (selectedArchiveEntry?.teamId ?? null);
  archiveAgentList.innerHTML = views
    .map((agent) => navItemHtml(agent, { selectedId: selectedArchiveAgentId, teamId: archiveTaskTeamId }))
    .join("");
  archiveAgentEmpty.hidden = views.length > 0;
  archiveAgentEmpty.textContent = selectedArchiveTeamId ? "该 Team 没有 Agent 记录。" : "未选择归档 Team。";
  archiveEmptyState.hidden = Boolean(selected);
  archiveDetail.hidden = !selected;
  renderedArchiveAgentId = selected?.agentId ?? null;
  archiveDetail.innerHTML = selected ? detailHtml(selected, true, archiveTaskTeamId) : "";
  if (selected) restoreScrollPosition(archivePane, archiveScrollPositions, selected.agentId);
  archivePaneLive = selectedTab === "archive";
  // 归档任务依赖图只跟随所选的真实历史 Team：Team 切换、Team 消失或选中伪条目都会在同一次
  // render 里立即重建或清空，绝不残留上一个 Team 的图。
  renderArchiveDag(selectedArchiveEntry);
  renderTarget = "current";
}

function render() {
  // T018-F02: the `innerHTML` writes below would drop keyboard focus from the selected Agent card
  // or a Task chip on every live update. Remember it and restore after the redraw.
  const activeElement = document.activeElement;
  const focusedAgentId = activeElement && typeof activeElement.closest === "function"
    ? activeElement.closest("#agent-list [data-agent-id]")?.dataset?.agentId ?? null
    : null;
  const values = agentGroups();
  renderedAgents = values;
  prunePendingAgentActions();
  // The current page shows the current Team only; every other Team (archived, DISSOLVED or a
  // previous non-current Team) is owned by the archive page. `terminated` members stay in
  // `renderedAgents`（归档页仍然找得到），但绝不进入当前 Team 列表。
  const context = currentTeamContext();
  const currentTeamId = context?.team.teamId ?? null;
  const currentViews = currentTeamId ? values.filter((agent) => agent.teamId === currentTeamId && !agent.terminated) : [];

  if (selectedAgentId && !currentViews.some((agent) => agent.agentId === selectedAgentId)) {
    selectedAgentId = null;
  }
  // A newly spawned Agent never steals the current selection.
  if (!selectedAgentId && currentViews.length > 0) selectedAgentId = currentViews[0].agentId;
  // A selected Task that left the projection is dropped instead of leaving a stale chip.
  if (selectedTaskId && !tasks.has(selectedTaskId)) selectedTaskId = null;

  const selected = currentViews.find((agent) => agent.agentId === selectedAgentId) ?? null;
  // T032-R3: the current page only reads/writes its own scroll offset while its tab is on screen;
  // a hidden pane reports clamped metrics and must never overwrite the saved reading position.
  const currentTabActive = selectedTab === "current";
  if (currentTabActive && currentPaneLive) captureScrollPosition(detailPane, scrollPositions, renderedAgentId);
  renderTarget = "current";

  teamSummary.innerHTML = teamSummaryHtml(values);
  list.innerHTML = currentViews.map((agent) => navItemHtml(agent, { teamId: currentTeamId })).join("");
  sidebarEmpty.hidden = currentViews.length > 0;
  sidebarEmpty.textContent = currentTeamId
    ? (values.some((agent) => agent.teamId === currentTeamId && agent.terminated)
      ? "该 Team 暂无在役 Agent（退役成员见「归档对话」）"
      : "该 Team 暂无 Agent")
    : "暂无当前 Team（历史 Agent 见「归档对话」）";
  empty.hidden = Boolean(selected);
  agentDetail.hidden = !selected;

  renderedAgentId = selected?.agentId ?? null;
  agentDetail.innerHTML = selected ? detailHtml(selected, false, currentTeamId) : "";
  if (selected && currentTabActive) restoreScrollPosition(detailPane, scrollPositions, selected.agentId);
  currentPaneLive = currentTabActive;

  // 退役成员由归档页展示，不计入当前页的 Agent 摘要。
  const visibleAgents = values.filter((agent) => !agent.terminated);
  const activeAgents = visibleAgents.filter((agent) => isActiveStatus(agent.status)).length;
  const totalTurns = visibleAgents.reduce((sum, agent) => sum + agent.turnCount, 0);
  // 状态栏摘要：Agent（含活动数与 Turn 总数）+ 最近一次投影时间。Team/Task 摘要在
  // renderTasks() 里写，因为那里才是 Task 投影的唯一来源。
  agentMetric.textContent = `${visibleAgents.length}（活动 ${activeAgents} · Turn ${totalTurns}）`;
  const latest = values.map((agent) => agent.lastUpdatedUtc).filter(Boolean).sort().at(-1) ?? null;
  if (latest) markUpdated(timeLabel(latest));

  renderTasks();
  renderDag();
  // T032-R4: the archive page is rebuilt only while it is on screen. The registry/SSE maps keep
  // updating, but a hidden archive is not re-rendered on every live tick; it is rebuilt fresh on
  // the next entry, which is also when its selection and offset are re-derived.
  if (selectedTab === "archive") renderArchive();
  if (focusedAgentId) {
    const card = list.querySelector(`[data-agent-id="${cssEscape(focusedAgentId)}"]`);
    if (card && typeof card.focus === "function") card.focus({ preventScroll: true });
  }
}

function scheduleRender() {
  if (renderTimer) return;
  renderTimer = setTimeout(() => {
    renderTimer = undefined;
    render();
  }, 120);
}

// Selection is presentational only: no fetch/dispatch/session/Git side effects. The compact
// sidebar card carries no Task chips any more, so this handler is the Agent choice itself.
list.addEventListener("click", (event) => {
  const card = event.target.closest("[data-agent-id]");
  if (!card) return;
  selectedAgentId = card.dataset.agentId;
  render();
});

// Archive browsing state is frontend-only and isolated from the current page: switching the
// archived Team or Agent re-renders locally and never issues a write request.
archiveTeamList.addEventListener("click", (event) => {
  const button = event.target.closest("[data-archive-team-id]");
  if (!button) return;
  const teamId = button.dataset.archiveTeamId;
  if (!archiveTeamEntries().some((entry) => entry.teamId === teamId)) return;
  selectedArchiveTeamId = teamId;
  // A different Team brings its own Agent list, so the archived Agent selection is re-derived.
  selectedArchiveAgentId = null;
  render();
});

archiveAgentList.addEventListener("click", (event) => {
  const card = event.target.closest("[data-agent-id]");
  if (!card) return;
  const agentId = card.dataset.agentId;
  const entry = archiveTeamEntries().find((item) => item.teamId === selectedArchiveTeamId) ?? null;
  if (!entry || !archiveAgentsOf(entry).some((agent) => agent.agentId === agentId)) return;
  selectedArchiveAgentId = agentId;
  render();
});

// DAG nodes and the Tasks-view row headers share the same presentational selection: they only
// write `selectedTaskId` and never issue a request or touch the Agent conversation.
dagBody.addEventListener("click", (event) => {
  const node = event.target.closest(".dag-node[data-task-id]");
  if (!node) return;
  selectTask(node.dataset.taskId);
});

taskGroups.addEventListener("click", (event) => {
  const select = event.target.closest(".task-select");
  if (!select) return;
  selectTask(select.dataset.taskId);
});

agentDetail.addEventListener("click", async (event) => {
  // Task chips inside the Agent Details keep the same presentational selection as the DAG:
  // they only write `selectedTaskId` and never issue a request.
  const chip = event.target.closest("[data-task-id]");
  if (chip) {
    selectTask(chip.dataset.taskId);
    return;
  }
  // Agent 级操作（中止任务 / 退役 Agent）：只从实时投影重新读取 expected IDs，
  // 陈旧页面不会把旧 Task/Run 的期望值发到新投影上。
  const action = event.target.closest("[data-agent-action]");
  if (action) {
    if (action.disabled) return;
    const agent = renderedAgents.find((item) => item.agentId === action.dataset.agentId) ?? null;
    if (agent) void runAgentAction(agent, action.dataset.agentAction);
    return;
  }
  const button = event.target.closest("[data-cancel-run]");
  if (!button || button.disabled) return;
  button.disabled = true;
  try {
    const response = await fetch(`/api/runs/${encodeURIComponent(button.dataset.cancelRun)}/cancel`, { method: "POST" });
    if (!response.ok) throw new Error(String(response.status));
  } catch {
    button.disabled = false;
  }
});

function providerById(providerId) {
  return modelSettings?.providers?.find((provider) => provider.id === providerId) ?? null;
}

function renderModelOptions(preferredModel = null) {
  const provider = providerById(modelProvider.value);
  modelName.replaceChildren();
  for (const model of provider?.models ?? []) {
    const option = document.createElement("option");
    option.value = model.id;
    option.textContent = model.name === model.id ? model.id : `${model.name} (${model.id})`;
    modelName.append(option);
  }
  if (preferredModel && [...modelName.options].some((option) => option.value === preferredModel)) {
    modelName.value = preferredModel;
  } else if (preferredModel) {
    modelName.selectedIndex = -1;
  }
  modelName.disabled = modelName.options.length === 0;
  const selected = (provider?.models ?? []).find((item) => item.id === modelName.value);
  const context = selected?.contextWindow ? `上下文 ${selected.contextWindow.toLocaleString()}` : null;
  const modalities = selected?.input?.length ? `输入 ${selected.input.join(" + ")}` : null;
  modelProviderMeta.textContent = [provider?.api, provider?.catalogInherited ? "模型目录由运行时继承" : `${provider?.models?.length ?? 0} 个模型`, context, modalities]
    .filter(Boolean).join(" · ");
}

function renderModelSettings(value) {
  // PATCH responses and the ordered SSE stream travel independently. Never let an older HTTP
  // response roll the control back after another tab's newer SSE projection has already landed.
  if (!shouldAcceptModelProjection(modelSettings, value)) return false;
  modelSettings = value ?? null;
  const providers = modelSettings?.providers ?? [];
  const effective = modelSettings?.selection ?? modelSettings?.effective ?? modelSettings?.dshDefault ?? null;
  modelProvider.replaceChildren();
  for (const provider of providers) {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = provider.models?.length ? provider.name : `${provider.name}（运行时继承目录）`;
    option.disabled = !provider.models?.length;
    modelProvider.append(option);
  }
  const selected = modelFormSelection(modelSettings);
  const hasAvailable = providers.some((provider) => provider.models?.length);
  modelProvider.value = selected.provider;
  modelProvider.disabled = !hasAvailable;
  renderModelOptions(effective?.model ?? null);
  modelCurrent.textContent = effective
    ? `${effective.provider} / ${effective.model}${modelSettings?.mode === "override" ? " · Override" : " · DSH 默认"}`
    : "模型配置不可用";
  modelMessage.textContent = modelSettings?.error ?? (selected.valid
    ? "跟随默认时读取主 DSH 配置；下一次任务会自动同步已更改的设置。"
    : "默认模型不可用，请检查 DSH 配置或明确选择供应商和模型。");
  modelMessage.dataset.state = modelSettings?.error || !selected.valid ? "error" : "ready";
  modelFollowDefault.disabled = modelSettings?.mode === "dsh-default";
  modelForm.querySelector('[type="submit"]').disabled = !modelProvider.value || !modelName.value;
  // 同步按钮的可用性来自 server：只有主/Team Home 都配置且不同时才可点，原因直接写进提示，
  // 不让用户去猜为什么按钮没反应。
  const availability = modelSettings?.settingsSync ?? null;
  const unavailable = Boolean(availability) && availability.available === false;
  if (syncState !== "syncing") {
    syncButton.dataset.state = unavailable ? "unavailable" : "idle";
    syncButton.disabled = unavailable;
  }
  syncButton.title = unavailable
    ? availability.reason
    : "把主 DSH Home 的 provider / model / auth 同步到 Team Home；不重启 Monitor";
  if (syncState === "idle") syncMessage.textContent = syncIdleHint();
  return true;
}

async function saveModelPreference(selection) {
  const buttons = [...modelForm.querySelectorAll("button")];
  buttons.forEach((button) => { button.disabled = true; });
  modelMessage.textContent = "正在保存…";
  modelMessage.dataset.state = "saving";
  try {
    const response = await fetch("/api/model-settings", {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ selection, expectedRevision: modelSettings?.revision ?? 0 }),
    });
    const value = await response.json();
    if (!response.ok) throw new Error(value.error ?? `HTTP ${response.status}`);
    const accepted = renderModelSettings(value);
    if (!accepted) {
      modelMessage.textContent = "设置已由其他页面更新；当前显示保留较新的版本。";
      modelMessage.dataset.state = "ready";
      return;
    }
    modelMessage.textContent = selection
      ? "已保存；下一次 spawn / follow-up 会在 prompt 前应用。"
      : "已恢复跟随 DSH 默认模型。";
    modelMessage.dataset.state = "ready";
  } catch (error) {
    modelMessage.textContent = `保存失败：${error.message}`;
    modelMessage.dataset.state = "error";
    buttons.forEach((button) => { button.disabled = false; });
  }
}

modelProvider.addEventListener("change", () => {
  renderModelOptions();
  modelForm.querySelector('[type="submit"]').disabled = !modelProvider.value || !modelName.value;
});
modelName.addEventListener("change", () => {
  modelForm.querySelector('[type="submit"]').disabled = !modelProvider.value || !modelName.value;
});
modelForm.addEventListener("submit", (event) => {
  event.preventDefault();
  if (!modelProvider.value || !modelName.value) return;
  void saveModelPreference({ provider: modelProvider.value, model: modelName.value });
});
modelFollowDefault.addEventListener("click", () => void saveModelPreference(null));

const stream = new EventSource("/api/events");

stream.addEventListener("snapshot", (message) => {
  const value = JSON.parse(message.data);
  // A snapshot carries the full projection, so every map is replaced exactly like runs/agents:
  // otherwise a Team or Task that disappeared from the control plane would survive as a ghost row.
  runs.clear();
  agents.clear();
  teams.clear();
  tasks.clear();
  // From here on the live projection is authoritative; a slower bootstrap response must not
  // roll it back (T018-F04).
  snapshotApplied = true;
  for (const run of value.runs || []) runs.set(run.id, run);
  for (const agent of value.agents || []) agents.set(agent.agentId, agent);
  for (const team of value.teams || []) teams.set(team.teamId, team);
  for (const task of value.tasks || []) tasks.set(task.taskId, task);
  if (value.modelSettings) renderModelSettings(value.modelSettings);
  setConnection("connected", "实时连接");
  scheduleRender();
});

stream.addEventListener("run", (message) => {
  const run = JSON.parse(message.data);
  runs.set(run.id, run);
  scheduleRender();
});

stream.addEventListener("run-event", (message) => {
  const value = JSON.parse(message.data);
  const run = runs.get(value.runId);
  if (run && value.run) runs.set(value.runId, { ...run, ...value.run, events: [...(run.events ?? []), value.event] });
  scheduleRender();
});

stream.addEventListener("agent", (message) => {
  const agent = JSON.parse(message.data);
  agents.set(agent.agentId, agent);
  scheduleRender();
});

// vNext projections. Latest value wins; the raw SSE payloads are never rewritten.
stream.addEventListener("task", (message) => {
  const task = JSON.parse(message.data);
  if (task?.taskId) tasks.set(task.taskId, task);
  scheduleRender();
});

stream.addEventListener("team", (message) => {
  const team = JSON.parse(message.data);
  if (team?.teamId) teams.set(team.teamId, team);
  scheduleRender();
});

stream.addEventListener("model-settings", (message) => {
  renderModelSettings(JSON.parse(message.data));
});

stream.addEventListener("open", () => setConnection("connected", "实时连接"));
stream.addEventListener("error", () => setConnection("offline", "连接中断，自动重连中"));

setInterval(() => {
  for (const agent of renderedAgents) {
    // 当前 Task 用时与 agent.status 解耦：external 在 ASSIGNED（已派发未开工）阶段 agent.status
    // 可能仍是 idle，所以这个分支必须在 isActiveStatus 短路之前执行，否则计时会停摆。
    const timer = agentTaskTimerView(agent);
    if (timer?.state === TASK_TIMER_STATES.LIVE) {
      for (const node of document.querySelectorAll(`[data-task-elapsed="${cssEscape(agent.agentId)}"]`)) {
        node.textContent = timer.label;
        node.dataset.taskTimerState = timer.state;
        node.dataset.taskTimerPhase = timer.phase;
        node.dataset.taskTimerHasStart = timer.startUtc ? "true" : "false";
        if (timer.startUtc) {
          node.dataset.taskTimerStart = timer.startUtc;
          node.dataset.taskTimerSource = timer.startSource;
        } else {
          delete node.dataset.taskTimerStart;
          delete node.dataset.taskTimerSource;
        }
      }
    }
    if (!isActiveStatus(agent.status)) continue;
    const label = agentDurationLabel(agent);
    // The selected Agent has an elapsed node in both the sidebar and the detail pane.
    for (const node of document.querySelectorAll(`[data-agent-elapsed="${cssEscape(agent.agentId)}"]`)) {
      node.textContent = label;
    }
    for (const run of agent.turns) {
      if (!isActive(run)) continue;
      const runLabel = durationLabel(run);
      for (const node of document.querySelectorAll(`[data-run-elapsed="${cssEscape(run.id)}"]`)) {
        node.textContent = runLabel;
      }
    }
  }
}, 1000);

// The initial view is always the current Team. Live snapshots never call this again, so a new
// Team appearing while the user reads the archive page cannot pull them back to the current page.
selectTab("current");

// Read-only bootstrap: /api/runs carries the legacy projection and the vNext teams/tasks,
// while /api/teams and /api/tasks stay the authoritative Task/Task-DAG read endpoints.
async function bootstrap() {
  const generation = ++bootstrapGeneration;
  const [runsResult, tasksResult, teamsResult, modelResult] = await Promise.allSettled([
    fetch("/api/runs").then((response) => response.json()),
    fetch("/api/tasks").then((response) => response.json()),
    fetch("/api/teams").then((response) => response.json()),
    fetch("/api/model-settings").then((response) => response.json()),
  ]);
  // T018-F04: drop a stale bootstrap response. Once a live snapshot has been applied it owns the
  // projection, and a newer bootstrap call supersedes an older one; without a snapshot (or an SSE
  // connection) the bootstrap result is still what populates the UI.
  if (snapshotApplied || generation !== bootstrapGeneration) return;
  if (runsResult.status === "fulfilled") {
    const value = runsResult.value ?? {};
    for (const run of value.runs || []) runs.set(run.id, run);
    for (const agent of value.agents || []) agents.set(agent.agentId, agent);
    for (const team of value.teams || []) teams.set(team.teamId, team);
    for (const task of value.tasks || []) tasks.set(task.taskId, task);
  } else {
    setConnection("offline", "本地服务不可用");
  }
  if (tasksResult.status === "fulfilled") {
    for (const task of tasksResult.value?.tasks || []) tasks.set(task.taskId, task);
  }
  if (teamsResult.status === "fulfilled") {
    for (const team of teamsResult.value?.teams || []) teams.set(team.teamId, team);
  }
  if (modelResult.status === "fulfilled") renderModelSettings(modelResult.value);
  render();
}

void bootstrap();
