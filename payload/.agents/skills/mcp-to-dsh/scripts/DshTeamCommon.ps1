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

function Resolve-DshUserHome {
    [CmdletBinding()]
    param(
        [string]$Requested,
        [string]$InitialDirectory = (Get-Location).Path,
        [switch]$AllowPrompt,
        [switch]$SelectAgain
    )
    # A bounded lookup, never a directory search. Save only a path in current-user local state.
    $preferencePath = Join-Path (Get-DshTeamBaseDir) 'user-settings-source.json'
    $canPrompt = $AllowPrompt -and [Environment]::UserInteractive -and $env:OS -eq 'Windows_NT'
    $mustChoose = [bool]$SelectAgain
    $candidate = $Requested
    $source = '-UserDshHome'
    if (-not $SelectAgain -and -not $candidate -and (Test-Path -LiteralPath $preferencePath -PathType Leaf)) {
        try {
            $saved = [IO.File]::ReadAllText($preferencePath) | ConvertFrom-Json
            if ($saved.schema -ne 'codex-dsh-user-settings-source/v1' -or -not $saved.userDshHome) { throw 'Invalid configuration location record' }
            $candidate = [string]$saved.userDshHome
            $source = '上次选择的目录'
        } catch {
            if (-not $canPrompt) { throw '无法读取保存的 DSH 配置位置，请交互启动并重新选择，或传入 -UserDshHome。' }
            $mustChoose = $true
        }
    }
    # A GUI choice takes precedence over automatic discovery, including stale environment values.
    if (-not $candidate) { $candidate = $env:DSH_USER_HOME; $source = 'DSH_USER_HOME' }
    if (-not $candidate) { $candidate = $env:DSH_HOME; $source = 'DSH_HOME' }
    if (-not $candidate) { $candidate = Join-Path $HOME '.dsh'; $source = '用户默认目录' }
    if ($mustChoose) {
        if (-not $canPrompt) { throw '当前为非交互运行，请通过 -UserDshHome 指定配置目录。' }
        $candidate = $null
    }
    $picked = $false
    while ($true) {
        if ($candidate) {
            $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
            if ((Test-Path -LiteralPath $expanded -PathType Container) -and
                (Test-Path -LiteralPath (Join-Path $expanded 'settings.yaml') -PathType Leaf)) {
                $resolved = (Resolve-Path -LiteralPath $expanded).Path
                if ($resolved -match '[\x00-\x1f]') { throw 'DSH 配置路径不能包含控制字符。' }
                if ($picked) {
                    Assert-DshReparseFreePath -Path $preferencePath -Label 'DSH 配置位置记录' | Out-Null
                    $value = [ordered]@{ schema = 'codex-dsh-user-settings-source/v1'; userDshHome = $resolved }
                    Write-DshAtomicText -Path $preferencePath -Text (ConvertTo-SafeJson -InputObject $value -Depth 3) | Out-Null
                }
                return $resolved
            }
            if (-not $canPrompt) { throw "$source 未指向包含 settings.yaml 的 DSH 配置目录。请修正该位置；不会改用其他配置。" }
            if ($picked) {
                [System.Windows.Forms.MessageBox]::Show('这个文件夹中没有 settings.yaml。请选择你平时使用的 DSH 配置目录。', '请重新选择 DSH 配置', 'OK', 'Information') | Out-Null
            }
        }
        if (-not $canPrompt) { throw '未找到 DSH 配置。交互启动会提供文件夹选择窗口；自动化运行请指定 -UserDshHome。' }
        $candidate = Show-DshUserHomePicker -InitialDirectory $InitialDirectory
        if (-not $candidate) { throw '已取消选择 DSH 配置，未启动任务。' }
        $picked = $true
    }
}

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

