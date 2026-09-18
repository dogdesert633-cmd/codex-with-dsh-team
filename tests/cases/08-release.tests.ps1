#Requires -Version 5.1
<#
  08 - release tooling: offline build, verification, scanning, no-checksum artefact set, inventory.

  The tests copy the repository infrastructure into a temporary repository so nothing in the
  working tree is touched, and they never use the network. Release integrity of the transport
  belongs to the distribution channel: the toolkit produces and consumes no checksum artefact.
#>

Test-Case -Name 'release: a full offline build produces a verifiable package' -Body {
  $base = New-ToolkitTestDirectory -Label 'release'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')

  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-Equal 0 $build.ExitCode ('the release build should succeed: ' + $build.Output)

  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'
  Assert-DirectoryExists $packageRoot
  Assert-FileExists (Join-Path $packageRoot 'release-manifest.json')
  Assert-FileExists (Join-Path $packageRoot 'Install.cmd')
  Assert-FileExists (Join-Path $packageRoot 'install\Invoke-Toolkit.ps1')
  Assert-FileExists (Join-Path $packageRoot 'uninstaller\CodexDshTeamToolkit.Uninstall.exe')
  Assert-FileExists (Join-Path $packageRoot 'uninstaller\src\Uninstaller.cs')
  Assert-FileExists (Join-Path $packageRoot 'uninstaller\Build-Uninstaller.ps1')
  # the installer EXE ships at the package root, next to Install.cmd, with its source and recipe
  Assert-FileExists (Join-Path $packageRoot 'CodexDshTeamToolkit.Install.exe')
  Assert-FileExists (Join-Path $packageRoot 'installer\src\Installer.cs')
  Assert-FileExists (Join-Path $packageRoot 'installer\Build-Installer.ps1')
  Assert-FileExists (Join-Path $packageRoot 'LICENSE')
  Assert-FileExists (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0.zip')

  # The no-checksum contract: the build must not produce any checksum artefact at all.
  Assert-FileMissing (Join-Path $packageRoot 'SHA256SUMS.txt') 'the build must not create a checksum list'
  Assert-FileMissing (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0.zip.sha256') 'the build must not create a zip sidecar'
  $packagedChecksumArtifacts = @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Force -File |
    Where-Object { $_.Name -eq 'SHA256SUMS.txt' -or $_.Name -like '*.sha256' })
  Assert-Equal 0 $packagedChecksumArtifacts.Count 'no checksum artefact may be packaged'

  # the inventory file itself is never packaged or installed
  Assert-FileMissing (Join-Path $packageRoot 'payload\COPY_FILE_LIST.json')
  $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'release-manifest.json') -Raw | ConvertFrom-Json
  foreach ($file in @($manifest.files)) {
    Assert-Match ([string]$file.path) '^[^/\\]' 'manifest paths must be relative'
    Assert-Match ([string]$file.source) '^[^/\\]' 'manifest sources must be relative'
    Assert-NotMatch ([string]$file.path) '\.\.' 'manifest paths must not traverse'
    Assert-NotMatch ([string]$file.source) 'COPY_FILE_LIST' 'the inventory must never be a managed source'
    # The manifest is a location list: an entry carries no digest field.
    Assert-True (-not ($file.PSObject.Properties.Name -contains 'sha256')) 'a managed entry must not carry a digest field'
    Assert-FileExists (Join-Path $packageRoot ([string]$file.source -replace '/', '\')) ('packaged source ' + [string]$file.source)
  }
  # the installer EXE is a package-root launcher: it is packaged but never a managed entry
  foreach ($file in @($manifest.files)) {
    Assert-NotMatch ([string]$file.path) 'CodexDshTeamToolkit\.Install\.exe' 'the installer EXE must never be installed'
    Assert-NotMatch ([string]$file.source) '^installer/' 'the installer source must never be a managed source'
  }

  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-Equal 0 $verify.ExitCode ('verify should pass: ' + $verify.Output)
  Assert-Match $verify.Output 'VERIFY PASS' 'the verifier must report success'
  Assert-Match $verify.Output 'releaseMustContain satisfied' 'the layout requirement must be checked'
  Assert-Match $verify.Output 'no checksum artefact in the package' 'the verifier must confirm the no-checksum contract'
  Assert-Match $verify.Output 'managed install set is runtime-only' 'the managed set must be proven runtime-only'

  $verifyZip = Invoke-ToolkitTestVerifyRelease -Package (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0.zip')
  Assert-Equal 0 $verifyZip.ExitCode ('zip verify should pass: ' + $verifyZip.Output)
  Assert-Match $verifyZip.Output 'expanded safely' 'zip entries must be validated before expansion'
  Assert-Match $verifyZip.Output 'no checksum artefact in the package' 'a zip package must also carry no checksum artefact'

  # and the built package is directly installable
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $install = Invoke-ToolkitTestCli -Arguments @('-Action', 'Install', '-Target', $project, '-PackageRoot', $packageRoot, '-Yes') -EnginePath (Join-Path $packageRoot 'install\Invoke-Toolkit.ps1')
  Assert-Equal 0 $install.ExitCode ('the built package must install: ' + $install.Output)
  Assert-FileExists (Join-Path $project 'CodexDshTeamToolkit.Uninstall.exe')
  Assert-FileMissing (Join-Path $project 'COPY_FILE_LIST.json') 'the inventory must never be installed'
}

Test-Case -Name 'release: the managed payload set comes from the frozen inventory' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-inventory'
  $payload = New-ToolkitTestPayload
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo') -PayloadFiles $payload
  # an extra payload file that the inventory does not declare (for example a build leftover)
  Write-ToolkitTestFile -Path (Join-Path $repo 'payload\.agents\skills\mcp-to-dsh\scratch.tmp.js') -Content "console.log('scratch');`n"

  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-Equal 0 $build.ExitCode ('the build should still succeed: ' + $build.Output)
  Assert-Match $build.Output 'EXCLUDED from this release' 'undeclared payload must be reported'
  Assert-Match $build.Output 'scratch.tmp.js' 'the excluded file must be named'

  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'
  Assert-FileMissing (Join-Path $packageRoot 'payload\.agents\skills\mcp-to-dsh\scratch.tmp.js')
  $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'release-manifest.json') -Raw | ConvertFrom-Json
  $paths = @($manifest.files | ForEach-Object { [string]$_.path })
  Assert-True ($paths -contains '.agents/skills/codex-dsh-team/SKILL.md') 'declared payload stays managed'
  Assert-False ($paths -contains '.agents/skills/mcp-to-dsh/scratch.tmp.js') 'undeclared payload is not managed'

  # an explicit override includes them, loudly
  $repoB = New-ToolkitTestRepo -Root (Join-Path $base 'repo-b') -PayloadFiles $payload
  Write-ToolkitTestFile -Path (Join-Path $repoB 'payload\.agents\skills\mcp-to-dsh\scratch.tmp.js') -Content "console.log('scratch');`n"
  $override = Invoke-ToolkitTestBuildRelease -RepoRoot $repoB -ExtraArguments @('-IncludeUndeclaredPayload')
  Assert-Equal 0 $override.ExitCode
  Assert-Match $override.Output 'Including 1 undeclared payload file' 'the override must be visible'
}

Test-Case -Name 'release: a missing payload inventory stops the build instead of guessing' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-noinventory'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo') -WithoutInventory

  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($build.ExitCode -ne 0) 'the build must refuse to guess the payload set'
  Assert-Match $build.Output 'Payload inventory is missing|Missing required package file: release/payload-inventory\.json' 'the reason must name the missing inventory'
  Assert-Match $build.Output 'Release build failed|Build stopped' 'the failure must be reported cleanly'

  # a payload-side COPY_FILE_LIST.json (as the payload work package used to ship) is neither an
  # inventory nor payload: it is reported as undeclared and never packaged or installed
  $stray = New-ToolkitTestRepo -Root (Join-Path $base 'stray-repo')
  Write-ToolkitTestFile -Path (Join-Path $stray 'payload\COPY_FILE_LIST.json') -Content "{ `"files`": [] }`n"
  $strayBuild = Invoke-ToolkitTestBuildRelease -RepoRoot $stray
  Assert-Equal 0 $strayBuild.ExitCode ('a stray inventory file must not break the build: ' + $strayBuild.Output)
  Assert-Match $strayBuild.Output 'EXCLUDED from this release' 'the stray file must be reported'
  Assert-Match $strayBuild.Output 'COPY_FILE_LIST\.json' 'the stray file must be named'
  Assert-FileMissing (Join-Path $stray 'dist\codex-dsh-team-toolkit-v1.0.0\payload\COPY_FILE_LIST.json') 'the inventory file is never packaged'
  $strayManifest = Get-Content -LiteralPath (Join-Path $stray 'dist\codex-dsh-team-toolkit-v1.0.0\release-manifest.json') -Raw | ConvertFrom-Json
  foreach ($file in @($strayManifest.files)) {
    Assert-NotMatch ([string]$file.source) 'COPY_FILE_LIST' 'the inventory is never a managed source'
    Assert-NotMatch ([string]$file.path) 'COPY_FILE_LIST' 'the inventory is never installed'
  }
}

