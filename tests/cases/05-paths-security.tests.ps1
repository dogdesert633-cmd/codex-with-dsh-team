#Requires -Version 5.1
<#
  05 - path safety, deny-by-default policy, redaction, reparse points, owned runtime marker.
#>

Test-Case -Name 'paths: absolute, traversal, UNC, device and reserved paths are refused' -Body {
  $longSegment = 'x' * 120
  $longPath = 'a/' + $longSegment + '.md'
  $hostilePaths = @(
    '..\outside.md',
    '../outside.md',
    'a/../../outside.md',
    'C:\Windows\System32\evil.dll',
    'C:/Windows/evil.dll',
    '\absolute.md',
    '/absolute.md',
    '\\server\share\file.md',
    '//server/share/file.md',
    '\\?\C:\device\file.md',
    '.',
    './file.md',
    'a/./b.md',
    '',
    '   ',
    'a/COM1.txt',
    'a/NUL',
    'a/trailingdot.',
    'a/trailing space ',
    'a/invalid<name>.md',
    'a/notes.md:evil',
    'a/COM1.txt:stream',
    'a/.hidden:ads'
  )
  $hostilePaths += $longPath

  foreach ($hostile in $hostilePaths) {
    Assert-ToolkitThrows -Body { Assert-ToolkitRelativePath -Path $hostile } -Message ('should refuse: ' + $hostile)
  }

  Assert-ToolkitDoesNotThrow -Body { Assert-ToolkitRelativePath -Path '.agents/skills/codex-dsh-team/SKILL.md' } -Message 'a normal managed path must be accepted'
  Assert-Equal '.agents/skills/x.md' (Assert-ToolkitRelativePath -Path '.agents\skills\x.md') 'backslashes must normalize to forward slashes'
}

Test-Case -Name 'paths: a differently-cased existing directory blocks the install' -Body {
  $base = New-ToolkitTestDirectory -Label 'casefold-disk'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  # On a case-insensitive filesystem this collides with the planned ".agents" directory while
  # preserving a different on-disk spelling; the toolkit must refuse rather than merge into it.
  New-Item -ItemType Directory -Path (Join-Path $project '.Agents') -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $project '.Agents\user-file.txt') -Content 'user content'

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitConflict $result.ExitCode ('a case-folded on-disk collision must block: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'differs only by letter case' 'the reason must name the case-fold conflict'
  Assert-FileExists (Join-Path $project '.Agents\user-file.txt') 'the existing directory must be untouched'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
}

Test-Case -Name 'paths: deny-by-default refuses credential stores and runtime trees' -Body {
  foreach ($denied in @(
      '.env',
      '.env.local',
      'config/.env.production',
      '.agents/skills/x/credentials.json',
      '.agents/skills/x/.credentials.yaml',
      '.agents/skills/x/id_rsa',
      '.agents/skills/x/id_ed25519.pub',
      '.agents/skills/x/server.key',
      '.agents/skills/x/cert.pem',
      '.agents/skills/x/settings.yaml',
      '.agents/skills/x/secrets/token.json',
      '.agents/skills/x/cookies.json',
      '.agents/skills/x/session.json',
      '.agents/skills/x/auth.log',
      '.git/config',
      '.dsh/state.json',
      'node_modules/dep/index.js',
      'artifacts/run.json',
      '.agents/skills/x/token=ABCDEF0123456789abcdef',
      '.agents/skills/x/ChromeProfile/Default/Cookies'
    )) {
    Assert-ToolkitThrows -Body { Assert-ToolkitPathNotDenied -RelativePath $denied } -Message ('should deny: ' + $denied)
  }

  foreach ($allowed in @(
      '.agents/skills/codex-dsh-team/SKILL.md',
      '.agents/skills/mcp-to-dsh/src/model-settings.mjs',
      '.agents/skills/mcp-to-dsh/references/evidence-and-recovery.md',
      '.codex-dsh-team-toolkit/engine/Invoke-Toolkit.ps1',
      'CodexDshTeamToolkit.Uninstall.exe',
      'start_dsh_team.cmd'
    )) {
    Assert-ToolkitDoesNotThrow -Body { Assert-ToolkitPathNotDenied -RelativePath $allowed } -Message ('should allow: ' + $allowed)
  }
}

