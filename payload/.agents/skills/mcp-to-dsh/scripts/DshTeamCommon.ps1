# DshTeamCommon.ps1
#
# Shared helpers for the public Codex x DSH team toolkit launchers.
#
# It carries the three cross-cutting guarantees that every entry point needs:
#
#   1. Safe JSON serialisation. Windows PowerShell 5.1 has a known trap where an
#      OrderedDictionary handed to ConvertTo-Json can be serialised as the dictionary
#      object instead of its entries, producing a huge non-JSON blob. Every structured
#      emission in this toolkit therefore goes through `ConvertTo-SafeJson`, which first
#      converts dictionaries to plain objects, and the entry point runs
#      `Assert-JsonSerializerCompatibility` so a runtime that cannot honour the contract
#      stops with a clear message instead of emitting unusable output.
#
#   2. Toolkit-owned Team Home proof. A Team Home is writable only when a marker file
#      proves this toolkit and this installation created it. A directory that merely
#      looks like a DSH Home is never adopted, and no path on the way may be a reparse
#      point (symlink/junction).
#
#   3. Monitor access token protection. The local Monitor token is persisted only as a
#      CurrentUser DPAPI record; the plaintext lives in memory for the process lifetime
#      and is never printed, never written to a log and never re-read from a plaintext
#      record.
#
# This file is dot-sourced by the launcher scripts. It never writes outside the Team Home
# it is given.

$script:DshTeamMarkerName = '.codex-dsh-team-home.json'
$script:DshTeamMarkerSchema = 'codex-dsh-team-home/v1'
$script:DshTeamMarkerPurpose = 'dsh-team-runtime-home'
$script:DshTeamToolkitId = 'codex-dsh-team-toolkit'
$script:DshTeamInstallSchema = 'codex-dsh-team-install/v1'
$script:DshTeamMarkerRequiredFields = @('schema', 'toolkitId', 'installId', 'createdAt', 'purpose')

function Get-DshTeamToolkitId { return $script:DshTeamToolkitId }

# ---------------------------------------------------------------------------
# Safe JSON
# ---------------------------------------------------------------------------

# Recursively turn dictionaries into plain objects so ConvertTo-Json always sees a shape it
# can serialise correctly on both Windows PowerShell 5.1 and PowerShell 7+.
function ConvertTo-DshPlainObject {
    param([Parameter(ValueFromPipeline = $true)]$InputObject)

    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [string]) { return $InputObject }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($InputObject.Keys)) {
                $ordered[[string]$key] = ConvertTo-DshPlainObject -InputObject $InputObject[$key]
            }
            return [pscustomobject]$ordered
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $ordered = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $ordered[$property.Name] = ConvertTo-DshPlainObject -InputObject $property.Value
            }
            return [pscustomobject]$ordered
        }
        if ($InputObject -is [System.Collections.IEnumerable]) {
            # The leading comma prevents PowerShell from unrolling a single-element array.
            return , @(foreach ($item in $InputObject) { ConvertTo-DshPlainObject -InputObject $item })
        }
        return $InputObject
    }
}

# The only JSON emitter this toolkit should use for structured output.
function ConvertTo-SafeJson {
    param(
        $InputObject,
        [int]$Depth = 10,
        [switch]$Compress
    )
    Set-StrictMode -Off
    try {
        $plain = ConvertTo-DshPlainObject -InputObject $InputObject
        if ($null -eq $plain) { return 'null' }
        if ($Compress) { return (ConvertTo-Json -InputObject $plain -Depth $Depth -Compress) }
        return (ConvertTo-Json -InputObject $plain -Depth $Depth)
    }
    finally {
        Set-StrictMode -Version Latest
    }
}

# A real compatibility probe for the running PowerShell host. When the host cannot produce
# the documented JSON for a known input, the caller must stop instead of emitting output
# that downstream tools cannot parse.
function Test-JsonSerializerCompatibility {
    $probe = [ordered]@{
        schema = 'dsh-team-json-probe'
        count  = 2
        items  = @('a', 'b')
        empty  = @()
    }
    $expected = '{"schema":"dsh-team-json-probe","count":2,"items":["a","b"],"empty":[]}'
    try {
        $actual = ConvertTo-SafeJson -InputObject $probe -Compress
    }
    catch {
        return [pscustomobject]@{ ok = $false; detail = "序列化探测抛出异常: $($_.Exception.Message)" }
    }
    if ($actual -cne $expected) {
        return [pscustomobject]@{ ok = $false; detail = "序列化探测结果不符合预期（实际长度 $($actual.Length)）" }
    }
    return [pscustomobject]@{ ok = $true; detail = 'ok' }
}

