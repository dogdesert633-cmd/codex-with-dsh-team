#Requires -Version 5.1
<#
  Codex x DSH Team Toolkit - single core engine (install / upgrade / uninstall).

  Design rules (fail-closed, zero guessing):
    * Only files explicitly listed in the release manifest are managed.
    * Unknown same-name files block the whole operation; nothing is overwritten.
    * Upgrades may replace a file only while its current bytes are identical to the pristine
      baseline recorded for it; user-modified managed files block everything. No checksum,
      hash or digest is computed, stored or trusted.
    * Missing / corrupt / wrong-identity ownership manifests, unsafe paths, reparse points,
      junctions, symlinks, '..', absolute / UNC / device paths, root paths and out-of-bounds
      targets block the operation with zero writes.
    * Transaction: Plan -> complete Preflight -> exclusive lock -> durable journal + backup
      -> same-directory temp + atomic replace/move -> verify -> manifest atomic commit.
      Any failure rolls back in reverse order.
    * Uninstall moves managed files into a toolkit-owned quarantine first and only then
      commits; user-modified files are kept, unknown / user-added files are never deleted.
    * Never elevates, never uses the network, never touches PATH / registry / global
      PowerShell / Git configuration / an existing AGENTS.md / sources.
    * Plan / journal / log record paths and status, never file bodies, and every human-readable
      or persisted message is redacted. Transaction backup/quarantine and the pristine baselines
      are deliberate byte copies of managed files, kept for rollback, restore and ownership
      comparison respectively - they are not message channels.

  Usage:
    pwsh -File install/Invoke-Toolkit.ps1 -Action Install -Target <project> [-PlanOnly]
    pwsh -File install/Invoke-Toolkit.ps1 -Action Uninstall -Target <project> -Yes

  Tests dot-source this file with -Library to reuse the same functions in-process:
    . install/Invoke-Toolkit.ps1 -Library
#>
[CmdletBinding()]
param(
  [ValidateSet('Install', 'Uninstall')]
  [string]$Action = 'Install',

  [string]$Target = '',

  [string]$PackageRoot = '',

  [string]$ReleaseManifest = '',

  [switch]$PlanOnly,

  [switch]$Yes,

  [switch]$NonInteractive,

  [switch]$Quiet,

  [string]$TeamDshHome = '',

  [string]$RuntimeRootBase = '',

  [switch]$InitializeRuntime,

  [switch]$Library,

  [string]$TestFault = '',

  [switch]$TestMode,

  [switch]$TestKeepTransaction,

  [ValidateSet('', 'yes', 'no')]
  [string]$TestConfirmation = '',

  [string]$UninstallerSelf = '',

  [string]$OutputFile = '',

  [switch]$ClearStaleLock
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:TKToolkitName = 'codex-dsh-team-toolkit'
$script:TKReleaseSchema = 'codex-dsh-team-toolkit/release-manifest/v1'
$script:TKOwnershipSchema = 'codex-dsh-team-toolkit/ownership-manifest/v1'
$script:TKStateDirectory = '.codex-dsh-team-toolkit'
# Pristine baselines: the exact bytes this toolkit installed, used as the only ownership
# reference. Comparison is always a direct streaming byte comparison.
$script:TKPristineDirectoryName = 'pristine'
$script:TKEngineRelativePath = '.codex-dsh-team-toolkit/engine/Invoke-Toolkit.ps1'
$script:TKUninstallerName = 'CodexDshTeamToolkit.Uninstall.exe'
$script:TKLockName = '.install.lock'
$script:TKLogName = 'install.log'
$script:TKManifestName = 'manifest.json'
$script:TKTxnDirectoryName = 'txn'
$script:TKQuarantineDirectoryName = 'quarantine'
$script:TKStateGitIgnoreName = '.gitignore'
$script:TKRuntimeBaseFolder = 'CodexDshTeam'
$script:TKRuntimeFolder = 'runtimes'

# Team Home ownership marker - ONE contract shared with the Node runtime
# (payload/.agents/skills/mcp-to-dsh/src/team-home.mjs). Same file name, same schema, same
# required fields, same purpose value. Never invent a second marker format.
$script:TKTeamHomeMarkerName = '.codex-dsh-team-home.json'
$script:TKTeamHomeMarkerSchema = 'codex-dsh-team-home/v1'
$script:TKTeamHomeMarkerPurpose = 'dsh-team-runtime-home'
$script:TKTeamHomeMarkerFields = @('schema', 'toolkitId', 'installId', 'createdAt', 'purpose')
# Stable install identity shared with the runtime: <base>/install.json
$script:TKInstallIdentityName = 'install.json'
$script:TKInstallIdentitySchema = 'codex-dsh-team-install/v1'
$script:TKInstallIdentityPurpose = 'codex-dsh-team-install-identity'
# Superseded marker names/schemas: never ownership proof, never written, never migrated.
$script:TKLegacyRuntimeMarkerName = '.codex-dsh-team-runtime.json'
$script:TKLegacyRuntimeMarkerSchema = 'codex-dsh-team-toolkit/runtime-marker/v1'

$script:TKExitOk = 0
$script:TKExitUsage = 2
$script:TKExitBlocked = 3
$script:TKExitConflict = 4
$script:TKExitManifest = 5
$script:TKExitTransaction = 6
$script:TKExitRollback = 7
$script:TKExitCancelled = 8

# Runtime state (reset by Invoke-ToolkitCommand).
$script:TKOutput = New-Object System.Collections.ArrayList
$script:TKCollectOutput = $false
$script:TKQuietOutput = $false
$script:TKNonInteractive = [bool]$NonInteractive
$script:TKTestMode = [bool]$TestMode
$script:TKTestFaultPoint = [string]$TestFault
$script:TKTestKeepTransaction = [bool]$TestKeepTransaction
$script:TKTestConfirmation = [string]$TestConfirmation
$script:TKUninstallerSelfPath = [string]$UninstallerSelf
$script:TKEngineSelfPath = ''
$script:TKCreatedStateDirectory = $false
$script:TKLogEnabled = $false
$script:TKLogPath = ''
$script:TKTransactionDirectory = ''

# ---------------------------------------------------------------------------
# Confined redaction helpers (used before anything is printed or persisted)
# ---------------------------------------------------------------------------

function Get-ToolkitSafeText {
  <#
    Redacts secret-shaped values from any text that may reach a console, a journal,
    a manifest or a log. Values are replaced, never echoed.
  #>
  param([string]$Text)

  if ([string]::IsNullOrEmpty($Text)) { return [string]$Text }
  $s = [string]$Text
  $s = [regex]::Replace($s, '-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----', '<redacted-private-key>')
  $s = [regex]::Replace($s, '(?i)(authorization\s*[:=]\s*)(bearer|basic)\s+[A-Za-z0-9\-._~+/=]+', '$1$2 <redacted>')
  $s = [regex]::Replace($s, '(?i)\b(bearer|basic)\s+[A-Za-z0-9\-._~+/=]{8,}', '$1 <redacted>')
  $s = [regex]::Replace($s, '\beyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}', '<redacted-jwt>')
  # quoted assignment form: key = "value" / key: "value" (only for value-looking strings)
  $s = [regex]::Replace($s, '(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|apikey|client[_-]?secret|access[_-]?key|private[_-]?key|cookie|authorization)\s*[:=]\s*"([^"]{12,})"', '$1="<redacted>"')
  # unquoted assignment form: key=value (no whitespace after the separator, so prose survives)
  $s = [regex]::Replace($s, '(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|apikey|client[_-]?secret|access[_-]?key|private[_-]?key|cookie)\s*[:=][^\s"'']+', '$1=<redacted>')
  # prose form: "secret: <value>" only when the value is one long unbroken token (never a path)
  $s = [regex]::Replace($s, '(?i)\b(password|passwd|pwd|secret|token|api[_-]?key|apikey|client[_-]?secret|access[_-]?key|private[_-]?key|cookie)\s*:\s+([A-Za-z0-9+_\-]{16,}=*)\b', '$1: <redacted>')
  $s = [regex]::Replace($s, '(?i)("(password|passwd|secret|token|api[_-]?key|cookie)"\s*:\s*)"[^"]*"', '$1"<redacted>"')
  $s = [regex]::Replace($s, '\bsk-[A-Za-z0-9]{16,}', '<redacted-key>')
  $s = [regex]::Replace($s, '\bgh[pousr]_[A-Za-z0-9]{20,}', '<redacted-key>')
  $s = [regex]::Replace($s, '\bxox[baprs]-[A-Za-z0-9\-]{10,}', '<redacted-key>')
  $s = [regex]::Replace($s, '\bAKIA[0-9A-Z]{12,}', '<redacted-key>')
  return $s
}

function Test-ToolkitSensitiveSegment {
  <#
    Path-level deny-by-default: a single path segment that looks like a credential
    store, a secret file or an embedded secret value.
  #>
  param([string]$Segment)

  if ([string]::IsNullOrEmpty($Segment)) { return $false }
  $s = [string]$Segment

  if ($s -match '(?i)^\.env(\..*)?$') { return $true }
  if ($s -match '(?i)^\.?credentials?(\..*)?$') { return $true }
  if ($s -match '(?i)^\.?(secrets?|tokens?|passwords?|cookies?)$') { return $true }
  if ($s -match '(?i)^(settings\.yaml|settings\.yml|settings\.local\.json)$') { return $true }
  if ($s -match '(?i)^(id_rsa|id_dsa|id_ecdsa|id_ed25519)(\..*)?$') { return $true }
  if ($s -match '(?i)\.(key|pem|pfx|p12|ppk|jks|keystore|kdbx)$') { return $true }
  if ($s -match '(?i)(^|[._-])(token|tokens|secret|secrets|password|passwd|credential|credentials|cookie|cookies|session|sessions|apikey|api[_-]key|private[_-]key|authorization)([._-]|$)') { return $true }
  if ($s.Contains('=') -and $s.Length -ge 20) { return $true }
  if ($s.Length -ge 32 -and $s -match '^[A-Za-z0-9+/_=-]+$' -and $s -cmatch '[a-z]' -and $s -cmatch '[A-Z]' -and $s -match '[0-9]') { return $true }
  return $false
}

function Get-ToolkitSafePath {
  <#
    Display-only path rendering. Sensitive segments are replaced with '<redacted>' and
    the original separator style is preserved so a plan stays readable.
  #>
  param([string]$Path)

  if ([string]::IsNullOrEmpty($Path)) { return [string]$Path }
  $text = Get-ToolkitSafeText -Text ([string]$Path)
  $result = New-Object System.Text.StringBuilder
  $segment = New-Object System.Text.StringBuilder
  for ($index = 0; $index -lt $text.Length; $index++) {
    $character = $text[$index]
    if ($character -eq '\' -or $character -eq '/') {
      [void]$result.Append((Format-ToolkitPathSegment -Segment $segment.ToString()))
      [void]$result.Append($character)
      [void]$segment.Clear()
    }
    else {
      [void]$segment.Append($character)
    }
  }
  [void]$result.Append((Format-ToolkitPathSegment -Segment $segment.ToString()))
  return $result.ToString()
}

function Format-ToolkitPathSegment {
  param([string]$Segment)

  if ([string]::IsNullOrEmpty($Segment)) { return [string]$Segment }
  if (Test-ToolkitSensitiveSegment -Segment $Segment) { return '<redacted>' }
  return $Segment
}

# ---------------------------------------------------------------------------
# Failure helpers
# ---------------------------------------------------------------------------

function New-ToolkitFailure {
  param(
    [int]$ExitCode,
    [string]$Message,
    [string]$Detail = ''
  )
  $ex = New-Object System.Exception((Get-ToolkitSafeText -Text $Message))
  $ex.Data['ToolkitExitCode'] = $ExitCode
  if (-not [string]::IsNullOrEmpty($Detail)) {
    $ex.Data['ToolkitDetail'] = (Get-ToolkitSafeText -Text $Detail)
  }
  return $ex
}

function Throw-ToolkitFailure {
  param(
    [int]$ExitCode,
    [string]$Message,
    [string]$Detail = ''
  )
  throw (New-ToolkitFailure -ExitCode $ExitCode -Message $Message -Detail $Detail)
}

function Get-ToolkitExitCodeFromException {
  param([System.Exception]$Exception)

  $ex = $Exception
  $guard = 0
  while ($null -ne $ex -and $guard -lt 10) {
    if ($ex.Data -and $ex.Data.Contains('ToolkitExitCode')) {
      return [int]$ex.Data['ToolkitExitCode']
    }
    $ex = $ex.InnerException
    $guard++
  }
  return $script:TKExitTransaction
}

function Get-ToolkitExceptionMessage {
  param([System.Exception]$Exception)

  $ex = $Exception
  while ($null -ne $ex.InnerException -and -not ($ex.Data -and $ex.Data.Contains('ToolkitExitCode'))) {
    $ex = $ex.InnerException
  }
  $message = [string]$ex.Message
  if ($ex.Data -and $ex.Data.Contains('ToolkitDetail')) {
    $message = $message + ' [' + [string]$ex.Data['ToolkitDetail'] + ']'
  }
  return (Get-ToolkitSafeText -Text $message)
}

# ---------------------------------------------------------------------------
# Output + log
# ---------------------------------------------------------------------------

function Write-ToolkitLine {
  param(
    [string]$Text,
    [ValidateSet('Info', 'Warn', 'Error', 'Detail')]
    [string]$Level = 'Info'
  )

  $line = Get-ToolkitSafeText -Text ([string]$Text)
  if ($script:TKCollectOutput) { [void]$script:TKOutput.Add($line) }
  if (-not $script:TKQuietOutput) {
    switch ($Level) {
      'Error' { Write-Host $line -ForegroundColor Red }
      'Warn' { Write-Host $line -ForegroundColor Yellow }
      'Detail' { Write-Host $line -ForegroundColor DarkGray }
      default { Write-Host $line }
    }
  }
  if ($script:TKLogEnabled -and $script:TKLogPath) {
    try {
      $stamp = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      Append-ToolkitTextDurable -Path $script:TKLogPath -Content ($stamp + ' [' + $Level + '] ' + $line)
    }
    catch {
      # A log failure must never change the outcome of a safety decision.
    }
  }
}

function Assert-ToolkitTestGate {
  <#
    Test-only features (fault injection, keeping transaction evidence) are gated behind an
    explicit environment variable so a release build cannot be steered by a normal user or a
    stray command line. Both the switch and the environment gate are required.
  #>
  param([string]$Feature)

  if ($env:CODEX_DSH_TOOLKIT_TEST -ne '1') {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage `
      -Message ('Test-only feature "' + $Feature + '" is disabled. Set CODEX_DSH_TOOLKIT_TEST=1 and pass -TestMode to run it (never do this for a real install).')
  }
}

function Invoke-ToolkitFaultInjection {
  <#
    Test-only fault injection points. Requires -TestMode plus the CODEX_DSH_TOOLKIT_TEST=1
    environment gate; never reachable from a normal release invocation.
  #>
  param([string]$Point)

  if ([string]::IsNullOrEmpty($script:TKTestFaultPoint)) { return }
  if (-not $script:TKTestMode) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'Fault injection requires -TestMode (test-only switch).'
  }
  Assert-ToolkitTestGate -Feature 'fault injection'
  if ($script:TKTestFaultPoint -eq $Point) {
    Write-ToolkitLine ("[test] injected fault at '" + $Point + "'; rolling back.") 'Warn'
    Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message ("Injected test fault at '" + $Point + "'.")
  }
}

# ---------------------------------------------------------------------------
# Path safety
# ---------------------------------------------------------------------------

function ConvertTo-ToolkitRelativePath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'Managed path is empty.'
  }
  if (([string]$Path).IndexOf([char]0) -ge 0) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'Managed path contains a NUL character.'
  }
  return ([string]$Path).Replace('\', '/')
}

function Assert-ToolkitRelativePath {
  <#
    Normalizes and validates a manifest-relative path. Rejects traversal, absolute,
    drive-qualified, UNC, device, root, over-long, invalid-character and reserved
    device names.
  #>
  param([string]$Path)

  $p = ConvertTo-ToolkitRelativePath -Path $Path

  Assert-ToolkitPathRule -Ok (-not $p.StartsWith('/')) -Reason 'absolute path or UNC prefix' -Path $p
  Assert-ToolkitPathRule -Ok (-not ($p -match '^[A-Za-z]:')) -Reason 'drive-qualified path' -Path $p
  Assert-ToolkitPathRule -Ok (-not ($p -match '^\\\\')) -Reason 'UNC or device path' -Path $p
  Assert-ToolkitPathRule -Ok (-not ($p -match '^//')) -Reason 'UNC path' -Path $p
  Assert-ToolkitPathRule -Ok (-not ($p -match '\\')) -Reason 'unnormalized separator' -Path $p
  Assert-ToolkitPathRule -Ok (-not ($p -match '//')) -Reason 'empty path segment' -Path $p
  Assert-ToolkitPathRule -Ok ($p.Length -le 240) -Reason 'path too long' -Path $p
  Assert-ToolkitPathRule -Ok ($p -notmatch '[\x00-\x1f<>:"|?*]') -Reason 'invalid character' -Path $p

  $segments = @($p.Split('/'))
  foreach ($segment in $segments) {
    Assert-ToolkitPathRule -Ok ($segment -ne '') -Reason 'empty path segment' -Path $p
    Assert-ToolkitPathRule -Ok ($segment -ne '.' -and $segment -ne '..') -Reason 'relative traversal' -Path $p
    Assert-ToolkitPathRule -Ok ($segment.Length -le 100) -Reason 'path segment too long' -Path $p
    Assert-ToolkitPathRule -Ok (-not $segment.EndsWith('.')) -Reason 'trailing dot in segment' -Path $p
    Assert-ToolkitPathRule -Ok (-not $segment.EndsWith(' ')) -Reason 'trailing space in segment' -Path $p
    $stem = $segment.Split('.')[0]
    Assert-ToolkitPathRule -Ok (-not ($stem -match '(?i)^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$')) -Reason 'reserved device name' -Path $p
  }
  return $p
}

function Assert-ToolkitPathRule {
  param(
    [bool]$Ok,
    [string]$Reason,
    [string]$Path
  )
  if (-not $Ok) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message ("Unsafe managed path rejected: " + $Reason + '.') `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
}

function Assert-ToolkitPathNotDenied {
  <#
    Deny-by-default path policy: credential stores, secret files, runtime/VCS trees and
    release-forbidden content are refused even if a manifest claims them.
  #>
  param([string]$RelativePath)

  $p = (ConvertTo-ToolkitRelativePath -Path $RelativePath).ToLowerInvariant()
  $segments = @($p.Split('/'))
  foreach ($segment in $segments) {
    if (Test-ToolkitSensitiveSegment -Segment $segment) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message 'Path is denied by the toolkit deny-by-default credential policy.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
    }
  }
  if ($p -match '(^|/)(\.git|\.dsh|node_modules|artifacts|\.ssh|\.aws|\.gnupg|\.azure|\.kube)(/|$)') {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message 'Path is inside a VCS, runtime or credential directory and is denied.' `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  if ($p -match '(^|/)[^/]*(server[-_.]?record|agent-registry)[^/]*(\.|$)') {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message 'Path looks like a runtime server record and is denied.' `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  if ($p -match '(^|/)[^/]*\.(log|jsonl|session|sessions)$') {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message 'Path looks like a log or session artefact and is denied.' `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  if ($p -match '(^|/)[^/]*(chrome|edge|firefox|brave)[-_ ]?(profile|user[-_ ]?data)[^/]*(/|$)') {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message 'Path looks like a browser profile and is denied.' `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
}

function ConvertTo-ToolkitNativePath {
  param([string]$RelativePath)
  return ([string]$RelativePath).Replace('/', '\')
}

function Get-ToolkitFullPath {
  param(
    [string]$Root,
    [string]$RelativePath
  )
  $native = ConvertTo-ToolkitNativePath -RelativePath $RelativePath
  return [System.IO.Path]::GetFullPath((Join-Path $Root $native))
}

function Assert-ToolkitPathInsideRoot {
  param(
    [string]$Root,
    [string]$FullPath,
    [string]$RelativePath
  )
  $rootPrefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
  $candidate = [System.IO.Path]::GetFullPath($FullPath)
  if (-not $candidate.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message 'Resolved path escapes the allowed root.' `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  return $candidate
}

function Get-ToolkitItemOrNull {
  param([string]$Path)
  return (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
}

function Test-ToolkitReparseItem {
  param($Item)
  if ($null -eq $Item) { return $false }
  if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
  $linkType = $null
  if ($Item.PSObject.Properties['LinkType']) { $linkType = $Item.LinkType }
  if (-not [string]::IsNullOrEmpty([string]$linkType)) { return $true }
  return $false
}

function Assert-ToolkitNoReparseInPath {
  <#
    Walks every existing path segment from the root down to the leaf and refuses any
    symlink, junction or other reparse point.
  #>
  param(
    [string]$Root,
    [string]$RelativePath,
    [switch]$RequireRootExists
  )

  $rootItem = Get-ToolkitItemOrNull -Path $Root
  if ($null -eq $rootItem) {
    if ($RequireRootExists) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'Target root does not exist.' -Detail ('path=' + (Get-ToolkitSafePath -Path $Root))
    }
    return
  }
  if (Test-ToolkitReparseItem -Item $rootItem) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'Target root is a symlink / junction / reparse point.' -Detail ('path=' + (Get-ToolkitSafePath -Path $Root))
  }

  $current = [System.IO.Path]::GetFullPath($Root)
  $segments = @((ConvertTo-ToolkitNativePath -RelativePath $RelativePath).Split('\'))
  foreach ($segment in $segments) {
    if ([string]::IsNullOrEmpty($segment)) { continue }
    $current = Join-Path $current $segment
    $item = Get-ToolkitItemOrNull -Path $current
    if ($null -eq $item) { continue }
    if (Test-ToolkitReparseItem -Item $item) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message 'Path traverses a symlink / junction / reparse point.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
    }
  }
}

function Test-ToolkitAbsoluteLocalPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  if ($Path -match '^[A-Za-z]:[\\/]') { return $true }
  if ($Path -match '^\\\\[^\\?]') { return $true }
  return $false
}

# ---------------------------------------------------------------------------
# Direct byte comparison + durable file IO (no checksums anywhere)
#
# Ownership, transaction and recovery safety are proved by comparing the bytes on disk with the
# pristine copy this toolkit installed. No digest is ever computed, stored, compared or trusted.
# ---------------------------------------------------------------------------

function Test-ToolkitPathIsRegularFile {
  param([string]$Path)

  if ([string]::IsNullOrEmpty($Path)) { return $false }
  $item = Get-ToolkitItemOrNull -Path $Path
  if ($null -eq $item -or -not ($item -is [System.IO.FileInfo])) { return $false }
  if (Test-ToolkitReparseItem -Item $item) { return $false }
  return $true
}

function Test-ToolkitFileContentEqual {
  <#
    Streaming byte comparison of two files: false when either is missing, not a regular file,
    a reparse point, or when length or any byte differs. Nothing is hashed and nothing is cached:
    the comparison is always against the bytes that are on disk right now.
  #>
  param(
    [string]$PathA,
    [string]$PathB
  )

  if ([string]::IsNullOrEmpty($PathA) -or [string]::IsNullOrEmpty($PathB)) { return $false }
  if (-not (Test-ToolkitPathIsRegularFile -Path $PathA)) { return $false }
  if (-not (Test-ToolkitPathIsRegularFile -Path $PathB)) { return $false }

  $lengthA = (Get-Item -LiteralPath $PathA).Length
  $lengthB = (Get-Item -LiteralPath $PathB).Length
  if ($lengthA -ne $lengthB) { return $false }
  if ($lengthA -eq 0) { return $true }

  $streamA = $null
  $streamB = $null
  try {
    $streamA = New-Object System.IO.FileStream($PathA, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $streamB = New-Object System.IO.FileStream($PathB, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $bufferA = New-Object byte[] 65536
    $bufferB = New-Object byte[] 65536
    while ($true) {
      $readA = $streamA.Read($bufferA, 0, $bufferA.Length)
      $readB = $streamB.Read($bufferB, 0, $bufferB.Length)
      if ($readA -ne $readB) { return $false }
      if ($readA -le 0) { return $true }
      for ($index = 0; $index -lt $readA; $index++) {
        if ($bufferA[$index] -ne $bufferB[$index]) { return $false }
      }
    }
  }
  catch {
    return $false
  }
  finally {
    if ($null -ne $streamA) { $streamA.Dispose() }
    if ($null -ne $streamB) { $streamB.Dispose() }
  }
}

function Get-ToolkitFileBytes {
  <#
    Raw bytes of a small file (the ownership ledger only). Returns $null when the file is
    missing or not a regular file, so callers can fail closed.
  #>
  param([string]$Path)

  if (-not (Test-ToolkitPathIsRegularFile -Path $Path)) { return $null }
  try {
    return [System.IO.File]::ReadAllBytes($Path)
  }
  catch {
    return $null
  }
}

function Test-ToolkitFileContentEqualToBytes {
  <#
    True when the file on disk is byte-identical to the captured byte array. Used for the
    in-lock "did the ledger change?" re-check and for small in-memory references.
  #>
  param(
    [string]$Path,
    $Bytes
  )

  if ($null -eq $Bytes) { return $false }
  if (-not (Test-ToolkitPathIsRegularFile -Path $Path)) { return $false }
  $current = Get-ToolkitFileBytes -Path $Path
  if ($null -eq $current) { return $false }
  if ($current.Length -ne $Bytes.Length) { return $false }
  for ($index = 0; $index -lt $current.Length; $index++) {
    if ($current[$index] -ne $Bytes[$index]) { return $false }
  }
  return $true
}

function Get-ToolkitPristineRelativePath {
  <#
    The pristine copy of a managed file lives at pristine/<same relative path> inside the state
    directory, so the mapping is self-locating and needs no digest or absolute path.
  #>
  param([string]$RelativePath)

  $normalized = ([string]$RelativePath).Replace('\', '/').Trim('/')
  if ([string]::IsNullOrEmpty($normalized)) { return '' }
  return ($script:TKPristineDirectoryName + '/' + $normalized)
}

function Get-ToolkitPristineFullPath {
  param(
    [string]$StateDirectory,
    [string]$RelativePath
  )

  $relative = Get-ToolkitPristineRelativePath -RelativePath $RelativePath
  if ([string]::IsNullOrEmpty($relative)) { return '' }
  return (Get-ToolkitFullPath -Root $StateDirectory -RelativePath $relative)
}

function Test-ToolkitStatePristineRootSafe {
  <#
    NEW-1: every pristine operation (write, read for proof, delete, empty-directory sweep) goes
    through here first. A junction at state/pristine would otherwise let a pristine write, delete
    or empty-directory removal land outside the state directory.
  #>
  param([string]$StateDirectory)

  Assert-ToolkitStateRootSafe -StateDirectory $StateDirectory -RelativeRoot $script:TKPristineDirectoryName
}

function Write-ToolkitPristineFile {
  <#
    Records the pristine baseline for a managed file. The copy is durable and verified by direct
    byte comparison, so a torn write can never become "trusted evidence".
  #>
  param(
    [string]$StateDirectory,
    [string]$RelativePath,
    [string]$SourcePath
  )

  Test-ToolkitStatePristineRootSafe -StateDirectory $StateDirectory
  $destination = Get-ToolkitPristineFullPath -StateDirectory $StateDirectory -RelativePath $RelativePath
  if ([string]::IsNullOrEmpty($destination)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'A pristine baseline path could not be derived; refusing to continue.' -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  $directory = Split-Path -Parent $destination
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  # Stage next to the destination and move atomically: a pristine baseline is rewritten on every
  # install/upgrade, so an existing copy must be replaced, never refused.
  $temp = Join-Path $directory ('.pristine-' + [Guid]::NewGuid().ToString('n'))
  Copy-ToolkitFileDurable -Source $SourcePath -Destination $temp
  if (-not (Test-ToolkitFileContentEqual -PathA $SourcePath -PathB $temp)) {
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'The pristine baseline copy does not match the file it records; aborting.' -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  Move-ToolkitFileAtomic -Source $temp -Destination $destination
  if (-not (Test-ToolkitFileContentEqual -PathA $SourcePath -PathB $destination)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'The pristine baseline stored on disk does not match the installed file; aborting.' -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  return $destination
}

function Test-ToolkitPristineMatches {
  <#
    Ownership proof: the target must be byte-identical to the pristine baseline this toolkit
    installed. A missing or unreadable baseline is never treated as "unchanged".
  #>
  param(
    [string]$StateDirectory,
    [string]$RelativePath,
    [string]$TargetPath
  )

  Test-ToolkitStatePristineRootSafe -StateDirectory $StateDirectory
  $pristine = Get-ToolkitPristineFullPath -StateDirectory $StateDirectory -RelativePath $RelativePath
  if ([string]::IsNullOrEmpty($pristine)) { return $false }
  return (Test-ToolkitFileContentEqual -PathA $TargetPath -PathB $pristine)
}

function Remove-ToolkitPristineFile {
  param(
    [string]$StateDirectory,
    [string]$RelativePath
  )

  Test-ToolkitStatePristineRootSafe -StateDirectory $StateDirectory
  $pristine = Get-ToolkitPristineFullPath -StateDirectory $StateDirectory -RelativePath $RelativePath
  if ([string]::IsNullOrEmpty($pristine)) { return }
  if (Test-Path -LiteralPath $pristine -PathType Leaf) {
    Remove-Item -LiteralPath $pristine -Force -ErrorAction SilentlyContinue
  }
}

function Remove-ToolkitEmptyPristineDirectories {
  <#
    Removes now-empty directories under pristine/ so an uninstall leaves no skeleton behind.
  #>
  param([string]$StateDirectory)

  Test-ToolkitStatePristineRootSafe -StateDirectory $StateDirectory
  $root = Join-Path $StateDirectory $script:TKPristineDirectoryName
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
  $directories = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
  foreach ($directory in $directories) {
    try {
      $children = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue)
      if ($children.Count -eq 0) { Remove-Item -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue }
    }
    catch { }
  }
  try {
    $remaining = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue }
  }
  catch { }
}

function Write-ToolkitTextFileDurable {
  param(
    [string]$Path,
    [string]$Content
  )

  $encoding = New-Object System.Text.UTF8Encoding($false)
  $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $bytes = $encoding.GetBytes([string]$Content)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  }
  finally {
    $stream.Dispose()
  }
}

function Append-ToolkitTextDurable {
  param(
    [string]$Path,
    [string]$Content
  )

  $encoding = New-Object System.Text.UTF8Encoding($false)
  $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $bytes = $encoding.GetBytes([string]$Content + [Environment]::NewLine)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
  }
  finally {
    $stream.Dispose()
  }
}

function Copy-ToolkitFileDurable {
  param(
    [string]$Source,
    [string]$Destination
  )

  $sourceStream = New-Object System.IO.FileStream($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $output = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
      $sourceStream.CopyTo($output)
      $output.Flush($true)
    }
    finally {
      $output.Dispose()
    }
  }
  finally {
    $sourceStream.Dispose()
  }
}

function Move-ToolkitFileAtomic {
  <#
    Same-directory atomic replace when the destination exists, atomic move otherwise.
    A throwaway backup path is used because .NET Framework File.Replace does not accept
    a null backup file name (the .NET Core 3.0+ overload is not available everywhere).
  #>
  param(
    [string]$Source,
    [string]$Destination
  )

  if ([System.IO.File]::Exists($Destination)) {
    $displaced = $Destination + '.toolkit-displaced-' + [Guid]::NewGuid().ToString('n')
    [System.IO.File]::Replace($Source, $Destination, $displaced)
    if ([System.IO.File]::Exists($displaced)) {
      Remove-Item -LiteralPath $displaced -Force -ErrorAction SilentlyContinue
    }
  }
  else {
    [System.IO.File]::Move($Source, $Destination)
  }
}

# ---------------------------------------------------------------------------
# JSON helpers (no ordered dictionaries: Windows PowerShell 5.1 trap avoided)
# ---------------------------------------------------------------------------

function New-ToolkitJsonObject {
  param([hashtable]$Properties)
  return (New-Object -TypeName psobject -Property $Properties)
}

function ConvertTo-ToolkitJson {
  param($Object)
  return (ConvertTo-Json -InputObject $Object -Depth 8)
}

function Get-ToolkitMember {
  param(
    $Object,
    [string]$Name,
    $Default = $null
  )

  if ($null -eq $Object) { return $Default }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) {
      $value = $Object[$Name]
      if ($null -eq $value) { return $Default }
      return $value
    }
    return $Default
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) { return $Default }
  if ($null -eq $property.Value) { return $Default }
  return $property.Value
}

function ConvertFrom-ToolkitJsonStringLiteral {
  <#
    Decodes the JSON string literal (including surrounding quotes) for duplicate-key
    comparison, so `"a"` and `"\u0061"` are recognised as the same key.
  #>
  param([string]$Literal)

  if ([string]::IsNullOrEmpty($Literal)) { return '' }
  $inner = $Literal
  if ($inner.StartsWith('"')) { $inner = $inner.Substring(1) }
  if ($inner.EndsWith('"') -and $inner.Length -ge 1) { $inner = $inner.Substring(0, $inner.Length - 1) }
  $builder = New-Object System.Text.StringBuilder
  $index = 0
  while ($index -lt $inner.Length) {
    $character = $inner[$index]
    if ($character -ne '\') { [void]$builder.Append($character); $index++; continue }
    if ($index + 1 -ge $inner.Length) { [void]$builder.Append('\'); break }
    $escape = $inner[$index + 1]
    switch ($escape) {
      'n' { [void]$builder.Append("`n"); $index += 2 }
      't' { [void]$builder.Append("`t"); $index += 2 }
      'r' { [void]$builder.Append("`r"); $index += 2 }
      'b' { [void]$builder.Append([char]8); $index += 2 }
      'f' { [void]$builder.Append([char]12); $index += 2 }
      'u' {
        if ($index + 5 -lt $inner.Length) {
          $hex = $inner.Substring($index + 2, 4)
          $code = 0
          if ([int]::TryParse($hex, [System.Globalization.NumberStyles]::HexNumber, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$code)) {
            [void]$builder.Append([char]$code)
            $index += 6
          }
          else { [void]$builder.Append($escape); $index += 2 }
        }
        else { [void]$builder.Append($escape); $index += 2 }
      }
      default { [void]$builder.Append($escape); $index += 2 }
    }
  }
  return $builder.ToString()
}

function Assert-ToolkitJsonNoDuplicateKeys {
  <#
    Security-critical JSON (release manifest, ownership manifest, package layout, Team Home
    marker, install identity, transaction journal) must not contain duplicate keys: JSON
    parsers silently keep the last one, so a duplicate is how a "signed" document can say two
    different things. This scanner walks the raw text and refuses duplicates (case-insensitive,
    escape-aware) per object level.

    PowerShell 5.1 has no duplicate-aware JSON parser, so the check is done on the text.
  #>
  param(
    [string]$Text,
    [string]$What = 'JSON document',
    [int]$ExitCode = $script:TKExitBlocked
  )

  $stack = New-Object System.Collections.ArrayList
  $index = 0
  $length = ([string]$Text).Length
  while ($index -lt $length) {
    $character = $Text[$index]
    if ($character -eq '{') {
      [void]$stack.Add(@{ Type = 'object'; Keys = @{}; ExpectKey = $true })
      $index++
      continue
    }
    if ($character -eq '[') {
      [void]$stack.Add(@{ Type = 'array'; Keys = $null; ExpectKey = $false })
      $index++
      continue
    }
    if ($character -eq '}' -or $character -eq ']') {
      if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
      $index++
      continue
    }
    if ($character -eq ',') {
      if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Type -eq 'object') {
        $stack[$stack.Count - 1].ExpectKey = $true
      }
      $index++
      continue
    }
    if ($character -eq '"') {
      $start = $index
      $index++
      while ($index -lt $length) {
        $inner = $Text[$index]
        if ($inner -eq '\') { $index += 2; continue }
        if ($inner -eq '"') { break }
        $index++
      }
      $literal = $Text.Substring($start, [Math]::Min($index - $start + 1, $length - $start))
      $index++
      $probe = $index
      while ($probe -lt $length -and [char]::IsWhiteSpace($Text[$probe])) { $probe++ }
      if ($stack.Count -gt 0 -and $stack[$stack.Count - 1].Type -eq 'object' -and $stack[$stack.Count - 1].ExpectKey -and $probe -lt $length -and $Text[$probe] -eq ':') {
        $name = ConvertFrom-ToolkitJsonStringLiteral -Literal $literal
        $context = $stack[$stack.Count - 1]
        $key = $name.ToLowerInvariant()
        if ($context.Keys.ContainsKey($key)) {
          Throw-ToolkitFailure -ExitCode $ExitCode `
            -Message ($What + ' contains a duplicate key "' + (Get-ToolkitSafeText -Text $name) + '"; the document is ambiguous and is refused.') `
            -Detail ('key=' + (Get-ToolkitSafeText -Text $name))
        }
        $context.Keys[$key] = $true
        $context.ExpectKey = $false
      }
      continue
    }
    $index++
  }
}

function Assert-ToolkitJsonArray {
  <#
    A missing or non-array property in security-critical JSON is a hard failure: it is never
    coerced into an empty list.
  #>
  param(
    $Object,
    [string]$Name,
    [string]$What = 'JSON document',
    [int]$ExitCode = $script:TKExitBlocked,
    [switch]$AllowMissing
  )

  if ($null -eq $Object) {
    Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' is not an object.')
  }
  if ($Object -is [System.Collections.IDictionary]) {
    if (-not $Object.Contains($Name)) {
      if ($AllowMissing) { return @() }
      Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' is missing the required array "' + $Name + '".')
    }
    $value = $Object[$Name]
  }
  else {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
      if ($AllowMissing) { return @() }
      Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' is missing the required array "' + $Name + '".')
    }
    $value = $property.Value
  }
  if ($null -eq $value) {
    if ($AllowMissing) { return @() }
    Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' has a null "' + $Name + '" where an array is required.')
  }
  if ($value -is [string] -or $value -is [System.Collections.IDictionary]) {
    Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' has a "' + $Name + '" that is not an array.')
  }
  if ($value -is [System.Collections.IEnumerable] -and -not ($value -is [string])) {
    return @($value)
  }
  Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' has a "' + $Name + '" that is not an array.')
}

