#Requires -Version 5.1
<#
  10 - repair-round coverage: durable-journal orphan recovery, in-lock TOCTOU guard, leftover
  state recovery, reinstall cycles, concurrent-file preservation, test-feature gating and the
  remaining transaction fault points.
#>

function New-ToolkitTestJournalFor {
  <#
    Creates a durable transaction directory exactly like an interrupted run would leave behind,
    without running the engine's own cleanup.
  #>
  param(
    [string]$StateDirectory,
    [string]$TargetRoot,
    [string]$Kind,
    [object[]]$JournalPaths,
    [string]$ToolkitVersion = '1.1.0'
  )
  $plan = New-ToolkitJsonObject -Properties @{
    JournalPaths       = @($JournalPaths)
    Notes              = @()
    CreatedDirectories = @()
  }
  return (Start-ToolkitTransaction -StateDirectory $StateDirectory -Kind $Kind -TargetRoot $TargetRoot -Plan $plan -ToolkitVersion $ToolkitVersion)
}

Test-Case -Name 'recovery: an interrupted install journal is replayed in-lock before the next write' -Body {
  $base = New-ToolkitTestDirectory -Label 'recover-install'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $target = Join-Path $project 'start_dsh_team.cmd'
  $originalContent = Get-Content -LiteralPath $target -Raw
  $stagedRelative = '.agents/skills/codex-dsh-team/.start_dsh_team.cmd.toolkit-tmp-deadbeefdeadbeefdeadbeefdeadbeef'
  $stagedFull = Join-Path $project ($stagedRelative -replace '/', '\')

  # simulate a hard interruption in the middle of an upgrade
  $txn = New-ToolkitTestJournalFor -StateDirectory $state -TargetRoot $project -Kind 'install' -JournalPaths @(
    New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd'; action = 'replace' }
  )
  Backup-ToolkitFile -Transaction $txn -RelativePath 'start_dsh_team.cmd' -SourcePath $target
  Backup-ToolkitManifest -Transaction $txn -ManifestPath (Join-Path $state 'manifest.json')
  Write-ToolkitTestFile -Path $stagedFull -Content 'staged but never moved'
  Register-ToolkitStagedFile -Transaction $txn -RelativePath $stagedRelative
  Write-ToolkitTestFile -Path $target -Content "@echo off`r`necho HALF APPLIED UPGRADE`r`n"

  Assert-FileExists $stagedFull 'the staged temp must exist before recovery'
  Assert-DirectoryExists $txn.Directory 'the orphan transaction must exist before recovery'

  # a run that fails right after the in-lock recovery proves the restore happened
  $payloadV2 = New-ToolkitTestPayload -Overrides @{ 'start_dsh_team.cmd' = "@echo off`r`necho v2 start`r`n" }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2
  $interrupted = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root
    TestFault = 'install.after-preflight'; TestMode = $true
  }
  Assert-Equal $script:ExitTransaction $interrupted.ExitCode ('the injected fault must abort: ' + (Get-ToolkitTestOutput $interrupted))
  Assert-Match (Get-ToolkitTestOutput $interrupted) 'Recovering an interrupted install transaction' 'the recovery must be reported'

  Assert-Equal $originalContent (Get-Content -LiteralPath $target -Raw) 'recovery must restore the pre-interruption content'
  Assert-FileMissing $stagedFull 'recovery must remove the staged temporary file'
  Assert-FileMissing $txn.Directory 'recovered evidence must be cleaned up'
  Assert-FileExists (Join-Path $state 'manifest.json') 'the ledger backup must be restored'

  # and a clean run afterwards completes the upgrade
  $completed = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root }
  Assert-Equal 0 $completed.ExitCode ('the upgrade must complete after recovery: ' + (Get-ToolkitTestOutput $completed))
  Assert-Match (Get-Content -LiteralPath $target -Raw) 'v2 start' 'the upgrade must apply after recovery'
}