function Assert-JsonSerializerCompatibility {
    $probe = Test-JsonSerializerCompatibility
    if (-not $probe.ok) {
        throw ("当前 PowerShell 宿主无法安全序列化 JSON：{0}。`n请改用 PowerShell 7+（pwsh.exe），或修复本机 PowerShell 后重试。工具已停止，不会输出不可解析的结果。" -f $probe.detail)
    }
    return $true
}

# ---------------------------------------------------------------------------
# Reparse / boundary checks
# ---------------------------------------------------------------------------

# Returns the first existing ancestor (including the path itself) that is a reparse point.
function Find-DshReparsePoint {
    param([Parameter(Mandatory)][string]$Path)
    $full = $Path
    try { $full = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)) } catch { return $null }
    $current = $full
    $chain = New-Object System.Collections.Generic.List[string]
    while ($current) {
        $chain.Add($current)
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    for ($index = $chain.Count - 1; $index -ge 0; $index--) {
        $candidate = $chain[$index]
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $candidate }
        }
        catch {
            return $null
        }
    }
    return $null
}

function Assert-DshReparseFreePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'path'
    )
    $reparse = Find-DshReparsePoint -Path $Path
    if ($reparse) {
        throw ("{0} 的路径链上存在 reparse point（符号链接/junction）：{1}；拒绝在可被重定向的路径上创建或写入 Team Home。" -f $Label, $reparse)
    }
    return $true
}

# True when $Child is $Parent or lives below it (case-insensitive on Windows).
function Test-DshPathInside {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\', '/')
    $childFull = [System.IO.Path]::GetFullPath($Child).TrimEnd('\', '/')
    if ($parentFull -ieq $childFull) { return $true }
    return $childFull.StartsWith($parentFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-DshTeamHomeOutsideWorkspace {
    param(
        [Parameter(Mandatory)][string]$TeamDshHome,
        [string]$Workspace
    )
    if (-not $Workspace) { return $true }
    if (Test-DshPathInside -Parent $Workspace -Child $TeamDshHome) {
        throw ("Team Home {0} 位于项目工作区 {1} 内；Team runtime 必须写在项目/Git 之外。" -f $TeamDshHome, $Workspace)
    }
    return $true
}

# ---------------------------------------------------------------------------
# Install identity (stable across project moves)
# ---------------------------------------------------------------------------

function Get-DshTeamBaseDir {
    if ($env:CODEX_DSH_TEAM_BASE_DIR) { return $env:CODEX_DSH_TEAM_BASE_DIR }
    if ($env:LOCALAPPDATA) { return (Join-Path $env:LOCALAPPDATA 'CodexDshTeam') }
    if ($env:APPDATA) { return (Join-Path $env:APPDATA 'CodexDshTeam') }
    return (Join-Path ([System.IO.Path]::GetTempPath()) 'CodexDshTeam')
}

function Get-DshTeamHomeRoot {
    param([string]$BaseDir)
    if ($BaseDir) { return (Join-Path $BaseDir 'runtimes') }
    return (Join-Path (Get-DshTeamBaseDir) 'runtimes')
}

# DSH 内置 ACP bundle id。它是 DSH 协议内置标识（`dsh --profile acp` 的 ACP stdio bundle），
# 与内置 provider id `deepseek-official`同类，不是用户/个人选择；集中命名一次，便于说明与
# 前向兼容，但不再在各处散落硬编码。
$script:DshAcpBundleId = 'acp'

function Get-DshAcpBundleId { return $script:DshAcpBundleId }

# Team profile 是 owned Team Home 下 profiles\<name> 目录名，必须由配置或可验证发现决定，
# 不允许静默默认：显式参数 > 环境变量 > Team Home 内唯一带 package.json 的 profile。
# 0 个或多个候选一律 fail-visible，绝不猜一个可写 profile。
function Resolve-DshTeamProfile {
    param(
        [string]$Requested,
        [Parameter(Mandatory)][string]$TeamDshHome,
        [string]$EnvironmentValue
    )
    $candidate = $Requested
    if (-not $candidate) { $candidate = $EnvironmentValue }
    if ($candidate) {
        $candidate = $candidate.Trim()
        if ($candidate -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            throw "TeamProfile 必须是 1-64 位字母/数字/._- 且以字母或数字开头：$candidate"
        }
        $manifest = Join-Path (Join-Path $TeamDshHome 'profiles') (Join-Path $candidate 'package.json')
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "指定的 TeamProfile '$candidate' 在 Team Home $TeamDshHome 中不存在（缺少 $manifest）。"
        }
        return $candidate
    }

    $profilesRoot = Join-Path $TeamDshHome 'profiles'
    $found = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $profilesRoot -PathType Container) {
        foreach ($dir in (Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($dir.Name -eq 'node_modules') { continue }
            if (Test-Path -LiteralPath (Join-Path $dir.FullName 'package.json') -PathType Leaf) {
                $found.Add($dir.Name)
            }
        }
    }
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -eq 0) {
        throw ("Team Home {0} 里找不到任何带 package.json 的 profile；请用 -TeamProfile 或 CODEX_DSH_TEAM_PROFILE 指定，或先由安装器预置 Team runtime。" -f $TeamDshHome)
    }
    throw ("Team Home {0} 存在多个候选 profile，无法安全推断可写目标：{1}。请用 -TeamProfile 或 CODEX_DSH_TEAM_PROFILE 明确指定。" -f $TeamDshHome, ($found -join ', '))
}

# Contract 必须绑定当前 workspace：相对路径、.md、无 '..'、无绝对/盘符/UNC、无 reparse，
# 且解析后仍位于 workspace 内。任何一条不满足都在产生 artifact 之前 fail-closed。
function Assert-DshContractPathBound {
    param(
        [Parameter(Mandatory)][string]$ContractRelativePath,
        [Parameter(Mandatory)][string]$Workspace
    )
    $raw = ([string]$ContractRelativePath).Trim()
    if (-not $raw) { throw 'ContractRelativePath 不能为空。' }
    if ($raw.Length -gt 512) { throw 'ContractRelativePath 超过 512 字符上限；拒绝 dispatch。' }
    if ($raw -match '[\x00-\x1f\x7f]') { throw 'ContractRelativePath 含控制字符；拒绝 dispatch。' }
    if ($raw -match '^[A-Za-z]:' -or [System.IO.Path]::IsPathRooted($raw)) {
        throw "ContractRelativePath 必须是 workspace 内的相对路径（收到绝对路径）：$raw"
    }
    $segments = @($raw -split '[\\/]+')
    foreach ($segment in $segments) {
        if ($segment -eq '..') { throw "ContractRelativePath 不得包含 '..' 段：$raw" }
        if ($segment -eq '' -or $segment -eq '.') { throw "ContractRelativePath 含空段或 '.' 段：$raw" }
    }
    if ($raw -notmatch '(?i)\.md$') { throw "ContractRelativePath 必须指向 .md 合同文件：$raw" }

    $workspaceFull = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Workspace))
    $absolute = [System.IO.Path]::GetFullPath((Join-Path $workspaceFull $raw))
    if ($absolute -ieq $workspaceFull -or -not (Test-DshPathInside -Parent $workspaceFull -Child $absolute)) {
        throw "ContractRelativePath 逃出了 workspace：$raw"
    }
    Assert-DshReparseFreePath -Path $absolute -Label 'contractPath' | Out-Null
    return $absolute
}