# 0 个候选且未显式指定时使用的 ACP 默认 profile 名。集中命名一次，并在选择结果里显式说明
# 它是默认值，而不是让调用方误以为存在一个“可发现”的既有 profile。
$script:DshDefaultAcpProfileName = 'acp'
# DSH 保留目录名与 DSH 内置 profile 模板名。
#   - Node 会解析 `node_modules`，它绝不能作为 profile 目录名。
#   - web/headless/sdk/sdk-minimal 是 DSH 内置模板，但不是 ACP 子代理入口；把它们初始化后
#     当作 ACP 入口属于错误接线，因此明确拒绝。
$script:DshShippedProfileNames = @('acp', 'web', 'headless', 'sdk', 'sdk-minimal')
$script:DshNonAcpShippedProfileNames = @('web', 'headless', 'sdk', 'sdk-minimal')
$script:DshReservedProfileNames = @('node_modules')
$script:DshTeamProfileNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'

# 名字合法性 + 保留名 + 非 ACP 内置模板拒绝。任何 prepare/初始化之前都必须先过这一关。
function Assert-DshTeamProfileName {
    param([Parameter(Mandatory)][string]$Name)
    $trimmed = ([string]$Name).Trim()
    if (-not $trimmed) { throw 'TeamProfile 不能为空。' }
    if ($trimmed -notmatch $script:DshTeamProfileNamePattern) {
        throw "TeamProfile 必须是 1-64 位字母/数字/._- 且以字母或数字开头：$trimmed"
    }
    if ($script:DshReservedProfileNames -contains $trimmed) {
        throw "TeamProfile 不能使用 DSH 保留目录名 '$trimmed'。"
    }
    if ($script:DshNonAcpShippedProfileNames -contains $trimmed) {
        throw ("Team profile '$trimmed' 是 DSH 内置的非 ACP 模板（web/headless/sdk），不能作为 Codex x DSH Team 的 ACP 入口。请使用 'acp'，或使用自定义名字（自定义名字会用官方 --from-default-profile acp 初始化）。")
    }
    return $trimmed
}

# 已存在、且可作为 ACP 入口的 profile 候选。node_modules 与非 ACP 内置模板都不计入，
# 因此“Team Home 里只有一个 web profile”不会被误当成可用的 ACP 入口。
function Get-DshTeamProfileCandidates {
    param([Parameter(Mandatory)][string]$TeamDshHome)
    $profilesRoot = Join-Path $TeamDshHome 'profiles'
    $found = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) { return @() }
    foreach ($dir in (Get-ChildItem -LiteralPath $profilesRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($script:DshReservedProfileNames -contains $dir.Name) { continue }
        if ($script:DshNonAcpShippedProfileNames -contains $dir.Name) { continue }
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'package.json') -PathType Leaf) {
            $found.Add($dir.Name)
        }
    }
    return @($found)
}

# Team profile 是 owned Team Home 下 profiles\<name> 目录名，必须由配置或可验证发现决定，
# 不允许静默默认：显式参数 > 环境变量 > Team Home 内唯一带 package.json 的 ACP 候选。
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
        $name = Assert-DshTeamProfileName -Name $candidate
        $manifest = Join-Path (Join-Path $TeamDshHome 'profiles') (Join-Path $name 'package.json')
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
            throw "指定的 TeamProfile '$name' 在 Team Home $TeamDshHome 中不存在（缺少 $manifest）。"
        }
        return $name
    }

    $found = @(Get-DshTeamProfileCandidates -TeamDshHome $TeamDshHome)
    if ($found.Count -eq 1) { return $found[0] }
    if ($found.Count -eq 0) {
        throw ("Team Home {0} 里找不到任何带 package.json 的 ACP profile；请用 -TeamProfile 或 CODEX_DSH_TEAM_PROFILE 指定，或让工具按约定初始化默认 ACP profile。" -f $TeamDshHome)
    }
    throw ("Team Home {0} 存在多个候选 profile，无法安全推断可写目标：{1}。请用 -TeamProfile 或 CODEX_DSH_TEAM_PROFILE 明确指定。" -f $TeamDshHome, ($found -join ', '))
}

