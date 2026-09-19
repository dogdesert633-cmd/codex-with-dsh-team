#Requires -Version 5.1
<#
  Builds the thin, single-purpose installer EXE.

    pwsh -File installer/Build-Installer.ps1
    pwsh -File installer/Build-Installer.ps1 -OutputPath <path>

  Technology: C# 5 source compiled with the Windows in-box .NET Framework csc.exe
  (framework-dependent, a few tens of KB). The build is fail-visible: when no compiler
  is found the prerequisites are printed and the exit code is non-zero. No network access
  is used and no package restore is required.

  The EXE is only a shell: every ownership decision lives in install/Invoke-Toolkit.ps1.
  Its default output is the repository/package root, next to Install.cmd and the thin
  uninstaller EXE, because the installer is a package-root launcher.
#>
[CmdletBinding()]
param(
  [string]$OutputPath = '',
  [string]$ToolkitRoot = '',
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($ToolkitRoot)) { $ToolkitRoot = Split-Path -Parent $PSScriptRoot }
$ToolkitRoot = [System.IO.Path]::GetFullPath($ToolkitRoot)

# reuse the engine's durable-write helper (single implementation, no duplicate IO code)
. (Join-Path $ToolkitRoot 'install\Invoke-Toolkit.ps1') -Library

$sourcePath = Join-Path $PSScriptRoot 'src\Installer.cs'
if ([string]::IsNullOrEmpty($OutputPath)) {
  # package root: the installer EXE ships next to Install.cmd, never inside a user project
  $OutputPath = Join-Path $ToolkitRoot 'CodexDshTeamToolkit.Install.exe'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

function Write-BuildLine {
  param([string]$Text, [string]$Level = 'Info')
  if ($Quiet -and $Level -eq 'Info') { return }
  switch ($Level) {
    'Error' { Write-Host $Text -ForegroundColor Red }
    'Warn' { Write-Host $Text -ForegroundColor Yellow }
    default { Write-Host $Text }
  }
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
  Write-BuildLine ('Installer source not found: ' + $sourcePath) 'Error'
  exit 1
}

function Resolve-CSharpCompiler {
  $candidates = New-Object System.Collections.ArrayList
  if (-not [string]::IsNullOrEmpty($env:WINDIR)) {
    [void]$candidates.Add((Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'))
    [void]$candidates.Add((Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))
  }
  $onPath = Get-Command -Name 'csc.exe' -ErrorAction SilentlyContinue
  if ($null -ne $onPath) { [void]$candidates.Add($onPath.Source) }
  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrEmpty($candidate) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
      return $candidate
    }
  }
  return ''
}

$compiler = Resolve-CSharpCompiler
if ([string]::IsNullOrEmpty($compiler)) {
  Write-BuildLine 'No C# compiler found; the thin installer EXE cannot be built.' 'Error'
  Write-BuildLine 'Prerequisites:'
  Write-BuildLine '  * Windows with the .NET Framework 4.x installed (ships with Windows 10/11).'
  Write-BuildLine '  * Expected compiler: %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  Write-BuildLine '  * Or put csc.exe on PATH.'
  Write-BuildLine 'No release package can be produced until this EXE exists (a placeholder is never substituted).' 'Error'
  exit 1
}

$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
  New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}
if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force }

Write-BuildLine ('Compiler : ' + $compiler)
Write-BuildLine ('Source   : ' + $sourcePath)
Write-BuildLine ('Output   : ' + $OutputPath)

# The shell is pinned to the C# 5 language level (the in-box .NET Framework compiler is a C# 5
# compiler). /deterministic is used when the resolved compiler supports it; the in-box
# pre-Roslyn csc does not, and that must not fail the build.
$compilerHelp = ''
try { $compilerHelp = (& $compiler '/help' 2>&1 | Out-String) } catch { $compilerHelp = '' }
$supportsLangVersion = ($compilerHelp -match '/langversion')
$supportsDeterministic = ($compilerHelp -match '/deterministic')

$arguments = @(
  '/nologo',
  '/target:winexe',
  '/platform:anycpu',
  '/optimize+',
  '/warn:4',
  '/reference:System.dll',
  '/reference:System.Drawing.dll',
  '/reference:System.Windows.Forms.dll',
  ('/out:' + $OutputPath),
  $sourcePath
)
if ($supportsLangVersion) { $arguments = @('/langversion:5') + $arguments }
if ($supportsDeterministic) { $arguments = @('/deterministic') + $arguments }

Write-BuildLine ('Flags    : ' + (($arguments | Where-Object { $_ -like '/*' }) -join ' '))
if (-not $supportsLangVersion) {
  Write-BuildLine 'This compiler does not accept /langversion; C# 5 is its native default.' 'Warn'
}

$compilerOutput = & $compiler @arguments 2>&1
$exitCode = $LASTEXITCODE
foreach ($line in @($compilerOutput)) { if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Write-BuildLine ([string]$line) } }

$langVersionValue = 'compiler-default'
if ($supportsLangVersion) { $langVersionValue = '5' }

$report = [ordered]@{
  schema        = 'codex-dsh-team-toolkit/installer-build/v1'
  builtAtUtc    = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  compilerPath  = $compiler
  langVersion   = $langVersionValue
  deterministic = [bool]$supportsDeterministic
  fileVersion   = '1.1.0.0'
  exitCode      = $exitCode
  succeeded     = ($exitCode -eq 0 -and (Test-Path -LiteralPath $OutputPath -PathType Leaf))
  outputName    = [System.IO.Path]::GetFileName($OutputPath)
  outputPath    = $OutputPath
  sizeBytes     = 0
}
# No digest is recorded: this report is local build residue, not a verification artefact.
# Freshness is decided from timestamps (see Test-ReleaseInstallerFreshness).
if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
  $report.sizeBytes = (Get-Item -LiteralPath $OutputPath).Length
}
Write-ToolkitTextFileDurable -Path (Join-Path $PSScriptRoot 'build-report.json') -Content ((ConvertTo-Json -InputObject (New-Object -TypeName psobject -Property $report) -Depth 4) + [Environment]::NewLine)

if ($exitCode -ne 0) {
  Write-BuildLine ('csc.exe failed with exit code ' + $exitCode + '.') 'Error'
  exit $exitCode
}
if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
  Write-BuildLine 'csc.exe reported success but produced no output file.' 'Error'
  exit 1
}
$sizeBytes = (Get-Item -LiteralPath $OutputPath).Length
Write-BuildLine ('Built ' + [System.IO.Path]::GetFileName($OutputPath) + ' (' + $sizeBytes + ' bytes, framework-dependent).')
exit 0