Test-Case -Name 'release: byte tampering is out of scope, a missing managed file fails verification' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-tamper'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  # Honest no-hash boundary: the release manifest is a location list, so rewriting a packaged
  # file's bytes is NOT detected by the toolkit. Transport integrity is the distribution
  # channel's responsibility, and this assertion documents that instead of pretending otherwise.
  $managed = Join-Path $packageRoot 'payload\.agents\skills\codex-dsh-team\SKILL.md'
  Write-ToolkitTestFile -Path $managed -Content "# rewritten after the build`n"
  $verifyRewritten = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-Equal 0 $verifyRewritten.ExitCode ('a location-only manifest cannot detect byte rewriting: ' + $verifyRewritten.Output)

  # What the toolkit DOES fail closed on is a missing managed file.
  Remove-Item -LiteralPath $managed -Force
  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verify.ExitCode -ne 0) 'a package missing a managed file must fail verification'
  Assert-Match $verify.Output 'VERIFY FAIL' 'the verifier must report failure'
  Assert-Match $verify.Output 'Managed source is missing from the package' 'the reason must be specific'
}

Test-Case -Name 'release: a smuggled managed path or checksum artefact fails closed' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-smuggle'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  # A managed entry that points at a path which must never be installed.
  $manifestPath = Join-Path $packageRoot 'release-manifest.json'
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $smuggled = 'payload/.agents/skills/mcp-to-dsh/test/smuggled.test.mjs'
  Write-ToolkitTestFile -Path (Join-Path $packageRoot ($smuggled -replace '/', '\')) -Content "# smuggled test file`n"
  $manifest.files = @($manifest.files) + [pscustomobject]@{ path = 'agents-smuggled.test.mjs'; source = $smuggled }
  $manifest.fileCount = @($manifest.files).Count
  [IO.File]::WriteAllText($manifestPath, (($manifest | ConvertTo-Json -Depth 6) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))

  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verify.ExitCode -ne 0) 'a smuggled managed path must fail verification'
  Assert-Match $verify.Output 'must never be installed|outside the runtime layout' 'the smuggled path must be named'

  # And a checksum artefact smuggled into an otherwise valid package is refused outright.
  Remove-Item -LiteralPath (Join-Path $packageRoot ($smuggled -replace '/', '\')) -Force
  [IO.File]::WriteAllText($manifestPath, ((Get-Content -LiteralPath $manifestPath -Raw).Replace($smuggled, 'payload/.agents/skills/mcp-to-dsh/SKILL.md')), (New-Object System.Text.UTF8Encoding($false)))
  Write-ToolkitTestFile -Path (Join-Path $packageRoot 'SHA256SUMS.txt') -Content ((('0' * 64) + '  release-manifest.json') + [Environment]::NewLine)
  $verifyB = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verifyB.ExitCode -ne 0) 'a smuggled checksum artefact must fail verification'
  Assert-Match $verifyB.Output 'checksum artefact must never be packaged' 'the checksum artefact must be named'
}

Test-Case -Name 'release: a package without a required layout file fails verification' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-required'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  Remove-Item -LiteralPath (Join-Path $packageRoot 'uninstaller\src\Uninstaller.cs') -Force

  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verify.ExitCode -ne 0) 'a missing required file must fail verification'
  Assert-Match $verify.Output 'required by the layout' 'the reason must name the layout requirement'
}

