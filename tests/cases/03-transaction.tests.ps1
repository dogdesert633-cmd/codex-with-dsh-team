#Requires -Version 5.1
<#
  03 - transactional behaviour: durable journal, backups, atomic replace, rollback, locking.
#>

function Get-ToolkitTestFaultOptions {
  param(
    [string]$Project,
    [string]$Package,
    [string]$Fault,
    [switch]$Upgrade
  )
  return @{
    Action            = 'Install'
    Target            = $Project
    PackageRoot       = $Package
    TestFault         = $Fault
    TestMode          = $true
    TestKeepTransaction = $true
  }
}

Test-Case -Name 'transaction: a fault after staging rolls back a first install completely' -Body {
  $base = New-ToolkitTestDirectory -Label 'txn-stage'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TestFault = 'install.after-stage'; TestMode = $true
  }
  Assert-Equal $script:ExitTransaction $result.ExitCode ('fault must abort: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'Rollback complete' 'rollback must be reported'

  $after = Get-ToolkitTestTreeSnapshot -Root $project
  Assert-Equal ($before -join ';') ($after -join ';') 'the project must be byte-identical after rollback (no staged temp files, no created directories)'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
  Assert-FileMissing (Join-Path $project '.agents')
}

Test-Case -Name 'transaction: a fault after the first replace restores every previous file' -Body {
  $base = New-ToolkitTestDirectory -Label 'txn-upgrade'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode
  $before = Get-ToolkitTestManagedSnapshot -Root $project

  $payloadV2 = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/codex-dsh-team/SKILL.md'  = "# fake payload v2`n"
    '.agents/skills/mcp-to-dsh/public/app.js' = "console.log('v2');`n"
    'start_dsh_team.cmd'                      = "@echo off`r`necho v2 start`r`n"
  }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2

  $result = Invoke-ToolkitTestCommand -Options (Get-ToolkitTestFaultOptions -Project $project -Package $packageV2.Root -Fault 'install.after-replace-first')
  Assert-Equal $script:ExitTransaction $result.ExitCode ('fault must abort the upgrade: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'Rollback complete' 'rollback must be reported'

  $after = Get-ToolkitTestManagedSnapshot -Root $project
  Assert-Equal ($before -join ';') ($after -join ';') 'every managed file must be restored byte for byte'
  $ownership = Read-ToolkitOwnershipManifest -Path (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
  Assert-Equal '1.0.0' $ownership.version 'the ownership manifest must still describe the previous version'
  Assert-Match (Get-Content -LiteralPath (Join-Path $project '.agents\skills\codex-dsh-team\SKILL.md') -Raw) 'version 1' 'old content must be back'

  # the prior pristine evidence must be restored together with the target bytes
  foreach ($file in @($ownership.files)) {
    $installed = Join-Path $project ([string]$file.path -replace '/', '\')
    $pristine = Join-Path $project ('.codex-dsh-team-toolkit\' + ([string]$file.pristine -replace '/', '\'))
    Assert-FileExists $pristine ('the pristine baseline must survive a rollback: ' + [string]$file.path)
    Assert-True (Test-ToolkitFileContentEqual -PathA $installed -PathB $pristine) ('the restored target and its pristine baseline must agree: ' + [string]$file.path)
  }
}

Test-Case -Name 'transaction: a fault at manifest commit leaves no partial install behind' -Body {
  $base = New-ToolkitTestDirectory -Label 'txn-commit'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options (Get-ToolkitTestFaultOptions -Project $project -Package $package.Root -Fault 'install.before-manifest-commit')
  Assert-Equal $script:ExitTransaction $result.ExitCode
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
  Assert-Equal ($before -join ';') ((Get-ToolkitTestManagedSnapshot -Root $project) -join ';') 'no managed file may survive a rollback'
  Assert-DirectoryExists $result.TransactionDirectory
  Assert-FileMissing (Join-Path $result.TransactionDirectory 'journal.json.lock')
}

Test-Case -Name 'transaction: the durable journal holds relative paths only and no file contents' -Body {
  $base = New-ToolkitTestDirectory -Label 'journal'
  $marker = 'FAKE-JOURNAL-CONTENT-MARKER-0001'
  $payload = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/codex-dsh-team/SKILL.md' = ("# fake payload`n" + $marker + "`n")
  }
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -PayloadFiles $payload
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $result = Invoke-ToolkitTestCommand -Options (Get-ToolkitTestFaultOptions -Project $project -Package $package.Root -Fault 'install.after-journal')
  Assert-Equal $script:ExitTransaction $result.ExitCode

  $journalPath = Join-Path $result.TransactionDirectory 'journal.json'
  Assert-FileExists $journalPath 'the durable journal must exist'
  $journalText = Get-Content -LiteralPath $journalPath -Raw
  Assert-Match $journalText '"schema"\s*:\s*"codex-dsh-team-toolkit/journal/v1"' 'the journal must be identified'
  Assert-Match $journalText '\.agents/skills/codex-dsh-team/SKILL\.md' 'the journal must record managed relative paths'
  Assert-NotMatch $journalText ([regex]::Escape($marker)) 'the journal must never contain file contents'
  Assert-NotMatch $journalText ([regex]::Escape($project)) 'the journal must not persist an absolute personal path'
  Assert-NotMatch $journalText '(?i)sha256|hashalgorithm|digest|targetroothash' 'the journal must not keep any digest or hashed identity'

  $backups = Join-Path $result.TransactionDirectory 'backup'
  Assert-DirectoryExists $backups 'the transaction must own a backup directory'
}

Test-Case -Name 'transaction: fault injection is refused without -TestMode' -Body {
  $base = New-ToolkitTestDirectory -Label 'faultguard'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{
    Action      = 'Install'
    Target      = $project
    PackageRoot = $package.Root
    TestFault   = 'install.after-stage'
  }
  Assert-Equal $script:ExitUsage $result.ExitCode
  Assert-Match (Get-ToolkitTestOutput $result) 'requires -TestMode' 'the guard must be explicit'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'nothing may be written'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
}

Test-Case -Name 'transaction: an existing lock blocks a concurrent run without writing' -Body {
  $base = New-ToolkitTestDirectory -Label 'lock'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $stateDirectory = Join-Path $project '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $stateDirectory '.install.lock') -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/lock/v1'; toolkit = 'codex-dsh-team-toolkit'; processId = $PID; startedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      }))

  # a state directory holding only toolkit-owned leftovers (no ledger) is recoverable, so the
  # lock itself is what blocks — it is not treated as an unknown directory takeover
  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitBlocked $result.ExitCode ('the lock must block: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'lock' 'the reason must mention the lock'
  Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd')

  # unknown content in a ledger-less state directory stays fail-closed
  Write-ToolkitTestFile -Path (Join-Path $stateDirectory 'not-ours.txt') -Content 'user content'
  Remove-Item -LiteralPath (Join-Path $stateDirectory '.install.lock') -Force
  $unknown = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitManifest $unknown.ExitCode ('unknown state content must fail closed: ' + (Get-ToolkitTestOutput $unknown))
  Assert-Match (Get-ToolkitTestOutput $unknown) 'unknown content' 'the reason must be explicit'
  Assert-FileExists (Join-Path $stateDirectory 'not-ours.txt') 'unknown content is never deleted'
  Assert-FileMissing (Join-Path $project 'start_dsh_team.cmd')
}