function Get-DshTeamInstallManifestPath {
    param([string]$BaseDir)
    if ($BaseDir) { return (Join-Path $BaseDir 'install.json') }
    return (Join-Path (Get-DshTeamBaseDir) 'install.json')
}

# Read, or create once, the stable install identity. It lives outside the project on
# purpose: moving or renaming the project must still find the same owned Team runtime.
function Get-DshTeamInstallIdentity {
    param(
        [string]$ManifestPath,
        [string]$BaseDir,
        [string]$ToolkitId = $script:DshTeamToolkitId
    )
    if (-not $ManifestPath) { $ManifestPath = Get-DshTeamInstallManifestPath -BaseDir $BaseDir }
    $ManifestPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ManifestPath))
    if (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
        try {
            $existing = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
            if ($existing.schema -eq $script:DshTeamInstallSchema -and
                $existing.toolkitId -eq $ToolkitId -and
                $existing.installId -and ([string]$existing.installId).Trim()) {
                return [pscustomobject]@{
                    InstallId    = [string]$existing.installId
                    ToolkitId    = $ToolkitId
                    ManifestPath = $ManifestPath
                    Created      = $false
                }
            }
        }
        catch {
            # A malformed manifest is replaced below with a fresh identity, loudly.
        }
    }
    Assert-DshReparseFreePath -Path (Split-Path -Parent $ManifestPath) -Label 'install manifest 父目录' | Out-Null
    $parent = Split-Path -Parent $ManifestPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $manifest = [ordered]@{
        schema     = $script:DshTeamInstallSchema
        toolkitId  = $ToolkitId
        installId  = [Guid]::NewGuid().ToString()
        createdAt  = [DateTimeOffset]::UtcNow.ToString('o')
        purpose    = 'codex-dsh-team-install-identity'
    }
    Write-DshAtomicText -Path $ManifestPath -Text ((ConvertTo-SafeJson -InputObject $manifest -Depth 4) + "`n") | Out-Null
    return [pscustomobject]@{
        InstallId    = $manifest.installId
        ToolkitId    = $ToolkitId
        ManifestPath = $ManifestPath
        Created      = $true
    }
}

