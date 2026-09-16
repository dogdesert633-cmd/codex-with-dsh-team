#Requires -Version 5.1
<#
  Shared release-tooling helpers (offline only).

  Used by tools/Build-Release.ps1 and tools/Verify-Release.ps1. The engine is dot-sourced so
  path normalization and the deny-by-default policy have exactly one implementation.

  No release checksum artefact exists in this toolkit: Build writes no SHA256SUMS.txt and no
  .sha256 sidecar, and Verify consumes neither. Release transport integrity belongs to the
  distribution channel; the installer separately protects post-install user changes with
  pristine byte copies recorded in the ownership manifest.

  Release scanning is deliberately conservative:
    * path scan     - always enforced; blocks VCS/runtime/credential/log/session artefacts and
                      absolute personal paths from entering a release package;
    * content scan  - every text file in the package (not just the payload); high-confidence
                      secret patterns. A hit blocks the build unless the *matched value itself*
                      self-identifies as fake/example/redacted/test, or the file is on the
                      explicit reviewer allowlist. A marker elsewhere on the line is never
                      enough to exempt a value.
    * binding scan  - fixed DSH home / DSH version fallbacks block; fixed provider/model
                      pinning is reported for human review.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ReleaseToolkitRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:ReleaseToolkitRoot 'install\Invoke-Toolkit.ps1') -Library

$script:ReleaseForbiddenPathPatterns = @(
  '(^|/)(\.git|\.dsh|\.svn|\.hg)(/|$)',
  '(^|/)(node_modules|bower_components)(/|$)',
  '(^|/)(artifacts|dist|bin|obj|\.vs|\.vscode)(/|$)',
  '(^|/)\.env(\..*)?$',
  '(^|/)(settings|settings\.local|appsettings)\.(json|ya?ml)$',
  '(^|/)[^/]*credential[^/]*(\.|$)',
  '(^|/)(server[-_.]?record|agent-registry|server)\.(json|ya?ml)$',
  '(^|/)[^/]*\.(log|jsonl|session|sessions)$',
  '(^|/)(logs?|sessions?|history)(/|$)',
  '(^|/)[^/]*(chrome|edge|firefox|brave)[-_ ]?(profile|user[-_ ]?data)[^/]*',
  '(^|/)(cookies?|Cookies)(\.|/|$)',
  '(^|/)[^/]*\.(pem|key|pfx|p12|ppk|kdbx|jks)$',
  '^[A-Za-z]:[\\/]',
  '^\\\\',
  '^/'
)

# High-confidence secret shapes. None of these may ship in a release package.
# Paths that must never appear in a release package at all: development tests, toolkit/release
# metadata, ownership markers, runtime state, credentials and build artifacts. The deny-by-default
# path scan covers several of these; this list states the release contract explicitly.
# Paths that must never be INSTALLED into a target project (the package may still ship tests).
$script:ReleaseForbiddenInstallPatterns = @(
  '(^|/)test/',
  '\.test\.(mjs|js|cjs)$',
  '(^|/)COPY_FILE_LIST\.json$',
  'ownership-manifest\.json$',
  '(^|/)\.codex-dsh-team-home\.json$',
  '(^|/)\.codex-dsh-team-runtime\.json$',
  '(^|/)install\.json$',
  '(^|/)node_modules(/|$)',
  '(^|/)artifacts(/|$)',
  '(^|/)\.dsh(/|$)',
  '(^|/)sessions?(/|$)',
  '(^|/)logs?(/|$)',
  '(^|/)[^/]*\.(log|jsonl|session|sessions)$',
  '(^|/)\.env(\..*)?$',
  '(^|/)[^/]*credentials?[^/]*(\.|$)',
  '(^|/)\.credentials\.yaml$',
  '(^|/)settings\.ya?ml$',
  '(^|/)payload-inventory\.json$',
  '(^|/)package-layout\.json$',
  '(^|/)build-report\.json$'
)