Test-Case -Name 'paths: display redaction hides secret-shaped segments and values' -Body {
  $secret = 'ABCDEF0123456789abcdefSECRET'
  $displayed = Get-ToolkitSafePath -Path ('C:\projects\token=' + $secret + '\file.md')
  Assert-NotMatch $displayed ([regex]::Escape($secret)) 'a secret in a path must never be displayed'
  Assert-Match $displayed 'redacted' 'the display must mark the redaction'

  $normal = Get-ToolkitSafePath -Path '.agents/skills/codex-dsh-team/SKILL.md'
  Assert-Equal '.agents/skills/codex-dsh-team/SKILL.md' $normal 'normal paths must be shown unchanged'

  $text = Get-ToolkitSafeText -Text ('Authorization: Bearer abcdef0123456789 and password=hunter2hunter2 and sk-ABCDEFGHIJKLMNOPQRSTUV')
  Assert-NotMatch $text 'abcdef0123456789' 'bearer values must be redacted'
  Assert-NotMatch $text 'hunter2hunter2' 'password values must be redacted'
  Assert-NotMatch $text 'sk-ABCDEFGHIJKLMNOPQRSTUV' 'api keys must be redacted'
  Assert-Match $text 'redacted' 'redaction must be visible'
}

Test-Case -Name 'paths: a junction anywhere on the managed path blocks the install' -Body {
  $base = New-ToolkitTestDirectory -Label 'reparse'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $outside = Join-Path $base 'outside'
  New-Item -ItemType Directory -Path $outside -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $outside 'planted.md') -Content "# outside the project`n"

  $linked = $false
  try {
    New-Item -ItemType Junction -Path (Join-Path $project '.agents') -Target $outside -ErrorAction Stop | Out-Null
    $linked = $true
  }
  catch {
    Write-ToolkitTestNote ('this platform cannot create a junction: ' + (Get-ToolkitSafeText -Text $_.Exception.Message))
  }

  if (-not $linked) {
    Write-ToolkitTestNote 'reparse check skipped: no junction support available'
    return
  }

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root }
  Assert-Equal $script:ExitBlocked $result.ExitCode ('a junction on the managed path must block: ' + (Get-ToolkitTestOutput $result))
  Assert-Match (Get-ToolkitTestOutput $result) 'reparse point' 'the reason must name the reparse point'
  Assert-FileExists (Join-Path $outside 'planted.md') 'nothing outside the project may be touched'
  Assert-FileMissing (Join-Path $outside 'skills')

  $uninstall = Invoke-ToolkitTestCommand -Options @{ Action = 'Uninstall'; Target = $project; Yes = $true }
  Assert-True ($uninstall.ExitCode -ne 0) 'uninstall through a junction must fail closed'
  Assert-FileExists (Join-Path $outside 'planted.md')
}