# ---------------------------------------------------------------------------
# Team Home marker / ownership
# ---------------------------------------------------------------------------

function Get-DshTeamHomeMarkerPath {
    param([Parameter(Mandatory)][string]$TeamDshHome)
    return (Join-Path $TeamDshHome $script:DshTeamMarkerName)
}

function Read-DshTeamHomeMarker {
    param([Parameter(Mandatory)][string]$TeamDshHome)
    $markerPath = Get-DshTeamHomeMarkerPath -TeamDshHome $TeamDshHome
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json) }
    catch { return $null }
}

function Test-DshTeamHomeMarker {
    param(
        $Marker,
        [string]$InstallId,
        [string]$ToolkitId = $script:DshTeamToolkitId
    )
    if ($null -eq $Marker) { return [pscustomobject]@{ Ok = $false; Reason = 'marker 缺失或不是对象' } }
    foreach ($field in $script:DshTeamMarkerRequiredFields) {
        $value = $Marker.$field
        if (-not $value -or -not ([string]$value).Trim()) {
            return [pscustomobject]@{ Ok = $false; Reason = "marker 缺少必需字段 $field" }
        }
    }
    if ($Marker.schema -ne $script:DshTeamMarkerSchema) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker schema $($Marker.schema) 不受支持" }
    }
    if ($Marker.toolkitId -ne $ToolkitId) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker 属于 toolkit $($Marker.toolkitId)" }
    }
    if ($Marker.purpose -ne $script:DshTeamMarkerPurpose) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker purpose $($Marker.purpose) 不正确" }
    }
    if ($InstallId -and $Marker.installId -ne $InstallId) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker 属于 install $($Marker.installId)，不是本次安装的 $InstallId" }
    }
    return [pscustomobject]@{ Ok = $true; Reason = 'marker 完整匹配' }
}

function Write-DshTeamHomeMarker {
    param(
        [Parameter(Mandatory)][string]$TeamDshHome,
        [Parameter(Mandatory)][string]$InstallId,
        [string]$ToolkitId = $script:DshTeamToolkitId
    )
    $marker = [ordered]@{
        schema    = $script:DshTeamMarkerSchema
        toolkitId = $ToolkitId
        installId = $InstallId
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        purpose   = $script:DshTeamMarkerPurpose
    }
    Write-DshAtomicText -Path (Get-DshTeamHomeMarkerPath -TeamDshHome $TeamDshHome) -Text ((ConvertTo-SafeJson -InputObject $marker -Depth 4) + "`n")
    return $marker
}

# A directory that carries DSH's own runtime state is a *user* DSH Home: read-only source,
# never a Team Home.
function Test-DshLooksLikeUserDshHome {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($probe in @('settings.yaml', '.credentials.yaml', 'sessions', 'storages')) {
        if (Test-Path -LiteralPath (Join-Path $Path $probe)) { return $true }
    }
    # 这里只是“这个目录像不像用户 DSH Home”的探测名单，不决定任何可写目标。
    foreach ($profileName in @('acp', 'headless', 'default')) {
        $profileDir = Join-Path (Join-Path $Path 'profiles') $profileName
        if ((Test-Path -LiteralPath (Join-Path $profileDir 'package.json') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $profileDir 'node_modules') -PathType Container)) {
            return $true
        }
    }
    return $false
}

function Get-DshTeamHomeState {
    param(
        [Parameter(Mandatory)][string]$TeamDshHome,
        [string]$InstallId,
        [string]$ToolkitId = $script:DshTeamToolkitId
    )
    $target = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($TeamDshHome))
    if (-not (Test-Path -LiteralPath $target)) {
        return [pscustomobject]@{ State = 'missing'; Path = $target; Reason = '目录不存在' }
    }
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        return [pscustomobject]@{ State = 'not-a-directory'; Path = $target; Reason = '目标已存在且不是目录' }
    }
    $marker = Read-DshTeamHomeMarker -TeamDshHome $target
    $validation = Test-DshTeamHomeMarker -Marker $marker -InstallId $InstallId -ToolkitId $ToolkitId
    if ($validation.Ok) { return [pscustomobject]@{ State = 'owned'; Path = $target; Reason = $validation.Reason } }
    if ($marker -and $marker.schema -eq $script:DshTeamMarkerSchema -and $marker.toolkitId -eq $ToolkitId -and
        $InstallId -and $marker.installId -ne $InstallId) {
        return [pscustomobject]@{ State = 'foreign-install'; Path = $target; Reason = $validation.Reason }
    }
    if (Test-DshLooksLikeUserDshHome -Path $target) {
        return [pscustomobject]@{ State = 'user-dsh-home'; Path = $target; Reason = '目录内容看起来是普通 DSH Home' }
    }
    return [pscustomobject]@{ State = 'unowned'; Path = $target; Reason = $validation.Reason }
}

