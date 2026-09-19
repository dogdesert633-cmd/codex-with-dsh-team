#Requires -Version 5.1
<#
  Builds an offline, GitHub-ready release package for the Codex x DSH Team Toolkit.

    pwsh -File tools/Build-Release.ps1
    pwsh -File tools/Build-Release.ps1 -Version 1.1.0

  Guarantees:
    * no network access and no push, ever;
    * the managed payload set comes from release/payload-inventory.json (the toolkit-owned single
      source of truth): `files` is the runtime-only install set, `releaseDevelopmentPaths` is
      packaged but never installed, never inferred from a blind directory walk;
    * no checksum artefact is produced: no SHA256SUMS.txt, no .sha256 sidecar, no digest in the
      release manifest. Release transport integrity belongs to the distribution channel; the
      installer separately protects post-install user changes with pristine byte copies;
    * everything is produced in a private staging directory, the previous artifacts stay
      untouched until the new package is complete, and only directories this tool created are
      ever removed;
    * path scan + content scan + fixed-environment binding scan run over the whole package.
#>
[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$Version = '1.1.0',
  [string]$OutputDir = '',
  [switch]$SkipZip,
  [switch]$AllowMissingPayload,
  [switch]$IncludeUndeclaredPayload,
  [switch]$SkipContentScan,
  [string[]]$ContentScanAllowlist = @(),
  [string]$PayloadInventory = '',
  [switch]$BuildInstaller,
  [switch]$AllowStaleInstaller,
  [switch]$BuildUninstaller,
  [switch]$AllowStaleUninstaller,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fail visible and clean: never dump a PowerShell stack trace at a release engineer.
trap {
  $message = [string]$_.Exception.Message
  if ($_.Exception.Data -and $_.Exception.Data.Contains('ToolkitDetail')) {
    $message = $message + ' [' + [string]$_.Exception.Data['ToolkitDetail'] + ']'
  }
  Write-Host ('Release build failed: ' + (Get-ToolkitSafeText -Text $message)) -ForegroundColor Red
  if (-not [string]::IsNullOrEmpty($script:ReleaseStagingRoot) -and (Test-Path -LiteralPath $script:ReleaseStagingRoot)) {
    try { Remove-Item -LiteralPath $script:ReleaseStagingRoot -Recurse -Force } catch { }
  }
  Exit-BuildFailure
}

$script:ReleaseStagingRoot = ''

$toolDirectory = $PSScriptRoot
. (Join-Path $toolDirectory 'Release.Common.ps1')

if ([string]::IsNullOrEmpty($RepoRoot)) { $RepoRoot = $script:ReleaseToolkitRoot }
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
if ([string]::IsNullOrEmpty($OutputDir)) { $OutputDir = Join-Path $RepoRoot 'dist' }
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

function Write-BuildLine {
  param([string]$Text, [string]$Level = 'Info')
  if ($Quiet -and $Level -eq 'Info') { return }
  $safe = Get-ToolkitSafeText -Text $Text
  switch ($Level) {
    'Error' { Write-Host $safe -ForegroundColor Red }
    'Warn' { Write-Host $safe -ForegroundColor Yellow }
    default { Write-Host $safe }
  }
}

function Exit-BuildFailure {
  <#
    Every failure path leaves the previous artifacts untouched and removes only the staging
    directory this build created.
  #>
  param([string]$Message = '')

  if (-not [string]::IsNullOrEmpty($Message)) { Write-BuildLine $Message 'Error' }
  if (-not [string]::IsNullOrEmpty($script:ReleaseStagingRoot) -and (Test-Path -LiteralPath $script:ReleaseStagingRoot)) {
    try { Remove-Item -LiteralPath $script:ReleaseStagingRoot -Recurse -Force } catch { }
  }
  exit 1
}

$layoutPath = Join-Path $RepoRoot 'release\package-layout.json'
if (-not (Test-Path -LiteralPath $layoutPath -PathType Leaf)) {
  Write-BuildLine ('Release layout is missing: ' + (Get-ToolkitSafePath -Path $layoutPath)) 'Error'
  Exit-BuildFailure
}
$layout = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $layoutPath -Raw -Encoding UTF8)
if ([string](Get-ToolkitMember -Object $layout -Name 'schema' -Default '') -ne 'codex-dsh-team-toolkit/package-layout/v1') {
  Write-BuildLine 'Release layout schema is not recognized.' 'Error'
  Exit-BuildFailure
}