Test-Case -Name 'release: a hostile zip is refused before anything is expanded' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-zip'
  $hostileCases = @(
    @{ Name = 'zip slip';        Entry = '../escaped.txt' },
    @{ Name = 'absolute path';   Entry = 'C:/Windows/evil.txt' },
    @{ Name = 'ads stream';      Entry = 'docs/notes.md:evil' },
    @{ Name = 'reserved device'; Entry = 'docs/NUL.txt' }
  )
  foreach ($case in $hostileCases) {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zipPath = Join-Path $base (($case.Name -replace '[^A-Za-z]', '') + '.zip')
    $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
      $entry = $archive.CreateEntry([string]$case.Entry)
      $writer = New-Object System.IO.StreamWriter($entry.Open())
      $writer.Write('hostile')
      $writer.Dispose()
    }
    finally { $archive.Dispose() }

    $verify = Invoke-ToolkitTestVerifyRelease -Package $zipPath
    Assert-True ($verify.ExitCode -ne 0) ($case.Name + ' must be refused')
    Assert-Match $verify.Output 'VERIFY FAIL|Release|Unsafe managed path|alternate data stream|Archive entry' ($case.Name + ' must be reported')
    Assert-FileMissing (Join-Path $base 'escaped.txt')
    Assert-FileMissing (Join-Path $base 'Windows')
  }
}