Test-Case -Name 'recovery: an interrupted uninstall journal puts the quarantined files back' -Body {
  $base = New-ToolkitTestDirectory -Label 'recover-uninstall'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $target = Join-Path $project 'start_dsh_team.cmd'
  $content = Get-Content -LiteralPath $target -Raw

  $txn = New-ToolkitTestJournalFor -StateDirectory $state -TargetRoot $project -Kind 'uninstall' -JournalPaths @(
    New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd'; action = 'remove' }
  )
  $quarantine = Join-Path $txn.Directory 'quarantine'
  New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
  [System.IO.File]::Move($target, (Join-Path $quarantine 'start_dsh_team.cmd'))
  Assert-FileMissing $target 'the file is in quarantine before recovery'

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal 0 $result.ExitCode ('the run must recover and continue: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'Recovering an interrupted uninstall transaction' 'the recovery must be reported'
  Assert-Equal $content (Get-Content -LiteralPath $target -Raw) 'the quarantined file must be restored'
  Assert-FileMissing $txn.Directory 'recovered evidence must be cleaned up'
}

Test-Case -Name 'recovery: a concurrent file during uninstall recovery is preserved and reported' -Body {
  $base = New-ToolkitTestDirectory -Label 'recover-concurrent'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $target = Join-Path $project 'start_dsh_team.cmd'

  $txn = New-ToolkitTestJournalFor -StateDirectory $state -TargetRoot $project -Kind 'uninstall' -JournalPaths @(
    New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd'; action = 'remove' }
  )
  $quarantine = Join-Path $txn.Directory 'quarantine'
  New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
  [System.IO.File]::Move($target, (Join-Path $quarantine 'start_dsh_team.cmd'))
  # a different file appears at the same path while the interrupted uninstall is unresolved
  Write-ToolkitTestFile -Path $target -Content "# user file created concurrently`n"

  $rollback = Invoke-ToolkitUninstallRollback -Transaction $txn -TargetRoot $project -Plan (New-ToolkitJsonObject -Properties @{
      Deletable = @(New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' })
    })
  Assert-False ([bool]$rollback.Ok) 'the rollback must be reported as incomplete'
  Assert-True ([bool]$rollback.KeepEvidence) 'the evidence must be kept'
  Assert-Match (@($rollback.Problems) -join ';') 'was preserved' 'the concurrent file must be reported'
  Assert-Match (Get-Content -LiteralPath $target -Raw) 'created concurrently' 'the concurrent user file must never be deleted'
  Assert-FileExists (Join-Path $quarantine 'start_dsh_team.cmd') 'the recovered original is kept as evidence'

  # a run against this state must refuse to continue rather than guess
  $blocked = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitRollback $blocked.ExitCode ('an unrecoverable orphan must stop the run: ' + (Get-ToolkitTestOutput $blocked))
  Assert-Match (Get-ToolkitTestOutput $blocked) 'could not be recovered automatically' 'the refusal must explain why'
  Assert-Match (Get-Content -LiteralPath $target -Raw) 'created concurrently' 'the concurrent file still survives'
}

Test-Case -Name 'recovery: hostile or unsupported journal evidence is refused and kept' -Body {
  $base = New-ToolkitTestDirectory -Label 'hostile-journal'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $outside = Join-Path $base 'outside-sentinel.txt'
  Write-ToolkitTestFile -Path $outside -Content 'sentinel outside the project'
  $outsidePath = $outside

  $hostileJournals = @(
    @{ Name = 'traversal path'; Plan = '.agents/skills/x/../../../../outside-sentinel.txt'; State = 'started'; Kind = 'install' },
    @{ Name = 'absolute path';  Plan = 'C:\Windows\System32\drivers\etc\hosts';              State = 'started'; Kind = 'install' },
    @{ Name = 'unc path';       Plan = '\\server\share\evil.txt';                            State = 'started'; Kind = 'install' },
    @{ Name = 'ads path';       Plan = '.agents/notes.md:evil';                              State = 'started'; Kind = 'install' },
    @{ Name = 'unknown state';  Plan = 'start_dsh_team.cmd';                                 State = 'weird';   Kind = 'install' },
    @{ Name = 'unknown kind';   Plan = 'start_dsh_team.cmd';                                 State = 'started'; Kind = 'migrate' }
  )

  foreach ($case in $hostileJournals) {
    $txnDirectory = Join-Path $state ('txn\' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Path (Join-Path $txnDirectory 'backup') -Force | Out-Null
    $journal = New-ToolkitJsonObject -Properties @{
      schema             = 'codex-dsh-team-toolkit/journal/v1'
      kind               = [string]$case.Kind
      state              = [string]$case.State
      plan               = @(New-ToolkitJsonObject -Properties @{ path = [string]$case.Plan; action = 'replace' })
      backups            = @()
      staged             = @()
      createdDirectories = @()
      manifestBackup     = $false
    }
    Write-ToolkitJsonAtomic -Object $journal -Destination (Join-Path $txnDirectory 'journal.json')

    $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
    Assert-Equal $script:ExitRollback $result.ExitCode ('hostile evidence must stop the run (' + [string]$case.Name + '): ' + (Get-ToolkitTestOutput $result))
    Assert-Match (Get-ToolkitTestOutput $result) 'unsafe or unsupported transaction evidence|could not be recovered automatically' ('the refusal must be explicit (' + [string]$case.Name + ')')
    Assert-True (Test-ToolkitFileContentEqual -PathA $outside -PathB $outsidePath) ('the outside sentinel must be untouched (' + [string]$case.Name + ')')
    Assert-FileExists (Join-Path $txnDirectory 'journal.json') ('the evidence must be kept (' + [string]$case.Name + ')')

    Remove-Item -LiteralPath $txnDirectory -Recurse -Force
  }
}

Test-Case -Name 'recovery: an unrecognized staged temp name is never deleted' -Body {
  $base = New-ToolkitTestDirectory -Label 'staged-pattern'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $userFile = Join-Path $project '.agents\skills\codex-dsh-team\.user-notes.toolkit-tmp-deadbeef'
  Write-ToolkitTestFile -Path $userFile -Content 'a user file that merely looks like a temp file'
  $userCopy = Join-Path $base 'user-file-copy.bin'
  Copy-Item -LiteralPath $userFile -Destination $userCopy -Force

  $txnDirectory = Join-Path $state ('txn\' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path (Join-Path $txnDirectory 'backup') -Force | Out-Null
  $journal = New-ToolkitJsonObject -Properties @{
    schema             = 'codex-dsh-team-toolkit/journal/v1'
    kind               = 'install'
    state              = 'started'
    plan               = @()
    backups            = @()
    staged             = @('.agents/skills/codex-dsh-team/.user-notes.toolkit-tmp-deadbeef')
    createdDirectories = @()
    manifestBackup     = $false
  }
  Write-ToolkitJsonAtomic -Object $journal -Destination (Join-Path $txnDirectory 'journal.json')

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitRollback $result.ExitCode ('a non-conforming staged name must stop the run: ' + (Get-ToolkitTestOutput $result))
  Assert-FileExists $userFile 'the file must never be deleted'
  Assert-True (Test-ToolkitFileContentEqual -PathA $userFile -PathB $userCopy) 'the file must never be modified'
  Assert-FileExists (Join-Path $txnDirectory 'journal.json') 'the evidence must be kept'
  Remove-Item -LiteralPath $txnDirectory -Recurse -Force
}

Test-Case -Name 'recovery: duplicate JSON keys and malformed evidence are refused' -Body {
  $base = New-ToolkitTestDirectory -Label 'dup-json'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'

  # a) duplicate key inside the journal
  $txnA = Join-Path $state ('txn\' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path (Join-Path $txnA 'backup') -Force | Out-Null
  $badJournal = '{"schema":"codex-dsh-team-toolkit/journal/v1","kind":"install","state":"started","plan":[],"backups":[],"staged":[],"state":"committed","createdDirectories":[],"manifestBackup":false}'
  [IO.File]::WriteAllText((Join-Path $txnA 'journal.json'), $badJournal, (New-Object System.Text.UTF8Encoding($false)))
  $dupResult = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitRollback $dupResult.ExitCode ('a duplicate journal key must stop the run: ' + (Get-ToolkitTestOutput $dupResult))
  Assert-Match (Get-ToolkitTestOutput $dupResult) 'duplicate key' 'the reason must name the duplicate key'
  Assert-FileExists (Join-Path $txnA 'journal.json') 'the evidence must be kept'
  Remove-Item -LiteralPath $txnA -Recurse -Force

  # b) truncated journal
  $txnB = Join-Path $state ('txn\' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path (Join-Path $txnB 'backup') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $txnB 'journal.json'), '{"schema":"codex-dsh-team-toolkit/journal/v1","kind":"inst', (New-Object System.Text.UTF8Encoding($false)))
  $truncResult = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitRollback $truncResult.ExitCode 'a truncated journal must stop the run'
  Assert-FileExists (Join-Path $txnB 'journal.json') 'the evidence must be kept'
  Remove-Item -LiteralPath $txnB -Recurse -Force

  # c) wrong-typed evidence (plan is not an array)
  $txnC = Join-Path $state ('txn\' + [guid]::NewGuid().ToString('n'))
  New-Item -ItemType Directory -Path (Join-Path $txnC 'backup') -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitJsonObject -Properties @{
      schema = 'codex-dsh-team-toolkit/journal/v1'; kind = 'install'; state = 'started'
      plan = 'not-an-array'; backups = @(); staged = @(); createdDirectories = @(); manifestBackup = $false
    }) -Destination (Join-Path $txnC 'journal.json')
  $typeResult = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitRollback $typeResult.ExitCode 'a wrong-typed journal field must stop the run'
  Assert-Match (Get-ToolkitTestOutput $typeResult) 'not an array|unsafe or unsupported' 'the reason must be explicit'
  Remove-Item -LiteralPath $txnC -Recurse -Force

  # d) a duplicate key in the ownership manifest is refused too
  $ledger = Join-Path $state 'manifest.json'
  $good = Get-Content -LiteralPath $ledger -Raw
  $duplicated = $good -replace '"schema":', '"schema": "codex-dsh-team-toolkit/ownership-manifest/v1", "schema":'
  [IO.File]::WriteAllText($ledger, $duplicated, (New-Object System.Text.UTF8Encoding($false)))
  $manifestResult = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitManifest $manifestResult.ExitCode ('a duplicate manifest key must stop the run: ' + (Get-ToolkitTestOutput $manifestResult))
  Assert-Match (Get-ToolkitTestOutput $manifestResult) 'duplicate key' 'the reason must name the duplicate key'
}

Test-Case -Name 'recovery: leftover lock and log from a killed run never block a reinstall' -Body {
  $base = New-ToolkitTestDirectory -Label 'leftovers'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $state -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $state 'install.log') -Content 'leftover log from a killed run'
  Write-ToolkitTestFile -Path (Join-Path $state '.install.lock') -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/lock/v1'; toolkit = 'codex-dsh-team-toolkit'
        processId = 999999; startedAtUtc = [DateTime]::UtcNow.AddHours(-3).ToString('yyyy-MM-ddTHH:mm:ssZ')
      }))

  $blocked = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitBlocked $blocked.ExitCode 'the lock still blocks until it is explicitly cleared'

  $cleared = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; ClearStaleLock = $true }
  Assert-Equal 0 $cleared.ExitCode ('leftovers must not permanently block a reinstall: ' + (Get-ToolkitTestOutput $cleared))
  Assert-Match (Get-ToolkitTestOutput $cleared) 'leftovers from an interrupted run' 'the leftover state must be explained'
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')
  Assert-FileExists (Join-Path $state 'manifest.json')

  # and once installed, a failed run never leaves a lock behind
  Assert-FileMissing (Join-Path $state '.install.lock')
}

Test-Case -Name 'recovery: a state directory with unknown content is never taken over' -Body {
  $base = New-ToolkitTestDirectory -Label 'unknown-state'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $state -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $state 'my-notes.txt') -Content 'user content in a colliding directory'
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitManifest $result.ExitCode ('unknown state content must fail closed: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'unknown content' 'the reason must be explicit'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'nothing may be written or deleted'
}

Test-Case -Name 'toctou: a user edit between planning and applying is refused in-lock' -Body {
  $base = New-ToolkitTestDirectory -Label 'toctou'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $ledger = Join-Path $state 'manifest.json'
  $ownership = Read-ToolkitOwnershipManifest -Path $ledger

  $payloadV2 = New-ToolkitTestPayload -Overrides @{ 'start_dsh_team.cmd' = "@echo off`r`necho v2`r`n" }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2
  $releaseManifest = Read-ToolkitReleaseManifest -Path $packageV2.ManifestPath
  $releaseManifest | Add-Member -NotePropertyName packageRoot -NotePropertyValue $packageV2.Root -Force

  $plan = New-ToolkitInstallPlan -TargetRoot $project -StateDirectory (Join-Path $project '.codex-dsh-team-toolkit') -ReleaseManifest $releaseManifest -OwnershipManifest $ownership
  Assert-True (@($plan.Operations).Count -gt 0) 'the plan must have operations'

  # the user edits a managed file after the plan was built
  Write-ToolkitTestFile -Path (Join-Path $project 'start_dsh_team.cmd') -Content "@echo off`r`necho USER EDIT AFTER PLAN`r`n"
  Assert-ToolkitThrows -Body {
    Assert-ToolkitApplyPreconditions -TargetRoot $project -StateDirectory (Join-Path $project '.codex-dsh-team-toolkit') -Plan $plan -OwnershipManifest $ownership `
      -OwnershipManifestPath $ledger -OwnershipManifestBytes (Get-ToolkitFileBytes -Path $ledger)
  } -Message 'an in-lock user edit must abort the apply'
  Assert-Match (Get-Content -LiteralPath (Join-Path $project 'start_dsh_team.cmd') -Raw) 'USER EDIT AFTER PLAN' 'the user edit must survive'

  # a file that appears at a planned "create" path is also refused
  $freshProject = New-ToolkitTestProject -Root (Join-Path $base 'fresh-project')
  $freshPlan = New-ToolkitInstallPlan -TargetRoot $freshProject -StateDirectory (Join-Path $freshProject '.codex-dsh-team-toolkit') -ReleaseManifest $releaseManifest -OwnershipManifest $null
  Write-ToolkitTestFile -Path (Join-Path $freshProject 'start_dsh_team.cmd') -Content '@echo off'
  Assert-ToolkitThrows -Body {
    Assert-ToolkitApplyPreconditions -TargetRoot $freshProject -StateDirectory (Join-Path $freshProject '.codex-dsh-team-toolkit') -Plan $freshPlan -OwnershipManifest $null -OwnershipManifestPath ''
  } -Message 'a concurrent file at a create path must abort the apply'

  # and a ledger that changed under us is refused
  $ledgerProject = New-ToolkitTestProject -Root (Join-Path $base 'ledger-project')
  $ledgerState = Join-Path $ledgerProject '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $ledgerState -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $ledgerState 'manifest.json') -Content '{"schema":"x"}'
  $ledgerPlan = New-ToolkitInstallPlan -TargetRoot $ledgerProject -StateDirectory (Join-Path $ledgerProject '.codex-dsh-team-toolkit') -ReleaseManifest $releaseManifest -OwnershipManifest $null
  Assert-ToolkitThrows -Body {
    Assert-ToolkitApplyPreconditions -TargetRoot $ledgerProject -Plan $ledgerPlan -OwnershipManifest $null `
      -OwnershipManifestPath (Join-Path $ledgerState 'manifest.json') -OwnershipManifestBytes ([byte[]]@(1,2,3))
  } -Message 'a changed ledger must abort the apply'
}

Test-Case -Name 'paths: a directory that became a junction is never removed as empty' -Body {
  $base = New-ToolkitTestDirectory -Label 'reparse-remove'
  $root = Join-Path $base 'root'
  $outside = Join-Path $base 'outside'
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  New-Item -ItemType Directory -Path $outside -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $outside 'keep.txt') -Content 'outside content'

  $linked = $false
  try {
    New-Item -ItemType Junction -Path (Join-Path $root 'linkdir') -Target $outside -ErrorAction Stop | Out-Null
    $linked = $true
  }
  catch {
    Write-ToolkitTestNote ('this platform cannot create a junction: ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
  }
  if (-not $linked) { return }

  $removed = @(Remove-ToolkitEmptyDirectories -Root $root -RelativeDirectories @('linkdir') -ProtectedDirectories @())
  Assert-Equal 0 $removed.Count 'a reparse point must not be removed'
  Assert-DirectoryExists (Join-Path $root 'linkdir')
  Assert-FileExists (Join-Path $outside 'keep.txt') 'nothing outside the project may be touched'

  # a genuine empty directory is still removed
  New-Item -ItemType Directory -Path (Join-Path $root 'emptydir') -Force | Out-Null
  $removedReal = @(Remove-ToolkitEmptyDirectories -Root $root -RelativeDirectories @('emptydir') -ProtectedDirectories @())
  Assert-Equal 1 $removedReal.Count 'a truly empty directory is removed'
  Assert-FileMissing (Join-Path $root 'emptydir')
}

Test-Case -Name 'recovery: a committed orphan transaction is cleaned up without touching files' -Body {
  $base = New-ToolkitTestDirectory -Label 'committed-orphan'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $target = Join-Path $project 'start_dsh_team.cmd'
  $content = Get-Content -LiteralPath $target -Raw

  # an interrupted run whose journal says the transaction had already committed
  $txn = New-ToolkitTestJournalFor -StateDirectory $state -TargetRoot $project -Kind 'install' -JournalPaths @(
    New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd'; action = 'replace' }
  )
  Backup-ToolkitFile -Transaction $txn -RelativePath 'start_dsh_team.cmd' -SourcePath $target
  $txn.Journal.state = 'committed'
  Save-ToolkitJournal -Transaction $txn

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal 0 $result.ExitCode ('a committed orphan must be cleaned up and the run must continue: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'had already committed' 'the committed state must be reported'
  Assert-FileMissing $txn.Directory 'committed transaction evidence must be removed'
  Assert-Equal $content (Get-Content -LiteralPath $target -Raw) 'a committed transaction must not restore or delete managed content'
}

Test-Case -Name 'isolation: other-Skill and outside-project sentinels survive a failed transaction' -Body {
  $base = New-ToolkitTestDirectory -Label 'sentinels'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  # a second skill and a file entirely outside the project
  $otherSkill = Join-Path $project '.agents\skills\other-skill\SKILL.md'
  New-ToolkitTestSentinel -Path $otherSkill -Content "# another skill - must never change`n" | Out-Null
  $outsidePath = Join-Path $base 'outside-sentinel.txt'
  New-ToolkitTestSentinel -Path $outsidePath -Content 'outside the project - must never change' | Out-Null
  $otherSkillCopy = Join-Path $base 'other-skill-copy.md'
  Copy-Item -LiteralPath $otherSkill -Destination $otherSkillCopy -Force
  $outsideCopy = Join-Path $base 'outside-copy.txt'
  Copy-Item -LiteralPath $outsidePath -Destination $outsideCopy -Force

  $payloadV2 = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/codex-dsh-team/SKILL.md'  = "# fake payload v2`n"
    '.agents/skills/mcp-to-dsh/public/app.js' = "console.log('v2');`n"
    'start_dsh_team.cmd'                      = "@echo off`r`necho v2`r`n"
  }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2

  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root
    TestFault = 'install.after-replace-first'; TestMode = $true
  }
  Assert-Equal $script:ExitTransaction $result.ExitCode
  Assert-Match (Get-ToolkitTestOutput $result) 'Rollback complete' 'the upgrade must roll back'
  Assert-True (Test-ToolkitFileContentEqual -PathA $otherSkill -PathB $otherSkillCopy) 'another skill must never be touched'
  Assert-True (Test-ToolkitFileContentEqual -PathA $outsidePath -PathB $outsideCopy) 'nothing outside the project may be touched'
}

Test-Case -Name 'uninstall: untracked runtime content is reported as kept' -Body {
  $base = New-ToolkitTestDirectory -Label 'untracked-report'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  Write-ToolkitTestFile -Path (Join-Path $project '.agents\skills\mcp-to-dsh\node_modules\dep\index.js') -Content 'module.exports = 1;'
  Write-ToolkitTestFile -Path (Join-Path $project '.agents\skills\mcp-to-dsh\my-notes.md') -Content '# mine'

  $planOnly = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; PlanOnly = $true }
  Assert-Equal 0 $planOnly.ExitCode
  $output = Get-ToolkitTestOutput $planOnly
  Assert-Match $output 'Untracked content that will be kept' 'untracked runtime content must be reported as kept'
  Assert-Match $output 'node_modules' 'the untracked runtime tree must be named'

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode
  Assert-FileExists (Join-Path $project '.agents\skills\mcp-to-dsh\node_modules\dep\index.js') 'node_modules must survive'
  Assert-FileExists (Join-Path $project '.agents\skills\mcp-to-dsh\my-notes.md') 'a user file must survive'
}