Write-BuildLine ('Codex x DSH Team Toolkit release build ' + $Version)
Write-BuildLine ('Repository   : ' + (Get-ToolkitSafePath -Path $RepoRoot))
Write-BuildLine ('Output       : ' + (Get-ToolkitSafePath -Path $OutputDir))

# ---- 1. required package files -------------------------------------------------------
$missing = New-Object System.Collections.ArrayList
foreach ($relative in @(Get-ToolkitMember -Object $layout -Name 'packageOnly' -Default @())) {
  $normalized = [string]$relative
  if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot (ConvertTo-ToolkitNativePath -RelativePath $normalized)) -PathType Leaf)) {
    [void]$missing.Add($normalized)
  }
}
if ($missing.Count -gt 0) {
  foreach ($entry in $missing) { Write-BuildLine ('Missing required package file: ' + (Get-ToolkitSafePath -Path $entry)) 'Error' }
  Exit-BuildFailure 'Build stopped: the package layout is incomplete (the thin EXEs are built by installer/Build-Installer.ps1 and uninstaller/Build-Uninstaller.ps1).'
}

# A release must never silently reuse a stale thin EXE: rebuild it here, or fail visibly.
# The installer and the uninstaller are symmetric gates.
$installerRecipe = Join-Path $RepoRoot 'installer\Build-Installer.ps1'
if ($BuildInstaller) {
  Write-BuildLine 'Rebuilding the thin installer EXE as part of this release build.'
  & $installerRecipe -Quiet
  if ($LASTEXITCODE -ne 0) {
    Exit-BuildFailure ('Build stopped: the thin installer EXE could not be rebuilt (exit ' + $LASTEXITCODE + '). The previous artifacts were left untouched.')
  }
}
$installerFreshness = Test-ReleaseInstallerFreshness -RepositoryRoot $RepoRoot
if (-not [bool]$installerFreshness.Fresh -and -not $AllowStaleInstaller) {
  Write-BuildLine ('Build stopped: ' + [string]$installerFreshness.Reason + '.') 'Error'
  Write-BuildLine 'Run installer/Build-Installer.ps1 first (or pass -BuildInstaller to do it here). Pass -AllowStaleInstaller only when you know the binary is current.' 'Error'
  Exit-BuildFailure
}
if (-not [bool]$installerFreshness.Fresh) {
  Write-BuildLine ('Proceeding with a possibly stale thin installer EXE because -AllowStaleInstaller was passed: ' + [string]$installerFreshness.Reason) 'Warn'
}

$uninstallerRecipe = Join-Path $RepoRoot 'uninstaller\Build-Uninstaller.ps1'
if ($BuildUninstaller) {
  Write-BuildLine 'Rebuilding the thin uninstaller EXE as part of this release build.'
  & $uninstallerRecipe -Quiet
  if ($LASTEXITCODE -ne 0) {
    Exit-BuildFailure ('Build stopped: the thin uninstaller EXE could not be rebuilt (exit ' + $LASTEXITCODE + '). The previous artifacts were left untouched.')
  }
}
$freshness = Test-ReleaseUninstallerFreshness -RepositoryRoot $RepoRoot
if (-not [bool]$freshness.Fresh -and -not $AllowStaleUninstaller) {
  Write-BuildLine ('Build stopped: ' + [string]$freshness.Reason + '.') 'Error'
  Write-BuildLine 'Run uninstaller/Build-Uninstaller.ps1 first (or pass -BuildUninstaller to do it here). Pass -AllowStaleUninstaller only when you know the binary is current.' 'Error'
  Exit-BuildFailure
}
if (-not [bool]$freshness.Fresh) {
  Write-BuildLine ('Proceeding with a possibly stale thin EXE because -AllowStaleUninstaller was passed: ' + [string]$freshness.Reason) 'Warn'
}

# ---- 2. managed entries: infrastructure + inventory-declared payload ------------------
$managedEntries = New-Object System.Collections.ArrayList
foreach ($entry in @(Get-ToolkitMember -Object $layout -Name 'managed' -Default @())) {
  $source = Assert-ReleasePathAllowed -RelativePath ([string](Get-ToolkitMember -Object $entry -Name 'source' -Default '')) -Origin 'layout.managed.source'
  $target = Assert-ReleasePathAllowed -RelativePath ([string](Get-ToolkitMember -Object $entry -Name 'path' -Default '')) -Origin 'layout.managed.path'
  [void]$managedEntries.Add((New-ToolkitJsonObject -Properties @{ path = $target; source = $source }))
}

