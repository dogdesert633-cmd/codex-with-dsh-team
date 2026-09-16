#Requires -Version 5.1
<#
  04 - uninstall: ownership-proven deletion, user content preservation, quarantine rollback.
#>

Test-Case -Name 'uninstall: managed files are removed and user files are preserved' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  # user content that the toolkit must never touch
  Write-ToolkitTestFile -Path (Join-Path $project '.agents\skills\mcp-to-dsh\node_modules\dep\index.js') -Content "module.exports = 1;`n"
  Write-ToolkitTestFile -Path (Join-Path $project '.agents\skills\other-skill\SKILL.md') -Content "# another skill`n"
  Write-ToolkitTestFile -Path (Join-Path $project '.agents\skills\mcp-to-dsh\user-notes.md') -Content "# my own notes`n"
  Write-ToolkitTestFile -Path (Join-Path $project 'src\app.js') -Content "console.log('user source');`n"

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('uninstall should succeed: ' + (Get-ToolkitTestOutput $result))
  $output = Get-ToolkitTestOutput $result
  Assert-Match $output 'Uninstall Plan|Managed files to delete' 'an uninstall plan must be shown first'
  Assert-Match $output 'never deleted' 'the safety promise must be stated'

  foreach ($entry in @($package.Entries)) {
    Assert-FileMissing (Join-Path $project ([string]$entry.path -replace '/', '\')) ('managed file must be removed: ' + [string]$entry.path)
  }
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
  Assert-FileMissing (Join-Path $project '.agents\skills\codex-dsh-team')
  Assert-FileMissing (Join-Path $project '.agents\skills\mcp-to-dsh\SKILL.md')

  # user content survives, including runtime directories
  Assert-FileExists (Join-Path $project '.agents\skills\mcp-to-dsh\node_modules\dep\index.js')
  Assert-FileExists (Join-Path $project '.agents\skills\other-skill\SKILL.md')
  Assert-FileExists (Join-Path $project '.agents\skills\mcp-to-dsh\user-notes.md')
  Assert-FileExists (Join-Path $project 'src\app.js')
  Assert-Match $output 'node_modules' 'unknown runtime content must be reported'
}

Test-Case -Name 'uninstall: a user-modified managed file is kept and keeps its ownership evidence' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-modified'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $edited = Join-Path $project '.agents\skills\codex-dsh-team\SKILL.md'
  Write-ToolkitTestFile -Path $edited -Content "# I changed this file by hand`n"

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('uninstall should succeed: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'could not be proven owned' 'the kept file must be reported'
  Assert-Match (Get-Content -LiteralPath $edited -Raw) 'changed this file by hand' 'the modified file must survive'
  Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd') 'unmodified managed files are still removed'

  $ledger = Join-Path $project '.codex-dsh-team-toolkit\manifest.json'
  Assert-FileExists $ledger 'ownership evidence must survive while a managed file remains'
  $ownership = Read-ToolkitOwnershipManifest -Path $ledger
  Assert-Equal 1 @($ownership.files).Count 'the ledger must list exactly the retained file'
  Assert-Equal '.agents/skills/codex-dsh-team/SKILL.md' ([string]($ownership.files[0].path))

  # The surviving state directory must keep BOTH the pristine baseline the reduced ledger
  # references AND its self-ignoring .gitignore, otherwise a later uninstall could no longer
  # prove ownership and the retained state would show up in the user's Git status.
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $gitIgnore = Join-Path $state '.gitignore'
  Assert-FileExists $gitIgnore 'the state self-ignore boundary must survive a partial uninstall'
  Assert-Match (Get-Content -LiteralPath $gitIgnore -Raw) '(?m)^\*' 'the surviving .gitignore must still ignore the whole state directory'
  $pristine = Join-Path $state ([string]$ownership.files[0].pristine -replace '/', '\')
  Assert-FileExists $pristine 'the pristine baseline of the retained file must survive'
  Assert-False (Test-ToolkitPristineMatches -StateDirectory $state -RelativePath ([string]$ownership.files[0].path) -TargetPath $edited) 'the retained pristine must be the original baseline, not the user edit'
  Assert-True (Test-ToolkitPristineMatches -StateDirectory $state -RelativePath ([string]$ownership.files[0].path) -TargetPath $pristine) 'the retained pristine must hold the original bytes'
  # only the retained entry keeps evidence; copies of removed files are pruned
  Assert-Equal 1 @(Get-ChildItem -LiteralPath (Join-Path $state 'pristine') -Recurse -Force -File).Count 'only referenced pristine evidence may remain'

  # a second uninstall run must again refuse to delete the user-modified file
  $second = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $second.ExitCode
  Assert-Match (Get-Content -LiteralPath $edited -Raw) 'changed this file by hand' 'the file must still be there after a second run'
  Assert-FileExists $pristine 'the evidence must still be there after the second run'
  Assert-FileExists $gitIgnore 'the self-ignore boundary must still be there after the second run'
}

Test-Case -Name 'uninstall: restoring the original bytes lets a later run finish the uninstall' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-resume'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $relative = '.agents/skills/codex-dsh-team/SKILL.md'
  $edited = Join-Path $project ($relative -replace '/', '\')
  $original = Join-Path $base 'original-skill.md'
  Copy-Item -LiteralPath $edited -Destination $original -Force
  Write-ToolkitTestFile -Path $edited -Content "# I changed this file by hand`n"

  # 1) partial uninstall: the edited file is kept together with its evidence
  $first = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $first.ExitCode ('partial uninstall should succeed: ' + (Get-ToolkitTestOutput $first))
  Assert-Match (Get-ToolkitTestOutput $first) 'Ownership evidence kept' 'the kept evidence must be reported'
  Assert-FileExists $edited 'the user edit must survive'
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  Assert-FileExists (Join-Path $state 'manifest.json')
  Assert-FileExists (Join-Path $state '.gitignore')
  $ownership = Read-ToolkitOwnershipManifest -Path (Join-Path $state 'manifest.json')
  Assert-Equal 1 @($ownership.files).Count 'only the retained file may stay in the reduced ledger'

  # 2) the user restores the original bytes
  Copy-Item -LiteralPath $original -Destination $edited -Force

  # 3) the later uninstall can now prove ownership, remove that file and clean the state up
  $second = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $second.ExitCode ('the resumed uninstall should succeed: ' + (Get-ToolkitTestOutput $second))
  Assert-FileMissing $edited 'the restored managed file must now be removed'
  Assert-FileMissing $state 'with nothing left to prove, the whole state directory must be gone'
}

Test-Case -Name 'uninstall: declining the plan writes nothing, and a non-interactive run needs -Yes' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-confirm'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $refused = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; NonInteractive = $true; Yes = $false }
  Assert-Equal $script:ExitCancelled $refused.ExitCode 'a non-interactive run without -Yes must refuse'
  Assert-Match (Get-ToolkitTestOutput $refused) '-Yes' 'the refusal must say what is missing'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'nothing may change'

  $planOnly = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; PlanOnly = $true }
  Assert-Equal 0 $planOnly.ExitCode
  Assert-Match (Get-ToolkitTestOutput $planOnly) 'dry run' 'the uninstall plan must be read-only'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'plan-only must not write'
}