# Read `dsh.profile.bundles` from a profile manifest. Returns @() when the manifest is absent,
# unparsable, or has no usable bundle list - an empty shell must never count as initialized.
# 只接受非空字符串条目：null、空白、数字/对象都不算“有效 bundle”，避免把空壳当成功。
function Get-DshProfileBundles {
    param([Parameter(Mandatory)][string]$ManifestPath)
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return @() }
    $manifest = $null
    try {
        $manifest = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8)
    }
    catch {
        return @()
    }
    if ($null -eq $manifest) { return @() }
    $dshNode = Get-CaseInsensitiveValue -Map $manifest -Name 'dsh'
    if ($null -eq $dshNode) { return @() }
    $profileNode = Get-CaseInsensitiveValue -Map $dshNode -Name 'profile'
    if ($null -eq $profileNode) { return @() }
    $bundles = Get-CaseInsensitiveValue -Map $profileNode -Name 'bundles'
    if ($null -eq $bundles) { return @() }
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($bundles)) {
        if ($null -eq $item) { continue }
        if ($item -isnot [string]) { continue }
        $text = ([string]$item).Trim()
        if (-not $text) { continue }
        $valid.Add($text)
    }
    return @($valid)
}

# True only when a bundle list really declares the ACP app bundle. Used to prove that a profile
# this toolkit just initialized is an ACP entry, not a web/headless/sdk template.
function Test-DshAcpCapableBundles {
    param([string[]]$Bundles = @())
    foreach ($bundle in @($Bundles)) {
        $name = ([string]$bundle).Trim()
        if (-not $name) { continue }
        if ($name -ieq $script:DshAcpBundleId) { return $true }
        if ($name -imatch '(^|[/@-])dsh-acp-app$') { return $true }
    }
    return $false
}

