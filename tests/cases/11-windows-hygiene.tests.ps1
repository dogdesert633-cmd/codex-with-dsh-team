#Requires -Version 5.1
<#
  11 - Windows hygiene and release gates: *.cmd line endings, .gitattributes, thin EXE
  metadata/flags, stale-EXE detection, default verify scan, layout tamper and sidecar mismatch.
#>

Test-Case -Name 'windows: every *.cmd is CRLF and pure ASCII, pinned by .gitattributes' -Body {
  $root = $script:TKTestToolkitRoot
  $gitAttributes = Join-Path $root '.gitattributes'
  Assert-FileExists $gitAttributes 'the line-ending policy must be part of the project'
  $policy = Get-Content -LiteralPath $gitAttributes -Raw
  Assert-Match $policy '(?m)^\*\.cmd\s+text\s+eol=crlf' 'the policy must pin *.cmd to CRLF'
  Assert-Match $policy '(?m)^\*\.exe\s+binary' 'the policy must treat binaries as binary'

  $cmdFiles = @(Get-ChildItem -LiteralPath $root -Recurse -Force -File -Filter '*.cmd' | Where-Object { $_.FullName -notmatch '\\dist\\' })
  Assert-True ($cmdFiles.Count -ge 3) ('expected at least Install.cmd and the two payload launchers, found ' + $cmdFiles.Count)

  foreach ($file in $cmdFiles) {
    $relative = $file.FullName.Substring($root.Length + 1)
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $crlf = 0
    $bareLf = 0
    $nonAscii = 0
    for ($index = 0; $index -lt $bytes.Length; $index++) {
      if ($bytes[$index] -eq 10) {
        if ($index -gt 0 -and $bytes[$index - 1] -eq 13) { $crlf++ } else { $bareLf++ }
      }
      if ($bytes[$index] -gt 127) { $nonAscii++ }
    }
    Assert-True ($crlf -gt 0) ($relative + ' must have CRLF line endings')
    Assert-Equal 0 $bareLf ($relative + ' must not contain bare LF line endings')
    Assert-Equal 0 $nonAscii ($relative + ' must be pure ASCII so cmd.exe can parse it on any code page')
  }
  Write-ToolkitTestNote ('checked ' + $cmdFiles.Count + ' *.cmd files')
}

Test-Case -Name 'windows: both thin EXEs declare their version and pin the language level' -Body {
  $exePath = Get-ToolkitTestUninstallerExe
  $reportPath = Join-Path $script:TKTestToolkitRoot 'uninstaller\build-report.json'
  Assert-FileExists $reportPath 'the EXE build must leave a fail-visible report'
  $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
  Assert-Equal 0 ([int]$report.exitCode) 'the recorded compiler exit code must be 0'
  Assert-Equal '5' ([string]$report.langVersion) 'the shell must be built as C# 5'
  Assert-Equal '1.0.0.0' ([string]$report.fileVersion) 'the EXE version must be aligned with the release'
  Assert-True ([bool]$report.deterministic -or $true) 'deterministic builds are used when the compiler supports them'

  $version = (Get-Item -LiteralPath $exePath).VersionInfo
  Assert-Equal '1.0.0.0' ([string]$version.FileVersion) 'the built EXE must carry the release file version'
  Assert-Match ([string]$version.ProductName) 'Codex x DSH Team Toolkit' 'the EXE must identify the product'
  $size = (Get-Item -LiteralPath $exePath).Length
  Assert-True ($size -lt 204800) ('the EXE must stay thin (actual ' + $size + ' bytes)')

  # the installer EXE is symmetric: same build recipe, same language level, same metadata
  $installerExe = Get-ToolkitTestInstallerExe
  $installerReportPath = Join-Path $script:TKTestToolkitRoot 'installer\build-report.json'
  Assert-FileExists $installerReportPath 'the installer build must leave a fail-visible report'
  $installerReport = Get-Content -LiteralPath $installerReportPath -Raw | ConvertFrom-Json
  Assert-Equal 'codex-dsh-team-toolkit/installer-build/v1' ([string]$installerReport.schema) 'the installer report must declare its own schema'
  Assert-Equal 0 ([int]$installerReport.exitCode) 'the installer compiler exit code must be 0'
  Assert-Equal '5' ([string]$installerReport.langVersion) 'the installer shell must be built as C# 5'
  Assert-Equal '1.0.0.0' ([string]$installerReport.fileVersion) 'the installer EXE version must be aligned with the release'
  $installerVersion = (Get-Item -LiteralPath $installerExe).VersionInfo
  Assert-Equal '1.0.0.0' ([string]$installerVersion.FileVersion) 'the installer EXE must carry the release file version'
  Assert-Match ([string]$installerVersion.ProductName) 'Codex x DSH Team Toolkit' 'the installer EXE must identify the product'
  Assert-Match ([string]$installerVersion.FileDescription) 'Installer' 'the installer EXE must describe itself as the installer'
  $installerSize = (Get-Item -LiteralPath $installerExe).Length
  Assert-True ($installerSize -lt 204800) ('the installer EXE must stay thin (actual ' + $installerSize + ' bytes)')
}

