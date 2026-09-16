#Requires -Version 5.1
<#
  02 - manifest-owned upgrade semantics, unknown conflicts, user-modified blocking.
#>

Test-Case -Name 'ownership: an unknown pre-existing file blocks the whole install' -Body {
  $base = New-ToolkitTestDirectory -Label 'unknown'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Write-ToolkitTestFile -Path (Join-Path $project 'start_dsh_team.cmd') -Content "@echo off`r`necho USER OWN FILE - DO NOT TOUCH`r`n"
  $before = Get-ToolkitTestTreeSnapshot -Root $project

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitConflict $result.ExitCode ('unknown same-name file must block: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'unknown file with the same name' 'the reason must be explicit'
  Assert-Match (Get-Content -LiteralPath (Join-Path $project 'start_dsh_team.cmd') -Raw) 'DO NOT TOUCH' 'the user file must be untouched'
  Assert-FileMissing (Join-Path $project '.agents')
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'a blocked install must not write anything'
}

Test-Case -Name 'ownership: a directory where a managed file belongs blocks the install' -Body {
  $base = New-ToolkitTestDirectory -Label 'typeconflict'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  New-Item -ItemType Directory -Path (Join-Path $project 'start_dsh_team.cmd') -Force | Out-Null

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitConflict $result.ExitCode
  Assert-DirectoryExists (Join-Path $project 'start_dsh_team.cmd')
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
}

Test-Case -Name 'ownership: upgrade replaces only unmodified managed files and records the new version' -Body {
  $base = New-ToolkitTestDirectory -Label 'upgrade'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $first = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }
  Assert-Equal 0 $first.ExitCode

  $payloadV2 = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/codex-dsh-team/SKILL.md' = "# Codex x DSH Team (fake payload)`nversion 2`n"
    '.agents/skills/mcp-to-dsh/public/app.js' = "console.log('fake monitor v2');`n"
  }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2

  $second = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root }
  Assert-Equal 0 $second.ExitCode ('upgrade should succeed: ' + (Get-ToolkitTestOutput $second))
  Assert-Match (Get-ToolkitTestOutput $second) 'replace' 'the plan must show replacements'

  Assert-Match (Get-Content -LiteralPath (Join-Path $project '.agents\skills\codex-dsh-team\SKILL.md') -Raw) 'version 2' 'the upgraded file must carry the new content'
  Assert-Match (Get-Content -LiteralPath (Join-Path $project '.agents\skills\mcp-to-dsh\public\app.js') -Raw) 'monitor v2' 'the second changed file must be upgraded'
  Assert-Match (Get-Content -LiteralPath (Join-Path $project 'start_dsh_team.cmd') -Raw) 'fake start' 'untouched files stay as they were'

  $ownership = Read-ToolkitOwnershipManifest -Path (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
  Assert-Equal '1.1.0' $ownership.version 'the ownership manifest must record the new version'
  foreach ($file in @($ownership.files)) {
    $installed = Join-Path $project ([string]$file.path -replace '/', '\')
    $pristine = Join-Path $project ('.codex-dsh-team-toolkit\' + ([string]$file.pristine -replace '/', '\'))
    Assert-True (Test-ToolkitFileContentEqual -PathA $installed -PathB $pristine) ('ownership must be byte-proven for ' + [string]$file.path)
  }
}

Test-Case -Name 'ownership: a user-modified managed file blocks the upgrade and is preserved' -Body {
  $base = New-ToolkitTestDirectory -Label 'usermod'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  $edited = Join-Path $project '.agents\skills\mcp-to-dsh\SKILL.md'
  Write-ToolkitTestFile -Path $edited -Content "# locally edited by the user - keep me`n"
  $ledgerPath = Join-Path $project '.codex-dsh-team-toolkit\manifest.json'
  $ledgerCopy = Join-Path $base 'ledger-before.json'
  Copy-Item -LiteralPath $ledgerPath -Destination $ledgerCopy -Force

  $payloadV2 = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/mcp-to-dsh/SKILL.md' = "# Codex x DSH Team (fake payload)`nversion 2`n"
  }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root }
  Assert-Equal $script:ExitConflict $result.ExitCode ('a user-modified managed file must block: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-Content -LiteralPath $edited -Raw) 'locally edited by the user' 'the edited file must be preserved'
  Assert-True (Test-ToolkitFileContentEqual -PathA $ledgerCopy -PathB $ledgerPath) 'the ownership manifest must be unchanged byte for byte'
}

Test-Case -Name 'ownership: a missing pristine baseline fails closed and preserves user data' -Body {
  $base = New-ToolkitTestDirectory -Label 'no-pristine'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  # destroy the only ownership evidence for one managed file
  $relative = '.agents/skills/mcp-to-dsh/SKILL.md'
  $target = Join-Path $project ($relative -replace '/', '\')
  $pristine = Join-Path $project ('.codex-dsh-team-toolkit\pristine\' + ($relative -replace '/', '\'))
  Assert-FileExists $pristine
  Remove-Item -LiteralPath $pristine -Force
  $targetCopy = Join-Path $base 'target-before.bin'
  Copy-Item -LiteralPath $target -Destination $targetCopy -Force

  # 1) an upgrade must be refused: ownership cannot be proven without the baseline
  $payloadV2 = New-ToolkitTestPayload -Overrides @{ $relative = "# upgrade attempt`n" }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2
  $upgrade = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root }
  Assert-Equal $script:ExitConflict $upgrade.ExitCode ('missing pristine evidence must fail closed: ' + (Get-ToolkitTestOutput $upgrade))
  Assert-Match (Get-ToolkitTestOutput $upgrade) 'pristine baseline is missing' 'the reason must name the missing evidence'
  Assert-True (Test-ToolkitFileContentEqual -PathA $target -PathB $targetCopy) 'the managed file must be preserved untouched'

  # 2) an uninstall must keep that file instead of deleting it
  $uninstall = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-Equal 0 $uninstall.ExitCode ('an uninstall must still complete: ' + (Get-ToolkitTestOutput $uninstall))
  Assert-Match (Get-ToolkitTestOutput $uninstall) 'pristine baseline missing' 'the kept file must be reported with its reason'
  Assert-True (Test-ToolkitFileContentEqual -PathA $target -PathB $targetCopy) 'user content must never be deleted without proof'
}

Test-Case -Name 'ownership: a managed file that left the release stays owned and untouched' -Body {
  $base = New-ToolkitTestDirectory -Label 'retained'
  $payloadV1 = New-ToolkitTestPayload -Overrides @{ '.agents/skills/extra/legacy.md' = "# legacy managed file`n" }
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0' -PayloadFiles $payloadV1
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode
  $legacy = Join-Path $project '.agents\skills\extra\legacy.md'
  Assert-FileExists $legacy

  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0'
  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV2.Root }
  Assert-Equal 0 $result.ExitCode
  Assert-Match (Get-ToolkitTestOutput $result) 'retained' 'the plan must report the retained file'
  Assert-FileExists $legacy 'the file is still owned and must not be deleted'

  $ownership = Read-ToolkitOwnershipManifest -Path (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
  $paths = @($ownership.files | ForEach-Object { [string]$_.path })
  Assert-True ($paths -contains '.agents/skills/extra/legacy.md') 'the retained file must stay in the ownership manifest'
}

Test-Case -Name 'ownership: the installed bytes become the pristine baseline (no package digest exists)' -Body {
  $base = New-ToolkitTestDirectory -Label 'tampered'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  # Change a package file after the release manifest was generated. There is no digest to
  # disagree with: the package IS the source of the bytes, and distribution integrity is
  # explicitly outside the installer guarantee. What must hold is that the pristine baseline
  # records exactly what was installed.
  Write-ToolkitTestFile -Path (Join-Path $package.Root 'payload\.agents\skills\mcp-to-dsh\SKILL.md') -Content "# changed in the package`n"

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal 0 $result.ExitCode ('the package source is authoritative: ' + (Get-ToolkitTestOutput $result))

  $installed = Join-Path $project '.agents\skills\mcp-to-dsh\SKILL.md'
  $pristine = Join-Path $project '.codex-dsh-team-toolkit\pristine\.agents\skills\mcp-to-dsh\SKILL.md'
  Assert-Match (Get-Content -LiteralPath $installed -Raw) 'changed in the package' 'the package bytes must be installed'
  Assert-True (Test-ToolkitFileContentEqual -PathA $installed -PathB $pristine) 'the pristine baseline must equal the installed bytes'
  Assert-True (Test-ToolkitPristineMatches -StateDirectory (Join-Path $project '.codex-dsh-team-toolkit') -RelativePath '.agents/skills/mcp-to-dsh/SKILL.md' -TargetPath $installed) 'ownership must be provable by direct comparison'
}

Test-Case -Name 'ownership: a release manifest with case-folded duplicate paths is rejected' -Body {
  $base = New-ToolkitTestDirectory -Label 'casedup'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $manifest = Get-Content -LiteralPath $package.ManifestPath -Raw | ConvertFrom-Json
  $file = $manifest.files[0]
  $duplicate = New-ToolkitJsonObject -Properties @{
    path   = ([string]$file.path).ToUpperInvariant()
    source = [string]$file.source
  }
  $manifest.files = @($manifest.files) + @($duplicate)
  $manifest.fileCount = @($manifest.files).Count
  Write-ToolkitJsonAtomic -Object $manifest -Destination $package.ManifestPath

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitManifest $result.ExitCode
  Assert-Match (Get-ToolkitTestOutput $result) 'duplicate' 'the reason must mention duplicates'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
}

Test-Case -Name 'ownership: a release manifest with a traversal path is rejected' -Body {
  $base = New-ToolkitTestDirectory -Label 'traversal'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $manifest = Get-Content -LiteralPath $package.ManifestPath -Raw | ConvertFrom-Json
  $file = $manifest.files[0]
  $file.path = '..\..\outside-the-project.md'
  Write-ToolkitJsonAtomic -Object $manifest -Destination $package.ManifestPath

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitBlocked $result.ExitCode
  Assert-Match (Get-ToolkitTestOutput $result) 'traversal' 'the reason must mention traversal'
}
