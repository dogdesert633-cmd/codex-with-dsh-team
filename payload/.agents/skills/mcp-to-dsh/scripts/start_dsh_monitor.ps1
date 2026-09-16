param(
    [string]$Workspace = (Get-Location).Path,
    [ValidateRange(1, 65535)]
    [int]$Port = 4317,
    # Team 运行时 Home。它必须是 Toolkit-owned Team Home（带合法 marker）；无 marker 的已有
    # 目录、属于别的 install 的目录、或看起来像普通 DSH Home 的目录都会被拒绝。
    [string]$DshHome,
    # 主（用户交互式）DSH Home：只用于 Monitor 的“一键同步设置”按钮，作为只读同步来源。
    [string]$UserDshHome,
    # Toolkit-owned Team Home 的默认根目录；为空时使用 %LOCALAPPDATA%\CodexDshTeam\runtimes。
    [string]$TeamHomeRoot,
    # 稳定 install id（随安装 manifest 保存）。为空时从 install manifest 读取或首次创建。
    [string]$InstallId,
    [string]$InstallManifestPath,
    [switch]$Background,
    [switch]$AutoPort,
    [ValidateRange(1, 200)]
    [int]$PortSearchSpan = 50,
    [switch]$OpenBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 共享安全助手：安全 JSON、Team Home ownership marker、DPAPI token 保护。
. (Join-Path $PSScriptRoot 'DshTeamCommon.ps1')
# 入口运行时校验：Windows PowerShell 5.1 与 PowerShell 7+ 都必须通过 JSON 兼容探测，
# 否则明确阻断，而不是输出下游无法解析的 Monitor 记录。
Assert-DshPowerShellRuntime | Out-Null

$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleRoot = Split-Path -Parent $scriptRoot
$serverPath = Join-Path $bundleRoot 'src\server.mjs'
$node = Get-Command node.exe -ErrorAction Stop
$npm = Get-Command npm.cmd -ErrorAction Stop
if (-not (Test-Path -LiteralPath (Join-Path $bundleRoot 'node_modules'))) {
    & $npm.Source ci --prefix $bundleRoot | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "npm ci failed: $LASTEXITCODE" }
}

# 稳定安装身份：位于项目/Git 之外，项目移动后仍能定位同一个 owned runtime。
if (-not $InstallId) {
    $identity = Get-DshTeamInstallIdentity -ManifestPath $InstallManifestPath
    $InstallId = $identity.InstallId
}

# Team 运行时 Home：显式参数 / REMOTE_TO_DSH_HOME，否则默认 owned 路径。
# Resolve-DshTeamHome 先做 reparse 与 workspace 越界检查，再按 marker 判定 ownership：
# 无 marker 的已有目录绝不被 adopt/patch。
$teamHomeCandidate = $DshHome
if (-not $teamHomeCandidate) { $teamHomeCandidate = $env:REMOTE_TO_DSH_HOME }
if (-not $teamHomeCandidate) { $teamHomeCandidate = [Environment]::GetEnvironmentVariable('REMOTE_TO_DSH_HOME', 'User') }
if (-not $teamHomeCandidate) { $teamHomeCandidate = [Environment]::GetEnvironmentVariable('REMOTE_TO_DSH_HOME', 'Machine') }
$resolvedTeam = Resolve-DshTeamHome -Requested $teamHomeCandidate -Workspace $workspacePath `
    -InstallId $InstallId -TeamHomeRoot $TeamHomeRoot -AllowCreate
$dshHomePath = $resolvedTeam.TeamDshHome

# 主（用户）DSH Home：一键同步的来源。允许 -UserDshHome、DSH_USER_HOME，或退一步的 DSH_HOME。
# 只有确实存在 settings.yaml 且与 Team Home 不同的候选才会透传给 server：同一个目录绝不会被
# 同步到它自己，缺失时只是让 Monitor 的同步按钮报告“未配置”，dispatch 行为完全不受影响。
if (-not $UserDshHome) { $UserDshHome = $env:DSH_USER_HOME }
if (-not $UserDshHome) { $UserDshHome = $env:DSH_HOME }
$resolvedUserDshHome = $null
if ($UserDshHome) {
    $userCandidate = $null
    try { $userCandidate = (Resolve-Path -LiteralPath $UserDshHome -ErrorAction Stop).Path } catch { $userCandidate = $null }
    if ($userCandidate -and -not (Test-Path -LiteralPath (Join-Path $userCandidate 'settings.yaml') -PathType Leaf)) { $userCandidate = $null }
    if ($userCandidate -and $userCandidate -eq $dshHomePath) {
        Write-Warning '主 DSH Home 与 Team DSH Home 是同一目录，已忽略一键同步来源（不会把配置同步到自己）。'
        $userCandidate = $null
    }
    $resolvedUserDshHome = $userCandidate
}
# 透传给 server.mjs 的固定参数片段；两个启动分支共用，避免前台/后台行为分叉。
$userHomeArgs = @()
$userHomeArgument = ''
if ($resolvedUserDshHome) {
    $userHomeArgs = @('--dsh-user-home', $resolvedUserDshHome)
    $userHomeArgument = " --dsh-user-home `"$resolvedUserDshHome`""
}