Test-Case -Name 'paths: the toolkit refuses to adopt a plain user DSH Home' -Body {
  $base = New-ToolkitTestDirectory -Label 'teamhome'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  # 1) an existing directory that looks like a real user DSH Home must be refused
  $dshHome = Join-Path $base 'user-dsh-home'
  New-Item -ItemType Directory -Path $dshHome -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $dshHome 'settings.yaml') -Content "model: fake`n"
  Write-ToolkitTestFile -Path (Join-Path $dshHome '.credentials.yaml') -Content "token: fake-value-not-a-real-secret`n"
  $credentialsCopy = Join-Path $base 'credentials-before.yaml'
  Copy-Item -LiteralPath (Join-Path $dshHome '.credentials.yaml') -Destination $credentialsCopy -Force

  $refused = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root; TeamDshHome = $dshHome
  }
  Assert-Equal $script:ExitBlocked $refused.ExitCode ('a user DSH Home must never be adopted: ' + (Get-ToolkitTestOutput $refused))
  Assert-Match (Get-ToolkitTestOutput $refused) 'DSH Home is read-only|looks like a real DSH Home' 'the refusal must explain the policy'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
  Assert-True (Test-ToolkitFileContentEqual -PathA (Join-Path $dshHome '.credentials.yaml') -PathB $credentialsCopy) 'the source file is untouched'

  # 2) an existing directory without a toolkit marker must be refused
  $unowned = Join-Path $base 'unowned-home'
  New-Item -ItemType Directory -Path $unowned -Force | Out-Null
  Write-ToolkitTestFile -Path (Join-Path $unowned 'something.txt') -Content 'x'
  $noMarker = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root; TeamDshHome = $unowned
  }
  Assert-Equal $script:ExitBlocked $noMarker.ExitCode 'an unowned directory must not be adopted'
  Assert-Match (Get-ToolkitTestOutput $noMarker) 'without a valid Team Home marker' 'the reason must name the marker'

  # 3) the superseded marker is no longer ownership proof (never migrated, never accepted)
  $legacyHome = Join-Path $base 'legacy-home'
  New-Item -ItemType Directory -Path $legacyHome -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitJsonObject -Properties @{
      schema = 'codex-dsh-team-toolkit/runtime-marker/v1'; toolkit = 'codex-dsh-team-toolkit'
      installId = [guid]::NewGuid().ToString(); createdAtUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
      purpose = 'Toolkit-owned writable runtime (Team Home). Not a user DSH Home.'
    }) -Destination (Join-Path $legacyHome '.codex-dsh-team-runtime.json')
  $legacyResult = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root; TeamDshHome = $legacyHome
  }
  Assert-Equal $script:ExitBlocked $legacyResult.ExitCode ('a legacy marker must be refused: ' + (Get-ToolkitTestOutput $legacyResult))
  Assert-Match (Get-ToolkitTestOutput $legacyResult) 'superseded Team runtime marker' 'the reason must name the legacy marker'
  Assert-FileExists (Join-Path $legacyHome '.codex-dsh-team-runtime.json') 'the legacy marker must be left untouched'
  Assert-FileMissing (Join-Path $legacyHome '.codex-dsh-team-home.json') 'no second marker may be written'
}

