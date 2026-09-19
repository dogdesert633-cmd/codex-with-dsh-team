#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Prepare', 'Start', 'Discover', 'Stop')][string]$Action,
    [string]$Workspace,
    [string]$PackageRoot,
    [string]$UserDshHome,
    [int]$MonitorProcessId
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
function Get-MonitorProcesses {
    $items = @()
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='node.exe'")) {
        $command = [string]$process.CommandLine
        if ($command -notmatch '[\\/]server\.mjs(?:"|\s)') { continue }
        $match = [regex]::Match($command, '(?:^|\s)--workspace\s+(?:"([^"]+)"|(\S+))')
        if (-not $match.Success) { continue }
        $path = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        $scriptMatch = [regex]::Match($command, '(?:^|\s)(?:"([^"]*[\\/]server\.mjs)"|(\S*[\\/]server\.mjs))(?=\s|$)')
        if (-not $scriptMatch.Success -or -not [IO.Path]::IsPathRooted($path)) { continue }
        $scriptPath = if ($scriptMatch.Groups[1].Success) { $scriptMatch.Groups[1].Value } else { $scriptMatch.Groups[2].Value }
        $path = [IO.Path]::GetFullPath($path).TrimEnd('\')
        $expectedScript = Join-Path $path '.agents\skills\mcp-to-dsh\src\server.mjs'
        if ([IO.Path]::GetFullPath($scriptPath) -ne $expectedScript) { continue }
        $items += [pscustomobject]@{ workspace = $path; pid = [int]$process.ProcessId; started = $process.CreationDate.ToUniversalTime().ToString('o') }
    }
    return $items
}
try {
    if ($Action -eq 'Discover') {
        ConvertTo-Json -InputObject @(Get-MonitorProcesses) -Compress
        exit 0
    }
    if ($Action -eq 'Stop') {
        if (-not [IO.Path]::IsPathRooted($Workspace)) { throw 'Workspace must be absolute' }
        $workspacePath = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
    } else {
        $workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
    }
    $skill = Join-Path $workspacePath '.agents\skills\mcp-to-dsh'
    switch ($Action) {
        Install {
            & (Join-Path $PackageRoot 'install\Invoke-Toolkit.ps1') -Action Install -Target $workspacePath -PackageRoot $PackageRoot -NonInteractive -Yes -Progress
            exit $LASTEXITCODE
        }
        Prepare {
            $npm = Get-Command npm.cmd -ErrorAction Stop
            & $npm.Source ci --prefix $skill
            exit $LASTEXITCODE
        }
        Start {
            # A Monitor may have started while npm was preparing the project. Do not
            # let the legacy bootstrap resync/restart a process owned by another caller.
            if (@(Get-MonitorProcesses | Where-Object { $_.workspace -eq $workspacePath }).Count -gt 0) {
                Write-Output 'Monitor 已在运行，保留现有连接。'
                exit 0
            }
            & (Join-Path $skill 'scripts\start_dsh_team.ps1') -Workspace $workspacePath -UserDshHome $UserDshHome -SkipDshCheck -NoBrowser -NonInteractive
            exit $LASTEXITCODE
        }
        Stop {
            # server.json may already have been deleted, or HTTP may be hung.
            # Local process identity is independent of both: exact workspace AND
            # the installed Monitor script path, followed by PID/start-time recheck.
            $owned = @(Get-MonitorProcesses | Where-Object { $_.workspace -eq $workspacePath })
            if ($MonitorProcessId -ne 0) {
                $owned = @($owned | Where-Object { $_.pid -eq $MonitorProcessId })
                if ($MonitorProcessId -lt 0 -or $owned.Count -ne 1) { throw 'Monitor process does not match this project' }
            }
            foreach ($entry in $owned) {
                $current = @(Get-MonitorProcesses | Where-Object { $_.pid -eq $entry.pid -and $_.workspace -eq $workspacePath -and $_.started -eq $entry.started })
                if ($current.Count -ne 1) { throw 'Monitor identity changed' }
                $processHandle = Get-Process -Id $entry.pid -ErrorAction Stop
                & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $entry.pid /T /F 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0 -or -not $processHandle.WaitForExit(10000)) { throw 'Monitor process tree did not exit' }
            }
            if (@(Get-MonitorProcesses | Where-Object { $_.workspace -eq $workspacePath }).Count -ne 0) { throw 'Monitor is still running' }
            # A successful kill request is not sufficient: prove the files can
            # actually be released before reporting success to the user.
            foreach ($logName in @('server-stdout.log', 'server-stderr.log')) {
                $logPath = Join-Path $workspacePath ('artifacts\dsh-monitor\' + $logName)
                $released = $false
                for ($attempt = 0; $attempt -lt 20; $attempt++) {
                    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) { $released = $true; break }
                    try {
                        $stream = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                        $stream.Dispose()
                        $released = $true
                        break
                    } catch { Start-Sleep -Milliseconds 100 }
                }
                if (-not $released) {
                    [Console]::Error.WriteLine('项目后台已退出，但日志仍被其他程序占用。请关闭查看日志的程序后重试。')
                    exit 1
                }
            }
            Write-Output '项目后台及其子进程已停止，日志文件占用已释放。'
        }
    }
} catch {
    # Never echo a raw command line, credentials or arbitrary PowerShell exception text.
    [Console]::Error.WriteLine('操作未完成。请检查项目位置、Node/npm、DSH 配置和 Monitor 状态。')
    exit 1
}
