#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Prepare', 'RemoveDependencies', 'Start', 'Discover', 'Stop')][string]$Action,
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
function Assert-ProjectStopped {
    if (@(Get-MonitorProcesses | Where-Object { $_.workspace -eq $workspacePath }).Count -gt 0) {
        Write-Output '此项目的 Monitor 后台仍在运行，请先点击“停止后台”，再安装或卸载依赖。'
        throw 'Monitor is running'
    }
}
function Enter-ProjectOperation {
    param([string]$CommonPath)
    if ($PackageRoot) {
        $CommonPath = Join-Path $PackageRoot 'payload\.agents\skills\mcp-to-dsh\scripts\DshTeamCommon.ps1'
    }
    . $CommonPath
    return Enter-DshWorkspaceLaunch -Workspace $workspacePath
}
function Assert-DependencyTarget {
    # The only removable target is this project's skill-local dependency tree.
    # Reject redirected ancestors before reading manifests or traversing children.
    $expected = [IO.Path]::GetFullPath((Join-Path $workspacePath '.agents\skills\mcp-to-dsh\node_modules'))
    if ($modules -ne $expected -or -not $modules.StartsWith($workspacePath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Dependency target is outside the selected project'
    }
    $probe = $modules
    while ($probe) {
        if (Test-Path -LiteralPath $probe) {
            $item = Get-Item -LiteralPath $probe -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Write-Output '依赖路径经过目录联接或符号链接，已停止操作，避免影响其他目录。'
                throw 'Redirected dependency path'
            }
        }
        $probe = [IO.Path]::GetDirectoryName($probe)
    }
    $manifest = Get-Content -LiteralPath (Join-Path $skill 'package.json') -Raw | ConvertFrom-Json
    if ($manifest.name -ne 'mcp-to-dsh-skill' -or -not (Test-Path -LiteralPath (Join-Path $skill 'package-lock.json') -PathType Leaf)) {
        Write-Output '项目工具包不完整，请先安装或修复工具包。'
        throw 'Not a toolkit dependency directory'
    }
}
$operationLock = $null
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
    $modules = [IO.Path]::GetFullPath((Join-Path $skill 'node_modules'))
    switch ($Action) {
        Install {
            Assert-ProjectStopped
            $operationLock = Enter-ProjectOperation -CommonPath (Join-Path $PackageRoot 'payload\.agents\skills\mcp-to-dsh\scripts\DshTeamCommon.ps1')
            Assert-ProjectStopped
            & (Join-Path $PackageRoot 'install\Invoke-Toolkit.ps1') -Action Install -Target $workspacePath -PackageRoot $PackageRoot -NonInteractive -Yes -Progress
            exit $LASTEXITCODE
        }
        Prepare {
            Assert-ProjectStopped
            Assert-DependencyTarget
            $operationLock = Enter-ProjectOperation -CommonPath (Join-Path $skill 'scripts\DshTeamCommon.ps1')
            Assert-ProjectStopped
            Write-Output '项目文件已就绪。接下来安装固定版本的 DSH 及依赖；有 npm 缓存时优先复用。'
            $npm = Get-Command npm.cmd -ErrorAction Stop
            & $npm.Source ci --prefix $skill --prefer-offline --no-audit --no-fund
            exit $LASTEXITCODE
        }
        RemoveDependencies {
            Assert-ProjectStopped
            Assert-DependencyTarget
            $operationLock = Enter-ProjectOperation -CommonPath (Join-Path $skill 'scripts\DshTeamCommon.ps1')
            Assert-ProjectStopped
            if (-not (Test-Path -LiteralPath $modules)) {
                Write-Output '此项目没有 DSH 运行依赖，无需卸载。'
                exit 0
            }
            if (-not (Test-Path -LiteralPath $modules -PathType Container)) { throw 'Dependency target is not a directory' }
            Write-Output '正在检查所选项目的依赖目录。'
            # Check the entire subtree without following junctions/symlinks.
            $pending = New-Object 'System.Collections.Generic.Stack[string]'
            $pending.Push($modules)
            while ($pending.Count -gt 0) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
                    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                        Write-Output '依赖目录内含符号链接或目录联接，已保留全部内容，未执行卸载。'
                        throw 'Redirected dependency entry'
                    }
                    if ($entry.PSIsContainer) { $pending.Push($entry.FullName) }
                }
            }
            Assert-ProjectStopped
            Assert-DependencyTarget
            Write-Output '正在卸载 .agents/skills/mcp-to-dsh/node_modules。'
            Remove-Item -LiteralPath $modules -Recurse -Force
            if (Test-Path -LiteralPath $modules) { throw 'Dependency removal is incomplete' }
            Write-Output 'DSH 运行依赖已卸载。项目文件、Skill、用户配置和任务记录均保留。'
        }
        Start {
            # A Monitor may have started while npm was preparing the project. Do not
            # let the legacy bootstrap resync/restart a process owned by another caller.
            if (@(Get-MonitorProcesses | Where-Object { $_.workspace -eq $workspacePath }).Count -gt 0) {
                Write-Output 'Monitor 已在运行，保留现有连接。'
                exit 0
            }
            # Desktop owns the runtime location. An unrelated legacy shell's
            # REMOTE_TO_DSH_HOME must never become this application's write target.
            . (Join-Path $skill 'scripts\DshTeamCommon.ps1')
            $identity = Get-DshTeamInstallIdentity
            $teamHome = Join-Path (Get-DshTeamHomeRoot) $identity.InstallId
            Write-Output '正在使用工具包专用运行目录；所选 DSH 配置目录保持只读。'
            & (Join-Path $skill 'scripts\start_dsh_team.ps1') -Workspace $workspacePath -UserDshHome $UserDshHome `
                -TeamDshHome $teamHome -InstallId $identity.InstallId -InstallManifestPath $identity.ManifestPath `
                -SkipDshCheck -NoBrowser -NonInteractive
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
} finally {
    if ($operationLock) { $operationLock.Dispose() }
}