Test-Case -Name 'paths: a marker-owned Team Home is adopted, and a new one is created with the shared marker' -Body {
  $base = New-ToolkitTestDirectory -Label 'marker'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  # create an owned Team Home through the documented initialisation path
  $runtimeBase = Join-Path $base 'runtime-base'
  $init = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    InitializeRuntime = $true; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal 0 $init.ExitCode ('runtime initialisation should succeed: ' + (Get-ToolkitTestOutput $init))
  $runtimeRoots = @(Get-ChildItem -LiteralPath (Join-Path $runtimeBase 'runtimes') -Directory -ErrorAction SilentlyContinue)
  Assert-Equal 1 $runtimeRoots.Count 'exactly one owned runtime root must be created'
  $ownedHome = $runtimeRoots[0].FullName

  # one contract, one marker file: the shared name/schema/fields, and no legacy marker
  $markerPath = Join-Path $ownedHome '.codex-dsh-team-home.json'
  Assert-FileExists $markerPath 'the shared Team Home marker must be created'
  Assert-FileMissing (Join-Path $ownedHome '.codex-dsh-team-runtime.json') 'the legacy marker must never be written'
  $marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
  Assert-Equal 'codex-dsh-team-home/v1' ([string]$marker.schema)
  Assert-Equal 'codex-dsh-team-toolkit' ([string]$marker.toolkitId)
  Assert-Equal 'dsh-team-runtime-home' ([string]$marker.purpose)
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$marker.installId)) 'the marker must carry an installId'
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$marker.createdAt)) 'the marker must carry createdAt'

  # the install identity manifest is the shared source of that installId
  $identityPath = Join-Path $runtimeBase 'install.json'
  Assert-FileExists $identityPath 'the shared install identity must exist'
  $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
  Assert-Equal 'codex-dsh-team-install/v1' ([string]$identity.schema)
  Assert-Equal 'codex-dsh-team-toolkit' ([string]$identity.toolkitId)
  Assert-Equal ([string]$identity.installId) ([string]$marker.installId) 'the marker must use the shared install identity'
  Assert-Equal ([string]$identity.installId) ([string](Get-ChildItem -LiteralPath (Join-Path $runtimeBase 'runtimes') -Directory)[0].Name) 'the runtime root must be keyed by the shared install id'
  $ledger = Read-ToolkitOwnershipManifest -Path (Join-Path $project '.codex-dsh-team-toolkit\manifest.json')
  Assert-Equal ([string]$identity.installId) ([string]$ledger.installId) 'the project ledger must share the same install id'

  # the same owned Team Home can be reused explicitly
  $reuse = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TeamDshHome = $ownedHome; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal 0 $reuse.ExitCode ('an owned Team Home must be accepted: ' + (Get-ToolkitTestOutput $reuse))

  # a marker for a different installation of this toolkit must be refused
  $foreignInstall = Join-Path $base 'foreign-install-home'
  New-Item -ItemType Directory -Path $foreignInstall -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitTeamHomeMarker -InstallId ([guid]::NewGuid().ToString())) -Destination (Join-Path $foreignInstall '.codex-dsh-team-home.json')
  $foreignResult = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TeamDshHome = $foreignInstall; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal $script:ExitBlocked $foreignResult.ExitCode ('a foreign-install marker must be refused: ' + (Get-ToolkitTestOutput $foreignResult))
  Assert-Match (Get-ToolkitTestOutput $foreignResult) 'different installation' 'the reason must name the foreign install'

  # a marker from another toolkit (wrong schema/toolkitId/purpose) must be refused
  $foreignTool = Join-Path $base 'foreign-tool-home'
  New-Item -ItemType Directory -Path $foreignTool -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitJsonObject -Properties @{
      schema = 'some-other-tool/home-marker/v1'; toolkitId = 'other-tool'; installId = [guid]::NewGuid().ToString()
      createdAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'); purpose = 'not ours'
    }) -Destination (Join-Path $foreignTool '.codex-dsh-team-home.json')
  $foreignToolResult = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TeamDshHome = $foreignTool; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal $script:ExitBlocked $foreignToolResult.ExitCode 'a foreign toolkit marker must be refused'

  # a marker missing a required field must be refused (no partial-marker compatibility)
  $partial = Join-Path $base 'partial-home'
  New-Item -ItemType Directory -Path $partial -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitJsonObject -Properties @{
      schema = 'codex-dsh-team-home/v1'; toolkitId = 'codex-dsh-team-toolkit'; installId = [guid]::NewGuid().ToString()
    }) -Destination (Join-Path $partial '.codex-dsh-team-home.json')
  $partialResult = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TeamDshHome = $partial; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal $script:ExitBlocked $partialResult.ExitCode 'a partial marker must be refused'
  Assert-Match (Get-ToolkitTestOutput $partialResult) 'missing the required field' 'the reason must name the missing field'

  # both markers on disk is a broken state and must be refused, never merged
  $dual = Join-Path $base 'dual-marker-home'
  New-Item -ItemType Directory -Path $dual -Force | Out-Null
  Write-ToolkitJsonAtomic -Object (New-ToolkitTeamHomeMarker -InstallId ([string]$identity.installId)) -Destination (Join-Path $dual '.codex-dsh-team-home.json')
  Write-ToolkitJsonAtomic -Object (New-ToolkitJsonObject -Properties @{ schema = 'codex-dsh-team-toolkit/runtime-marker/v1'; toolkit = 'codex-dsh-team-toolkit'; installId = [string]$identity.installId; createdAtUtc = '2026-01-01T00:00:00Z'; purpose = 'x' }) -Destination (Join-Path $dual '.codex-dsh-team-runtime.json')
  $dualResult = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TeamDshHome = $dual; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal $script:ExitBlocked $dualResult.ExitCode 'a dual-marker directory must be refused'
  Assert-FileExists (Join-Path $dual '.codex-dsh-team-home.json') 'nothing may be deleted from the refused directory'
  Assert-FileExists (Join-Path $dual '.codex-dsh-team-runtime.json') 'nothing may be deleted from the refused directory'
}

Test-Case -Name 'marker: the installer and the Node runtime accept each other markers' -Body {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) {
    Write-ToolkitTestNote 'node is unavailable; the cross-implementation marker test cannot run'
    return
  }
  $teamHomeModule = Join-Path $script:TKTestToolkitRoot 'payload\.agents\skills\mcp-to-dsh\src\team-home.mjs'
  Assert-FileExists $teamHomeModule 'the runtime marker authority must be part of the payload'

  $base = New-ToolkitTestDirectory -Label 'marker-cross'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $runtimeBase = Join-Path $base 'runtime-base'

  # (a) installer creates the Team Home -> the Node runtime must accept it as owned
  $init = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    InitializeRuntime = $true; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal 0 $init.ExitCode ('runtime initialisation should succeed: ' + (Get-ToolkitTestOutput $init))
  $ownedHome = @(Get-ChildItem -LiteralPath (Join-Path $runtimeBase 'runtimes') -Directory)[0].FullName

  $script = @'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.argv[2]).href);