function Read-ToolkitJsonFile {
  param(
    [string]$Path,
    [int]$ExitCode = $script:TKExitManifest,
    [string]$What = 'JSON file',
    [switch]$SkipDuplicateKeyCheck
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' is missing; refusing to guess.') -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
  $raw = $null
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
  }
  catch {
    Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' could not be read.') -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
  if ([string]::IsNullOrWhiteSpace($raw)) {
    Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' is empty; refusing to guess.') -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
  if (-not $SkipDuplicateKeyCheck) {
    Assert-ToolkitJsonNoDuplicateKeys -Text $raw -What $What -ExitCode $ExitCode
  }
  try {
    return (ConvertFrom-Json -InputObject $raw)
  }
  catch {
    Throw-ToolkitFailure -ExitCode $ExitCode -Message ($What + ' is not valid JSON; refusing to guess.') -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
}

function Write-ToolkitJsonAtomic {
  param(
    $Object,
    [string]$Destination
  )

  $directory = Split-Path -Parent $Destination
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $temp = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Destination) + '.tmp-' + [Guid]::NewGuid().ToString('n'))
  Write-ToolkitTextFileDurable -Path $temp -Content ((ConvertTo-ToolkitJson -Object $Object) + [Environment]::NewLine)
  try {
    Move-ToolkitFileAtomic -Source $temp -Destination $Destination
  }
  catch {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    throw
  }
}

# ---------------------------------------------------------------------------
# Release manifest (how to install) and ownership manifest (what we installed)
# ---------------------------------------------------------------------------

function Read-ToolkitReleaseManifest {
  param([string]$Path)

  $manifest = Read-ToolkitJsonFile -Path $Path -ExitCode $script:TKExitManifest -What 'Release manifest'

  $schema = [string](Get-ToolkitMember -Object $manifest -Name 'schema' -Default '')
  $name = [string](Get-ToolkitMember -Object $manifest -Name 'name' -Default '')
  $version = [string](Get-ToolkitMember -Object $manifest -Name 'version' -Default '')

  if ($schema -ne $script:TKReleaseSchema) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Release manifest schema is not recognized.' -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
  if ($name -ne $script:TKToolkitName) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Release manifest identity does not match this toolkit.' -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
  if ($version -notmatch '^\d+\.\d+\.\d+([\-+][0-9A-Za-z\.\-]+)?$') {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Release manifest version is malformed.' -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }

  # stateDirectory is part of the manifest contract; a different value is not something this
  # engine can honour, so it is validated rather than silently ignored.
  $stateDirectory = [string](Get-ToolkitMember -Object $manifest -Name 'stateDirectory' -Default '')
  if ($stateDirectory -ne $script:TKStateDirectory) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest `
      -Message ('Release manifest stateDirectory must be "' + $script:TKStateDirectory + '".') `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $Path) + ' stateDirectory=' + (Get-ToolkitSafeText -Text $stateDirectory))
  }

  $files = @(Get-ToolkitMember -Object $manifest -Name 'files' -Default @())
  if ($files.Count -eq 0) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Release manifest lists no files; refusing to continue.'
  }
  $declared = Get-ToolkitMember -Object $manifest -Name 'fileCount' -Default $null
  if ($null -ne $declared -and [int]$declared -ne $files.Count) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Release manifest fileCount does not match its file list.'
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $entries = New-Object System.Collections.ArrayList
  foreach ($file in $files) {
    $relative = [string](Get-ToolkitMember -Object $file -Name 'path' -Default '')
    $source = [string](Get-ToolkitMember -Object $file -Name 'source' -Default '')

    $relative = Assert-ToolkitRelativePath -Path $relative
    $source = Assert-ToolkitRelativePath -Path $source
    Assert-ToolkitPathNotDenied -RelativePath $relative
    Assert-ToolkitPathNotDenied -RelativePath $source

    if (-not $seen.Add($relative)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Release manifest contains duplicate or case-folded duplicate paths.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }
    # The release manifest describes where each managed file comes from. No digest is read,
    # validated or stored: an entry that carries one is simply ignored.
    [void]$entries.Add((New-ToolkitJsonObject -Properties @{
          path   = $relative
          source = $source
        }))
  }

  return (New-ToolkitJsonObject -Properties @{
      schema         = $schema
      name           = $name
      version        = $version
      stateDirectory = $stateDirectory
      files          = $entries.ToArray()
      path           = [System.IO.Path]::GetFullPath($Path)
    })
}

function New-ToolkitReleaseManifest {
  <#
    Builds and writes a release manifest from explicit managed entries.
    Used by tools/Build-Release.ps1 and by the test harness to create fake packages.
  #>
  param(
    [string]$PackageRoot,
    [string]$Version,
    [object[]]$ManagedEntries,
    [string]$Destination,
    [string]$StateDirectory = $script:TKStateDirectory
  )

  $root = [System.IO.Path]::GetFullPath($PackageRoot)
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $files = New-Object System.Collections.ArrayList

  foreach ($entry in @($ManagedEntries)) {
    $relative = Assert-ToolkitRelativePath -Path ([string](Get-ToolkitMember -Object $entry -Name 'path' -Default ''))
    $source = Assert-ToolkitRelativePath -Path ([string](Get-ToolkitMember -Object $entry -Name 'source' -Default ''))
    Assert-ToolkitPathNotDenied -RelativePath $relative
    Assert-ToolkitPathNotDenied -RelativePath $source

    if (-not $seen.Add($relative)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Duplicate managed path in release manifest input.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }
    $sourceAbsolute = Assert-ToolkitPathInsideRoot -Root $root -FullPath (Get-ToolkitFullPath -Root $root -RelativePath $source) -RelativePath $source
    if (-not (Test-Path -LiteralPath $sourceAbsolute -PathType Leaf)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Managed source file is missing from the package.' -Detail ('path=' + (Get-ToolkitSafePath -Path $source))
    }
    $item = Get-ToolkitItemOrNull -Path $sourceAbsolute
    if (Test-ToolkitReparseItem -Item $item) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Managed source file is a reparse point.' -Detail ('path=' + (Get-ToolkitSafePath -Path $source))
    }
    [void]$files.Add((New-ToolkitJsonObject -Properties @{
          path   = $relative
          source = $source
        }))
  }

  if ($files.Count -eq 0) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Refusing to write an empty release manifest.'
  }

  $manifest = New-ToolkitJsonObject -Properties @{
    schema         = $script:TKReleaseSchema
    name           = $script:TKToolkitName
    version        = $Version
    stateDirectory = $StateDirectory
    generatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    fileCount      = $files.Count
    files          = $files.ToArray()
  }
  Write-ToolkitJsonAtomic -Object $manifest -Destination $Destination
  return $manifest
}

function Read-ToolkitOwnershipManifest {
  param(
    [string]$Path,
    [switch]$Optional
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    if ($Optional) { return $null }
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Ownership manifest is missing; refusing to guess what this toolkit installed.' -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }

  $manifest = Read-ToolkitJsonFile -Path $Path -ExitCode $script:TKExitManifest -What 'Ownership manifest'
  $schema = [string](Get-ToolkitMember -Object $manifest -Name 'schema' -Default '')
  $name = [string](Get-ToolkitMember -Object $manifest -Name 'name' -Default '')
  $version = [string](Get-ToolkitMember -Object $manifest -Name 'version' -Default '')
  $installId = [string](Get-ToolkitMember -Object $manifest -Name 'installId' -Default '')

  if ($schema -ne $script:TKOwnershipSchema) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Ownership manifest schema does not match this toolkit.'
  }
  if ($name -ne $script:TKToolkitName) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Ownership manifest identity does not match this toolkit.'
  }
  if ($installId -notmatch '^[0-9a-fA-F\-]{8,64}$') {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Ownership manifest install id is malformed.'
  }

  $files = @(Get-ToolkitMember -Object $manifest -Name 'files' -Default @())
  if ($files.Count -eq 0) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Ownership manifest lists no files; refusing to continue.'
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $entries = New-Object System.Collections.ArrayList
  foreach ($file in $files) {
    $relative = Assert-ToolkitRelativePath -Path ([string](Get-ToolkitMember -Object $file -Name 'path' -Default ''))
    Assert-ToolkitPathNotDenied -RelativePath $relative
    if (-not $seen.Add($relative)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Ownership manifest contains duplicate or case-folded duplicate paths.'
    }
    # Every managed entry must carry a valid pristine reference: that copy is the only
    # ownership evidence this toolkit has. A digest field is neither read nor required.
    $pristineRelative = [string](Get-ToolkitMember -Object $file -Name 'pristine' -Default '')
    if ([string]::IsNullOrEmpty($pristineRelative)) {
      $pristineRelative = Get-ToolkitPristineRelativePath -RelativePath $relative
    }
    $pristineRelative = Assert-ToolkitRelativePath -Path $pristineRelative
    Assert-ToolkitPathNotDenied -RelativePath $pristineRelative
    if ($pristineRelative -ne (Get-ToolkitPristineRelativePath -RelativePath $relative)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Ownership manifest pristine reference does not match its managed path.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }
    [void]$entries.Add((New-ToolkitJsonObject -Properties @{
          path     = $relative
          pristine = $pristineRelative
          state    = ([string](Get-ToolkitMember -Object $file -Name 'state' -Default 'owned'))
        }))
  }

  # Self-locating state: the ledger describes the state directory layout, never the absolute
  # project path, so relocating a project needs no digest and no migration.
  $location = Get-ToolkitMember -Object $manifest -Name 'location' -Default $null
  $locationStateDirectory = $script:TKStateDirectory
  $locationPristineRoot = $script:TKPristineDirectoryName
  if ($null -ne $location) {
    $locationStateDirectory = [string](Get-ToolkitMember -Object $location -Name 'stateDir' -Default $script:TKStateDirectory)
    $locationPristineRoot = [string](Get-ToolkitMember -Object $location -Name 'pristineRoot' -Default $script:TKPristineDirectoryName)
  }
  if ($locationStateDirectory -ne $script:TKStateDirectory) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message ('Ownership manifest state directory must be "' + $script:TKStateDirectory + '".')
  }
  if ($locationPristineRoot -ne $script:TKPristineDirectoryName) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message ('Ownership manifest pristine root must be "' + $script:TKPristineDirectoryName + '".')
  }

  return (New-ToolkitJsonObject -Properties @{
      schema   = $schema
      name     = $name
      version  = $version
      installId = $installId
      location = (New-ToolkitJsonObject -Properties @{
          stateDir     = $locationStateDirectory
          pristineRoot = $locationPristineRoot
        })
      files    = $entries.ToArray()
      path     = [System.IO.Path]::GetFullPath($Path)
    })
}

function New-ToolkitOwnershipManifest {
  param(
    [string]$InstallId,
    [string]$Version,
    [string]$TargetRoot,
    [object[]]$Files,
    [string]$ToolkitVersion = ''
  )

  $list = New-Object System.Collections.ArrayList
  foreach ($file in @($Files)) {
    $relative = [string](Get-ToolkitMember -Object $file -Name 'path' -Default '')
    [void]$list.Add((New-ToolkitJsonObject -Properties @{
          path     = $relative
          pristine = (Get-ToolkitPristineRelativePath -RelativePath $relative)
          state    = 'owned'
        }))
  }

  $description = 'Toolkit-owned files under this project. Managed by install/Invoke-Toolkit.ps1.'
  if (-not [string]::IsNullOrEmpty($ToolkitVersion)) {
    $description = $description + ' Written by toolkit ' + $ToolkitVersion + '.'
  }

  return (New-ToolkitJsonObject -Properties @{
      schema       = $script:TKOwnershipSchema
      name         = $script:TKToolkitName
      version      = $Version
      installId    = $InstallId
      updatedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      location     = (New-ToolkitJsonObject -Properties @{
          # Self-locating: relative layout only, never an absolute (personal) path and never a
          # location digest. Ownership is proved by the pristine copies, so a moved project
          # keeps working without migration.
          stateDir     = $script:TKStateDirectory
          pristineRoot = $script:TKPristineDirectoryName
        })
      description  = $description
      fileCount    = $list.Count
      files        = $list.ToArray()
    })
}

function Get-ToolkitStateGitIgnoreContent {
  <#
    The exact bytes of the self-ignoring state .gitignore the toolkit writes. Used so the file may
    be removed only while it is still byte-identical to what the toolkit generated.
  #>
  return ('# Toolkit-owned state (ledger, log, transaction evidence). Ignore the whole directory.' + [Environment]::NewLine + '*' + [Environment]::NewLine)
}

function Write-ToolkitStateGitIgnore {
  <#
    A self-ignoring state directory: the project never has to edit its own .gitignore.
  #>
  param([string]$StateDirectory)

  $gitIgnorePath = Join-Path $StateDirectory $script:TKStateGitIgnoreName
  if (Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) { return }
  Write-ToolkitTextFileDurable -Path $gitIgnorePath -Content (Get-ToolkitStateGitIgnoreContent)
}

function Get-ToolkitStateCleanupCandidates {
  <#
    Relative directories inside the state directory that may be removed when they are empty.
  #>
  param([string]$StateDirectory)

  return @($script:TKTxnDirectoryName, $script:TKQuarantineDirectoryName, 'backup', 'engine', $script:TKPristineDirectoryName)
}

