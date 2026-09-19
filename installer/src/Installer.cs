// ---------------------------------------------------------------------------
//  Codex x DSH Team Toolkit - thin installer shell.
//
//  Deliberately tiny and single purpose:
//    * locate the release package (from its own location, or --package);
//    * pick the target project (--target, a positional path, or the Windows folder picker);
//    * show the install plan produced by the shared PowerShell engine;
//    * ask for confirmation;
//    * invoke the same engine and forward its exit code.
//
//  It contains no Monitor, Team or DSH logic and makes no ownership decision itself.
//  Every ownership, transaction and path decision lives in install/Invoke-Toolkit.ps1, which
//  is testable. This shell is a package-root launcher: it is never installed into a user
//  project and is never recorded in an ownership ledger.
//
//  C# 5 compatible so the Windows in-box csc.exe can build it (framework-dependent).
// ---------------------------------------------------------------------------
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

// The thin shell is version-aligned with the release it ships in (v1.1.0). No SDK or extra
// dependency is needed for this: version metadata is compiled straight into the EXE.
[assembly: AssemblyTitle("Codex x DSH Team Toolkit Installer")]
[assembly: AssemblyDescription("Thin installer shell: locates the package and the project, shows the plan, calls the shared PowerShell engine.")]
[assembly: AssemblyProduct("Codex x DSH Team Toolkit")]
[assembly: AssemblyCompany("Codex x DSH Team Toolkit contributors")]
[assembly: AssemblyCopyright("MIT licensed")]
[assembly: AssemblyVersion("1.1.0.0")]
[assembly: AssemblyFileVersion("1.1.0.0")]
[assembly: System.Runtime.InteropServices.ComVisible(false)]

internal static class Program
{
    private const string EngineRelativePath = @"install\Invoke-Toolkit.ps1";
    private const string ReleaseManifestFileName = "release-manifest.json";
    private const string InstallerFileName = "CodexDshTeamToolkit.Install.exe";

    private static bool guiMode = false;

