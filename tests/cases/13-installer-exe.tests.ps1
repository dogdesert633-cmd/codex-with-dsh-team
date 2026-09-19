#Requires -Version 5.1
<#
  13 - the thin installer EXE: build, package-root discovery, plan-only, unattended install,
  target/engine rejection and exit-code forwarding.

  The EXE is only a shell: it locates the extracted release package and the target project,
  shows the plan the engine produces, asks for confirmation, then calls the same engine and
  forwards its exit code. Every ownership decision stays in install/Invoke-Toolkit.ps1, and the
  installer EXE is never installed into a project nor recorded in an ownership ledger.
#>

Test-Case -Name 'installer exe: the built shell is small and single purpose' -Body {
  $exePath = Get-ToolkitTestInstallerExe
  $size = (Get-Item -LiteralPath $exePath).Length
  Assert-True ($size -gt 0) 'the EXE must exist and be non-empty'
  Assert-True ($size -lt 204800) ('the EXE must stay thin (a few tens of KB), actual ' + $size + ' bytes')
  Write-ToolkitTestNote ('thin installer size: ' + $size + ' bytes')

  # the source must stay a pure shell: no network, no embedded runtime, no monitor/team code
  $source = Get-Content -LiteralPath (Join-Path $script:TKTestToolkitRoot 'installer\src\Installer.cs') -Raw
  Assert-NotMatch $source '(?i)HttpListener|HttpClient|WebClient|System\.Net\.Sockets' 'the shell must not host a server or use the network'
  Assert-NotMatch $source '(?i)server\.mjs|app\.js|node_modules|codex-dsh-team\\SKILL' 'the shell must not embed monitor/team code'
  Assert-NotMatch $source '(?i)dotnet|Microsoft\.NET\.Sdk|RuntimeIdentifier|PublishSingleFile' 'the shell must stay framework-dependent, not self-contained'
  Assert-Match $source 'Invoke-Toolkit\.ps1' 'the shell must delegate to the engine'
  Assert-Match $source '-NonInteractive' 'the shell must always invoke the engine non-interactively'
  # no installer-self residual mechanism: the EXE is a package-root launcher
  Assert-NotMatch $source '(?i)ScheduleSelfDelete|del /f /q' 'the installer must not carry a self-delete mechanism'

  # the installer EXE is not a managed entry: it is never installed and never ledgered
  $layout = Get-Content -LiteralPath (Join-Path $script:TKTestToolkitRoot 'release\package-layout.json') -Raw | ConvertFrom-Json
  $managedPaths = @($layout.managed | ForEach-Object { [string]$_.path })
  Assert-Equal 2 $managedPaths.Count 'the managed set must stay exactly engine + uninstaller EXE'
  foreach ($managed in $managedPaths) {
    Assert-NotMatch $managed 'CodexDshTeamToolkit\.Install\.exe' ('the installer EXE must never be a managed entry: ' + $managed)
  }
  # ... but it is packaged, together with its source and recipe
  foreach ($required in @('CodexDshTeamToolkit.Install.exe', 'installer/Build-Installer.ps1', 'installer/src/Installer.cs')) {
    Assert-True (@($layout.packageOnly) -contains $required) ('the package must carry ' + $required)
    Assert-True (@($layout.releaseMustContain) -contains $required) ('the release must require ' + $required)
  }

  # the thin EXE metadata is aligned with the release
  $reportPath = Join-Path $script:TKTestToolkitRoot 'installer\build-report.json'
  Assert-FileExists $reportPath 'the installer build must leave a fail-visible report'
  $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  Assert-Equal 0 ([int]$report.exitCode) 'the recorded compiler exit code must be 0'
  Assert-Equal '5' ([string]$report.langVersion) 'the shell must be built as C# 5'
  Assert-Equal '1.1.0.0' ([string]$report.fileVersion) 'the EXE version must be aligned with the release'
  $version = (Get-Item -LiteralPath $exePath).VersionInfo
  Assert-Equal '1.1.0.0' ([string]$version.FileVersion) 'the built EXE must carry the release file version'
  Assert-Match ([string]$version.ProductName) 'Codex x DSH Team Toolkit' 'the EXE must identify the product'
}