# First-start bootstrap for a brand-new owned Team Home.
#
# DSH itself initializes `profiles/<name>` from its shipped template on first use; the toolkit
# previously required the profile to already exist, so a fresh install could never start. This
# triggers that initialization through DSH's own offline diagnostic entry point
# (`--dump-default-config`: it composes patches and prints them - it does not boot plugins,
# open a model session or contact a provider), then verifies DSH actually wrote a usable
# manifest with a non-empty ACP bundle list. A bare directory, an empty package.json or a
# non-ACP template is never accepted as the ACP entry.
#
# Idempotent by design: an existing profile manifest is validated and left untouched, and an
# existing directory without a manifest is refused rather than adopted.
function Initialize-DshTeamProfile {
    param(
        [Parameter(Mandatory)][string]$TeamDshHome,
        [Parameter(Mandatory)][string]$ProfileName,
        [Parameter(Mandatory)][string]$DshBinPath,
        [Parameter(Mandatory)][string]$NodePath,
        [string]$Workspace,
        [int]$TimeoutSeconds = 120
    )
    # 非 ACP 内置模板名（web/headless/sdk）在这一步就被拒绝，绝不可能被初始化为 ACP 入口。
    $name = Assert-DshTeamProfileName -Name $ProfileName
    $teamHome = [System.IO.Path]::GetFullPath($TeamDshHome)
    $profilesRoot = Join-Path $teamHome 'profiles'
    $profileDir = Join-Path $profilesRoot $name
    # 写入链上的每一层都要防 reparse：Team Home、profiles 父目录、profile 目录本身，以及后续
    # 的 package.json / cordis.patch.yml / 运行配置都挂在这条链上，只查 Team Home 顶层不够。
    Assert-DshReparseFreePath -Path $teamHome -Label 'Team Home' | Out-Null
    Assert-DshReparseFreePath -Path $profilesRoot -Label 'profiles 父目录' | Out-Null
    Assert-DshReparseFreePath -Path $profileDir -Label 'profile 目录' | Out-Null
    Assert-DshTeamHomeOutsideWorkspace -TeamDshHome $teamHome -Workspace $Workspace | Out-Null
    if (-not (Test-DshPathInside -Parent $profilesRoot -Child $profileDir)) {
        throw ("profile 目录越过 Team Home 的 profiles 根：{0}" -f $profileDir)
    }
    $manifest = Join-Path $profileDir 'package.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        # 已有 manifest：只验证“可用 bundles”，内容原样保留，绝不覆盖/重写。
        $existingBundles = @(Get-DshProfileBundles -ManifestPath $manifest)
        if ($existingBundles.Count -eq 0) {
            throw ("Team Home 中已存在 profile '{0}'，但 {1} 没有有效的非空 dsh.profile.bundles；拒绝把空壳 manifest 当作可用 ACP profile，也不会覆盖它。请修复该 profile，或改用其它 -TeamProfile。" -f $name, $manifest)
        }
        return ([pscustomobject]@{
                Name    = $name
                Dir     = $profileDir
                Created = $false
                Bundles = $existingBundles
            })
    }
    if (Test-Path -LiteralPath $profileDir -PathType Container) {
        throw ("Team Home 中已存在 profile 目录 {0}，但其中没有 package.json；拒绝接管未知或半成品目录。请换一个 -TeamProfile 名称，或自行清理该目录后重试。" -f $profileDir)
    }
    if (-not (Test-Path -LiteralPath $DshBinPath -PathType Leaf)) {
        throw ("找不到已锁定的 DSH 运行时：{0}；无法初始化 Team profile '{1}'。" -f $DshBinPath, $name)
    }
    if (-not (Test-Path -LiteralPath $NodePath -PathType Leaf)) {
        throw ("找不到 node.exe：{0}；无法初始化 Team profile '{1}'。" -f $NodePath, $name)
    }
    # Explicit argument vector: shipped names take no --from-default-profile; a custom name is
    # initialized from the shipped `acp` template (an existing directory never reaches here).
    $dshArguments = New-Object System.Collections.Generic.List[string]
    $dshArguments.Add('--profile')
    $dshArguments.Add($name)
    if ($script:DshShippedProfileNames -notcontains $name) {
        $dshArguments.Add('--from-default-profile')
        $dshArguments.Add($script:DshDefaultAcpProfileName)
    }
    $dshArguments.Add('--dump-default-config')
    $diagnosticArguments = ($dshArguments -join ' ')
    $argumentLine = ('"{0}" {1}' -f $DshBinPath, $diagnosticArguments)
    # 最小但足以真实启动 Windows 子进程的环境：allowlist + 允许的系统变量补齐 + DSH_HOME。
    # 只传 DSH_HOME 会在缺少 SystemRoot/TEMP 的宿主上让 node 启动失败，所以必须走
    # Get-DshNarrowedChildEnv，而不是自己拼一个空环境或继承父进程全部变量。
    $narrowedEnv = Get-DshNarrowedChildEnv -Explicit @{ DSH_HOME = $teamHome }
    $result = Start-DshNarrowedProcess -FileName $NodePath -Arguments $argumentLine `
        -WorkingDirectory $teamHome -TimeoutSeconds $TimeoutSeconds -Environment $narrowedEnv
    if ($result.TimedOut) {
        throw ("DSH profile 初始化超时（{0}s），未完成初始化；没有重试，也没有改动既有内容。" -f $TimeoutSeconds)
    }
    if ($result.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        # 不回显 DSH 的原始 stderr/stdout：那是不受控通道，可能含未脱敏的 provider 信息。
        # 只报 exit code 与安全分类，并给出可本地复现的诊断命令。分类失败时为 unclassified。
        $failureClass = Get-DshProcessFailureClass -Stdout $result.Stdout -Stderr $result.Stderr
        throw ("DSH 未能为 profile '{0}' 初始化运行配置（exit={1}; 分类={2}）。请确认已锁定安装的 DSH 可用；可在本机复现诊断：node `"{3}`" {4}（原始输出可能含未脱敏 provider 信息，本工具不打印它）。" -f $name, $result.ExitCode, $failureClass, $DshBinPath, $diagnosticArguments)
    }
    $bundles = @(Get-DshProfileBundles -ManifestPath $manifest)
    if ($bundles.Count -eq 0) {
        throw ("profile '{0}' 的 package.json 缺少有效的非空 dsh.profile.bundles；拒绝把空壳当作初始化成功。" -f $name)
    }
    if (-not (Test-DshAcpCapableBundles -Bundles $bundles)) {
        throw ("profile '{0}' 已初始化，但其 bundles（{1}）没有声明 ACP 运行入口；拒绝把它当作 ACP 入口。" -f $name, ($bundles -join ', '))
    }
    return ([pscustomobject]@{
            Name    = $name
            Dir     = $profileDir
            Created = $true
            Bundles = $bundles
        })
}