Test-Case -Name 'transaction: the remaining documented fault points roll back cleanly' -Body {
  $faultPoints = @('install.after-lock', 'install.after-backup', 'install.after-replace', 'install.before-manifest-commit', 'uninstall.after-journal')
  foreach ($fault in $faultPoints) {
    $base = New-ToolkitTestDirectory -Label ('fault-' + ($fault -replace '[^A-Za-z]', ''))
    $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
    $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
    $before = Get-ToolkitTestManagedSnapshot -Root $project

    if ($fault -like 'uninstall.*') {
      Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode
      $before = Get-ToolkitTestManagedSnapshot -Root $project
      $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true; TestFault = $fault; TestMode = $true }
    }
    else {
      $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; TestFault = $fault; TestMode = $true }
    }

    Assert-Equal $script:ExitTransaction $result.ExitCode ($fault + ' must abort with a transaction failure: ' + (Get-ToolkitTestOutput $result))
    if ($fault -eq 'install.after-lock') {
      # This fault fires before any transaction exists: the invariant is "nothing was mutated",
      # not "a transaction was rolled back".
      Assert-Match (Get-ToolkitTestOutput $result) 'Install failed' ($fault + ' must report the failure')
      Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') ($fault + ' must not leave a state directory behind')
    }
    else {
      Assert-Match (Get-ToolkitTestOutput $result) 'Rollback complete' ($fault + ' must roll back')
      Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit\txn') ($fault + ' must not leave transaction evidence behind')
    }
    Assert-Equal ($before -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') ($fault + ' must restore every managed file')
  }
}