$script:ReleaseForbiddenPackagePatterns = @(
  '(^|/)COPY_FILE_LIST\.json$',
  'ownership-manifest\.json$',
  '(^|/)\.codex-dsh-team-home\.json$',
  '(^|/)\.codex-dsh-team-runtime\.json$',
  '(^|/)install\.json$',
  '(^|/)node_modules(/|$)',
  '(^|/)artifacts(/|$)',
  '(^|/)\.dsh(/|$)',
  '(^|/)sessions?(/|$)',
  '(^|/)logs?(/|$)',
  '(^|/)[^/]*\.(log|jsonl|session|sessions)$',
  '(^|/)\.env(\..*)?$',
  '(^|/)[^/]*credentials?[^/]*(\.|$)',
  '(^|/)\.credentials\.yaml$',
  '(^|/)settings\.ya?ml$'
)

$script:ReleaseSecretPatterns = @(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----',
  '\bAKIA[0-9A-Z]{16}\b',
  '\bsk-[A-Za-z0-9]{20,}\b',
  '\bgh[pousr]_[A-Za-z0-9]{20,}\b',
  '\bxox[baprs]-[A-Za-z0-9-]{10,}\b',
  '\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\b',
  '(?i)\b(authorization|api[_-]?key|apikey|access[_-]?token|client[_-]?secret|password|passwd|secret)\b\s*[:=]\s*["'']([A-Za-z0-9+/_\-]{24,})["'']'
)

# Fixed-environment bindings that must not be baked into a public release.
$script:ReleaseBindingBlockPatterns = @(
  '(?i)\bhome-acp-\d+\.\d+\.\d+\b',
  '(?i)(dsh_home|dshhome|dsh-home)\s*[:=]\s*["'']?[A-Za-z]:[\\/]',
  '(?i)[A-Za-z]:\\[^\s"'']*home-acp-\d'
)

# Environment pinning that is reported for human review instead of failing the build.
$script:ReleaseBindingWarnPatterns = @(
  '(?i)\b(provider|model)\s*[:=]\s*["'']?(deepseek|openai|anthropic|azure|google|gemini|bedrock|ollama)[A-Za-z0-9._\-]*'
)

# Applied to the matched value only - never to the whole line or the surrounding context.
$script:ReleaseSecretExceptionPattern = '(?i)(fake|dummy|example|placeholder|redacted|sample|changeme|xxxx|0{8,}|<redacted>)'

function Get-ReleaseRelativePath {
  param(
    [string]$Root,
    [string]$Path
  )
  $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\').Length + 1
  return ([System.IO.Path]::GetFullPath($Path).Substring($prefix)).Replace('\', '/')
}

function Get-ReleaseFileList {
  <#
    Lists every regular file below a root as normalized relative paths, refusing reparse
    points so a symlinked payload can never smuggle outside content into a release.
  #>
  param([string]$Root)

  $files = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $files.ToArray() }
  foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $full = [System.IO.Path]::GetFullPath($item.FullName)
    if (Test-ToolkitReparseItem -Item $item) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'Release source contains a symlink or reparse point.' -Detail ('path=' + (Get-ToolkitSafePath -Path $full))
    }
    [void]$files.Add((Get-ReleaseRelativePath -Root $Root -Path $full))
  }
  return $files.ToArray()
}

function Assert-ReleasePathAllowed {
  <#
    Fails the build when a release-bound path is forbidden or unsafe.
  #>
  param(
    [string]$RelativePath,
    [string]$Origin = 'release'
  )

  $normalized = (ConvertTo-ToolkitRelativePath -Path $RelativePath)
  Assert-ToolkitRelativePath -Path $normalized | Out-Null
  Assert-ToolkitPathNotDenied -RelativePath $normalized | Out-Null

  foreach ($pattern in $script:ReleaseForbiddenPathPatterns) {
    if ($normalized -match $pattern) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked `
        -Message ('Release scan blocked a forbidden path (' + $Origin + ').') `
        -Detail ('path=' + (Get-ToolkitSafePath -Path $normalized))
    }
  }
  return $normalized
}

