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
        $items += [pscustomobject]@{ workspace = $path; pid = [int]$process.ProcessId }
    }
    return $items
}
try {
    if ($Action -eq 'Discover') {
        ConvertTo-Json -InputObject @(Get-MonitorProcesses) -Compress
        exit 0
    }
    $workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
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
            $recordPath = Join-Path $workspacePath 'artifacts\dsh-monitor\server.json'
            if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
                $record = [IO.File]::ReadAllText($recordPath) | ConvertFrom-Json
                $running = @(Get-MonitorProcesses | Where-Object { $_.pid -eq [int]$record.pid -and $_.workspace -eq $workspacePath })
                if ($running.Count -gt 0) {
                    Write-Output 'Monitor 已在运行，保留现有连接。'
                    exit 0
                }
            }
            & (Join-Path $skill 'scripts\start_dsh_team.ps1') -Workspace $workspacePath -UserDshHome $UserDshHome -SkipDshCheck -NoBrowser -NonInteractive
            exit $LASTEXITCODE
        }
        Stop {
            $record = [IO.File]::ReadAllText((Join-Path $workspacePath 'artifacts\dsh-monitor\server.json')) | ConvertFrom-Json
            if ([int]$record.pid -ne $MonitorProcessId -or $MonitorProcessId -le 0 -or $record.workspace -ne $workspacePath) { throw 'Monitor identity changed' }
            $owned = @(Get-MonitorProcesses | Where-Object { $_.pid -eq $MonitorProcessId -and $_.workspace -eq $workspacePath })
            if ($owned.Count -ne 1) { throw 'Monitor process does not match this project' }
            Stop-Process -Id $MonitorProcessId -ErrorAction Stop
            Write-Output 'Monitor 已停止。'
        }
    }
} catch {
    # Never echo a raw command line, credentials or arbitrary PowerShell exception text.
    [Console]::Error.WriteLine('操作未完成。请检查项目位置、Node/npm、DSH 配置和 Monitor 状态。')
    exit 1
}