Test-Case -Name 'release: a zip with a case-folded duplicate entry is refused' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-zipdup'
  Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
  $zipPath = Join-Path $base 'dup.zip'
  $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($name in @('docs/readme.md', 'docs/README.md')) {
      $entry = $archive.CreateEntry($name)
      $writer = New-Object System.IO.StreamWriter($entry.Open())
      $writer.Write('x')
      $writer.Dispose()
    }
  }
  finally { $archive.Dispose() }

  $verify = Invoke-ToolkitTestVerifyRelease -Package $zipPath
  Assert-True ($verify.ExitCode -ne 0) 'a case-folded duplicate must be refused'
  Assert-Match $verify.Output 'case-folded duplicate' 'the reason must be explicit'
}

Test-Case -Name 'release: a checksum artefact added to a package is refused' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-checksumhostile'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'

  # There is no checksum file to tamper with any more; the contract is that one may not exist.
  # A hostile entry inside a smuggled checksum file is therefore irrelevant: the file itself is
  # refused, which is the intended fail-closed behaviour (nothing parses checksum entries).
  Write-ToolkitTestFile -Path (Join-Path $packageRoot 'SHA256SUMS.txt') -Content ((('a' * 64) + '  ../outside.txt') + [Environment]::NewLine)

  $verify = Invoke-ToolkitTestVerifyRelease -Package $packageRoot
  Assert-True ($verify.ExitCode -ne 0) 'a smuggled checksum file must be refused'
  Assert-Match $verify.Output 'checksum artefact must never be packaged' 'the reason must name the checksum artefact'
}

Test-Case -Name 'release: the whole package is scanned, not just the payload' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-scan'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  # a secret in a packaged doc (outside payload) must be caught as well
  Write-ToolkitTestFile -Path (Join-Path $repo 'docs\INSTALLATION.md') -Content "# install`napi_key = `"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345`"`n"

  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($build.ExitCode -ne 0) 'a secret outside the payload must stop the build'
  Assert-Match $build.Output 'Content scan blocked a possible secret: docs/INSTALLATION\.md:\d+' 'the hit must be reported as path:line only'
  Assert-NotMatch $build.Output 'ABCDEFGHIJKLMNOPQRSTUVWXYZ012345' 'the value itself must never be echoed'
}

Test-Case -Name 'release: a fixed DSH home or version binding stops the build' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-binding'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo') -PayloadFiles (New-ToolkitTestPayload -Overrides @{
      '.agents/skills/mcp-to-dsh/src/config.mjs' = "export const dshHome = 'C:\\Users\\someone\\DSH\\home-acp-0.1.5';`n"
    })

  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($build.ExitCode -ne 0) 'a fixed DSH home/version binding must stop the build'
  Assert-Match $build.Output 'Binding scan blocked a fixed DSH home/version: .*config\.mjs:\d+' 'the hit must be reported as path:line'
  Assert-NotMatch $build.Output 'home-acp-0\.1\.5' 'the matched binding value must not be echoed'

  # provider/model pinning is reported for review, not silently accepted or failed
  $repoB = New-ToolkitTestRepo -Root (Join-Path $base 'repo-b') -PayloadFiles (New-ToolkitTestPayload -Overrides @{
      '.agents/skills/mcp-to-dsh/profiles/default.yaml' = "provider: deepseek`nmodel: deepseek-chat`n"
    })
  $buildB = Invoke-ToolkitTestBuildRelease -RepoRoot $repoB
  Assert-Equal 0 $buildB.ExitCode ('provider/model pinning is a review warning: ' + $buildB.Output)
  Assert-Match $buildB.Output 'Binding scan review' 'the warning must be visible'
}

