// ---------------------------------------------------------------------------
//  Codex x DSH Team Toolkit - thin uninstaller shell.
//
//  Deliberately tiny and single purpose:
//    * locate the project root (from its own installed location, or --target);
//    * show the uninstall plan produced by the shared PowerShell engine;
//    * ask for confirmation;
//    * invoke the same engine and forward its exit code.
//
//  It contains no Monitor, Team or DSH logic and makes no delete decision itself.
//  Every ownership decision lives in install/Invoke-Toolkit.ps1, which is testable.
//
//  C# 5 compatible so the Windows in-box csc.exe can build it (framework-dependent).
// ---------------------------------------------------------------------------
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// The thin shell is version-aligned with the release it ships in (v1.0.0). No SDK or extra
// dependency is needed for this: version metadata is compiled straight into the EXE.
[assembly: AssemblyTitle("Codex x DSH Team Toolkit Uninstaller")]
[assembly: AssemblyDescription("Thin uninstaller shell: locates the project, shows the plan, calls the shared PowerShell engine.")]
[assembly: AssemblyProduct("Codex x DSH Team Toolkit")]
[assembly: AssemblyCompany("Codex x DSH Team Toolkit contributors")]
[assembly: AssemblyCopyright("MIT licensed")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: ComVisible(false)]

internal static class Program
{
    private const string StateDirectoryName = ".codex-dsh-team-toolkit";
    private const string EngineFileName = "Invoke-Toolkit.ps1";
    private const string ManifestFileName = "manifest.json";
    private const string UninstallerFileName = "CodexDshTeamToolkit.Uninstall.exe";
    private const int SearchDepth = 8;

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    private static bool guiMode = false;