$payloadRoot = Join-Path $RepoRoot ([string](Get-ToolkitMember -Object $layout -Name 'payloadRoot' -Default 'payload'))
$inventoryName = [string](Get-ToolkitMember -Object $layout -Name 'payloadInventory' -Default 'release/payload-inventory.json')
if (-not [string]::IsNullOrEmpty($PayloadInventory)) { $inventoryName = $PayloadInventory }
$payloadPresent = @(Get-ReleaseFileList -Root $payloadRoot)
$payloadIncluded = $payloadPresent.Count -gt 0

if (-not $payloadIncluded) {
  if (-not $AllowMissingPayload) {
    Write-BuildLine ('Payload is empty or missing at ' + (Get-ToolkitSafePath -Path $payloadRoot) + '. Build stopped: pass -AllowMissingPayload only when you knowingly want an infrastructure-only package.') 'Error'
    Exit-BuildFailure
  }
  Write-BuildLine 'Payload is missing; building an infrastructure-only package because -AllowMissingPayload was passed.' 'Warn'
}

$declaredPayload = New-Object System.Collections.ArrayList
$packagedDevelopmentPayload = New-Object System.Collections.ArrayList
$undeclaredPayload = New-Object System.Collections.ArrayList
if ($payloadIncluded) {
  # The inventory is toolkit-owned (release/payload-inventory.json) and required. Nothing is
  # ever inferred from a directory walk, and a payload-side COPY_FILE_LIST.json is never
  # packaged, installed or treated as an inventory (it is simply an undeclared payload file).
  $inventoryPath = Join-Path $RepoRoot (ConvertTo-ToolkitNativePath -RelativePath $inventoryName)
  if (-not (Test-Path -LiteralPath $inventoryPath -PathType Leaf)) {
    Exit-BuildFailure ('Payload inventory is missing: ' + (Get-ToolkitSafePath -Path $inventoryName) + '. The managed payload set is never guessed from a directory walk.')
  }
  $inventory = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $inventoryPath -Raw -Encoding UTF8)
  foreach ($declared in @(Get-ToolkitMember -Object $inventory -Name 'files' -Default @())) {
    $declaredPath = ([string](Get-ToolkitMember -Object $declared -Name 'path' -Default '')).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($declaredPath)) { continue }
    if ($declaredPath -eq 'COPY_FILE_LIST.json') {
      Exit-BuildFailure 'Build stopped: the payload inventory must not declare COPY_FILE_LIST.json as a managed file.'
    }
    if (-not ($payloadPresent -contains $declaredPath)) {
      Exit-BuildFailure ('Declared payload file is missing: ' + (Get-ToolkitSafePath -Path $declaredPath))
    }
    [void]$declaredPayload.Add($declaredPath)
  }
  # Development-only payload files (the public project's own tests): packaged so the release is
  # a faithful, auditable snapshot of the public payload, but NEVER added to the install
  # manifest. They are neither "declared managed" nor "undeclared".
  foreach ($development in @(Get-ToolkitMember -Object $inventory -Name 'releaseDevelopmentPaths' -Default @())) {
    $developmentPath = ([string]$development).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($developmentPath)) { continue }
    if (-not ($payloadPresent -contains $developmentPath)) {
      Exit-BuildFailure ('Declared development payload file is missing: ' + (Get-ToolkitSafePath -Path $developmentPath))
    }
    [void]$packagedDevelopmentPayload.Add($developmentPath)
  }
  if ($declaredPayload.Count -eq 0) {
    Exit-BuildFailure 'The payload inventory declares no files; refusing to build an empty payload.'
  }
  foreach ($present in $payloadPresent) {
    if ($declaredPayload -contains $present) { continue }
    if ($packagedDevelopmentPayload -contains $present) { continue }
    # payload/COPY_FILE_LIST.json is a payload-side inventory/metadata file: never declared,
    # never installed, and reported like any other undeclared payload file.
    [void]$undeclaredPayload.Add($present)
  }
}