# Resolve the only directory Team-owned runtime configuration may be written into.
# An existing directory is adopted only with a fully matching marker; everything else stops.
function Resolve-DshTeamHome {
    param(
        [string]$Requested,
        [string]$Workspace,
        [Parameter(Mandatory)][string]$InstallId,
        [string]$TeamHomeRoot,
        [switch]$AllowCreate,
        [string]$ToolkitId = $script:DshTeamToolkitId
    )
    $explicit = [bool]$Requested
    if ($explicit) {
        if (-not [System.IO.Path]::IsPathRooted([Environment]::ExpandEnvironmentVariables($Requested))) {
            throw "Team Home 必须是绝对路径：$Requested"
        }
        $target = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Requested))
    }
    else {
        if (-not $TeamHomeRoot) { $TeamHomeRoot = Get-DshTeamHomeRoot }
        $target = [System.IO.Path]::GetFullPath((Join-Path $TeamHomeRoot $InstallId))
    }

    # 所有 Assert 都必须 Out-Null：函数只允许把结果对象写进 pipeline，否则调用方拿到的
    # 会是一个混杂数组，在 Set-StrictMode 下属性访问会直接失败。
    Assert-DshReparseFreePath -Path $target -Label $(if ($explicit) { '-TeamDshHome / REMOTE_TO_DSH_HOME' } else { '默认 Team Home 路径' }) | Out-Null
    Assert-DshTeamHomeOutsideWorkspace -TeamDshHome $target -Workspace $Workspace | Out-Null

    $state = Get-DshTeamHomeState -TeamDshHome $target -InstallId $InstallId -ToolkitId $ToolkitId
    switch ($state.State) {
        'owned' {
            return [pscustomobject]@{ TeamDshHome = $target; Created = $false; Explicit = $explicit; State = 'owned' }
        }
        'missing' {
            if (-not $AllowCreate) {
                throw ("Team Home 不存在：{0}。请先由安装器准备该 Toolkit-owned runtime，或用 -TeamDshHome 指向带合法 marker 的 Team Home。" -f $target)
            }
            Assert-DshReparseFreePath -Path (Split-Path -Parent $target) -Label 'Team Home 父目录' | Out-Null
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Write-DshTeamHomeMarker -TeamDshHome $target -InstallId $InstallId -ToolkitId $ToolkitId | Out-Null
            return [pscustomobject]@{ TeamDshHome = $target; Created = $true; Explicit = $explicit; State = 'created' }
        }
        'user-dsh-home' {
            throw ("拒绝把 {0} 当作 Team Home：{1}。用户 DSH Home 只作为只读配置来源，绝不被 adopt/patch/覆盖。" -f $target, $state.Reason)
        }
        'foreign-install' {
            throw ("拒绝写入 {0}：{1}。它属于另一次安装；请使用本安装 manifest 记录的 install id。" -f $target, $state.Reason)
        }
        'unowned' {
            throw ("拒绝写入 {0}：目录已存在但没有合法 Team Home marker（{1}）。本工具绝不 adopt 无 marker 的目录。" -f $target, $state.Reason)
        }
        default {
            throw ("拒绝写入 {0}：{1}。" -f $target, $state.Reason)
        }
    }
}

# The user DSH Home is a read-only source; the Team Home is the only write target, and the
# two may not overlap in either direction.
function Assert-UserDshHomeReadOnlySource {
    param(
        [Parameter(Mandatory)][string]$UserDshHome,
        [Parameter(Mandatory)][string]$TeamDshHome
    )
    $source = [System.IO.Path]::GetFullPath($UserDshHome)
    $target = [System.IO.Path]::GetFullPath($TeamDshHome)
    if ($source -ieq $target) {
        throw ("用户 DSH Home 与 Team Home 是同一目录（{0}）；拒绝把配置同步到它自己。" -f $source)
    }
    if (Test-DshPathInside -Parent $source -Child $target) {
        throw ("Team Home {0} 位于用户 DSH Home {1} 内；禁止向用户 DSH Home 写入任何内容。" -f $target, $source)
    }
    if (Test-DshPathInside -Parent $target -Child $source) {
        throw ("用户 DSH Home {0} 位于 Team Home {1} 内；同步方向必须单向 User DSH -> Team Home。" -f $source, $target)
    }
    return $true
}

