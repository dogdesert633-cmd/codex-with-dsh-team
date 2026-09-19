#Requires -Version 5.1
<#
  Shared test harness for the Codex x DSH Team Toolkit.

  Everything here uses temporary directories and fake credentials only. No real DSH
  configuration, credential store, runtime directory or network access is touched.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TKTestToolkitRoot = Split-Path -Parent $PSScriptRoot
$script:TKTestEnginePath = Join-Path $script:TKTestToolkitRoot 'install\Invoke-Toolkit.ps1'
$script:TKTestCaseResults = New-Object System.Collections.ArrayList
$script:TKTestTempRoots = New-Object System.Collections.ArrayList
$script:TKTestKeepTemp = $false
$script:TKTestCurrent = ''

# Exit codes mirrored from the engine contract.
$script:ExitOk = 0
$script:ExitUsage = 2
$script:ExitBlocked = 3
$script:ExitConflict = 4
$script:ExitManifest = 5
$script:ExitTransaction = 6
$script:ExitRollback = 7
$script:ExitCancelled = 8

# The engine is dot-sourced as a library so tests exercise the exact production code.
. $script:TKTestEnginePath -Library

# Release helpers (checksum/layout/freshness assertions) are shared with the release tools, so
# the tests assert exactly what Build/Verify assert.
. (Join-Path $script:TKTestToolkitRoot 'tools\Release.Common.ps1')

# Test-only engine features (fault injection, keeping transaction evidence) are gated behind
# this environment variable; a normal release invocation cannot reach them without it.
$env:CODEX_DSH_TOOLKIT_TEST = '1'

function Invoke-ToolkitTestBuildRelease {
  param(
    [string]$RepoRoot,
    [string[]]$ExtraArguments = @(),
    [string]$Version = '1.0.0'
  )
  $arguments = @('-RepoRoot', $RepoRoot, '-Version', $Version) + $ExtraArguments
  return (Invoke-ToolkitTestCli -Arguments $arguments -EnginePath (Join-Path $script:TKTestToolkitRoot 'tools\Build-Release.ps1'))
}

function Invoke-ToolkitTestVerifyRelease {
  param(
    [string]$Package,
    [string[]]$ExtraArguments = @()
  )
  $arguments = @('-Package', $Package) + $ExtraArguments
  return (Invoke-ToolkitTestCli -Arguments $arguments -EnginePath (Join-Path $script:TKTestToolkitRoot 'tools\Verify-Release.ps1'))
}

function Get-ToolkitTestUninstallerExe {
  <#
    Returns a current thin uninstaller EXE, rebuilding it when it is missing or older than its
    own source/recipe (a stale shell must never be exercised by a test).
  #>
  $exePath = Join-Path $script:TKTestToolkitRoot 'uninstaller\CodexDshTeamToolkit.Uninstall.exe'
  $needsBuild = -not (Test-Path -LiteralPath $exePath -PathType Leaf)
  if (-not $needsBuild) {
    $freshness = Test-ReleaseUninstallerFreshness -RepositoryRoot $script:TKTestToolkitRoot
    if (-not [bool]$freshness.Fresh) {
      Write-ToolkitTestNote ('rebuilding the thin uninstaller EXE: ' + [string]$freshness.Reason)
      $needsBuild = $true
    }
  }
  if ($needsBuild) {
    $build = Invoke-ToolkitTestCli -Arguments @('-Quiet') -EnginePath (Join-Path $script:TKTestToolkitRoot 'uninstaller\Build-Uninstaller.ps1')
    if ($build.ExitCode -ne 0) {
      throw ('The thin uninstaller EXE could not be built (csc.exe prerequisite missing): ' + $build.Output)
    }
  }
  if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw 'The thin uninstaller EXE is missing after the build.'
  }
  return $exePath
}

