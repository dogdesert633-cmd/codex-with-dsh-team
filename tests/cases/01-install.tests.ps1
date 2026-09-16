#Requires -Version 5.1
<#
  01 - first install, plan-only zero writes, CLI/non-interactive behaviour.
#>

Test-Case -Name 'install: first install writes exactly the manifest-listed files' -Body {
  $base = New-ToolkitTestDirectory -Label 'install'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $result = Invoke-ToolkitTestCommand -Options @{
    Action      = 'Install'
    Target      = $project
    PackageRoot = $package.Root
  }
  Assert-Equal 0 $result.ExitCode ('install should succeed: ' + (Get-ToolkitTestOutput $result))

  foreach ($entry in @($package.Entries)) {
    Assert-FileExists (Join-Path $project ($entry.path -replace '/', '\')) ('managed file ' + $entry.path)
  }
  $stateDirectory = Join-Path $project '.codex-dsh-team-toolkit'
  Assert-FileExists (Join-Path $stateDirectory 'manifest.json')
  Assert-FileExists (Join-Path $project 'CodexDshTeamToolkit.Uninstall.exe')
  Assert-FileExists (Join-Path $project '.codex-dsh-team-toolkit\engine\Invoke-Toolkit.ps1')

  $ownership = Read-ToolkitOwnershipManifest -Path (Join-Path $stateDirectory 'manifest.json')
  Assert-Equal 'codex-dsh-team-toolkit' $ownership.name
  Assert-Equal '1.0.0' $ownership.version
  Assert-Equal @($package.Entries).Count @($ownership.files).Count
  foreach ($file in @($ownership.files)) {
    $relative = [string]$file.path
    Assert-Match $relative '^[^/\\]+(/[^/\\]+)*$' 'ownership paths must be relative and normalized'
    Assert-Equal 'owned' ([string]$file.state) 'ownership entries must record their state'
    Assert-Equal ('pristine/' + $relative) ([string]$file.pristine) 'ownership entries must point at their pristine baseline, never at a digest'
    Assert-NotMatch ([string]$file.PSObject.Properties.Name -join ',') 'sha|hash|digest' 'the ledger must not carry a checksum or digest field'
    # the pristine baseline holds the exact installed bytes
    $installedPath = Join-Path $project ($relative -replace '/', '\')
    $pristinePath = Join-Path $stateDirectory ('pristine\' + ($relative -replace '/', '\'))
    Assert-FileExists $pristinePath ('every managed file must have a pristine baseline: ' + $relative)
    Assert-True (Test-ToolkitFileContentEqual -PathA $installedPath -PathB $pristinePath) ('the pristine baseline must equal the installed file: ' + $relative)
  }

  # no stray transaction or lock artefacts are left behind
  Assert-FileMissing (Join-Path $stateDirectory '.install.lock')
  Assert-FileMissing (Join-Path $stateDirectory 'txn')
}

Test-Case -Name 'install: plan-only is displayed per file and writes nothing at all' -Body {
  $base = New-ToolkitTestDirectory -Label 'planonly'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{
    Action      = 'Install'
    Target      = $project
    PackageRoot = $package.Root
    PlanOnly    = $true
  }
  Assert-Equal 0 $result.ExitCode
  $output = Get-ToolkitTestOutput $result
  foreach ($entry in @($package.Entries)) {
    Assert-Match $output ([regex]::Escape([string]$entry.path)) ('plan should list ' + [string]$entry.path)
  }
  Assert-Match $output 'Plan-only mode' 'plan-only mode must be reported'

  $after = Get-ToolkitTestTreeSnapshot -Root $project
  Assert-Equal $before.Count $after.Count 'plan-only must not create files'
  Assert-Equal ($before -join ';') ($after -join ';') 'plan-only must not modify or create anything'
}

Test-Case -Name 'install: re-running the same release is a verified no-op' -Body {
  $base = New-ToolkitTestDirectory -Label 'noop'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $first = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal 0 $first.ExitCode
  $snapshot = Get-ToolkitTestTreeSnapshot -Root $project

  $second = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal 0 $second.ExitCode ('second install should succeed: ' + (Get-ToolkitTestOutput $second))
  Assert-Match (Get-ToolkitTestOutput $second) 'unchanged' 'the plan should report unchanged files'
  $after = Get-ToolkitTestTreeSnapshot -Root $project
  # the toolkit log is append-only by design; every managed file must stay byte-identical
  $beforeManaged = @($snapshot | Where-Object { $_ -notlike '*install.log*' })
  $afterManaged = @($after | Where-Object { $_ -notlike '*install.log*' })
  Assert-Equal ($beforeManaged -join ';') ($afterManaged -join ';') 'a repeat install must not rewrite any managed content'
}

Test-Case -Name 'install: a missing target root is refused and never created' -Body {
  $base = New-ToolkitTestDirectory -Label 'missingtarget'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $missing = Join-Path $base 'does-not-exist'

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $missing; PackageRoot = $package.Root }
  Assert-Equal $script:ExitBlocked $result.ExitCode
  Assert-Match (Get-ToolkitTestOutput $result) 'must already exist' 'the refusal must explain the precondition'
  Assert-FileMissing $missing
}

Test-Case -Name 'install: no UI and no target fails fast with a clear error (never hangs)' -Body {
  $base = New-ToolkitTestDirectory -Label 'notarget'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')

  $result = Invoke-ToolkitTestCommand -Options @{
    Action         = 'Install'
    PackageRoot    = $package.Root
    NonInteractive = $true
  }
  Assert-Equal $script:ExitUsage $result.ExitCode
  Assert-Match (Get-ToolkitTestOutput $result) 'Pass -Target' 'the error must tell the caller what to do'
}

Test-Case -Name 'install: CLI process reporting works and exit codes are forwarded' -Body {
  $base = New-ToolkitTestDirectory -Label 'cli'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $noTarget = Invoke-ToolkitTestCli -Arguments @('-Action', 'Install', '-PackageRoot', $package.Root)
  Assert-Equal $script:ExitUsage $noTarget.ExitCode ('CLI without a target must exit 2, output: ' + $noTarget.Output)

  $install = Invoke-ToolkitTestCli -Arguments @('-Action', 'Install', '-Target', $project, '-PackageRoot', $package.Root, '-Yes')
  Assert-Equal 0 $install.ExitCode ('CLI install should succeed: ' + $install.Output)
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')

  # without -Yes the CLI must refuse in a non-interactive session and write nothing
  $unconfirmedProject = New-ToolkitTestProject -Root (Join-Path $base 'project-unconfirmed')
  $unconfirmed = Invoke-ToolkitTestCli -Arguments @('-Action', 'Install', '-Target', $unconfirmedProject, '-PackageRoot', $package.Root, '-NonInteractive')
  Assert-Equal $script:ExitCancelled $unconfirmed.ExitCode ('CLI install without -Yes must exit 8: ' + $unconfirmed.Output)
  Assert-FileMissing (Join-Path $unconfirmedProject '.codex-dsh-team-toolkit') 'no state directory may be created before consent'

  $planOnly = Invoke-ToolkitTestCli -Arguments @('-Action', 'Install', '-Target', $project, '-PackageRoot', $package.Root, '-PlanOnly')
  Assert-Equal 0 $planOnly.ExitCode
  Assert-Match $planOnly.Output 'dry run' 'CLI plan-only must be reported'
}

Test-Case -Name 'install: a cancelled folder picker exits safely with zero writes' -Body {
  $base = New-ToolkitTestDirectory -Label 'picker-cancel'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  # stub the STA folder picker so the "user pressed Cancel" branch can be tested headlessly
  $original = Get-Item -Path function:script:Select-ToolkitFolderInteractive -ErrorAction SilentlyContinue
  try {
    Set-Item -Path function:script:Select-ToolkitFolderInteractive -Value { return '' }
    $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; PackageRoot = $package.Root }
    Assert-Equal 0 $result.ExitCode ('a cancelled picker is not an error: ' + (Get-ToolkitTestOutput $result))
    Assert-Match (Get-ToolkitTestOutput $result) 'Cancelled by the user' 'the cancellation must be reported'
  }
  finally {
    if ($null -ne $original) {
      Set-Item -Path function:script:Select-ToolkitFolderInteractive -Value $original.ScriptBlock
    }
  }

  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'cancelling must write nothing'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
}

Test-Case -Name 'install: Install.cmd forwards arguments and the engine exit code' -Body {
  $base = New-ToolkitTestDirectory -Label 'cmd-wrapper'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Copy-Item -LiteralPath (Join-Path $script:TKTestToolkitRoot 'Install.cmd') -Destination (Join-Path $package.Root 'Install.cmd') -Force

  $planOutput = & cmd.exe /c ('"' + (Join-Path $package.Root 'Install.cmd') + '" -Target "' + $project + '" -PlanOnly') 2>&1 | Out-String
  Assert-Equal 0 $LASTEXITCODE ('the cmd wrapper must forward a successful exit code: ' + $planOutput)
  Assert-Match $planOutput 'dry run' 'the plan must be shown through the wrapper'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') 'plan-only through the wrapper must not write'

  $errorOutput = & cmd.exe /c ('"' + (Join-Path $package.Root 'Install.cmd') + '" -Target "' + (Join-Path $base 'missing') + '"') 2>&1 | Out-String
  Assert-True ($LASTEXITCODE -ne 0) 'the cmd wrapper must forward a failing exit code'
  Assert-Match $errorOutput 'exited with code' 'the wrapper must explain the failure'
}

Test-Case -Name 'install: a missing release manifest blocks with a manifest error' -Body {
  $base = New-ToolkitTestDirectory -Label 'norelease'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Remove-Item -LiteralPath $package.ManifestPath -Force
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitManifest $result.ExitCode
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'no writes on manifest failure'
}
