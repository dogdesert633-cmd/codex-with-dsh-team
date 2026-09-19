#Requires -Version 5.1

Test-Case -Name 'installer progress: reports actual phases without changing plans, rollback or result objects' -Body {
  $base = New-ToolkitTestDirectory -Label 'progress'
  $package = New-ToolkitTestPackage -Root (Join-Path $base 'package')
  $project = New-ToolkitTestProject -Root (Join-Path $base 'project')
  $original = [Console]::Out
  $capture = New-Object IO.StringWriter
  try {
    [Console]::SetOut($capture)
    $plan = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; PlanOnly = $true; Progress = $true }
    $planProgress = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null
    $failed = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; Progress = $true; TestFault = 'install.after-stage'; TestMode = $true }
    $failedProgress = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null
    $success = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; Progress = $true }
    $successProgress = $capture.ToString()
    $capture.GetStringBuilder().Clear() | Out-Null
    $repeat = Invoke-ToolkitTestCommand -Options @{ Action = 'Install'; Target = $project; PackageRoot = $package.Root; PlanOnly = $true }
    $defaultProgress = $capture.ToString()
  } finally { [Console]::SetOut($original); $capture.Dispose() }
  Assert-Equal 0 $plan.ExitCode 'plan succeeds'
  Assert-Match $planProgress '@@TK_PROGRESS@@\|preflight\|1\|1' 'preflight is reported'
  Assert-NotMatch $planProgress '\|apply\|' 'plan never enters write phase'
  Assert-Equal $script:ExitTransaction $failed.ExitCode 'fault keeps transaction exit code'
  Assert-Match $failedProgress '\|rollback\|' 'rollback is visible'
  Assert-NotMatch $failedProgress '\|commit\|1\|1' 'failed transaction never reports commit success'
  Assert-Equal 0 $success.ExitCode 'successful installation keeps the result contract'
  Assert-Match $successProgress '\|stage\|' 'stage is visible'
  Assert-Match $successProgress '\|apply\|' 'apply is visible'
  Assert-Match $successProgress '\|verify\|' 'verification is visible'
  Assert-Match $successProgress '\|commit\|1\|1' 'commit is visible after completion'
  Assert-NotMatch (Get-ToolkitTestOutput $success) '@@TK_PROGRESS@@' 'protocol does not pollute returned messages'
  Assert-Equal '' $defaultProgress 'progress is opt-in'
  Assert-Equal 0 $repeat.ExitCode 'default invocation remains unchanged'
}