function Assert-ReleaseArchiveEntryPath {
  <#
    Full relative-path validation for an archive (zip) entry name, used BEFORE a package is
    expanded. Rejects traversal, absolute/UNC/device paths, drive letters, alternate data
    streams (embedded ':'), reserved device names, case-fold duplicates, empty segments and
    invalid characters.
  #>
  param(
    [string]$EntryName,
    [string]$Origin = 'archive entry',
    [hashtable]$Seen = $null
  )

  $candidate = [string]$EntryName
  if ([string]::IsNullOrEmpty($candidate)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('An archive entry has an empty name (' + $Origin + ').')
  }
  $candidate = $candidate.TrimEnd('/')
  if ([string]::IsNullOrEmpty($candidate)) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('An archive entry has an empty name (' + $Origin + ').')
  }
  if ($candidate.Contains('\')) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('Archive entries must use forward slashes (' + $Origin + ').') -Detail ('path=' + (Get-ToolkitSafePath -Path $candidate))
  }
  if ($candidate.Contains(':')) {
    Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('An archive entry contains an alternate data stream or drive prefix (' + $Origin + ').') -Detail ('path=' + (Get-ToolkitSafePath -Path $candidate))
  }

  $normalized = Assert-ToolkitRelativePath -Path $candidate
  if ($null -ne $Seen) {
    if ($Seen.ContainsKey($normalized.ToLowerInvariant())) {
      Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message ('An archive contains case-folded duplicate entries (' + $Origin + ').') -Detail ('path=' + (Get-ToolkitSafePath -Path $normalized))
    }
    $Seen[$normalized.ToLowerInvariant()] = $true
  }
  return $normalized
}

