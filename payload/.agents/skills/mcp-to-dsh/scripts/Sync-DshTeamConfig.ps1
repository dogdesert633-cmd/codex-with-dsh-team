# Sync-DshTeamConfig.ps1
#
# Copies the runtime configuration that the user's own DSH actually uses into the
# Toolkit-owned DSH Team runtime home, so delegated DSH child agents run on the same
# provider / model / auth as the interactive DSH.
#
# Direction is one-way and enforced: User DSH Home (read-only source) -> owned Team Home.
# The Team Home must prove Toolkit ownership with a matching marker; an unowned directory,
# a marker from another installation, or a directory that looks like a normal DSH Home is
# refused instead of being patched.
#
# Synced (runtime configuration only):
#   - settings.yaml              provider list + agent default provider/model
#   - .credentials.yaml          API keys referenced by apiKeyEnv (atomic, owner-only ACL)
#   - profiles/<profile>/cordis.patch.yml  pins the *selected* ACP profile to the configured
#                                provider/model
#
# The selected Team profile itself is only ever prepared, never copied from the user home:
# it is bootstrapped from the official DSH ACP template when it is missing, and an existing
# manifest/patch is validated and left untouched. User profile manifests and plugins are not
# mirrored, so a private plugin can never leak into the Team runtime and a newer Team template
# can never be overwritten by an older user copy.
#
# Never copied (personal, credential-bearing or regenerable state):
#   sessions/, storages/, attachments/, *.log, artifacts, caches, backups,
#   user profiles/<name>/ payloads, .env*, *.pem, *.key, *.pfx, id_rsa*, .netrc, .npmrc.
#
# No credential value is ever printed, and the credentials file is never re-emitted: the
# summary reports only the changed relative path.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 共享安全助手：安全 JSON、Team Home ownership marker、原子写与当前用户 ACL。
if (-not (Get-Command ConvertTo-SafeJson -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'DshTeamCommon.ps1')
}

function Get-DshConfigMap {
    param([Parameter(Mandatory)][string]$Text)

    $map = [ordered]@{}
    foreach ($line in ($Text -split "\r?\n")) {
        $match = [regex]::Match($line, '^\s*"?([A-Za-z0-9_./-]+)"?\s*:\s*(.*)$')
        if (-not $match.Success) { continue }
        $value = $match.Groups[2].Value.Trim()
        if ($value -eq '' -or $value -eq '|' -or $value -eq '>') { continue }
        $map[$match.Groups[1].Value] = $value
    }
    return $map
}

# True when the document holds usable apiKeyEnv credentials: a plain mapping of
# credential reference to non-empty string. The nested `version:`/`refs:` layout
# written by newer runtimes is accepted, and independently re-checked by the
# caller's runtime check, so it is not rejected here.
function Test-DshCredentialsDocument {
    param([Parameter(Mandatory)][string]$Text)

    $map = Get-DshConfigMap -Text $Text
    $keyLike = @($map.Keys | Where-Object { $_ -like '*API_KEY*' -or $_ -like '*_TOKEN' })
    if ($keyLike.Count -eq 0) {
        throw "the credentials file holds no apiKeyEnv-style entry (expected at least one *_API_KEY reference)"
    }
    return $map
}

