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
  # The toolkit's own unreferenced pristine copies (paths the pre-uninstall ledger proved) are
  # still pruned; the retained baseline is the only one left (SAFE-01: no bare count, the
  # per-item rule is asserted explicitly).
  $pristineRoot = Join-Path $state 'pristine'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $pristineRoot 'start_dsh_team.cmd'))) 'the toolkit copy of a deleted managed file must be pruned'
  Assert-True (-not (Test-Path -LiteralPath (Join-Path $pristineRoot '.agents\skills\mcp-to-dsh\SKILL.md'))) 'the toolkit copy of a deleted managed file must be pruned'
  Assert-Equal 1 @(Get-ChildItem -LiteralPath $pristineRoot -Recurse -Force -File).Count 'only the referenced baseline may remain'

  # a second uninstall run must again refuse to delete the user-modified file
  $second = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $second.ExitCode
  Assert-Match (Get-Content -LiteralPath $edited -Raw) 'changed this file by hand' 'the file must still be there after a second run'
  Assert-FileExists $pristine 'the evidence must still be there after the second run'
  Assert-FileExists $gitIgnore 'the self-ignore boundary must still be there after the second run'
  # MINOR-3: a partial uninstall with nothing but deliberately retained evidence reports no
  # "unprovable content" at all (only the retained-evidence line).
  Assert-NotMatch (Get-ToolkitTestOutput $result) 'cannot prove it created' 'deliberately retained evidence must never be misreported'
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

Test-Case -Name 'uninstall: user content inside the state directory is never deleted (SAFE-01)' -Body {
  $base = New-ToolkitTestDirectory -Label 'safe01-full'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  # A toolkit-owned *name* must not imply that its descendants are owned: drop user content into
  # every state sub-tree the cleanup used to delete wholesale.
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $notes = @{
    'pristine'                    = 'pristine\my-note.txt'
    'pristine-nested'             = 'pristine\.agents\skills\mcp-to-dsh\my-own-note.md'
    'txn'                         = 'txn\user-kept\inner-note.txt'
    'quarantine'                  = 'quarantine\my-quarantine-note.txt'
    'backup'                      = 'backup\my-backup-note.txt'
  }
  $expected = @{}
  foreach ($key in $notes.Keys) {
    $relative = [string]$notes[$key]
    $full = Join-Path $state $relative
    Write-ToolkitTestFile -Path $full -Content ("# user content: " + $key + "`n")
    $expected[$full] = Get-Content -LiteralPath $full -Raw
  }
  # a user-edited self-ignore file must not be deleted as if it were the generated one
  $gitIgnorePath = Join-Path $state '.gitignore'
  Write-ToolkitTestFile -Path $gitIgnorePath -Content "# my own ignore rules`n*`n!my-note.txt`n"
  $expected[$gitIgnorePath] = Get-Content -LiteralPath $gitIgnorePath -Raw
  $gitIgnoreCopy = Join-Path $base 'gitignore-before.txt'
  Copy-Item -LiteralPath $gitIgnorePath -Destination $gitIgnoreCopy -Force

  $beforeManaged = Join-Path $project 'start_dsh_team.cmd'
  Assert-FileExists $beforeManaged

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('the uninstall must still succeed: ' + (Get-ToolkitTestOutput $result))
  $output = Get-ToolkitTestOutput $result

  # every piece of user content survives byte for byte and is reported
  foreach ($full in $expected.Keys) {
    Assert-FileExists $full ('user content under the state directory must survive: ' + $full)
    Assert-Equal $expected[$full] (Get-Content -LiteralPath $full -Raw) ('user content must be unchanged: ' + $full)
  }
  Assert-Match $output 'Preserved state-directory content the toolkit cannot prove it created' 'the preserved content must be reported'
  Assert-Match $output 'never deleted' 'the safety promise must be stated'
  Assert-Match $output 'my-note\.txt' 'the preserved content must be named'

  # ... while the toolkit's own managed files are still removed and no ownership evidence remains
  Assert-FileMissing $beforeManaged 'managed files are still removed'
  Assert-FileMissing (Join-Path $state 'manifest.json') 'a complete uninstall still removes the ledger'
  Assert-True (Test-ToolkitFileContentEqual -PathA $gitIgnorePath -PathB $gitIgnoreCopy) 'the user-edited .gitignore stays in place byte for byte'
  Assert-Match (Get-Content -LiteralPath $gitIgnorePath -Raw) 'my own ignore rules' 'the user-edited .gitignore keeps its user content'
}