Test-Case -Name 'transaction: a post-commit failure is reported and the previous state is restored' -Body {
  $base = New-ToolkitTestDirectory -Label 'post-commit'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $before = Get-ToolkitTestManagedSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TestFault = 'install.after-manifest-commit'; TestMode = $true
  }
  Assert-Equal $script:ExitTransaction $result.ExitCode ('a post-commit fault must be reported: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'Rollback complete' 'the committed transaction must still be undone cleanly'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') 'no partial install may survive'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') 'the project must be back to its previous state'
}

Test-Case -Name 'transaction: test-only features are refused without the explicit environment gate' -Body {
  $base = New-ToolkitTestDirectory -Label 'testgate'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $saved = $env:CODEX_DSH_TOOLKIT_TEST
  try {
    $env:CODEX_DSH_TOOLKIT_TEST = $null
    $result = Invoke-ToolkitTestCommand -Options @{
      Action = 'Install'; Target = $project; PackageRoot = $package.Root
      TestFault = 'install.after-stage'; TestMode = $true
    }
  }
  finally {
    $env:CODEX_DSH_TOOLKIT_TEST = $saved
  }

  Assert-Equal $script:ExitUsage $result.ExitCode ('the gate must refuse test features: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'CODEX_DSH_TOOLKIT_TEST' 'the gate must name the environment variable'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'nothing may be written'
}

Test-Case -Name 'recovery: an anomalous lock is never broken even with the explicit switch' -Body {
  $base = New-ToolkitTestDirectory -Label 'anomalous-lock'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')

  # 1) a syntactically valid but process-less lock (no plausible pid) stays fail-closed
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $state -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitOwnershipManifest -InstallId ([guid]::NewGuid().ToString()) -Version '0.0.1' -TargetRoot $project -Files @(
      New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' }
    )) -Destination (Join-Path $state 'manifest.json')
  Write-ToolkitTestFile -Path (Join-Path $state '.install.lock') -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/lock/v1'; toolkit = 'codex-dsh-team-toolkit'
        processId = 0; startedAtUtc = [DateTime]::UtcNow.AddHours(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
      }))
  $noPid = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; ClearStaleLock = $true }
  Assert-Equal $script:ExitBlocked $noPid.ExitCode ('a lock without a plausible pid must not be broken: ' + (Get-ToolkitTestOutput $noPid))
  Assert-Match (Get-ToolkitTestOutput $noPid) 'not provably stale' 'the refusal must be explicit'
  Assert-FileExists (Join-Path $state '.install.lock') 'the anomalous lock must survive'

  # 2) a corrupt lock record is also fail-closed
  $projectB = New-ToolkitTestProject -Root (Join-Path $base 'project-b')
  $stateB = Join-Path $projectB '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $stateB -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitOwnershipManifest -InstallId ([guid]::NewGuid().ToString()) -Version '0.0.1' -TargetRoot $projectB -Files @(
      New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' }
    )) -Destination (Join-Path $stateB 'manifest.json')
  Write-ToolkitTestFile -Path (Join-Path $stateB '.install.lock') -Content '{ not a lock record'
  $corrupt = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $projectB; PackageRoot = $package.Root; ClearStaleLock = $true }
  Assert-Equal $script:ExitBlocked $corrupt.ExitCode ('a corrupt lock must not be broken: ' + (Get-ToolkitTestOutput $corrupt))
  Assert-FileExists (Join-Path $stateB '.install.lock') 'the corrupt lock must survive'

  # 3) a lock whose recorded process is still running is refused too
  $projectC = New-ToolkitTestProject -Root (Join-Path $base 'project-c')
  $stateC = Join-Path $projectC '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $stateC -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitOwnershipManifest -InstallId ([guid]::NewGuid().ToString()) -Version '0.0.1' -TargetRoot $projectC -Files @(
      New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' }
    )) -Destination (Join-Path $stateC 'manifest.json')
  Write-ToolkitTestFile -Path (Join-Path $stateC '.install.lock') -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/lock/v1'; toolkit = 'codex-dsh-team-toolkit'
        processId = $PID; startedAtUtc = [DateTime]::UtcNow.AddHours(-5).ToString('yyyy-MM-ddTHH:mm:ssZ')
      }))
  $live = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $projectC; PackageRoot = $package.Root; ClearStaleLock = $true }
  Assert-Equal $script:ExitBlocked $live.ExitCode 'a live owner process must never be ignored, even when the lock is old'
  Assert-FileExists (Join-Path $stateC '.install.lock') 'the live lock must survive'
}