function Invoke-ToolkitTestNode {
  <#
    Runs Node with an explicit argument vector (never a quoted -e payload: Windows PowerShell 5.1
    mangles embedded double quotes when passing native arguments) and with native stderr
    tolerated, so a diagnostic line cannot abort the test through $ErrorActionPreference='Stop'.
  #>
  param(
    [string[]]$Arguments,
    [string]$NodePath = '',
    [string]$WorkingDirectory = '',
    [int]$TimeoutSeconds = 240
  )

  if ([string]::IsNullOrEmpty($NodePath)) {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $node) { return $null }
    $NodePath = $node.Source
  }

  $job = Start-Job -ScriptBlock {
    param($Node, $Argv, $Directory)
    $ErrorActionPreference = 'Continue'
    if (-not [string]::IsNullOrEmpty($Directory)) { Set-Location -LiteralPath $Directory }
    $output = & $Node @Argv 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
  } -ArgumentList $NodePath, $Arguments, $WorkingDirectory

  $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds
  if ($null -eq $finished) {
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return (New-ToolkitJsonObject -Properties @{
        ExitCode = -1
        Output   = ('node did not finish within ' + $TimeoutSeconds + ' seconds; it was killed')
        TimedOut = $true
      })
  }
  $result = Receive-Job -Job $job
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
  return (New-ToolkitJsonObject -Properties @{
      ExitCode = [int]$result.ExitCode
      Output   = [string]$result.Output
      TimedOut = $false
    })
}

function Invoke-ToolkitTestNative {
  <#
    Runs a native command and returns exit code + combined output, with stderr tolerated.
    Windows PowerShell 5.1 turns a native stderr write into a terminating error when
    $ErrorActionPreference is 'Stop', which would otherwise mask the real exit code.
  #>
  param([scriptblock]$Command)

  $previous = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $Command 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previous
  }
  return (New-ToolkitJsonObject -Properties @{ ExitCode = $exitCode; Output = $output })
}

function Get-ToolkitTestInstallerExe {
  <#
    Returns a current thin installer EXE, rebuilding it when it is missing or older than its own
    source/recipe (a stale shell must never be exercised by a test).
  #>
  $exePath = Join-Path $script:TKTestToolkitRoot 'CodexDshTeamToolkit.Install.exe'
  $needsBuild = -not (Test-Path -LiteralPath $exePath -PathType Leaf)
  if (-not $needsBuild) {
    $freshness = Test-ReleaseInstallerFreshness -RepositoryRoot $script:TKTestToolkitRoot
    if (-not [bool]$freshness.Fresh) {
      Write-ToolkitTestNote ('rebuilding the thin installer EXE: ' + [string]$freshness.Reason)
      $needsBuild = $true
    }
  }
  if ($needsBuild) {
    $build = Invoke-ToolkitTestCli -Arguments @('-Quiet') -EnginePath (Join-Path $script:TKTestToolkitRoot 'installer\Build-Installer.ps1')
    if ($build.ExitCode -ne 0) {
      throw ('The thin installer EXE could not be built (csc.exe prerequisite missing): ' + $build.Output)
    }
  }
  if (-not (Test-Path -LiteralPath $exePath -PathType Leaf)) {
    throw 'The thin installer EXE is missing after the build.'
  }
  return $exePath
}