Test-Case -Name 'uninstall: a user file under pristine survives while toolkit copies are pruned (SAFE-01)' -Body {
  $base = New-ToolkitTestDirectory -Label 'safe01-partial'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $note = Join-Path $state 'pristine\my-note.txt'
  Write-ToolkitTestFile -Path $note -Content "# a user note next to the baselines`n"
  $noteCopy = Join-Path $base 'note-before.txt'
  Copy-Item -LiteralPath $note -Destination $noteCopy -Force

  # a user edit forces a partial uninstall with a reduced ledger
  $edited = Join-Path $project '.agents\skills\codex-dsh-team\SKILL.md'
  Write-ToolkitTestFile -Path $edited -Content "# I changed this file by hand`n"

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('the partial uninstall must succeed: ' + (Get-ToolkitTestOutput $result))
  $output = Get-ToolkitTestOutput $result

  # the user note survives and is reported; the referenced baseline still survives
  Assert-FileExists $note 'a user file under pristine/ must survive a partial uninstall'
  Assert-True (Test-ToolkitFileContentEqual -PathA $note -PathB $noteCopy) 'the user note must be unchanged'
  Assert-Match $output 'Preserved state-directory content' 'the preserved user file must be reported'
  $ownership = Read-ToolkitOwnershipManifest -Path (Join-Path $state 'manifest.json')
  $pristine = Join-Path $state ([string]$ownership.files[0].pristine -replace '/', '\')
  Assert-FileExists $pristine 'the referenced pristine baseline must survive'
  Assert-FileMissing (Join-Path $state 'pristine\start_dsh_team.cmd') 'the toolkit copy of a deleted managed file must still be pruned'
  Assert-FileExists (Join-Path $state '.gitignore') 'the self-ignore boundary must survive'
  # MINOR-3: only the genuine user file may be reported as unprovable - the baseline this run
  # deliberately retains must not be counted or listed as content the toolkit cannot prove.
  Assert-Match $output 'cannot prove it created: 1' 'only the user file may be reported as unprovable'
  Assert-Match $output 'my-note\.txt' 'the genuine user file must be named'
  Assert-NotMatch $output 'pristine[\\/]\.agents' 'the deliberately retained baseline must not be reported as unprovable'
  Assert-Match $output 'Ownership evidence kept' 'the retained evidence must be reported as such'
}

Test-Case -Name 'uninstall: kept transaction evidence survives the state cleanup (MAJOR-1)' -Body {
  $base = New-ToolkitTestDirectory -Label 'safe01-keepevidence'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $relative = 'start_dsh_team.cmd'
  $target = Join-Path $project $relative
  $originalCopy = Join-Path $base 'original-managed-file.cmd'
  Copy-Item -LiteralPath $target -Destination $originalCopy -Force

  # Build exactly the evidence a run leaves behind when a quarantined file could not be removed:
  # a real transaction (journal + ledger backup) with the original sitting in quarantine.
  $plan = New-ToolkitJsonObject -Properties @{
    JournalPaths       = @(New-ToolkitJsonObject -Properties @{ path = $relative; action = 'remove' })
    Notes              = @()
    CreatedDirectories = @()
  }
  $txn = Start-ToolkitTransaction -StateDirectory $state -TargetRoot $project -Kind 'uninstall' -Plan $plan -ToolkitVersion '1.0.0'
  Backup-ToolkitFile -Transaction $txn -RelativePath $relative -SourcePath $target
  Backup-ToolkitManifest -Transaction $txn -ManifestPath (Join-Path $state 'manifest.json')
  $quarantine = Join-Path $txn.Directory 'quarantine'
  New-Item -ItemType Directory -Path $quarantine -Force | Out-Null
  [System.IO.File]::Move($target, (Join-Path $quarantine $relative))

  $txnRelative = ('txn/' + [System.IO.Path]::GetFileName([string]$txn.Directory))
  $journalPath = Join-Path $txn.Directory 'journal.json'
  $manifestBackup = Join-Path $txn.Directory 'backup\ownership-manifest.json'
  $quarantinedOriginal = Join-Path $quarantine $relative
  Assert-FileExists $journalPath 'the fixture must carry a journal'
  Assert-FileExists $manifestBackup 'the fixture must carry the ledger backup'
  Assert-FileExists $quarantinedOriginal 'the fixture must carry the quarantined original'

  # The success path calls the cleanup with the current transaction excluded (keepEvidence=true)
  $ledger = Read-ToolkitOwnershipManifest -Path (Join-Path $state 'manifest.json')
  $proven = @($ledger.files | ForEach-Object { [string]$_.path })
  $kept = Remove-ToolkitStateInternals -StateDirectory $state -KeepDirectory:$true -PreserveEvidence `
    -ReferencedManagedPaths @($relative) -ProvenManagedPaths $proven -PreserveRelativeRoots @($txnRelative)
  Assert-Equal 0 @($kept.Problems).Count 'excluding the current transaction must not report a problem'

  Assert-FileExists $journalPath 'journal.json must survive when the evidence is kept'
  Assert-FileExists $manifestBackup 'the ledger backup must survive when the evidence is kept'
  Assert-FileExists $quarantinedOriginal 'the quarantined original must survive when the evidence is kept'
  Assert-True (Test-ToolkitFileContentEqual -PathA $quarantinedOriginal -PathB $originalCopy) 'the quarantined original must still hold the bytes it was moved with'
}

Test-Case -Name 'cleanup: a direct file under txn/ and a file under engine/ survive and are reported (MINOR-1)' -Body {
  $base = New-ToolkitTestDirectory -Label 'safe01-unenumerated'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $txnFile = Join-Path $state 'txn\user-note.txt'
  $engineFile = Join-Path $state 'engine\my-own-note.md'
  Write-ToolkitTestFile -Path $txnFile -Content "# a user file directly under txn`n"
  Write-ToolkitTestFile -Path $engineFile -Content "# a user file under engine`n"
  $txnCopy = Join-Path $base 'txn-note.txt'
  $engineCopy = Join-Path $base 'engine-note.txt'
  Copy-Item -LiteralPath $txnFile -Destination $txnCopy -Force
  Copy-Item -LiteralPath $engineFile -Destination $engineCopy -Force

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('the uninstall must succeed: ' + (Get-ToolkitTestOutput $result))
  $output = Get-ToolkitTestOutput $result

  Assert-FileExists $txnFile 'a direct file under txn/ must survive'
  Assert-FileExists $engineFile 'a file under engine/ must survive'
  Assert-True (Test-ToolkitFileContentEqual -PathA $txnFile -PathB $txnCopy) 'the txn file must be unchanged'
  Assert-True (Test-ToolkitFileContentEqual -PathA $engineFile -PathB $engineCopy) 'the engine file must be unchanged'
  Assert-Match $output 'user-note\.txt' 'the preserved txn file must be reported'
  Assert-Match $output 'my-own-note\.md' 'the preserved engine file must be reported'
  # the state directory survives with preserved content, so it must carry a current self-ignore file
  Assert-FileExists (Join-Path $state '.gitignore') 'preserved content must leave a self-ignoring .gitignore behind'
  Assert-Match (Get-Content -LiteralPath (Join-Path $state '.gitignore') -Raw) '(?m)^\*' 'the rewritten .gitignore must still ignore the whole state directory'

  # and the preserved state does not fabricate ownership records for those user files
  $ledgerPath = Join-Path $state 'manifest.json'
  if (Test-Path -LiteralPath $ledgerPath) {
    $ledgerText = Get-Content -LiteralPath $ledgerPath -Raw
    Assert-NotMatch $ledgerText 'user-note\.txt' 'a user file must never be recorded as a managed path'
    Assert-NotMatch $ledgerText 'my-own-note\.md' 'a user file must never be recorded as a managed path'
  }
}

Test-Case -Name 'uninstall: a file resident in state/quarantine is reported but never ledgered (MINOR-2)' -Body {
  $base = New-ToolkitTestDirectory -Label 'safe01-quarantine-ledger'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $note = Join-Path $state 'quarantine\my-quarantine-note.txt'
  Write-ToolkitTestFile -Path $note -Content "# resident in quarantine`n"
  $noteCopy = Join-Path $base 'quarantine-note.txt'
  Copy-Item -LiteralPath $note -Destination $noteCopy -Force

  # a user edit forces a partial uninstall, which writes a reduced ledger
  $edited = Join-Path $project '.agents\skills\codex-dsh-team\SKILL.md'
  Write-ToolkitTestFile -Path $edited -Content "# edited by hand`n"

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('the partial uninstall must succeed: ' + (Get-ToolkitTestOutput $result))

  Assert-FileExists $note 'the resident quarantine file must survive'
  Assert-True (Test-ToolkitFileContentEqual -PathA $note -PathB $noteCopy) 'the resident quarantine file must be unchanged'
  $ownership = Read-ToolkitOwnershipManifest -Path (Join-Path $state 'manifest.json')
  Assert-Equal 1 @($ownership.files).Count 'only the retained managed file may be in the reduced ledger'
  Assert-Equal '.agents/skills/codex-dsh-team/SKILL.md' ([string]($ownership.files[0].path)) 'the ledger must not fabricate an entry for the quarantine file'
  Assert-NotMatch (Get-Content -LiteralPath (Join-Path $state 'manifest.json') -Raw) 'my-quarantine-note' 'a quarantine resident must never become a managed path'
}

Test-Case -Name 'cleanup: a state root name occupied by a regular file is reported and keeps the self-ignore (NEW-2)' -Body {
  $base = New-ToolkitTestDirectory -Label 'safe01-occupied-root'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  # The uninstall itself does not use the top-level quarantine/ or backup/ roots, so occupying them
  # with regular files must not block it: they are preserved, reported, and the state directory
  # keeps its self-ignoring .gitignore.
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $quarantineFile = Join-Path $state 'quarantine'
  $backupFile = Join-Path $state 'backup'
  Write-ToolkitTestFile -Path $quarantineFile -Content "# a user file named quarantine`n"
  Write-ToolkitTestFile -Path $backupFile -Content "# a user file named backup`n"
  $quarantineCopy = Join-Path $base 'quarantine-before.txt'
  $backupCopy = Join-Path $base 'backup-before.txt'
  Copy-Item -LiteralPath $quarantineFile -Destination $quarantineCopy -Force
  Copy-Item -LiteralPath $backupFile -Destination $backupCopy -Force

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('the uninstall must still succeed: ' + (Get-ToolkitTestOutput $result))
  $output = Get-ToolkitTestOutput $result

  Assert-FileExists $quarantineFile 'a file occupying the quarantine root name must survive'
  Assert-FileExists $backupFile 'a file occupying the backup root name must survive'
  Assert-True (Test-ToolkitFileContentEqual -PathA $quarantineFile -PathB $quarantineCopy) 'the occupied root file must be unchanged'
  Assert-True (Test-ToolkitFileContentEqual -PathA $backupFile -PathB $backupCopy) 'the occupied root file must be unchanged'
  Assert-Match $output 'occupied by a file' 'the occupation must be reported'
  Assert-Match $output 'occupies the toolkit state root name' 'the cleanup must report the preserved occupation'

  # the self-ignore invariant must hold for this occupation form too
  $gitIgnore = Join-Path $state '.gitignore'
  Assert-FileExists $gitIgnore 'a surviving state directory must keep its self-ignoring .gitignore'
  Assert-Match (Get-Content -LiteralPath $gitIgnore -Raw) '(?m)^\*' 'the .gitignore must still ignore the whole state directory'
  # and the managed files are still removed
  Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd') 'managed files are still removed'
}

Test-Case -Name 'cleanup: an occupied txn root fails closed with a remediation (NEW-2/NEW-5)' -Body {
  $base = New-ToolkitTestDirectory -Label 'safe01-occupied-txn'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  # A txn root occupied by a file makes a transaction impossible: fail closed, with a clear reason
  # and an actionable remediation, and never delete the occupying file.
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  $txnFile = Join-Path $state 'txn'
  Write-ToolkitTestFile -Path $txnFile -Content "# a user file named txn`n"
  $txnCopy = Join-Path $base 'txn-before.txt'
  Copy-Item -LiteralPath $txnFile -Destination $txnCopy -Force
  $managedBefore = Join-Path $project 'start_dsh_team.cmd'
  $managedCopy = Join-Path $base 'managed-before.cmd'
  Copy-Item -LiteralPath $managedBefore -Destination $managedCopy -Force

  $blocked = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-True ($blocked.ExitCode -ne 0) ('an occupied txn root must fail closed: ' + (Get-ToolkitTestOutput $blocked))
  Assert-Match (Get-ToolkitTestOutput $blocked) 'occupied by a file' 'the refusal must explain the occupation'
  Assert-Match (Get-ToolkitTestOutput $blocked) 'Remediation' 'the refusal must carry a remediation (NEW-5)'
  Assert-True (Test-ToolkitFileContentEqual -PathA $txnFile -PathB $txnCopy) 'the occupying file must never be deleted'
  Assert-True (Test-ToolkitFileContentEqual -PathA $managedBefore -PathB $managedCopy) 'a refused uninstall must not delete managed files'
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