function Get-SettingsSectionValue {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    $lines = $Text -split "\r?\n"
    $inSection = $false
    foreach ($line in $lines) {
        if ($line -match '^([A-Za-z0-9_.\-]+):\s*$') {
            $inSection = ($Matches[1] -eq $Section)
            continue
        }
        if (-not $inSection) { continue }
        $match = [regex]::Match($line, '^\s+' + [regex]::Escape($Key) + ':\s*(\S+)\s*$')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return $null
}

# Provider -> model ids, plus the configured default provider/model, read from
# the user's settings.yaml. Only a bounded indentation-aware scan is performed so
# no YAML parser dependency is introduced.
function Get-DshModelSelection {
    param([Parameter(Mandatory)][string]$Text)

    $defaultProvider = Get-SettingsSectionValue -Text $Text -Section 'agent-default-model' -Key 'provider'
    $defaultModel = Get-SettingsSectionValue -Text $Text -Section 'agent-default-model' -Key 'model'

    $providers = [ordered]@{}
    $lines = $Text -split "\r?\n"
    $inProviders = $false
    $providersIndent = -1
    $currentProvider = $null
    $currentModel = $null
    $inModels = $false

    foreach ($line in $lines) {
        if ($line -match '^(\s*)providers:\s*$') {
            $providersIndent = $Matches[1].Length
            $inProviders = $true
            continue
        }
        if ($line -match '^([A-Za-z0-9_.\-]+):\s*$') { $inProviders = $false; continue }
        if (-not $inProviders) { continue }

        $providerMatch = [regex]::Match($line, ('^\s{{{0}}}([A-Za-z0-9_.\-]+):\s*$' -f ($providersIndent + 2)))
        if ($providerMatch.Success) {
            if ($currentProvider) { $providers[$currentProvider] = @($script:seenModels) }
            $currentProvider = $providerMatch.Groups[1].Value
            $script:seenModels = New-Object System.Collections.Generic.List[string]
            $inModels = $false
            continue
        }
        if (-not $currentProvider) { continue }
        if ($line -match ('^\s{{{0}}}models:\s*$' -f ($providersIndent + 4))) { $inModels = $true; continue }
        if ($line -match ('^\s{{{0}}}\S' -f ($providersIndent + 4))) { $inModels = $false; continue }
        if (-not $inModels) { continue }

        $idMatch = [regex]::Match($line, ('^\s{{{0}}}-\s+id:\s*(\S+)\s*$' -f ($providersIndent + 6)))
        if ($idMatch.Success) {
            $modelId = $idMatch.Groups[1].Value.Trim('"', "'")
            if (-not $script:seenModels.Contains($modelId)) { $script:seenModels.Add($modelId) }
            $currentModel = $null
            continue
        }
        $nameMatch = [regex]::Match($line, ('^\s{{{0}}}name:\s*(\S+)\s*$' -f ($providersIndent + 8)))
        if ($nameMatch.Success -and $currentModel -and -not $script:seenModels.Contains($nameMatch.Groups[1].Value)) {
            $script:seenModels.Add($nameMatch.Groups[1].Value)
            $currentModel = $null
            continue
        }
        if ($currentModel -and $line -match ('^\s{{{0}}}\S' -f ($providersIndent + 8))) {
            if (-not $script:seenModels.Contains($currentModel)) { $script:seenModels.Add($currentModel) }
            $currentModel = $null
        }
    }
    if ($currentProvider) { $providers[$currentProvider] = @($script:seenModels) }
    Remove-Variable -Name seenModels -Scope Script -ErrorAction SilentlyContinue

    if (-not $defaultProvider -or -not $defaultModel) {
        throw 'settings.yaml does not declare agent-default-model.provider and agent-default-model.model; the Team runtime cannot be pinned to a working model.'
    }
    # `deepseek-official` is supplied by DSH's built-in llm-deepseek adapter,
    # not by the optional llm-pi-ai provider catalog. Its model id is passed
    # through by that adapter, so the default selection remains valid without
    # a matching `llm-pi-ai.providers` entry.
    $builtInProviders = @('deepseek-official')
    if ($providers.Contains($defaultProvider)) {
        $models = @($providers[$defaultProvider])
        if ($models.Count -eq 0) {
            throw "provider '$defaultProvider' declares no models in settings.yaml."
        }
        if (-not ($models -contains $defaultModel)) {
            throw "provider '$defaultProvider' does not list model '$defaultModel' in settings.yaml (declared: $($models -join ', '))."
        }
    }
    elseif ($builtInProviders -contains $defaultProvider) {
        $models = @($defaultModel)
    }
    else {
        throw "settings.yaml default provider '$defaultProvider' has no llm-pi-ai provider entry and is not a supported built-in provider."
    }

    return [pscustomobject]@{
        Providers       = $providers
        DefaultProvider = $defaultProvider
        DefaultModel    = $defaultModel
        ProviderModels  = $models
    }
}

# Renders the profile patch that pins the child-agent runtime. The patch layer is applied
# after every bundle layer, so it overrides the bundle's own default selection.
# `- id:` is the DSH built-in ACP bundle id (a DSH protocol identifier, named once in
# DshTeamCommon.ps1), while the *profile directory* is resolved per installation.
function Get-AcpPatchText {
    param(
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Model,
        [string]$BundleId = $script:DshAcpBundleId
    )

    return @"
# Generated by start_dsh_team.ps1 - do not edit by hand.
#
# The bundle ships its own provider/model default, which may have no credit even when the
# user's interactive DSH works. This patch layer is applied after the bundle layer and pins
# the DSH Team child-agent runtime to the provider and model that the user's own DSH is
# configured to use.
- id: $BundleId
  config:
    provider: $Provider
    model: $Model
"@
}

function Test-AcpPatchMatches {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Provider,
        [Parameter(Mandatory)][string]$Model
    )

    $providerMatch = [regex]::Match($Text, '(?m)^\s+provider:\s*(\S+)\s*$')
    $modelMatch = [regex]::Match($Text, '(?m)^\s+model:\s*(\S+)\s*$')
    return ($providerMatch.Success -and $modelMatch.Success -and
        $providerMatch.Groups[1].Value -eq $Provider -and $modelMatch.Groups[1].Value -eq $Model)
}