if ($undeclaredPayload.Count -gt 0 -and -not $IncludeUndeclaredPayload) {
  Write-BuildLine ('Payload contains ' + $undeclaredPayload.Count + ' file(s) that the payload inventory does not declare; they are EXCLUDED from this release:') 'Warn'
  foreach ($entry in $undeclaredPayload) { Write-BuildLine ('  excluded ' + (Get-ToolkitSafePath -Path $entry)) 'Warn' }
  Write-BuildLine ('Declare them in ' + $inventoryName + ' if they must ship, or pass -IncludeUndeclaredPayload knowingly.') 'Warn'
}
elseif ($undeclaredPayload.Count -gt 0) {
  Write-BuildLine ('Including ' + $undeclaredPayload.Count + ' undeclared payload file(s) because -IncludeUndeclaredPayload was passed.') 'Warn'
  foreach ($entry in $undeclaredPayload) { [void]$declaredPayload.Add($entry) }
}

$payloadFiles = New-Object System.Collections.ArrayList
foreach ($relative in @($declaredPayload | Sort-Object -Unique)) {
  $target = Assert-ReleasePathAllowed -RelativePath ([string]$relative) -Origin 'payload'
  [void]$payloadFiles.Add([string]$target)
  [void]$managedEntries.Add((New-ToolkitJsonObject -Properties @{ path = $target; source = ('payload/' + $target) }))
}
$developmentPayloadFiles = New-Object System.Collections.ArrayList
foreach ($relative in @($packagedDevelopmentPayload | Sort-Object -Unique)) {
  $target = Assert-ReleasePathAllowed -RelativePath ([string]$relative) -Origin 'payload development'
  [void]$developmentPayloadFiles.Add([string]$target)
}
if ($developmentPayloadFiles.Count -gt 0) {
  Write-BuildLine ('Packaged development payload (never installed, install manifest unaffected): ' + $developmentPayloadFiles.Count + ' file(s).')
}

# ---- 3. owned staging directory ------------------------------------------------------
# Nothing is written into the final output location until the whole package is complete, and
# only the staging directory this tool created is ever removed.
if (-not (Test-Path -LiteralPath $OutputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$script:ReleaseStagingRoot = Join-Path $OutputDir ('.codex-dsh-team-toolkit-staging-' + [Guid]::NewGuid().ToString('n'))
$stagingPackageRoot = Join-Path $script:ReleaseStagingRoot ('codex-dsh-team-toolkit-v' + $Version)
New-Item -ItemType Directory -Path $stagingPackageRoot -Force | Out-Null
Write-BuildLine ('Staging      : ' + (Get-ToolkitSafePath -Path $script:ReleaseStagingRoot))

$stagingSources = New-Object System.Collections.ArrayList
foreach ($relative in @(Get-ToolkitMember -Object $layout -Name 'packageOnly' -Default @())) {
  [void]$stagingSources.Add([string]$relative)
}
foreach ($entry in @(Get-ToolkitMember -Object $layout -Name 'managed' -Default @())) {
  [void]$stagingSources.Add([string](Get-ToolkitMember -Object $entry -Name 'source' -Default ''))
}
foreach ($relative in @($developmentPayloadFiles | ForEach-Object { 'payload/' + $_ })) { [void]$stagingSources.Add([string]$relative) }
foreach ($relative in @($stagingSources | Sort-Object -Unique)) {
  $sourceRelative = [string]$relative
  if ([string]::IsNullOrEmpty($sourceRelative)) { continue }
  $sourceFull = Join-Path $RepoRoot (ConvertTo-ToolkitNativePath -RelativePath $sourceRelative)
  $destinationFull = Join-Path $stagingPackageRoot (ConvertTo-ToolkitNativePath -RelativePath $sourceRelative)
  $destinationDirectory = Split-Path -Parent $destinationFull
  if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
  }
  Copy-Item -LiteralPath $sourceFull -Destination $destinationFull -Force
}

foreach ($relative in $payloadFiles) {
  $sourceFull = Join-Path $payloadRoot (ConvertTo-ToolkitNativePath -RelativePath ([string]$relative))
  $destinationFull = Join-Path $stagingPackageRoot (ConvertTo-ToolkitNativePath -RelativePath ('payload/' + [string]$relative))
  $destinationDirectory = Split-Path -Parent $destinationFull
  if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
  }
  Copy-Item -LiteralPath $sourceFull -Destination $destinationFull -Force
}

# ---- 4. release manifest ---------------------------------------------------------------
$releaseManifestPath = Join-Path $stagingPackageRoot 'release-manifest.json'
[void](New-ToolkitReleaseManifest -PackageRoot $stagingPackageRoot -Version $Version -ManagedEntries $managedEntries.ToArray() -Destination $releaseManifestPath)