Test-Case -Name 'transaction: PlanOnly runs the full read-only package preflight' -Body {
  $base = New-ToolkitTestDirectory -Label 'planonly-preflight'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  # The preflight proves package *structure*: with no digest to compare there is nothing that
  # can disagree about content, but a missing managed source must stop a dry run exactly like a
  # real run.
  Remove-Item -LiteralPath (Join-Path $package.Root 'payload\.agents\skills\mcp-to-dsh\SKILL.md') -Force
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; PlanOnly = $true }
  Assert-Equal $script:ExitManifest $result.ExitCode ('plan-only must fail on an incomplete package: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'missing from the package' 'the preflight reason must be explicit'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'plan-only must still write nothing'
}

Test-Case -Name 'confirm: install shows the plan before any state, lock or runtime write and needs consent' -Body {
  $base = New-ToolkitTestDirectory -Label 'install-confirm'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $runtimeBase = Join-Path $base 'runtime-base'
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  # 1) non-interactive without -Yes refuses with exit 8 and writes nothing at all
  $refused = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    RuntimeRootBase = $runtimeBase; InitializeRuntime = $true
    NonInteractive = $true; Yes = $false
  }
  Assert-Equal $script:ExitCancelled $refused.ExitCode ('install without consent must refuse: ' + (Get-ToolkitTestOutput $refused))
  Assert-Match (Get-ToolkitTestOutput $refused) 'awaiting confirmation' 'the plan must be shown before the refusal'
  Assert-Match (Get-ToolkitTestOutput $refused) '-Yes' 'the refusal must say what is missing'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'nothing may be written'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit') 'no state directory before consent'
  Assert-FileMissing $runtimeBase 'no runtime base before consent'

  # 2) an interactive decline also writes nothing (the answer is injected through the
  #    test-only, gate-protected confirmation hook so the flow is deterministic)
  $declined = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    RuntimeRootBase = $runtimeBase; InitializeRuntime = $true
    NonInteractive = $false; Yes = $false
    TestMode = $true; TestConfirmation = 'no'
  }
  Assert-Equal 0 $declined.ExitCode 'declining is not an error'
  Assert-Match (Get-ToolkitTestOutput $declined) 'Cancelled by the user' 'the decline must be reported'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'a decline must write nothing'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
  Assert-FileMissing $runtimeBase

  # 3) explicit -Yes proceeds and the plan is still shown first
  $accepted = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    RuntimeRootBase = $runtimeBase; InitializeRuntime = $true; Yes = $true
  }
  Assert-Equal 0 $accepted.ExitCode ('confirmed install must succeed: ' + (Get-ToolkitTestOutput $accepted))
  $output = Get-ToolkitTestOutput $accepted
  $planIndex = $output.IndexOf('awaiting confirmation')
  $applyIndex = $output.IndexOf('Installed toolkit')
  Assert-True ($planIndex -ge 0 -and $applyIndex -gt $planIndex) 'the plan must be displayed before the install summary'
  Assert-FileExists (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
}