$artifactDir = Join-Path $workspacePath 'artifacts\dsh-monitor'
$recordPath = Join-Path $artifactDir 'server.json'

function Get-MonitorHealth {
    param([int]$CandidatePort)
    try {
        return Invoke-RestMethod -Uri "http://127.0.0.1:$CandidatePort/api/health" -TimeoutSec 1
    }
    catch {
        return $null
    }
}

function Test-LocalPortInUse {
    param([int]$CandidatePort)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect('127.0.0.1', $CandidatePort, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(250)) {
            return $false
        }
        try {
            $client.EndConnect($async)
            return $client.Connected
        }
        catch {
            return $false
        }
    }
    finally {
        $client.Close()
    }
}

function Open-MonitorPage {
    param([string]$Url)
    if (-not $OpenBrowser) { return }
    try {
        Start-Process $Url | Out-Null
    }
    catch {
        Write-Warning "Monitor is running, but the browser could not be opened automatically. Open this URL manually: $Url"
    }
}

function Write-PublicRecord {
    param(
        [string]$Status,
        [string]$Url,
        [int]$ActualPort,
        [Nullable[int]]$MonitorPid,
        [string]$StartUtc
    )
    $publicRecord = [ordered]@{
        schema_version = 2
        status = $Status
        url = $Url
        port = $ActualPort
        pid = $MonitorPid
        workspace = $workspacePath
        dsh_home = $dshHomePath
        # 一键同步来源（主 DSH Home）；未配置时为 null，只作为本地证据，不参与复用判定。
        dsh_user_home = $resolvedUserDshHome
        install_id = $InstallId
        start_utc = $StartUtc
    }
    # 公开记录里永远没有 access token；它只存在于 DPAPI 保护的记录中。
    Write-Output (ConvertTo-SafeJson -InputObject $publicRecord -Depth 6)
}

# Monitor access token 只以 CurrentUser DPAPI 密文落盘；明文仅存在于本进程内存中，
# 不打印、不写日志、不进入任何 evidence。
function New-MonitorTokenRecord {
    param(
        [string]$Status,
        [string]$Url,
        [int]$ActualPort,
        [Nullable[int]]$MonitorPid,
        [Parameter(Mandatory)][string]$PlainToken,
        [string]$StartUtc
    )
    return [ordered]@{
        schema_version = 2
        status = $Status
        url = $Url
        port = $ActualPort
        pid = $MonitorPid
        workspace = $workspacePath
        dsh_home = $dshHomePath
        dsh_user_home = $resolvedUserDshHome
        install_id = $InstallId
        token_scheme = 'dpapi-current-user'
        access_token_protected = (Protect-DshMonitorToken -Token $PlainToken)
        start_utc = $StartUtc
    }
}

# Prefer an already-running monitor recorded for this workspace, regardless of
# which port was originally chosen. This makes the workspace, not the port,
# the stable ownership key.
if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
    try {
        $existingRecord = Get-Content -Raw -LiteralPath $recordPath | ConvertFrom-Json
        if ($existingRecord.url) {
            $existingUri = [Uri]$existingRecord.url
            $existingPort = $existingUri.Port
            $existingHealth = Get-MonitorHealth -CandidatePort $existingPort
            if ($existingHealth -and
                $existingHealth.service -eq 'dsh-team-monitor' -and
                $existingHealth.workspace -eq $workspacePath -and
                $existingHealth.dshHome -eq $dshHomePath) {
                Open-MonitorPage -Url $existingRecord.url
                $existingStart = if ($existingRecord.start_utc) { [string]$existingRecord.start_utc } else { [DateTimeOffset]::UtcNow.ToString('o') }
                $existingPid = if ($existingRecord.pid) { [Nullable[int]]([int]$existingRecord.pid) } else { [Nullable[int]]$null }
                Write-PublicRecord -Status 'already_running' -Url $existingRecord.url -ActualPort $existingPort -MonitorPid $existingPid -StartUtc $existingStart
                exit 0
            }
        }
    }
    catch {
        # Stale or malformed record: continue with normal startup selection.
    }
}