# Deny rule for any file copy: credential stores and private key material are never copied.
function Test-DshDeniedFileName {
    param([Parameter(Mandatory)][string]$Name)
    $base = [System.IO.Path]::GetFileName($Name)
    if (-not $base) { return $false }
    $lower = $base.ToLowerInvariant()
    if ($lower -eq '.env' -or $lower.StartsWith('.env.')) { return $true }
    foreach ($exact in @('.netrc', '_netrc', '.npmrc', '.pypirc', 'credentials', 'credentials.json',
            'credentials.yaml', 'credentials.yml', '.credentials.yaml', '.credentials.yml',
            'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'secrets.json', 'secrets.yaml', 'secrets.yml')) {
        if ($lower -eq $exact) { return $true }
    }
    foreach ($extension in @('.pem', '.key', '.pfx', '.p12', '.jks', '.keystore', '.ppk')) {
        if ($lower.EndsWith($extension)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Atomic writes and DPAPI token protection
# ---------------------------------------------------------------------------

# Atomic byte-exact file copy. Used for settings.yaml and .credentials.yaml: a text
# round-trip through Get-Content/WriteAllText would re-encode them, and Windows PowerShell
# 5.1 decodes a BOM-less UTF-8 file with the ANSI code page, which silently corrupts any
# non-ASCII content. Copying the bytes preserves the source document exactly.
function Copy-DshAtomicFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$RestrictToCurrentUser
    )
    $directory = Split-Path -Parent $Destination
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $temporary = "$Destination.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    Copy-Item -LiteralPath $Source -Destination $temporary -Force
    try {
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw
    }
    if ($RestrictToCurrentUser) {
        # credential 副本的 ACL 收紧失败必须阻断并回滚：留下一个可能继承宽权限的 secret
        # 文件比同步失败严重得多，所以这里不允许“记一条 note 继续”。
        $aclOk = Set-DshCurrentUserOnlyAcl -Path $Destination
        if (-not $aclOk) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            $detail = if ($script:DshAclDiagnostic) { "（$($script:DshAclDiagnostic)）" } else { '' }
            throw ("无法为 {0} 设置仅当前用户 ACL{1}；已回滚（删除）该副本并停止，避免在 Team Home 留下可能继承宽权限的 credential 文件。" -f $Destination, $detail)
        }
    }
    return $Destination
}

# Atomic UTF-8 text write without BOM, so a reader never observes a half-written file.
function Write-DshAtomicText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [switch]$RestrictToCurrentUser
    )
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $temporary = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, $Text, (New-Object System.Text.UTF8Encoding($false)))
    try {
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    catch {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        throw
    }
    if ($RestrictToCurrentUser) {
        Set-DshCurrentUserOnlyAcl -Path $Path | Out-Null
    }
    return $Path
}