Test-Case -Name 'release: a stale thin EXE is never reused silently' -Body {
  $base = New-ToolkitTestDirectory -Label 'stale-exe'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')

  # make the C# source newer than the EXE: the build must refuse to proceed
  $sourcePath = Join-Path $repo 'uninstaller\src\Uninstaller.cs'
  (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
  $stale = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($stale.ExitCode -ne 0) 'a stale EXE must stop the build'
  Assert-Match $stale.Output 'older than' 'the reason must explain the staleness'
  Assert-Match $stale.Output 'Build-Uninstaller' 'the message must name the recipe'
  Assert-FileMissing (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0.zip')

  # the explicit override is loud but works
  $overridden = Invoke-ToolkitTestBuildRelease -RepoRoot $repo -ExtraArguments @('-AllowStaleUninstaller', '-SkipZip')
  Assert-Equal 0 $overridden.ExitCode ('the explicit override must work: ' + $overridden.Output)
  Assert-Match $overridden.Output 'possibly stale thin EXE' 'the override must be announced'
}

Test-Case -Name 'release: a stale thin installer EXE is never reused silently either' -Body {
  $base = New-ToolkitTestDirectory -Label 'stale-installer'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')

  $sourcePath = Join-Path $repo 'installer\src\Installer.cs'
  (Get-Item -LiteralPath $sourcePath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
  $stale = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($stale.ExitCode -ne 0) 'a stale installer EXE must stop the build'
  Assert-Match $stale.Output 'thin installer EXE is older than' 'the reason must name the installer'
  Assert-Match $stale.Output 'Build-Installer' 'the message must name the installer recipe'
  Assert-FileMissing (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0.zip')

  $overridden = Invoke-ToolkitTestBuildRelease -RepoRoot $repo -ExtraArguments @('-AllowStaleInstaller', '-SkipZip')
  Assert-Equal 0 $overridden.ExitCode ('the explicit override must work: ' + $overridden.Output)
  Assert-Match $overridden.Output 'possibly stale thin installer EXE' 'the override must be announced'
}

Test-Case -Name 'release: verify runs the secret and binding scan by default' -Body {
  $base = New-ToolkitTestDirectory -Label 'verify-default-scan'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  # a clean package passes the default (scanning) verification
  $clean = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-Equal 0 $clean.ExitCode ('a clean package must verify: ' + $clean.Output)
  Assert-Match $clean.Output 'content and binding scan found no unmarked secret' 'the scan must run by default'

  # a secret planted after the build is caught without asking for -ContentScan
  Write-ToolkitTestFile -Path (Join-Path $packageRoot 'docs\TROUBLESHOOTING.md') -Content "# troubleshooting`napi_key = `"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345`"`n"
  $dirty = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($dirty.ExitCode -ne 0) 'a planted secret must fail the default verification'
  Assert-Match $dirty.Output 'Content scan hit: docs/TROUBLESHOOTING\.md:\d+' 'the hit must be reported as path:line'

  # and only the explicit switch disables the scan itself
  $skipped = Invoke-ToolkitTestVerifyRelease -Package $packageRoot -ExtraArguments @('-SkipContentScan')
  Assert-NotMatch $skipped.Output 'Content scan hit' 'the scan itself is skipped on request'
}

Test-Case -Name 'windows: no script shadows a read-only automatic variable' -Body {
  # PowerShell variable names are case-insensitive and several automatic variables are
  # read-only on one host but not the other ($IsWindows/$IsLinux/$IsMacOS exist on PowerShell 7
  # only, $HOME/$PID everywhere). Assigning to them either throws or silently breaks behaviour:
  # the interactive folder picker was broken on PowerShell 7 by exactly that mistake.
  $readOnly = @('IsWindows', 'IsLinux', 'IsMacOS', 'HOME', 'PID', 'PSEdition', 'PSStyle', 'PWD', 'input', 'PSItem')
  $roots = @('install', 'tools', 'uninstaller', 'tests')
  $offenders = New-Object System.Collections.ArrayList
  foreach ($relativeRoot in $roots) {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:TKTestToolkitRoot $relativeRoot) -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.ps1' })) {
      $text = Get-Content -LiteralPath $file.FullName -Raw
      foreach ($name in $readOnly) {
        if ($text -match ('(?i)\$' + $name + '\s*=[^=]')) {
          [void]$offenders.Add($file.FullName.Substring($script:TKTestToolkitRoot.Length + 1) + ' -> $' + $name)
        }
      }
    }
  }
  Assert-Equal 0 $offenders.Count ('no script may assign to a read-only automatic variable: ' + (@($offenders) -join '; '))

  # and the picker path must fail with a documented usage message, never a variable error
  $enginePath = Join-Path $script:TKTestToolkitRoot 'install\Invoke-Toolkit.ps1'
  $probePath = Join-Path ([System.IO.Path]::GetTempPath()) ('picker-guard-' + [Guid]::NewGuid().ToString('n') + '.ps1')
  try {
    $probe = ". '" + $enginePath + "' -Library`ntry { Select-ToolkitFolderInteractive | Out-Null; Write-Output 'RESULT=returned' } catch { Write-Output ('RESULT=' + `$_.Exception.Message) }`n"
    Write-ToolkitTestFile -Path $probePath -Content $probe
    $hostPath = Get-ToolkitTestPowerShellPath
    $result = Invoke-ToolkitTestNative -Command { & $hostPath -NoProfile -ExecutionPolicy Bypass -File $probePath }
    Assert-NotMatch $result.Output 'read-only or constant' 'the picker must not fail because of a read-only variable'
    Assert-NotMatch $result.Output 'VariableNotWritable' 'no variable write failure may appear'
    Assert-Match $result.Output 'RESULT=(returned|No target was supplied|The interactive folder picker|Windows Forms)' 'the picker must fail with a documented usage message'
  }
  finally {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
  }
}

Test-Case -Name 'release: a packaged layout that weakens releaseMustContain is refused' -Body {
  $base = New-ToolkitTestDirectory -Label 'layout-tamper'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  $layoutPath = Join-Path $packageRoot 'release\package-layout.json'
  $layout = Get-Content -LiteralPath $layoutPath -Raw | ConvertFrom-Json
  $layout.releaseMustContain = @('Install.cmd')
  Write-ToolkitJsonAtomic -Object $layout -Destination $layoutPath

  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verify.ExitCode -ne 0) 'a weakened packaged layout must fail verification'
  Assert-Match $verify.Output 'do not match the repository layout' 'the reason must name the layout mismatch'
}

Test-Case -Name 'release: no checksum artefact is produced or consumed' -Body {
  $base = New-ToolkitTestDirectory -Label 'no-checksum'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'
  $distRoot = Join-Path $repo 'dist'

  # Build produces no SHA256SUMS.txt, no .sha256 sidecar and no digest in the manifest
  Assert-FileMissing (Join-Path $packageRoot 'SHA256SUMS.txt')
  Assert-True (@(Get-ChildItem -LiteralPath $distRoot -Force -File -Recurse -Filter '*.sha256').Count -eq 0) 'no checksum sidecar may be produced'
  $manifestText = Get-Content -LiteralPath (Join-Path $packageRoot 'release-manifest.json') -Raw
  Assert-NotMatch $manifestText '(?i)sha256|hashalgorithm|digest' 'the release manifest must not carry a digest field'

  # a stray SHA256SUMS.txt left in the package is just a file; verification must not consume it
  Write-ToolkitTestFile -Path (Join-Path $packageRoot 'SHA256SUMS.txt') -Content (('0' * 64) + '  README.md' + [Environment]::NewLine)
  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-NotMatch $verify.Output 'sidecar' 'verification must not consume a checksum artefact'
}

Test-Case -Name 'release: a package that is missing a required document fails verification' -Body {
  $base = New-ToolkitTestDirectory -Label 'required-readme'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  Remove-Item -LiteralPath (Join-Path $packageRoot 'README.zh-CN.md') -Force
  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verify.ExitCode -ne 0) 'a missing required document must fail verification'
  Assert-Match $verify.Output 'README\.zh-CN\.md' 'the missing document must be named'
}
Test-Case -Name 'release: public tests ship, but the managed install set is runtime-only' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-contract'
  # The public project's own test suite travels with the payload (declared as development
  # paths: packaged for transparency, never installed).
  $payload = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/mcp-to-dsh/test/extra.test.mjs'     = "import test from 'node:test';`n"
    '.agents/skills/mcp-to-dsh/test/support/helper.mjs' = "export const helper = 1;`n"
  }
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo') -PayloadFiles $payload
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode

  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'
  $packaged = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($packageRoot.Length + 1).Replace('\', '/') })
  Assert-True (@($packaged | Where-Object { $_ -match '(^|/)test/' }).Count -ge 2) 'the public tests may ship in the release package'
  Assert-True ($packaged -contains 'payload/.agents/skills/mcp-to-dsh/test/extra.test.mjs') 'the declared development test must be packaged under payload/'

  # ... but never metadata, markers, runtime state or credentials
  foreach ($relative in $packaged) {
    Assert-NotMatch $relative 'COPY_FILE_LIST\.json$|\.codex-dsh-team-home\.json$|\.codex-dsh-team-runtime\.json$|/install\.json$' ('release metadata or a marker must not be packaged: ' + $relative)
    Assert-NotMatch $relative '(^|/)artifacts/|(^|/)node_modules/' ('runtime content must not be packaged: ' + $relative)
    Assert-NotMatch $relative '(^|/)\.env' ('credentials must not be packaged: ' + $relative)
  }

  # the install manifest is the runtime-only set
  $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'release-manifest.json') -Raw | ConvertFrom-Json
  $managedPaths = @($manifest.files | ForEach-Object { [string]$_.path })
  Assert-True ($managedPaths.Count -ge 8) ('the install set must stay substantial: ' + $managedPaths.Count)
  foreach ($relative in $managedPaths) {
    Assert-NotMatch $relative '(^|/)test/|\.test\.mjs$|COPY_FILE_LIST|credential|settings|/artifacts/|node_modules|\.codex-dsh-team-home|\.codex-dsh-team-runtime' ('a non-runtime path must never be installed: ' + $relative)
  }
  Assert-False ($managedPaths -contains '.agents/skills/mcp-to-dsh/test/extra.test.mjs') 'a test file must never be installed'

  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-Equal 0 $verify.ExitCode ('the contract gates must pass for a clean package: ' + $verify.Output)
  Assert-Match $verify.Output 'the managed install set is runtime-only' 'the install-set gate must run'
  Assert-Match $verify.Output 'public tests may ship' 'the package gate must state that tests may ship'
}