function Expand-ReleaseZipSafely {
  <#
    Validates every zip entry (name shape, duplicates, symlink attribute, containment) before
    writing anything, then extracts entry by entry with a resolved-path containment check.
  #>
  param(
    [string]$ZipPath,
    [string]$Destination
  )

  Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

  $fullZip = [System.IO.Path]::GetFullPath($ZipPath)
  $fullDestination = [System.IO.Path]::GetFullPath($Destination)
  if (-not (Test-Path -LiteralPath $fullDestination -PathType Container)) {
    New-Item -ItemType Directory -Path $fullDestination -Force | Out-Null
  }
  $destinationPrefix = $fullDestination.TrimEnd('\') + '\'
  $seen = @{}
  $entryCount = 0

  $archive = [System.IO.Compression.ZipFile]::OpenRead($fullZip)
  try {
    foreach ($entry in $archive.Entries) {
      $normalized = Assert-ReleaseArchiveEntryPath -EntryName $entry.FullName -Origin 'zip entry' -Seen $seen
      # symlink entries (unix mode bits in the external attributes) are refused outright
      $mode = ($entry.ExternalAttributes -shr 16) -band 0xF000
      if ($mode -eq 0xA000) {
        Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'The zip contains a symlink entry; refusing to expand it.' -Detail ('path=' + (Get-ToolkitSafePath -Path $normalized))
      }
      if ([string]::IsNullOrEmpty($entry.Name)) { continue }  # directory entry
      $target = [System.IO.Path]::GetFullPath((Join-Path $fullDestination ($normalized -replace '/', '\')))
      if (-not $target.StartsWith($destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-ToolkitFailure -ExitCode $script:TKExitBlocked -Message 'A zip entry would escape the extraction directory (zip slip).' -Detail ('path=' + (Get-ToolkitSafePath -Path $normalized))
      }
      $targetDirectory = Split-Path -Parent $target
      if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
      }
      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
      $entryCount++
    }
  }
  finally {
    $archive.Dispose()
  }
  return $entryCount
}

function New-ReleaseZip {
  <#
    Writes the release zip directly with System.IO.Compression instead of Compress-Archive.

    Windows PowerShell 5.1's Compress-Archive can write entry names with backslashes, which
    produces a non-portable archive and is refused by the verifier. Creating the entries here
    guarantees forward-slash names on every host.
  #>
  param(
    [string]$Root,
    [string]$Destination
  )

  Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop

  if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Force }
  $files = @(Get-ReleaseFileList -Root $Root)
  $archive = [System.IO.Compression.ZipFile]::Open($Destination, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($relative in $files) {
      $source = Join-Path $Root (ConvertTo-ToolkitNativePath -RelativePath ([string]$relative))
      $entry = $archive.CreateEntry([string]$relative, [System.IO.Compression.CompressionLevel]::Optimal)
      $sourceStream = [System.IO.File]::Open($source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
      try {
        $output = $entry.Open()
        try { $sourceStream.CopyTo($output) }
        finally { $output.Dispose() }
      }
      finally { $sourceStream.Dispose() }
    }
  }
  finally {
    $archive.Dispose()
  }
  return $files.Count
}

function Get-ReleaseAllowList {
  <#
    Normalises a reviewer allowlist. Accepts an array (-ContentScanAllowlist a,b,c) and a single
    comma-separated string (-ContentScanAllowlist "a,b,c"), and accepts entries either as the
    install-relative path declared by the inventory (.agents/...) or as the package-relative
    path (payload/.agents/...). Returns a plain array (callers use @()).
  #>
  param([object[]]$Values)

  $list = New-Object System.Collections.ArrayList
  foreach ($value in @($Values)) {
    $text = [string]$value
    foreach ($part in ($text -split ',')) {
      $trimmed = $part.Trim().Trim('"').Trim("'")
      if (-not [string]::IsNullOrWhiteSpace($trimmed)) { [void]$list.Add($trimmed) }
    }
  }
  return $list.ToArray()
}

function Get-ReleaseForbiddenPackageProblems {
  <#
    Asserts the release contract that development tests, metadata, markers, runtime state,
    credentials and artifacts are absent from a package.
  #>
  param([string]$Root)

  $problems = New-Object System.Collections.ArrayList
  foreach ($relative in @(Get-ReleaseFileList -Root $Root)) {
    foreach ($pattern in $script:ReleaseForbiddenPackagePatterns) {
      if ($relative -match $pattern) {
        [void]$problems.Add('A package file violates the release contract (matched ' + $pattern + '): ' + (Get-ToolkitSafePath -Path $relative))
        break
      }
    }
  }
  return $problems.ToArray()
}

function Get-ReleaseInstallSetProblems {
  <#
    Fail-closed gate for the managed install set: release-manifest.json `files` is the only thing
    that is ever installed, so every entry must be a runtime payload path. Development tests,
    release/build metadata, credentials, ownership markers, runtime state, sessions and build
    artifacts may be packaged for transparency but must never appear here.
  #>
  param([string]$PackageRoot)

  $problems = New-Object System.Collections.ArrayList
  $manifestPath = Join-Path $PackageRoot 'release-manifest.json'
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    [void]$problems.Add('release-manifest.json is missing, so the install set cannot be checked.')
    return $problems.ToArray()
  }
  $manifest = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8)
  $entries = @(Get-ToolkitMember -Object $manifest -Name 'files' -Default @())
  if ($entries.Count -eq 0) {
    [void]$problems.Add('release-manifest.json declares no managed files.')
    return $problems.ToArray()
  }

  foreach ($entry in $entries) {
    $relative = [string](Get-ToolkitMember -Object $entry -Name 'path' -Default '')
    if ([string]::IsNullOrWhiteSpace($relative)) {
      [void]$problems.Add('release-manifest.json contains a managed entry without a path.')
      continue
    }
    foreach ($pattern in $script:ReleaseForbiddenInstallPatterns) {
      if ($relative -match $pattern) {
        [void]$problems.Add('The managed install set contains a path that must never be installed (matched ' + $pattern + '): ' + (Get-ToolkitSafePath -Path $relative))
        break
      }
    }
    if ($relative -notmatch '^(\.agents/|start_dsh_team\.cmd$|sync_dsh_team_config\.cmd$|\.codex-dsh-team-toolkit/engine/|CodexDshTeamToolkit\.Uninstall\.exe$)') {
      [void]$problems.Add('The managed install set contains an unexpected path outside the runtime layout: ' + (Get-ToolkitSafePath -Path $relative))
    }
  }
  return $problems.ToArray()
}

function Get-ReleaseRequiredFiles {
  <#
    The releaseMustContain list comes from the packaged layout when present (that is the layout
    the package was actually built with); the repository copy is a fallback. When both exist
    their rule sets must agree, so a tampered in-package layout cannot weaken the check.
  #>
  param(
    [string]$PackageRoot,
    [string]$RepositoryLayoutPath
  )

  $required = New-Object System.Collections.ArrayList
  $packagedLayoutPath = Join-Path $PackageRoot 'release\package-layout.json'
  $packagedRules = @()
  $repositoryRules = @()

  if (Test-Path -LiteralPath $packagedLayoutPath -PathType Leaf) {
    $packaged = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $packagedLayoutPath -Raw -Encoding UTF8)
    $packagedRules = @(Get-ToolkitMember -Object $packaged -Name 'releaseMustContain' -Default @() | ForEach-Object { [string]$_ })
  }
  if (-not [string]::IsNullOrEmpty($RepositoryLayoutPath) -and (Test-Path -LiteralPath $RepositoryLayoutPath -PathType Leaf)) {
    $repository = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $RepositoryLayoutPath -Raw -Encoding UTF8)
    $repositoryRules = @(Get-ToolkitMember -Object $repository -Name 'releaseMustContain' -Default @() | ForEach-Object { [string]$_ })
  }

  $problems = New-Object System.Collections.ArrayList
  if ($packagedRules.Count -gt 0 -and $repositoryRules.Count -gt 0) {
    $packagedSorted = (@($packagedRules | Sort-Object -Unique) -join '|')
    $repositorySorted = (@($repositoryRules | Sort-Object -Unique) -join '|')
    if ($packagedSorted -ne $repositorySorted) {
      [void]$problems.Add('The packaged release/package-layout.json releaseMustContain rules do not match the repository layout.')
    }
  }

  $effective = $packagedRules
  $source = 'package'
  if ($effective.Count -eq 0) {
    $effective = $repositoryRules
    $source = 'repository'
  }
  foreach ($item in $effective) { [void]$required.Add([string]$item) }
  return (New-ToolkitJsonObject -Properties @{
      Required = $required.ToArray()
      Problems = $problems.ToArray()
      Source   = $source
    })
}

