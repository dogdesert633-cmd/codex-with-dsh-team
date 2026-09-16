#Requires -Version 5.1
<#
  Test runner for the Codex x DSH Team Toolkit.

    pwsh -File tests/Run-Tests.ps1
    pwsh -File tests/Run-Tests.ps1 -Filter '03-*'
    pwsh -File tests/Run-Tests.ps1 -KeepTemp

  Exits 0 when every case passes, 1 otherwise. No network access is used and no real
  DSH configuration, credential store, runtime directory or repository outside the
  toolkit is touched.
#>
[CmdletBinding()]
param(
  [string]$Filter = '*',
  [switch]$KeepTemp,
  [switch]$ListOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'TestHarness.ps1')
$script:TKTestKeepTemp = [bool]$KeepTemp

# The harness sets CODEX_DSH_TOOLKIT_TEST=1 for the test features. Restore whatever the caller
# had so a test run never changes the environment for the process that started it.
$script:TKTestGatePrevious = $env:CODEX_DSH_TOOLKIT_TEST

$caseDirectory = Join-Path $PSScriptRoot 'cases'
$caseFiles = @(Get-ChildItem -LiteralPath $caseDirectory -Filter '*.tests.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)

if ($ListOnly) {
  $env:CODEX_DSH_TOOLKIT_TEST = $script:TKTestGatePrevious
  foreach ($case in $caseFiles) { Write-Host $case.Name }
  exit 0
}

Write-Host ''
Write-Host 'Codex x DSH Team Toolkit - core engine tests'
Write-Host ('Host: ' + $PSVersionTable.PSVersion.ToString() + '  Temp roots are used for every case.')
Write-Host ('Toolkit root: ' + $script:TKTestToolkitRoot)
Write-Host ''

foreach ($case in $caseFiles) {
  if ($Filter -ne '*' -and $case.Name -notlike $Filter) { continue }
  Write-Host ('== ' + $case.Name + ' ==') -ForegroundColor Cyan
  . $case.FullName
}

$passed = @($script:TKTestCaseResults | Where-Object { $_.Passed })
$failed = @($script:TKTestCaseResults | Where-Object { -not $_.Passed })

Write-Host ''
Write-Host ('Cases run: ' + @($script:TKTestCaseResults).Count + '  passed: ' + $passed.Count + '  failed: ' + $failed.Count)
if ($failed.Count -gt 0) {
  foreach ($case in $failed) { Write-Host ('  FAILED: ' + $case.Name + ' :: ' + $case.Reason) -ForegroundColor Red }
}

Remove-ToolkitTestArtifacts
$env:CODEX_DSH_TOOLKIT_TEST = $script:TKTestGatePrevious

if ($failed.Count -gt 0) { exit 1 }
if (@($script:TKTestCaseResults).Count -eq 0) {
  Write-Host 'No test cases matched the filter.' -ForegroundColor Yellow
  exit 1
}
exit 0