Test-Case -Name 'confirm: PlanOnly stays absolutely zero-write even with orphan transactions' -Body {
  $base = New-ToolkitTestDirectory -Label 'planonly-orphan'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  # leave an interrupted transaction plus a half-applied file behind
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $target = Join-Path $project 'start_dsh_team.cmd'
  $txn = New-ToolkitTestJournalFor -StateDirectory $state -TargetRoot $project -Kind 'install' -JournalPaths @(
    New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd'; action = 'replace' }
  )
  Backup-ToolkitFile -Transaction $txn -RelativePath 'start_dsh_team.cmd' -SourcePath $target
  Backup-ToolkitManifest -Transaction $txn -ManifestPath (Join-Path $state 'manifest.json')
  Write-ToolkitTestFile -Path $target -Content "@echo off`r`necho HALF APPLIED`r`n"

  $before = Get-ToolkitTestTreeSnapshot -Root $project
  $payloadV2 = New-ToolkitTestPayload -Overrides @{ 'start_dsh_team.cmd' = "@echo off`r`necho v2`r`n" }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2

  $planOnly = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root; PlanOnly = $true }
  Assert-Equal 0 $planOnly.ExitCode ('plan-only must succeed with orphans present: ' + (Get-ToolkitTestOutput $planOnly))
  Assert-Match (Get-ToolkitTestOutput $planOnly) 'Interrupted transaction evidence found' 'the pending recovery must be reported'
  Assert-Match (Get-ToolkitTestOutput $planOnly) 'nothing was written' 'plan-only must say so'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'plan-only with orphans must not write or replay anything'
  Assert-FileExists (Join-Path $txn.Directory 'journal.json') 'the orphan evidence must still be there'
  Assert-Match (Get-Content -LiteralPath $target -Raw) 'HALF APPLIED' 'the interrupted state must be untouched'
}