const home = process.argv[3];
const inspected = mod.inspectTeamHome(home);
const marker = mod.readTeamHomeMarker(home);
process.stdout.write(JSON.stringify({ state: inspected.state, marker }));
'@
  $scriptPath = Join-Path $base 'inspect-marker.mjs'
  Write-ToolkitTestFile -Path $scriptPath -Content $script
  $probe = Invoke-ToolkitTestNative -Command { & node $scriptPath $teamHomeModule $ownedHome }
  $nodeOut = $probe.Output
  Assert-Equal 0 $probe.ExitCode ('the Node runtime must accept the installer marker: ' + $nodeOut)
  $parsed = ConvertFrom-Json -InputObject $nodeOut
  Assert-Equal 'owned' ([string]$parsed.state) 'the runtime must classify the installer Team Home as owned'
  Assert-Equal 'codex-dsh-team-home/v1' ([string]$parsed.marker.schema)
  Assert-Equal 'codex-dsh-team-toolkit' ([string]$parsed.marker.toolkitId)

  # (b) the Node runtime creates the Team Home -> the installer must accept it
  #     The identity is passed as a *file path*: Windows PowerShell 5.1 strips double quotes
  #     from native arguments, so JSON must never travel as an argv value.
  $runtimeCreated = Join-Path $base 'runtime-created-home'
  $identityFromRuntime = Join-Path $runtimeBase 'install.json'
  $identityCopy = Join-Path $base 'identity-for-runtime.json'
  Copy-Item -LiteralPath $identityFromRuntime -Destination $identityCopy -Force
  $scriptB = @'
import { pathToFileURL } from "node:url";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
const mod = await import(pathToFileURL(process.argv[2]).href);
const home = process.argv[3];
const identity = JSON.parse(readFileSync(process.argv[4], "utf8"));
mkdirSync(home, { recursive: true });
const marker = mod.buildTeamHomeMarker({ installId: identity.installId });
writeFileSync(join(home, mod.TEAM_HOME_MARKER_NAME), JSON.stringify(marker, null, 2) + "\n", "utf8");
process.stdout.write(JSON.stringify({ marker }));
'@
  $scriptBPath = Join-Path $base 'create-marker.mjs'
  Write-ToolkitTestFile -Path $scriptBPath -Content $scriptB
  $probeB = Invoke-ToolkitTestNative -Command { & node $scriptBPath $teamHomeModule $runtimeCreated $identityCopy }
  $nodeOutB = $probeB.Output
  Assert-Equal 0 $probeB.ExitCode ('the runtime marker fixture must be written: ' + $nodeOutB)
  Assert-FileExists (Join-Path $runtimeCreated '.codex-dsh-team-home.json')

  $accepted = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TeamDshHome = $runtimeCreated; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal 0 $accepted.ExitCode ('the installer must accept a runtime-created marker: ' + (Get-ToolkitTestOutput $accepted))

  # (c) a runtime marker for a different install is still refused by the installer
  $otherHome = Join-Path $base 'runtime-other-install'
  New-Item -ItemType Directory -Path $otherHome -Force | Out-Null
  $scriptC = @'
import { pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
const mod = await import(pathToFileURL(process.argv[2]).href);
const home = process.argv[3];
const marker = mod.buildTeamHomeMarker({ installId: process.argv[4] });
writeFileSync(join(home, mod.TEAM_HOME_MARKER_NAME), JSON.stringify(marker, null, 2) + "\n", "utf8");
'@
  $scriptCPath = Join-Path $base 'create-foreign-marker.mjs'
  Write-ToolkitTestFile -Path $scriptCPath -Content $scriptC
  $probeC = Invoke-ToolkitTestNative -Command { & node $scriptCPath $teamHomeModule $otherHome ([guid]::NewGuid().ToString()) }
  Assert-Equal 0 $probeC.ExitCode ('the foreign marker fixture must be written: ' + $probeC.Output)
  $refused = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root
    TeamDshHome = $otherHome; RuntimeRootBase = $runtimeBase
  }
  Assert-Equal $script:ExitBlocked $refused.ExitCode 'a runtime marker for another install must be refused'
}