function Invoke-ToolkitTestExe {
  <#
    Runs a thin EXE and returns its real process exit code plus combined output. A GUI-subsystem
    EXE is not reliably waited for by a bare `&`, so the process object is used.
  #>
  param(
    [string]$ExePath,
    [string[]]$Arguments = @()
  )

  $outputFile = Join-Path ([System.IO.Path]::GetTempPath()) ('toolkit-exe-' + [Guid]::NewGuid().ToString('n') + '.txt')
  $errorFile = Join-Path ([System.IO.Path]::GetTempPath()) ('toolkit-exe-' + [Guid]::NewGuid().ToString('n') + '.err')
  try {
    $process = Start-Process -FilePath $ExePath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow `
      -RedirectStandardOutput $outputFile -RedirectStandardError $errorFile
    $combined = ''
    foreach ($file in @($outputFile, $errorFile)) {
      if (Test-Path -LiteralPath $file -PathType Leaf) {
        $combined = $combined + (Get-Content -LiteralPath $file -Raw -Encoding UTF8)
      }
    }
    return (New-ToolkitJsonObject -Properties @{ ExitCode = [int]$process.ExitCode; Output = $combined })
  }
  finally {
    Remove-Item -LiteralPath $outputFile, $errorFile -Force -ErrorAction SilentlyContinue
  }
}

function New-ToolkitTestDirectory {
  param([string]$Label = 'case')

  $base = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-dsh-toolkit-' + $Label + '-' + [Guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  [void]$script:TKTestTempRoots.Add($base)
  return $base
}

function Remove-ToolkitTestArtifacts {
  if ($script:TKTestKeepTemp) {
    Write-Host ('[keep] temporary test roots retained under ' + [System.IO.Path]::GetTempPath())
    return
  }
  foreach ($root in @($script:TKTestTempRoots)) {
    try {
      if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    catch { }
  }
}

function Write-ToolkitTestFile {
  param(
    [string]$Path,
    [string]$Content
  )
  $directory = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Test-Case {
  param(
    [string]$Name,
    [scriptblock]$Body
  )

  $script:TKTestCurrent = $Name
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    & $Body
    $stopwatch.Stop()
    [void]$script:TKTestCaseResults.Add((New-ToolkitJsonObject -Properties @{ Name = $Name; Passed = $true; Reason = ''; Milliseconds = $stopwatch.ElapsedMilliseconds }))
    Write-Host ('  PASS  ' + $Name + ' (' + $stopwatch.ElapsedMilliseconds + ' ms)') -ForegroundColor Green
  }
  catch {
    $stopwatch.Stop()
    $reason = Get-ToolkitSafeText -Text $_.Exception.Message
    [void]$script:TKTestCaseResults.Add((New-ToolkitJsonObject -Properties @{ Name = $Name; Passed = $false; Reason = $reason; Milliseconds = $stopwatch.ElapsedMilliseconds }))
    Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red
    Write-Host ('        ' + $reason) -ForegroundColor Red
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw ('assertion failed: ' + $Message) }
}

function Assert-False {
  param([bool]$Condition, [string]$Message)
  if ($Condition) { throw ('assertion failed (expected false): ' + $Message) }
}

function Assert-Equal {
  param($Expected, $Actual, [string]$Message)
  if ([string]$Expected -cne [string]$Actual) {
    throw ('assertion failed: ' + $Message + ' (expected "' + [string]$Expected + '", actual "' + [string]$Actual + '")')
  }
}

function Assert-NotEqual {
  param($Expected, $Actual, [string]$Message)
  if ([string]$Expected -ceq [string]$Actual) {
    throw ('assertion failed: ' + $Message + ' (both values are "' + [string]$Actual + '")')
  }
}

function Assert-Match {
  param([string]$Text, [string]$Pattern, [string]$Message)
  if ([string]$Text -notmatch $Pattern) {
    throw ('assertion failed: ' + $Message + ' (pattern "' + $Pattern + '" not found)')
  }
}

function Assert-NotMatch {
  param([string]$Text, [string]$Pattern, [string]$Message)
  if ([string]$Text -match $Pattern) {
    throw ('assertion failed: ' + $Message + ' (pattern "' + $Pattern + '" unexpectedly present)')
  }
}

function Assert-FileExists {
  param([string]$Path, [string]$Message = '')
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw ('assertion failed: file should exist: ' + (Get-ToolkitSafePath -Path $Path) + ' ' + $Message)
  }
}

function Assert-FileMissing {
  param([string]$Path, [string]$Message = '')
  if (Test-Path -LiteralPath $Path) {
    throw ('assertion failed: path should not exist: ' + (Get-ToolkitSafePath -Path $Path) + ' ' + $Message)
  }
}

function Assert-DirectoryExists {
  param([string]$Path, [string]$Message = '')
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw ('assertion failed: directory should exist: ' + (Get-ToolkitSafePath -Path $Path) + ' ' + $Message)
  }
}

function Assert-ToolkitThrows {
  param(
    [scriptblock]$Body,
    [string]$Message
  )
  $threw = $false
  try { & $Body }
  catch { $threw = $true }
  if (-not $threw) { throw ('assertion failed: expected a refusal: ' + $Message) }
}

function Assert-ToolkitDoesNotThrow {
  param(
    [scriptblock]$Body,
    [string]$Message
  )
  try { & $Body }
  catch { throw ('assertion failed: expected success: ' + $Message + ' (' + (Get-ToolkitSafeText -Text $_.Exception.Message) + ')') }
}

function Write-ToolkitTestNote {
  param([string]$Text)
  Write-Host ('        note: ' + $Text) -ForegroundColor DarkGray
}

function Get-ToolkitTestTreeSnapshot {
  <#
    Snapshot of every file below a root: relative path, byte length and last-write time. The
    timestamp is part of the snapshot so "nothing was written" cannot be satisfied by a
    rewrite that happens to produce identical bytes, and no digest is computed anywhere.
  #>
  param([string]$Root)

  $lines = New-Object System.Collections.ArrayList
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $lines.ToArray() }
  $prefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\').Length + 1
  foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue | Sort-Object FullName)) {
    $relative = $file.FullName.Substring($prefix)
    [void]$lines.Add($relative + '|' + $file.Length + '|' + $file.LastWriteTimeUtc.ToString('o'))
  }
  return $lines.ToArray()
}

function Get-ToolkitTestContentSnapshot {
  <#
    Content-only snapshot (path + length, no timestamp). Use this when a run legitimately
    appends to an append-only log.
  #>
  param([string]$Root)

  $lines = New-Object System.Collections.ArrayList
  foreach ($entry in @(Get-ToolkitTestTreeSnapshot -Root $Root)) {
    $parts = ([string]$entry).Split('|')
    [void]$lines.Add($parts[0] + '|' + $parts[1])
  }
  return $lines.ToArray()
}

function Test-ToolkitTestSameContent {
  <#
    Direct byte comparison of two files (no digest). Returns $false when either file is missing.
  #>
  param(
    [string]$PathA,
    [string]$PathB
  )

  return (Test-ToolkitFileContentEqual -PathA $PathA -PathB $PathB)
}

function Assert-ToolkitTestSameContent {
  param(
    [string]$PathA,
    [string]$PathB,
    [string]$Reason = ''
  )

  if (-not (Test-ToolkitTestSameContent -PathA $PathA -PathB $PathB)) {
    $message = 'files are not byte-identical: ' + (Get-ToolkitSafePath -Path $PathA) + ' vs ' + (Get-ToolkitSafePath -Path $PathB)
    if (-not [string]::IsNullOrEmpty($Reason)) { $message = $Reason + ' (' + $message + ')' }
    throw (New-Object System.Exception($message))
  }
}

function Test-ToolkitTestSnapshotEqual {
  <#
    Compares two snapshots line by line (path, length, timestamp).
  #>
  param(
    [object[]]$Baseline,
    [object[]]$Current
  )

  return ((@($Baseline) -join ';') -ceq (@($Current) -join ';'))
}

function New-ToolkitTestSentinel {
  <#
    Creates a sentinel file and returns its *path + a copy of its bytes*, so a test can prove
    that nothing outside the project (or nothing belonging to another skill) was touched by
    comparing bytes directly.
  #>
  param(
    [string]$Path,
    [string]$Content = 'sentinel - must never change'
  )

  Write-ToolkitTestFile -Path $Path -Content $Content
  return $Path
}

function Get-ToolkitTestManagedSnapshot {
  <#
    Snapshot of project content plus installed managed files: the toolkit state directory
    (log, journal, backups, ledger) is excluded so a comparison proves that no managed or
    user file changed.
  #>
  param([string]$Root)

  $managed = New-Object System.Collections.ArrayList
  foreach ($item in @(Get-ToolkitTestTreeSnapshot -Root $Root)) {
    if ([string]$item -like '.codex-dsh-team-toolkit\*') { continue }
    [void]$managed.Add([string]$item)
  }
  return $managed.ToArray()
}

function Get-ToolkitTestOutput {
  param($Result)
  return (@($Result.Lines) -join [Environment]::NewLine)
}

function Invoke-ToolkitTestCommand {
  param([hashtable]$Options)

  $defaults = @{
    Action            = 'Install'
    Target            = ''
    PackageRoot       = ''
    ReleaseManifest   = ''
    PlanOnly          = $false
    # The engine requires an explicit confirmation for every mutating operation. Tests are
    # automation, so they confirm explicitly; the refusal path is tested on purpose.
    Yes               = $true
    NonInteractive    = $false
    Quiet             = $false
    TeamDshHome       = ''
    RuntimeRootBase   = ''
    InitializeRuntime = $false
    TestFault         = ''
    TestMode          = $false
    TestConfirmation  = ''
    TestKeepTransaction = $false
    UninstallerSelf   = ''
    ClearStaleLock    = $false
    EnginePath        = $script:TKTestEnginePath
  }
  foreach ($key in $Options.Keys) { $defaults[$key] = $Options[$key] }
  return (Invoke-ToolkitCommand -Options $defaults)
}

function New-ToolkitTestPayload {
  param([hashtable]$Overrides)

  $files = @{
    '.agents/skills/codex-dsh-team/SKILL.md'   = "# Codex x DSH Team (fake payload)`nversion 1`n"
    '.agents/skills/codex-dsh-team/roles/coder.md' = "# coder role (fake)`n"
    '.agents/skills/mcp-to-dsh/SKILL.md'       = "# mcp-to-dsh (fake payload)`nversion 1`n"
    '.agents/skills/mcp-to-dsh/public/app.js'  = "console.log('fake monitor');`n"
    'start_dsh_team.cmd'                       = "@echo off`r`necho fake start`r`n"
    'sync_dsh_team_config.cmd'                 = "@echo off`r`necho fake sync`r`n"
  }
  if ($null -ne $Overrides) {
    foreach ($key in $Overrides.Keys) {
      if ($null -eq $Overrides[$key]) { $files.Remove($key) } else { $files[$key] = $Overrides[$key] }
    }
  }
  return $files
}

