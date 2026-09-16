#Requires -Version 1.0
<#
  06 - confidentiality: deny-by-default, no secret in plan/journal/manifest/log/release.
  Every value used here is a fake credential created only for the test.
#>
Set-StrictMode -Version Latest

$script:FakeSecret = 'FAKE-SECRET-VALUE-000000000000000000'

function New-ToolkitTestRawPackage {
  <#
    Builds a package whose release manifest claims an arbitrary (possibly forbidden) path,
    bypassing the manifest builder, to test the engine's own deny-by-default policy.
  #>
  param(
    [string]$Root,
    [string]$TargetPath,
    [string]$SourceRelative,
    [string]$Content
  )
  New-Item -ItemType Directory -Path $Root -Force | Out-Null
  $sourcePath = Join-Path $Root ($SourceRelative -replace '/', '\')
  Write-ToolkitTestFile -Path $sourcePath -Content $Content
  $manifest = New-ToolkitJsonObject -Properties @{
    schema         = 'codex-dsh-team-toolkit/release-manifest/v1'
    name           = 'codex-dsh-team-toolkit'
    version        = '1.0.0'
    stateDirectory = '.codex-dsh-team-toolkit'
    fileCount      = 1
    files          = @(New-ToolkitJsonObject -Properties @{
        path   = $TargetPath
        source = $SourceRelative
      })
  }
  Write-ToolkitJsonAtomic -Object $manifest -Destination (Join-Path $Root 'release-manifest.json')
  return $Root
}

Test-Case -Name 'confidentiality: a manifest that claims credential stores is refused' -Body {
  $hostileTargets = @(
    '.env',
    '.agents/skills/x/credentials.json',
    '.agents/skills/x/secrets/token.json',
    '.agents/skills/x/id_rsa',
    '.agents/skills/x/server.key',
    '.agents/skills/x/settings.yaml',
    'node_modules/dep/index.js',
    '.git/config'
  )
  foreach ($hostile in $hostileTargets) {
    $base = New-ToolkitTestDirectory -Label 'deny'
    $package = New-ToolkitTestRawPackage -Root (Join-Path $base 'package') -TargetPath $hostile -SourceRelative 'payload/file.bin' -Content "fake content`n"
    $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
    $before = Get-ToolkitTestTreeSnapshot -Root $project

    $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package }
    Assert-Equal $script:ExitBlocked $result.ExitCode ('should refuse: ' + $hostile + ' :: ' + (Get-ToolkitTestOutput $result))
    Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot -Root $project) -join ';') 'a denied package must not write anything'
    Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
  }
}

Test-Case -Name 'confidentiality: a secret embedded in a path never reaches console, journal or log' -Body {
  $base = New-ToolkitTestDirectory -Label 'pathsecret'
  $secretPath = '.agents/skills/x/token=' + $script:FakeSecret + '.json'
  $package = New-ToolkitTestRawPackage -Root (Join-Path $base 'package') -TargetPath $secretPath -SourceRelative 'payload/file.bin' -Content "fake`n"
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $result = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package }
  Assert-Equal $script:ExitBlocked $result.ExitCode
  $output = Get-ToolkitTestOutput $result
  Assert-NotMatch $output ([regex]::Escape($script:FakeSecret)) 'the secret value must never be printed'
  Assert-Match $output 'redacted' 'the refusal must show a redacted path'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
}