$selectedPort = $Port
if ($AutoPort) {
    $found = $false
    $lastPort = [Math]::Min(65535, $Port + $PortSearchSpan - 1)
    for ($candidate = $Port; $candidate -le $lastPort; $candidate++) {
        $health = Get-MonitorHealth -CandidatePort $candidate
        if ($health) {
            if ($health.service -eq 'dsh-team-monitor' -and
                $health.workspace -eq $workspacePath -and
                $health.dshHome -eq $dshHomePath) {
                $selectedPort = $candidate
                $url = "http://127.0.0.1:$selectedPort"
                Open-MonitorPage -Url $url
                Write-PublicRecord -Status 'already_running' -Url $url -ActualPort $selectedPort -MonitorPid ([Nullable[int]]$null) -StartUtc ([DateTimeOffset]::UtcNow.ToString('o'))
                exit 0
            }
            continue
        }
        if (Test-LocalPortInUse -CandidatePort $candidate) { continue }
        $selectedPort = $candidate
        $found = $true
        break
    }
    if (-not $found) {
        throw "No free monitor port was found from $Port through $lastPort."
    }
}
else {
    $health = Get-MonitorHealth -CandidatePort $selectedPort
    if ($health) {
        if ($health.service -ne 'dsh-team-monitor') {
            throw "Port $selectedPort is occupied by another HTTP service."
        }
        if ($health.workspace -ne $workspacePath -or $health.dshHome -ne $dshHomePath) {
            throw "Port $selectedPort is occupied by a DSH monitor for another workspace or DSH home. Use -AutoPort or choose another port."
        }
        $url = "http://127.0.0.1:$selectedPort"
        Open-MonitorPage -Url $url
        Write-PublicRecord -Status 'already_running' -Url $url -ActualPort $selectedPort -MonitorPid ([Nullable[int]]$null) -StartUtc ([DateTimeOffset]::UtcNow.ToString('o'))
        exit 0
    }
    if (Test-LocalPortInUse -CandidatePort $selectedPort) {
        throw "Port $selectedPort is already in use. Use -AutoPort or choose another port."
    }
}

$url = "http://127.0.0.1:$selectedPort"

function New-MonitorToken {
    $tokenBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($tokenBytes)
    return (-join ($tokenBytes | ForEach-Object { $_.ToString('x2') }))
}

if (-not $Background) {
    $monitorToken = New-MonitorToken
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    $foregroundRecord = New-MonitorTokenRecord -Status 'running' -Url $url -ActualPort $selectedPort `
        -MonitorPid ([Nullable[int]]$null) -PlainToken $monitorToken -StartUtc ([DateTimeOffset]::UtcNow.ToString('o'))
    # 只写 DPAPI 密文记录；明文 token 不进磁盘、不进日志、不进 console。
    # Out-Null：helper 的返回值不能混进本脚本唯一的 JSON 输出行。
    Write-DshAtomicText -Path $recordPath -Text ((ConvertTo-SafeJson -InputObject $foregroundRecord -Depth 6) + "`n") -RestrictToCurrentUser | Out-Null
    Open-MonitorPage -Url $url
    & $node.Source $serverPath '--workspace' $workspacePath '--port' $selectedPort '--token' $monitorToken `
        '--dsh-home' $dshHomePath '--toolkit-install-id' $InstallId @userHomeArgs
    exit $LASTEXITCODE
}

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$monitorToken = New-MonitorToken
$stdoutPath = Join-Path $artifactDir 'server-stdout.log'
$stderrPath = Join-Path $artifactDir 'server-stderr.log'
$argumentLine = "`"$serverPath`" --workspace `"$workspacePath`" --port $selectedPort --token $monitorToken --dsh-home `"$dshHomePath`" --toolkit-install-id `"$InstallId`"$userHomeArgument"
$process = Start-Process -FilePath $node.Source -ArgumentList $argumentLine -WorkingDirectory $workspacePath -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

$ready = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    Start-Sleep -Milliseconds 250
    try {
        $health = Invoke-RestMethod -Uri "$url/api/health" -TimeoutSec 1
        if ($health.service -eq 'dsh-team-monitor') {
            $ready = $true
            break
        }
    }
    catch {
        if ($process.HasExited) { break }
    }
}

if (-not $ready) {
    $message = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath } else { 'No server stderr was captured.' }
    throw "DSH Team Monitor failed to start. $message"
}

$record = New-MonitorTokenRecord -Status 'running' -Url $url -ActualPort $selectedPort `
    -MonitorPid ([Nullable[int]]$process.Id) -PlainToken $monitorToken -StartUtc ([DateTimeOffset]::UtcNow.ToString('o'))
Write-DshAtomicText -Path $recordPath -Text ((ConvertTo-SafeJson -InputObject $record -Depth 6) + "`n") -RestrictToCurrentUser | Out-Null
Open-MonitorPage -Url $url
Write-PublicRecord -Status 'running' -Url $url -ActualPort $selectedPort -MonitorPid ([Nullable[int]]$process.Id) -StartUtc $record.start_utc