Test-Case -Name 'release: an unmarked secret in payload content stops the build, a marked fake does not' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-secret'

  $repoA = New-ToolkitTestRepo -Root (Join-Path $base 'repo-a') -PayloadFiles (New-ToolkitTestPayload -Overrides @{
      '.agents/skills/codex-dsh-team/SKILL.md' = "# payload`napi_key = `"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345`"`n"
    })
  $blocked = Invoke-ToolkitTestBuildRelease -RepoRoot $repoA
  Assert-True ($blocked.ExitCode -ne 0) 'an unmarked secret pattern must stop the build'
  Assert-Match $blocked.Output 'Content scan blocked' 'the reason must name the content scan'

  # a single-line value that self-identifies as fake is only a warning
  $repoB = New-ToolkitTestRepo -Root (Join-Path $base 'repo-b') -PayloadFiles (New-ToolkitTestPayload -Overrides @{
      '.agents/skills/codex-dsh-team/SKILL.md' = "# payload`napi_key = `"fake-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345`"`n"
    })
  $allowed = Invoke-ToolkitTestBuildRelease -RepoRoot $repoB
  Assert-Equal 0 $allowed.ExitCode ('a self-identified fake value must only warn: ' + $allowed.Output)
  Assert-Match $allowed.Output 'Content scan warning' 'the warning must still be reported'

  # the deliberate override is available and loud
  $repoC = New-ToolkitTestRepo -Root (Join-Path $base 'repo-c') -PayloadFiles (New-ToolkitTestPayload -Overrides @{
      '.agents/skills/codex-dsh-team/SKILL.md' = "# payload`napi_key = `"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345`"`n"
    })
  $skipped = Invoke-ToolkitTestBuildRelease -RepoRoot $repoC -ExtraArguments @('-SkipContentScan')
  Assert-Equal 0 $skipped.ExitCode ('the explicit override must work: ' + $skipped.Output)
  Assert-Match $skipped.Output 'skipped by explicit request' 'the override must be loud'
}

Test-Case -Name 'release: a multi-line key fixture is no longer exempted by a nearby marker' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-pem'
  # A runtime reference file (test/** is never packaged at all): the matched value is the PEM
  # header, which itself carries no fake/example marker, so the build must block.
  $fixture = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/mcp-to-dsh/references/redaction-fixture.md' = @"
Example key material used by the redaction documentation:
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAfakefakefakefakefakefakefakefake
-----END RSA PRIVATE KEY-----
"@
  }
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo') -PayloadFiles $fixture

  # the matched value (the PEM header) carries no marker, so a marker on another line is not
  # enough: the build blocks and reports path:line for a human decision
  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($build.ExitCode -ne 0) 'a multi-line key fixture must block by default'
  Assert-Match $build.Output 'Content scan blocked' 'the reason must name the content scan'
  Assert-Match $build.Output 'redaction-fixture\.md:\d+' 'the hit must be reported as path:line'

  # a reviewer allowlist resolves it explicitly and loudly
  $allowlisted = Invoke-ToolkitTestBuildRelease -RepoRoot $repo -ExtraArguments @('-ContentScanAllowlist', '.agents/skills/mcp-to-dsh/references/redaction-fixture.md')
  Assert-Equal 0 $allowlisted.ExitCode ('the reviewed allowlist entry must work: ' + $allowlisted.Output)
  Assert-Match $allowlisted.Output 'allowlisted' 'the allowlist use must be visible in the build output'
}