Test-Case -Name 'confidentiality: fake secrets in payload content never reach plan, manifest, log or journal' -Body {
  $base = New-ToolkitTestDirectory -Label 'contentsecret'
  $payload = New-ToolkitTestPayload -Overrides @{
    '.agents/skills/codex-dsh-team/SKILL.md' = ("# fake payload`napi_key = " + $script:FakeSecret + "`n")
  }
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package') -PayloadFiles $payload
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root; TestKeepTransaction = $true; TestMode = $true
  }
  Assert-Equal 0 $result.ExitCode ('install should succeed: ' + (Get-ToolkitTestOutput $result))

  $output = Get-ToolkitTestOutput $result
  Assert-NotMatch $output ([regex]::Escape($script:FakeSecret)) 'console output must not contain payload content'

  # the installed file itself legitimately carries the payload bytes
  Assert-Match (Get-Content -LiteralPath (Join-Path $project '.agents\skills\codex-dsh-team\SKILL.md') -Raw) ([regex]::Escape($script:FakeSecret)) 'payload content is installed as-is'

  $stateDirectory = Join-Path $project '.codex-dsh-team-toolkit'
  Assert-NotMatch (Get-Content -LiteralPath (Join-Path $stateDirectory 'manifest.json') -Raw) ([regex]::Escape($script:FakeSecret)) 'the ownership manifest must not contain file contents'
  Assert-NotMatch (Get-Content -LiteralPath (Join-Path $stateDirectory 'install.log') -Raw) ([regex]::Escape($script:FakeSecret)) 'the log must not contain file contents'

  $journals = @(Get-ChildItem -LiteralPath (Join-Path $stateDirectory 'txn') -Recurse -Force -Filter 'journal.json' -ErrorAction SilentlyContinue)
  if ($journals.Count -gt 0) {
    foreach ($journal in $journals) {
      Assert-NotMatch (Get-Content -LiteralPath $journal.FullName -Raw) ([regex]::Escape($script:FakeSecret)) 'the journal must not contain file contents'
    }
  }
  else {
    Write-ToolkitTestNote 'no journal was kept (the transaction committed and cleaned up)'
  }
}

Test-Case -Name 'confidentiality: secret-shaped header and token values are redacted from output' -Body {
  $samples = @(
    'Authorization: Bearer abcdefghij0123456789',
    'api_key=FAKEFAKEFAKE0123456789',
    'password=FAKEPASSWORD0123456789',
    ('eyJhbGciOiJIUzI1NiJ9.' + 'eyJzdWIiOiJmYWtlIn0.' + 'FAKESIGNATURE0123456789'),
    'sk-FAKEFAKEFAKEFAKE0123456789'
  )
  foreach ($sample in $samples) {
    $safe = Get-ToolkitSafeText -Text $sample
    Assert-Match $safe 'redacted' ('must be redacted: ' + $sample)
  }
}

Test-Case -Name 'confidentiality: a refused Team Home is never modified and its secret never leaks' -Body {
  $base = New-ToolkitTestDirectory -Label 'teamhomesafe'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')

  $dshHome = Join-Path $base 'user-dsh-home'
  New-Item -ItemType Directory -Path $dshHome -Force | Out-Null
  $credentialPath = Join-Path $dshHome '.credentials.yaml'
  Write-ToolkitTestFile -Path $credentialPath -Content ("token: " + $script:FakeSecret + "`n")
  Write-ToolkitTestFile -Path (Join-Path $dshHome 'settings.yaml') -Content "model: fake`n"
  $beforeHashes = Get-ToolkitTestTreeSnapshot -Root $dshHome
  $beforeWrite = (Get-Item -LiteralPath $credentialPath).LastWriteTimeUtc

  $result = Invoke-ToolkitTestCommand -Options @{
    Action = 'Install'; Target = $project; PackageRoot = $package.Root; TeamDshHome = $dshHome
  }
  Assert-Equal $script:ExitBlocked $result.ExitCode
  Assert-NotMatch (Get-ToolkitTestOutput $result) ([regex]::Escape($script:FakeSecret)) 'the credential value must never be read out'
  Assert-Equal ($beforeHashes -join ';') ((Get-ToolkitTestTreeSnapshot -Root $dshHome) -join ';') 'the user DSH Home must be untouched'
  Assert-Equal ([string]$beforeWrite) ([string](Get-Item -LiteralPath $credentialPath).LastWriteTimeUtc) 'the credential file must not even be rewritten'
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
}