function New-ToolkitTestPackage {
  <#
    Builds a fake release package (payload + engine + thin uninstaller placeholder)
    with a real, engine-generated release manifest.
  #>
  param(
    [string]$Root,
    [string]$Version = '1.0.0',
    [hashtable]$PayloadFiles,
    [switch]$WithoutEngine,
    [switch]$WithoutUninstaller,
    [string]$UninstallerExePath = '',
    [string]$InstallerExePath = ''
  )

  if ($null -eq $PayloadFiles) { $PayloadFiles = New-ToolkitTestPayload }
  New-Item -ItemType Directory -Path $Root -Force | Out-Null

  $entries = New-Object System.Collections.ArrayList
  foreach ($relative in @($PayloadFiles.Keys | Sort-Object)) {
    $target = Join-Path $Root ('payload\' + ($relative -replace '/', '\'))
    Write-ToolkitTestFile -Path $target -Content ([string]$PayloadFiles[$relative])
    [void]$entries.Add((New-ToolkitJsonObject -Properties @{ path = $relative; source = ('payload/' + $relative) }))
  }

  if (-not $WithoutEngine) {
    $engineSource = Join-Path $Root 'install\Invoke-Toolkit.ps1'
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($engineSource)) | Out-Null
    [IO.File]::Copy($script:TKTestEnginePath, $engineSource, $true)
    [void]$entries.Add((New-ToolkitJsonObject -Properties @{
          path   = '.codex-dsh-team-toolkit/engine/Invoke-Toolkit.ps1'
          source = 'install/Invoke-Toolkit.ps1'
        }))
  }

  if (-not $WithoutUninstaller) {
    $exeSource = Join-Path $Root 'uninstaller\CodexDshTeamToolkit.Uninstall.exe'
    if (-not [string]::IsNullOrEmpty($UninstallerExePath)) {
      if (-not (Test-Path -LiteralPath $UninstallerExePath -PathType Leaf)) {
        throw ('The real uninstaller EXE was requested but not found: ' + (Get-ToolkitSafePath -Path $UninstallerExePath))
      }
      $exeDirectory = Split-Path -Parent $exeSource
      if (-not (Test-Path -LiteralPath $exeDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $exeDirectory -Force | Out-Null
      }
      Copy-Item -LiteralPath $UninstallerExePath -Destination $exeSource -Force
    }
    else {
      Write-ToolkitTestFile -Path $exeSource -Content 'FAKE-FRAMEWORK-DEPENDENT-EXE-PLACEHOLDER'
    }
    [void]$entries.Add((New-ToolkitJsonObject -Properties @{
          path   = 'CodexDshTeamToolkit.Uninstall.exe'
          source = 'uninstaller/CodexDshTeamToolkit.Uninstall.exe'
        }))
  }

  # The installer EXE sits at the PACKAGE ROOT (next to Install.cmd) and is deliberately NOT a
  # managed entry: it is a launcher, never installed into a user project and never recorded in
  # an ownership ledger.
  if (-not [string]::IsNullOrEmpty($InstallerExePath)) {
    if (-not (Test-Path -LiteralPath $InstallerExePath -PathType Leaf)) {
      throw ('The real installer EXE was requested but not found: ' + (Get-ToolkitSafePath -Path $InstallerExePath))
    }
    Copy-Item -LiteralPath $InstallerExePath -Destination (Join-Path $Root 'CodexDshTeamToolkit.Install.exe') -Force
  }

  $manifestPath = Join-Path $Root 'release-manifest.json'
  [void](New-ToolkitReleaseManifest -PackageRoot $Root -Version $Version -ManagedEntries $entries.ToArray() -Destination $manifestPath)
  return (New-ToolkitJsonObject -Properties @{
      Root         = $Root
      ManifestPath = $manifestPath
      Version      = $Version
      Entries      = $entries.ToArray()
    })
}

function New-ToolkitTestProject {
  param([string]$Root)

  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $Root 'README.md') -Content "# target project`n"
  Write-ToolkitTestFile -Path (Join-Path $Root 'src\app.js') -Content "console.log('user source');`n"
  return $Root
}