# The release contract: the package may ship public tests, but never metadata, markers, runtime
# state or credentials - and the managed INSTALL set must be runtime-only (fail-closed).
$packageContractProblems = @(Get-ReleaseForbiddenPackageProblems -Root $stagingPackageRoot)
if ($packageContractProblems.Count -gt 0) {
  foreach ($problem in $packageContractProblems) { Write-BuildLine $problem 'Error' }
  Exit-BuildFailure 'Build stopped: the staged package violates the release contract.'
}
$installSetProblems = @(Get-ReleaseInstallSetProblems -PackageRoot $stagingPackageRoot)
if ($installSetProblems.Count -gt 0) {
  foreach ($problem in $installSetProblems) { Write-BuildLine $problem 'Error' }
  Exit-BuildFailure 'Build stopped: the managed install set is not runtime-only.'
}

# No checksum artefact is produced: the release manifest is a location list, and release
# transport integrity belongs to the distribution channel. The installer's own protection of
# post-install user changes is the ownership manifest (pristine byte copies), not this build.
$checksumArtifacts = @(Get-ChildItem -LiteralPath $stagingPackageRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -eq 'SHA256SUMS.txt' -or $_.Name -like '*.sha256' })
if ($checksumArtifacts.Count -gt 0) {
  foreach ($artifact in $checksumArtifacts) {
    Write-BuildLine ('A checksum artefact must never be staged: ' + (Get-ReleaseRelativePath -Root $stagingPackageRoot -Path $artifact.FullName)) 'Error'
  }
  Exit-BuildFailure 'Build stopped: a checksum artefact was staged into the package.'
}

# ---- 5. scans over the whole staged package ------------------------------------------
foreach ($required in @(Get-ToolkitMember -Object $layout -Name 'releaseMustContain' -Default @())) {
  $requiredPath = Join-Path $stagingPackageRoot (ConvertTo-ToolkitNativePath -RelativePath ([string]$required))
  if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
    Write-BuildLine ('Staged package is missing a required file: ' + (Get-ToolkitSafePath -Path ([string]$required))) 'Error'
    Exit-BuildFailure
  }
}

$stagedFiles = @(Get-ReleaseFileList -Root $stagingPackageRoot)
foreach ($relative in $stagedFiles) {
  Assert-ReleasePathAllowed -RelativePath $relative -Origin 'staged package' | Out-Null
}

$contentScan = New-ToolkitJsonObject -Properties @{ performed = $false; blocked = @(); warnings = @(); bindings = @(); bindingWarnings = @(); scope = '' }
if (-not $SkipContentScan) {
  $allowList = @(Get-ReleaseAllowList -Values $ContentScanAllowlist)
  if ($allowList.Count -gt 0) {
    foreach ($allowlisted in $allowList) {
      Write-BuildLine ('Content scan allowlist entry (reviewed by the maintainer): ' + (Get-ToolkitSafePath -Path $allowlisted)) 'Warn'
    }
  }
  $scan = Invoke-ReleaseContentScan -Root $stagingPackageRoot -RelativePaths $stagedFiles -Allowlist $allowList -IncludeBindings
  $contentScan = New-ToolkitJsonObject -Properties @{
    performed       = $true
    scope           = 'whole package (text files)'
    blocked         = @($scan.Blocked)
    warnings        = @($scan.Warnings)
    bindings        = @($scan.Bindings)
    bindingWarnings = @($scan.BindingWarnings)
    allowlist       = @($allowList)
  }
  foreach ($warning in @($scan.Warnings)) {
    Write-BuildLine ('Content scan warning (self-identified fake/example value): ' + $warning) 'Warn'
  }
  foreach ($warning in @($scan.BindingWarnings)) {
    Write-BuildLine ('Binding scan review (fixed provider/model or allowlisted): ' + $warning) 'Warn'
  }
  if (@($scan.Bindings).Count -gt 0) {
    foreach ($hit in @($scan.Bindings)) { Write-BuildLine ('Binding scan blocked a fixed DSH home/version: ' + $hit) 'Error' }
    Write-BuildLine 'Build stopped: remove the fixed environment binding or allowlist the reviewed file.' 'Error'
    Exit-BuildFailure
  }
  if (@($scan.Blocked).Count -gt 0) {
    foreach ($hit in @($scan.Blocked)) { Write-BuildLine ('Content scan blocked a possible secret: ' + $hit) 'Error' }
    Write-BuildLine 'Build stopped: remove the value, mark the matched value itself as synthetic, or allowlist the reviewed file.' 'Error'
    Exit-BuildFailure
  }
}
else {
  Write-BuildLine 'Content scan skipped by explicit request (-SkipContentScan).' 'Warn'
  $contentScan = New-ToolkitJsonObject -Properties @{ performed = $false; blocked = @(); warnings = @(); bindings = @(); bindingWarnings = @(); skipped = $true }
}