function Test-ReleaseUninstallerFreshness {
  <#
    A release must never silently ship a stale thin EXE: the binary is compared against the
    C# source and the build recipe it is supposed to come from.
  #>
  param([string]$RepositoryRoot)

  $exePath = Join-Path $RepositoryRoot 'uninstaller\CodexDshTeamToolkit.Uninstall.exe'
  $sourcePath = Join-Path $RepositoryRoot 'uninstaller\src\Uninstaller.cs'
  $recipePath = Join-Path $RepositoryRoot 'uninstaller\Build-Uninstaller.ps1'

  if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    return (New-ToolkitJsonObject -Properties @{ Fresh = $false; Reason = 'the thin uninstaller EXE does not exist yet' })
  }
  $exeTime = (Get-Item -LiteralPath $exePath).LastWriteTimeUtc
  foreach ($prerequisite in @($sourcePath, $recipePath)) {
    if (-not (Test-Path -LiteralPath $prerequisite -PathType Leaf)) { continue }
    if ((Get-Item -LiteralPath $prerequisite).LastWriteTimeUtc -gt $exeTime) {
      return (New-ToolkitJsonObject -Properties @{
          Fresh  = $false
          Reason = ('the thin uninstaller EXE is older than ' + (Get-ReleaseRelativePath -Root $RepositoryRoot -Path $prerequisite))
        })
    }
  }
  return (New-ToolkitJsonObject -Properties @{ Fresh = $true; Reason = '' })
}