function New-ToolkitTestRepo {
  <#
    Copies this repository's non-payload infrastructure into a temporary repository so the
    release tools can be exercised without touching the working tree.

    The payload inventory (payload/COPY_FILE_LIST.json) is written to declare exactly the
    supplied payload files, mirroring the frozen-inventory contract.
  #>
  param(
    [string]$Root,
    [hashtable]$PayloadFiles,
    [switch]$WithoutPayload,
    [switch]$WithoutInventory,
    [object[]]$InventoryPaths = @()
  )

  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  foreach ($relative in @(
      'Install.cmd', 'README.md', 'README.zh-CN.md', 'LICENSE', 'CHANGELOG.md',
      'install\Invoke-Toolkit.ps1',
      'CodexDshTeamToolkit.Install.exe',
      'installer\Build-Installer.ps1', 'installer\src\Installer.cs',
      'uninstaller\CodexDshTeamToolkit.Uninstall.exe',
      'uninstaller\Build-Uninstaller.ps1', 'uninstaller\src\Uninstaller.cs',
      'release\package-layout.json', 'release\payload-inventory.json', 'release\release-manifest.schema.json', 'release\ownership-manifest.schema.json',
      'tools\Build-Release.ps1', 'tools\Verify-Release.ps1', 'tools\Release.Common.ps1',
      'docs\INSTALLATION.md', 'docs\CONFIGURATION.md', 'docs\SECURITY.md', 'docs\TROUBLESHOOTING.md'
    )) {
    $source = Join-Path $script:TKTestToolkitRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
      throw ('The test repository needs this file but it is missing: ' + (Get-ToolkitSafePath -Path $source))
    }
    $destination = Join-Path $Root $relative
    $destinationDirectory = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
      New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $source -Destination $destination -Force
  }

  if (-not $WithoutPayload) {
    if ($null -eq $PayloadFiles) { $PayloadFiles = New-ToolkitTestPayload }
    foreach ($relative in @($PayloadFiles.Keys | Sort-Object)) {
      Write-ToolkitTestFile -Path (Join-Path $Root ('payload\' + ($relative -replace '/', '\'))) -Content ([string]$PayloadFiles[$relative])
    }
    if (-not $WithoutInventory) {
      $inventoryTarget = Join-Path $Root 'release\payload-inventory.json'
      # Two sets, mirroring the real inventory: `files` is the managed INSTALL set (runtime
      # only) and `releaseDevelopmentPaths` is packaged for transparency but never installed.
      $declared = New-Object System.Collections.ArrayList
      $development = New-Object System.Collections.ArrayList
      $allPaths = New-Object System.Collections.ArrayList
      if (@($InventoryPaths).Count -gt 0) {
        foreach ($item in @($InventoryPaths)) {
          [void]$allPaths.Add(([string]$item).Replace('\', '/'))
        }
      }
      else {
        foreach ($relative in @($PayloadFiles.Keys | Sort-Object)) {
          [void]$allPaths.Add(([string]$relative).Replace('\', '/'))
        }
      }
      foreach ($relative in @($allPaths)) {
        if ($relative -match '(^|/)test/') { [void]$development.Add([string]$relative) }
        else { [void]$declared.Add((New-ToolkitJsonObject -Properties @{ path = [string]$relative })) }
      }
      $inventory = New-ToolkitJsonObject -Properties @{
        name                    = 'codex-dsh-team-toolkit'
        version                 = '3.2.0'
        purpose                 = 'relative-path-only install inventory for tests; development tests are packaged but never installed'
        secrets_included        = $false
        file_count              = $declared.Count
        files                   = $declared.ToArray()
        releaseDevelopmentPaths = $development.ToArray()
      }
      Write-ToolkitJsonAtomic -Object $inventory -Destination $inventoryTarget
    }
    else {
      # -WithoutInventory: the copied repository must carry no inventory at all
      $copiedInventory = Join-Path $Root 'release\payload-inventory.json'
      if (Test-Path -LiteralPath $copiedInventory -PathType Leaf) { Remove-Item -LiteralPath $copiedInventory -Force }
    }
  }
  return $Root
}

function Get-ToolkitTestPowerShellPath {
  $candidates = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrEmpty($PSHOME)) {
    [void]$candidates.Add((Join-Path $PSHOME 'pwsh.exe'))
    [void]$candidates.Add((Join-Path $PSHOME 'powershell.exe'))
  }
  [void]$candidates.Add((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  throw 'No PowerShell host found for CLI tests.'
}

function Invoke-ToolkitTestCli {
  <#
    Runs the real engine as a separate process so exit codes and non-interactive
    behaviour are validated end to end.
  #>
  param(
    [string[]]$Arguments,
    [string]$EnginePath = ''
  )

  if ([string]::IsNullOrEmpty($EnginePath)) { $EnginePath = $script:TKTestEnginePath }
  $hostPath = Get-ToolkitTestPowerShellPath
  $output = & $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $EnginePath @Arguments 2>&1 | Out-String
  $exitCode = $LASTEXITCODE
  return (New-ToolkitJsonObject -Properties @{ ExitCode = $exitCode; Output = $output })
}
