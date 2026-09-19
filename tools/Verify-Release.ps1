#Requires -Version 5.1
<#
  Verifies a built release package (directory or zip) without network access.

    pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.1.0
    pwsh -File tools/Verify-Release.ps1 -Package dist/codex-dsh-team-toolkit-v1.1.0.zip
    pwsh -File tools/Verify-Release.ps1 -Package <dir> -ContentScan

  Checks:
    * every zip entry validated BEFORE anything is expanded (traversal, absolute/UNC/device
      paths, drive letters, ADS, reserved names, case-fold duplicates, symlink entries,
      zip slip);
    * no checksum artefact is expected or consumed: there is no SHA256SUMS.txt and no .sha256
      sidecar. Release transport integrity belongs to the distribution channel;
    * package identity, relative-path-only release manifest, deny-by-default path policy;
    * presence of every managed file (location only: the manifest carries no digest), and the
      releaseMustContain list from the layout;
    * the managed install set is runtime-only (fail-closed against smuggled paths);
    * optional content + fixed-environment binding scan over the whole package.
  Exits 0 on PASS and 1 on FAIL.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$Package,
  [switch]$SkipContentScan,
  [string]$ExpectVersion = '',
  [string[]]$ContentScanAllowlist = @(),
  [switch]$KeepExpanded
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Release.Common.ps1')

$problems = New-Object System.Collections.ArrayList
$notes = New-Object System.Collections.ArrayList

function Add-Problem {
  param([string]$Text)
  [void]$problems.Add((Get-ToolkitSafeText -Text $Text))
  Write-Host ('FAIL  ' + (Get-ToolkitSafeText -Text $Text)) -ForegroundColor Red
}

function Add-Note {
  param([string]$Text)
  [void]$notes.Add((Get-ToolkitSafeText -Text $Text))
  Write-Host ('  ok  ' + (Get-ToolkitSafeText -Text $Text))
}

# An unexpected terminating error is a verification failure, never a stack trace.
trap {
  $message = [string]$_.Exception.Message
  if ($_.Exception.Data -and $_.Exception.Data.Contains('ToolkitDetail')) {
    $message = $message + ' [' + [string]$_.Exception.Data['ToolkitDetail'] + ']'
  }
  Add-Problem ('Unexpected verification error: ' + $message)
  Write-Host 'VERIFY FAIL' -ForegroundColor Red
  exit 1
}

