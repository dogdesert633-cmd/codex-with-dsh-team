# start_dsh_team.ps1
#
# One-shot bootstrap for the Codex x DSH Team environment on this machine.
#
#   double-click start_dsh_team.cmd
#       -> sync the user's working DSH runtime config into the Team DSH home
#       -> verify a minimal DSH request really succeeds
#       -> start or reuse this project's DSH Monitor
#       -> open the Monitor page
#       -> print DSH / Monitor / Team runtime status
#
# This entry point only coordinates the existing Teammate scripts:
#   Sync-DshTeamConfig.ps1   configuration synchronisation
#   start_dsh_monitor.ps1    monitor ownership, port selection, reuse, browser entry
#
# Failures are loud: the script throws with a Chinese explanation, the caller keeps
# the console window open, and nothing is silently skipped. Credential values are
# never written to the console.

[CmdletBinding()]
param(
    # Left empty on purpose: $PSScriptRoot is not reliably populated inside a param
    # default, so the project root is derived from it in the body below.
    [string]$Workspace,
    [string]$UserDshHome,
    # Toolkit-owned Team Home：必须带合法 marker；无 marker 的已有目录绝不被 adopt。
    [string]$TeamDshHome,
    # 默认 owned Team Home 的根目录；为空时使用 %LOCALAPPDATA%\CodexDshTeam\runtimes。
    [string]$TeamHomeRoot,
    # 稳定 install id 与 install manifest 路径；为空时读取或首次创建 manifest。
    [string]$InstallId,
    [string]$InstallManifestPath,
    # Team profile 目录名（profiles\<name>）。为空时按 owned Team Home 内唯一带 package.json
    # 的 profile 发现；0 个或多个候选一律 fail-visible，不使用静默默认值。
    [string]$TeamProfile,
    [ValidateRange(1, 65535)]
    [int]$Port = 4317,
    [int]$DshCheckTimeoutSeconds = 300,
    [switch]$SkipSync,
    [switch]$SkipDshCheck,
    [switch]$NonInteractive,
    [switch]$SelectDshHome,
    [switch]$NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 共享安全助手：安全 JSON、Team Home ownership marker、DPAPI token 保护。
. (Join-Path $PSScriptRoot 'DshTeamCommon.ps1')
# 入口运行时兼容闸门：Windows PowerShell 5.1 与 PowerShell 7+ 都必须通过 JSON 探测，
# 否则明确阻断（见 DshTeamCommon.ps1 的 Assert-JsonSerializerCompatibility）。
Assert-DshPowerShellRuntime | Out-Null

$script:Report = [ordered]@{
    Project      = $null
    Workspace    = $null
    Node         = $null
    Git          = $null
    InstallId    = $null
    UserDshHome  = $null
    TeamDshHome  = $null
    Provider     = $null
    Model        = $null
    DshStatus    = 'not checked'
    ChildEnvDropped = @()
    MonitorUrl   = $null
    MonitorState = $null
    SyncChanges  = @()
    Notes        = @()
}

function Write-Headline {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor DarkGray
}

function Write-Step {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[*] $Text" -ForegroundColor Yellow
}

function Write-Ok {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "[+] $Text" -ForegroundColor Green
}

function Write-Note {
    param([Parameter(Mandatory)][string]$Text)
    Write-Host "    $Text" -ForegroundColor DarkGray
}

function Write-EnvironmentReport {
    Write-Headline 'DSH Team 启动器 - 环境状态'
    Write-Host ("  Project        : {0}" -f $script:Report.Project)
    Write-Host ("  Workspace      : {0}" -f $script:Report.Workspace)
    Write-Host ("  Node           : {0}" -f $script:Report.Node)
    Write-Host ("  Git            : {0}" -f $script:Report.Git)
    Write-Host ("  install id     : {0}" -f $script:Report.InstallId)
    Write-Host ("  用户 DSH home  : {0} (只读来源)" -f $script:Report.UserDshHome)
    Write-Host ("  Team DSH home  : {0}" -f $script:Report.TeamDshHome) -ForegroundColor White
    Write-Host ''
    Write-Host ("  DSH connection : {0}" -f $script:Report.DshStatus) -ForegroundColor Green
    if ($script:Report.Provider) {
        Write-Host ("  Team provider  : {0}" -f $script:Report.Provider)
        Write-Host ("  Team model     : {0}" -f $script:Report.Model)
    }
    Write-Host ''
    Write-Host ("  Monitor URL    : {0}" -f $script:Report.MonitorUrl) -ForegroundColor Green
    Write-Host ("  Monitor 状态   : {0}" -f $script:Report.MonitorState)
    Write-Host ("  Team DSH 运行时: {0} (profile {1})" -f $script:Report.TeamDshHome, $TeamProfile)
    if ($script:Report.ChildEnvDropped.Count -gt 0) {
        # 只打印变量名，绝不打印值：这是"最小 child env"策略的可核对证据。
        Write-Host ("  已从 DSH child env 丢弃的敏感变量名: {0}" -f ($script:Report.ChildEnvDropped -join ', ')) -ForegroundColor DarkGray
    }
    if ($script:Report.SyncChanges.Count -gt 0) {
        Write-Host ''
        Write-Host '  本轮同步的配置:' -ForegroundColor Cyan
        Write-Host ("    - {0}" -f ($script:Report.SyncChanges -join "`n    - "))
    }
    if ($script:Report.Notes.Count -gt 0) {
        Write-Host ''
        $script:Report.Notes | ForEach-Object { Write-Note $_ }
    }
    Write-Host ''
}

# Fail loudly, keep the window open through the caller, and never hide the cause.
trap {
    Write-Host ''
    Write-Host '############################################################################' -ForegroundColor Red
    Write-Host '# DSH Team 启动失败' -ForegroundColor Red
    Write-Host '############################################################################' -ForegroundColor Red
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host '已停止，未静默继续。请根据上面的错误信息处理后重新双击 start_dsh_team.cmd。' -ForegroundColor Yellow
    if ($_.ScriptStackTrace) {
        Write-Host ''
        Write-Host '调用位置:' -ForegroundColor DarkGray
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    exit 1
}

$scriptRoot = $PSScriptRoot
$syncScript = Join-Path $scriptRoot 'Sync-DshTeamConfig.ps1'
$monitorScript = Join-Path $scriptRoot 'start_dsh_monitor.ps1'
$skillRoot = Split-Path -Parent $scriptRoot
$bundledDshBin = Join-Path $skillRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'

# scripts -> mcp-to-dsh -> skills -> .agents -> project root (three parents up)
if (-not $Workspace) {
    $Workspace = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $skillRoot))
}