# 解析随包安装、已锁定的 DSH 运行时。CLI 模式（Monitor 一键同步）不会显式传 -DshBinPath，
# 因此在这里从 skill root 推导；被 start_dsh_team.ps1 dot-source 时，调用方会显式传参。
function Get-DshSyncBootstrapRuntime {
    $skillRoot = Split-Path -Parent $PSScriptRoot
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    return [pscustomobject]@{
        DshBinPath = (Get-DshBundledDshBinPath -SkillRoot $skillRoot)
        NodePath   = $(if ($nodeCommand) { $nodeCommand.Source } else { $null })
    }
}

function Invoke-DshTeamConfigSync {
    <#
    .SYNOPSIS
        Synchronise the user's working DSH runtime configuration into the owned Team DSH home.
    .DESCRIPTION
        Returns a report object describing what was synced and which provider/model the
        Team runtime is pinned to. Throws on any condition that would make the Team runtime
        unusable, and never prints credential values. The selected Team profile is only
        prepared/resolved - user profile payloads are never copied into the Team Home.
    #>
    param(
        [Parameter(Mandatory)][string]$UserDshHome,
        [Parameter(Mandatory)][string]$TeamDshHome,
        # Team profile 目录名；为空时按 owned Team Home 内唯一 ACP 候选发现；真空且未指定时
        # 选择 ACP 默认 profile 并在 notes 里显式说明；0/多候选不再静默。
        [string]$TeamProfile,
        # 稳定 install id 与 manifest 路径；为空时从 manifest 读取或首次创建。
        [string]$InstallId,
        [string]$InstallManifestPath,
        [string]$TeamHomeRoot,
        [string]$Workspace,
        # 已锁定的 DSH 运行时（profile bootstrap 用）。为空时从本脚本所在 skill root 推导。
        [string]$DshBinPath,
        [string]$NodePath,
        [int]$ProfileTimeoutSeconds = 120
    )

    if (-not $InstallId) {
        $identity = Get-DshTeamInstallIdentity -ManifestPath $InstallManifestPath
        $InstallId = $identity.InstallId
    }

    $userHome = (Resolve-Path -LiteralPath $UserDshHome).Path
    # Team Home 必须先是 Toolkit-owned：reparse/越界检查 + marker 完整匹配，否则在这里停止。
    $resolvedTeam = Resolve-DshTeamHome -Requested $TeamDshHome -Workspace $Workspace `
        -InstallId $InstallId -TeamHomeRoot $TeamHomeRoot -AllowCreate
    $teamHome = $resolvedTeam.TeamDshHome
    # 同步方向永远单向：用户 DSH Home 只读，Team Home 唯一可写。
    Assert-UserDshHomeReadOnlySource -UserDshHome $userHome -TeamDshHome $teamHome | Out-Null

    $notes = New-Object System.Collections.Generic.List[string]
    $changed = New-Object System.Collections.Generic.List[string]

    # 0. Team profile：owned 验证 -> prepare/ensure -> resolve，两个入口共用同一逻辑。
    #    先把 profile 准备好再复制凭据：新 Home 若无法成为可用的 ACP 运行时，就不会先拿到凭据。
    if (-not $DshBinPath -or -not $NodePath) {
        $runtime = Get-DshSyncBootstrapRuntime
        if (-not $DshBinPath) { $DshBinPath = $runtime.DshBinPath }
        if (-not $NodePath) { $NodePath = $runtime.NodePath }
    }
    $profileSelection = Resolve-DshTeamProfileSelection -Requested $TeamProfile -TeamDshHome $teamHome `
        -InstallId $InstallId -EnvironmentValue $env:CODEX_DSH_TEAM_PROFILE `
        -DshBinPath $DshBinPath -NodePath $NodePath -Workspace $Workspace -TimeoutSeconds $ProfileTimeoutSeconds
    $TeamProfile = $profileSelection.Name
    foreach ($profileNote in @($profileSelection.Notes)) { $notes.Add($profileNote) }

    # 1. settings.yaml -------------------------------------------------------
    $userSettingsPath = Join-Path $userHome 'settings.yaml'
    if (-not (Test-Path -LiteralPath $userSettingsPath -PathType Leaf)) {
        throw "the user DSH settings file was not found: $userSettingsPath"
    }
    $userSettingsText = Get-Content -Raw -LiteralPath $userSettingsPath
    $selection = Get-DshModelSelection -Text $userSettingsText

    $teamSettingsPath = Join-Path $teamHome 'settings.yaml'
    # Compare the complete file, not only provider/model. DSH settings are an
    # extensible document; every actual content change must reach Team home.
    $settingsSynced = $true
    if (Test-Path -LiteralPath $teamSettingsPath -PathType Leaf) {
        $teamSettingsText = Get-Content -Raw -LiteralPath $teamSettingsPath
        $settingsSynced = $teamSettingsText -cne $userSettingsText
    }
    if ($settingsSynced) {
        # 原子「按字节」复制：settings.yaml 必须与用户 Home 的文档完全一致。
        # 走文本往返会重新编码，而 Windows PowerShell 5.1 对无 BOM 的 UTF-8 文件按 ANSI
        # 代码页解码，非 ASCII 内容会被静默损坏。
        # Out-Null 是必需的：helper 的返回值不能混进本函数的 pipeline 结果，
        # 否则调用方拿到的是混杂数组（Set-StrictMode 下属性访问会直接失败）。
        Copy-DshAtomicFile -Source $userSettingsPath -Destination $teamSettingsPath | Out-Null
        $changed.Add('settings.yaml')
    }
    else {
        $notes.Add('settings.yaml 已与用户 DSH 的 provider/model 配置一致。')
    }

    # 2. .credentials.yaml ---------------------------------------------------
    # DSH 的 credentials-local 插件从 <DSH_HOME>/.credentials.yaml 读取 apiKeyEnv 引用的密钥，
    # 因此 Team Home 确实需要这一份副本才能完成真实 provider 往返。复制只发生在明确同步流程里，
    # 目标是已证明 ownership 的 Team Home，并且：原子写 + 只允许当前用户读取 + 绝不记录内容。
    $userCredentialsPath = Join-Path $userHome '.credentials.yaml'
    if (-not (Test-Path -LiteralPath $userCredentialsPath -PathType Leaf)) {
        throw "the user DSH credentials file was not found: $userCredentialsPath"
    }
    $userCredentialsText = Get-Content -Raw -LiteralPath $userCredentialsPath
    $userKeys = Test-DshCredentialsDocument -Text $userCredentialsText

    $teamCredentialsPath = Join-Path $teamHome '.credentials.yaml'
    $credentialsSynced = $false
    if (Test-Path -LiteralPath $teamCredentialsPath -PathType Leaf) {
        $teamCredentialsText = Get-Content -Raw -LiteralPath $teamCredentialsPath
        # Credentials are compared/copied locally as opaque bytes. Never emit
        # their values or key names, and do not infer equality from a partial
        # YAML parse because the runtime may add new credential fields.
        $credentialsSynced = $teamCredentialsText -cne $userCredentialsText
    }
    else {
        $credentialsSynced = $true
    }
    if ($credentialsSynced) {
        # 按字节原子复制 + 当前用户 ACL。ACL 失败会在 helper 内删除副本并抛错（阻断 + 回滚），
        # 绝不会留下一个可能继承宽权限的 credential 文件。
        # 内容、键名与长度都不记录，只报告 changed path。
        Copy-DshAtomicFile -Source $userCredentialsPath -Destination $teamCredentialsPath -RestrictToCurrentUser | Out-Null
        $changed.Add('.credentials.yaml')
    }
    else {
        $notes.Add('Team 凭证已与用户 DSH 凭证一致。')
    }

    # 3. Selected profile model pin ------------------------------------------
    # 只写当前选定 profile 的 patch。用户 profiles 的 manifest/插件不再整体复制进 Team Home：
    # 未知用户插件不会泄漏，Team 模板/旧自定义 manifest 也不会被用户副本覆盖。
    $profileDir = $profileSelection.Dir
    if (-not (Test-Path -LiteralPath $profileDir -PathType Container)) {
        throw "the Team DSH home has no '$TeamProfile' profile at $profileDir; the DSH Team bridge cannot start without it."
    }
    $patchPath = Join-Path $profileDir 'cordis.patch.yml'
    # 写入 patch 前再确认一次写入链：profile 目录与 patch 文件本身都不得是 reparse point。
    Assert-DshReparseFreePath -Path $profileDir -Label 'profile 目录' | Out-Null
    Assert-DshReparseFreePath -Path $patchPath -Label 'cordis.patch.yml' | Out-Null
    $patchText = Get-AcpPatchText -Provider $selection.DefaultProvider -Model $selection.DefaultModel
    $patchNeedsWrite = $true
    if (Test-Path -LiteralPath $patchPath -PathType Leaf) {
        $existingPatch = Get-Content -Raw -LiteralPath $patchPath
        $patchNeedsWrite = -not (Test-AcpPatchMatches -Text $existingPatch -Provider $selection.DefaultProvider -Model $selection.DefaultModel)
        if ($patchNeedsWrite) {
            $stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
            Copy-Item -LiteralPath $patchPath -Destination "$patchPath.$stamp.bak" -Force
        }
    }
    if ($patchNeedsWrite) {
        # Written atomically and without a BOM: this file is consumed by the DSH YAML loader.
        Write-DshAtomicText -Path $patchPath -Text $patchText | Out-Null
        $changed.Add("profiles/$TeamProfile/cordis.patch.yml")
    }
    else {
        $notes.Add("profiles/$TeamProfile/cordis.patch.yml 已固定为当前配置的模型。")
    }

    return [pscustomobject]@{
        UserDshHome      = $userHome
        TeamDshHome      = $teamHome
        TeamProfile      = $TeamProfile
        TeamProfileSource = $profileSelection.Source
        Provider         = $selection.DefaultProvider
        Model            = $selection.DefaultModel
        ProviderModels   = $selection.ProviderModels
        # Deliberately omit credential metadata from the public result.
        Changed          = @($changed)
        Notes            = @($notes)
    }
}

# ---------------------------------------------------------------------------
# Safe CLI mode used only by the monitor's one-click "sync settings" endpoint.
# `start_dsh_team.ps1` dot-sources this file as a library (InvocationName is '.'),
# so this branch never runs during bootstrap and never clobbers caller variables.
# The endpoint invokes this file directly with `powershell.exe -File ...`, which
# binds `-UserDshHome` / `-TeamDshHome` into `$args` and emits one JSON object.
# It deliberately never calls `start_dsh_team.ps1` and never stops the monitor.
# ---------------------------------------------------------------------------
if ($MyInvocation.InvocationName -ne '.') {
    # The monitor reads this branch through a pipe, so the summary must leave as UTF-8: a host
    # codepage such as 936 would otherwise mangle the Chinese notes into unreadable text.
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
    # Windows PowerShell 5.1 与 PowerShell 7+ 都必须通过 JSON 兼容探测，否则明确阻断。
    Assert-DshPowerShellRuntime | Out-Null
    $cliUser = $null
    $cliTeam = $null
    $cliProfile = $null
    $cliInstallId = $null
    $cliManifest = $null
    $cliTeamHomeRoot = $null
    $cliWorkspace = $null
    $cliArgs = @($args)
    for ($i = 0; $i -lt $cliArgs.Count; $i++) {
        $current = $cliArgs[$i]
        if ($current -eq '-UserDshHome' -and $i + 1 -lt $cliArgs.Count) { $cliUser = $cliArgs[$i + 1]; $i++ }
        elseif ($current -eq '-TeamDshHome' -and $i + 1 -lt $cliArgs.Count) { $cliTeam = $cliArgs[$i + 1]; $i++ }
        elseif ($current -eq '-TeamProfile' -and $i + 1 -lt $cliArgs.Count) { $cliProfile = $cliArgs[$i + 1]; $i++ }
        elseif ($current -eq '-InstallId' -and $i + 1 -lt $cliArgs.Count) { $cliInstallId = $cliArgs[$i + 1]; $i++ }
        elseif ($current -eq '-InstallManifestPath' -and $i + 1 -lt $cliArgs.Count) { $cliManifest = $cliArgs[$i + 1]; $i++ }
        elseif ($current -eq '-TeamHomeRoot' -and $i + 1 -lt $cliArgs.Count) { $cliTeamHomeRoot = $cliArgs[$i + 1]; $i++ }
        elseif ($current -eq '-Workspace' -and $i + 1 -lt $cliArgs.Count) { $cliWorkspace = $cliArgs[$i + 1]; $i++ }
    }
    if (-not $cliUser -or -not $cliTeam) {
        [Console]::Error.WriteLine('Sync-DshTeamConfig.ps1 CLI 模式需要 -UserDshHome 与 -TeamDshHome。')
        exit 2
    }
    try {
        $syncResult = Invoke-DshTeamConfigSync -UserDshHome $cliUser -TeamDshHome $cliTeam -TeamProfile $cliProfile `
            -InstallId $cliInstallId -InstallManifestPath $cliManifest -TeamHomeRoot $cliTeamHomeRoot -Workspace $cliWorkspace
        $safeSummary = [ordered]@{
            status   = 'success'
            provider = $syncResult.Provider
            model    = $syncResult.Model
            changed  = @($syncResult.Changed)
            notes    = @($syncResult.Notes)
            syncedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
        # Only the safe summary is emitted: provider/model, changed relative paths,
        # notes and time. No settings body, credential value or environment secret.
        # ConvertTo-SafeJson 避免 Windows PowerShell 5.1 的 OrderedDictionary 序列化陷阱。
        Write-Output (ConvertTo-SafeJson -InputObject $safeSummary -Compress -Depth 6)
        exit 0
    }
    catch {
        [Console]::Error.WriteLine(('同步失败: ' + $_.Exception.Message))
        exit 1
    }
}