$expanded = ''
$packageRoot = [System.IO.Path]::GetFullPath($Package)
$zipPath = ''
if (Test-Path -LiteralPath $packageRoot -PathType Leaf) {
  if ([System.IO.Path]::GetExtension($packageRoot) -ne '.zip') {
    Write-Host ('Not a directory and not a .zip: ' + (Get-ToolkitSafePath -Path $packageRoot)) -ForegroundColor Red
    exit 1
  }
  $zipPath = $packageRoot

  # Validate every entry BEFORE expanding anything.
  $expanded = Join-Path ([System.IO.Path]::GetTempPath()) ('toolkit-verify-' + [Guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $expanded -Force | Out-Null
  $entryCount = Expand-ReleaseZipSafely -ZipPath $zipPath -Destination $expanded
  Add-Note ('zip entries validated and expanded safely (' + $entryCount + ' files)')
  $packageRoot = $expanded
}
elseif (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
  Write-Host ('Package not found: ' + (Get-ToolkitSafePath -Path $packageRoot)) -ForegroundColor Red
  exit 1
}

try {
  # ---- release manifest -------------------------------------------------------------
  $manifestPath = Join-Path $packageRoot 'release-manifest.json'
  $manifest = $null
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Add-Problem 'release-manifest.json is missing from the package.'
  }
  else {
    try { $manifest = Read-ToolkitReleaseManifest -Path $manifestPath }
    catch { Add-Problem ('release-manifest.json is invalid: ' + (Get-ToolkitExceptionMessage -Exception $_.Exception)) }

    if ($null -ne $manifest) {
      Add-Note ('release manifest identity ok (version ' + [string]$manifest.version + ', ' + @($manifest.files).Count + ' managed files)')
      if (-not [string]::IsNullOrEmpty($ExpectVersion) -and [string]$manifest.version -ne $ExpectVersion) {
        Add-Problem ('Version mismatch: expected ' + $ExpectVersion + ', found ' + [string]$manifest.version)
      }

      $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
      foreach ($entry in @($manifest.files)) {
        $relative = [string]$entry.path
        $source = [string]$entry.source
        if (-not $seen.Add($relative)) { Add-Problem ('Duplicate managed path: ' + (Get-ToolkitSafePath -Path $relative)) }

        $sourceFull = Join-Path $packageRoot (ConvertTo-ToolkitNativePath -RelativePath $source)
        if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) {
          Add-Problem ('Managed source is missing from the package: ' + (Get-ToolkitSafePath -Path $source))
          continue
        }
        # The release manifest is a location list: no digest is read, validated or stored, and
        # the toolkit makes no release-integrity claim about the transport.
      }
      Add-Note 'every managed file exists in the package (location-only manifest, no digest)'
    }
  }

  # ---- path policy over the whole package --------------------------------------------
  $staged = @(Get-ReleaseFileList -Root $packageRoot)
  foreach ($relative in $staged) {
    Assert-ReleasePathAllowed -RelativePath $relative -Origin 'package' | Out-Null
  }
  Add-Note ('deny-by-default path scan passed for ' + $staged.Count + ' packaged files')

  # ---- release contract: package content, then the fail-closed managed install set -------
  $contractProblems = @(Get-ReleaseForbiddenPackageProblems -Root $packageRoot)
  foreach ($contractProblem in $contractProblems) { Add-Problem $contractProblem }
  if ($contractProblems.Count -eq 0) {
    Add-Note 'the package contains no metadata, marker, runtime or credential path (public tests may ship)'
  }
  $installSetProblems = @(Get-ReleaseInstallSetProblems -PackageRoot $packageRoot)
  foreach ($installSetProblem in $installSetProblems) { Add-Problem $installSetProblem }
  if ($installSetProblems.Count -eq 0) {
    Add-Note 'the managed install set is runtime-only (no test, metadata, credential, marker or runtime path)'
  }

  # ---- releaseMustContain from the PACKAGED layout (repository copy is a fallback) -----
  $layoutResult = Get-ReleaseRequiredFiles -PackageRoot $packageRoot -RepositoryLayoutPath (Join-Path $script:ReleaseToolkitRoot 'release\package-layout.json')
  foreach ($layoutProblem in @($layoutResult.Problems)) { Add-Problem $layoutProblem }
  $required = @($layoutResult.Required)
  if ($required.Count -eq 0) {
    Add-Problem 'releaseMustContain could not be determined from release/package-layout.json.'
  }
  else {
    foreach ($item in $required) {
      $requiredPath = Join-Path $packageRoot (ConvertTo-ToolkitNativePath -RelativePath ([string]$item))
      if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        Add-Problem ('The package is missing a file required by the layout: ' + (Get-ToolkitSafePath -Path ([string]$item)))
      }
    }
    Add-Note ('releaseMustContain satisfied (' + $required.Count + ' entries, source: ' + [string]$layoutResult.Source + ')')
  }

  # ---- no checksum artefact may exist in a release package ----------------------------
  $checksumArtifacts = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'SHA256SUMS.txt' -or $_.Name -like '*.sha256' })
  foreach ($artifact in $checksumArtifacts) {
    Add-Problem ('A checksum artefact must never be packaged: ' + (Get-ReleaseRelativePath -Root $packageRoot -Path $artifact.FullName))
  }
  if ($checksumArtifacts.Count -eq 0) {
    Add-Note 'no checksum artefact in the package (no SHA256SUMS.txt, no .sha256 sidecar)'
  }
  # ---- optional content + binding scan over the whole package -------------------------
  if (-not $SkipContentScan) {
    $allowList = @(Get-ReleaseAllowList -Values $ContentScanAllowlist)
    foreach ($allowlisted in $allowList) {
      Write-Host ('  ok  content scan allowlist entry (reviewed): ' + (Get-ToolkitSafePath -Path $allowlisted))
    }
    $scan = Invoke-ReleaseContentScan -Root $packageRoot -RelativePaths $staged -Allowlist $allowList -IncludeBindings
    foreach ($warning in @($scan.Warnings)) { Write-Host ('  warn  content scan (self-identified fake): ' + $warning) -ForegroundColor Yellow }
    foreach ($warning in @($scan.BindingWarnings)) { Write-Host ('  warn  binding scan review: ' + $warning) -ForegroundColor Yellow }
    foreach ($hit in @($scan.Bindings)) { Add-Problem ('Binding scan hit: ' + $hit) }
    foreach ($hit in @($scan.Blocked)) { Add-Problem ('Content scan hit: ' + $hit) }
    if (@($scan.Blocked).Count -eq 0 -and @($scan.Bindings).Count -eq 0) {
      Add-Note 'content and binding scan found no unmarked secret or fixed environment binding'
    }
  }
}
finally {
  if (-not [string]::IsNullOrEmpty($expanded) -and -not $KeepExpanded) {
    try { Remove-Item -LiteralPath $expanded -Recurse -Force -ErrorAction SilentlyContinue } catch { }
  }
}

Write-Host ''
if ($problems.Count -gt 0) {
  Write-Host ('VERIFY FAIL (' + $problems.Count + ' problem(s))') -ForegroundColor Red
  exit 1
}
Write-Host 'VERIFY PASS' -ForegroundColor Green
exit 0