Write-Headline 'DSH Team 启动器'

# ---------------------------------------------------------------------------
# 1. Resolve this project's workspace
# ---------------------------------------------------------------------------
Write-Step '解析项目工作区'
if (-not (Test-Path -LiteralPath $Workspace -PathType Container)) {
    throw "工作区不存在: $Workspace"
}
$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
$script:Report.Project = Split-Path -Leaf $workspacePath
$script:Report.Workspace = $workspacePath
Write-Ok "Project=$($script:Report.Project)"

$workspaceLaunchLock = Enter-DshWorkspaceLaunch -Workspace $workspacePath
try {
$existingMonitor = Get-DshWorkspaceMonitor -Workspace $workspacePath -RequestedHome $TeamDshHome `
    -RequestedSource $UserDshHome -RequestedProfile $TeamProfile
if ($existingMonitor) {
    Write-Ok "Monitor READY (复用已有团队) - $($existingMonitor.url)"
    Write-Note '同一项目使用一支团队；现有任务保持运行。更新设置请使用桌面或网页的同步配置。'
    if (-not $NoBrowser) { Start-Process $existingMonitor.url | Out-Null }
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Resolve the runtimes the Team scripts need
# ---------------------------------------------------------------------------
Write-Step '解析 Node / npm'
$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { throw '找不到 node.exe。请安装 Node.js 并确保它在 PATH 中。' }
$npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
if (-not $npm) { throw '找不到 npm。请安装 Node.js 并确保 npm 在 PATH 中。' }
$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
$script:Report.Node = "$($node.Source) ($(& node --version))"
$script:Report.Git = if ($git) { '可用（差异记录为可选辅助）' } else { '未安装（不影响 DSH 使用）' }
Write-Ok "node $(& node --version)"

if (-not (Test-Path -LiteralPath $monitorScript -PathType Leaf)) {
    throw "缺少 Monitor 启动脚本: $monitorScript"
}
if (-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) {
    throw "缺少配置同步脚本: $syncScript"
}
if (-not (Test-Path -LiteralPath $bundledDshBin -PathType Leaf)) {
    throw "DSH Team 运行时未安装: $bundledDshBin 不存在。请先在 $skillRoot 执行 npm install。"
}
if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'node_modules'))) {
    throw "DSH Team 依赖未安装: $(Join-Path $skillRoot 'node_modules') 不存在。请先在 $skillRoot 执行 npm install。"
}

# ---------------------------------------------------------------------------
# 3. Resolve the user's working DSH home and the Team DSH home
# ---------------------------------------------------------------------------
Write-Step '定位用户正在使用的 DSH 配置'

$resolvedUserHome = Resolve-DshUserHome -Requested $UserDshHome -InitialDirectory $workspacePath `
    -AllowPrompt:(-not $NonInteractive) -SelectAgain:$SelectDshHome
$script:Report.UserDshHome = $resolvedUserHome
Write-Ok "用户 DSH home = $resolvedUserHome (只读来源，绝不写入)"

# 稳定安装身份：保存在项目/Git 之外的 install manifest 中，项目移动后仍能定位同一个
# owned runtime。ownership 绝不依据“目录名像 DSH Home”来猜。
if (-not $InstallId) {
    $identity = Get-DshTeamInstallIdentity -ManifestPath $InstallManifestPath
    $InstallId = $identity.InstallId
    if ($identity.Created) {
        Write-Ok "已创建安装身份 install id = $InstallId"
        Write-Note "install manifest = $($identity.ManifestPath)"
    }
}
$script:Report.InstallId = $InstallId
Write-Ok "install id = $InstallId"

# 用户配置只读；旧 REMOTE_TO_DSH_HOME 不再参与可写运行目录选择。
$resolvedTeamHome = (Resolve-DshTeamHome -Requested $TeamDshHome -Workspace $workspacePath `
    -InstallId $InstallId -TeamHomeRoot $TeamHomeRoot -AllowCreate).TeamDshHome
Assert-UserDshHomeReadOnlySource -UserDshHome $resolvedUserHome -TeamDshHome $resolvedTeamHome | Out-Null

# Team profile：先证明 Team Home 属于本安装（owned），再 prepare（缺失时用官方 DSH 初始化
# ACP profile），最后 resolve 出最终名字。安装器不再需要预置任何 profile。
$profileSelection = Resolve-DshTeamProfileSelection -Requested $TeamProfile -TeamDshHome $resolvedTeamHome `
    -InstallId $InstallId -EnvironmentValue $env:CODEX_DSH_TEAM_PROFILE `
    -DshBinPath $bundledDshBin -NodePath $node.Source -Workspace $workspacePath
$TeamProfile = $profileSelection.Name
Write-Ok "Team profile = $TeamProfile (来源: $($profileSelection.Source), bundles: $(@($profileSelection.Bundles) -join ', '))"
foreach ($profileNote in @($profileSelection.Notes)) { Write-Note $profileNote }
$script:Report.TeamDshHome = $resolvedTeamHome
Write-Ok "Team DSH home = $resolvedTeamHome (Toolkit-owned, marker 已验证)"

# ---------------------------------------------------------------------------
# 4. Sync the runtime configuration into the Team home
# ---------------------------------------------------------------------------
. $syncScript

if ($SkipSync) {
    Write-Step '按 -SkipSync 跳过配置同步'
    $teamSettingsPath = Join-Path $resolvedTeamHome 'settings.yaml'
    if (-not (Test-Path -LiteralPath $teamSettingsPath -PathType Leaf)) {
        throw "按 -SkipSync 跳过同步，但 Team Home 没有 settings.yaml：$teamSettingsPath。请先执行一次同步。"
    }
    $selection = Get-DshModelSelection -Text (Get-Content -Raw -LiteralPath $teamSettingsPath)
    $script:Report.Provider = $selection.DefaultProvider
    $script:Report.Model = $selection.DefaultModel
    $script:Report.Notes += '已按 -SkipSync 跳过配置同步，直接使用 Team home 现有配置。'
}
else {
    Write-Step '同步 provider / model / auth 到 Team 运行时'
    $syncResult = Invoke-DshTeamConfigSync -UserDshHome $resolvedUserHome -TeamDshHome $resolvedTeamHome `
        -TeamProfile $TeamProfile -InstallId $InstallId -TeamHomeRoot $TeamHomeRoot -Workspace $workspacePath `
        -DshBinPath $bundledDshBin -NodePath $node.Source
    $script:Report.Provider = $syncResult.Provider
    $script:Report.Model = $syncResult.Model
    $script:Report.SyncChanges = @($syncResult.Changed)
    $script:Report.Notes = @($syncResult.Notes)
    if ($syncResult.Changed.Count -eq 0) {
        Write-Ok 'Team 配置已是最新，无需改动'
    }
    else {
        Write-Ok ("已同步 {0} 项: {1}" -f $syncResult.Changed.Count, ($syncResult.Changed -join ', '))
    }
    Write-Note "provider=$($syncResult.Provider) model=$($syncResult.Model)"
}

# ---------------------------------------------------------------------------
# 5. Verify the Team DSH runtime with a minimal request
# ---------------------------------------------------------------------------
function Invoke-DshTeamCheck {
    param(
        [Parameter(Mandatory)][string]$DshHome,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [string]$PermissionMode = 'danger-full-access'
    )

    # Deliberately tiny: the point is to prove the Team runtime can complete one
    # real provider round-trip, not to assert on the wording of the answer.
    $sentinel = 'DSH_TEAM_READY_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $prompt = "Reply with exactly this token and nothing else: $sentinel"

    $argumentLine = '"{0}" --profile headless {1}' -f $bundledDshBin, ('"' + $prompt.Replace('"', '\"') + '"')
    # Release Blocker A：DSH 子进程不继承启动器的完整环境。只传 allowlist + 已确认的
    # DSH runtime 字段；REMOTE_TO_DSH_HOME、任何 *_TOKEN/*_KEY/*_SECRET 都不会进入 child。
    $narrowedEnv = Get-DshNarrowedChildEnv -Explicit @{
        DSH_HOME              = $DshHome
        DSH_PERMISSION_MODE   = $PermissionMode
    }
    $script:Report.ChildEnvDropped = @((Get-DshChildEnvAudit -Environment $narrowedEnv).DroppedSensitive)
    $result = Start-DshNarrowedProcess -FileName $node.Source -Arguments $argumentLine `
        -WorkingDirectory $WorkingDirectory -TimeoutSeconds $TimeoutSeconds -Environment $narrowedEnv

    if ($result.TimedOut) {
        throw "DSH 最小请求在 $TimeoutSeconds 秒内没有返回（已终止）。可能是网络、API 额度或 provider 配置问题。"
    }

    $stdout = if ($null -eq $result.Stdout) { '' } else { $result.Stdout }
    $stderr = if ($null -eq $result.Stderr) { '' } else { $result.Stderr }
    $exitCode = $result.ExitCode

    # Verified on this machine: `dsh --profile headless "<prompt>"` prints the
    # answer to stdout, may stream model reasoning to stderr, and can report a
    # null exit code even on success. Success is therefore decided by the real
    # output plus the absence of runtime-error signatures, never by the exit
    # code alone, so a healthy Team runtime is never misreported as broken.
    $errorSignatures = @(
        'credentials-local:',
        'settings-file:',
        'EPERM',
        'Cannot find module',
        'ERR_MODULE_NOT_FOUND',
        'Insufficient Balance',
        'bridge:fatal',
        'Error: turn failed',
        'is not configured'
    )
    $fatalText = "$stdout`n$stderr"
    $hits = @($errorSignatures | Where-Object { $fatalText -like "*$_*" })
    $answered = $stdout.Trim().Length -gt 0

    if ($hits.Count -eq 0 -and $answered) {
        return @{ Stdout = $stdout; Stderr = $stderr; ExitCode = $exitCode }
    }

    $detail = if ($stderr.Trim()) { $stderr.Trim() } else { $stdout.Trim() }
    if ($detail.Length -gt 1600) { $detail = $detail.Substring(0, 1600) + "`n...(已截断)" }
    if ($hits.Count -gt 0) {
        throw "DSH 最小请求失败，检测到运行时错误（exit=$exitCode；命中: $($hits -join ', ')）。`n$detail"
    }
    if (-not $detail) { $detail = '（DSH 没有产生任何输出）' }
    throw "DSH 最小请求没有返回任何应答（exit=$exitCode）。`n$detail"
}

if ($SkipDshCheck) {
    Write-Step '按 -SkipDshCheck 跳过 DSH 可用性检查'
    $script:Report.DshStatus = 'skipped (-SkipDshCheck)'
}
else {
    Write-Step "检查 Team DSH 运行时（最小请求，最多等待 $DshCheckTimeoutSeconds 秒）"
    $check = Invoke-DshTeamCheck -DshHome $resolvedTeamHome -WorkingDirectory $workspacePath -TimeoutSeconds $DshCheckTimeoutSeconds
    $script:Report.DshStatus = "READY (provider=$($script:Report.Provider), model=$($script:Report.Model))"
    Write-Ok 'DSH READY - Team 运行时可正常完成一次真实请求'
}

# ---------------------------------------------------------------------------
# 6. Start this project's monitor while keeping the workspace launch lock.
Write-Step '启动或复用本项目的 DSH Monitor'
# 主 DSH Home 与 Team Home 一起透传：Team Home 继续是 dispatch 运行时的 dshHome，主 Home 只作为
# Monitor「一键同步设置」按钮的来源。两者相同就没有可同步的两个 Home，直接拒绝而不是悄悄丢失按钮。
if ($resolvedUserHome -eq $resolvedTeamHome) {
    throw "主 DSH Home 与 Team DSH Home 是同一目录（$resolvedUserHome）；Team 运行时需要一个独立的 Home。"
}
$monitorArgs = @{
    Workspace   = $workspacePath
    Port        = $Port
    WorkspaceLaunchLock = $workspaceLaunchLock
    AutoPort    = $true
    Background  = $true
    DshHome     = $resolvedTeamHome
    UserDshHome = $resolvedUserHome
    InstallId   = $InstallId
    # 最终选定的 Team profile 必须一路传到 Monitor（--dsh-profile），保证 bridge 子进程、
    # Task/permission 证据与本次启动用的是同一个 profile。
    TeamProfile = $TeamProfile
}
if ($TeamHomeRoot) { $monitorArgs['TeamHomeRoot'] = $TeamHomeRoot }
if ($InstallManifestPath) { $monitorArgs['InstallManifestPath'] = $InstallManifestPath }
if (-not $NoBrowser) { $monitorArgs['OpenBrowser'] = $true }

$rawMonitorOutput = & $monitorScript @monitorArgs
$monitorText = ($rawMonitorOutput | Out-String).Trim()
if (-not $monitorText) {
    throw 'Monitor 启动脚本没有返回结果（预期为一行 JSON）。'
}

$monitorRecord = $null
try {
    $monitorRecord = $monitorText | ConvertFrom-Json
}
catch {
    throw "Monitor 启动脚本返回了无法解析的结果:`n$monitorText"
}
if (-not $monitorRecord.url) {
    throw "Monitor 启动脚本没有返回 URL:`n$monitorText"
}

$script:Report.MonitorUrl = $monitorRecord.url
$script:Report.MonitorState = switch ($monitorRecord.status) {
    'running' { 'READY (本次启动)' }
    'already_running' { 'READY (复用已有 monitor)' }
    default { "READY ($($monitorRecord.status))" }
}
Write-Ok ("Monitor {0} - {1}" -f $script:Report.MonitorState, $script:Report.MonitorUrl)

# ---------------------------------------------------------------------------
# 7. Final status
# ---------------------------------------------------------------------------
Write-EnvironmentReport
Write-Host 'DSH READY / Monitor READY - 可以开始 Codex x DSH Team 工作。' -ForegroundColor Green
Write-Host '（本窗口可以直接关闭；Monitor 在后台继续运行。）' -ForegroundColor DarkGray
exit 0
} finally {
    $workspaceLaunchLock.Dispose()
}