Test-Case -Name 'lifecycle: uninstall followed by a reinstall works repeatedly' -Body {
  $base = New-ToolkitTestDirectory -Label 'reinstall'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  foreach ($cycle in 1..3) {
    $install = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
    Assert-Equal 0 $install.ExitCode ('install cycle ' + $cycle + ' must succeed: ' + (Get-ToolkitTestOutput $install))
    Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')
    Assert-FileExists (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')

    $uninstall = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
    Assert-Equal 0 $uninstall.ExitCode ('uninstall cycle ' + $cycle + ' must succeed: ' + (Get-ToolkitTestOutput $uninstall))
    Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd')
    Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
    Assert-FileExists (Join-Path $project 'src\app.js') 'user files survive every cycle'
  }
}

Test-Case -Name 'lifecycle: the state directory ignores itself in the target project' -Body {
  $base = New-ToolkitTestDirectory -Label 'selfignore'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Remove-Item -LiteralPath (Join-Path $project 'README.md') -Force

  $before = Get-ToolkitTestTreeSnapshot -Root $project
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  # the toolkit never edits or creates the project's own .gitignore
  Assert-FileMissing (Join-Path $project '.gitignore') 'the project .gitignore must not be created or edited'

  # every pre-existing user file is still present with identical content
  $after = Get-ToolkitTestTreeSnapshot -Root $project
  foreach ($entry in @($before)) {
    Assert-True ($after -contains $entry) ('the user file must be untouched: ' + [string]$entry)
  }

  # instead the state directory carries its own self-ignoring .gitignore
  $selfIgnore = Join-Path $project '.codex-dsh-team-toolkit\.gitignore'
  Assert-FileExists $selfIgnore 'the state directory must ignore itself'
  Assert-Match (Get-Content -LiteralPath $selfIgnore -Raw) '\*' 'the self-ignore must ignore the whole directory'
}
