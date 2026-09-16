param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [string]$ContractRelativePath,

    [Parameter(Mandatory = $true)]
    [string]$AgentId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('code_explorer','coder','tester','code_reviewer','progress_recorder')]
    [string]$FormalRole,

    [Parameter(Mandatory = $true)]
    [ValidateSet('spawn','follow_up')]
    [string]$LifecycleAction,

    [string]$TaskId,
    [string]$Title,

    # vNext Team-managed explicit assignment. TeamId/AttemptId travel together with TaskId;
    # the monitor fences each attempt on taskId+attemptId and rejects unknown/duplicate ones.
    [string]$TeamId,
    [string]$AttemptId,

    # Team children always request the full-access preset. The monitor rejects any mismatch
    # with its own effective mode instead of silently downgrading the child.
    [ValidateSet('read-only','workspace-write','danger-full-access')]
    [string]$RequestedPermissionMode = 'danger-full-access',

    [ValidateRange(0, 65535)]
    [int]$Port = 0,
    [switch]$RejectTools
)

# Codex child-agent lifecycle -> DSH adapter mapping:
#   spawn      -> new agentId, new DSH native session, turn 1
#   follow_up  -> existing agentId, resume the session bound in the monitor registry
# The caller never supplies a session id; the monitor/registry owns the binding.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 共享安全助手：安全 JSON 与 DPAPI token 解密。明文 token 只在内存里出现。
. (Join-Path $PSScriptRoot 'DshTeamCommon.ps1')
Assert-DshPowerShellRuntime | Out-Null

if ($AgentId -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
    throw "AgentId must start with a letter or digit and contain only letters, digits, '.', '_', ':' or '-', max 128 characters."
}

# Explicit assignment is all-or-nothing: a Team-managed dispatch needs TeamId + TaskId +
# AttemptId, and a legacy dispatch must not carry an attempt id at all.
$teamManaged = [bool]$TeamId -or [bool]$AttemptId
if ($teamManaged) {
    if (-not $TeamId -or -not $AttemptId -or -not $TaskId) {
        throw 'Team-managed dispatch requires -TeamId, -TaskId and -AttemptId together.'
    }
    foreach ($pair in @(@('TeamId', $TeamId), @('TaskId', $TaskId), @('AttemptId', $AttemptId))) {
        if ($pair[1] -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$') {
            throw "$($pair[0]) must start with a letter or digit and contain only letters, digits, '.', '_', ':' or '-', max 128 characters."
        }
    }
}

$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
# workspace 必须是真实目录（非 reparse），并且 ContractRelativePath 必须严格绑定在它内部：
# 相对、.md、无 '..'、无绝对/盘符/UNC、无 reparse。任何一条不满足就在这里 fail-closed，
# 不会产生 artifact，也不会把逃逸路径交给 DSH 当 cwd。
Assert-DshReparseFreePath -Path $workspacePath -Label '-Workspace' | Out-Null
if (-not (Test-Path -LiteralPath $workspacePath -PathType Container)) {
    throw "Workspace 必须是已存在的目录：$workspacePath"
}
$contractAbsolutePath = Assert-DshContractPathBound -ContractRelativePath $ContractRelativePath -Workspace $workspacePath

$recordPath = Join-Path $workspacePath 'artifacts\dsh-monitor\server.json'
if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
    throw 'Monitor authorization record not found. Start it with scripts/start_dsh_monitor.ps1.'
}
$monitorRecord = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
if (-not $monitorRecord.url) {
    throw 'Monitor authorization record is incomplete. Restart the monitor.'
}
# workspace 必须与 Monitor 记录的 canonical workspace 一致，不能借用另一个目录的 Monitor。
if ($monitorRecord.workspace -and
    $monitorRecord.workspace.TrimEnd('\', '/') -ine $workspacePath.TrimEnd('\', '/')) {
    throw "Monitor 记录的 workspace ($($monitorRecord.workspace)) 与本次 dispatch 的 workspace ($workspacePath) 不一致；拒绝 dispatch。"
}
# Access token 只从 DPAPI 保护的记录在内存里解密；明文不再被读取，也绝不被打印。
$monitorAccessToken = Get-DshMonitorAccessToken -Record $monitorRecord
$monitorUri = [Uri]$monitorRecord.url
$actualPort = $monitorUri.Port
if ($Port -ne 0 -and $Port -ne $actualPort) {
    throw "Monitor authorization record uses port $actualPort, but port $Port was requested. Omit -Port to use the workspace monitor automatically."
}
$contractPath = $contractAbsolutePath
if (-not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    throw "Contract not found: $contractPath"
}

$payload = [ordered]@{
    workspace = $workspacePath
    agentId = $AgentId
    formalRole = $FormalRole
    lifecycleAction = $LifecycleAction
    taskId = $TaskId
    teamId = $TeamId
    attemptId = $AttemptId
    requestedPermissionMode = $RequestedPermissionMode
    title = if ($Title) { $Title } elseif ($TaskId) { $TaskId } else { "DSH $FormalRole" }
    contractPath = $ContractRelativePath
    contractText = Get-Content -Raw -LiteralPath $contractPath
    allowTools = -not $RejectTools
}

$response = Invoke-RestMethod `
    -Uri "$($monitorRecord.url)/api/runs" `
    -Method Post `
    -Headers @{ 'X-DSH-Monitor-Token' = $monitorAccessToken } `
    -ContentType 'application/json; charset=utf-8' `
    -Body (ConvertTo-SafeJson -InputObject $payload -Depth 5)

Write-Output (ConvertTo-SafeJson -InputObject $response -Depth 12)