    private static int Main(string[] args)
    {
        bool confirmed = false;
        bool planOnly = false;
        bool noUi = false;
        string target = null;

        for (int i = 0; i < args.Length; i++)
        {
            string argument = args[i];
            if (argument == "--yes" || argument == "-y" || argument == "/yes" || argument == "-Yes")
            {
                confirmed = true;
            }
            else if (argument == "--plan-only" || argument == "-planonly" || argument == "-PlanOnly")
            {
                planOnly = true;
            }
            else if (argument == "--no-ui" || argument == "-noui" || argument == "-NoUi")
            {
                noUi = true;
            }
            else if ((argument == "--target" || argument == "-t" || argument == "-Target" || argument == "/target") && i + 1 < args.Length)
            {
                target = args[++i];
            }
            else if (argument == "--help" || argument == "-h" || argument == "-?" || argument == "/?")
            {
                ShowUsage();
                return 0;
            }
            else if (target == null && argument.Length > 0 && argument[0] != '-')
            {
                target = argument;
            }
        }

        // Unattended runs (--yes / --no-ui) never open a modal dialog: an error must
        // surface as an exit code plus stderr, never as a window that blocks a script.
        bool unattended = confirmed || noUi;
        bool hasConsole = GetConsoleWindow() != IntPtr.Zero;
        guiMode = !unattended && !hasConsole;

        string exePath;
        try
        {
            exePath = System.Reflection.Assembly.GetExecutingAssembly().Location;
        }
        catch (Exception)
        {
            exePath = Application.ExecutablePath;
        }
        if (string.IsNullOrEmpty(exePath))
        {
            exePath = Application.ExecutablePath;
        }
        exePath = Path.GetFullPath(exePath);
        string exeDirectory = Path.GetDirectoryName(exePath);

        string projectRoot = null;
        if (!string.IsNullOrEmpty(target))
        {
            string candidate = Path.GetFullPath(target);
            if (!Directory.Exists(candidate))
            {
                Fail("The target project directory does not exist:\r\n" + candidate);
                return 3;
            }
            projectRoot = candidate;
        }
        else
        {
            projectRoot = FindProjectRoot(exeDirectory);
            if (projectRoot == null)
            {
                Fail("Could not find a project owning this uninstaller.\r\n\r\nLooked for a " +
                     StateDirectoryName + "\\" + ManifestFileName + " next to or above:\r\n" + exeDirectory +
                     "\r\n\r\nRun it with --target <project> if the project was moved.");
                return 3;
            }
        }

        string enginePath = FindEngine(projectRoot, exeDirectory);
        if (enginePath == null)
        {
            Fail("The toolkit engine was not found. Expected:\r\n" +
                 Path.Combine(Path.Combine(projectRoot, StateDirectoryName), Path.Combine("engine", EngineFileName)) +
                 "\r\n\r\nThe install may be incomplete; nothing was deleted.");
            return 5;
        }

        string powerShellHost = FindPowerShellHost();
        if (powerShellHost == null)
        {
            Fail("No PowerShell host found (pwsh.exe or Windows PowerShell 5.1). Nothing was deleted.");
            return 2;
        }

        // 1) ask the engine for the plan first - the engine makes every decision
        string planFile = Path.Combine(Path.GetTempPath(), "codex-dsh-team-toolkit-uninstall-" + Guid.NewGuid().ToString("n") + ".txt");
        int planExit = RunEngine(powerShellHost, enginePath, projectRoot, exePath, planFile, true);
        string planText = ReadTextIfExists(planFile);
        TryDelete(planFile);

        if (planExit != 0)
        {
            Fail("The toolkit refused to plan the uninstall (exit code " + planExit + ").\r\n\r\n" + planText);
            return planExit;
        }

        if (planOnly)
        {
            Console.WriteLine(planText);
            return 0;
        }

        // 2) confirm with the plan in front of the user; default answer is No
        if (!confirmed)
        {
            string prompt = "Codex x DSH Team Toolkit - uninstall\r\n\r\n" + planText +
                            "\r\nRemove the toolkit-managed files listed above?\r\n" +
                            "User-added and unmodified user files are never deleted.";
            if (guiMode)
            {
                DialogResult answer = MessageBox.Show(prompt, "Uninstall Codex x DSH Team Toolkit",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
                if (answer != DialogResult.Yes)
                {
                    Console.WriteLine("Cancelled by the user: nothing was written.");
                    return 0;
                }
            }
            else
            {
                Console.WriteLine(planText);
                Console.Write("Type YES to delete the managed files listed above: ");
                string answer = null;
                try { answer = Console.ReadLine(); }
                catch (Exception) { answer = null; }
                if (answer != "YES")
                {
                    Console.WriteLine("Cancelled: nothing was written. Re-run with --yes for unattended use.");
                    return 0;
                }
            }
        }

        // 3) run the real uninstall and forward the exit code
        string outputFile = Path.Combine(Path.GetTempPath(), "codex-dsh-team-toolkit-uninstall-" + Guid.NewGuid().ToString("n") + ".txt");
        int exitCode = RunEngine(powerShellHost, enginePath, projectRoot, exePath, outputFile, false);
        string output = ReadTextIfExists(outputFile);
        TryDelete(outputFile);
        Console.WriteLine(output);

        if (exitCode != 0)
        {
            Fail("The uninstall did not complete (exit code " + exitCode + ").\r\n\r\n" + output);
            return exitCode;
        }

        // 4) an installed EXE inside the project cannot delete itself while running:
        //    report it and schedule a minimal self-cleanup. A copy run from elsewhere
        //    (for example straight out of the release package) is left alone.
        if (File.Exists(exePath) && IsUnder(exePath, projectRoot))
        {
            Console.WriteLine("Residual: this uninstaller executable could not remove itself while running; " +
                              "it will be deleted now that it has exited.");
            Console.WriteLine("A tiny ownership record (.codex-dsh-team-toolkit\\manifest.json) is kept so the " +
                              "residual stays provable; it is safe to delete by hand once this executable is gone.");
            ScheduleSelfDelete(exePath);
        }
        return 0;
    }

    private static bool IsUnder(string path, string root)
    {
        try
        {
            string fullPath = Path.GetFullPath(path);
            string fullRoot = Path.GetFullPath(root).TrimEnd('\\') + "\\";
            return fullPath.StartsWith(fullRoot, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static void ShowUsage()
    {
        Console.WriteLine("CodexDshTeamToolkit.Uninstall.exe [--target <project>] [--yes] [--no-ui] [--plan-only]");
        Console.WriteLine("  --target <project>  project root (otherwise derived from this executable)");
        Console.WriteLine("  --yes               unattended: no dialog, engine confirmation is implied");
        Console.WriteLine("  --no-ui             never open a dialog (errors go to stderr)");
        Console.WriteLine("  --plan-only         show the uninstall plan and write nothing");
    }

    private static string FindProjectRoot(string startDirectory)
    {
        string current = startDirectory;
        for (int depth = 0; depth <= SearchDepth && !string.IsNullOrEmpty(current); depth++)
        {
            string stateDirectory = Path.Combine(current, StateDirectoryName);
            if (Directory.Exists(stateDirectory) && File.Exists(Path.Combine(stateDirectory, ManifestFileName)))
            {
                return current;
            }
            DirectoryInfo parent = Directory.GetParent(current);
            if (parent == null)
            {
                return null;
            }
            current = parent.FullName;
        }
        return null;
    }

    private static string FindEngine(string projectRoot, string exeDirectory)
    {
        string[] candidates = new string[]
        {
            Path.Combine(Path.Combine(projectRoot, StateDirectoryName), Path.Combine("engine", EngineFileName)),
            Path.Combine(Path.Combine(exeDirectory, StateDirectoryName), Path.Combine("engine", EngineFileName)),
            Path.Combine(exeDirectory, EngineFileName)
        };
        for (int i = 0; i < candidates.Length; i++)
        {
            if (File.Exists(candidates[i]))
            {
                return Path.GetFullPath(candidates[i]);
            }
        }
        return null;
    }

    private static string FindPowerShellHost()
    {
        string[] candidates = new string[]
        {
            FindOnPath("pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), @"PowerShell\7\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"PowerShell\7\pwsh.exe"),
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe")
        };
        for (int i = 0; i < candidates.Length; i++)
        {
            if (!string.IsNullOrEmpty(candidates[i]) && File.Exists(candidates[i]))
            {
                return candidates[i];
            }
        }
        return null;
    }

    private static string FindOnPath(string fileName)
    {
        string path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrEmpty(path))
        {
            return null;
        }
        string[] parts = path.Split(';');
        for (int i = 0; i < parts.Length; i++)
        {
            string directory = parts[i].Trim();
            if (directory.Length == 0)
            {
                continue;
            }
            try
            {
                string candidate = Path.Combine(directory, fileName);
                if (File.Exists(candidate))
                {
                    return candidate;
                }
            }
            catch (Exception)
            {
            }
        }
        return null;
    }

    private static int RunEngine(string powerShellHost, string enginePath, string projectRoot, string exePath,
        string outputFile, bool planOnly)
    {
        StringBuilder arguments = new StringBuilder();
        arguments.Append("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
        arguments.Append(Quote(enginePath));
        arguments.Append(" -Action Uninstall -Target ");
        arguments.Append(Quote(projectRoot));
        arguments.Append(" -UninstallerSelf ");
        arguments.Append(Quote(exePath));
        arguments.Append(" -OutputFile ");
        arguments.Append(Quote(outputFile));
        if (planOnly)
        {
            arguments.Append(" -PlanOnly");
        }
        else
        {
            arguments.Append(" -Yes");
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powerShellHost;
        startInfo.Arguments = arguments.ToString();
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WorkingDirectory = projectRoot;

        try
        {
            using (Process process = Process.Start(startInfo))
            {
                process.WaitForExit();
                return process.ExitCode;
            }
        }
        catch (Exception error)
        {
            Fail("Could not start the toolkit engine:\r\n" + error.Message);
            return 6;
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static string ReadTextIfExists(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                return File.ReadAllText(path, Encoding.UTF8);
            }
        }
        catch (Exception)
        {
        }
        return string.Empty;
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception)
        {
        }
    }

    private static void ScheduleSelfDelete(string exePath)
    {
        try
        {
            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
            startInfo.Arguments = "/c ping -n 3 127.0.0.1 > nul & del /f /q " + Quote(exePath);
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            Process.Start(startInfo);
        }
        catch (Exception)
        {
            Console.WriteLine("The uninstaller residual must be deleted manually: " + exePath);
        }
    }

    private static void Fail(string message)
    {
        try { Console.Error.WriteLine(message); }
        catch (Exception) { }
        if (!guiMode)
        {
            return;
        }
        try
        {
            MessageBox.Show(message, "Codex x DSH Team Toolkit - uninstall", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        catch (Exception)
        {
        }
    }
}