function Get-ToolkitOrphanTransactions {
  <#
    Finds transaction directories left behind by a hard interruption (no cleanup ran).

    SAFE-01: a directory under txn/ is only transaction evidence when it actually carries the
    journal. The toolkit writes journal.json *before* it mutates anything, so a directory without
    a journal cannot describe a half-applied transaction - it is unproven content that the state
    cleanup preserves and reports instead of treating as recoverable evidence.
  #>
  param([string]$StateDirectory)

  $orphans = New-Object System.Collections.ArrayList
  $txnRoot = Join-Path $StateDirectory $script:TKTxnDirectoryName
  if (-not (Test-Path -LiteralPath $txnRoot -PathType Container)) { return $orphans.ToArray() }
  # MAJOR-2: the txn root itself must not be a reparse point: Get-ChildItem would follow it and
  # recovery could act on files outside the state directory.
  $txnRootItem = Get-ToolkitItemOrNull -Path $txnRoot
  if (Test-ToolkitReparseItem -Item $txnRootItem) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message ('The toolkit state transaction directory is a symlink / junction / reparse point; refusing to enumerate or recover it so nothing outside the state directory can be touched.') `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $script:TKTxnDirectoryName))
  }
  foreach ($candidate in @(Get-ChildItem -LiteralPath $txnRoot -Force -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if (Test-ToolkitReparseItem -Item $candidate) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'A transaction directory is a symlink / junction / reparse point; refusing to recover it.' -Detail ('path=' + (Get-ToolkitSafePath -Path $candidate.FullName))
    }
    if (-not (Test-Path -LiteralPath (Join-Path $candidate.FullName 'journal.json') -PathType Leaf)) {
      # not transaction evidence: nothing was mutated, so it is left for the state cleanup to
      # preserve and report rather than being replayed or deleted.
      continue
    }
    [void]$orphans.Add($candidate)
  }
  return $orphans.ToArray()
}

function Invoke-ToolkitOrphanRecovery {
  <#
    Durable-journal replay. Runs under the exclusive lock before any new mutation so that a
    project killed mid-transaction is brought back to a coherent state instead of being
    permanently blocked or half-applied.

    Safety rules: only files that are byte-identical to the bytes this transaction recorded as
    pristine (or to its own backup) are touched, a file that changed since the interruption is
    preserved and reported, and anything that cannot be recovered keeps its evidence and stops
    the run.
  #>
  param(
    [string]$StateDirectory,
    [string]$TargetRoot,
    [string]$OwnershipManifestPath
  )

  # NEW-1: validate every state sub-root once before recovery replays anything (it restores
  # target bytes and pristine evidence, and removes transaction evidence).
  [void](Assert-ToolkitStateRootsSafe -StateDirectory $StateDirectory)

  $orphans = @(Get-ToolkitOrphanTransactions -StateDirectory $StateDirectory)
  if ($orphans.Count -eq 0) {
    return (New-ToolkitJsonObject -Properties @{ Recovered = 0; Problems = @(); Changed = $false })
  }

  $problems = New-Object System.Collections.ArrayList
  $keptEvidence = New-Object System.Collections.ArrayList
  $recovered = 0
  foreach ($directory in $orphans) {
    $journalPath = Join-Path $directory.FullName 'journal.json'
    $journal = $null
    try {
      $journal = Read-ToolkitJsonFile -Path $journalPath -ExitCode $script:TKExitRollback -What 'Transaction journal'
    }
    catch {
      [void]$problems.Add('unreadable or ambiguous journal at ' + (Get-ToolkitSafePath -Path $directory.FullName) + ': ' + (Get-ToolkitExceptionMessage -Exception $_.Exception))
      continue
    }

    # The journal is untrusted evidence: validate schema, kind, state and every path before
    # acting on anything. Unknown state/kind is refused by explicit allowlist and the evidence
    # is kept for a human.
    $validated = $null
    try {
      $validated = Get-ToolkitValidatedJournal -TargetRoot $TargetRoot -Journal $journal
    }
    catch {
      [void]$problems.Add('unsafe or unsupported transaction evidence at ' + (Get-ToolkitSafePath -Path $directory.FullName) + ': ' + (Get-ToolkitExceptionMessage -Exception $_.Exception))
      continue
    }

    Write-ToolkitLine ('Recovering an interrupted ' + [string]$validated.Kind + ' transaction (' + (Get-ToolkitSafePath -Path $directory.FullName) + ', state=' + [string]$validated.State + ').') 'Warn'

    if ([string]$validated.State -eq 'committed') {
      # The transaction had committed: the only leftovers are evidence files.
      Write-ToolkitLine 'The interrupted transaction had already committed; removing its leftover evidence.' 'Warn'
      try {
        # SAFE-01: only content its own journal justifies may go.
        $evidence = Remove-ToolkitProvenTransactionDirectory -StateDirectory $StateDirectory -TransactionDirectory $directory.FullName
        foreach ($problem in @($evidence.Problems)) { [void]$problems.Add([string]$problem) }
        # NEW-4: quarantine originals of a committed transaction are retained evidence (a previous
        # run may have promised to keep them), so they are reported as kept, not as a recovery
        # failure that would block every future run.
        foreach ($entry in @($evidence.Preserved)) {
          Write-ToolkitLine ('Kept retained transaction evidence: ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory ([string]$entry)))) 'Warn'
          [void]$keptEvidence.Add([string]$entry)
        }
        if ([bool]$evidence.Removed) { $recovered++ }
      }
      catch {
        [void]$problems.Add('could not remove committed transaction evidence at ' + (Get-ToolkitSafePath -Path $directory.FullName))
      }
      continue
    }

    $txn = New-ToolkitJsonObject -Properties @{
      Directory       = $directory.FullName
      BackupDirectory = (Join-Path $directory.FullName 'backup')
      QuarantineDirectory = (Join-Path $directory.FullName $script:TKQuarantineDirectoryName)
      JournalPath     = $journalPath
      Journal         = $journal
      StateDirectory  = $StateDirectory
    }

    if ([string]$validated.Kind -eq 'uninstall') {
      # Reverse a half-finished uninstall through the shared, non-destructive rollback path.
      # The journal records the transaction's own plan under 'plan'; adapt it to the shape the
      # rollback helper expects (already validated above).
      $journalPlan = New-ToolkitJsonObject -Properties @{
        Deletable = @($validated.Plan)
      }
      $uninstallRollback = Invoke-ToolkitUninstallRollback -Transaction $txn -TargetRoot $TargetRoot -Plan $journalPlan
      foreach ($problem in @($uninstallRollback.Problems)) { [void]$problems.Add([string]$problem) }
      if ([bool]$uninstallRollback.Ok) {
        try {
          # SAFE-01: only content its own journal justifies may go.
          $evidence = Remove-ToolkitProvenTransactionDirectory -StateDirectory $StateDirectory -TransactionDirectory $directory.FullName
          foreach ($problem in @($evidence.Problems)) { [void]$problems.Add([string]$problem) }
          foreach ($entry in @($evidence.Preserved)) {
            [void]$problems.Add('kept unproven content inside recovered uninstall evidence: ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory ([string]$entry))))
          }
          if ([bool]$evidence.Removed) { $recovered++ }
        }
        catch {
          [void]$problems.Add('could not remove recovered uninstall evidence at ' + (Get-ToolkitSafePath -Path $directory.FullName))
        }
      }
      continue
    }

    # install / upgrade: replay the documented reverse rollback, then drop the evidence
    $rollbackProblems = @(Invoke-ToolkitRollback -Transaction $txn -TargetRoot $TargetRoot -ManifestPath $OwnershipManifestPath)
    foreach ($problem in $rollbackProblems) { [void]$problems.Add($problem) }
    if ($rollbackProblems.Count -eq 0) {
      try {
        # SAFE-01: only content its own journal justifies may go.
        $evidence = Remove-ToolkitProvenTransactionDirectory -StateDirectory $StateDirectory -TransactionDirectory $directory.FullName
        foreach ($problem in @($evidence.Problems)) { [void]$problems.Add([string]$problem) }
        foreach ($entry in @($evidence.Preserved)) {
          [void]$problems.Add('kept unproven content inside recovered transaction evidence: ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory ([string]$entry))))
        }
        if ([bool]$evidence.Removed) { $recovered++ }
      }
      catch {
        [void]$problems.Add('could not remove recovered transaction evidence at ' + (Get-ToolkitSafePath -Path $directory.FullName))
      }
    }
  }

  if ($recovered -gt 0) {
    Write-ToolkitLine ('Recovered ' + $recovered + ' interrupted transaction(s) under the exclusive lock.') 'Warn'
  }
  if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-ToolkitLine ('Recovery issue: ' + $problem) 'Error' }
    Throw-ToolkitFailure -ExitCode $script:TKExitRollback `
      -Message 'An interrupted transaction could not be recovered automatically; refusing to continue so nothing is overwritten. The transaction evidence was kept.' `
      -Detail ('state=' + (Get-ToolkitSafePath -Path $StateDirectory))
  }
  return (New-ToolkitJsonObject -Properties @{ Recovered = $recovered; Problems = @(); Changed = ($recovered -gt 0); KeptEvidence = @($keptEvidence.ToArray()) })
}

function Assert-ToolkitApplyPreconditions {
  <#
    In-lock TOCTOU guard: re-proves ownership and content immediately before applying, so a
    file that changed between planning and applying is never overwritten. Every decision is a
    direct byte comparison against the pristine baseline (or, for the ledger, against the bytes
    captured under the lock).
  #>
  param(
    [string]$TargetRoot,
    [string]$StateDirectory,
    [object]$Plan,
    $OwnershipManifest,
    [string]$OwnershipManifestPath,
    $OwnershipManifestBytes = $null
  )

  $ownIndex = @{}
  if ($null -ne $OwnershipManifest) {
    foreach ($file in @($OwnershipManifest.files)) {
      $ownIndex[([string]$file.path).ToLowerInvariant()] = $true
    }
  }

  foreach ($operation in @($Plan.Operations)) {
    $relative = [string]$operation.path
    $destination = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative
    Assert-ToolkitNoReparseInPath -Root $TargetRoot -RelativePath $relative

    if ([string]$operation.action -eq 'create') {
      if (Test-Path -LiteralPath $destination) {
        Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
          -Message 'A file appeared at a managed path between planning and applying; the install was aborted before anything was overwritten.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      continue
    }

    if (-not (Test-ToolkitPathIsRegularFile -Path $destination)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
        -Message 'A managed file disappeared or is no longer a regular file between planning and applying; the install was aborted.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }
    if (-not $ownIndex.ContainsKey($relative.ToLowerInvariant())) {
      Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
        -Message 'A managed path is no longer recorded as owned; the install was aborted.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }
    if (-not (Test-ToolkitPristineMatches -StateDirectory $StateDirectory -RelativePath $relative -TargetPath $destination)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
        -Message 'A managed file changed between planning and applying (user edit detected in-lock); the install was aborted and the file was preserved.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }
  }

  # The ledger itself must not have changed under us: compared byte for byte with what was
  # captured under the lock.
  if ($null -ne $OwnershipManifestBytes) {
    if (-not (Test-Path -LiteralPath $OwnershipManifestPath -PathType Leaf)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'The ownership manifest disappeared between planning and applying; the install was aborted.'
    }
    if (-not (Test-ToolkitFileContentEqualToBytes -Path $OwnershipManifestPath -Bytes $OwnershipManifestBytes)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'The ownership manifest changed between planning and applying; the install was aborted.'
    }
  }
}

# ---------------------------------------------------------------------------
# Package / target resolution
# ---------------------------------------------------------------------------

function Get-ToolkitEngineSelfPath {
  if (-not [string]::IsNullOrEmpty($script:TKEngineSelfPath)) { return $script:TKEngineSelfPath }
  $path = $PSCommandPath
  if ([string]::IsNullOrEmpty($path)) { $path = $MyInvocation.MyCommand.Path }
  if ([string]::IsNullOrEmpty($path)) { $path = $MyInvocation.PSCommandPath }
  return [string]$path
}

function Resolve-ToolkitPackageRoot {
  param([hashtable]$Options)

  $explicitManifest = [string]$Options['ReleaseManifest']
  if (-not [string]::IsNullOrEmpty($explicitManifest)) {
    $full = [System.IO.Path]::GetFullPath($explicitManifest)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'The release manifest passed on the command line does not exist.' -Detail ('path=' + (Get-ToolkitSafePath -Path $full))
    }
    return (Split-Path -Parent $full)
  }

  $candidates = New-Object System.Collections.ArrayList
  $explicitRoot = [string]$Options['PackageRoot']
  if (-not [string]::IsNullOrEmpty($explicitRoot)) {
    [void]$candidates.Add($explicitRoot)
  }
  else {
    $engine = Get-ToolkitEngineSelfPath
    if (-not [string]::IsNullOrEmpty($engine)) {
      $engineDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($engine))
      [void]$candidates.Add((Join-Path $engineDirectory '..'))
      [void]$candidates.Add((Join-Path $engineDirectory '..\..'))
      [void]$candidates.Add($engineDirectory)
    }
    [void]$candidates.Add((Get-Location).Path)
  }

  foreach ($candidate in $candidates) {
    $full = [System.IO.Path]::GetFullPath([string]$candidate)
    if (Test-Path -LiteralPath (Join-Path $full 'release-manifest.json') -PathType Leaf) { return $full }
  }
  Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'No release-manifest.json found. Pass -PackageRoot or -ReleaseManifest explicitly (install must run from an extracted release package).'
}

function Resolve-ToolkitReleaseManifestPath {
  param(
    [hashtable]$Options,
    [string]$PackageRoot
  )

  $explicit = [string]$Options['ReleaseManifest']
  if (-not [string]::IsNullOrEmpty($explicit)) { return [System.IO.Path]::GetFullPath($explicit) }
  return (Join-Path $PackageRoot 'release-manifest.json')
}

function Resolve-ToolkitTargetPath {
  <#
    Validates an explicitly supplied target root: must already exist, be a directory,
    be absolute and contain no reparse point on any segment.
  #>
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'A target project root is required.'
  }
  if (-not (Test-ToolkitAbsoluteLocalPath -Path $Path)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'The target project root must be an absolute local path.' -Detail ('path=' + (Get-ToolkitSafePath -Path $Path))
  }
  $full = [System.IO.Path]::GetFullPath($Path)
  if ($full -eq [System.IO.Path]::GetPathRoot($full).TrimEnd('\')) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'A drive root cannot be a toolkit target.'
  }
  $item = Get-ToolkitItemOrNull -Path $full
  if ($null -eq $item -or -not ($item -is [System.IO.DirectoryInfo])) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'The target project root must already exist as a directory (the toolkit never creates it).' -Detail ('path=' + (Get-ToolkitSafePath -Path $full))
  }
  Assert-ToolkitNoReparseInPath -Root $full -RelativePath '' -RequireRootExists
  $resolved = (Resolve-Path -LiteralPath $full).Path
  return $resolved
}

function Get-ToolkitDerivedTargetPath {
  param([string]$EnginePath)

  if ([string]::IsNullOrEmpty($EnginePath)) { return '' }
  $engineDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($EnginePath))
  $stateCandidate = Split-Path -Parent $engineDirectory
  if ([System.IO.Path]::GetFileName($stateCandidate) -ne $script:TKStateDirectory) { return '' }
  $targetCandidate = Split-Path -Parent $stateCandidate
  if ([string]::IsNullOrEmpty($targetCandidate)) { return '' }
  if (-not (Test-Path -LiteralPath $targetCandidate -PathType Container)) { return '' }
  return $targetCandidate
}

function Read-ToolkitConfirmation {
  <#
    The single confirmation gate for every mutating operation (install/upgrade/uninstall).

    * -Yes (automation) confirms explicitly;
    * a non-interactive session without -Yes is refused with exit 8 and zero writes;
    * an interactive session is asked to type YES; anything else declines safely.
  #>
  param(
    [string]$Operation = 'This operation',
    [switch]$AlreadyConfirmed
  )

  if ($AlreadyConfirmed) { return $true }
  if (-not [string]::IsNullOrEmpty($script:TKTestConfirmation)) {
    Assert-ToolkitTestGate -Feature 'confirmation override'
    return ($script:TKTestConfirmation -ceq 'yes')
  }
  if ($script:TKNonInteractive) {
    Throw-ToolkitFailure -ExitCode $script:TKExitCancelled -Message ($Operation + ' needs explicit confirmation. Re-run with -Yes in a non-interactive session; nothing was written.')
  }
  $inputRedirected = $false
  try { $inputRedirected = [Console]::IsInputRedirected }
  catch { $inputRedirected = $true }
  if ($inputRedirected) {
    Throw-ToolkitFailure -ExitCode $script:TKExitCancelled -Message ($Operation + ' needs explicit confirmation and standard input is redirected. Re-run with -Yes; nothing was written.')
  }
  Write-Host ('Type YES to continue with ' + $Operation + ': ') -NoNewline
  $answer = Read-Host
  return ($answer -ceq 'YES')
}

function Get-ToolkitPlanSignature {
  <#
    Stable signature of the operations a plan would perform. Used to detect that automatic
    recovery changed the plan after the user confirmed, so consent never drifts from action.
  #>
  param([object]$Plan)

  if ($null -eq $Plan) { return '' }
  $parts = New-Object System.Collections.ArrayList
  foreach ($operation in @(Get-ToolkitMember -Object $Plan -Name 'Operations' -Default @())) {
    [void]$parts.Add(([string](Get-ToolkitMember -Object $operation -Name 'action' -Default '')) + ':' + ([string](Get-ToolkitMember -Object $operation -Name 'path' -Default '')))
  }
  if (@($parts).Count -eq 0) {
    foreach ($record in @(Get-ToolkitMember -Object $Plan -Name 'Deletable' -Default @())) {
      [void]$parts.Add('delete:' + ([string](Get-ToolkitMember -Object $record -Name 'path' -Default '')))
    }
    foreach ($record in @(Get-ToolkitMember -Object $Plan -Name 'Retained' -Default @())) {
      [void]$parts.Add('keep:' + ([string](Get-ToolkitMember -Object $record -Name 'path' -Default '')))
    }
  }
  return ((@($parts | Sort-Object)) -join '|')
}

function Select-ToolkitFolderInteractive {
  <#
    STA Windows folder picker (double-click entry point). Returns '' when cancelled.
    Never writes anything; refuses to run in a non-interactive host.
  #>
  if ($script:TKNonInteractive) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'No target was supplied and the session is non-interactive. Pass -Target <path> explicitly.'
  }
  $inputRedirected = $false
  try { $inputRedirected = [Console]::IsInputRedirected }
  catch { $inputRedirected = $true }
  if ($inputRedirected) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'No target was supplied and standard input is redirected. Pass -Target <path> explicitly (CI mode never prompts).'
  }

  # NOTE: the variable must not be named $isWindows: PowerShell variable names are
  # case-insensitive, and $IsWindows is a read-only automatic variable on PowerShell 7, so an
  # assignment would throw and break the interactive entry point there.
  $onWindowsPlatform = $true
  try { $onWindowsPlatform = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) }
  catch { $onWindowsPlatform = $true }
  if (-not $onWindowsPlatform) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'The interactive folder picker is Windows-only. Pass -Target <path> explicitly.'
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  }
  catch {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'Windows Forms is unavailable, so the folder picker cannot be shown. Pass -Target <path> explicitly.'
  }

  $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
  try {
    $dialog.Description = 'Select the project root where the Codex x DSH Team Toolkit should be installed'
    $dialog.ShowNewFolderButton = $false
    $dialog.RootFolder = [System.Environment+SpecialFolder]::MyComputer
    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
    return [string]$dialog.SelectedPath
  }
  finally {
    $dialog.Dispose()
  }
}

# ---------------------------------------------------------------------------
# Lock, journal, transaction
# ---------------------------------------------------------------------------

function Enter-ToolkitLock {
  param(
    [string]$StateDirectory,
    [switch]$ClearStaleLock
  )

  $lockPath = Join-Path $StateDirectory $script:TKLockName
  if (Test-Path -LiteralPath $lockPath) {
    if ($ClearStaleLock) {
      # A lock may only be broken when the record is intact AND proves the owner is gone:
      # a syntactically valid schema/toolkit identity, a plausible recorded pid, that pid not
      # running, and an age past the staleness threshold. Anything anomalous stays fail-closed.
      $stale = $false
      $reason = ''
      try {
        $record = Read-ToolkitJsonFile -Path $lockPath -ExitCode $script:TKExitBlocked -What 'Install lock'
        $lockSchema = [string](Get-ToolkitMember -Object $record -Name 'schema' -Default '')
        $lockToolkit = [string](Get-ToolkitMember -Object $record -Name 'toolkit' -Default '')
        $ownerProcessId = [int](Get-ToolkitMember -Object $record -Name 'processId' -Default 0)
        $started = [string](Get-ToolkitMember -Object $record -Name 'startedAtUtc' -Default '')
        $age = [TimeSpan]::Zero
        $ageKnown = $false
        if (-not [string]::IsNullOrEmpty($started)) {
          try {
            $age = [DateTime]::UtcNow - [DateTime]::Parse($started).ToUniversalTime()
            $ageKnown = $true
          }
          catch { $ageKnown = $false }
        }
        $pidPlausible = ($ownerProcessId -ge 2 -and $ownerProcessId -le 4194304)
        $identityValid = ($lockSchema -eq 'codex-dsh-team-toolkit/lock/v1' -and $lockToolkit -eq $script:TKToolkitName)
        $running = $false
        if ($pidPlausible) { $running = $null -ne (Get-Process -Id $ownerProcessId -ErrorAction SilentlyContinue) }
        if ($identityValid -and $pidPlausible -and $ageKnown -and (-not $running) -and $age.TotalMinutes -ge 10) {
          $stale = $true
        }
        else {
          $reason = 'identityValid=' + $identityValid + ' pidPlausible=' + $pidPlausible + ' ownerRunning=' + $running + ' ageKnown=' + $ageKnown + ' ageMinutes=' + [int]$age.TotalMinutes
        }
      }
      catch {
        $stale = $false
        $reason = 'the lock record could not be parsed'
      }
      if (-not $stale) {
        Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
          -Message 'The existing toolkit lock is not provably stale; refusing to break it. Inspect it by hand if you are certain no run is active.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $lockPath) + ' ' + $reason)
      }
      Write-ToolkitLine 'Removing a provably stale toolkit lock (-ClearStaleLock).' 'Warn'
      Remove-Item -LiteralPath $lockPath -Force
    }
    else {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'Another toolkit install/uninstall is in progress (lock file present). Re-run later, or use -ClearStaleLock if the previous run was killed.' -Detail ('path=' + (Get-ToolkitSafePath -Path $lockPath))
    }
  }

  $stream = $null
  try {
    $stream = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
  }
  catch {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'Could not acquire the exclusive toolkit lock.' -Detail ('path=' + (Get-ToolkitSafePath -Path $lockPath))
  }
  $record = New-ToolkitJsonObject -Properties @{
    schema       = 'codex-dsh-team-toolkit/lock/v1'
    toolkit      = $script:TKToolkitName
    processId    = $PID
    startedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-ToolkitJson -Object $record))
  $stream.Write($bytes, 0, $bytes.Length)
  $stream.Flush($true)
  return (New-ToolkitJsonObject -Properties @{ Stream = $stream; Path = $lockPath })
}

function Exit-ToolkitLock {
  param($Lock)

  if ($null -eq $Lock) { return }
  try { $Lock.Stream.Dispose() } catch { }
  try {
    if (Test-Path -LiteralPath $Lock.Path) { Remove-Item -LiteralPath $Lock.Path -Force }
  }
  catch { }
}

function Start-ToolkitTransaction {
  param(
    [string]$StateDirectory,
    [string]$Kind,
    [string]$TargetRoot,
    [object]$Plan,
    [string]$ToolkitVersion
  )

  $txnRoot = Join-Path $StateDirectory $script:TKTxnDirectoryName
  # NEW-1: creating the transaction writes into txn/, so that root must be safe first. An occupied
  # name is not a reparse point but still makes a transaction impossible: fail with a clear message
  # instead of surfacing a raw directory-creation error.
  Assert-ToolkitStateRootSafe -StateDirectory $StateDirectory -RelativeRoot $script:TKTxnDirectoryName
  if (Test-Path -LiteralPath $txnRoot) {
    $txnRootItem = Get-ToolkitItemOrNull -Path $txnRoot
    if ($null -ne $txnRootItem -and -not ($txnRootItem -is [System.IO.DirectoryInfo])) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message 'The toolkit state root "txn" is occupied by a file, so a transaction directory cannot be created; refusing to continue.' `
        -Detail ('Remediation: move ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory $script:TKTxnDirectoryName)) + ' aside, then retry. Nothing was changed.')
    }
  }
  if (-not (Test-Path -LiteralPath $txnRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $txnRoot -Force | Out-Null
  }
  $id = [Guid]::NewGuid().ToString('n')
  $directory = Join-Path $txnRoot $id
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
  $backupDirectory = Join-Path $directory 'backup'
  New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
  $journalPath = Join-Path $directory 'journal.json'

  $journal = New-ToolkitJsonObject -Properties @{
    schema         = 'codex-dsh-team-toolkit/journal/v1'
    transactionId  = $id
    kind           = $Kind
    toolkitVersion = $ToolkitVersion
    startedAtUtc   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    plan           = @(Get-ToolkitMember -Object $Plan -Name 'JournalPaths' -Default @())
    state          = 'started'
    backups        = @()
    pristineBackups = @()
    staged         = @()
    createdDirectories = @()
    manifestBackup = $false
    runtimeCreated = $false
    notes          = @()
  }
  if ($null -ne $Plan) {
    $notes = @(Get-ToolkitMember -Object $Plan -Name 'Notes' -Default @())
    if ($notes.Count -gt 0) {
      $journal.notes = $notes
    }
    $journal.createdDirectories = @(Get-ToolkitMember -Object $Plan -Name 'CreatedDirectories' -Default @())
  }
  Save-ToolkitJournal -Transaction (New-ToolkitJsonObject -Properties @{
      Directory      = $directory
      BackupDirectory = $backupDirectory
      JournalPath    = $journalPath
      Journal        = $journal
    })

  return (New-ToolkitJsonObject -Properties @{
      Id              = $id
      Directory       = $directory
      BackupDirectory = $backupDirectory
      JournalPath     = $journalPath
      Journal         = $journal
      StateDirectory  = $StateDirectory
    })
}

function Save-ToolkitJournal {
  param($Transaction)

  Write-ToolkitTextFileDurable -Path $Transaction.JournalPath -Content ((ConvertTo-ToolkitJson -Object $Transaction.Journal) + [Environment]::NewLine)
}

