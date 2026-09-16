#Requires -Version 5.1
<#
  09 - the thin uninstaller EXE: build, plan-only, unattended uninstall, residual handling.

  The EXE is only a shell: these tests prove it locates the project, shows the plan, calls
  the same engine and forwards the exit code. All ownership decisions are the engine's and are
  covered by cases 01-07.
#>

Test-Case -Name 'uninstaller exe: the built shell is small and single purpose' -Body {
  $exePath = Get-ToolkitTestUninstallerExe
  $size = (Get-Item -LiteralPath $exePath).Length
  Assert-True ($size -gt 0) 'the EXE must exist and be non-empty'
  Assert-True ($size -lt 204800) ('the EXE must stay thin (a few tens of KB), actual ' + $size + ' bytes')
  Write-ToolkitTestNote ('thin uninstaller size: ' + $size + ' bytes')

  # the source must stay a pure shell: it may not embed monitor/team/DSH code of its own
  $source = Get-Content -LiteralPath (Join-Path $script:TKTestToolkitRoot 'uninstaller\src\Uninstaller.cs') -Raw
  Assert-NotMatch $source '(?i)HttpListener|HttpClient|WebClient|System\.Net\.Sockets' 'the shell must not host a server or use the network'
  Assert-NotMatch $source '(?i)server\.mjs|app\.js|node_modules|codex-dsh-team\\SKILL' 'the shell must not embed monitor/team code'
  Assert-Match $source 'Invoke-Toolkit\.ps1' 'the shell must delegate to the engine'
}

Test-Case -Name 'uninstaller exe: plan-only writes nothing and --yes uninstalls unattended' -Body {
  $exePath = Get-ToolkitTestUninstallerExe
  $base = New-ToolkitTestDirectory -Label 'exe-e2e'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -UninstallerExePath $exePath
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $installedExe = Join-Path $project 'CodexDshTeamToolkit.Uninstall.exe'
  Assert-FileExists $installedExe 'the thin uninstaller must be installed into the project'
  # Direct byte comparison (no digest): the installed EXE must be the built one.
  Assert-Equal ([System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($exePath))) ([System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($installedExe))) 'the installed EXE must be the built one'

  # 1) plan-only: zero writes
  $before = Get-ToolkitTestTreeSnapshot -Root $project
  & $installedExe --plan-only --target $project --no-ui 2>&1 | Out-Null
  Assert-Equal 0 $LASTEXITCODE 'plan-only must succeed'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'plan-only must not write'

  # 2) unattended uninstall through the EXE
  $output = & $installedExe --target $project --yes --no-ui 2>&1 | Out-String
  Assert-Equal 0 $LASTEXITCODE ('the EXE must forward the engine exit code: ' + $output)
  foreach ($entry in @($package.Entries)) {
    if ([string]$entry.path -eq 'CodexDshTeamToolkit.Uninstall.exe') { continue }
    Assert-FileMissing (Join-Path $project ([string]$entry.path -replace '/', '\')) ('managed file must be gone: ' + [string]$entry.path)
  }
  Assert-FileExists (Join-Path $project 'src\app.js') 'user files must survive the EXE uninstall'

  # 3) the in-use EXE is reported as a minimal residual and keeps its ownership record,
  #    so a later run can still finish the job without guessing
  if (Test-Path -LiteralPath $installedExe) {
    Assert-Match $output 'Residual' 'the residual must be reported'
    $ledger = Join-Path $project '.codex-dsh-team-toolkit\manifest.json'
    Assert-FileExists $ledger 'the residual keeps ownership evidence for a later run'
    $ownership = Read-ToolkitOwnershipManifest -Path $ledger
    Assert-Equal 1 @($ownership.files).Count 'only the residual may remain in the ledger'
    Assert-Equal 'CodexDshTeamToolkit.Uninstall.exe' ([string]($ownership.files[0].path))
  }

  # 4) the EXE schedules its own deletion; once it is gone the engine can finish cleanly
  $deadline = (Get-Date).AddSeconds(20)
  while ((Test-Path -LiteralPath $installedExe) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
  }
  if (Test-Path -LiteralPath $installedExe) {
    Write-ToolkitTestNote 'the scheduled self-deletion had not completed yet; finishing with the engine'
  }
  $finish = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $finish.ExitCode ('the follow-up run must finish the uninstall: ' + (Get-ToolkitTestOutput $finish))
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') 'the state directory must be gone once nothing is owned any more'
  Assert-FileExists (Join-Path $project 'README.md') 'user files still survive'
}

Test-Case -Name 'uninstaller exe: an unusable target is refused with a non-zero code and no deletion' -Body {
  $exePath = Get-ToolkitTestUninstallerExe
  $base = New-ToolkitTestDirectory -Label 'exe-refuse'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Write-ToolkitTestFile -Path (Join-Path $project 'keep-me.md') -Content "# keep`n"

  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $exePath --target $project --yes --no-ui 2>&1 | Out-String
    $refuseExit = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $previousPreference }
  Assert-True ($refuseExit -ne 0) ('a project without a ledger must be refused: ' + $output)
  Assert-FileExists (Join-Path $project 'keep-me.md') 'nothing may be deleted'
  Assert-FileExists (Join-Path $project 'src\app.js')

  # a project that does not exist at all is also refused
  $missing = Join-Path $base 'nope'
  $ErrorActionPreference = 'Continue'
  try {
    $output2 = & $exePath --target $missing --yes --no-ui 2>&1 | Out-String
    $missingExit = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $previousPreference }
  Assert-True ($missingExit -ne 0) 'a missing target must be refused'
  Assert-FileMissing $missing
}

Test-Case -Name 'uninstaller exe: the project is derived from the installed location without --target' -Body {
  $exePath = Get-ToolkitTestUninstallerExe
  $base = New-ToolkitTestDirectory -Label 'exe-derive'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -UninstallerExePath $exePath
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $installedExe = Join-Path $project 'CodexDshTeamToolkit.Uninstall.exe'
  $output = & $installedExe --yes --no-ui 2>&1 | Out-String
  Assert-Equal 0 $LASTEXITCODE ('the installed EXE must find its own project: ' + $output)
  Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd')
  Assert-FileExists (Join-Path $project 'README.md')
}
