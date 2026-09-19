param(
    [string]$Workspace = (Get-Location).Path,
    [ValidateRange(1, 65535)]
    [int]$Port = 4317,
    # Team 运行时 Home。它必须是 Toolkit-owned Team Home（带合法 marker）；无 marker 的已有
    # 目录、属于别的 install 的目录、或看起来像普通 DSH Home 的目录都会被拒绝。
    [string]$DshHome,
    # 主（用户交互式）DSH Home：作为默认模型和自动同步的只读来源。
    [string]$UserDshHome,
    # Toolkit-owned Team Home 的默认根目录；为空时使用 %LOCALAPPDATA%\CodexDshTeam\runtimes。
    [string]$TeamHomeRoot,
    # 稳定 install id（随安装 manifest 保存）。为空时从 install manifest 读取或首次创建。
    [string]$InstallId,
    [string]$InstallManifestPath,
    # DSH ACP profile 名。`acp` 是 DSH 内置协议 profile；未传时默认 `acp`（既有调用完全兼容）。
    # 该值会同时传给 server（--dsh-profile）、bridge 子进程与一键配置同步（-TeamProfile），
    # 保证 Task/permission 证据与 DSH 子进程运行在同一个 profile 下。
    [string]$TeamProfile,
    [switch]$Background,
    [switch]$AutoPort,
    [ValidateRange(1, 200)]
    [int]$PortSearchSpan = 50,
    [switch]$NonInteractive,
    [switch]$OpenBrowser,
    [System.IO.FileStream]$WorkspaceLaunchLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 共享安全助手：安全 JSON、Team Home ownership marker、DPAPI token 保护。
. (Join-Path $PSScriptRoot 'DshTeamCommon.ps1')
# 入口运行时校验：Windows PowerShell 5.1 与 PowerShell 7+ 都必须通过 JSON 兼容探测，
# 否则明确阻断，而不是输出下游无法解析的 Monitor 记录。
Assert-DshPowerShellRuntime | Out-Null

# DSH ACP profile：未传默认 acp（既有调用兼容）；名字必须满足保守语法且不能是保留目录名。
# 校验放在最前面：非法参数必须在解析 workspace / 创建任何 identity 或 Team Home 之前就被拒绝。
# 与 src/server.mjs 的 normalizeDshProfile / src/cli.mjs 的 resolveDshProfile 使用同一规则。
$profileName = $TeamProfile
if (-not $profileName) { $profileName = 'acp' }
$profileName = $profileName.Trim()
if ($profileName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
    throw "TeamProfile 非法：'$profileName'（只允许字母数字开头，后跟字母数字、点、下划线或连字符，最长 64 个字符）。"
}
if ($profileName.ToLowerInvariant() -eq 'node_modules') {
    throw "TeamProfile 非法：'$profileName' 是保留的目录名，不能作为 DSH ACP profile。"
}
$profileArgs = @('--dsh-profile', $profileName)
$profileArgument = " --dsh-profile `"$profileName`""

$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
$ownsLaunchLock = $null -eq $WorkspaceLaunchLock
if ($ownsLaunchLock) { $WorkspaceLaunchLock = Enter-DshWorkspaceLaunch -Workspace $workspacePath }
elseif (-not $WorkspaceLaunchLock.CanWrite -or
    $WorkspaceLaunchLock.Name -ne (Join-Path $workspacePath 'artifacts\dsh-monitor\launch.lock')) {
    throw 'Monitor 启动锁与当前项目不匹配。'
}
try {
$existingMonitor = Get-DshWorkspaceMonitor -Workspace $workspacePath -RequestedHome $DshHome `
    -RequestedSource $UserDshHome -RequestedProfile $TeamProfile
if ($existingMonitor) {
    if ($OpenBrowser) { Start-Process $existingMonitor.url | Out-Null }
    Write-Output (ConvertTo-SafeJson -InputObject $existingMonitor -Depth 6)
    exit 0
}
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundleRoot = Split-Path -Parent $scriptRoot
$serverPath = Join-Path $bundleRoot 'src\server.mjs'
$node = Get-Command node.exe -ErrorAction Stop
$npm = Get-Command npm.cmd -ErrorAction Stop
if (-not (Test-Path -LiteralPath (Join-Path $bundleRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js') -PathType Leaf)) {
    throw '项目尚未安装 DSH 依赖，请在桌面点击“安装工具包与依赖”，完成后再启动 Monitor。'
}

# 稳定安装身份：位于项目/Git 之外，项目移动后仍能定位同一个 owned runtime。
if (-not $InstallId) {
    $identity = Get-DshTeamInstallIdentity -ManifestPath $InstallManifestPath
    $InstallId = $identity.InstallId
}

# 默认受管运行目录与只读用户配置分开，不读取旧 REMOTE_TO_DSH_HOME。
$resolvedTeam = Resolve-DshTeamHome -Requested $DshHome -Workspace $workspacePath `
    -InstallId $InstallId -TeamHomeRoot $TeamHomeRoot -AllowCreate
$dshHomePath = $resolvedTeam.TeamDshHome

# Both launchers resolve the same authoritative current-user configuration.
$resolvedUserDshHome = Resolve-DshUserHome -Requested $UserDshHome -InitialDirectory $workspacePath `
    -AllowPrompt:($OpenBrowser -and -not $NonInteractive)
Assert-UserDshHomeReadOnlySource -UserDshHome $resolvedUserDshHome -TeamDshHome $dshHomePath | Out-Null
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

# 旧 record / 旧 health 没有 profile 字段：按历史值 acp 解释，因此只有请求 acp 时才可以复用。
function Get-HealthProfile {
    param($Health)
    if ($null -eq $Health) { return 'acp' }
    $value = [string]$Health.dshProfile
    if ([string]::IsNullOrWhiteSpace($value)) { return 'acp' }
    return $value
}

# 复用判定：workspace、Team DSH home、profile 三者都必须一致。
function Test-MonitorHealthMatch {
    param($Health)
    if ($null -eq $Health) { return $false }
    if ($Health.service -ne 'dsh-team-monitor') { return $false }
    if ($Health.workspace -ne $workspacePath) { return $false }
    if ($Health.dshHome -ne $dshHomePath) { return $false }
    $sourceProperty = $Health.PSObject.Properties['dshUserHome']
    if (-not $sourceProperty -or [string]$sourceProperty.Value -ne $resolvedUserDshHome) { return $false }
    return ((Get-HealthProfile -Health $Health) -eq $profileName)
}

# record 里的 profile：缺失按历史 acp 解释；与请求不一致时绝不复用。
function Test-MonitorRecordProfileMatch {
    param($Record)
    if ($null -eq $Record) { return ($profileName -eq 'acp') }
    $value = [string]$Record.dsh_profile
    $recordProfile = if ([string]::IsNullOrWhiteSpace($value)) { 'acp' } else { $value }
    return ($recordProfile -eq $profileName)
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
        # Monitor/bridge 使用的 DSH ACP profile（复用判定的一部分；旧 record 缺此字段按 acp）。
        dsh_profile = $profileName
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
        dsh_profile = $profileName
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
        $existingRecord = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
        if ($existingRecord.url) {
            $existingUri = [Uri]$existingRecord.url
            $existingPort = $existingUri.Port
            $existingHealth = Get-MonitorHealth -CandidatePort $existingPort
            # 复用必须 workspace + home + profile 三者一致；record 缺 profile 按历史 acp 解释，
            # 因此旧 record 只在请求 acp 时可复用，profile 不同绝不复用错误的 monitor。
            if ((Test-MonitorHealthMatch -Health $existingHealth) -and (Test-MonitorRecordProfileMatch -Record $existingRecord)) {
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
            if (Test-MonitorHealthMatch -Health $health) {
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
        if ((Get-HealthProfile -Health $health) -ne $profileName) {
            throw "Port $selectedPort is occupied by a DSH monitor for profile '$(Get-HealthProfile -Health $health)', but profile '$profileName' was requested. Use -AutoPort or choose another port."
        }
        if (-not (Test-MonitorHealthMatch -Health $health)) {
            throw '此 Monitor 使用另一份用户 DSH 配置，不能复用。请重新运行项目启动器。'
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
        '--dsh-home' $dshHomePath '--toolkit-install-id' $InstallId @profileArgs @userHomeArgs
    exit $LASTEXITCODE
}

New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
$monitorToken = New-MonitorToken
$stdoutPath = Join-Path $artifactDir 'server-stdout.log'
$stderrPath = Join-Path $artifactDir 'server-stderr.log'
$argumentLine = "`"$serverPath`" --workspace `"$workspacePath`" --port $selectedPort --token $monitorToken --dsh-home `"$dshHomePath`" --toolkit-install-id `"$InstallId`"$profileArgument$userHomeArgument"
$process = Start-DshMonitorProcess -FilePath $node.Source -ArgumentList $argumentLine -WorkingDirectory $workspacePath -WindowStyle Hidden -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

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
} finally {
    if ($ownsLaunchLock) { $WorkspaceLaunchLock.Dispose() }
}