function Remove-ToolkitProvenTransactionDirectory {
  <#
    SAFE-01: removes a transaction directory only as far as its own journal justifies. A toolkit
    directory name never authorises deleting whatever a user may have dropped inside it:
    content the journal does not name is preserved and returned.

    Returns @{ Removed = <bool>; Preserved = @(<relative paths>); Problems = @() } where Removed
    means the directory itself is gone.
  #>
  param(
    [string]$StateDirectory,
    [string]$TransactionDirectory,
    [string]$StateRelativePath = ''
  )

  $preserved = New-Object System.Collections.ArrayList
  $problems = New-Object System.Collections.ArrayList

  if (-not (Test-Path -LiteralPath $TransactionDirectory -PathType Container)) {
    return (New-ToolkitJsonObject -Properties @{ Removed = $true; Preserved = @(); Problems = @() })
  }
  $relative = [string]$StateRelativePath
  if ([string]::IsNullOrEmpty($relative)) {
    $prefix = [System.IO.Path]::GetFullPath($StateDirectory).TrimEnd('\').Length + 1
    $full = [System.IO.Path]::GetFullPath($TransactionDirectory)
    if (-not $full.StartsWith(([System.IO.Path]::GetFullPath($StateDirectory).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
      [void]$preserved.Add($full)
      [void]$problems.Add('refused to touch a transaction directory outside the state directory: ' + (Get-ToolkitSafePath -Path $full))
      return (New-ToolkitJsonObject -Properties @{ Removed = $false; Preserved = $preserved.ToArray(); Problems = $problems.ToArray() })
    }
    $relative = $full.Substring($prefix).Replace('\', '/')
  }

  $owned = Get-ToolkitTransactionOwnedPaths -TransactionDirectory $TransactionDirectory
  if (-not [bool]$owned.Ok) {
    # No readable journal: nothing inside can be justified. An empty directory still goes.
    $children = @(Get-ChildItem -LiteralPath $TransactionDirectory -Force -Recurse -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) {
      try { Remove-Item -LiteralPath $TransactionDirectory -Force; return (New-ToolkitJsonObject -Properties @{ Removed = $true; Preserved = @(); Problems = @() }) }
      catch { }
    }
    [void]$preserved.Add($relative)
    [void]$problems.Add('preserved transaction evidence whose journal is unreadable: ' + (Get-ToolkitSafePath -Path $relative))
    return (New-ToolkitJsonObject -Properties @{ Removed = $false; Preserved = $preserved.ToArray(); Problems = $problems.ToArray() })
  }

  $result = Remove-ToolkitStateEvidenceSubtree -StateDirectory $StateDirectory -RelativeRoot $relative -ProvenRelativePaths @($owned.Paths) -Origin 'transaction'
  foreach ($entry in @($result.Preserved)) { [void]$preserved.Add([string]$entry) }
  foreach ($problem in @($result.Problems)) { [void]$problems.Add([string]$problem) }
  $stillThere = Test-Path -LiteralPath $TransactionDirectory
  return (New-ToolkitJsonObject -Properties @{ Removed = (-not $stillThere); Preserved = $preserved.ToArray(); Problems = $problems.ToArray() })
}

function Remove-ToolkitTransactionDirectory {
  param($Transaction)

  if ($null -eq $Transaction) { return }
  if ($script:TKTestKeepTransaction -and $script:TKTestMode) {
    Write-ToolkitLine ('[test] transaction directory kept for inspection: ' + (Get-ToolkitSafePath -Path ([string]$Transaction.Directory))) 'Warn'
    return
  }
  try {
    $stateDirectory = [string]$Transaction.StateDirectory
    if (Test-Path -LiteralPath ([string]$Transaction.Directory)) {
      $result = Remove-ToolkitProvenTransactionDirectory -StateDirectory $stateDirectory -TransactionDirectory ([string]$Transaction.Directory)
      foreach ($problem in @($result.Problems)) { Write-ToolkitLine ('Transaction cleanup: ' + [string]$problem) 'Warn' }
      if (-not [bool]$result.Removed -and @($result.Preserved).Count -gt 0) {
        Write-ToolkitLine ('Preserved content inside the transaction directory that the toolkit cannot prove it created: ' + @($result.Preserved).Count) 'Warn'
        foreach ($entry in @($result.Preserved)) {
          Write-ToolkitLine ('  keep     ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory ([string]$entry))))
        }
      }
    }
    $txnRoot = Join-Path $Transaction.StateDirectory $script:TKTxnDirectoryName
    $remainingTxn = @(Get-ChildItem -LiteralPath $txnRoot -Force -ErrorAction SilentlyContinue)
    if ((Test-Path -LiteralPath $txnRoot -PathType Container) -and $remainingTxn.Count -eq 0) {
      Remove-Item -LiteralPath $txnRoot -Force -ErrorAction SilentlyContinue
    }
  }
  catch {
    # Never silent: a failure here must surface, and preservation must still be reported.
    Write-ToolkitLine ('Transaction cleanup failed (evidence may have been kept): ' + (Get-ToolkitSafeText -Text $_.Exception.Message)) 'Warn'
  }
}

function Backup-ToolkitFile {
  <#
    Backs up a target file AND its pristine baseline as one transaction step. The copies are
    verified by direct byte comparison, so a rollback always has trustworthy bytes to restore.
  #>
  param(
    $Transaction,
    [string]$RelativePath,
    [string]$SourcePath
  )

  $backupPath = Join-Path $Transaction.BackupDirectory (ConvertTo-ToolkitNativePath -RelativePath $RelativePath)
  $backupDirectory = Split-Path -Parent $backupPath
  if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
  }
  Copy-ToolkitFileDurable -Source $SourcePath -Destination $backupPath
  if (-not (Test-ToolkitFileContentEqual -PathA $SourcePath -PathB $backupPath)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'Backup copy does not match the file it replaces; aborting before any mutation.' -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
  }
  $originalWriteTime = ''
  try { $originalWriteTime = (Get-Item -LiteralPath $SourcePath).LastWriteTimeUtc.ToString('o') } catch { $originalWriteTime = '' }
  [void](Add-ToolkitJournalBackup -Transaction $Transaction -RelativePath $RelativePath -WriteTime $originalWriteTime)

  # The pristine baseline is part of the same transaction: it must be restorable too. Reading it
  # happens through state/pristine, so that root must be safe even for this caller.
  Test-ToolkitStatePristineRootSafe -StateDirectory ([string]$Transaction.StateDirectory)
  $pristinePath = Get-ToolkitPristineFullPath -StateDirectory $Transaction.StateDirectory -RelativePath $RelativePath
  if (Test-Path -LiteralPath $pristinePath -PathType Leaf) {
    $pristineBackup = Join-Path $Transaction.BackupDirectory ('pristine\' + (ConvertTo-ToolkitNativePath -RelativePath $RelativePath))
    $pristineBackupDirectory = Split-Path -Parent $pristineBackup
    if (-not (Test-Path -LiteralPath $pristineBackupDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $pristineBackupDirectory -Force | Out-Null
    }
    Copy-ToolkitFileDurable -Source $pristinePath -Destination $pristineBackup
    if (-not (Test-ToolkitFileContentEqual -PathA $pristinePath -PathB $pristineBackup)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'Backup copy of the pristine baseline does not match; aborting before any mutation.' -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
    }
    [void](Add-ToolkitJournalPristineBackup -Transaction $Transaction -RelativePath $RelativePath)
  }
}

function Add-ToolkitJournalBackup {
  param(
    $Transaction,
    [string]$RelativePath,
    [string]$WriteTime = ''
  )

  $list = New-Object System.Collections.ArrayList
  foreach ($existing in @($Transaction.Journal.backups)) { [void]$list.Add($existing) }
  [void]$list.Add((New-ToolkitJsonObject -Properties @{
        path             = $RelativePath
        # recorded so a rollback restores the file *and* its timestamp, leaving the tree
        # indistinguishable from before the transaction
        lastWriteTimeUtc = $WriteTime
      }))
  $Transaction.Journal.backups = $list.ToArray()
  Save-ToolkitJournal -Transaction $Transaction
}

function Add-ToolkitJournalPristineBackup {
  param(
    $Transaction,
    [string]$RelativePath
  )

  $list = New-Object System.Collections.ArrayList
  foreach ($existing in @($Transaction.Journal.pristineBackups)) { [void]$list.Add($existing) }
  [void]$list.Add((New-ToolkitJsonObject -Properties @{ path = $RelativePath }))
  $Transaction.Journal.pristineBackups = $list.ToArray()
  Save-ToolkitJournal -Transaction $Transaction
}

function Register-ToolkitStagedFile {
  param(
    $Transaction,
    [string]$RelativePath
  )

  $list = New-Object System.Collections.ArrayList
  foreach ($existing in @($Transaction.Journal.staged)) { [void]$list.Add($existing) }
  [void]$list.Add($RelativePath)
  $Transaction.Journal.staged = $list.ToArray()
  Save-ToolkitJournal -Transaction $Transaction
}

function Backup-ToolkitManifest {
  param(
    $Transaction,
    [string]$ManifestPath
  )

  if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return }
  $target = Join-Path $Transaction.BackupDirectory 'ownership-manifest.json'
  Copy-ToolkitFileDurable -Source $ManifestPath -Destination $target
  $Transaction.Journal.manifestBackup = $true
  Save-ToolkitJournal -Transaction $Transaction
}

function Invoke-ToolkitRollback {
  <#
    Reverse-order rollback driven by the durable journal. Never deletes anything whose
    current content does not match what this transaction wrote.

    The journal is untrusted input: every path it carries is validated (strict relative syntax,
    deny policy, containment, case-fold, reparse) before anything is restored, moved or deleted.
  #>
  param(
    $Transaction,
    [string]$TargetRoot,
    [string]$ManifestPath
  )

  $problems = New-Object System.Collections.ArrayList
  if ($null -eq $Transaction) { return $problems.ToArray() }

  # NEW-1: rollback restores pristine baselines (write), deletes them (created files) and sweeps
  # pristine directories, so every state sub-root must be safe before it touches any of them. This
  # function is reachable from Invoke-ToolkitOrphanRecovery, which also pre-checks; keeping the
  # guard here means a direct caller cannot bypass it.
  [void](Assert-ToolkitStateRootsSafe -StateDirectory ([string]$Transaction.StateDirectory))

  # 0. validate the whole journal before acting on any of it
  $validated = Get-ToolkitValidatedJournal -TargetRoot $TargetRoot -Journal $Transaction.Journal

  # 0a. remove staged temporary files (recorded as relative paths before they were created)
  foreach ($stagedRelative in @($validated.Staged)) {
    try {
      $tempPath = Get-ToolkitFullPath -Root $TargetRoot -RelativePath ([string]$stagedRelative)
      if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
    }
    catch {
      [void]$problems.Add('staged cleanup failed for ' + (Get-ToolkitSafePath -Path ([string]$stagedRelative)) + ': ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }

  # 0b. sweep any remaining same-directory temp for this transaction's plan
  $strayTemps = @(Remove-ToolkitStrayTemps -TargetRoot $TargetRoot -StateDirectory $Transaction.StateDirectory -Plan @($validated.Plan))
  foreach ($issue in $strayTemps) { [void]$problems.Add([string]$issue) }

  # 1. restore replaced / removed files from backup (target bytes AND pristine bytes)
  foreach ($record in @($validated.Backups)) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    $recordedWriteTime = [string](Get-ToolkitMember -Object $record -Name 'lastWriteTimeUtc' -Default '')
    $backupPath = Join-Path $Transaction.BackupDirectory (ConvertTo-ToolkitNativePath -RelativePath $relative)
    try {
      if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        [void]$problems.Add('missing backup for ' + (Get-ToolkitSafePath -Path $relative))
        continue
      }
      $destination = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative
      $destinationDirectory = Split-Path -Parent $destination
      if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
      }
      $temp = Join-Path $destinationDirectory ('.rollback-' + [Guid]::NewGuid().ToString('n'))
      Copy-ToolkitFileDurable -Source $backupPath -Destination $temp
      Move-ToolkitFileAtomic -Source $temp -Destination $destination
      if (-not (Test-ToolkitFileContentEqual -PathA $destination -PathB $backupPath)) {
        [void]$problems.Add('restored content mismatch for ' + (Get-ToolkitSafePath -Path $relative))
      }
      # restore the original timestamp too (best effort): a rolled-back file must be
      # indistinguishable from the one that existed before the transaction.
      if (-not [string]::IsNullOrEmpty($recordedWriteTime)) {
        try { [System.IO.File]::SetLastWriteTimeUtc($destination, [DateTime]::Parse($recordedWriteTime, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()) } catch { }
      }
    }
    catch {
      [void]$problems.Add('restore failed for ' + (Get-ToolkitSafePath -Path $relative) + ': ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }

  # 1b. restore the pristine baselines that were part of this transaction
  foreach ($record in @($validated.PristineBackups)) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    $pristineBackup = Join-Path $Transaction.BackupDirectory ('pristine\' + (ConvertTo-ToolkitNativePath -RelativePath $relative))
    try {
      if (-not (Test-Path -LiteralPath $pristineBackup -PathType Leaf)) {
        [void]$problems.Add('missing pristine backup for ' + (Get-ToolkitSafePath -Path $relative))
        continue
      }
      $pristinePath = Get-ToolkitPristineFullPath -StateDirectory $Transaction.StateDirectory -RelativePath $relative
      $pristineDirectory = Split-Path -Parent $pristinePath
      if (-not (Test-Path -LiteralPath $pristineDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $pristineDirectory -Force | Out-Null
      }
      $temp = Join-Path $pristineDirectory ('.pristine-rollback-' + [Guid]::NewGuid().ToString('n'))
      Copy-ToolkitFileDurable -Source $pristineBackup -Destination $temp
      Move-ToolkitFileAtomic -Source $temp -Destination $pristinePath
      if (-not (Test-ToolkitFileContentEqual -PathA $pristinePath -PathB $pristineBackup)) {
        [void]$problems.Add('restored pristine mismatch for ' + (Get-ToolkitSafePath -Path $relative))
      }
    }
    catch {
      [void]$problems.Add('pristine restore failed for ' + (Get-ToolkitSafePath -Path $relative) + ': ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }

  # 2. delete files this transaction created (only while they still equal the bytes we wrote)
  foreach ($record in @($validated.Plan)) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    try {
      $destination = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative
      $backedUp = @($validated.Backups | Where-Object { [string](Get-ToolkitMember -Object $_ -Name 'path' -Default '') -eq $relative })
      if ($backedUp.Count -gt 0) { continue }
      # The pristine copy holds the exact bytes we installed. It is the only trustworthy
      # reference; without it the file is preserved rather than guessed at.
      $pristinePath = Get-ToolkitPristineFullPath -StateDirectory $Transaction.StateDirectory -RelativePath $relative
      if (Test-Path -LiteralPath $destination -PathType Leaf) {
        if ((Test-Path -LiteralPath $pristinePath -PathType Leaf) -and (Test-ToolkitFileContentEqual -PathA $destination -PathB $pristinePath)) {
          Remove-Item -LiteralPath $destination -Force
        }
        else {
          [void]$problems.Add('kept a created file that no longer matches the pristine baseline: ' + (Get-ToolkitSafePath -Path $relative))
        }
      }
      Remove-ToolkitPristineFile -StateDirectory $Transaction.StateDirectory -RelativePath $relative
    }
    catch {
      [void]$problems.Add('cleanup failed for ' + (Get-ToolkitSafePath -Path $relative) + ': ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }
  Remove-ToolkitEmptyPristineDirectories -StateDirectory $Transaction.StateDirectory

  # 3. remove directories this transaction created (only when they are empty)
  $createdDirectories = @($validated.CreatedDirectories)
  if ($createdDirectories.Count -gt 0) {
    $removed = @(Remove-ToolkitEmptyDirectories -Root $TargetRoot -RelativeDirectories $createdDirectories -ProtectedDirectories @())
    $expected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $createdDirectories) { [void]$expected.Add(([string]$item).Replace('\', '/').Trim('/')) }
    foreach ($item in $removed) { [void]$expected.Remove([string]$item) }
    foreach ($leftover in $expected) {
      $leftoverPath = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $leftover
      if (-not (Test-Path -LiteralPath $leftoverPath -PathType Container)) { continue }
      # The toolkit state directory owns its own cleanup path (log, journal, lock), so a
      # directory inside it is not a rollback failure.
      $statePrefix = $script:TKStateDirectory.ToLowerInvariant()
      $normalized = ([string]$leftover).ToLowerInvariant()
      if ($normalized -eq $statePrefix -or $normalized.StartsWith($statePrefix + '/')) { continue }
      [void]$problems.Add('created directory still present: ' + (Get-ToolkitSafePath -Path $leftover))
    }
  }

  # 4. ownership manifest
  try {
    if ($validated.ManifestBackup) {
      $backupManifest = Join-Path $Transaction.BackupDirectory 'ownership-manifest.json'
      if (Test-Path -LiteralPath $backupManifest -PathType Leaf) {
        $temp = Join-Path $Transaction.StateDirectory ('.manifest-rollback-' + [Guid]::NewGuid().ToString('n'))
        Copy-ToolkitFileDurable -Source $backupManifest -Destination $temp
        Move-ToolkitFileAtomic -Source $temp -Destination $ManifestPath
      }
    }
    elseif (Test-Path -LiteralPath $ManifestPath -PathType Leaf) {
      Remove-Item -LiteralPath $ManifestPath -Force
    }
  }
  catch {
    [void]$problems.Add('ownership manifest rollback failed: ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
  }

  return $problems.ToArray()
}

function Get-ToolkitValidatedJournalPath {
  <#
    Transaction evidence is untrusted input. Before any restore/move/delete/cleanup the path is
    validated for: strict relative syntax, deny policy, canonical containment inside the target,
    case-folded duplicates within the evidence set, and reparse points on every segment. A
    hostile path can therefore never aim an operation outside the project.
  #>
  param(
    [string]$TargetRoot,
    [string]$RelativePath,
    [hashtable]$Seen,
    [string]$Origin
  )

  $normalized = Assert-ToolkitRelativePath -Path $RelativePath
  Assert-ToolkitPathNotDenied -RelativePath $normalized
  if ($null -ne $Seen) {
    $key = $normalized.ToLowerInvariant()
    if ($Seen.ContainsKey($key)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message ('Transaction evidence contains a duplicate or case-folded duplicate path (' + $Origin + ').') `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $normalized))
    }
    $Seen[$key] = $true
  }
  Assert-ToolkitPathInsideRoot -Root $TargetRoot -FullPath (Get-ToolkitFullPath -Root $TargetRoot -RelativePath $normalized) -RelativePath $normalized | Out-Null
  Assert-ToolkitNoReparseInPath -Root $TargetRoot -RelativePath $normalized
  return $normalized
}

function Get-ToolkitValidatedJournal {
  <#
    Validates the whole journal before it is used. Returns the validated path sets; throws
    (leaving the evidence untouched) on anything hostile, ambiguous or truncated.
  #>
  param(
    [string]$TargetRoot,
    [object]$Journal
  )

  if ($null -eq $Journal) {
    Throw-ToolkitFailure -ExitCode $script:TKExitRollback -Message 'Transaction evidence is missing; refusing to act on it.'
  }
  $schema = [string](Get-ToolkitMember -Object $Journal -Name 'schema' -Default '')
  $kind = [string](Get-ToolkitMember -Object $Journal -Name 'kind' -Default '')
  $state = [string](Get-ToolkitMember -Object $Journal -Name 'state' -Default '')
  if ($schema -ne 'codex-dsh-team-toolkit/journal/v1') {
    Throw-ToolkitFailure -ExitCode $script:TKExitRollback -Message 'Transaction evidence has an unrecognized schema; refusing to act on it.'
  }
  if (@('install', 'uninstall') -notcontains $kind) {
    Throw-ToolkitFailure -ExitCode $script:TKExitRollback -Message ('Transaction evidence has an unsupported kind "' + (Get-ToolkitSafeText -Text $kind) + '"; refusing to act on it (evidence kept).')
  }
  if (@('started', 'committed') -notcontains $state) {
    Throw-ToolkitFailure -ExitCode $script:TKExitRollback -Message ('Transaction evidence has an unsupported state "' + (Get-ToolkitSafeText -Text $state) + '"; refusing to act on it (evidence kept).')
  }

  # Duplicates are detected per evidence list: the same path legitimately appears in both the
  # plan (what this transaction touched) and the backups (how to undo it).
  $seenPlan = @{}
  $seenBackups = @{}
  $seenStaged = @{}
  $plan = New-Object System.Collections.ArrayList
  foreach ($record in @(Assert-ToolkitJsonArray -Object $Journal -Name 'plan' -What 'Transaction journal' -ExitCode $script:TKExitRollback -AllowMissing)) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    [void]$plan.Add((New-ToolkitJsonObject -Properties @{
          path   = (Get-ToolkitValidatedJournalPath -TargetRoot $TargetRoot -RelativePath $relative -Seen $seenPlan -Origin 'plan')
          action = [string](Get-ToolkitMember -Object $record -Name 'action' -Default '')
        }))
  }
  $backups = New-Object System.Collections.ArrayList
  foreach ($record in @(Assert-ToolkitJsonArray -Object $Journal -Name 'backups' -What 'Transaction journal' -ExitCode $script:TKExitRollback -AllowMissing)) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    [void]$backups.Add((New-ToolkitJsonObject -Properties @{
          path             = (Get-ToolkitValidatedJournalPath -TargetRoot $TargetRoot -RelativePath $relative -Seen $seenBackups -Origin 'backups')
          # carried through so a rollback can restore the original timestamp as well
          lastWriteTimeUtc = [string](Get-ToolkitMember -Object $record -Name 'lastWriteTimeUtc' -Default '')
        }))
  }
  $seenPristineBackups = @{}
  $pristineBackups = New-Object System.Collections.ArrayList
  foreach ($record in @(Assert-ToolkitJsonArray -Object $Journal -Name 'pristineBackups' -What 'Transaction journal' -ExitCode $script:TKExitRollback -AllowMissing)) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    [void]$pristineBackups.Add((New-ToolkitJsonObject -Properties @{
          path = (Get-ToolkitValidatedJournalPath -TargetRoot $TargetRoot -RelativePath $relative -Seen $seenPristineBackups -Origin 'pristineBackups')
        }))
  }
  $staged = New-Object System.Collections.ArrayList
  foreach ($entry in @(Assert-ToolkitJsonArray -Object $Journal -Name 'staged' -What 'Transaction journal' -ExitCode $script:TKExitRollback -AllowMissing)) {
    $relative = Get-ToolkitValidatedJournalPath -TargetRoot $TargetRoot -RelativePath ([string]$entry) -Seen $seenStaged -Origin 'staged'
    $leaf = [System.IO.Path]::GetFileName($relative)
    if ($leaf -notmatch '^\..+\.toolkit-tmp-[0-9a-f]{32}$') {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message 'Transaction evidence lists a staged file that does not follow the toolkit temporary naming pattern; refusing to delete it.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }
    [void]$staged.Add($relative)
  }
  $directories = New-Object System.Collections.ArrayList
  foreach ($entry in @(Assert-ToolkitJsonArray -Object $Journal -Name 'createdDirectories' -What 'Transaction journal' -ExitCode $script:TKExitRollback -AllowMissing)) {
    $relative = [string]$entry
    if ([string]::IsNullOrWhiteSpace($relative)) { continue }
    Assert-ToolkitRelativePath -Path $relative | Out-Null
    [void]$directories.Add($relative)
  }

  return (New-ToolkitJsonObject -Properties @{
      Kind               = $kind
      State              = $state
      Plan               = $plan.ToArray()
      Backups            = $backups.ToArray()
      PristineBackups    = $pristineBackups.ToArray()
      Staged             = $staged.ToArray()
      CreatedDirectories = $directories.ToArray()
      ManifestBackup     = [bool](Get-ToolkitMember -Object $Journal -Name 'manifestBackup' -Default $false)
      RuntimeCreated     = [bool](Get-ToolkitMember -Object $Journal -Name 'runtimeCreated' -Default $false)
      Notes              = @(Assert-ToolkitJsonArray -Object $Journal -Name 'notes' -What 'Transaction journal' -ExitCode $script:TKExitRollback -AllowMissing)
    })
}

function Remove-ToolkitStrayTemps {
  <#
    Defence in depth: sweeps the planned destination directories for files that follow our own
    temp naming pattern and whose bytes equal the planned source (or, when the source is gone,
    the pristine baseline). A file that matches neither is left untouched and reported, because
    without a trustworthy reference the safe outcome is to preserve it.
  #>
  param(
    [string]$TargetRoot,
    [string]$StateDirectory = '',
    [object]$Plan
  )

  $problems = New-Object System.Collections.ArrayList
  # NEW-1: this sweep may read a pristine baseline as its trusted reference, so state/pristine must
  # be a real directory before anything here runs (the function is also reachable on its own).
  if (-not [string]::IsNullOrEmpty($StateDirectory)) {
    Test-ToolkitStatePristineRootSafe -StateDirectory $StateDirectory
  }
  foreach ($record in @($Plan)) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    if ([string]::IsNullOrEmpty($relative)) { continue }
    try {
      $destination = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative
      # A trustworthy reference for "this temp is ours": the planned source, else the pristine.
      $reference = ''
      $sourceCandidate = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative
      if (Test-ToolkitPathIsRegularFile -Path $sourceCandidate) { $reference = $sourceCandidate }
      if ([string]::IsNullOrEmpty($reference) -and -not [string]::IsNullOrEmpty($StateDirectory)) {
        $pristineCandidate = Get-ToolkitPristineFullPath -StateDirectory $StateDirectory -RelativePath $relative
        if (Test-ToolkitPathIsRegularFile -Path $pristineCandidate) { $reference = $pristineCandidate }
      }
      $directory = Split-Path -Parent $destination
      if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
      $leaf = [System.IO.Path]::GetFileName($destination)
      foreach ($candidate in @(Get-ChildItem -LiteralPath $directory -Force -File -ErrorAction SilentlyContinue)) {
        if ($candidate.Name -notmatch ('^\.' + [regex]::Escape($leaf) + '\.toolkit-tmp-[0-9a-f]{32}$')) { continue }
        if ([string]::IsNullOrEmpty($reference) -or -not (Test-ToolkitFileContentEqual -PathA $candidate.FullName -PathB $reference)) {
          [void]$problems.Add('left an unrecognized temporary file in place: ' + (Get-ToolkitSafePath -Path (($relative -replace '[^/]+$', '') + $candidate.Name)))
          continue
        }
        Remove-Item -LiteralPath $candidate.FullName -Force
      }
    }
    catch {
      [void]$problems.Add('temporary cleanup failed for ' + (Get-ToolkitSafePath -Path $relative) + ': ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }
  return $problems.ToArray()
}

function Invoke-ToolkitUninstallRollback {
  <#
    Reverse a half-finished uninstall: move every quarantined file back. A file that appeared
    at the destination in the meantime is a concurrent user file: it is never deleted, the
    recovered original is kept as transaction evidence, and the rollback is reported as
    incomplete so a human reconciles it.
  #>
  param(
    $Transaction,
    [string]$TargetRoot,
    [object]$Plan
  )

  $problems = New-Object System.Collections.ArrayList
  $keepEvidence = $false
  if ($null -eq $Transaction) {
    return (New-ToolkitJsonObject -Properties @{ Ok = $false; Problems = @('no transaction to roll back'); KeepEvidence = $true })
  }

  $quarantine = Join-Path $Transaction.Directory $script:TKQuarantineDirectoryName
  if (-not (Test-Path -LiteralPath $quarantine -PathType Container)) {
    return (New-ToolkitJsonObject -Properties @{ Ok = $true; Problems = @(); KeepEvidence = $false })
  }

  # Untrusted evidence: every path is validated before a single move happens.
  $validatedSeen = @{}
  $deletable = New-Object System.Collections.ArrayList
  foreach ($record in @(Assert-ToolkitJsonArray -Object $Plan -Name 'Deletable' -What 'Uninstall recovery plan' -ExitCode $script:TKExitRollback -AllowMissing)) {
    $relative = Get-ToolkitValidatedJournalPath -TargetRoot $TargetRoot -RelativePath ([string](Get-ToolkitMember -Object $record -Name 'path' -Default '')) -Seen $validatedSeen -Origin 'uninstall plan'
    [void]$deletable.Add((New-ToolkitJsonObject -Properties @{ path = $relative }))
  }

  foreach ($record in $deletable) {
    $relative = [string](Get-ToolkitMember -Object $record -Name 'path' -Default '')
    if ([string]::IsNullOrEmpty($relative)) { continue }
    $quarantinePath = Join-Path $quarantine (ConvertTo-ToolkitNativePath -RelativePath $relative)
    if (-not (Test-Path -LiteralPath $quarantinePath -PathType Leaf)) { continue }
    try {
      $destination = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative
      if (Test-Path -LiteralPath $destination) {
        $keepEvidence = $true
        [void]$problems.Add('a file exists at ' + (Get-ToolkitSafePath -Path $relative) + ' and was preserved; the recovered original is kept in the transaction directory')
        continue
      }
      $destinationDirectory = Split-Path -Parent $destination
      if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
      }
      [System.IO.File]::Move($quarantinePath, $destination)
      # The quarantined copy IS the reference: moving must not change a single byte.
      if (Test-Path -LiteralPath $quarantinePath -PathType Leaf) {
        if (-not (Test-ToolkitFileContentEqual -PathA $destination -PathB $quarantinePath)) {
          [void]$problems.Add('restored content mismatch for ' + (Get-ToolkitSafePath -Path $relative))
        }
      }
    }
    catch {
      $keepEvidence = $true
      [void]$problems.Add('restore failed for ' + (Get-ToolkitSafePath -Path $relative) + ': ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }

  return (New-ToolkitJsonObject -Properties @{
      Ok           = ($problems.Count -eq 0)
      Problems     = @($problems.ToArray())
      KeepEvidence = $keepEvidence
    })
}

function Remove-ToolkitEmptyDirectories {
  param(
    [string]$Root,
    [object[]]$RelativeDirectories,
    [object]$ProtectedDirectories = @()
  )

  $removed = New-Object System.Collections.ArrayList
  $protected = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($item in @($ProtectedDirectories)) { [void]$protected.Add(([string]$item).ToLowerInvariant()) }

  $ordered = @($RelativeDirectories | Sort-Object -Property @{ Expression = { $_.Length } } -Descending)
  foreach ($relative in $ordered) {
    $normalized = ([string]$relative).Replace('\', '/').Trim('/')
    if ([string]::IsNullOrEmpty($normalized)) { continue }
    if ($protected.Contains($normalized.ToLowerInvariant())) { continue }
    $full = Get-ToolkitFullPath -Root $Root -RelativePath $normalized
    try {
      if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
      # Re-check for a reparse point immediately before removing: the directory may have been
      # swapped for a junction/link after the plan was built.
      $item = Get-ToolkitItemOrNull -Path $full
      if ($null -eq $item -or -not ($item -is [System.IO.DirectoryInfo])) { continue }
      if (Test-ToolkitReparseItem -Item $item) {
        Write-ToolkitLine ('Refusing to remove a directory that is now a symlink / junction / reparse point: ' + (Get-ToolkitSafePath -Path $normalized)) 'Warn'
        continue
      }
      $children = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)
      if ($children.Count -eq 0) {
        Remove-Item -LiteralPath $full -Force
        [void]$removed.Add($normalized)
      }
    }
    catch {
      # Leaving a non-empty or locked directory in place is always the safe outcome.
    }
  }
  return $removed.ToArray()
}

# ---------------------------------------------------------------------------
# Runtime Team Home (owned path + marker)
# ---------------------------------------------------------------------------

function Test-ToolkitLegacyTeamHomeMarker {
  <#
    The superseded marker (.codex-dsh-team-runtime.json / codex-dsh-team-toolkit/runtime-marker/v1)
    is no longer ownership proof in either direction. Its presence is reported so the caller can
    fail closed instead of quietly adopting a stale directory.
  #>
  param([string]$Root)

  $legacyPath = Join-Path $Root $script:TKLegacyRuntimeMarkerName
  if (-not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { return $null }
  return $legacyPath
}

function Read-ToolkitTeamHomeMarker {
  <#
    Reads and strictly validates the shared Team Home ownership marker.

    Contract (identical to the Node runtime):
      file    .codex-dsh-team-home.json
      schema  codex-dsh-team-home/v1
      fields  schema, toolkitId, installId, createdAt, purpose (all non-empty strings)
      purpose dsh-team-runtime-home
      toolkitId codex-dsh-team-toolkit

    A directory carrying the legacy marker, or both markers, is refused: no migration, no
    dual-marker state on disk, no partial marker accepted.
  #>
  param([string]$Root)

  $legacy = Test-ToolkitLegacyTeamHomeMarker -Root $Root
  if ($null -ne $legacy) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message 'This directory carries the superseded Team runtime marker, which is no longer ownership proof. Refusing to adopt it; nothing was written.' `
      -Detail ('path=' + (Get-ToolkitSafePath -Path $Root))
  }

  $markerPath = Join-Path $Root $script:TKTeamHomeMarkerName
  if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { return $null }

  $item = Get-ToolkitItemOrNull -Path $markerPath
  if (Test-ToolkitReparseItem -Item $item) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'The Team Home marker is a symlink / reparse point; refusing to trust it.' -Detail ('path=' + (Get-ToolkitSafePath -Path $markerPath))
  }

  $marker = Read-ToolkitJsonFile -Path $markerPath -ExitCode $script:TKExitBlocked -What 'Team Home ownership marker'
  foreach ($field in $script:TKTeamHomeMarkerFields) {
    $value = [string](Get-ToolkitMember -Object $marker -Name $field -Default '')
    if ([string]::IsNullOrWhiteSpace($value)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message ('The Team Home marker is missing the required field "' + $field + '"; refusing to adopt this directory.') `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $markerPath))
    }
  }
  $schema = [string](Get-ToolkitMember -Object $marker -Name 'schema' -Default '')
  $toolkitId = [string](Get-ToolkitMember -Object $marker -Name 'toolkitId' -Default '')
  $purpose = [string](Get-ToolkitMember -Object $marker -Name 'purpose' -Default '')
  if ($schema -ne $script:TKTeamHomeMarkerSchema) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('The Team Home marker schema "' + $schema + '" is not supported (expected ' + $script:TKTeamHomeMarkerSchema + ').') -Detail ('path=' + (Get-ToolkitSafePath -Path $markerPath))
  }
  if ($toolkitId -ne $script:TKToolkitName) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('The Team Home marker belongs to toolkit "' + $toolkitId + '", not ' + $script:TKToolkitName + '.') -Detail ('path=' + (Get-ToolkitSafePath -Path $markerPath))
  }
  if ($purpose -ne $script:TKTeamHomeMarkerPurpose) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('The Team Home marker purpose "' + $purpose + '" is not ' + $script:TKTeamHomeMarkerPurpose + '.') -Detail ('path=' + (Get-ToolkitSafePath -Path $markerPath))
  }

  return (New-ToolkitJsonObject -Properties @{
      schema     = $schema
      toolkitId  = $toolkitId
      installId  = [string](Get-ToolkitMember -Object $marker -Name 'installId' -Default '')
      createdAt  = [string](Get-ToolkitMember -Object $marker -Name 'createdAt' -Default '')
      purpose    = $purpose
      markerPath = $markerPath
    })
}

function New-ToolkitTeamHomeMarker {
  param(
    [string]$InstallId,
    [string]$CreatedAt = ''
  )

  if ([string]::IsNullOrWhiteSpace($InstallId)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'A Team Home marker needs an installId.'
  }
  if ([string]::IsNullOrWhiteSpace($CreatedAt)) { $CreatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ') }
  return (New-ToolkitJsonObject -Properties @{
      schema    = $script:TKTeamHomeMarkerSchema
      toolkitId = $script:TKToolkitName
      installId = $InstallId
      createdAt = $CreatedAt
      purpose   = $script:TKTeamHomeMarkerPurpose
    })
}

function Get-ToolkitInstallIdentity {
  <#
    The stable, machine-level install identity shared with the Node runtime
    (<base>/install.json, schema codex-dsh-team-install/v1). The same installId keys the
    project ledger, the Team Home marker and the runtime root.

    An existing identity file that does not validate is fail-closed: it is ownership
    evidence, so it is never silently replaced.
  #>
  param(
    [string]$BaseDirectory,
    [switch]$ValidateOnly
  )

  if ([string]::IsNullOrWhiteSpace($BaseDirectory)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'The toolkit base directory must be an absolute local path.'
  }
  $base = [System.IO.Path]::GetFullPath($BaseDirectory)
  $identityPath = Join-Path $base $script:TKInstallIdentityName

  if (Test-Path -LiteralPath $identityPath -PathType Leaf) {
    $identity = Read-ToolkitJsonFile -Path $identityPath -ExitCode $script:TKExitBlocked -What 'Toolkit install identity'
    $schema = [string](Get-ToolkitMember -Object $identity -Name 'schema' -Default '')
    $toolkitId = [string](Get-ToolkitMember -Object $identity -Name 'toolkitId' -Default '')
    $installId = [string](Get-ToolkitMember -Object $identity -Name 'installId' -Default '')
    if ($schema -ne $script:TKInstallIdentitySchema -or $toolkitId -ne $script:TKToolkitName -or [string]::IsNullOrWhiteSpace($installId)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message 'The toolkit install identity file exists but does not validate; refusing to replace ownership evidence. Resolve it by hand.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $identityPath))
    }
    return (New-ToolkitJsonObject -Properties @{
        InstallId    = $installId
        IdentityPath = $identityPath
        Created      = $false
        BaseDirectory = $base
      })
  }

  if ($ValidateOnly) {
    return (New-ToolkitJsonObject -Properties @{
        InstallId    = ''
        IdentityPath = $identityPath
        Created      = $false
        MustCreate   = $true
        BaseDirectory = $base
      })
  }

  New-Item -ItemType Directory -Path $base -Force | Out-Null
  $identityObject = New-ToolkitJsonObject -Properties @{
    schema    = $script:TKInstallIdentitySchema
    toolkitId = $script:TKToolkitName
    installId = [guid]::NewGuid().ToString()
    createdAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    purpose   = $script:TKInstallIdentityPurpose
  }
  Write-ToolkitJsonAtomic -Object $identityObject -Destination $identityPath
  return (New-ToolkitJsonObject -Properties @{
      InstallId    = [string]$identityObject.installId
      IdentityPath = $identityPath
      Created      = $true
      BaseDirectory = $base
    })
}

function Test-ToolkitLooksLikeUserDshHome {
  param([string]$Root)

  foreach ($candidate in @('settings.yaml', 'settings.yml', '.credentials.yaml', 'credentials.json', 'auth.json')) {
    if (Test-Path -LiteralPath (Join-Path $Root $candidate)) { return $true }
  }
  foreach ($pattern in @('sessions', 'storages', 'logs', 'history')) {
    if (Test-Path -LiteralPath (Join-Path $Root $pattern)) { return $true }
  }
  return $false
}

function Resolve-ToolkitRuntimeContext {
  <#
    Validates (and, when not in plan-only mode, prepares) the toolkit-owned Team Home using the
    marker contract shared with the Node runtime. An existing directory without a valid marker,
    with a legacy marker, or that looks like a real DSH Home is always refused.
  #>
  param(
    [hashtable]$Options,
    [string]$InstallId,
    [switch]$ValidateOnly
  )

  $requested = [string]$Options['TeamDshHome']
  $initialize = [bool]$Options['InitializeRuntime']
  if ([string]::IsNullOrEmpty($requested) -and -not $initialize) {
    return (New-ToolkitJsonObject -Properties @{
        Enabled        = $false
        Root           = ''
        InstallId      = $InstallId
        MustCreate     = $false
        ExistingMarker = $null
        IdentityPath   = ''
      })
  }

  $base = [string]$Options['RuntimeRootBase']
  if ([string]::IsNullOrEmpty($base)) { $base = Join-Path $env:LOCALAPPDATA $script:TKRuntimeBaseFolder }
  if (-not (Test-ToolkitAbsoluteLocalPath -Path $base)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'The runtime root base must be an absolute local path.'
  }
  $base = [System.IO.Path]::GetFullPath($base)

  # The ownership identity comes from the shared install manifest, never from a directory name.
  $identity = Get-ToolkitInstallIdentity -BaseDirectory $base -ValidateOnly:$ValidateOnly
  $identityInstallId = [string]$identity.InstallId
  # In a dry run the identity may not exist yet: the preview keeps the caller's install id and
  # the real identity is created (and adopted) during the transaction.
  if ([string]::IsNullOrWhiteSpace($identityInstallId)) { $identityInstallId = $InstallId }

  if (-not [string]::IsNullOrEmpty($requested)) {
    if (-not (Test-ToolkitAbsoluteLocalPath -Path $requested)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message '-TeamDshHome must be an absolute local path.'
    }
    $root = [System.IO.Path]::GetFullPath($requested)
  }
  else {
    $root = Join-Path (Join-Path $base $script:TKRuntimeFolder) $identityInstallId
  }

  # Parent chain must be free of reparse points before we consider writing there.
  $parent = Split-Path -Parent $root
  while (-not [string]::IsNullOrEmpty($parent)) {
    $item = Get-ToolkitItemOrNull -Path $parent
    if ($null -ne $item) {
      if (Test-ToolkitReparseItem -Item $item) {
        Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'The Team Home parent chain contains a symlink / junction / reparse point.' -Detail ('path=' + (Get-ToolkitSafePath -Path $parent))
      }
    }
    $next = Split-Path -Parent $parent
    if ($next -eq $parent) { break }
    $parent = $next
  }

  $exists = Test-Path -LiteralPath $root -PathType Container
  if ($exists) {
    $existingItem = Get-ToolkitItemOrNull -Path $root
    if (Test-ToolkitReparseItem -Item $existingItem) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'The Team Home is a symlink / junction / reparse point; refusing to write there.' -Detail ('path=' + (Get-ToolkitSafePath -Path $root))
    }
    $marker = Read-ToolkitTeamHomeMarker -Root $root
    if ($null -eq $marker) {
      if (Test-ToolkitLooksLikeUserDshHome -Root $root) {
        Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message '-TeamDshHome points at something that looks like a real DSH Home. The user DSH Home is read-only and is never adopted, patched or reconfigured.' -Detail ('path=' + (Get-ToolkitSafePath -Path $root))
      }
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message '-TeamDshHome points at an existing directory without a valid Team Home marker; refusing to adopt it.' -Detail ('path=' + (Get-ToolkitSafePath -Path $root))
    }
    if ([string]$marker.installId -ne $identityInstallId) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message 'The Team Home marker belongs to a different installation of this toolkit; refusing to write into it.' `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $root) + ' expectedInstallId=' + $identityInstallId)
    }
    return (New-ToolkitJsonObject -Properties @{
        Enabled        = $true
        Root           = $root
        InstallId      = [string]$marker.installId
        IdentityInstallId = $identityInstallId
        IdentityPath   = [string]$identity.IdentityPath
        MustCreate     = $false
        ExistingMarker = $marker
      })
  }

  if ($ValidateOnly) {
    return (New-ToolkitJsonObject -Properties @{
        Enabled        = $true
        Root           = $root
        InstallId      = $identityInstallId
        IdentityInstallId = $identityInstallId
        IdentityPath   = [string]$identity.IdentityPath
        MustCreate     = $true
        ExistingMarker = $null
      })
  }

  New-Item -ItemType Directory -Path $root -Force | Out-Null
  $markerObject = New-ToolkitTeamHomeMarker -InstallId $identityInstallId
  Write-ToolkitJsonAtomic -Object $markerObject -Destination (Join-Path $root $script:TKTeamHomeMarkerName)
  # Never leave a superseded marker behind: one contract, one marker file.
  $legacy = Test-ToolkitLegacyTeamHomeMarker -Root $root
  if ($null -ne $legacy) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'A legacy Team runtime marker exists next to the new Team Home marker; refusing to continue with both on disk.' -Detail ('path=' + (Get-ToolkitSafePath -Path $root))
  }
  return (New-ToolkitJsonObject -Properties @{
      Enabled        = $true
      Root           = $root
      InstallId      = $identityInstallId
      IdentityInstallId = $identityInstallId
      IdentityPath   = [string]$identity.IdentityPath
      MustCreate     = $false
      ExistingMarker = $markerObject
      Created        = $true
    })
}

# ---------------------------------------------------------------------------
# Install / upgrade plan
# ---------------------------------------------------------------------------

function Assert-ToolkitPackagePreflight {
  <#
    Complete, read-only package preflight: every managed source must exist and must be a
    regular file (never a symlink/reparse point), and the package must be internally consistent
    (no two managed entries may resolve to the same source bytes requirement).

    No digest is computed or compared: the package IS the source of the bytes that get
    installed, and integrity of the distributed archive is outside the installer's guarantee.
    This runs before the plan is displayed and also in -PlanOnly mode, so a dry run performs
    exactly the same validation as a real run (and writes nothing).
  #>
  param([object]$ReleaseManifest)

  if ($null -eq $ReleaseManifest) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'Release manifest is not loaded; package preflight cannot run.'
  }
  $packageRoot = [string]$ReleaseManifest.packageRoot
  $rootItem = Get-ToolkitItemOrNull -Path $packageRoot
  if ($null -eq $rootItem -or -not ($rootItem -is [System.IO.DirectoryInfo])) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'The package root is not a directory; nothing was written.' -Detail ('path=' + (Get-ToolkitSafePath -Path $packageRoot))
  }
  if (Test-ToolkitReparseItem -Item $rootItem) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'The package root is a symlink / junction / reparse point; nothing was written.' -Detail ('path=' + (Get-ToolkitSafePath -Path $packageRoot))
  }

  $checked = 0
  foreach ($entry in @($ReleaseManifest.files)) {
    $sourceRelative = [string]$entry.source
    $source = Assert-ToolkitPathInsideRoot -Root $packageRoot -FullPath (Get-ToolkitFullPath -Root $packageRoot -RelativePath $sourceRelative) -RelativePath $sourceRelative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'A managed source file is missing from the package; nothing was written.' -Detail ('path=' + (Get-ToolkitSafePath -Path $sourceRelative))
    }
    $item = Get-ToolkitItemOrNull -Path $source
    if (Test-ToolkitReparseItem -Item $item) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'A managed source file is a symlink / reparse point; nothing was written.' -Detail ('path=' + (Get-ToolkitSafePath -Path $sourceRelative))
    }
    if (-not (Test-ToolkitPathIsRegularFile -Path $source)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'A managed source is not a regular readable file; nothing was written.' -Detail ('path=' + (Get-ToolkitSafePath -Path $sourceRelative))
    }
    $checked++
  }
  if ($checked -eq 0) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'The release manifest lists no usable files; nothing was written.'
  }
}

function Get-ToolkitDirectoryChildrenIndex {
  param(
        [hashtable]$Cache,
    [string]$Directory
  )

  $key = $Directory.ToLowerInvariant()
  if ($Cache.ContainsKey($key)) { return $Cache[$key] }
  $map = @{}
  foreach ($child in @(Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue)) {
    $map[$child.Name.ToLowerInvariant()] = $child.Name
  }
  $Cache[$key] = $map
  return $map
}

function Assert-ToolkitNoCaseFoldConflict {
  param(
    [string]$Root,
    [string]$RelativePath
  )

  $current = [System.IO.Path]::GetFullPath($Root)
  $segments = @((ConvertTo-ToolkitNativePath -RelativePath $RelativePath).Split('\'))
  for ($i = 0; $i -lt $segments.Count; $i++) {
    $segment = $segments[$i]
    if ([string]::IsNullOrEmpty($segment)) { continue }
    $index = Get-ToolkitDirectoryChildrenIndex -Cache $script:TKChildIndexCache -Directory $current
    if ($index.ContainsKey($segment.ToLowerInvariant())) {
      $actual = [string]$index[$segment.ToLowerInvariant()]
      if ($actual -cne $segment) {
        Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
          -Message 'A path segment differs only by letter case from what already exists on disk; refusing to create a case-folded duplicate.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $RelativePath))
      }
    }
    $current = Join-Path $current $segment
    if (-not (Test-Path -LiteralPath $current -PathType Container)) { break }
  }
}

function New-ToolkitInstallPlan {
  <#
    Ownership decisions are made by direct byte comparison against the pristine baseline this
    toolkit installed. Nothing is hashed:
      * destination missing                        -> create
      * destination differs from pristine          -> user edit: fail closed, file preserved
      * destination equals pristine, equals source -> same (verified no-op)
      * destination equals pristine, differs       -> replace
  #>
  param(
    [string]$TargetRoot,
    [string]$StateDirectory,
    [object]$ReleaseManifest,
    $OwnershipManifest
  )

  $script:TKChildIndexCache = @{}
  $ownIndex = @{}
  if ($null -ne $OwnershipManifest) {
    foreach ($file in @($OwnershipManifest.files)) {
      $ownIndex[([string]$file.path).ToLowerInvariant()] = $true
    }
  }

  $operations = New-Object System.Collections.ArrayList
  $createdDirectories = New-Object System.Collections.ArrayList
  $notes = New-Object System.Collections.ArrayList
  $releasePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $newFileRecords = New-Object System.Collections.ArrayList

  foreach ($entry in @($ReleaseManifest.files)) {
    $relative = Assert-ToolkitRelativePath -Path ([string]$entry.path)
    Assert-ToolkitPathNotDenied -RelativePath $relative
    [void]$releasePaths.Add($relative)

    $sourceAbsolute = Assert-ToolkitPathInsideRoot -Root $ReleaseManifest.packageRoot -FullPath (Get-ToolkitFullPath -Root $ReleaseManifest.packageRoot -RelativePath ([string]$entry.source)) -RelativePath ([string]$entry.source)
    $destination = Assert-ToolkitPathInsideRoot -Root $TargetRoot -FullPath (Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative) -RelativePath $relative

    Assert-ToolkitNoReparseInPath -Root $TargetRoot -RelativePath $relative
    Assert-ToolkitNoCaseFoldConflict -Root $TargetRoot -RelativePath $relative

    # Parent chain must not contain a file; record directories we are about to create.
    $segments = @($relative.Split('/'))
    if ($segments.Count -gt 1) {
      $parentPath = $TargetRoot
      $prefix = ''
      for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
        $parentPath = Join-Path $parentPath $segments[$index]
        if ([string]::IsNullOrEmpty($prefix)) { $prefix = $segments[$index] }
        else { $prefix = $prefix + '/' + $segments[$index] }
        $parentItem = Get-ToolkitItemOrNull -Path $parentPath
        if ($null -ne $parentItem -and -not ($parentItem -is [System.IO.DirectoryInfo])) {
          Throw-ToolkitFailure -ExitCode $script:TKExitConflict -Message 'A file already occupies a directory position required by the install plan.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
        }
        if ($null -eq $parentItem) {
          [void]$createdDirectories.Add($prefix)
        }
      }
    }

    $leafItem = Get-ToolkitItemOrNull -Path $destination
    if ($null -ne $leafItem -and ($leafItem -is [System.IO.DirectoryInfo])) {
      Throw-ToolkitFailure -ExitCode $script:TKExitConflict -Message 'A directory already exists where the install plan needs a file.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
    }

    $action = 'create'
    if ($null -ne $leafItem) {
      if (-not $ownIndex.ContainsKey($relative.ToLowerInvariant())) {
        Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
          -Message 'An unknown file with the same name already exists and is not owned by this toolkit. Nothing was overwritten.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      if (-not (Test-ToolkitPathIsRegularFile -Path $destination)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
          -Message 'A managed path is no longer a regular file (symlink, reparse point or special file). Nothing was overwritten.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      if (-not (Test-ToolkitPristineMatches -StateDirectory $StateDirectory -RelativePath $relative -TargetPath $destination)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
          -Message 'A managed file was modified by the user, or its pristine baseline is missing. Upgrade is blocked and the file is preserved.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      if (Test-ToolkitFileContentEqual -PathA $destination -PathB $sourceAbsolute) { $action = 'same' }
      else { $action = 'replace' }
    }

    [void]$operations.Add((New-ToolkitJsonObject -Properties @{
          path        = $relative
          action      = $action
          source      = [string]$entry.source
          sourceFull  = $sourceAbsolute
          destination = $destination
        }))
    [void]$newFileRecords.Add((New-ToolkitJsonObject -Properties @{
          path = $relative
        }))
  }

  # Ownership entries that are no longer part of this release.
  if ($null -ne $OwnershipManifest) {
    foreach ($file in @($OwnershipManifest.files)) {
      $relative = Assert-ToolkitRelativePath -Path ([string]$file.path)
      Assert-ToolkitPathNotDenied -RelativePath $relative
      if ($releasePaths.Contains($relative)) { continue }
      $destination = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative
      Assert-ToolkitNoReparseInPath -Root $TargetRoot -RelativePath $relative
      $item = Get-ToolkitItemOrNull -Path $destination
      if ($null -eq $item) {
        [void]$notes.Add('retained entry no longer present on disk: ' + (Get-ToolkitSafePath -Path $relative))
        continue
      }
      if (-not ($item -is [System.IO.FileInfo])) {
        Throw-ToolkitFailure -ExitCode $script:TKExitConflict -Message 'A managed file path is now a directory; refusing to continue.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      if (-not (Test-ToolkitPristineMatches -StateDirectory $StateDirectory -RelativePath $relative -TargetPath $destination)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitConflict `
          -Message 'A managed file that is absent from this release was modified by the user. Upgrade is blocked and the file is preserved.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      [void]$notes.Add('retained (still owned, not part of this release): ' + (Get-ToolkitSafePath -Path $relative))
      [void]$newFileRecords.Add((New-ToolkitJsonObject -Properties @{
            path = $relative
          }))
    }
  }

  return (New-ToolkitJsonObject -Properties @{
      TargetRoot          = $TargetRoot
      PackageRoot         = $ReleaseManifest.packageRoot
      Version             = $ReleaseManifest.version
      Operations          = $operations.ToArray()
      NewFiles            = $newFileRecords.ToArray()
      CreatedDirectories  = @($createdDirectories | Sort-Object -Unique)
      Notes               = $notes.ToArray()
      JournalPaths        = @($operations | Where-Object { $_.action -ne 'same' } | ForEach-Object { New-ToolkitJsonObject -Properties @{ path = $_.path; action = $_.action } })
    })
}

function Show-ToolkitInstallPlan {
  param(
    [object]$Plan,
    [string]$Mode
  )

  if ($null -eq $Plan) {
    Write-ToolkitLine 'Install plan: no file operations can be planned yet.'
    Write-ToolkitLine ('Mode           : ' + $Mode)
    Write-ToolkitLine 'An interrupted transaction will be replayed first; the exact plan is shown again after recovery (and re-confirmed when it changed).'
    Write-ToolkitLine ''
    return
  }

  Write-ToolkitLine ('Codex x DSH Team Toolkit ' + $Plan.Version)
  Write-ToolkitLine ('Target project : ' + (Get-ToolkitSafePath -Path $Plan.TargetRoot))
  Write-ToolkitLine ('Package root   : ' + (Get-ToolkitSafePath -Path $Plan.PackageRoot))
  Write-ToolkitLine ('Mode           : ' + $Mode)
  Write-ToolkitLine ''
  $counts = @{ create = 0; replace = 0; same = 0 }
  foreach ($operation in @($Plan.Operations)) {
    $counts[[string]$operation.action] = [int]$counts[[string]$operation.action] + 1
  }
  Write-ToolkitLine ('Planned file operations: ' + @($Plan.Operations).Count +
    ' (create ' + $counts['create'] + ', replace ' + $counts['replace'] + ', unchanged ' + $counts['same'] + ')')
  foreach ($operation in @($Plan.Operations)) {
    Write-ToolkitLine ('  ' + ([string]$operation.action).PadRight(8) + (Get-ToolkitSafePath -Path ([string]$operation.path)))
  }
  foreach ($note in @($Plan.Notes)) {
    Write-ToolkitLine ('  note     ' + (Get-ToolkitSafePath -Path ([string]$note)))
  }
  Write-ToolkitLine ''
  Write-ToolkitLine 'No file contents are read into the plan, journal, backup or log.'
}

# ---------------------------------------------------------------------------
# Install / upgrade action
# ---------------------------------------------------------------------------

function Invoke-ToolkitInstallAction {
  param([hashtable]$Options)

  $enginePath = Get-ToolkitEngineSelfPath
  $targetArgument = [string]$Options['Target']
  if ([string]::IsNullOrEmpty($targetArgument)) {
    $targetArgument = Select-ToolkitFolderInteractive
    if ([string]::IsNullOrEmpty($targetArgument)) {
      Write-ToolkitLine 'Cancelled by the user: no target selected, nothing was written.' 'Warn'
      return $script:TKExitOk
    }
  }
  $targetRoot = Resolve-ToolkitTargetPath -Path $targetArgument

  $packageRoot = Resolve-ToolkitPackageRoot -Options $Options
  $manifestPath = Resolve-ToolkitReleaseManifestPath -Options $Options -PackageRoot $packageRoot
  $releaseManifest = Read-ToolkitReleaseManifest -Path $manifestPath
  $releaseManifest | Add-Member -NotePropertyName packageRoot -NotePropertyValue $packageRoot -Force
  $releaseManifest | Add-Member -NotePropertyName manifestPath -NotePropertyValue $manifestPath -Force

  $stateDirectory = Join-Path $targetRoot $script:TKStateDirectory
  $ownershipManifestPath = Join-Path $stateDirectory $script:TKManifestName

  $stateItem = Get-ToolkitItemOrNull -Path $stateDirectory
  if ($null -ne $stateItem -and -not ($stateItem -is [System.IO.DirectoryInfo])) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'The toolkit state path exists but is not a directory.' -Detail ('path=' + (Get-ToolkitSafePath -Path $stateDirectory))
  }

  # NEW-1: one unified pre-check of every state sub-root before this run reads, writes or replays
  # anything. A root occupied by a file is reported here and preserved (NEW-2); a reparse point
  # fails closed with remediation.
  $occupiedStateRoots = @(Assert-ToolkitStateRootsSafe -StateDirectory $stateDirectory)
  foreach ($occupiedRoot in $occupiedStateRoots) {
    Write-ToolkitLine ('The state root "' + [string]$occupiedRoot + '" is occupied by a file, not a directory; it is preserved and will be reported, never deleted.') 'Warn'
  }

  $ownershipManifest = $null
  $stateDirectoryHasLeftoversOnly = $false
  if ($null -ne $stateItem) {
    Assert-ToolkitNoReparseInPath -Root $targetRoot -RelativePath $script:TKStateDirectory
    if (-not (Test-Path -LiteralPath $ownershipManifestPath -PathType Leaf)) {
      # No ledger. This is only acceptable when the directory holds nothing but toolkit-owned
      # leftovers from an interrupted run (lock/log/journal). Anything unknown stays fail-closed
      # so a user directory with the same name is never taken over.
      $unknownStateEntries = @(Get-ToolkitUnknownStateEntries -StateDirectory $stateDirectory)
      if ($unknownStateEntries.Count -gt 0) {
        foreach ($entry in $unknownStateEntries) {
          Write-ToolkitLine ('  unknown state entry: ' + (Get-ToolkitSafePath -Path ([string]$entry))) 'Error'
        }
        Throw-ToolkitFailure -ExitCode $script:TKExitManifest `
          -Message 'A toolkit state directory exists without an ownership manifest and contains unknown content. Fail-closed: nothing was written.' `
          -Detail ('path=' + (Get-ToolkitSafePath -Path $stateDirectory))
      }
      $stateDirectoryHasLeftoversOnly = $true
      Write-ToolkitLine 'The state directory holds only toolkit-owned leftovers from an interrupted run; they will be recovered and reused.' 'Warn'
    }
    else {
      $ownershipManifest = Read-ToolkitOwnershipManifest -Path $ownershipManifestPath
    }
  }

  $installId = ''
  if ($null -ne $ownershipManifest) { $installId = [string]$ownershipManifest.installId }
  if ([string]::IsNullOrEmpty($installId)) { $installId = [guid]::NewGuid().ToString() }

  $runtimeContext = Resolve-ToolkitRuntimeContext -Options $Options -InstallId $installId -ValidateOnly
  if (-not [string]::IsNullOrEmpty([string]$runtimeContext.InstallId)) { $installId = [string]$runtimeContext.InstallId }

  # ---- complete package preflight (read-only, always before any plan is shown) ----
  Assert-ToolkitPackagePreflight -ReleaseManifest $releaseManifest
  Write-ToolkitLine 'Package preflight complete: every managed source exists as a regular file and the package is internally consistent.' 'Detail'

  $orphanCount = 0
  if ($null -ne $stateItem) { $orphanCount = @(Get-ToolkitOrphanTransactions -StateDirectory $stateDirectory).Count }

  # ---- read-only preview plan (no state directory, no lock, no runtime, no writes) ----
  $previewPlan = $null
  $previewBlockedByRecovery = $false
  try {
    $previewPlan = New-ToolkitInstallPlan -TargetRoot $targetRoot -StateDirectory $stateDirectory -ReleaseManifest $releaseManifest -OwnershipManifest $ownershipManifest
  }
  catch {
    $previewExit = Get-ToolkitExitCodeFromException -Exception $_.Exception
    if ($orphanCount -gt 0 -and $previewExit -eq $script:TKExitConflict) {
      # An interrupted transaction explains the conflict: the plan can only be accurate after
      # the in-lock replay, which is a write and therefore happens after confirmation.
      $previewBlockedByRecovery = $true
      Write-ToolkitLine 'The current on-disk state conflicts with this release; it is explained by interrupted transaction evidence that a real run recovers first.' 'Warn'
    }
    else {
      throw
    }
  }

  if ([bool]$Options['PlanOnly']) {
    # A dry run performs the same read-only package preflight, shows the plan and writes nothing.
    if ($previewBlockedByRecovery) {
      Write-ToolkitLine ('Plan preview is unavailable until the interrupted transaction is replayed; ' + $orphanCount + ' evidence directory(ies) found. This dry run will not write anything.') 'Warn'
    }
    else {
      if ($null -eq $ownershipManifest) { $previewMode = 'install plan (dry run, zero writes)' }
      else { $previewMode = 'upgrade plan ' + [string]$ownershipManifest.version + ' -> ' + [string]$releaseManifest.version + ' (dry run, zero writes)' }
      Show-ToolkitInstallPlan -Plan $previewPlan -Mode $previewMode
    }
    if ($orphanCount -gt 0) {
      Write-ToolkitLine ('Interrupted transaction evidence found: ' + $orphanCount + ' (a real run recovers it first, under the exclusive lock, before planning).') 'Warn'
    }
    if ($stateDirectoryHasLeftoversOnly) {
      Write-ToolkitLine 'Toolkit state leftovers without a ledger were found; they are recovered and reused, not treated as an install.' 'Warn'
    }
    Write-ToolkitLine 'Plan-only mode: nothing was written (the full package preflight above already ran read-only).' 'Warn'
    return $script:TKExitOk
  }

  # ---- confirmation gate: still zero writes (no state directory, no lock, no runtime) ----
  if ($previewBlockedByRecovery) {
    Show-ToolkitInstallPlan -Plan $null -Mode ('install plan (pending recovery of ' + $orphanCount + ' interrupted transaction(s))')
  }
  else {
    if ($null -eq $ownershipManifest) { $confirmMode = 'install plan (awaiting confirmation)' }
    else { $confirmMode = 'upgrade plan ' + [string]$ownershipManifest.version + ' -> ' + [string]$releaseManifest.version + ' (awaiting confirmation)' }
    Show-ToolkitInstallPlan -Plan $previewPlan -Mode $confirmMode
  }
  $operationLabel = 'the install'
  if ($null -ne $ownershipManifest) { $operationLabel = 'the upgrade' }
  $confirmed = Read-ToolkitConfirmation -Operation $operationLabel -AlreadyConfirmed:([bool]$Options['Yes'])
  if (-not $confirmed) {
    Write-ToolkitLine 'Cancelled by the user: nothing was written.' 'Warn'
    return $script:TKExitOk
  }
  $confirmedSignature = ''
  if (-not $previewBlockedByRecovery) { $confirmedSignature = Get-ToolkitPlanSignature -Plan $previewPlan }

  # ---- transaction (writes start here) ----
  $createdState = $false
  $removeCreatedState = $false
  if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
    Assert-ToolkitNoReparseInPath -Root $targetRoot -RelativePath ''
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    $createdState = $true
  }
  Write-ToolkitStateGitIgnore -StateDirectory $stateDirectory
  $script:TKLogPath = Join-Path $stateDirectory $script:TKLogName
  $script:TKLogEnabled = $true

  $lock = $null
  $transaction = $null
  $runtimeCreated = $false
  $plan = $null
  $ownershipManifestBytes = $null
  try {
    $lock = Enter-ToolkitLock -StateDirectory $stateDirectory -ClearStaleLock:([bool]$Options['ClearStaleLock'])

    # Anything an interrupted run left behind is replayed in-lock BEFORE any ownership decision,
    # otherwise a half-applied file would look like a user edit and block the install forever.
    $recovery = Invoke-ToolkitOrphanRecovery -StateDirectory $stateDirectory -TargetRoot $targetRoot -OwnershipManifestPath $ownershipManifestPath
    if ([bool]$recovery.Changed) {
      Write-ToolkitLine 'State was recovered from an interrupted run; ownership is re-read before planning.' 'Warn'
      $ownershipManifest = $null
    }

    # Authoritative re-read of the ledger and the ownership plan, now that the lock is held and
    # recovery has finished.
    if ($null -eq $ownershipManifest -and (Test-Path -LiteralPath $ownershipManifestPath -PathType Leaf)) {
      $ownershipManifest = Read-ToolkitOwnershipManifest -Path $ownershipManifestPath
    }
    if ($null -ne $ownershipManifest) { $installId = [string]$ownershipManifest.installId }
    if (Test-Path -LiteralPath $ownershipManifestPath -PathType Leaf) {
      $ownershipManifestBytes = Get-ToolkitFileBytes -Path $ownershipManifestPath
    }

    $plan = New-ToolkitInstallPlan -TargetRoot $targetRoot -StateDirectory $stateDirectory -ReleaseManifest $releaseManifest -OwnershipManifest $ownershipManifest
    if ($null -eq $ownershipManifest) { $planMode = 'install (transactional)' }
    else { $planMode = 'upgrade ' + [string]$ownershipManifest.version + ' -> ' + [string]$releaseManifest.version + ' (transactional)' }
    $planSignature = Get-ToolkitPlanSignature -Plan $plan
    if ($confirmedSignature -ne $planSignature) {
      # Recovery (or a concurrent change) moved the plan after the user confirmed: show the
      # updated plan and ask again, so consent never drifts from what is about to happen.
      Write-ToolkitLine 'The plan changed after recovery; showing the updated plan before applying.' 'Warn'
      Show-ToolkitInstallPlan -Plan $plan -Mode ($planMode + ', updated after recovery')
      if (-not (Read-ToolkitConfirmation -Operation 'the updated install plan' -AlreadyConfirmed:([bool]$Options['Yes']))) {
        Write-ToolkitLine 'Cancelled by the user: nothing was applied (recovery already ran).' 'Warn'
        return $script:TKExitOk
      }
    }
    else {
      Show-ToolkitInstallPlan -Plan $plan -Mode $planMode
    }

    # A repeat install of the same release is a verified no-op: every destination was just
    # compared byte for byte with the release source and the pristine baseline, so nothing
    # (not even the ledger) is rewritten.
    $isNoOp = $true
    foreach ($operation in @($plan.Operations)) {
      if ([string]$operation.action -ne 'same') { $isNoOp = $false; break }
    }
    if ($isNoOp -and $null -ne $ownershipManifest -and @($plan.Notes).Count -eq 0 -and $orphanCount -eq 0 -and
      ([string]$ownershipManifest.version -eq [string]$releaseManifest.version)) {
      Write-ToolkitLine 'Already up to date: every managed file matches this release byte for byte.'
      Write-ToolkitLine ('Managed files verified: ' + @($plan.Operations).Count)
      Write-ToolkitLine 'No file was written (this is a verified no-op).'
      return $script:TKExitOk
    }

    # In-lock TOCTOU guard: re-prove every ownership decision by direct byte comparison right
    # before applying.
    Assert-ToolkitApplyPreconditions -TargetRoot $targetRoot -StateDirectory $stateDirectory -Plan $plan -OwnershipManifest $ownershipManifest `
      -OwnershipManifestPath $ownershipManifestPath -OwnershipManifestBytes $ownershipManifestBytes
    Write-ToolkitLine 'In-lock precondition check passed (ownership and content unchanged since planning).' 'Detail'

    Invoke-ToolkitFaultInjection -Point 'install.after-preflight'
    Invoke-ToolkitFaultInjection -Point 'install.after-lock'
    $transaction = Start-ToolkitTransaction -StateDirectory $stateDirectory -Kind 'install' -TargetRoot $targetRoot -Plan $plan -ToolkitVersion ([string]$releaseManifest.version)
    $script:TKTransactionDirectory = [string]$transaction.Directory
    Invoke-ToolkitFaultInjection -Point 'install.after-journal'

    # stage 1: durable backups of everything that may be replaced (target + pristine)
    foreach ($operation in @($plan.Operations)) {
      if ([string]$operation.action -ne 'replace') { continue }
      Backup-ToolkitFile -Transaction $transaction -RelativePath ([string]$operation.path) -SourcePath ([string]$operation.destination)
    }
    Backup-ToolkitManifest -Transaction $transaction -ManifestPath $ownershipManifestPath
    Invoke-ToolkitFaultInjection -Point 'install.after-backup'

    # stage 2: same-directory temp staging
    foreach ($operation in @($plan.Operations)) {
      if ([string]$operation.action -eq 'same') { continue }
      $destinationDirectory = Split-Path -Parent ([string]$operation.destination)
      if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
      }
      $temp = Join-Path $destinationDirectory ('.' + [System.IO.Path]::GetFileName([string]$operation.destination) + '.toolkit-tmp-' + [Guid]::NewGuid().ToString('n'))
      $targetPrefix = [System.IO.Path]::GetFullPath($targetRoot).TrimEnd('\').Length + 1
      Register-ToolkitStagedFile -Transaction $transaction -RelativePath ($temp.Substring($targetPrefix).Replace('\', '/'))
      Copy-ToolkitFileDurable -Source ([string]$operation.sourceFull) -Destination $temp
      if (-not (Test-ToolkitFileContentEqual -PathA $temp -PathB ([string]$operation.sourceFull))) {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'A staged temporary file does not match its package source; rolling back.' -Detail ('path=' + (Get-ToolkitSafePath -Path ([string]$operation.path)))
      }
      # The pristine baseline is part of this transaction and is recorded *before* the target is
      # replaced, so a rollback can always prove which bytes this run wrote - even for a file it
      # had just created.
      [void](Write-ToolkitPristineFile -StateDirectory $stateDirectory -RelativePath ([string]$operation.path) -SourcePath ([string]$operation.sourceFull))
      $operation | Add-Member -NotePropertyName tempPath -NotePropertyValue $temp -Force
    }
    Invoke-ToolkitFaultInjection -Point 'install.after-stage'

    # stage 3: atomic same-directory replace / move
    $replaced = 0
    foreach ($operation in @($plan.Operations)) {
      if ([string]$operation.action -eq 'same') { continue }
      Move-ToolkitFileAtomic -Source ([string]$operation.tempPath) -Destination ([string]$operation.destination)
      $replaced++
      Invoke-ToolkitFaultInjection -Point 'install.after-replace-first'
    }
    Invoke-ToolkitFaultInjection -Point 'install.after-replace'
    Write-ToolkitLine ('Applied ' + $replaced + ' file operations.') 'Detail'

    # stage 4: verify what is now on disk against the pristine baseline recorded in stage 2
    foreach ($record in @($plan.NewFiles)) {
      $relative = [string]$record.path
      $destination = Get-ToolkitFullPath -Root $targetRoot -RelativePath $relative
      if (-not (Test-ToolkitPathIsRegularFile -Path $destination)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'Post-install verification failed: a managed file is missing or is not a regular file; rolling back.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      if (-not (Test-ToolkitPristineMatches -StateDirectory $stateDirectory -RelativePath $relative -TargetPath $destination)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'Post-install verification failed: an installed file does not match the bytes this run recorded as pristine; rolling back.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
    }
    Invoke-ToolkitFaultInjection -Point 'install.after-verify'

    # stage 5: owned runtime Team Home (marker proven) before the manifest commit
    if ([bool]$runtimeContext.Enabled -and [bool]$runtimeContext.MustCreate) {
      $runtime = Resolve-ToolkitRuntimeContext -Options $Options -InstallId $installId
      $runtimeCreated = [bool](Get-ToolkitMember -Object $runtime -Name 'Created' -Default $false)
      # Adopt the real install identity the Team Home marker was written with, so the ledger,
      # the marker and the runtime all share one install id.
      if (-not [string]::IsNullOrEmpty([string]$runtime.InstallId)) { $installId = [string]$runtime.InstallId }
      $transaction.Journal.runtimeCreated = $runtimeCreated
      Save-ToolkitJournal -Transaction $transaction
    }

    Invoke-ToolkitFaultInjection -Point 'install.before-manifest-commit'

    # stage 6: ownership manifest atomic commit (also refreshes location metadata after a move)
    $ownership = New-ToolkitOwnershipManifest -InstallId $installId -Version ([string]$releaseManifest.version) -TargetRoot $targetRoot -Files @($plan.NewFiles) -ToolkitVersion ([string]$releaseManifest.version)
    Write-ToolkitJsonAtomic -Object $ownership -Destination $ownershipManifestPath
    $transaction.Journal.state = 'committed'
    Save-ToolkitJournal -Transaction $transaction
    Invoke-ToolkitFaultInjection -Point 'install.after-manifest-commit'

    if ($null -ne $ownershipManifest) {
      Write-ToolkitLine 'Ownership is self-locating: the state directory plus its pristine copies identify the managed files, so no location digest is needed.'
    }
    Write-ToolkitLine ('Installed toolkit ' + [string]$releaseManifest.version + ' into ' + (Get-ToolkitSafePath -Path $targetRoot))
    Write-ToolkitLine ('Managed files: ' + @($plan.NewFiles).Count)
    Write-ToolkitLine 'Managed files are listed in .codex-dsh-team-toolkit/manifest.json.'
    return $script:TKExitOk
  }
  catch {
    $failure = $_
    $exitCode = Get-ToolkitExitCodeFromException -Exception $failure.Exception
    $message = Get-ToolkitExceptionMessage -Exception $failure.Exception
    Write-ToolkitLine ('Install failed: ' + $message) 'Error'
    if (-not [string]::IsNullOrEmpty([string]$failure.InvocationInfo.PositionMessage)) {
      Write-ToolkitLine ('Failure site: ' + (Get-ToolkitSafeText -Text ([string]$failure.InvocationInfo.PositionMessage).Trim())) 'Detail'
    }

    if ($null -ne $transaction) {
      $problems = @(Invoke-ToolkitRollback -Transaction $transaction -TargetRoot $targetRoot -ManifestPath $ownershipManifestPath)
      if ([bool]$transaction.Journal.runtimeCreated) {
        try {
          $runtimeRoot = [string]$runtimeContext.Root
          if (-not [string]::IsNullOrEmpty($runtimeRoot) -and (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
            # remove the marker this transaction wrote (and never leave a superseded one behind)
            foreach ($markerName in @($script:TKTeamHomeMarkerName, $script:TKLegacyRuntimeMarkerName)) {
              $markerPath = Join-Path $runtimeRoot $markerName
              if (Test-Path -LiteralPath $markerPath -PathType Leaf) { Remove-Item -LiteralPath $markerPath -Force }
            }
            $remaining = @(Get-ChildItem -LiteralPath $runtimeRoot -Force -ErrorAction SilentlyContinue)
            if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $runtimeRoot -Force }
          }
        }
        catch { }
      }
      if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { Write-ToolkitLine ('Rollback issue: ' + $problem) 'Error' }
        Write-ToolkitLine ('Rollback was incomplete. Transaction evidence kept at ' + (Get-ToolkitSafePath -Path ([string]$transaction.Directory))) 'Error'
        return $script:TKExitRollback
      }
      Write-ToolkitLine 'Rollback complete: the project was restored to its previous state.' 'Warn'
      Remove-ToolkitTransactionDirectory -Transaction $transaction
      $removeCreatedState = $true
    }
    else {
      # Failed before the transaction existed: nothing was mutated, so a state directory we
      # created in this run is removed with the lock already released (finally block).
      $removeCreatedState = $true
    }
    return $exitCode
  }
  finally {
    $script:TKLogEnabled = $false
    Exit-ToolkitLock -Lock $lock
    Remove-ToolkitTransactionDirectory -Transaction $transaction
    if ($createdState -and $removeCreatedState -and -not ($script:TKTestKeepTransaction -and $script:TKTestMode)) {
      try {
        # SAFE-01: only content this run's plan proves is toolkit-owned may go; anything a user
        # dropped into the state directory meanwhile is preserved and reported.
        $provenPaths = @()
        if ($null -ne $plan) { $provenPaths = @($plan.Operations | ForEach-Object { [string]$_.path }) }
        $stateCleanup = Remove-ToolkitStateInternals -StateDirectory $stateDirectory -ProvenManagedPaths $provenPaths
        foreach ($entry in @($stateCleanup.Preserved)) {
          Write-ToolkitLine ('Preserved content the toolkit cannot prove it created: ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory ([string]$entry)))) 'Warn'
        }
        $remaining = @(Get-ChildItem -LiteralPath $stateDirectory -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $stateDirectory -Force }
      }
      catch { }
    }
  }
}

# ---------------------------------------------------------------------------
# Uninstall plan + action
# ---------------------------------------------------------------------------

function New-ToolkitUninstallPlan {
  <#
    A managed file is deletable only while it is byte-identical to the pristine baseline this
    toolkit installed. A user edit, a missing pristine baseline or a non-regular file is kept
    and reported. Nothing is ever deleted on a guess.
  #>
  param(
    [string]$TargetRoot,
    [string]$StateDirectory,
    [object]$OwnershipManifest,
    [object[]]$ResidualPaths = @()
  )

  $deletable = New-Object System.Collections.ArrayList
  $retained = New-Object System.Collections.ArrayList
  $alreadyAbsent = New-Object System.Collections.ArrayList

  # A running uninstaller EXE (or a locked engine) can be moved but never deleted on
  # Windows, so it is classified up front as a reported residual instead of being
  # quarantined and silently leaking.
  $residualIndex = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($selfPath in @($ResidualPaths)) {
    if ([string]::IsNullOrEmpty([string]$selfPath)) { continue }
    try { [void]$residualIndex.Add([System.IO.Path]::GetFullPath([string]$selfPath)) } catch { }
  }

  foreach ($file in @($OwnershipManifest.files)) {
    $relative = Assert-ToolkitRelativePath -Path ([string]$file.path)
    Assert-ToolkitPathNotDenied -RelativePath $relative
    Assert-ToolkitNoReparseInPath -Root $TargetRoot -RelativePath $relative
    $destination = Assert-ToolkitPathInsideRoot -Root $TargetRoot -FullPath (Get-ToolkitFullPath -Root $TargetRoot -RelativePath $relative) -RelativePath $relative
    $item = Get-ToolkitItemOrNull -Path $destination
    if ($null -eq $item) {
      [void]$alreadyAbsent.Add((New-ToolkitJsonObject -Properties @{ path = $relative; reason = 'already absent' }))
      continue
    }
    if ($residualIndex.Contains([System.IO.Path]::GetFullPath($destination))) {
      [void]$retained.Add((New-ToolkitJsonObject -Properties @{
            path   = $relative
            reason = 'in use by this process; minimal residual reported'
          }))
      continue
    }
    if (-not ($item -is [System.IO.FileInfo])) {
      [void]$retained.Add((New-ToolkitJsonObject -Properties @{ path = $relative; reason = 'not a regular file' }))
      continue
    }
    if (Test-ToolkitPristineMatches -StateDirectory $StateDirectory -RelativePath $relative -TargetPath $destination) {
      [void]$deletable.Add((New-ToolkitJsonObject -Properties @{ path = $relative }))
    }
    else {
      [void]$retained.Add((New-ToolkitJsonObject -Properties @{ path = $relative; reason = 'modified since install (or pristine baseline missing); kept' }))
    }
  }

  $directories = New-Object System.Collections.ArrayList
  foreach ($record in @($deletable)) {
    $relative = [string]$record.path
    $segments = @($relative.Split('/'))
    for ($i = 1; $i -lt $segments.Count; $i++) {
      $prefix = [string]::Join('/', $segments[0..($i - 1)])
      if ($prefix -eq $script:TKStateDirectory) { continue }
      [void]$directories.Add($prefix)
    }
  }

  # Untracked content (for example a runtime node_modules tree or user files inside a
  # managed skill directory) is never deleted, but it must be reported.
  $untracked = New-Object System.Collections.ArrayList
  $managedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($file in @($OwnershipManifest.files)) { [void]$managedFiles.Add(([string]$file.path).ToLowerInvariant()) }
  $managedDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($directory in @($directories | Sort-Object -Unique)) { [void]$managedDirs.Add(([string]$directory).ToLowerInvariant()) }
  foreach ($directory in @($managedDirs)) {
    $fullDirectory = Get-ToolkitFullPath -Root $TargetRoot -RelativePath $directory
    if (-not (Test-Path -LiteralPath $fullDirectory -PathType Container)) { continue }
    foreach ($child in @(Get-ChildItem -LiteralPath $fullDirectory -Force -ErrorAction SilentlyContinue)) {
      $childRelative = ($directory + '/' + $child.Name)
      $childKey = $childRelative.ToLowerInvariant()
      if ($managedFiles.Contains($childKey) -or $managedDirs.Contains($childKey)) { continue }
      [void]$untracked.Add($childRelative)
    }
  }

  return (New-ToolkitJsonObject -Properties @{
      TargetRoot    = $TargetRoot
      Version       = [string]$OwnershipManifest.version
      InstallId     = [string]$OwnershipManifest.installId
      Deletable     = $deletable.ToArray()
      Retained      = $retained.ToArray()
      AlreadyAbsent = $alreadyAbsent.ToArray()
      Directories   = @($directories | Sort-Object -Unique)
      Untracked     = @($untracked | Sort-Object -Unique)
      JournalPaths  = @($deletable | ForEach-Object { New-ToolkitJsonObject -Properties @{ path = $_.path; action = 'remove' } })
    })
}

function Show-ToolkitUninstallPlan {
  param(
    [object]$Plan,
    [string]$Mode
  )

  Write-ToolkitLine ('Codex x DSH Team Toolkit uninstall ' + $Plan.Version)
  Write-ToolkitLine ('Target project : ' + (Get-ToolkitSafePath -Path $Plan.TargetRoot))
  Write-ToolkitLine ('Mode           : ' + $Mode)
  Write-ToolkitLine ''
  Write-ToolkitLine ('Managed files to delete (ownership proven): ' + @($Plan.Deletable).Count)
  foreach ($record in @($Plan.Deletable)) {
    Write-ToolkitLine ('  delete   ' + (Get-ToolkitSafePath -Path ([string]$record.path)))
  }
  Write-ToolkitLine ('Files kept because ownership cannot be proven: ' + @($Plan.Retained).Count)
  foreach ($record in @($Plan.Retained)) {
    Write-ToolkitLine ('  keep     ' + (Get-ToolkitSafePath -Path ([string]$record.path)) + '  (' + [string]$record.reason + ')')
  }
  Write-ToolkitLine ('Managed files already absent: ' + @($Plan.AlreadyAbsent).Count)
  $untracked = @($Plan.Untracked)
  if ($untracked.Count -gt 0) {
    Write-ToolkitLine ('Untracked content that will be kept (never deleted): ' + $untracked.Count) 'Warn'
    $shown = 0
    foreach ($entry in $untracked) {
      if ($shown -ge 20) {
        Write-ToolkitLine ('  keep     ... and ' + ($untracked.Count - $shown) + ' more') 'Warn'
        break
      }
      Write-ToolkitLine ('  keep     ' + (Get-ToolkitSafePath -Path ([string]$entry))) 'Warn'
      $shown++
    }
  }
  Write-ToolkitLine 'User-added and unknown files are never deleted; directories are removed only when empty.'
}

function Invoke-ToolkitUninstallAction {
  param([hashtable]$Options)

  $enginePath = Get-ToolkitEngineSelfPath
  $targetArgument = [string]$Options['Target']
  if ([string]::IsNullOrEmpty($targetArgument)) {
    $targetArgument = Get-ToolkitDerivedTargetPath -EnginePath $enginePath
    if ([string]::IsNullOrEmpty($targetArgument)) {
      Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'Uninstall needs -Target <project>, or must run from inside the installed toolkit state directory.'
    }
  }
  $targetRoot = Resolve-ToolkitTargetPath -Path $targetArgument

  $stateDirectory = Join-Path $targetRoot $script:TKStateDirectory
  $ownershipManifestPath = Join-Path $stateDirectory $script:TKManifestName
  Assert-ToolkitNoReparseInPath -Root $targetRoot -RelativePath $script:TKStateDirectory

  # NEW-1: one unified pre-check of every state sub-root before the uninstall reads ownership
  # evidence, rolls anything back or cleans up. A root occupied by a file is reported and
  # preserved (NEW-2); a reparse point fails closed with remediation.
  $occupiedStateRoots = @(Assert-ToolkitStateRootsSafe -StateDirectory $stateDirectory)
  foreach ($occupiedRoot in $occupiedStateRoots) {
    Write-ToolkitLine ('The state root "' + [string]$occupiedRoot + '" is occupied by a file, not a directory; it is preserved and will be reported, never deleted.') 'Warn'
  }

  if (-not (Test-Path -LiteralPath $ownershipManifestPath -PathType Leaf)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'No ownership manifest found: the toolkit cannot prove what it installed, so nothing will be deleted.' -Detail ('path=' + (Get-ToolkitSafePath -Path $stateDirectory))
  }
  $ownershipManifest = Read-ToolkitOwnershipManifest -Path $ownershipManifestPath

  $selfPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($selfPath in @([string]$Options['UninstallerSelf'], $enginePath)) {
    if ([string]::IsNullOrEmpty($selfPath)) { continue }
    try { [void]$selfPaths.Add([System.IO.Path]::GetFullPath($selfPath)) } catch { }
  }

  # Only the running uninstaller EXE is classified as a residual up front: Windows will
  # rename a running image but never delete it. Everything else (including the installed
  # engine) goes through the normal quarantine path, where a locked file is restored and
  # reported by the commit hardening instead of being lost.
  $previewPlan = New-ToolkitUninstallPlan -TargetRoot $targetRoot -StateDirectory $stateDirectory -OwnershipManifest $ownershipManifest -ResidualPaths @([string]$Options['UninstallerSelf'])

  if ([bool]$Options['PlanOnly']) {
    Show-ToolkitUninstallPlan -Plan $previewPlan -Mode 'uninstall plan (dry run, zero writes)'
    $orphanPreview = @(Get-ToolkitOrphanTransactions -StateDirectory $stateDirectory)
    if ($orphanPreview.Count -gt 0) {
      Write-ToolkitLine ('Interrupted transaction evidence found: ' + $orphanPreview.Count + ' (a real run recovers it first, under the exclusive lock).') 'Warn'
    }
    Write-ToolkitLine 'Plan-only mode: nothing was written.' 'Warn'
    return $script:TKExitOk
  }

  # ---- confirmation gate: before the lock, before any write ----
  Show-ToolkitUninstallPlan -Plan $previewPlan -Mode 'uninstall plan (awaiting confirmation)'
  if (-not (Read-ToolkitConfirmation -Operation 'the uninstall' -AlreadyConfirmed:([bool]$Options['Yes']))) {
    Write-ToolkitLine 'Cancelled by the user: nothing was deleted.' 'Warn'
    return $script:TKExitOk
  }
  $confirmedSignature = Get-ToolkitPlanSignature -Plan $previewPlan

  $lock = $null
  $transaction = $null
  $commitStarted = $false
  $removeEmptyStateDirectory = $false
  $keepEvidence = $false
  $residual = New-Object System.Collections.ArrayList

  $script:TKLogPath = Join-Path $stateDirectory $script:TKLogName
  $script:TKLogEnabled = $true
  try {
    $lock = Enter-ToolkitLock -StateDirectory $stateDirectory -ClearStaleLock:([bool]$Options['ClearStaleLock'])

    # Replay any interrupted transaction before planning the uninstall, so the plan describes
    # the recovered state rather than a half-applied one.
    $recovery = Invoke-ToolkitOrphanRecovery -StateDirectory $stateDirectory -TargetRoot $targetRoot -OwnershipManifestPath $ownershipManifestPath
    if ([bool]$recovery.Changed) {
      Write-ToolkitLine 'State was recovered from an interrupted run; rebuilding the uninstall plan.' 'Warn'
      if (-not (Test-Path -LiteralPath $ownershipManifestPath -PathType Leaf)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitManifest -Message 'After recovery there is no ownership manifest, so ownership cannot be proven. Nothing was deleted.'
      }
      $ownershipManifest = Read-ToolkitOwnershipManifest -Path $ownershipManifestPath
    }

    $plan = New-ToolkitUninstallPlan -TargetRoot $targetRoot -StateDirectory $stateDirectory -OwnershipManifest $ownershipManifest -ResidualPaths @([string]$Options['UninstallerSelf'])
    if ((Get-ToolkitPlanSignature -Plan $plan) -ne $confirmedSignature) {
      Write-ToolkitLine 'The plan changed after recovery; showing the updated plan before deleting.' 'Warn'
      Show-ToolkitUninstallPlan -Plan $plan -Mode 'uninstall (transactional, updated after recovery)'
      if (-not (Read-ToolkitConfirmation -Operation 'the updated uninstall plan' -AlreadyConfirmed:([bool]$Options['Yes']))) {
        Write-ToolkitLine 'Cancelled by the user: nothing was deleted (recovery already ran).' 'Warn'
        return $script:TKExitOk
      }
    }
    else {
      Show-ToolkitUninstallPlan -Plan $plan -Mode 'uninstall (transactional)'
    }

    $transaction = Start-ToolkitTransaction -StateDirectory $stateDirectory -Kind 'uninstall' -TargetRoot $targetRoot -Plan $plan -ToolkitVersion ([string]$ownershipManifest.version)
    $script:TKTransactionDirectory = [string]$transaction.Directory
    $quarantine = Join-Path $transaction.Directory $script:TKQuarantineDirectoryName
    New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
    Invoke-ToolkitFaultInjection -Point 'uninstall.after-journal'

    $moved = 0
    foreach ($record in @($plan.Deletable)) {
      $relative = [string]$record.path
      $destination = Get-ToolkitFullPath -Root $targetRoot -RelativePath $relative
      if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }
      $quarantinePath = Join-Path $quarantine (ConvertTo-ToolkitNativePath -RelativePath $relative)
      $quarantineParent = Split-Path -Parent $quarantinePath
      if (-not (Test-Path -LiteralPath $quarantineParent -PathType Container)) {
        New-Item -ItemType Directory -Path $quarantineParent -Force | Out-Null
      }
      try {
        [System.IO.File]::Move($destination, $quarantinePath)
      }
      catch [System.IO.IOException] {
        if ($selfPaths.Contains([System.IO.Path]::GetFullPath($destination))) {
          [void]$residual.Add((New-ToolkitJsonObject -Properties @{ path = $relative; reason = 'in use by this process; minimal residual reported' }))
          Write-ToolkitLine ('Residual (cannot be removed while in use): ' + (Get-ToolkitSafePath -Path $relative)) 'Warn'
          continue
        }
        throw
      }
      # The pristine baseline is the reference: a file may only be quarantined while it is
      # byte-identical to what this toolkit installed, and the move must not change a byte.
      if (-not (Test-ToolkitPristineMatches -StateDirectory $stateDirectory -RelativePath $relative -TargetPath $quarantinePath)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitTransaction -Message 'A quarantined file does not match the pristine baseline; rolling back.' -Detail ('path=' + (Get-ToolkitSafePath -Path $relative))
      }
      $moved++
      Invoke-ToolkitFaultInjection -Point 'uninstall.after-quarantine-first'
    }
    Invoke-ToolkitFaultInjection -Point 'uninstall.before-commit'
    Write-ToolkitLine ('Quarantined ' + $moved + ' managed files.') 'Detail'

    # commit (irreversible from here on: quarantined content is discarded)
    $commitStarted = $true
    $transaction.Journal.state = 'committed'
    Save-ToolkitJournal -Transaction $transaction

    # Discard the quarantine file by file and verify each deletion. A file that cannot be
    # deleted (a locked executable is the classic case) is restored to its original place
    # and recorded as a reported residual instead of being silently lost.
    if (Test-Path -LiteralPath $quarantine -PathType Container) {
      $quarantinePrefix = [System.IO.Path]::GetFullPath($quarantine).TrimEnd('\').Length + 1
      # SAFE-01: only files this transaction quarantined from a planned managed path are proven
      # toolkit-owned. Anything else found in the quarantine directory is user content: it is
      # preserved, reported and keeps its ownership evidence.
      $quarantinedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($record in @($plan.Deletable)) {
        $planned = ([string]$record.path).Replace('\', '/').Trim('/')
        if (-not [string]::IsNullOrEmpty($planned)) { [void]$quarantinedPaths.Add($planned) }
      }
      foreach ($quarantined in @(Get-ChildItem -LiteralPath $quarantine -Recurse -Force -File -ErrorAction SilentlyContinue)) {
        $relative = $quarantined.FullName.Substring($quarantinePrefix).Replace('\', '/')
        if (-not $quarantinedPaths.Contains($relative)) {
          # MINOR-2: this file was not quarantined by this transaction, so it is not a managed
          # project-relative path. Report it, but never write it into the reduced ownership ledger
          # (that would fabricate an ownership record and inflate the kept-evidence count).
          Write-ToolkitLine ('Preserved unproven content in the quarantine directory: ' + (Get-ToolkitSafePath -Path $relative)) 'Warn'
          continue
        }
        try {
          Remove-Item -LiteralPath $quarantined.FullName -Force -ErrorAction Stop
        }
        catch {
          $restored = $false
          try {
            $destination = Get-ToolkitFullPath -Root $targetRoot -RelativePath $relative
            $destinationDirectory = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
              New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
            }
            if (Test-Path -LiteralPath $destination) {
              # A concurrent file appeared while we were committing: it is never overwritten,
              # and the quarantined original is kept as evidence instead of being discarded.
              $keepEvidence = $true
              [void]$residual.Add((New-ToolkitJsonObject -Properties @{
                    path   = $relative
                    reason = 'locked during commit and a different file now occupies the path; the recovered original is kept as transaction evidence and was not deleted'
                  }))
              Write-ToolkitLine ('Residual (kept as evidence, concurrent file preserved): ' + (Get-ToolkitSafePath -Path $relative)) 'Warn'
              continue
            }
            [System.IO.File]::Move($quarantined.FullName, $destination)
            $restored = $true
          }
          catch {
            $keepEvidence = $true
            Write-ToolkitLine ('Could not restore a locked quarantined file: ' + (Get-ToolkitSafePath -Path $relative)) 'Error'
          }
          [void]$residual.Add((New-ToolkitJsonObject -Properties @{
                path   = $relative
                reason = 'locked during the commit; restored or left in place and reported as a residual'
              }))
          if ($restored) {
            Write-ToolkitLine ('Residual (locked during commit, restored and reported): ' + (Get-ToolkitSafePath -Path $relative)) 'Warn'
          }
        }
      }
      Remove-ToolkitEmptyDirectories -Root $quarantine -RelativeDirectories @(Get-ToolkitRelativeSubdirectories -Root $quarantine) -ProtectedDirectories @() | Out-Null
      if (Test-Path -LiteralPath $quarantine -PathType Container) {
        $leftBehind = @(Get-ChildItem -LiteralPath $quarantine -Recurse -Force -ErrorAction SilentlyContinue)
        if ($leftBehind.Count -eq 0) { Remove-Item -LiteralPath $quarantine -Force -ErrorAction SilentlyContinue }
      }
    }

    # Anything we could not delete keeps its original ownership record so a later run can
    # still prove (or refuse) ownership instead of guessing.
    $leftovers = New-Object System.Collections.ArrayList
    foreach ($record in @($plan.Retained)) {
      [void]$leftovers.Add((New-ToolkitJsonObject -Properties @{ path = [string]$record.path }))
    }
    foreach ($record in @($residual)) {
      [void]$leftovers.Add((New-ToolkitJsonObject -Properties @{ path = [string]$record.path }))
    }

    $manifestBackupPath = Join-Path $transaction.BackupDirectory 'ownership-manifest.json'
    if (Test-Path -LiteralPath $ownershipManifestPath -PathType Leaf) {
      Copy-ToolkitFileDurable -Source $ownershipManifestPath -Destination $manifestBackupPath
      $transaction.Journal.manifestBackup = $true
      Save-ToolkitJournal -Transaction $transaction
    }
    if ($leftovers.Count -gt 0) {
      $reduced = New-ToolkitOwnershipManifest -InstallId ([string]$ownershipManifest.installId) -Version ([string]$ownershipManifest.version) `
        -TargetRoot $targetRoot -Files @($leftovers) -ToolkitVersion ([string]$ownershipManifest.version)
      Write-ToolkitJsonAtomic -Object $reduced -Destination $ownershipManifestPath
    }
    elseif (Test-Path -LiteralPath $ownershipManifestPath -PathType Leaf) {
      Remove-Item -LiteralPath $ownershipManifestPath -Force
    }

    $removedDirectories = @(Remove-ToolkitEmptyDirectories -Root $targetRoot -RelativeDirectories @($plan.Directories) -ProtectedDirectories @($script:TKStateDirectory))

    Write-ToolkitLine ('Uninstalled toolkit ' + [string]$ownershipManifest.version + ' from ' + (Get-ToolkitSafePath -Path $targetRoot))
    Write-ToolkitLine ('Deleted managed files: ' + $moved)
    if (@($plan.Retained).Count -gt 0) {
      Write-ToolkitLine ('Kept files that could not be proven owned or are in use: ' + @($plan.Retained).Count) 'Warn'
      foreach ($record in @($plan.Retained)) {
        Write-ToolkitLine ('  keep     ' + (Get-ToolkitSafePath -Path ([string]$record.path)) + '  (' + [string]$record.reason + ')')
      }
      Write-ToolkitLine 'These kept files are reported as a minimal residual and are never recursively deleted.' 'Warn'
    }
    if (@($residual).Count -gt 0) {
      Write-ToolkitLine ('Minimal residual reported (not recursively deleted): ' + @($residual).Count) 'Warn'
      foreach ($record in @($residual)) {
        Write-ToolkitLine ('  residual ' + (Get-ToolkitSafePath -Path ([string]$record.path)) + '  (' + [string]$record.reason + ')') 'Warn'
      }
    }
    Write-ToolkitLine ('Removed empty directories: ' + @($removedDirectories).Count)
    if ($leftovers.Count -gt 0) {
      Write-ToolkitLine ('Ownership evidence kept for ' + $leftovers.Count + ' file(s) in .codex-dsh-team-toolkit/manifest.json so a later run can still prove ownership.') 'Warn'
    }
    $unknown = @(Get-ToolkitUnknownStateEntries -StateDirectory $stateDirectory)
    if ($unknown.Count -gt 0) {
      Write-ToolkitLine ('Kept unknown content inside the toolkit state directory: ' + $unknown.Count) 'Warn'
      foreach ($entry in $unknown) { Write-ToolkitLine ('  keep     ' + (Get-ToolkitSafePath -Path ([string]$entry))) }
    }

    # A partial uninstall keeps a reduced ownership ledger, so the state directory survives and
    # must keep both its self-ignore boundary and the pristine evidence that ledger references.
    # Without this a later uninstall could no longer prove ownership of the retained files.
    #
    # SAFE-01: the full (pre-uninstall) ledger is the authority for what the toolkit ever owned,
    # so its paths may have their pristine copies pruned; anything else found under the state
    # directory is user content and is preserved and reported.
    $stateSurvives = ($leftovers.Count -gt 0) -or $keepEvidence -or ($unknown.Count -gt 0)
    $referencedPristine = New-Object System.Collections.ArrayList
    foreach ($record in @($leftovers)) {
      $relative = ([string](Get-ToolkitMember -Object $record -Name 'path' -Default '')).Replace('\', '/').Trim('/')
      if ([string]::IsNullOrEmpty($relative)) { continue }
      [void]$referencedPristine.Add($relative)
    }
    $provenManaged = New-Object System.Collections.ArrayList
    foreach ($file in @($ownershipManifest.files)) {
      $relative = ([string](Get-ToolkitMember -Object $file -Name 'path' -Default '')).Replace('\', '/').Trim('/')
      if ([string]::IsNullOrEmpty($relative)) { continue }
      [void]$provenManaged.Add($relative)
    }
    # MAJOR-1: when this run deliberately keeps transaction evidence for manual reconciliation,
    # the state cleanup must not touch that very transaction directory (it would delete the
    # journal, the ledger backup and the retained quarantine original while the finally block
    # reports that the evidence was kept). Excluding its relative root keeps the report truthful.
    $preserveRoots = New-Object System.Collections.ArrayList
    if ($keepEvidence -and $null -ne $transaction -and -not [string]::IsNullOrEmpty([string]$transaction.Directory)) {
      $stateFull = [System.IO.Path]::GetFullPath($stateDirectory).TrimEnd('\')
      $transactionFull = [System.IO.Path]::GetFullPath([string]$transaction.Directory)
      if ($transactionFull.StartsWith(($stateFull + '\'), [StringComparison]::OrdinalIgnoreCase)) {
        [void]$preserveRoots.Add($transactionFull.Substring($stateFull.Length + 1).Replace('\', '/'))
        Write-ToolkitLine ('Keeping this transaction''s evidence untouched: ' + (Get-ToolkitSafePath -Path ([string]$transaction.Directory))) 'Warn'
      }
    }
    if ($stateSurvives) {
      $stateCleanup = Remove-ToolkitStateInternals -StateDirectory $stateDirectory -KeepDirectory:$true -PreserveEvidence `
        -ReferencedManagedPaths $referencedPristine.ToArray() -ProvenManagedPaths $provenManaged.ToArray() `
        -PreserveRelativeRoots $preserveRoots.ToArray()
    }
    else {
      $stateCleanup = Remove-ToolkitStateInternals -StateDirectory $stateDirectory -KeepDirectory:$true `
        -ProvenManagedPaths $provenManaged.ToArray() -PreserveRelativeRoots $preserveRoots.ToArray()
    }
    foreach ($problem in @($stateCleanup.Problems)) { Write-ToolkitLine ('State cleanup: ' + [string]$problem) 'Warn' }
    if (@($stateCleanup.Preserved).Count -gt 0) {
      Write-ToolkitLine ('Preserved state-directory content the toolkit cannot prove it created: ' + @($stateCleanup.Preserved).Count) 'Warn'
      foreach ($entry in @($stateCleanup.Preserved)) {
        Write-ToolkitLine ('  keep     ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory ([string]$entry))))
      }
      Write-ToolkitLine 'Anything the toolkit cannot prove it created or installed is never deleted.' 'Warn'
    }
    if ($stateSurvives) {
      $keptPristine = @(Get-ChildItem -LiteralPath (Join-Path $stateDirectory $script:TKPristineDirectoryName) -Recurse -Force -File -ErrorAction SilentlyContinue).Count
      if ($keptPristine -gt 0) {
        Write-ToolkitLine ('Ownership evidence kept: ' + $keptPristine + ' pristine baseline(s) and the state .gitignore stay with the reduced ledger.') 'Warn'
      }
    }
    if (-not $stateSurvives) {
      # deferred to the finally block: the exclusive lock file is still held right now
      $removeEmptyStateDirectory = $true
    }
    return $script:TKExitOk
  }
  catch {
    $failure = $_
    $exitCode = Get-ToolkitExitCodeFromException -Exception $failure.Exception
    $message = Get-ToolkitExceptionMessage -Exception $failure.Exception
    Write-ToolkitLine ('Uninstall failed: ' + $message) 'Error'
    if ($null -ne $transaction -and $commitStarted) {
      Write-ToolkitLine 'Managed files were already deleted (the uninstall had committed); only post-commit cleanup failed.' 'Error'
      return $exitCode
    }
    if ($null -ne $transaction) {
      $uninstallRollback = Invoke-ToolkitUninstallRollback -Transaction $transaction -TargetRoot $targetRoot -Plan $plan
      if ([bool]$uninstallRollback.KeepEvidence) { $keepEvidence = $true }
      foreach ($problem in @($uninstallRollback.Problems)) {
        Write-ToolkitLine ('Rollback issue: ' + [string]$problem) 'Error'
      }
      if ([bool]$uninstallRollback.Ok) {
        Write-ToolkitLine 'Rollback complete: every managed file was restored.' 'Warn'
        Remove-ToolkitTransactionDirectory -Transaction $transaction
        return $exitCode
      }
      Write-ToolkitLine ('Rollback was incomplete. Transaction evidence kept at ' + (Get-ToolkitSafePath -Path ([string]$transaction.Directory))) 'Error'
      return $script:TKExitRollback
    }
    return $exitCode
  }
  finally {
    $script:TKLogEnabled = $false
    Exit-ToolkitLock -Lock $lock
    if (-not $keepEvidence) {
      Remove-ToolkitTransactionDirectory -Transaction $transaction
    }
    elseif ($null -ne $transaction) {
      # NEW-3: only claim the evidence was kept while it is actually still on disk. On the catch
      # path Remove-ToolkitTransactionDirectory may already have removed it, and a stale flag must
      # never produce a "kept" line that is not true.
      if (Test-Path -LiteralPath ([string]$transaction.Directory)) {
        Write-ToolkitLine ('Transaction evidence kept for manual reconciliation at ' + (Get-ToolkitSafePath -Path ([string]$transaction.Directory))) 'Warn'
      }
      else {
        Write-ToolkitLine 'Transaction cleanup already removed the transaction directory; no evidence needed to be kept.' 'Warn'
      }
    }
    if ($removeEmptyStateDirectory) {
      try {
        # only provably empty toolkit-owned subdirectories are removed, never recursively; a
        # reparse point is refused here too (NEW-1 class closure for the deferred sweep).
        foreach ($sub in @(Get-ToolkitStateRootNames)) {
          $subPath = Join-Path $stateDirectory $sub
          if (-not (Test-Path -LiteralPath $subPath -PathType Container)) { continue }
          $subItem = Get-ToolkitItemOrNull -Path $subPath
          if (Test-ToolkitReparseItem -Item $subItem) {
            Write-ToolkitLine ('Refusing to enumerate a state root that is a symlink / junction / reparse point: ' + (Get-ToolkitSafePath -Path $sub)) 'Warn'
            continue
          }
          $children = @(Get-ChildItem -LiteralPath $subPath -Force -ErrorAction SilentlyContinue)
          if ($children.Count -eq 0) { Remove-Item -LiteralPath $subPath -Force }
        }
        foreach ($internal in @($script:TKLockName, $script:TKLogName)) {
          $internalPath = Join-Path $stateDirectory $internal
          if (Test-Path -LiteralPath $internalPath -PathType Leaf) { Remove-Item -LiteralPath $internalPath -Force }
        }
        $remaining = @(Get-ChildItem -LiteralPath $stateDirectory -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $stateDirectory -Force }
      }
      catch { }
    }
  }
}

function Remove-ToolkitStateEvidenceSubtree {
  <#
    SAFE-01: a toolkit-owned *name* does not make its descendants toolkit-owned.

    Deletes only the files below a state sub-tree whose relative path is explained by toolkit
    evidence ($ProvenRelativePaths); everything else is preserved and returned so the caller can
    report it. Paths in $ReferencedRelativePaths are deliberately retained evidence: they are kept
    without being reported as unprovable content. Directories are removed only when they end up
    empty (never recursively), and a reparse point is refused instead of followed.

    Returns @{ Removed; Preserved; Problems } where Preserved holds paths relative to the state
    directory.
  #>
  param(
    [string]$StateDirectory,
    [string]$RelativeRoot,
    [object[]]$ProvenRelativePaths = @(),
    [object[]]$ReferencedRelativePaths = @(),
    [string]$Origin = 'state'
  )

  $removed = 0
  $preserved = New-Object System.Collections.ArrayList
  $problems = New-Object System.Collections.ArrayList

  $root = Join-Path $StateDirectory (ConvertTo-ToolkitNativePath -RelativePath $RelativeRoot)
  if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    return (New-ToolkitJsonObject -Properties @{ Removed = 0; Preserved = @(); Problems = @() })
  }
  $rootItem = Get-ToolkitItemOrNull -Path $root
  if (Test-ToolkitReparseItem -Item $rootItem) {
    [void]$preserved.Add($RelativeRoot)
    [void]$problems.Add('refused to descend into a reparse point under the state directory: ' + (Get-ToolkitSafePath -Path $RelativeRoot))
    return (New-ToolkitJsonObject -Properties @{ Removed = 0; Preserved = $preserved.ToArray(); Problems = $problems.ToArray() })
  }

  $proven = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($ProvenRelativePaths)) {
    $normalized = ([string]$entry).Replace('\', '/').Trim('/')
    if (-not [string]::IsNullOrEmpty($normalized)) { [void]$proven.Add($normalized) }
  }
  $deliberatelyKept = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($ReferencedRelativePaths)) {
    $normalized = ([string]$entry).Replace('\', '/').Trim('/')
    if (-not [string]::IsNullOrEmpty($normalized)) { [void]$deliberatelyKept.Add($normalized) }
  }

  $prefix = [System.IO.Path]::GetFullPath($root).TrimEnd('\').Length + 1
  $files = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
  foreach ($file in $files) {
    $relativeInside = $file.FullName.Substring($prefix).Replace('\', '/')
    $stateRelative = ($RelativeRoot.Trim('/') + '/' + $relativeInside)
    if (Test-ToolkitReparseItem -Item $file) {
      [void]$preserved.Add($stateRelative)
      [void]$problems.Add('preserved a reparse point under the state directory: ' + (Get-ToolkitSafePath -Path $stateRelative))
      continue
    }
    if ($deliberatelyKept.Contains($relativeInside)) {
      # retained on purpose (for example the baseline the reduced ledger references): keep it
      # without reporting it as content the toolkit cannot prove it created.
      continue
    }
    if (-not $proven.Contains($relativeInside)) {
      [void]$preserved.Add($stateRelative)
      continue
    }
    try {
      Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
      $removed++
    }
    catch {
      [void]$preserved.Add($stateRelative)
      [void]$problems.Add('could not remove proven state content ' + (Get-ToolkitSafePath -Path $stateRelative) + ': ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }

  # A directory may only go when it is proven empty; reparse points are never followed.
  $directories = @(Get-ChildItem -LiteralPath $root -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)
  foreach ($directory in $directories) {
    if (Test-ToolkitReparseItem -Item $directory) {
      [void]$preserved.Add(($RelativeRoot.Trim('/') + '/' + $directory.FullName.Substring($prefix).Replace('\', '/')))
      continue
    }
    try {
      $children = @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue)
      if ($children.Count -eq 0) { Remove-Item -LiteralPath $directory.FullName -Force }
    }
    catch { }
  }
  try {
    $remaining = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $root -Force }
  }
  catch { }

  return (New-ToolkitJsonObject -Properties @{ Removed = $removed; Preserved = $preserved.ToArray(); Problems = $problems.ToArray() })
}

function Get-ToolkitTransactionOwnedPaths {
  <#
    The files a transaction directory may contain, derived from its own journal: the journal and
    its lock are always toolkit evidence, and the backup/quarantine entries exist only for the
    managed paths that journal recorded. Anything else inside the directory is not explained by
    toolkit evidence and must be preserved.
  #>
  param([string]$TransactionDirectory)

  $owned = New-Object System.Collections.ArrayList
  [void]$owned.Add('journal.json')
  [void]$owned.Add('journal.json.lock')
  $journalPath = Join-Path $TransactionDirectory 'journal.json'
  if (-not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
    return (New-ToolkitJsonObject -Properties @{ Ok = $false; Paths = @() })
  }
  $journal = $null
  try {
    $journal = Read-ToolkitJsonFile -Path $journalPath -ExitCode $script:TKExitRollback -What 'Transaction journal'
  }
  catch {
    return (New-ToolkitJsonObject -Properties @{ Ok = $false; Paths = @() })
  }
  $kind = [string](Get-ToolkitMember -Object $journal -Name 'kind' -Default '')
  $state = [string](Get-ToolkitMember -Object $journal -Name 'state' -Default '')
  # The ledger's own transaction backup only exists when this transaction recorded one.
  if ([bool](Get-ToolkitMember -Object $journal -Name 'manifestBackup' -Default $false)) {
    [void]$owned.Add('backup/ownership-manifest.json')
  }
  # Backup-ToolkitFile writes the target copy under backup/<path> and the pristine copy under
  # backup/pristine/<path> inside the transaction directory; staged[] records project-relative
  # temporary paths, which never live here.
  foreach ($record in @(Get-ToolkitMember -Object $journal -Name 'backups' -Default @())) {
    $relative = ([string](Get-ToolkitMember -Object $record -Name 'path' -Default '')).Replace('\', '/').Trim('/')
    if (-not [string]::IsNullOrEmpty($relative)) { [void]$owned.Add('backup/' + $relative) }
  }
  foreach ($record in @(Get-ToolkitMember -Object $journal -Name 'pristineBackups' -Default @())) {
    $relative = ([string](Get-ToolkitMember -Object $record -Name 'path' -Default '')).Replace('\', '/').Trim('/')
    if (-not [string]::IsNullOrEmpty($relative)) { [void]$owned.Add('backup/pristine/' + $relative) }
  }
  # Only an uninstall transaction in the 'started' state quarantines managed files that recovery
  # will move back into the project; an install never uses quarantine. A *committed* transaction's
  # quarantine holds the originals a previous run may have promised to keep for manual
  # reconciliation (NEW-4), so those files are evidence and must be preserved, not treated as
  # proven garbage.
  if ($kind -eq 'uninstall' -and $state -eq 'started') {
    foreach ($record in @(Get-ToolkitMember -Object $journal -Name 'plan' -Default @())) {
      $relative = ([string](Get-ToolkitMember -Object $record -Name 'path' -Default '')).Replace('\', '/').Trim('/')
      if (-not [string]::IsNullOrEmpty($relative)) { [void]$owned.Add('quarantine/' + $relative) }
    }
  }
  return (New-ToolkitJsonObject -Properties @{ Ok = $true; Paths = $owned.ToArray() })
}

function Get-ToolkitStateRootNames {
  <#
    The toolkit-owned sub-roots of the state directory. Every one of them is a place the toolkit
    reads, writes, enumerates or deletes inside, so each must be validated before use.
  #>
  return @($script:TKTxnDirectoryName, $script:TKQuarantineDirectoryName, 'backup', $script:TKPristineDirectoryName, 'engine')
}

function Assert-ToolkitStateRootSafe {
  <#
    NEW-1 / MAJOR-2: a reparse point at a toolkit state *root* (txn/, quarantine/, backup/,
    pristine/, engine/) must be refused before anything enumerates, reads, writes or deletes
    under it. Get-ChildItem / Remove-Item / Copy-Item would follow a junction and the operation
    could land outside the state directory, so this fails closed (exit 3) instead.
  #>
  param(
    [string]$StateDirectory,
    [string]$RelativeRoot
  )

  $path = Join-Path $StateDirectory (ConvertTo-ToolkitNativePath -RelativePath $RelativeRoot)
  if (-not (Test-Path -LiteralPath $path)) { return }
  $item = Get-ToolkitItemOrNull -Path $path
  if (Test-ToolkitReparseItem -Item $item) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
      -Message ('The state directory contains a symlink / junction / reparse point at "' + $RelativeRoot + '"; refusing to read, write, enumerate or clean it so nothing outside the state directory can be touched.') `
      -Detail ('Remediation: replace ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory $RelativeRoot)) + ' with a real directory (or move the link aside), then retry. Nothing was changed.')
  }
}

function Assert-ToolkitStateRootsSafe {
  <#
    NEW-1: the single unified pre-check. Once a path has resolved the state directory it validates
    every toolkit state sub-root at once, so a future caller cannot forget one.

    * a reparse point anywhere in the set fails closed (exit 3), with a remediation line;
    * a root occupied by something that is not a directory is returned to the caller so it can be
      reported and preserved (NEW-2) instead of being silently ignored.

    Returns the list of root names occupied by a non-directory.
  #>
  param([string]$StateDirectory)

  $occupied = New-Object System.Collections.ArrayList
  foreach ($rootName in @(Get-ToolkitStateRootNames)) {
    Assert-ToolkitStateRootSafe -StateDirectory $StateDirectory -RelativeRoot $rootName
    $path = Join-Path $StateDirectory (ConvertTo-ToolkitNativePath -RelativePath $rootName)
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $item = Get-ToolkitItemOrNull -Path $path
    if ($null -ne $item -and -not ($item -is [System.IO.DirectoryInfo])) {
      [void]$occupied.Add($rootName)
    }
  }
  return $occupied.ToArray()
}

function Remove-ToolkitStateInternals {
  <#
    Removes toolkit-owned working files inside the state directory.

    SAFE-01: every deletion is justified per item. A path that merely *looks* like a toolkit name
    (pristine/, txn/, quarantine/, backup/) never authorises removing its descendants:

      * a pristine baseline is removable only when its managed path is explained by the ledger
        ($ProvenManagedPaths) or by transaction evidence;
      * a transaction directory is inspected file by file and only content named by its own
        journal may go; an unreadable journal means the whole directory is preserved;
      * the state .gitignore is removable only while it is still byte-identical to what the
        toolkit generated;
      * a reparse point is refused, never followed;
      * directories are removed only when they are proven empty.

    Everything that cannot be justified is preserved and returned so the caller can report it.

    -PreserveEvidence keeps the two things a *surviving* state directory still needs: the
    self-ignoring .gitignore, and the pristine baseline referenced by every entry of the
    (possibly reduced) ownership ledger.
  #>
  param(
    [string]$StateDirectory,
    [switch]$KeepDirectory,
    [switch]$PreserveEvidence,
    [object[]]$ReferencedManagedPaths = @(),
    [object[]]$ProvenManagedPaths = @(),
    [object[]]$PreserveRelativeRoots = @()
  )

  $preserved = New-Object System.Collections.ArrayList
  $problems = New-Object System.Collections.ArrayList

  # --- NEW-1/MAJOR-2: refuse a reparse point at every state root before enumerating anything ----
  # NEW-2: a root occupied by a regular file (or anything that is not a directory) is not deleted,
  # but it must be reported and must keep the state directory's self-ignore boundary alive.
  $occupiedRoots = @(Assert-ToolkitStateRootsSafe -StateDirectory $StateDirectory)
  foreach ($occupied in $occupiedRoots) {
    [void]$preserved.Add([string]$occupied)
    [void]$problems.Add('preserved a file that occupies the toolkit state root name "' + [string]$occupied + '" instead of a directory: ' + (Get-ToolkitSafePath -Path (Join-Path $script:TKStateDirectory ([string]$occupied))))
  }

  # --- subtrees this run deliberately keeps (MAJOR-1: the current transaction's evidence) ------
  $keepRoots = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($PreserveRelativeRoots)) {
    $normalized = ([string]$entry).Replace('\', '/').Trim('/')
    if (-not [string]::IsNullOrEmpty($normalized)) { [void]$keepRoots.Add($normalized) }
  }

  # --- top-level single toolkit working files ------------------------------------------------
  # The lock is still held by this very process at cleanup time, so its removal is deliberately
  # left to the lock-release sweep in the caller's finally block (it is a single toolkit file,
  # never a subtree). The log is attempted here and a failure is reported, never swallowed.
  foreach ($name in @($script:TKLockName, $script:TKLogName)) {
    $path = Join-Path $StateDirectory $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    if (-not (Test-ToolkitPathIsRegularFile -Path $path)) {
      # a directory / reparse point where a toolkit file belongs is not toolkit content
      [void]$preserved.Add($name)
      continue
    }
    if ($name -eq $script:TKLockName) { continue }
    try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    catch {
      [void]$problems.Add('could not remove ' + (Get-ToolkitSafePath -Path $name) + ' during state cleanup: ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
    }
  }

  # --- the self-ignoring state .gitignore ----------------------------------------------------
  $gitIgnorePath = Join-Path $StateDirectory $script:TKStateGitIgnoreName
  if ((Test-Path -LiteralPath $gitIgnorePath -PathType Leaf) -and -not $PreserveEvidence) {
    $generated = Join-Path $StateDirectory ('.gitignore-expected-' + [Guid]::NewGuid().ToString('n'))
    $justified = $false
    try {
      Write-ToolkitTextFileDurable -Path $generated -Content (Get-ToolkitStateGitIgnoreContent)
      $justified = Test-ToolkitFileContentEqual -PathA $gitIgnorePath -PathB $generated
    }
    catch { $justified = $false }
    finally {
      if (Test-Path -LiteralPath $generated) { Remove-Item -LiteralPath $generated -Force -ErrorAction SilentlyContinue }
    }
    if ($justified) {
      try { Remove-Item -LiteralPath $gitIgnorePath -Force -ErrorAction Stop }
      catch { [void]$preserved.Add($script:TKStateGitIgnoreName) }
    }
    else {
      # a user-edited self-ignore file is preserved and reported
      [void]$preserved.Add($script:TKStateGitIgnoreName)
    }
  }

  # --- pristine baselines: per-file proof ----------------------------------------------------
  $referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($ReferencedManagedPaths)) {
    $normalized = ([string]$entry).Replace('\', '/').Trim('/')
    if (-not [string]::IsNullOrEmpty($normalized)) { [void]$referenced.Add($normalized) }
  }
  $prunable = New-Object System.Collections.ArrayList
  foreach ($entry in @($ProvenManagedPaths)) {
    $normalized = ([string]$entry).Replace('\', '/').Trim('/')
    if ([string]::IsNullOrEmpty($normalized)) { continue }
    if ($referenced.Contains($normalized)) { continue }
    [void]$prunable.Add($normalized)
  }
  if ($PreserveEvidence) {
    $pristineResult = Remove-ToolkitStateEvidenceSubtree -StateDirectory $StateDirectory `
      -RelativeRoot $script:TKPristineDirectoryName -ProvenRelativePaths $prunable.ToArray() `
      -ReferencedRelativePaths @($ReferencedManagedPaths) -Origin 'pristine'
  }
  else {
    $pristineResult = Remove-ToolkitStateEvidenceSubtree -StateDirectory $StateDirectory `
      -RelativeRoot $script:TKPristineDirectoryName -ProvenRelativePaths @($ProvenManagedPaths) `
      -ReferencedRelativePaths @($ReferencedManagedPaths) -Origin 'pristine'
  }
  foreach ($entry in @($pristineResult.Preserved)) { [void]$preserved.Add([string]$entry) }
  foreach ($problem in @($pristineResult.Problems)) { [void]$problems.Add([string]$problem) }

  # --- engine/ (the installed engine copy) ---------------------------------------------------
  # MINOR-1: this subtree is enumerated like any other, so a file the toolkit cannot prove it
  # created is preserved and reported instead of being left unreported and unenumerated.
  $engineProven = New-Object System.Collections.ArrayList
  $engineReferenced = New-Object System.Collections.ArrayList
  $enginePrefix = ($script:TKStateDirectory + '/engine/')
  foreach ($entry in @($ProvenManagedPaths)) {
    $normalized = ([string]$entry).Replace('\', '/').Trim('/')
    if ($normalized.StartsWith($enginePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      [void]$engineProven.Add($normalized.Substring($enginePrefix.Length))
    }
  }
  foreach ($entry in @($ReferencedManagedPaths)) {
    $normalized = ([string]$entry).Replace('\', '/').Trim('/')
    if ($normalized.StartsWith($enginePrefix, [StringComparison]::OrdinalIgnoreCase)) {
      [void]$engineReferenced.Add($normalized.Substring($enginePrefix.Length))
    }
  }
  $engineResult = Remove-ToolkitStateEvidenceSubtree -StateDirectory $StateDirectory `
    -RelativeRoot 'engine' -ProvenRelativePaths $engineProven.ToArray() `
    -ReferencedRelativePaths $engineReferenced.ToArray() -Origin 'engine'
  foreach ($entry in @($engineResult.Preserved)) { [void]$preserved.Add([string]$entry) }
  foreach ($problem in @($engineResult.Problems)) { [void]$problems.Add([string]$problem) }

  # --- transaction directories: file-by-file proof from each journal -------------------------
  $txnRoot = Join-Path $StateDirectory $script:TKTxnDirectoryName
  if (Test-Path -LiteralPath $txnRoot -PathType Container) {
    # MINOR-1: a plain file directly under txn/ is not transaction evidence; it is preserved and
    # reported (the previous code only enumerated directories and silently left such files).
    foreach ($txnFile in @(Get-ChildItem -LiteralPath $txnRoot -Force -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
      $txnFileRelative = ($script:TKTxnDirectoryName + '/' + $txnFile.Name)
      [void]$preserved.Add($txnFileRelative)
      [void]$problems.Add('preserved a file in the transaction directory that no journal explains: ' + (Get-ToolkitSafePath -Path $txnFileRelative))
    }
    foreach ($transactionDirectory in @(Get-ChildItem -LiteralPath $txnRoot -Force -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
      $transactionRelative = ($script:TKTxnDirectoryName + '/' + $transactionDirectory.Name)
      if ($keepRoots.Contains($transactionRelative)) {
        # MAJOR-1: this transaction's evidence is being kept deliberately (keepEvidence); the
        # finally block reports it truthfully and nothing here may touch it.
        continue
      }
      $owned = Get-ToolkitTransactionOwnedPaths -TransactionDirectory $transactionDirectory.FullName
      if (-not [bool]$owned.Ok) {
        # Without a readable journal nothing inside can be justified: keep the whole directory.
        [void]$preserved.Add($transactionRelative)
        [void]$problems.Add('preserved a transaction directory whose journal is unreadable: ' + (Get-ToolkitSafePath -Path $transactionRelative))
        continue
      }
      $result = Remove-ToolkitStateEvidenceSubtree -StateDirectory $StateDirectory -RelativeRoot $transactionRelative -ProvenRelativePaths @($owned.Paths) -Origin 'transaction'
      foreach ($entry in @($result.Preserved)) { [void]$preserved.Add([string]$entry) }
      foreach ($problem in @($result.Problems)) { [void]$problems.Add([string]$problem) }
    }
    try {
      $leftover = @(Get-ChildItem -LiteralPath $txnRoot -Force -ErrorAction SilentlyContinue)
      if ($leftover.Count -eq 0) { Remove-Item -LiteralPath $txnRoot -Force }
    }
    catch { }
  }

  # --- legacy top-level quarantine / backup trees --------------------------------------------
  # No journal names their content, so nothing inside them can be proven: they are preserved and
  # reported rather than recursively deleted.
  foreach ($legacyName in @($script:TKQuarantineDirectoryName, 'backup')) {
    $legacyPath = Join-Path $StateDirectory $legacyName
    if (-not (Test-Path -LiteralPath $legacyPath -PathType Container)) { continue }
    $legacyChildren = @(Get-ChildItem -LiteralPath $legacyPath -Force -Recurse -ErrorAction SilentlyContinue)
    if ($legacyChildren.Count -eq 0) {
      try { Remove-Item -LiteralPath $legacyPath -Force } catch { }
      continue
    }
    [void]$preserved.Add($legacyName)
    [void]$problems.Add('preserved unproven content in the state directory: ' + (Get-ToolkitSafePath -Path $legacyName))
  }

  if ($PreserveEvidence) {
    # The self-ignore boundary must survive as long as the state directory does.
    Write-ToolkitStateGitIgnore -StateDirectory $StateDirectory
  }
  elseif (@($preserved.ToArray()).Count -gt 0 -and (Test-Path -LiteralPath $StateDirectory -PathType Container)) {
    # Content the toolkit cannot prove it created is kept, so the state directory survives: it
    # must keep its self-ignore boundary too, otherwise the preserved state would show up in the
    # user's Git status. The .gitignore is toolkit-generated and safe to (re)write.
    Write-ToolkitStateGitIgnore -StateDirectory $StateDirectory
  }

  if (-not $KeepDirectory) {
    try {
      $remaining = @(Get-ChildItem -LiteralPath $StateDirectory -Force -ErrorAction SilentlyContinue)
      if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $StateDirectory -Force }
    }
    catch { }
  }

  return (New-ToolkitJsonObject -Properties @{
      Preserved = @($preserved.ToArray() | Sort-Object -Unique)
      Problems  = $problems.ToArray()
    })
}

function Get-ToolkitRelativeSubdirectories {
  <#
    Lists every subdirectory below a root as normalized relative paths (deepest last),
    refusing reparse points.
  #>
  param([string]$Root)

  $directories = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $directories.ToArray() }
  $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\').Length + 1
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    if (Test-ToolkitReparseItem -Item $item) { continue }
    [void]$directories.Add($item.FullName.Substring($prefix).Replace('\', '/'))
  }
  return $directories.ToArray()
}

function Get-ToolkitUnknownStateEntries {
  param([string]$StateDirectory)

  $known = @($script:TKManifestName, $script:TKLockName, $script:TKLogName, $script:TKTxnDirectoryName, $script:TKQuarantineDirectoryName, $script:TKStateGitIgnoreName, 'engine', $script:TKPristineDirectoryName)
  $unknown = New-Object System.Collections.ArrayList
  foreach ($child in @(Get-ChildItem -LiteralPath $StateDirectory -Force -ErrorAction SilentlyContinue)) {
    if ($known -contains $child.Name) { continue }
    [void]$unknown.Add($child.Name)
  }
  return $unknown.ToArray()
}

# ---------------------------------------------------------------------------
# Command surface
# ---------------------------------------------------------------------------

function Invoke-ToolkitCommand {
  <#
    Single in-process entry point. Returns @{ ExitCode; Lines } and never throws for
    expected failures, which makes it directly testable without spawning a process.
  #>
  param([hashtable]$Options)

  $script:TKOutput = New-Object System.Collections.ArrayList
  $script:TKCollectOutput = $true
  $script:TKQuietOutput = $true
  $script:TKNonInteractive = [bool]$Options['NonInteractive']
  $script:TKTestMode = [bool]$Options['TestMode']
  $script:TKTestFaultPoint = [string]$Options['TestFault']
  $script:TKTestKeepTransaction = [bool]$Options['TestKeepTransaction']
  $script:TKTestConfirmation = [string]$Options['TestConfirmation']
  $script:TKUninstallerSelfPath = [string]$Options['UninstallerSelf']
  $script:TKEngineSelfPath = [string]$Options['EnginePath']
  $script:TKCreatedStateDirectory = $false
  $script:TKTransactionDirectory = ''

  $exitCode = $script:TKExitOk
  try {
    $testRequested = (-not [string]::IsNullOrEmpty([string]$Options['TestFault'])) -or
      [bool]$Options['TestKeepTransaction'] -or [bool]$Options['TestMode'] -or (-not [string]::IsNullOrEmpty([string]$Options['TestConfirmation']))
    if ($testRequested) {
      if (-not [bool]$Options['TestMode']) {
        Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message 'Fault injection requires -TestMode (test-only switch); nothing was written.'
      }
      # Both the switch and the environment gate are required so a release binary cannot be
      # steered into test behaviour by a stray command line.
      Assert-ToolkitTestGate -Feature 'fault injection'
    }
    switch ([string]$Options['Action']) {
      'Install' { $exitCode = Invoke-ToolkitInstallAction -Options $Options }
      'Uninstall' { $exitCode = Invoke-ToolkitUninstallAction -Options $Options }
      default { Throw-ToolkitFailure -ExitCode $script:TKExitUsage -Message ('Unsupported action: ' + [string]$Options['Action']) }
    }
  }
  catch {
    $exitCode = Get-ToolkitExitCodeFromException -Exception $_.Exception
    [void]$script:TKOutput.Add((Get-ToolkitSafeText -Text ('ERROR: ' + (Get-ToolkitExceptionMessage -Exception $_.Exception))))
  }
  finally {
    $script:TKLogEnabled = $false
    $script:TKCollectOutput = $false
    $script:TKQuietOutput = $false
  }
  return (New-ToolkitJsonObject -Properties @{
      ExitCode             = $exitCode
      Lines                = @($script:TKOutput)
      TransactionDirectory = $script:TKTransactionDirectory
    })
}

function Invoke-ToolkitCli {
  param([hashtable]$Options)

  $result = Invoke-ToolkitCommand -Options $Options
  foreach ($line in @($result.Lines)) { Write-Host $line }
  $outputFile = [string]$Options['OutputFile']
  if (-not [string]::IsNullOrEmpty($outputFile)) {
    try {
      $full = [System.IO.Path]::GetFullPath($outputFile)
      Write-ToolkitTextFileDurable -Path $full -Content ((@($result.Lines) -join [Environment]::NewLine) + [Environment]::NewLine)
    }
    catch {
      Write-Host ('WARNING: could not write the requested output file: ' + (Get-ToolkitSafeText -Text $_.Exception.Message)) -ForegroundColor Yellow
    }
  }
  return [int]$result.ExitCode
}

# ---------------------------------------------------------------------------
# Entry point (skipped when dot-sourced with -Library)
# ---------------------------------------------------------------------------

if (-not $Library) {
  $script:TKEngineSelfPath = Get-ToolkitEngineSelfPath
  $options = @{
    Action           = $Action
    Target           = $Target
    PackageRoot      = $PackageRoot
    ReleaseManifest  = $ReleaseManifest
    PlanOnly         = [bool]$PlanOnly
    Yes              = [bool]$Yes
    NonInteractive   = [bool]$NonInteractive
    Quiet            = [bool]$Quiet
    TeamDshHome      = $TeamDshHome
    RuntimeRootBase  = $RuntimeRootBase
    InitializeRuntime = [bool]$InitializeRuntime
    TestFault        = $TestFault
    TestMode         = [bool]$TestMode
    TestKeepTransaction = [bool]$TestKeepTransaction
    TestConfirmation = $TestConfirmation
    UninstallerSelf  = $UninstallerSelf
    OutputFile       = $OutputFile
    ClearStaleLock   = [bool]$ClearStaleLock
    EnginePath       = $script:TKEngineSelfPath
  }
  exit (Invoke-ToolkitCli -Options $options)
}