Test-Case -Name 'uninstall: without a manifest or with a corrupt manifest nothing is deleted' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-manifest'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $ledger = Join-Path $project '.codex-dsh-team-toolkit\manifest.json'
  Write-ToolkitTestFile -Path $ledger -Content '{ this is not json'
  $beforeCorrupt = Get-ToolkitTestManagedSnapshot -Root $project
  $corrupt = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal $script:ExitManifest $corrupt.ExitCode ('a corrupt manifest must stop the uninstall: ' + (Get-ToolkitTestOutput $corrupt))
  Assert-Equal ($beforeCorrupt -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') 'nothing may change'

  Write-ToolkitTestFile -Path $ledger -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/ownership-manifest/v1'; name = 'someone-else'; version = '9.9.9'
        installId = [guid]::NewGuid().ToString()
        files = @(New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' })
      }))
  $beforeForeign = Get-ToolkitTestManagedSnapshot -Root $project
  $wrongIdentity = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal $script:ExitManifest $wrongIdentity.ExitCode 'a foreign manifest identity must stop the uninstall'
  Assert-Equal ($beforeForeign -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') 'nothing may change'
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')

  Remove-Item -LiteralPath $ledger -Force
  $beforeMissing = Get-ToolkitTestManagedSnapshot -Root $project
  $missing = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal $script:ExitManifest $missing.ExitCode 'a missing manifest must stop the uninstall'
  Assert-Equal ($beforeMissing -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') 'nothing may change'
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')
}

Test-Case -Name 'uninstall: a mid-transaction failure restores every quarantined file' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-rollback'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode
  $before = Get-ToolkitTestManagedSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Uninstall'; Target = $project; Yes = $true
    TestFault = 'uninstall.after-quarantine-first'; TestMode = $true
  }
  Assert-Equal $script:ExitTransaction $result.ExitCode ('the injected fault must abort: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'Rollback complete' 'the rollback must be reported'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') 'every file must be restored, including the ledger'
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')
  Assert-FileExists (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit\txn')
}

