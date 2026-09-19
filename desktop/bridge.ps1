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
            Write-Output '项目文件已就绪。接下来安装固定版本的 DSH 及依赖；有 npm 缓存时优先复用。'
            $npm = Get-Command npm.cmd -ErrorAction Stop
            & $npm.Source ci --prefix $skill --prefer-offline --no-audit --no-fund
            exit $LASTEXITCODE
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
            # Keep the legacy launcher's interface, but use literal Win32 paths
            # when PowerShell's Start-Process would expand brackets in log paths.
            function Start-Process {
                [CmdletBinding()]
                param([string]$FilePath, [string[]]$ArgumentList, [string]$WorkingDirectory,
                      [string]$WindowStyle, [string]$RedirectStandardOutput,
                      [string]$RedirectStandardError, [switch]$PassThru)
                $forward = @{}
                foreach ($key in $PSBoundParameters.Keys) { $forward[$key] = $PSBoundParameters[$key] }
                if (($WorkingDirectory + $RedirectStandardOutput + $RedirectStandardError).IndexOfAny([char[]]'[]') -lt 0) {
                    Microsoft.PowerShell.Management\Start-Process @forward
                    return
                }
                if (-not ('DshDesktopLiteralProcess' -as [type])) {
                    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
public static class DshDesktopLiteralProcess {
    [StructLayout(LayoutKind.Sequential)] struct Security {
        public int size; public IntPtr descriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool inherit;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct Startup {
        public int size; public string reserved, desktop, title;
        public int x, y, width, height, xChars, yChars, fill, flags;
        public short show, reservedSize; public IntPtr reserved2, input, output, error;
    }
    [StructLayout(LayoutKind.Sequential)] struct Info {
        public IntPtr process, thread; public int pid, tid;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx {
        public Startup startup; public IntPtr attributes;
    }
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute,
        IntPtr value, IntPtr size, IntPtr previous, IntPtr returnedSize);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, ref Security security,
                                    uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processSecurity,
        IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string cwd,
        ref StartupEx startup, out Info info);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    static void Close(IntPtr handle) {
        if (handle != IntPtr.Zero && handle != new IntPtr(-1)) CloseHandle(handle);
    }
    static IntPtr Open(string path, bool input) {
        Security security = new Security { size=Marshal.SizeOf(typeof(Security)), inherit=true };
        IntPtr handle = CreateFileW(path, input ? 0x80000000u : 0x40000000u, 3,
                                   ref security, input ? 3u : 2u, 0x80, IntPtr.Zero);
        if (handle == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }
    public static Process Start(string app, string args, string cwd, string stdout, string stderr) {
        StartupEx start = new StartupEx();
        start.startup = new Startup { size=Marshal.SizeOf(typeof(StartupEx)), flags=0x101, show=0 };
        Info info = new Info();
        IntPtr handles = IntPtr.Zero;
        bool initialized = false;
        try {
            start.startup.input=Open("NUL", true);
            start.startup.output=Open(stdout, false);
            start.startup.error=Open(stderr, false);
            IntPtr size = IntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
            start.attributes = Marshal.AllocHGlobal(size);
            if (!InitializeProcThreadAttributeList(start.attributes, 1, 0, ref size))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            initialized = true;
            handles = Marshal.AllocHGlobal(3 * IntPtr.Size);
            Marshal.WriteIntPtr(handles, 0, start.startup.input);
            Marshal.WriteIntPtr(handles, IntPtr.Size, start.startup.output);
            Marshal.WriteIntPtr(handles, 2 * IntPtr.Size, start.startup.error);
            // Inherit ONLY the explicit standard handles. Inheriting PowerShell's
            // own output pipe would prevent the desktop from seeing completion.
            if (!UpdateProcThreadAttribute(start.attributes, 0, new IntPtr(0x20002), handles,
                new IntPtr(3 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            // No shell, no console; only the Node process inherits these log handles.
            if (!CreateProcessW(app, new StringBuilder("\"" + app + "\" " + args),
                IntPtr.Zero, IntPtr.Zero, true, 0x08080000, IntPtr.Zero, cwd, ref start, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            Process process = Process.GetProcessById(info.pid);
            IntPtr retained = process.Handle;
            return process;
        } finally {
            Close(info.thread); Close(info.process);
            if (initialized) DeleteProcThreadAttributeList(start.attributes);
            if (start.attributes != IntPtr.Zero) Marshal.FreeHGlobal(start.attributes);
            if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
            Close(start.startup.input); Close(start.startup.output); Close(start.startup.error);
        }
    }
}
'@
                }
                $process = [DshDesktopLiteralProcess]::Start($FilePath, ($ArgumentList -join ' '), $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError)
                if ($PassThru) { $process } else { $process.Dispose() }
            }
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
}
