#Requires -Version 5.1
<#
  07 - the ownership manifest locates the project after it moves; no guessing, no takeover.
#>

Test-Case -Name 'relocation: an upgrade after the project moved re-anchors on the manifest itself' -Body {
  $base = New-ToolkitTestDirectory -Label 'move'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  $ledger = Join-Path $project '.codex-dsh-team-toolkit\manifest.json'
  $original = Read-ToolkitOwnershipManifest -Path $ledger
  # Self-locating state: the ledger describes the state layout, never a location digest.
  Assert-Equal '.codex-dsh-team-toolkit' ([string]$original.location.stateDir) 'the ledger must record the state directory layout'
  $ledgerText = Get-Content -LiteralPath $ledger -Raw
  Assert-NotMatch $ledgerText ([regex]::Escape($project)) 'the ledger must never persist the absolute project path'
  Assert-NotMatch $ledgerText '(?i)[A-Za-z]:\\\\' 'the ledger must not contain an absolute personal path'
  Assert-NotMatch $ledgerText '(?i)sha256|hashalgorithm|digest' 'the ledger must not contain any digest field'

  $movedProject = Join-Path $base 'moved-project'
  Move-Item -LiteralPath $project -Destination $movedProject

  $payloadV2 = New-ToolkitTestPayload -Overrides @{ 'start_dsh_team.cmd' = "@echo off`r`necho v2 start`r`n" }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $movedProject; PackageRoot = $packageV2.Root }
  Assert-Equal 0 $result.ExitCode ('the upgrade after a move should succeed: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'self-locating' 'the relocation must be reported as self-locating'
  Assert-Match (Get-Content -LiteralPath (Join-Path $movedProject 'start_dsh_team.cmd') -Raw) 'v2 start' 'the upgrade must apply'

  $updated = Read-ToolkitOwnershipManifest -Path (Join-Path $movedProject '.codex-dsh-team-toolkit\manifest.json')
  Assert-Equal '1.1.0' $updated.version 'the ledger must describe the new release'
  Assert-Equal ([string]$original.installId) ([string]$updated.installId) 'the install id must be stable across a move'
  foreach ($file in @($updated.files)) {
    $installed = Join-Path $movedProject ([string]$file.path -replace '/', '\')
    $pristine = Join-Path $movedProject ('.codex-dsh-team-toolkit\' + ([string]$file.pristine -replace '/', '\'))
    Assert-True (Test-ToolkitFileContentEqual -PathA $installed -PathB $pristine) ('ownership must be re-provable after the move for ' + [string]$file.path)
  }
}

Test-Case -Name 'relocation: an uninstall after a move removes exactly the managed files' -Body {
  $base = New-ToolkitTestDirectory -Label 'move-uninstall'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode
  Write-ToolkitTestFile -Path (Join-Path $project '.agents\skills\mine\SKILL.md') -Content "# user skill`n"

  $movedProject = Join-Path $base 'relocated'
  Move-Item -LiteralPath $project -Destination $movedProject

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $movedProject; Yes = $true }
  Assert-Equal 0 $result.ExitCode ('uninstall after a move should succeed: ' + (Get-ToolkitTestOutput $result))
  foreach ($entry in @($package.Entries)) {
    Assert-FileMissing (Join-Path $movedProject ([string]$entry.path -replace '/', '\'))
  }
  Assert-FileMissing (Join-Path $movedProject '.codex-dsh-team-toolkit')
  Assert-FileExists (Join-Path $movedProject '.agents\skills\mine\SKILL.md') 'the user skill survives the move and the uninstall'
  Assert-FileExists (Join-Path $movedProject 'src\app.js')
}

Test-Case -Name 'relocation: a modified file is still refused after the project moved' -Body {
  $base = New-ToolkitTestDirectory -Label 'move-modified'
  $packageV1 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.0.0') -Version '1.0.0'
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $packageV1.Root }).ExitCode

  $edited = Join-Path $project '.agents\skills\codex-dsh-team\SKILL.md'
  Write-ToolkitTestFile -Path $edited -Content "# hand edited before the move`n"
  $movedProject = Join-Path $base 'relocated'
  Move-Item -LiteralPath $project -Destination $movedProject

  $payloadV2 = New-ToolkitTestPayload -Overrides @{ '.agents/skills/codex-dsh-team/SKILL.md' = "# v2`n" }
  $packageV2 = New-ToolkitTestPackage -Root (Join-Path $base 'package-1.1.0') -Version '1.1.0' -PayloadFiles $payloadV2

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $movedProject; PackageRoot = $packageV2.Root }
  Assert-Equal $script:ExitConflict $result.ExitCode 'a user-modified managed file must still block after a move'
  Assert-Match (Get-Content -LiteralPath (Join-Path $movedProject '.agents\skills\codex-dsh-team\SKILL.md') -Raw) 'hand edited before the move'
}

Test-Case -Name 'relocation: the ledger is only trusted from its own location inside the target' -Body {
  $base = New-ToolkitTestDirectory -Label 'move-anchor'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  Assert-Equal 0 (Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }).ExitCode

  # a second, empty project must not inherit ownership from the first one
  $other = New-ToolkitTestProject -Root (Join-Path $base 'other-project')
  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $other; Yes = $true }
  Assert-Equal $script:ExitManifest $result.ExitCode 'another project has no ledger and must be refused'
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd') 'the real install is untouched'

  # copying the ledger into the other project still fails because the files are absent / unrelated
  New-Item -ItemType Directory -Path (Join-Path $other '.codex-dsh-team-toolkit') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $project '.codex-dsh-team-toolkit\manifest.json') -Destination (Join-Path $other '.codex-dsh-team-toolkit\manifest.json')
  $copied = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $other; Yes = $true }
  Assert-Equal 0 $copied.ExitCode ('a copied ledger finds no provable files and deletes nothing: ' + (Get-ToolkitTestOutput $copied))
  Assert-Match (Get-ToolkitTestOutput $copied) 'Deleted managed files: 0' 'nothing may be deleted in the other project'
  Assert-FileExists (Join-Path $project 'start_dsh_team.cmd')
}
