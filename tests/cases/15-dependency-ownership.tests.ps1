#Requires -Version 5.1
# Real engine tests, with tiny local dependency fixtures and no npm/network calls.
function New-DependencyFixture {
  $base = New-ToolkitTestDirectory -Label 'dependency-ownership'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  # These directories existed before installation and must survive uninstall.
  [IO.Directory]::CreateDirectory((Join-Path $project '.agents\skills')) | Out-Null
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{Action='Install';Target=$project;PackageRoot=$package.Root}).ExitCode
  $source = Join-Path $base 'prepared'
  Write-ToolkitTestFile (Join-Path $source 'fixture\original.js') 'original dependency'
  Write-ToolkitTestFile (Join-Path $source 'fixture\edited.js') 'before edit'
  $result = Invoke-ToolkitTestCommand -Options @{Action='InstallDependencies';Target=$project;DependencySource=$source;Yes=$true}
  Assert-Equal 0 $result.ExitCode (Get-ToolkitTestOutput $result)
  return @{ Project=$project; Package=$package; Source=$source; Modules=(Join-Path $project '.agents\skills\mcp-to-dsh\node_modules') }
}

Test-Case 'dependencies: full uninstall removes owned dependencies and preserves pre-existing empty directories' {
  $fixture = New-DependencyFixture
  $previewBefore = Get-ToolkitTestTreeSnapshot $fixture.Project
  $plan = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;PlanOnly=$true}
  Assert-Equal 0 $plan.ExitCode (Get-ToolkitTestOutput $plan)
  Assert-Equal ($previewBefore -join ';') ((Get-ToolkitTestTreeSnapshot $fixture.Project) -join ';')
  $result = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $result.ExitCode (Get-ToolkitTestOutput $result)
  Assert-FileMissing $fixture.Modules
  Assert-FileMissing (Join-Path $fixture.Project '.codex-dsh-team-toolkit')
  Assert-True (Test-Path -LiteralPath (Join-Path $fixture.Project '.agents\skills') -PathType Container)
  Assert-FileExists (Join-Path $fixture.Project 'src\app.js')
}

Test-Case 'dependencies: edited and user-added files survive, unchanged dependencies and only their baselines are removed' {
  $fixture = New-DependencyFixture
  Write-ToolkitTestFile (Join-Path $fixture.Modules 'fixture\edited.js') 'user edit'
  Write-ToolkitTestFile (Join-Path $fixture.Modules 'my-note.txt') 'user addition'
  $result = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $result.ExitCode (Get-ToolkitTestOutput $result)
  Assert-FileMissing (Join-Path $fixture.Modules 'fixture\original.js')
  Assert-Equal 'user edit' ([IO.File]::ReadAllText((Join-Path $fixture.Modules 'fixture\edited.js')))
  Assert-FileExists (Join-Path $fixture.Modules 'my-note.txt')
  Assert-FileExists (Join-Path $fixture.Project '.codex-dsh-team-toolkit\pristine\dependencies.zip')
  Assert-Match (Get-ToolkitTestOutput $result) 'modified since install'
}

Test-Case 'dependencies: dependency-only removal preserves toolkit and project dependencies and supports reinstall' {
  $fixture = New-DependencyFixture
  Write-ToolkitTestFile (Join-Path $fixture.Project 'node_modules\game.js') 'project dependency'
  $result = Invoke-ToolkitTestCommand -Options @{Action='RemoveDependencies';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $result.ExitCode (Get-ToolkitTestOutput $result)
  Assert-FileMissing $fixture.Modules
  Assert-FileExists (Join-Path $fixture.Project 'start_dsh_team.cmd')
  Assert-FileExists (Join-Path $fixture.Project 'node_modules\game.js')
  $again = Invoke-ToolkitTestCommand -Options @{Action='InstallDependencies';Target=$fixture.Project;DependencySource=$fixture.Source;Yes=$true}
  Assert-Equal 0 $again.ExitCode (Get-ToolkitTestOutput $again)
}

Test-Case 'dependencies: a failure before uninstall commit restores dependency files and ownership' {
  $fixture = New-DependencyFixture
  $result = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true;TestMode=$true;TestFault='uninstall.before-commit'}
  Assert-True ($result.ExitCode -ne 0)
  Assert-FileExists (Join-Path $fixture.Modules 'fixture\original.js')
  Assert-FileExists (Join-Path $fixture.Project 'start_dsh_team.cmd')
  $finished = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $finished.ExitCode (Get-ToolkitTestOutput $finished)
  Assert-FileMissing $fixture.Modules
}

