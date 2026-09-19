param([Parameter(Mandatory=$true)][string]$PackagePath, [Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TestHarness.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[IO.Directory]::CreateDirectory($Output) | Out-Null
$project = Join-Path $Output ("中文 项目's [demo]-" + [Guid]::NewGuid().ToString('n'))
[IO.Directory]::CreateDirectory($project) | Out-Null
Write-ToolkitTestFile (Join-Path $project '我的文件.txt') 'keep original'
$result = Invoke-ToolkitTestCommand -Options @{Action='Install'; Target=$project; PackageRoot=$PackagePath}
Assert-Equal 0 $result.ExitCode (Get-ToolkitTestOutput $result)
$exe = Join-Path $PackagePath 'uninstaller\CodexDshTeamToolkit.Uninstall.exe'
if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $PackagePath 'CodexDshTeamToolkit.Uninstall.exe' }
$assembly = [Reflection.Assembly]::LoadFrom($exe)
$type = $assembly.GetType('UninstallerWindow', $true)
$flags = [Reflection.BindingFlags]'Instance,NonPublic,Public'
$constructor = $type.GetConstructors($flags)[0]
$hostPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
function Control($Form, $Name) { $Form.Controls.Find($Name, $true)[0] }
function State($Form) { $type.GetProperty('State', $flags).GetValue($Form, $null) }
function Capture($Form, $Name) {
  $bitmap = New-Object Drawing.Bitmap($Form.Width, $Form.Height)
  try { $Form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0,0,$Form.Width,$Form.Height))); $bitmap.Save((Join-Path $Output $Name), [Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
}
function Wait-State($Form, $Expected) {
  $deadline = [DateTime]::UtcNow.AddSeconds(90)
  $ticks = 0
  while ((State $Form) -in @('checking','uninstalling')) {
    [Windows.Forms.Application]::DoEvents()
    $ticks++
    if ([DateTime]::UtcNow -gt $deadline) { throw 'GUI timed out' }
    Start-Sleep -Milliseconds 20
  }
  Assert-Equal $Expected (State $Form) (Control $Form 'logBox').Text
  return $ticks
}
$form = $constructor.Invoke([object[]]@([string](Join-Path $PackagePath 'install\Invoke-Toolkit.ps1'), [string]$project, [string]$hostPath, [string]$exe))
try {
  $form.StartPosition = 'Manual'
  $form.Location = New-Object Drawing.Point(-30000, -30000)
  $form.ShowInTaskbar = $false
  $form.Show()
  [Windows.Forms.Application]::DoEvents()
  Capture $form 'uninstaller-initial.png'
  $before = Get-ToolkitTestTreeSnapshot $project
  (Control $form 'installButton').PerformClick()
  $checkTicks = Wait-State $form 'ready'
  Assert-Equal ($before -join ';') ((Get-ToolkitTestTreeSnapshot $project) -join ';') 'Preview must write nothing'
  Capture $form 'uninstaller-plan.png'
  (Control $form 'installButton').PerformClick()
  Assert-True (-not (Control $form 'installButton').Enabled) 'Prevent duplicate operations'
  $form.Close()
  Assert-True (-not $form.IsDisposed) 'Do not close during removal'
  $removeTicks = Wait-State $form 'success'
  Assert-Equal 100 (Control $form 'progressBar').Value
  Assert-Equal '卸载完成' (Control $form 'statusLabel').Text
  Assert-FileMissing (Join-Path $project '.codex-dsh-team-toolkit')
  Assert-FileMissing (Join-Path $project '.agents')
  Assert-Equal 'keep original' ([IO.File]::ReadAllText((Join-Path $project '我的文件.txt')))
  Assert-NotMatch (Control $form 'logBox').Text 'CLIXML|<Objs'
  Capture $form 'uninstaller-success.png'
  [IO.File]::WriteAllText((Join-Path $Output 'gui-log.txt'), (Control $form 'logBox').Text)
  (Control $form 'closeButton').PerformClick()
  Assert-True $form.IsDisposed 'Finish must close the window'
  @{status='PASS'; planWrites=0; checkUiTicks=$checkTicks; removalUiTicks=$removeTicks; cleanupComplete=$true; originalPreserved=$true} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Output 'gui-result.json') -Encoding UTF8
} finally { if (-not $form.IsDisposed) { $form.Dispose() } }
Get-Content -LiteralPath (Join-Path $Output 'gui-result.json')
$failed = $constructor.Invoke([object[]]@([string](Join-Path $PackagePath 'install\Invoke-Toolkit.ps1'), [string]$Output, [string]$hostPath, [string]$exe))
try {
  $failed.StartPosition = 'Manual'
  $failed.Location = New-Object Drawing.Point(-30000, -30000)
  $failed.ShowInTaskbar = $false
  $failed.Show()
  [Windows.Forms.Application]::DoEvents()
  (Control $failed 'installButton').PerformClick()
  Assert-Equal 'failed' (State $failed)
  Assert-True ((Control $failed 'progressBar').Value -ne 100) 'Failure must not appear complete'
  Capture $failed 'uninstaller-failure.png'
} finally { $failed.Dispose() }