# 两个入口（start_dsh_team.ps1 与独立 Sync-DshTeamConfig.ps1）共用的选择逻辑。
# 顺序是刻意的：先证明 Team Home 属于本安装（owned），再 prepare（缺失时 bootstrap），
# 最后 resolve 出最终名字。选择规则：显式参数 > 环境变量 > 既有唯一 ACP 候选；真空且未
# 指定时显式选择 ACP 默认 profile 并写进 Notes，绝不静默猜测；多候选继续拒绝。
function Resolve-DshTeamProfileSelection {
    param(
        [string]$Requested,
        [Parameter(Mandatory)][string]$TeamDshHome,
        [Parameter(Mandatory)][string]$InstallId,
        [string]$EnvironmentValue,
        [string]$DshBinPath,
        [string]$NodePath,
        [string]$Workspace,
        [int]$TimeoutSeconds = 120
    )
    # 1) ownership：只有带完整 marker 且属于本 install 的 Team Home 才能被 prepare/写入。
    $state = Get-DshTeamHomeState -TeamDshHome $TeamDshHome -InstallId $InstallId
    if ($state.State -ne 'owned') {
        throw ("拒绝在 {0} 上 prepare Team profile：状态={1}（{2}）。只有本安装拥有的 Team Home 才能被写入。" -f $TeamDshHome, $state.State, $state.Reason)
    }

    $notes = New-Object System.Collections.Generic.List[string]
    $source = $null
    $explicitName = $Requested
    if (-not $explicitName) { $explicitName = $EnvironmentValue }
    if ($explicitName) {
        # 显式自定义名字即使尚不存在也允许 bootstrap；内置非 ACP 模板在这里就会被拒绝。
        $name = Assert-DshTeamProfileName -Name $explicitName
        $source = $(if ($Requested) { 'parameter' } else { 'environment' })
    }
    else {
        $found = @(Get-DshTeamProfileCandidates -TeamDshHome $TeamDshHome)
        if ($found.Count -gt 1) {
            throw ("Team Home {0} 存在多个候选 profile，无法安全推断可写目标：{1}。请用 -TeamProfile 或 CODEX_DSH_TEAM_PROFILE 明确指定。" -f $TeamDshHome, ($found -join ', '))
        }
        if ($found.Count -eq 1) {
            $name = $found[0]
            $source = 'discovered'
        }
        else {
            # 真空且未指定：按约定选择 ACP 默认 profile，并在输出里显式说明。
            $name = $script:DshDefaultAcpProfileName
            $source = 'default-acp'
            $notes.Add(("Team Home 中没有任何 ACP profile；按约定使用默认 ACP profile '{0}' 并用官方 DSH 初始化它。" -f $name))
        }
    }

    # 2) prepare：既有 manifest 只校验并保留；缺失时才用官方 DSH 初始化。
    $prepared = Initialize-DshTeamProfile -TeamDshHome $TeamDshHome -ProfileName $name `
        -DshBinPath $DshBinPath -NodePath $NodePath -Workspace $Workspace -TimeoutSeconds $TimeoutSeconds
    if ($prepared.Created) {
        $notes.Add(("已用官方 DSH 初始化 profile '{0}'（bundles: {1}）。" -f $prepared.Name, (@($prepared.Bundles) -join ', ')))
    }
    else {
        $notes.Add(("复用已有 profile '{0}'（bundles: {1}），内容未被修改。" -f $prepared.Name, (@($prepared.Bundles) -join ', ')))
    }

    # 3) resolve：最终名字必须来自 Resolve-DshTeamProfile，而不是本函数内部推断。
    $finalName = Resolve-DshTeamProfile -Requested $prepared.Name -TeamDshHome $TeamDshHome
    return [pscustomobject]@{
        Name    = $finalName
        Dir     = $prepared.Dir
        Created = [bool]$prepared.Created
        Bundles = @($prepared.Bundles)
        Source  = $source
        Notes   = @($notes)
    }
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
            # safe accessor：缺字段只会让这份 manifest 被判为不可用并按 malformed 重新生成，
            # 而不是依赖严格模式抛异常来“碰巧”走到同一个分支。
            $existingSchema = Get-CaseInsensitiveValue -Map $existing -Name 'schema'
            $existingToolkit = Get-CaseInsensitiveValue -Map $existing -Name 'toolkitId'
            $existingInstall = Get-CaseInsensitiveValue -Map $existing -Name 'installId'
            if ($existingSchema -eq $script:DshTeamInstallSchema -and
                $existingToolkit -eq $ToolkitId -and
                $existingInstall -and ([string]$existingInstall).Trim()) {
                return [pscustomobject]@{
                    InstallId    = [string]$existingInstall
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
    # 标量/数组 JSON 也会被 ConvertFrom-Json 接受；它们不是 marker 对象。
    if ($Marker -is [string] -or $Marker -is [ValueType] -or $Marker -is [System.Array]) {
        return [pscustomobject]@{ Ok = $false; Reason = 'marker 缺失或不是对象' }
    }
    # 字段读取一律走 safe accessor：缺字段时返回 $null 并给出可读 Reason，而不是让
    # Set-StrictMode -Version Latest 抛 PropertyNotFoundException 覆盖真正的诊断信息。
    $values = @{}
    foreach ($field in $script:DshTeamMarkerRequiredFields) {
        $value = Get-CaseInsensitiveValue -Map $Marker -Name $field
        if ($null -eq $value -or -not ([string]$value).Trim()) {
            return [pscustomobject]@{ Ok = $false; Reason = "marker 缺少必需字段 $field" }
        }
        $values[$field] = ([string]$value).Trim()
    }
    if ($values['schema'] -ne $script:DshTeamMarkerSchema) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker schema $($values['schema']) 不受支持" }
    }
    if ($values['toolkitId'] -ne $ToolkitId) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker 属于 toolkit $($values['toolkitId'])" }
    }
    if ($values['purpose'] -ne $script:DshTeamMarkerPurpose) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker purpose $($values['purpose']) 不正确" }
    }
    if ($InstallId -and $values['installId'] -ne $InstallId) {
        return [pscustomobject]@{ Ok = $false; Reason = "marker 属于 install $($values['installId'])，不是本次安装的 $InstallId" }
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
    # marker 字段读取同样走 safe accessor：缺 schema/installId 的 marker 只会得到
    # unowned/foreign-install 判定，不会因严格模式抛异常而丢掉可读原因。
    $markerSchema = Get-CaseInsensitiveValue -Map $marker -Name 'schema'
    $markerToolkit = Get-CaseInsensitiveValue -Map $marker -Name 'toolkitId'
    $markerInstall = Get-CaseInsensitiveValue -Map $marker -Name 'installId'
    if ($null -ne $marker -and $markerSchema -eq $script:DshTeamMarkerSchema -and $markerToolkit -eq $ToolkitId -and
        $InstallId -and $markerInstall -and $markerInstall -ne $InstallId) {
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

# 属性读取在 Set-StrictMode -Version Latest 下必须安全：ConvertFrom-Json 得到 PSCustomObject
# （没有 .Keys），而缺字段时 $obj.missing 会直接抛 PropertyNotFoundException。这个 helper 只做
# “存在即返回、不存在返回 $null”，让调用方显式判定必需字段，而不是依赖严格模式抛异常。
# IDictionary（[ordered]@{}/hashtable）与 PSCustomObject 都支持。
function Get-CaseInsensitiveValue {
    param(
        [Parameter(Mandatory)][AllowNull()]$Map,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Map) { return $null }
    if ($Map -is [System.Collections.IDictionary]) {
        foreach ($key in @($Map.Keys)) {
            if ([string]$key -ieq $Name) { return $Map[$key] }
        }
        return $null
    }
    foreach ($property in @($Map.PSObject.Properties)) {
        if ($property.Name -ieq $Name) { return $property.Value }
    }
    return $null
}

# 允许“按系统环境补齐”的变量名。当父进程环境缺失这些名字（最小化启动的宿主、测试探针）
# 时，从 Machine/User 作用域或系统 API 取值补齐，绝不因此整体继承父进程环境。
$script:DshChildEnvSystemFallbackNames = @('SYSTEMROOT', 'SYSTEMDRIVE', 'WINDIR', 'COMSPEC', 'PATH', 'PATHEXT', 'TEMP', 'TMP')

function Get-DshSystemEnvFallback {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($scope in @('Machine', 'User')) {
        $value = $null
        try { $value = [System.Environment]::GetEnvironmentVariable($Name, $scope) } catch { $value = $null }
        if ($value -and ([string]$value).Trim()) { return [string]$value }
    }
    $upper = $Name.ToUpperInvariant()
    if ($upper -eq 'TEMP' -or $upper -eq 'TMP') {
        try {
            $temp = [System.IO.Path]::GetTempPath()
            if ($temp) { return $temp.TrimEnd('\', '/') }
        }
        catch { }
        return $null
    }
    if ($upper -eq 'SYSTEMROOT' -or $upper -eq 'WINDIR') {
        try {
            $windows = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows)
            if ($windows) { return $windows }
        }
        catch { }
        return $null
    }
    if ($upper -eq 'SYSTEMDRIVE') {
        try {
            $windows = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Windows)
            if ($windows -and $windows.Length -ge 2) { return $windows.Substring(0, 2) }
        }
        catch { }
        return $null
    }
    return $null
}

# Minimal, explicitly constructed child environment: allowlist first, then the confirmed DSH
# runtime fields, then an allowlisted system-variable fallback. A secret-bearing name in
# `-Explicit` is refused loudly.
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
    # 补齐缺失的允许系统变量：真实 Windows 启动需要 SystemRoot/TEMP/PATH 等；只对 allowlist
    # 内的名字补齐，既避免“继承所有变量”，也避免子进程因缺系统变量而失败。
    foreach ($key in $script:DshChildEnvSystemFallbackNames) {
        if ($narrowed.ContainsKey($key)) { continue }
        if (Test-DshDeniedEnvName -Name $key) { continue }
        $fallback = Get-DshSystemEnvFallback -Name $key
        if ($null -eq $fallback) { continue }
        $narrowed[$key] = [string]$fallback
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
# Diagnosable-but-safe failure reporting
# ---------------------------------------------------------------------------
#
# 失败必须可诊断，但 DSH 子进程的原始 stdout/stderr 是不受控通道，可能带未脱敏的 provider
# 凭据。这里只把已识别的失败签名映射成稳定分类，配合 exit code 输出；绝不回显原始文本。

$script:DshProcessFailureSignatures = @(
    @{ Class = 'credentials'; Pattern = 'credentials-local:' },
    @{ Class = 'settings'; Pattern = 'settings-file:' },
    @{ Class = 'permission'; Pattern = 'EPERM' },
    @{ Class = 'permission'; Pattern = 'EACCES' },
    @{ Class = 'module-missing'; Pattern = 'Cannot find module' },
    @{ Class = 'module-missing'; Pattern = 'ERR_MODULE_NOT_FOUND' },
    @{ Class = 'network'; Pattern = 'ENOTFOUND' },
    @{ Class = 'network'; Pattern = 'ETIMEDOUT' },
    @{ Class = 'network'; Pattern = 'ECONNREFUSED' },
    @{ Class = 'network'; Pattern = 'ECONNRESET' },
    @{ Class = 'provider-config'; Pattern = 'is not configured' },
    @{ Class = 'quota'; Pattern = 'Insufficient Balance' }
)

function Get-DshProcessFailureClass {
    param([string]$Stdout, [string]$Stderr)
    $text = [string]$Stdout + "`n" + [string]$Stderr
    $classes = New-Object System.Collections.Generic.List[string]
    foreach ($signature in $script:DshProcessFailureSignatures) {
        if ($text.IndexOf([string]$signature.Pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            if (-not $classes.Contains([string]$signature.Class)) { $classes.Add([string]$signature.Class) }
        }
    }
    if ($classes.Count -eq 0) { return 'unclassified' }
    return ($classes -join '+')
}

# The DSH entry point bundled next to a skill root. The standalone sync CLI may run without an
# explicit -DshBinPath (the Monitor's one-click sync), so it derives the locked runtime here.
function Get-DshBundledDshBinPath {
    param([Parameter(Mandatory)][string]$SkillRoot)
    return (Join-Path $SkillRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js')
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

# Native Windows folder browser; loaded only for interactive setup.
function Show-DshUserHomePicker {
    param([string]$InitialDirectory)
    Add-Type -AssemblyName System.Windows.Forms
    if (-not ('DshUserHomePicker' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DshUserHomePicker
{
    public static string Select(string initialDirectory)
    {
        IFileDialog dialog = null; IShellItem initial = null, result = null;
        try {
            dialog = (IFileDialog)new FileOpenDialog();
            uint options; dialog.GetOptions(out options);
            dialog.SetOptions(options | 0x20U | 0x40U | 0x800U | 0x8U | 0x2000000U);
            dialog.SetTitle("选择 DSH 配置文件夹（其中应有 settings.yaml）");
            dialog.SetOkButtonLabel("选择此文件夹");
            Guid iid = typeof(IShellItem).GUID;
            Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(initialDirectory, IntPtr.Zero, ref iid, out initial));
            dialog.SetDefaultFolder(initial); dialog.SetFolder(initial);
            int hr = dialog.Show(IntPtr.Zero);
            if (hr == unchecked((int)0x800704C7)) return null;
            Marshal.ThrowExceptionForHR(hr);
            dialog.GetResult(out result);
            IntPtr path; result.GetDisplayName(0x80058000U, out path);
            try { return Marshal.PtrToStringUni(path); } finally { Marshal.FreeCoTaskMem(path); }
        } finally {
            if (result != null) Marshal.ReleaseComObject(result);
            if (initial != null) Marshal.ReleaseComObject(initial);
            if (dialog != null) Marshal.ReleaseComObject(dialog);
        }
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IShellItem item);
    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    private class FileOpenDialog { }
    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint count, IntPtr specs); void SetFileTypeIndex(uint index); void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie); void Unadvise(uint cookie);
        void SetOptions(uint options); void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item); void SetFolder(IShellItem item); void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name); void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetResult(out IShellItem item); void AddPlace(IShellItem item, uint location);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result); void SetClientGuid(ref Guid guid); void ClearClientData(); void SetFilter(IntPtr filter);
    }
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint type, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }
}
"@
    }
    if (-not (Test-Path -LiteralPath $InitialDirectory -PathType Container)) { $InitialDirectory = [Environment]::GetFolderPath('UserProfile') }
    try { return [DshUserHomePicker]::Select($InitialDirectory) }
    catch {
        $fallback = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $fallback.Description = '请选择包含 settings.yaml 的 DSH 配置文件夹'
            $fallback.SelectedPath = $InitialDirectory
            $fallback.ShowNewFolderButton = $false
            if ($fallback.ShowDialog() -eq 'OK') { return $fallback.SelectedPath }
            return $null
        } finally { $fallback.Dispose() }
    }
}