    [STAThread]
    private static int Main(string[] args)
    {
        bool confirmed = false;
        bool planOnly = false;
        bool noUi = false;
        string target = null;
        string packageRoot = null;

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
            else if ((argument == "--package" || argument == "-p" || argument == "-PackageRoot" || argument == "/package") && i + 1 < args.Length)
            {
                packageRoot = args[++i];
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

        // Unattended runs (--yes / --no-ui) never open a modal dialog: an error must surface as
        // an exit code plus stderr, never as a window that blocks a script.
        bool unattended = confirmed || noUi;
        bool hasConsole = HasConsoleWindow();
        guiMode = !unattended && !hasConsole;

        string exePath;
        try
        {
            exePath = Assembly.GetExecutingAssembly().Location;
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

        // 1) the package is where this EXE lives, unless --package says otherwise. It is never
        //    inferred from the target project: the installer EXE is a package-root launcher.
        string package = null;
        if (!string.IsNullOrEmpty(packageRoot))
        {
            package = Path.GetFullPath(packageRoot);
            if (!Directory.Exists(package))
            {
                Fail("The package directory does not exist:\r\n" + package);
                return 3;
            }
        }
        else
        {
            package = exeDirectory;
        }

        string enginePath = Path.Combine(package, EngineRelativePath);
        if (!File.Exists(enginePath) || !File.Exists(Path.Combine(package, ReleaseManifestFileName)))
        {
            Fail("This executable must run from the root of an extracted release package.\r\n\r\nExpected:\r\n" +
                 enginePath + "\r\n" + Path.Combine(package, ReleaseManifestFileName) +
                 "\r\n\r\nRun it from the extracted package directory, or pass --package <dir>.");
            return 5;
        }

        // 2) the target project: --target / positional, else the folder picker
        string projectRoot = null;
        if (!string.IsNullOrEmpty(target))
        {
            try
            {
                projectRoot = Path.GetFullPath(target);
            }
            catch (Exception)
            {
                Fail("The target path is not valid:\r\n" + target);
                return 3;
            }
            if (!Directory.Exists(projectRoot))
            {
                Fail("The target project directory does not exist:\r\n" + projectRoot);
                return 3;
            }
        }
        else if (unattended)
        {
            Fail("No target project was supplied. Pass --target <project> (a folder picker is never shown in unattended mode).");
            return 2;
        }
        else
        {
            projectRoot = SelectFolder();
            if (string.IsNullOrEmpty(projectRoot))
            {
                Console.WriteLine("Cancelled by the user: no target selected, nothing was written.");
                return 0;
            }
        }

        string powerShellHost = FindPowerShellHost();
        if (powerShellHost == null)
        {
            Fail("No PowerShell host found (pwsh.exe or Windows PowerShell 5.1). Nothing was written.");
            return 2;
        }

        // 3) ask the engine for the plan first - the engine makes every decision
        string planFile = Path.Combine(Path.GetTempPath(), "codex-dsh-team-toolkit-install-" + Guid.NewGuid().ToString("n") + ".txt");
        int planExit = RunEngine(powerShellHost, enginePath, projectRoot, package, planFile, true, false);
        string planText = ReadTextIfExists(planFile);
        TryDelete(planFile);

        if (planExit != 0)
        {
            Fail("The toolkit refused to plan the install (exit code " + planExit + ").\r\n\r\n" + planText);
            return planExit;
        }

        if (planOnly)
        {
            Console.WriteLine(planText);
            return 0;
        }

        // 4) confirm with the plan in front of the user; default answer is No
        if (!confirmed)
        {
            string prompt = "Codex x DSH Team Toolkit - install\r\n\r\n" + planText +
                            "\r\nInstall the toolkit files listed above into:\r\n" + projectRoot +
                            "\r\n\r\nUser files and unknown files are never overwritten.";
            if (guiMode)
            {
                DialogResult answer = MessageBox.Show(prompt, "Install Codex x DSH Team Toolkit",
                    MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
                if (answer != DialogResult.Yes)
                {
                    Console.WriteLine("Cancelled by the user: nothing was written.");
                    return 0;
                }
            }
            else
            {
                Console.WriteLine(planText);
                Console.Write("Type YES to install the files listed above: ");
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

        // 5) run the real install and forward the exit code
        string outputFile = Path.Combine(Path.GetTempPath(), "codex-dsh-team-toolkit-install-" + Guid.NewGuid().ToString("n") + ".txt");
        int exitCode = RunEngine(powerShellHost, enginePath, projectRoot, package, outputFile, false, true);
        string output = ReadTextIfExists(outputFile);
        TryDelete(outputFile);
        Console.WriteLine(output);

        if (exitCode != 0)
        {
            Fail("The install did not complete (exit code " + exitCode + ").\r\n\r\n" + output);
            return exitCode;
        }

        // No residual mechanism: this executable is a package-root launcher and is never
        // installed into the project, so there is nothing to clean up here.
        return 0;
    }

    private static void ShowUsage()
    {
        Console.WriteLine(InstallerFileName + " [--target <project>] [--package <dir>] [--yes] [--no-ui] [--plan-only]");
        Console.WriteLine("  --target <project>  project root (or pass it as a positional argument)");
        Console.WriteLine("  --package <dir>     extracted release package (default: this executable's directory)");
        Console.WriteLine("  --yes               unattended: no dialog, engine confirmation is implied");
        Console.WriteLine("  --no-ui             never open a dialog (errors go to stderr)");
        Console.WriteLine("  --plan-only         show the install plan and write nothing");
        Console.WriteLine("  --help              show this help");
    }

    private static string SelectFolder()
    {
        try
        {
            using (FolderBrowserDialog dialog = new FolderBrowserDialog())
            {
                dialog.Description = "Select the existing project root to install the Codex x DSH Team Toolkit into";
                dialog.ShowNewFolderButton = false;
                DialogResult answer = dialog.ShowDialog();
                if (answer != DialogResult.OK)
                {
                    return null;
                }
                return dialog.SelectedPath;
            }
        }
        catch (Exception error)
        {
            Fail("The folder picker could not be shown (" + error.Message + ").\r\nPass --target <project> explicitly.");
            return null;
        }
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

    private static int RunEngine(string powerShellHost, string enginePath, string projectRoot, string package,
        string outputFile, bool planOnly, bool confirmed)
    {
        // The engine is always invoked with -NonInteractive: this shell owns any user
        // interaction (folder picker, plan display, confirmation) and the engine never prompts.
        StringBuilder arguments = new StringBuilder();
        arguments.Append("-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ");
        arguments.Append(Quote(enginePath));
        arguments.Append(" -Action Install -Target ");
        arguments.Append(Quote(projectRoot));
        arguments.Append(" -PackageRoot ");
        arguments.Append(Quote(package));
        arguments.Append(" -OutputFile ");
        arguments.Append(Quote(outputFile));
        if (planOnly)
        {
            arguments.Append(" -PlanOnly");
        }
        else if (confirmed)
        {
            arguments.Append(" -Yes");
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powerShellHost;
        startInfo.Arguments = arguments.ToString();
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WorkingDirectory = package;

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

    private static bool HasConsoleWindow()
    {
        try
        {
            return ConsoleWindow.GetConsoleWindow() != IntPtr.Zero;
        }
        catch (Exception)
        {
            return false;
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
            MessageBox.Show(message, "Codex x DSH Team Toolkit - install", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        catch (Exception)
        {
        }
    }
}

internal static class ConsoleWindow
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    internal static extern IntPtr GetConsoleWindow();
}