Test-Case -Name 'uninstall: a fault before the commit restores the project too' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-rollback2'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode
  $before = Get-ToolkitTestManagedSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Uninstall'; Target = $project; Yes = $true
    TestFault = 'uninstall.before-commit'; TestMode = $true
  }
  Assert-Equal $script:ExitTransaction $result.ExitCode
  Assert-Equal ($before -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') 'the project must be restored byte for byte'
}

Test-Case -Name 'uninstall: an uninstaller that cannot delete itself reports a minimal residual' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-residual'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $exeInUse = Join-Path $project 'CodexDshTeamToolkit.Uninstall.exe'
  # simulate the running thin EXE by claiming ownership of a file that is held open
  $handle = New-Object System.IO.FileStream($exeInUse, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
  try {
    $result = Invoke-ToolkitTestCommand -Options @{
      Action = 'Uninstall'; Target = $project; Yes = $true; UninstallerSelf = $exeInUse
    }
  }
  finally {
    $handle.Dispose()
  }
  Assert-Equal 0 $result.ExitCode ('the uninstall must still succeed: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'minimal residual|Minimal residual' 'the residual must be reported explicitly'
  Assert-Match (Get-ToolkitTestOutput $result) 'never recursively deleted' 'the residual must never trigger a recursive delete'
  Assert-Match (Get-ToolkitTestOutput $result) 'in use by this process' 'the reason must be explicit'
  Assert-FileExists $exeInUse 'the in-use file is the reported residual'
  Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd') 'everything else is still removed'

  $ledger = Join-Path $project '.codex-dsh-team-toolkit\manifest.json'
  Assert-FileExists $ledger 'the residual keeps its ownership record for a later run'
  $ownership = Read-ToolkitOwnershipManifest -Path $ledger
  Assert-Equal 'CodexDshTeamToolkit.Uninstall.exe' ([string]($ownership.files[0].path))
  # a deliberately kept residual keeps its evidence and the self-ignore boundary too
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  Assert-FileExists (Join-Path $state '.gitignore') 'the self-ignore boundary must survive a kept residual'
  $pristine = Join-Path $state ([string]$ownership.files[0].pristine -replace '/', '\')
  Assert-FileExists $pristine 'the residual keeps the pristine baseline its reduced ledger references'
  Assert-True (Test-ToolkitPristineMatches -StateDirectory $state -RelativePath ([string]$ownership.files[0].path) -TargetPath $exeInUse) 'the residual pristine must equal the in-use file it was installed from'
}

Test-Case -Name 'uninstall: the target is derived from the installed engine location' -Body {
  $base = New-ToolkitTestDirectory -Label 'uninstall-derive'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $installedEngine = Join-Path $project '.codex-dsh-team-toolkit\engine\Invoke-Toolkit.ps1'
  Assert-FileExists $installedEngine
  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Uninstall'; Yes = $true; EnginePath = $installedEngine
  }
  Assert-Equal 0 $result.ExitCode ('derived target uninstall should succeed: ' + (Get-ToolkitTestOutput $result))
  Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd')
  Assert-FileMissing (Join-Path $project 'CodexDshTeamToolkit.Uninstall.exe')
  Assert-FileExists (Join-Path $project 'README.md') 'user content stays'

  $noTarget = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Yes = $true }
  Assert-Equal $script:ExitUsage $noTarget.ExitCode 'with no target and no installed location the engine must refuse clearly'
}