Test-Case -Name 'release: a forbidden path in the payload stops the build' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-forbidden'
  $payload = New-ToolkitTestPayload -Overrides @{ '.env' = "SECRET=1`n"; '.agents/skills/x/credentials.json' = "{`"a`":1}`n" }
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo') -PayloadFiles $payload

  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($build.ExitCode -ne 0) 'the build must refuse forbidden payload paths'
  Assert-Match $build.Output 'deny|forbidden path' 'the reason must name the path policy that stopped it'
  Assert-Match $build.Output 'Release build failed' 'the failure must be reported cleanly'
  Assert-FileMissing (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0.zip')
}

Test-Case -Name 'release: a failed build keeps the previous artifacts and removes its staging' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-staging'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo).ExitCode
  $packageRoot = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0'
  $zipPath = Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0.zip'
  # Direct content comparison (no digest): the previous package file and zip bytes must be intact.
  $previousManifestPath = Join-Path $packageRoot 'release-manifest.json'
  $manifestBefore = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($previousManifestPath))
  $zipBefore = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($zipPath))

  # make the next build fail after staging has started
  Write-ToolkitTestFile -Path (Join-Path $repo 'docs\CONFIGURATION.md') -Content "# config`npassword = `"ABCDEFGHIJKLMNOPQRSTUVWXYZ012345`"`n"
  $failed = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($failed.ExitCode -ne 0) 'the build must fail on the injected secret'

  $manifestAfter = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($previousManifestPath))
  $zipAfter = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($zipPath))
  Assert-Equal $manifestBefore $manifestAfter 'the previous package must be byte-for-byte untouched'
  Assert-Equal $zipBefore $zipAfter 'the previous zip must be byte-for-byte untouched'
  $staging = @(Get-ChildItem -LiteralPath (Join-Path $repo 'dist') -Force -Directory | Where-Object { $_.Name -like '.codex-dsh-team-toolkit-staging-*' })
  Assert-Equal 0 $staging.Count 'no staging directory may be left behind'
  $previous = @(Get-ChildItem -LiteralPath (Join-Path $repo 'dist') -Force -Directory | Where-Object { $_.Name -like '.*.previous-*' })
  Assert-Equal 0 $previous.Count 'no displaced previous directory may be left behind'
}

Test-Case -Name 'release: a missing payload fails visibly unless it is explicitly allowed' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-nopayload'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo') -WithoutPayload

  $refused = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($refused.ExitCode -ne 0) 'a missing payload must fail the build by default'
  Assert-Match $refused.Output 'Payload is empty or missing' 'the reason must be explicit'
  Assert-Match $refused.Output 'AllowMissingPayload' 'the message must name the override'

  $allowed = Invoke-ToolkitTestBuildRelease -RepoRoot $repo -ExtraArguments @('-AllowMissingPayload', '-SkipZip')
  Assert-Equal 0 $allowed.ExitCode ('the explicit override must work: ' + $allowed.Output)
  Assert-Match $allowed.Output 'infrastructure-only package' 'the degraded package must be announced'
  $manifest = Get-Content -LiteralPath (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0\release-manifest.json') -Raw | ConvertFrom-Json
  foreach ($file in @($manifest.files)) {
    Assert-NotMatch ([string]$file.source) '^payload/' 'an infrastructure-only package must not claim payload files'
  }
  # the output directory is never recursively deleted: unrelated content survives a rebuild
  $keep = Join-Path $repo 'dist\keep-me.txt'
  Write-ToolkitTestFile -Path $keep -Content 'unrelated'
  Assert-Equal 0 (Invoke-ToolkitTestBuildRelease -RepoRoot $repo -ExtraArguments @('-AllowMissingPayload', '-SkipZip')).ExitCode
  Assert-FileExists $keep 'unrelated output directory content must never be deleted'
}

Test-Case -Name 'release: a missing build input is reported instead of being substituted' -Body {
  $base = New-ToolkitTestDirectory -Label 'release-missinginput'
  $repo = New-ToolkitTestRepo -Root (Join-Path $base 'repo')
  Remove-Item -LiteralPath (Join-Path $repo 'Install.cmd') -Force

  $build = Invoke-ToolkitTestBuildRelease -RepoRoot $repo
  Assert-True ($build.ExitCode -ne 0) 'a missing package file must fail the build'
  Assert-Match $build.Output 'Missing required package file' 'the reason must be explicit'
  Assert-FileMissing (Join-Path $repo 'dist\codex-dsh-team-toolkit-v1.0.0\release-manifest.json')
}