# ---- 6. publish: move staging into place only now ------------------------------------
$packageName = 'codex-dsh-team-toolkit-v' + $Version
$packageRoot = Join-Path $OutputDir $packageName
$previousRoot = ''
if (Test-Path -LiteralPath $packageRoot) {
  $previousRoot = Join-Path $OutputDir ('.' + $packageName + '.previous-' + [Guid]::NewGuid().ToString('n'))
  Move-Item -LiteralPath $packageRoot -Destination $previousRoot
}
try {
  Move-Item -LiteralPath $stagingPackageRoot -Destination $packageRoot
}
catch {
  if (-not [string]::IsNullOrEmpty($previousRoot) -and (Test-Path -LiteralPath $previousRoot)) {
    Move-Item -LiteralPath $previousRoot -Destination $packageRoot
  }
  throw
}
if (-not [string]::IsNullOrEmpty($previousRoot) -and (Test-Path -LiteralPath $previousRoot)) {
  Remove-Item -LiteralPath $previousRoot -Recurse -Force
}

# ---- 7. zip ---------------------------------------------------------------------------
$zipPath = ''
if (-not $SkipZip) {
  $zipPath = Join-Path $OutputDir ($packageName + '.zip')
  $stagingZip = Join-Path $script:ReleaseStagingRoot ($packageName + '.zip')
  [void](New-ReleaseZip -Root $packageRoot -Destination $stagingZip)
  Move-Item -LiteralPath $stagingZip -Destination $zipPath -Force
}

# ---- 8. build report (outside the release, relative names only) -----------------------
$zipName = ''
if (-not [string]::IsNullOrEmpty($zipPath)) { $zipName = [System.IO.Path]::GetFileName($zipPath) }
$report = New-ToolkitJsonObject -Properties @{
  schema            = 'codex-dsh-team-toolkit/build-report/v1'
  version           = $Version
  builtAtUtc        = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  packageName       = $packageName
  managedFileCount  = $managedEntries.Count
  payloadIncluded   = $payloadIncluded
  payloadFileCount  = $payloadFiles.Count
  undeclaredPayload = @($undeclaredPayload)
  contentScan       = $contentScan
  zip               = $zipName
  installerFresh    = [bool]$installerFreshness.Fresh
  uninstallerFresh  = [bool]$freshness.Fresh
  checksumArtifacts = @()
  noHashContract    = 'no SHA256SUMS.txt, no .sha256 sidecar, no digest field in release metadata'
  networkUsed       = $false
}
Write-ToolkitJsonAtomic -Object $report -Destination (Join-Path $OutputDir 'build-report.json')

# ---- 9. clean up our own staging directory -------------------------------------------
if (Test-Path -LiteralPath $script:ReleaseStagingRoot) {
  $leftover = @(Get-ChildItem -LiteralPath $script:ReleaseStagingRoot -Force -Recurse -ErrorAction SilentlyContinue)
  if ($leftover.Count -eq 0) { Remove-Item -LiteralPath $script:ReleaseStagingRoot -Force }
  else { Write-BuildLine ('Staging directory still holds content and was kept: ' + (Get-ToolkitSafePath -Path $script:ReleaseStagingRoot)) 'Warn' }
}

Write-BuildLine ''
Write-BuildLine ('Package      : ' + (Get-ToolkitSafePath -Path $packageRoot))
if (-not [string]::IsNullOrEmpty($zipPath)) { Write-BuildLine ('Zip          : ' + (Get-ToolkitSafePath -Path $zipPath)) }
Write-BuildLine ('Managed files: ' + $managedEntries.Count + ' (payload included: ' + $payloadIncluded + ')')
Write-BuildLine 'Checksums    : none (no SHA256SUMS.txt, no .sha256 sidecar; release transport integrity belongs to the distribution channel)'
Write-BuildLine 'No network access and no push were performed.'
exit 0