function Invoke-ReleaseContentScan {
  <#
    Secret + fixed-environment binding scan for every text file that is about to enter (or has
    entered) a release package.

    Returns @{ Blocked; Warnings; Bindings; BindingWarnings } containing `path:line` entries
    only - never the matched value.

    Exception rule (deliberately strict): a hit is downgraded to a warning only when the
    matched value itself self-identifies as fake/example/redacted/test, or the file is on the
    reviewer allowlist.
  #>
  param(
    [string]$Root,
    [object[]]$RelativePaths,
    [string[]]$Allowlist = @(),
    [int]$MaxBytes = 2097152,
    [switch]$IncludeBindings
  )

  $blocked = New-Object System.Collections.ArrayList
  $warnings = New-Object System.Collections.ArrayList
  $bindings = New-Object System.Collections.ArrayList
  $bindingWarnings = New-Object System.Collections.ArrayList
  $allow = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($entry in @($Allowlist)) {
    if ([string]::IsNullOrEmpty([string]$entry)) { continue }
    # Accept both conventions: the install-relative path declared by the payload inventory and
    # the package-relative path (payload/...).
    $candidate = ([string]$entry).Replace('\', '/').TrimStart('/')
    [void]$allow.Add($candidate)
    if ($candidate.StartsWith('payload/')) {
      [void]$allow.Add($candidate.Substring('payload/'.Length))
    }
    else {
      [void]$allow.Add('payload/' + $candidate)
    }
  }

  foreach ($relative in @($RelativePaths)) {
    $normalized = ([string]$relative).Replace('\', '/')
    $full = Join-Path $Root (ConvertTo-ToolkitNativePath -RelativePath $normalized)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $info = Get-Item -LiteralPath $full -Force
    if ($info.Length -gt $MaxBytes) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    $isBinary = $false
    foreach ($b in $bytes) { if ($b -eq 0) { $isBinary = $true; break } }
    if ($isBinary) { continue }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    $lines = $text -split "`r?`n"
    for ($index = 0; $index -lt $lines.Length; $index++) {
      $line = [string]$lines[$index]
      $entry = $normalized + ':' + ($index + 1)

      foreach ($pattern in $script:ReleaseSecretPatterns) {
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) { continue }
        if ($allow.Contains($normalized)) {
          [void]$warnings.Add($entry + ' (allowlisted)')
        }
        elseif ($match.Value -match $script:ReleaseSecretExceptionPattern) {
          [void]$warnings.Add($entry)
        }
        else {
          [void]$blocked.Add($entry)
        }
        break
      }

      if ($IncludeBindings) {
        foreach ($pattern in $script:ReleaseBindingBlockPatterns) {
          if ($line -match $pattern) {
            if ($allow.Contains($normalized)) { [void]$bindingWarnings.Add($entry + ' (allowlisted)') }
            else { [void]$bindings.Add($entry) }
            break
          }
        }
        foreach ($pattern in $script:ReleaseBindingWarnPatterns) {
          if ($line -match $pattern) {
            [void]$bindingWarnings.Add($entry)
            break
          }
        }
      }
    }
  }

  return (New-ToolkitJsonObject -Properties @{
      Blocked         = @($blocked | Sort-Object -Unique)
      Warnings        = @($warnings | Sort-Object -Unique)
      Bindings        = @($bindings | Sort-Object -Unique)
      BindingWarnings = @($bindingWarnings | Sort-Object -Unique)
    })
}