Test-Case -Name 'transaction: a provably stale lock can be cleared explicitly, a live one cannot' -Body {
  $base = New-ToolkitTestDirectory -Label 'stalelock'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  # 1) a live lock owned by this process must never be broken, even explicitly
  $live = New-ToolkitTestProject -Root (Join-Path $base 'live-project')
  $liveState = Join-Path $live '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $liveState -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $liveState '.install.lock') -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/lock/v1'; toolkit = 'codex-dsh-team-toolkit'; processId = $PID; startedAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      }))
  $ownership = New-ToolkitOwnershipManifest -InstallId ([guid]::NewGuid().ToString()) -Version '0.0.1' -TargetRoot $live -Files @(
    New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' }
  )
  Write-ToolkitJsonAtomic -Object $ownership -Destination (Join-Path $liveState 'manifest.json')

  $liveResult = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $live; PackageRoot = $package.Root; ClearStaleLock = $true }
  Assert-Equal $script:ExitBlocked $liveResult.ExitCode ('a live lock must not be broken: ' + (Get-ToolkitTestOutput $liveResult))
  Assert-Match (Get-ToolkitTestOutput $liveResult) 'not provably stale' 'the refusal must explain why the lock was kept'
  Assert-FileExists (Join-Path $liveState '.install.lock') 'the live lock must survive'
  Assert-FileMissing (Join-Path $live 'start_dsh_team.cmd')

  # 2) an old lock from a dead process, on a healthy install state, can be cleared explicitly
  $state = Join-Path $project '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $state -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitOwnershipManifest -InstallId ([guid]::NewGuid().ToString()) -Version '0.0.1' -TargetRoot $project -Files @(
      New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' }
    )) -Destination (Join-Path $state 'manifest.json')
  Write-ToolkitTestFile -Path (Join-Path $state '.install.lock') -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/lock/v1'; toolkit = 'codex-dsh-team-toolkit'; processId = 999999; startedAtUtc = [DateTime]::UtcNow.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
      }))

  $cleared = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; ClearStaleLock = $true }
  Assert-Equal 0 $cleared.ExitCode ('the stale lock must be broken and the install must succeed: ' + (Get-ToolkitTestOutput $cleared))
  Assert-Match (Get-ToolkitTestOutput $cleared) 'stale toolkit lock' 'the stale lock removal must be reported'
  Assert-FileMissing (Join-Path $state '.install.lock') 'the lock must be released again'
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')

  # 3) without the explicit switch the same lock stays fail-closed
  $project2 = New-ToolkitTestProject -Root (Join-Path $base 'project2')
  $state2 = Join-Path $project2 '.codex-dsh-team-toolkit'
  New-Item -ItemType Directory -Path $state2 -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitOwnershipManifest -InstallId ([guid]::NewGuid().ToString()) -Version '0.0.1' -TargetRoot $project2 -Files @(
      New-ToolkitJsonObject -Properties @{ path = 'start_dsh_team.cmd' }
    )) -Destination (Join-Path $state2 'manifest.json')
  Write-ToolkitTestFile -Path (Join-Path $state2 '.install.lock') -Content (ConvertTo-ToolkitJson -Object (New-ToolkitJsonObject -Properties @{
        schema = 'codex-dsh-team-toolkit/lock/v1'; toolkit = 'codex-dsh-team-toolkit'; processId = 999999; startedAtUtc = [DateTime]::UtcNow.AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ')
      }))
  $closed = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project2; PackageRoot = $package.Root }
  Assert-Equal $script:ExitBlocked $closed.ExitCode 'without -ClearStaleLock the lock stays fail-closed'
  Assert-FileExists (Join-Path $state2 '.install.lock')
}

Test-Case -Name 'transaction: no temporary or displaced files are left behind on success' -Body {
  $base = New-ToolkitTestDirectory -Label 'leftovers'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  $payloadV2 = New-ToolkitTestPayload -Overrides @{ 'start_dsh_team.cmd' = "@echo off`r`necho v2`r`n" }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root }).ExitCode

  $leftovers = @(Get-ChildItem -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '*toolkit-tmp*' -or $_.Name -like '*toolkit-displaced*' -or $_.Name -like '.rollback-*' -or $_.Name -like '*.tmp-*' })
  Assert-Equal 0 $leftovers.Count ('no temporary artefacts may remain: ' + (($leftovers | ForEach-Object { $_.Name }) -join ', '))
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit\txn')
}