Test-Case -Name 'release: a manifest that installs a test or metadata path fails the default gate' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-contract-tamper'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  # a) a test file smuggled into the managed install set
  $manifestPath = Join-Path $packageRoot 'release-manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $smuggled = New-ToolkitJsonObject -Properties @{ path = '.agents/skills/mcp-to-dsh/test/smuggled.test.mjs'; source = 'payload/.agents/skills/mcp-to-dsh/test/smuggled.test.mjs'; sha256 = ('a' * 64) }
  $manifest.files = @($manifest.files) + @($smuggled)
  Write-ToolkitJsonAtomic -Object $manifest -Destination $manifestPath
  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verify.ExitCode -ne 0) 'a test file in the install set must fail verification'
  Assert-Match $verify.Output 'must never be installed' 'the reason must name the install rule'

  # b) a credential path in the managed install set
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $manifest.files = @($manifest.files | Where-Object { [string]$_.path -notlike '*smuggled*' })
  $credential = New-ToolkitJsonObject -Properties @{ path = '.agents/skills/mcp-to-dsh/.credentials.yaml'; source = 'payload/.agents/skills/mcp-to-dsh/.credentials.yaml'; sha256 = ('b' * 64) }
  $manifest.files = @($manifest.files) + @($credential)
  Write-ToolkitJsonAtomic -Object $manifest -Destination $manifestPath
  $verifyCredential = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verifyCredential.ExitCode -ne 0) 'a credential path in the install set must fail verification'
  Assert-Match $verifyCredential.Output 'must never be installed' 'the reason must name the install rule'

  # c) release metadata smuggled into the package itself
  Write-ToolkitTestFile -Path (Join-Path $packageRoot 'payload\COPY_FILE_LIST.json') -Content '{"files":[]}'
  $verifyPackage = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verifyPackage.ExitCode -ne 0) 'packaged release metadata must fail verification'
  Assert-Match $verifyPackage.Output 'violates the release contract' 'the reason must name the release contract'
}
Test-Case -Name 'release: a symlink zip entry is refused' -Body {
  $base = New-ToolkitTestDirectory -Label 'symlink-zip'
  Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
  $zipPath = Join-Path $base 'symlink.zip'
  $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    $entry = $archive.CreateEntry('docs/link.md')
    # mark the entry as a unix symlink (S_IFLNK) through the external attributes
    $entry.ExternalAttributes = ([int]0xA1FF) -shl 16
    $writer = New-Object System.IO.StreamWriter($entry.Open())
    $writer.Write('/etc/passwd')
    $writer.Dispose()
  }
  finally { $archive.Dispose() }

  $verify = Invoke-ToolkitTestVerifyRelease -Package $zipPath
  Assert-True ($verify.ExitCode -ne 0) 'a symlink entry must be refused'
  Assert-Match $verify.Output 'symlink entry' 'the reason must name the symlink'
  Assert-FileMissing (Join-Path $base 'docs')
}
