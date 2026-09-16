#Requires -Version 5.1
<#
  12 - payload Node integration gate.

  Runs the payload's own Node suite in a standalone temporary copy with read-only offline
  dependencies and a hard time bound, so a leaked handle / teardown bug can never turn into an
  unbounded hang that has to be interrupted by hand.

  Nothing here touches the real user DSH Home, the network, or the repository payload tree:
  the payload is copied into a temp directory and node_modules is a read-only junction to the
  dependencies that already exist in this workspace.

  All Node invocations use an explicit argument vector and files (never a quoted `-e` payload):
  Windows PowerShell 5.1 mangles embedded double quotes when passing native arguments.
#>

function Get-ToolkitTestNodePath {
  $node = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $node) { return '' }
  return $node.Source
}

function Add-ToolkitTestPowerShell7ToPath {
  <#
    The payload's launcher tests assert parity between Windows PowerShell 5.1 and PowerShell 7,
    and they resolve PowerShell 7 by its bare name. When the parent host is 5.1 (or PowerShell 7
    simply is not on PATH) the child Node process cannot find it, so the directory of a
    discoverable PowerShell 7 host is prepended to PATH for this test run only.

    Only portable probes are used: an explicit CODEX_DSH_TOOLKIT_PWSH override, PATH, the
    current host's own $PSHOME, and the standard installer location. No machine-specific path is
    hardcoded, and nothing is installed.
  #>
  $override = [string]$env:CODEX_DSH_TOOLKIT_PWSH
  if (-not [string]::IsNullOrEmpty($override) -and (Test-Path -LiteralPath $override -PathType Leaf)) { return $override }
  $match = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($null -ne $match) { return [string]$match.Source }
  $candidates = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrEmpty($PSHOME)) { [void]$candidates.Add((Join-Path $PSHOME 'pwsh.exe')) }
  if (-not [string]::IsNullOrEmpty($env:ProgramFiles)) { [void]$candidates.Add((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe')) }
  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  return ''
}

function Enable-ToolkitTestPowerShell7ForChild {
  param([switch]$Quiet)
  $pwshPath = Add-ToolkitTestPowerShell7ToPath
  if ([string]::IsNullOrEmpty($pwshPath)) {
    if (-not $Quiet) {
      Write-ToolkitTestNote 'PowerShell 7 (pwsh) is not discoverable; the payload launcher parity assertions need it on PATH'
    }
    return $false
  }
  $directory = Split-Path -Parent $pwshPath
  if (($env:PATH -split ';') -notcontains $directory) {
    $env:PATH = $directory + ';' + $env:PATH
  }
  return $true
}

function New-ToolkitTestStandalonePayload {
  <#
    Builds <root>/codex-dsh-team-toolkit/payload/.agents/skills/mcp-to-dsh with a read-only
    node_modules junction, i.e. exactly the layout a standalone clone has.
  #>
  param(
    [string]$Root,
    [switch]$WithFrozenTree
  )

  $payloadDestination = Join-Path $Root 'codex-dsh-team-toolkit\payload'
  New-Item -ItemType Directory -Path $payloadDestination -Force | Out-Null
  Copy-Item -Path (Join-Path $script:TKTestToolkitRoot 'payload\*') -Destination $payloadDestination -Recurse -Force

  $dependencyRoot = Join-Path (Split-Path -Parent $script:TKTestToolkitRoot) '.agents\skills\mcp-to-dsh\node_modules'
  $nodeModulesReady = Test-Path -LiteralPath (Join-Path $dependencyRoot 'zod') -PathType Container
  if ($nodeModulesReady) {
    New-Item -ItemType Junction -Path (Join-Path $payloadDestination '.agents\skills\mcp-to-dsh\node_modules') -Target $dependencyRoot | Out-Null
  }
  if ($WithFrozenTree) {
    # Optional maintainer-only baseline. It is an EXPLICIT external input (environment
    # variable), never a hardcoded internal development path, so the public test tree has no
    # dependency on `deliverables/...` and simply skips the comparison when it is absent.
    $baselineRoot = [string]$env:CODEX_DSH_TEAM_BASELINE_ROOT
    if (-not [string]::IsNullOrEmpty($baselineRoot) -and (Test-Path -LiteralPath $baselineRoot -PathType Container)) {
      # The child Node process reads the same environment variable; nothing is copied in.
      $env:CODEX_DSH_TEAM_BASELINE_ROOT = $baselineRoot
    }
  }
  return (New-ToolkitJsonObject -Properties @{
      SkillDirectory   = Join-Path $payloadDestination '.agents\skills\mcp-to-dsh'
      NodeModulesReady = $nodeModulesReady
    })
}

function New-ToolkitTestNodeSuiteRunner {
  <#
    Writes a small ESM runner that executes the payload test suite in a child Node process and
    forwards its output. Running a file avoids every `-e` quoting problem.
  #>
  param([string]$SkillDirectory)

  $runner = @'
import { spawnSync } from "node:child_process";
import { readdirSync } from "node:fs";
const files = readdirSync("test").filter((name) => name.endsWith(".test.mjs")).map((name) => "test/" + name);
const child = spawnSync(process.execPath, ["--test", "--test-reporter=spec", ...files], {
  encoding: "utf8",
  maxBuffer: 64 * 1024 * 1024,
});
process.stdout.write(child.stdout ?? "");
process.stderr.write(child.stderr ?? "");
process.exit(child.status ?? 1);
'@
  $runnerPath = Join-Path $SkillDirectory 'run-node-suite.mjs'
  Write-ToolkitTestFile -Path $runnerPath -Content $runner
  return $runnerPath
}

Test-Case -Name 'payload: npm run check passes offline' -Body {
  $node = Get-ToolkitTestNodePath
  if ([string]::IsNullOrEmpty($node)) {
    Write-ToolkitTestNote 'node is unavailable; the payload check cannot run'
    return
  }
  $base = New-ToolkitTestDirectory -Label 'payload-check'
  $standalone = New-ToolkitTestStandalonePayload -Root $base

  # node --check needs no dependencies at all, so this always runs
  $checks = @(
    'src/security.mjs', 'src/team-home.mjs', 'src/cli.mjs', 'src/server.mjs', 'src/model-settings.mjs',
    'public/model-revision.js', 'public/app.js'
  )
  $checkScript = @'
import { spawnSync } from "node:child_process";
const files = [
  "src/security.mjs", "src/team-home.mjs", "src/cli.mjs", "src/server.mjs",
  "src/model-settings.mjs", "public/model-revision.js", "public/app.js",
];
let failed = false;
for (const file of files) {
  const child = spawnSync(process.execPath, ["--check", file], { encoding: "utf8" });
  if (child.status !== 0) {
    failed = true;
    process.stdout.write(`node --check failed for ${file}\n${child.stdout}${child.stderr}`);
  }
}
process.stdout.write(`checked ${files.length} files\n`);
process.exit(failed ? 1 : 0);
'@
  $checkPath = Join-Path $standalone.SkillDirectory 'run-node-check.mjs'
  Write-ToolkitTestFile -Path $checkPath -Content $checkScript
  $result = Invoke-ToolkitTestNode -NodePath $node -TimeoutSeconds 180 -WorkingDirectory $standalone.SkillDirectory -Arguments @($checkPath)
  Assert-Equal 0 $result.ExitCode ('node --check must pass for every payload source: ' + $result.Output)
  Assert-Match $result.Output ('checked ' + $checks.Count + ' files') 'every source file must be checked'
  Write-ToolkitTestNote ('checked ' + $checks.Count + ' payload source files with node --check')
}

Test-Case -Name 'payload: the full Node suite exits naturally within a bounded timeout' -Body {
  $node = Get-ToolkitTestNodePath
  if ([string]::IsNullOrEmpty($node)) {
    Write-ToolkitTestNote 'node is unavailable; the payload Node suite cannot run'
    return
  }
  $base = New-ToolkitTestDirectory -Label 'payload-suite'
  $standalone = New-ToolkitTestStandalonePayload -Root $base
  if (-not $standalone.NodeModulesReady) {
    Write-ToolkitTestNote 'offline node_modules are not available in this workspace; skipping the full Node suite'
    return
  }
  [void](Enable-ToolkitTestPowerShell7ForChild)
  $runnerPath = New-ToolkitTestNodeSuiteRunner -SkillDirectory $standalone.SkillDirectory

  $result = Invoke-ToolkitTestNode -NodePath $node -TimeoutSeconds 300 -WorkingDirectory $standalone.SkillDirectory -Arguments @($runnerPath)
  Assert-False ([bool]$result.TimedOut) ('the payload Node suite must exit on its own: ' + $result.Output)
  Assert-Equal 0 $result.ExitCode ('the payload Node suite must exit 0: ' + $result.Output)
  Assert-Match $result.Output 'fail 0' 'no payload test may fail'
  Assert-Match $result.Output 'maintainer-only: no external baseline provided' 'the baseline comparison must be an explicit maintainer-only skip in a standalone copy'
  Write-ToolkitTestNote 'payload Node suite completed within the bound (standalone copy, read-only deps)'
}

Test-Case -Name 'payload: the Node suite also passes when an explicit external baseline is provided' -Body {
  $node = Get-ToolkitTestNodePath
  if ([string]::IsNullOrEmpty($node)) {
    Write-ToolkitTestNote 'node is unavailable; the payload Node suite cannot run'
    return
  }
  $baselineRoot = [string]$env:CODEX_DSH_TEAM_BASELINE_ROOT
  if ([string]::IsNullOrEmpty($baselineRoot) -or -not (Test-Path -LiteralPath $baselineRoot -PathType Container)) {
    Write-ToolkitTestNote 'maintainer-only: no external baseline provided (set CODEX_DSH_TEAM_BASELINE_ROOT); skipping the comparison run'
    return
  }
  $base = New-ToolkitTestDirectory -Label 'payload-devtree'
  $standalone = New-ToolkitTestStandalonePayload -Root $base -WithFrozenTree
  if (-not $standalone.NodeModulesReady) {
    Write-ToolkitTestNote 'offline node_modules are not available in this workspace; skipping the baseline comparison run'
    return
  }
  [void](Enable-ToolkitTestPowerShell7ForChild)
  $runnerPath = New-ToolkitTestNodeSuiteRunner -SkillDirectory $standalone.SkillDirectory

  $result = Invoke-ToolkitTestNode -NodePath $node -TimeoutSeconds 300 -WorkingDirectory $standalone.SkillDirectory -Arguments @($runnerPath)
  Assert-False ([bool]$result.TimedOut) ('the payload Node suite must exit on its own: ' + $result.Output)
  Assert-Equal 0 $result.ExitCode ('the payload Node suite must exit 0 with the baseline present: ' + $result.Output)
  Assert-NotMatch $result.Output 'maintainer-only: no external baseline provided' 'the baseline comparison must actually run when a baseline is supplied'
}