# Owner-only DACL via icacls.
#
# `Set-Acl -AclObject (New-Object FileSecurity)` writes a whole security descriptor including
# the SACL section, which needs SeSecurityPrivilege — a normal (non-admin) user does not hold
# it, so that approach failed on a standard machine. `.NET`'s
# `FileInfo.GetAccessControl(Access)` is gone on .NET 8 (PowerShell 7). `icacls` with
# `/inheritance:r /grant:r <user>:F` rewrites only the DACL, needs no special privilege, and
# behaves identically on Windows PowerShell 5.1 and PowerShell 7.
#
# The result is re-read and verified: no inherited ACE may remain and no identity other than
# the current user (or SYSTEM) may keep access. A false return is a hard failure for callers.
function Set-DshCurrentUserOnlyAcl {
    param([Parameter(Mandatory)][string]$Path)
    $script:DshAclDiagnostic = $null
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (-not (Test-Path -LiteralPath $icacls -PathType Leaf)) { $icacls = 'icacls.exe' }
        # 输出被吞掉：不打印文件内容。icacls 的 stderr 在调用方 EAP=Stop 下会被当成
        # terminating error，因此这里临时降级为 Continue 并只用 exit code 判定。
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & $icacls $Path /inheritance:r /grant:r "${identity}:F" 2>&1
            $applyExit = $LASTEXITCODE
            $listing = @(& $icacls $Path 2>&1 | ForEach-Object { [string]$_ })
            $verifyExit = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        if ($applyExit -ne 0) {
            $script:DshAclDiagnostic = "icacls 应用失败 exit $applyExit"
            return $false
        }
        if ($verifyExit -ne 0) {
            $script:DshAclDiagnostic = "icacls 校验失败 exit $verifyExit"
            return $false
        }
        # 只从 icacls 输出解析 ACE（identity:(flags)），不依赖 Get-Acl：在受限宿主里
        # Microsoft.PowerShell.Security 模块可能加载失败。解析与系统语言无关。
        $entries = [regex]::Matches(($listing -join "`n"), '([^\s:]+):\(([^)]*)\)')
        if ($entries.Count -eq 0) {
            $script:DshAclDiagnostic = 'icacls 输出里没有可解析的 ACE'
            return $false
        }
        foreach ($entry in $entries) {
            $owner = $entry.Groups[1].Value
            $flags = $entry.Groups[2].Value
            if ($flags -match 'I') {
                $script:DshAclDiagnostic = "仍存在继承 ACE（$owner`:$flags）"
                return $false
            }
            if ($owner -ieq $identity) { continue }
            if ($owner -match 'SYSTEM$') { continue }
            $script:DshAclDiagnostic = "仍存在其他身份 ACE：$owner"
            return $false
        }
        return $true
    }
    catch {
        # 只记录异常类型与消息（不含文件内容），用于故障排查。
        $script:DshAclDiagnostic = "$($_.Exception.GetType().Name): $($_.Exception.Message)"
        return $false
    }
}

function Initialize-DshDpapi {
    if ('System.Security.Cryptography.ProtectedData' -as [type]) { return $true }
    try {
        Add-Type -AssemblyName System.Security -ErrorAction Stop
    }
    catch {
        throw "当前 PowerShell 无法加载 System.Security（DPAPI）。Monitor access token 不能以明文落盘，已停止。"
    }
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        throw "当前 PowerShell 缺少 System.Security.Cryptography.ProtectedData（DPAPI）。Monitor access token 不能以明文落盘，已停止。"
    }
    return $true
}

function Protect-DshMonitorToken {
    param([Parameter(Mandatory)][string]$Token)
    Initialize-DshDpapi | Out-Null
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Token)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($protected)
}