Test-Case -Name 'installer exe: plan-only writes nothing and --yes installs unattended' -Body {
  $exePath = Get-ToolkitTestInstallerExe
  $base = New-ToolkitTestDirectory -Label 'installer-exe-e2e'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -InstallerExePath $exePath
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $packageExe = Join-Path $package.Root 'CodexDshTeamToolkit.Install.exe'
  Assert-FileExists $packageExe 'the package must carry the installer EXE at its root'

  # 1) plan-only: the plan is shown and nothing is written
  $before = Get-ToolkitTestTreeSnapshot -Root $project
  $planOnly = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--target', $project, '--plan-only', '--no-ui')
  Assert-Equal 0 $planOnly.ExitCode ('plan-only must succeed: ' + $planOnly.Output)
  Assert-Match $planOnly.Output 'Plan-only mode: nothing was written' 'the dry run must say so'
  Assert-Match $planOnly.Output 'create ' 'the plan must be displayed per file'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'plan-only must not write'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') 'plan-only must not create the state directory'

  # 2) unattended install
  $install = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--target', $project, '--yes', '--no-ui')
  Assert-Equal 0 $install.ExitCode ('the unattended install must succeed: ' + $install.Output)
  Assert-Match $install.Output 'Installed toolkit' 'the install must be reported'
  foreach ($entry in @($package.Entries)) {
    Assert-FileExists (Join-Path $project ([string]$entry.path -replace '/', '\')) ('managed file must be installed: ' + [string]$entry.path)
  }
  Assert-FileExists (Join-Path $project '.codex-dsh-team-toolkit\manifest.json') 'the ledger must be written'
  # the launcher itself is never installed into the project
  Assert-FileMissing (Join-Path $project 'CodexDshTeamToolkit.Install.exe') 'the installer EXE must never be installed into a project'
  $ledgerText = Get-Content -LiteralPath (Join-Path $project '.codex-dsh-team-toolkit\manifest.json') -Raw
  Assert-NotMatch $ledgerText 'CodexDshTeamToolkit\.Install\.exe' 'the installer EXE must never be recorded in the ledger'

  # 3) a repeat run is a verified no-op and still exits 0
  $repeat = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--target', $project, '--yes', '--no-ui')
  Assert-Equal 0 $repeat.ExitCode ('a repeat install must be a verified no-op: ' + $repeat.Output)
  Assert-Match $repeat.Output 'verified no-op|Already up to date' 'the no-op must be reported'
}

Test-Case -Name 'installer exe: package-root discovery, --package override and missing-engine rejection' -Body {
  $exePath = Get-ToolkitTestInstallerExe
  $base = New-ToolkitTestDirectory -Label 'installer-exe-discovery'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -InstallerExePath $exePath
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $packageExe = Join-Path $package.Root 'CodexDshTeamToolkit.Install.exe'

  # 1) positional target is accepted
  $positional = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @($project, '--plan-only', '--no-ui')
  Assert-Equal 0 $positional.ExitCode ('a positional target must be accepted: ' + $positional.Output)
  Assert-Match $positional.Output 'Target project' 'the plan must name the target'

  # 2) a copy run from elsewhere works through --package
  $elsewhere = Join-Path $base 'elsewhere'
  New-Item -ItemType Directory -Path $elsewhere -Force | Out-Null
  $copied = Join-Path $elsewhere 'CodexDshTeamToolkit.Install.exe'
  Copy-Item -LiteralPath $packageExe -Destination $copied -Force
  $viaPackage = Invoke-ToolkitTestExe -ExePath $copied -Arguments @('--target', $project, '--package', $package.Root, '--plan-only', '--no-ui')
  Assert-Equal 0 $viaPackage.ExitCode ('--package must locate the engine: ' + $viaPackage.Output)

  # 3) the same copy without --package is refused: it is not a package root
  $noPackage = Invoke-ToolkitTestExe -ExePath $copied -Arguments @('--target', $project, '--yes', '--no-ui')
  Assert-Equal 5 $noPackage.ExitCode ('an EXE outside a package must be refused: ' + $noPackage.Output)
  Assert-Match $noPackage.Output 'root of an extracted release package' 'the refusal must explain the package-root requirement'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') 'nothing may be written by the refusal'

  # 4) a package without the engine is refused too
  $brokenPackage = Join-Path $base 'broken-package'
  New-Item -ItemType Directory -Path $brokenPackage -Force | Out-Null
  Copy-Item -LiteralPath $packageExe -Destination (Join-Path $brokenPackage 'CodexDshTeamToolkit.Install.exe') -Force
  $broken = Invoke-ToolkitTestExe -ExePath (Join-Path $brokenPackage 'CodexDshTeamToolkit.Install.exe') -Arguments @('--target', $project, '--yes', '--no-ui')
  Assert-Equal 5 $broken.ExitCode ('a package without the engine must be refused: ' + $broken.Output)

  # 5) --help is always available and exits 0
  $help = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--help')
  Assert-Equal 0 $help.ExitCode 'help must exit 0'
  Assert-Match $help.Output '--plan-only' 'help must document the switches'
}

Test-Case -Name 'installer exe: target validation and unattended behaviour' -Body {
  $exePath = Get-ToolkitTestInstallerExe
  $base = New-ToolkitTestDirectory -Label 'installer-exe-target'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -InstallerExePath $exePath
  $packageExe = Join-Path $package.Root 'CodexDshTeamToolkit.Install.exe'

  # 1) a missing target directory is refused with exit 3 and nothing written
  $missing = Join-Path $base 'does-not-exist'
  $badTarget = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--target', $missing, '--yes', '--no-ui')
  Assert-Equal 3 $badTarget.ExitCode ('a missing target must exit 3: ' + $badTarget.Output)
  Assert-Match $badTarget.Output 'target project directory does not exist' 'the reason must be explicit'
  Assert-FileMissing $missing 'the installer must never create the target root'

  # 2) unattended without a target is refused with exit 2: no folder picker is ever shown
  $noTarget = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--yes', '--no-ui')
  Assert-Equal 2 $noTarget.ExitCode ('an unattended run without a target must exit 2: ' + $noTarget.Output)
  Assert-Match $noTarget.Output 'No target project was supplied' 'the reason must be explicit'
}

Test-Case -Name 'installer exe: the engine exit code is forwarded unchanged' -Body {
  $exePath = Get-ToolkitTestInstallerExe
  $base = New-ToolkitTestDirectory -Label 'installer-exe-forward'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -InstallerExePath $exePath
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $packageExe = Join-Path $package.Root 'CodexDshTeamToolkit.Install.exe'

  # an unknown pre-existing file at a managed path makes the engine refuse with exit 4
  $conflict = Join-Path $project '.agents\skills\codex-dsh-team\roles\coder.md'
  Write-ToolkitTestFile -Path $conflict -Content "# user file that must never be overwritten`n"
  $conflictBefore = Get-Content -LiteralPath $conflict -Raw

  $result = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--target', $project, '--yes', '--no-ui')
  Assert-Equal 4 $result.ExitCode ('the engine conflict exit code must be forwarded: ' + $result.Output)
  Assert-Match $result.Output 'not owned by this toolkit|Nothing was overwritten' 'the engine refusal must be surfaced'
  Assert-Equal $conflictBefore (Get-Content -LiteralPath $conflict -Raw) 'the user file must be preserved'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') 'a refused install must leave no state'

  # the same conflict is reported by a dry run too (exit code preserved there as well)
  $planOnly = Invoke-ToolkitTestExe -ExePath $packageExe -Arguments @('--target', $project, '--plan-only', '--no-ui')
  Assert-Equal 4 $planOnly.ExitCode ('plan-only must forward the engine refusal too: ' + $planOnly.Output)
}