Test-Case 'dependencies: an existing unrecorded tree is never adopted or overwritten' {
  $fixture = New-DependencyFixture
  $removed = Invoke-ToolkitTestCommand -Options @{Action='RemoveDependencies';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $removed.ExitCode
  Write-ToolkitTestFile (Join-Path $fixture.Modules 'legacy.js') 'original legacy dependency'
  $before = Get-ToolkitTestTreeSnapshot $fixture.Project
  $again = Invoke-ToolkitTestCommand -Options @{Action='InstallDependencies';Target=$fixture.Project;DependencySource=$fixture.Source;Yes=$true}
  Assert-True ($again.ExitCode -ne 0)
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot $fixture.Project) -join ';')
  $result = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $result.ExitCode
  Assert-FileExists (Join-Path $fixture.Modules 'legacy.js')
}

Test-Case 'dependencies: a toolkit update preserves modified dependencies and their original baselines' {
  $fixture = New-DependencyFixture
  Write-ToolkitTestFile (Join-Path $fixture.Modules 'fixture\edited.js') 'my dependency edit'
  $updated = Invoke-ToolkitTestCommand -Options @{Action='Install';Target=$fixture.Project;PackageRoot=$fixture.Package.Root}
  Assert-Equal 0 $updated.ExitCode (Get-ToolkitTestOutput $updated)
  $removed = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $removed.ExitCode (Get-ToolkitTestOutput $removed)
  Assert-Equal 'my dependency edit' ([IO.File]::ReadAllText((Join-Path $fixture.Modules 'fixture\edited.js')))
  Assert-FileMissing (Join-Path $fixture.Modules 'fixture\original.js')
}

Test-Case 'content comparison: edits beyond the first buffer and length changes are detected' {
  $base = New-ToolkitTestDirectory -Label 'large-byte-comparison'
  $first = Join-Path $base 'first.bin'
  $second = Join-Path $base 'second.bin'
  $bytes = New-Object byte[] 131073
  [IO.File]::WriteAllBytes($first, $bytes)
  [IO.File]::WriteAllBytes($second, $bytes)
  Assert-True (Test-ToolkitFileContentEqual $first $second)
  $bytes[131072] = 42
  [IO.File]::WriteAllBytes($second, $bytes)
  Assert-True (-not (Test-ToolkitFileContentEqual $first $second))
  [IO.File]::WriteAllBytes($second, (New-Object byte[] 131072))
  Assert-True (-not (Test-ToolkitFileContentEqual $first $second))
}

Test-Case 'dependencies: restoring an edited dependency allows final archive and ledger cleanup' {
  $fixture = New-DependencyFixture
  $edited = Join-Path $fixture.Modules 'fixture\edited.js'
  Write-ToolkitTestFile $edited 'user change'
  $first = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $first.ExitCode (Get-ToolkitTestOutput $first)
  Write-ToolkitTestFile $edited 'before edit'
  $second = Invoke-ToolkitTestCommand -Options @{Action='Uninstall';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $second.ExitCode (Get-ToolkitTestOutput $second)
  Assert-FileMissing $fixture.Modules
  Assert-FileMissing (Join-Path $fixture.Project '.codex-dsh-team-toolkit')
}

Test-Case 'dependencies: damaged original archive never authorizes deleting dependency files' {
  $fixture = New-DependencyFixture
  Write-ToolkitTestFile (Join-Path $fixture.Project '.codex-dsh-team-toolkit\pristine\dependencies.zip') 'damaged archive'
  $result = Invoke-ToolkitTestCommand -Options @{Action='RemoveDependencies';Target=$fixture.Project;Yes=$true}
  Assert-Equal 0 $result.ExitCode (Get-ToolkitTestOutput $result)
  Assert-FileExists (Join-Path $fixture.Modules 'fixture\original.js')
  Assert-FileExists (Join-Path $fixture.Modules 'fixture\edited.js')
}