function Unprotect-DshMonitorToken {
    param([Parameter(Mandatory)][string]$ProtectedToken)
    Initialize-DshDpapi | Out-Null
    $protected = [Convert]::FromBase64String($ProtectedToken)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protected, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# Read the Monitor access token into memory. A legacy plaintext record is refused instead of
# being re-read: writing plaintext tokens is exactly what Release Blocker A forbids.
function Get-DshMonitorAccessToken {
    param([Parameter(Mandatory)]$Record)
    $protected = $null
    if ($Record.PSObject.Properties.Name -contains 'access_token_protected') { $protected = $Record.access_token_protected }
    if ($protected) {
        return (Unprotect-DshMonitorToken -ProtectedToken ([string]$protected))
    }
    if ($Record.PSObject.Properties.Name -contains 'access_token' -and $Record.access_token) {
        throw 'Monitor 授权记录仍是明文 access_token（旧格式）。明文 token 不再被读取；请重新运行 start_dsh_team.cmd 生成 DPAPI 保护的记录。'
    }
    throw 'Monitor 授权记录缺少 access_token_protected；请重新启动 Monitor。'
}

# ---------------------------------------------------------------------------
# Child process environment policy (mirror of src/security.mjs)
# ---------------------------------------------------------------------------
#
# The allowlist and the deny rule must stay byte-for-byte equivalent to
# `CHILD_ENV_ALLOWLIST` / `isDeniedEnvName` in src/security.mjs. The direct test suite
# compares both sides and fails on any divergence, so the policy cannot silently fork.

$script:DshChildEnvAllowlist = @(
    'PATH', 'PATHEXT', 'SYSTEMROOT', 'SYSTEMDRIVE', 'WINDIR', 'COMSPEC', 'TEMP', 'TMP',
    'USERDOMAIN', 'USERNAME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH',
    'LOCALAPPDATA', 'APPDATA', 'PROGRAMDATA', 'PROGRAMFILES', 'PROGRAMFILES(X86)',
    'NUMBER_OF_PROCESSORS', 'PROCESSOR_ARCHITECTURE', 'OS', 'LANG', 'LC_ALL', 'TZ'
)

$script:DshEnvDenyPattern = '(^|_)(TOKEN|TOKENS|KEY|KEYS|APIKEY|API_KEY|SECRET|SECRETS|PASSWORD|PASSWD|PWD|PASSPHRASE|COOKIE|COOKIES|AUTHORIZATION|CREDENTIAL|CREDENTIALS|PRIVATE_KEY|SIGNATURE|SAS|DSN|CONNECTION_STRING)(_|$)'
$script:DshEnvDenyExact = @('DSH_MONITOR_TOKEN', 'NODE_OPTIONS', 'NODE_PATH', 'PSMODULEPATH')

function Test-DshDeniedEnvName {
    param([Parameter(Mandatory)][string]$Name)
    $upper = $Name.ToUpperInvariant()
    if ($script:DshEnvDenyExact -contains $upper) { return $true }
    return [regex]::IsMatch($upper, $script:DshEnvDenyPattern)
}

function Get-DshChildEnvAllowlist { return @($script:DshChildEnvAllowlist) }

function Get-CaseInsensitiveValue {
    param(
        [Parameter(Mandatory)]$Map,
        [Parameter(Mandatory)][string]$Name
    )
    foreach ($key in @($Map.Keys)) {
        if ($key -ieq $Name) { return $Map[$key] }
    }
    return $null
}

# Minimal, explicitly constructed child environment: allowlist first, then the confirmed DSH
# runtime fields. A secret-bearing name in `-Explicit` is refused loudly.
function Get-DshNarrowedChildEnv {
    param([hashtable]$Explicit = @{})
    $source = [System.Environment]::GetEnvironmentVariables()
    $narrowed = @{}
    foreach ($key in $script:DshChildEnvAllowlist) {
        if (Test-DshDeniedEnvName -Name $key) { continue }
        $value = Get-CaseInsensitiveValue -Map $source -Name $key
        if ($null -eq $value) { continue }
        $narrowed[$key] = [string]$value
    }
    foreach ($key in @($Explicit.Keys)) {
        if (Test-DshDeniedEnvName -Name $key) {
            throw "拒绝把 secret-bearing 环境变量 $key 递给子进程（policy security-policy/v1）。"
        }
        if ($null -eq $Explicit[$key]) { continue }
        $narrowed[$key] = [string]$Explicit[$key]
    }
    return $narrowed
}

# Names-only audit of a narrowing decision: safe to log or write into evidence.
function Get-DshChildEnvAudit {
    param(
        [hashtable]$Environment = @{},
        [hashtable]$Explicit = @{}
    )
    $source = [System.Environment]::GetEnvironmentVariables()
    $dropped = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($source.Keys)) {
        $name = [string]$key
        if ($Environment.ContainsKey($name)) { continue }
        if (Test-DshDeniedEnvName -Name $name) { $dropped.Add($name) }
    }
    return [pscustomobject]@{
        Forwarded              = @($Environment.Keys | Sort-Object)
        ForwardCount           = $Environment.Count
        DroppedSensitive       = @($dropped | Sort-Object)
        DroppedSensitiveCount  = $dropped.Count
        ExplicitKeys           = @($Explicit.Keys | Sort-Object)
    }
}

# Run a child process with the narrowed environment, bounded timeout and captured output.
# Used for the DSH availability preflight so the real DSH runtime never inherits the
# launcher's full environment.
function Start-DshNarrowedProcess {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [hashtable]$Environment = @{}
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { $psi.EnvironmentVariables.Clear() } catch { }
    foreach ($key in @($Environment.Keys)) {
        $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw "无法启动子进程：$FileName"
    }
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill() } catch { }
    }
    $stdout = ''
    $stderr = ''
    try { $stdout = [string]$outTask.Result } catch { $stdout = '' }
    try { $stderr = [string]$errTask.Result } catch { $stderr = '' }
    return [pscustomobject]@{
        Stdout   = $stdout
        Stderr   = $stderr
        ExitCode = $(if ($finished) { $process.ExitCode } else { $null })
        TimedOut = (-not $finished)
    }
}

# ---------------------------------------------------------------------------
# Runtime compatibility gate for the entry points
# ---------------------------------------------------------------------------

function Assert-DshPowerShellRuntime {
    param([int]$MinimumMajor = 5)
    $version = $PSVersionTable.PSVersion
    if ($version.Major -lt $MinimumMajor) {
        throw ("需要 PowerShell {0}+（当前 {1}）。请安装 PowerShell 7+ 后重试。" -f $MinimumMajor, $version)
    }
    Assert-JsonSerializerCompatibility | Out-Null
    return [pscustomobject]@{
        Edition = $PSVersionTable.PSEdition
        Version = $version.ToString()
        JsonSerializer = 'safe'
    }
}
