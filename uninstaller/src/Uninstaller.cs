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
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Threading.Tasks;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

// The thin shell is version-aligned with the release it ships in (v1.3.1). No SDK or extra
// dependency is needed for this: version metadata is compiled straight into the EXE.
[assembly: AssemblyTitle("Codex x DSH Team Toolkit Uninstaller")]
[assembly: AssemblyDescription("Thin uninstaller shell: locates the project, shows the plan, calls the shared PowerShell engine.")]
[assembly: AssemblyProduct("Codex x DSH Team Toolkit")]
[assembly: AssemblyCompany("Codex x DSH Team Toolkit contributors")]
[assembly: AssemblyCopyright("MIT licensed")]
[assembly: AssemblyVersion("1.3.1.0")]
[assembly: AssemblyFileVersion("1.3.1.0")]
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

    [STAThread]
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
        guiMode = !unattended && !planOnly;

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
        if (guiMode)
        {
            string initialTarget = target;
            try { initialTarget = string.IsNullOrEmpty(target) ? (FindProjectRoot(exeDirectory) ?? exeDirectory) : Path.GetFullPath(target); }
            catch (Exception) { initialTarget = exeDirectory; }
            string initialEngine = FindEngine(initialTarget, exeDirectory);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (var window = new UninstallerWindow(initialEngine, initialTarget, FindPowerShellHost(), exePath))
            {
                Application.Run(window);
                return window.ResultCode;
            }
        }

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

        string engineCopy = Path.Combine(Path.GetTempPath(), "codex-dsh-uninstall-engine-" + Guid.NewGuid().ToString("n") + ".ps1");
        File.Copy(enginePath, engineCopy, false);
        enginePath = engineCopy;
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
            ScheduleSelfDelete(exePath, enginePath, projectRoot, powerShellHost);
        }
        TryDelete(engineCopy);
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

    internal static void ScheduleSelfDelete(string exePath, string enginePath, string projectRoot, string host)
    {
        // The same engine makes the final ownership decisions after this image exits.
        // Keep a temporary engine copy because the installed engine is itself removed.
        if (!IsUnder(exePath, projectRoot) || !File.Exists(enginePath)) return;
        string cleanup = Path.Combine(Path.GetTempPath(), "codex-dsh-uninstall-finish-" + Guid.NewGuid().ToString("n") + ".ps1");
        try
        {
            File.Copy(enginePath, cleanup, false);
            string command = "$ErrorActionPreference='Stop'; Wait-Process -Id " + Process.GetCurrentProcess().Id +
                " -ErrorAction SilentlyContinue; try { & " + PsQuote(cleanup) + " -Action Uninstall -Target " + PsQuote(projectRoot) +
                " -NonInteractive -Yes } finally { Remove-Item -LiteralPath " + PsQuote(cleanup) + " -Force }";
            var info = new ProcessStartInfo(host, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command))) {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = Path.GetTempPath()
            };
            using (Process process = Process.Start(info)) { }
        }
        catch (Exception) { Console.Error.WriteLine("卸载器自身的清理未完成，请保留卸载日志后重试。"); }
    }
    private static string PsQuote(string value) { return "'" + value.Replace("'", "''") + "'"; }

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

internal sealed class UninstallerWindow : Form
{
    private readonly string powerShellHost, exeDirectory, exePath, engineCopy;
    private string enginePath;
    private readonly TextBox targetPathInput, logBox;
    private readonly Button browseButton, installButton, openProjectButton, closeButton;
    private readonly Label statusLabel, detailLabel;
    private readonly ProgressBar progressBar;
    private readonly Panel statusPanel;
    private bool busy, planned, installed;
    private string plannedTarget;
    internal int ResultCode { get; private set; }
    internal string State { get; private set; }
    internal string InitialBrowsePath
    {
        get { return Directory.Exists(targetPathInput.Text) ? targetPathInput.Text : exeDirectory; }
    }
    private static readonly Color Accent = Color.FromArgb(79, 70, 229);
    private static readonly Color Ink = Color.FromArgb(30, 41, 59);

    internal UninstallerWindow(string enginePath, string initialTarget, string powerShellHost, string exePath)
    {
        this.enginePath = enginePath;
        this.exePath = exePath;
        this.engineCopy = Path.Combine(Path.GetTempPath(), "codex-dsh-uninstall-ui-" + Guid.NewGuid().ToString("n") + ".ps1");
        this.powerShellHost = powerShellHost;
        this.exeDirectory = Path.GetDirectoryName(exePath);
        Text = "Codex × DSH Team Toolkit · 卸载";
        Font = new Font("Microsoft YaHei UI", 9F);
        ForeColor = Ink;
        BackColor = Color.FromArgb(245, 247, 251);
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(900, 710);
        MinimumSize = new Size(800, 670);
        StartPosition = FormStartPosition.CenterScreen;
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(28, 20, 28, 18), ColumnCount = 1, RowCount = 7 };
        foreach (float height in new float[] { 84, 54, 108, 78, 26 }) root.RowStyles.Add(new RowStyle(SizeType.Absolute, height));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 60));
        Controls.Add(root);

        var header = new Panel { Dock = DockStyle.Fill };
        header.Controls.Add(new Label { Text = "卸载 Codex × DSH 工具包", Font = new Font(Font.FontFamily, 20F, FontStyle.Bold), AutoSize = true, Location = new Point(0, 3) });
        header.Controls.Add(new Label { Text = "Codex × DSH Team Toolkit  /  v1.3.1", ForeColor = Color.FromArgb(100, 116, 139), AutoSize = true, Location = new Point(2, 48) });
        root.Controls.Add(header, 0, 0);

        var features = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        foreach (string text in new string[] { "01  清理未修改文件", "02  保留你的改动", "03  完成后自动收尾" })
            features.Controls.Add(new Label { Text = text, AutoSize = true, Padding = new Padding(13, 8, 13, 8), Margin = new Padding(0, 0, 10, 0), BackColor = Color.White, ForeColor = Accent });
        root.Controls.Add(features, 0, 1);

        var directory = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(16, 10, 16, 10), RowCount = 3, ColumnCount = 2, Margin = new Padding(0, 0, 0, 12) };
        directory.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        directory.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 106));
        directory.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
        directory.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        directory.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var pathLabel = new Label { Text = "从所选项目卸载", AutoSize = true, Font = new Font(Font, FontStyle.Bold) };
        directory.Controls.Add(pathLabel, 0, 0);
        directory.SetColumnSpan(pathLabel, 2);
        targetPathInput = new TextBox { Name = "targetPathInput", Dock = DockStyle.Fill, Margin = new Padding(0, 3, 10, 3), BorderStyle = BorderStyle.FixedSingle, Text = initialTarget ?? "" };
        browseButton = MakeButton("browseButton", "浏览…", false);
        browseButton.Dock = DockStyle.Fill;
        browseButton.Margin = new Padding(0);
        directory.Controls.Add(targetPathInput, 0, 1);
        directory.Controls.Add(browseButton, 1, 1);
        var hint = new Label { Text = "清理工具包及未修改的运行依赖，保留原有文件和你的改动。", AutoSize = true, ForeColor = Color.FromArgb(100, 116, 139), Margin = new Padding(0, 3, 0, 0) };
        directory.Controls.Add(hint, 0, 2);
        directory.SetColumnSpan(hint, 2);
        root.Controls.Add(directory, 0, 2);

        statusPanel = new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(238, 242, 255), Margin = new Padding(0, 0, 0, 8), Padding = new Padding(15, 9, 15, 9) };
        statusLabel = new Label { Name = "statusLabel", Text = "选择项目，准备开始", Font = new Font(Font.FontFamily, 12F, FontStyle.Bold), Dock = DockStyle.Top, Height = 25, ForeColor = Accent };
        detailLabel = new Label { Name = "detailLabel", Text = "先查看清理范围，确认后再卸载。", Dock = DockStyle.Fill, Padding = new Padding(0, 5, 0, 0) };
        statusPanel.Controls.Add(detailLabel);
        statusPanel.Controls.Add(statusLabel);
        root.Controls.Add(statusPanel, 0, 3);
        progressBar = new ProgressBar { Name = "progressBar", Dock = DockStyle.Fill, Margin = new Padding(0, 1, 0, 9), Maximum = 100 };
        root.Controls.Add(progressBar, 0, 4);

        var logs = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, BackColor = Color.White, Padding = new Padding(14, 9, 14, 10), Margin = new Padding(0) };
        logs.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
        logs.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        logs.Controls.Add(new Label { Text = "卸载日志", AutoSize = true, Font = new Font(Font, FontStyle.Bold) }, 0, 0);
        logBox = new TextBox { Name = "logBox", Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, BackColor = Color.White, ForeColor = Color.FromArgb(71, 85, 105), Font = new Font("Consolas", 9F), WordWrap = true };
        logs.Controls.Add(logBox, 0, 1);
        root.Controls.Add(logs, 0, 5);

        var footer = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new Padding(0, 14, 0, 0), Margin = new Padding(0) };
        installButton = MakeButton("installButton", "检查卸载", true);
        closeButton = MakeButton("closeButton", "取消", false);
        openProjectButton = MakeButton("openProjectButton", "打开项目文件夹", false);
        openProjectButton.Width = 156;
        openProjectButton.Visible = false;
        footer.Controls.Add(installButton);
        footer.Controls.Add(closeButton);
        footer.Controls.Add(openProjectButton);
        root.Controls.Add(footer, 0, 6);
        AcceptButton = installButton;
        State = "idle";
        Log("欢迎使用。选择项目后，点击“检查卸载”。");
        targetPathInput.TextChanged += delegate { if (!busy && !installed) ResetPlan(); };
        browseButton.Click += delegate {
            try {
                string selected = ProjectFolderBrowser.Select(this, InitialBrowsePath);
                if (!string.IsNullOrEmpty(selected)) targetPathInput.Text = selected;
            } catch (Exception) { ShowFailure(3, "无法打开文件夹浏览器，请在输入框中粘贴项目路径。"); }
        };
        installButton.Click += delegate { BeginOperation(); };
        closeButton.Click += delegate { Close(); };
        openProjectButton.Click += delegate {
            try { Process.Start(new ProcessStartInfo(plannedTarget) { UseShellExecute = true }); }
            catch (Exception) { Log("无法打开文件夹，请复制上方项目路径，在资源管理器中打开。"); }
        };
        FormClosed += delegate {
            if (installed) Program.ScheduleSelfDelete(exePath, engineCopy, plannedTarget, powerShellHost);
            try { if (File.Exists(engineCopy)) File.Delete(engineCopy); } catch (Exception) { }
        };
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (busy) { e.Cancel = true; detailLabel.Text = "正在处理卸载，请等待完成后再关闭窗口。"; }
        };
    }

    private static Button MakeButton(string name, string text, bool primary)
    {
        return new FlatInstallerButton { Name = name, Text = text, Width = 126, Height = 38,
            Primary = primary, BackColor = primary ? Accent : Color.White,
            ForeColor = primary ? Color.White : Ink, Margin = new Padding(10, 0, 0, 0),
            Cursor = Cursors.Hand, AccessibleName = text };
    }

    private void ResetPlan()
    {
        planned = false;
        State = "idle";
        ResultCode = 0;
        installButton.Text = "检查卸载";
        progressBar.Value = 0;
        SetStatus("选择项目，准备开始", "检查通过后，还需要点击“开始卸载”进行确认。", false);
    }

    private void SetStatus(string title, string detail, bool error)
    {
        statusLabel.Text = title;
        detailLabel.Text = detail;
        statusLabel.ForeColor = error ? Color.FromArgb(185, 28, 28) : Accent;
        statusPanel.BackColor = error ? Color.FromArgb(254, 242, 242) : Color.FromArgb(238, 242, 255);
    }

    private void ShowFailure(int code, string message)
    {
        ResultCode = code;
        State = "failed";
        planned = false;
        progressBar.Style = ProgressBarStyle.Continuous;
        progressBar.Value = 0;
        SetStatus("未完成卸载", message + "（错误码 " + code + "）", true);
        installButton.Text = "重新检查";
        Log(message + "（错误码 " + code + "）");
    }

    private void Log(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        if (logBox.TextLength > 60000) logBox.Text = logBox.Text.Substring(logBox.TextLength - 30000);
        logBox.AppendText(DateTime.Now.ToString("HH:mm:ss") + "  " + text + Environment.NewLine);
        logBox.SelectionStart = logBox.TextLength;
        logBox.ScrollToCaret();
    }

    private void OnUi(Action action)
    {
        if (IsDisposed || Disposing) return;
        try { BeginInvoke(action); } catch (InvalidOperationException) { }
    }

    private void SetBusy(bool value)
    {
        busy = value;
        targetPathInput.ReadOnly = value || installed;
        browseButton.Enabled = !value && !installed;
        installButton.Enabled = !value;
        closeButton.Enabled = !value;
    }

    private void BeginOperation()
    {
        if (busy || installed) return;
        string target;
        try {
            if (string.IsNullOrWhiteSpace(targetPathInput.Text) || !Path.IsPathRooted(targetPathInput.Text.Trim()))
                throw new IOException();
            target = Path.GetFullPath(targetPathInput.Text.Trim());
            if (!Directory.Exists(target)) throw new IOException();
        } catch (Exception) { ShowFailure(3, "请选择一个存在的项目文件夹。"); return; }
        string selectedEngine = Path.Combine(target, @".codex-dsh-team-toolkit\engine\Invoke-Toolkit.ps1");
        if (File.Exists(selectedEngine)) enginePath = selectedEngine;
        if (!File.Exists(enginePath) || !File.Exists(Path.Combine(target, @".codex-dsh-team-toolkit\manifest.json"))) {
            ShowFailure(5, "未找到项目的卸载记录或引擎，请确认项目目录。"); return;
        }
        if (string.IsNullOrEmpty(powerShellHost)) { ShowFailure(2, "未找到可用的 PowerShell。"); return; }
        bool preview = !planned || !string.Equals(target, plannedTarget, StringComparison.OrdinalIgnoreCase);
        plannedTarget = target;
        SetBusy(true);
        State = preview ? "checking" : "uninstalling";
        SetStatus(preview ? "正在检查卸载" : "正在卸载", preview ? "正在核对文件清单，此步骤不会写入项目。" : "正在准备文件，请保持窗口打开。", false);
        progressBar.Value = 0;
        progressBar.Style = ProgressBarStyle.Marquee;
        Log(preview ? "开始检查卸载包与项目目录。" : "已确认卸载，开始处理文件。");
        Task.Factory.StartNew(() => RunEngine(target, preview)).ContinueWith(task => OnUi(delegate {
            SetBusy(false);
            progressBar.Style = ProgressBarStyle.Continuous;
            if (task.IsFaulted) { ShowFailure(6, "卸载进程发生异常，请查看日志后重试。"); return; }
            EngineResult result = task.Result;
            if (result.Code != 0) { ShowFailure(result.Code, "请查看下方日志中的原因，处理后重新检查。"); return; }
            ResultCode = 0;
            if (preview) {
                planned = true;
                State = "ready";
                progressBar.Value = 0;
                installButton.Text = "开始卸载";
                SetStatus("检查通过，可以卸载", "请核对项目路径与日志中的文件清单，再点击“开始卸载”。", false);
                Log("检查通过。尚未删除任何文件，等待你确认卸载。");
            } else {
                installed = true;
                State = "success";
                progressBar.Value = 100;
                SetStatus("卸载完成", "点击“完成”后清理卸载器自身。保留文件及原因请查看下方日志。", false);
                statusLabel.ForeColor = Color.FromArgb(21, 128, 61);
                statusPanel.BackColor = Color.FromArgb(240, 253, 244);
                installButton.Visible = false;
                openProjectButton.Visible = true;
                closeButton.Text = "完成";
                AcceptButton = closeButton;
                SetBusy(false);
                Log("未修改的工具包文件已清理；修改过或未登记的文件会保留并列在日志中。");
            }
        }));
    }

    private static string TranslateLine(string line)
    {
        string[,] labels = {
            { "Managed files to delete (ownership proven):", "将清理的未修改文件：" },
            { "Files kept because ownership cannot be proven:", "本轮保留的文件（含正在运行的卸载器）：" },
            { "Managed files already absent:", "已经不存在的文件：" },
            { "Untracked content that will be kept (never deleted):", "未登记的内容，将保留：" },
            { "Target project :", "所选项目：" }, { "Mode           :", "处理方式：" },
            { "Deleted managed files:", "已清理文件：" }, { "Removed empty directories:", "已清理空目录：" },
            { "  delete   ", "  清理  " }, { "  keep     ", "  保留  " }
        };
        for (int i = 0; i < labels.GetLength(0); i++)
            if (line.StartsWith(labels[i, 0], StringComparison.Ordinal)) return labels[i, 1] + line.Substring(labels[i, 0].Length);
        if (line == "User-added and unknown files are never deleted; directories are removed only when empty.") return "你额外添加或未登记的文件会保留；仅清理工具包创建的空目录。";
        if (line == "Plan-only mode: nothing was written.") return "检查完成：没有写入或删除任何文件。";
        return line;
    }
    private void ReceiveLine(string line)
    {
        if (string.IsNullOrEmpty(line)) return;
        OnUi(delegate {
            if (!line.StartsWith("@@TK_PROGRESS@@|", StringComparison.Ordinal)) { Log(TranslateLine(line)); return; }
            string[] parts = line.Split('|');
            int done, total;
            if (parts.Length != 4 || !int.TryParse(parts[2], out done) || !int.TryParse(parts[3], out total) || done < 0 || total < done) return;
            string label; int start, span;
            switch (parts[1]) {
                case "preflight": label = "检查卸载条件"; start = 0; span = 8; break;
                case "stage": label = "核对文件原始内容"; start = 8; span = 42; break;
                case "apply": label = "清理未修改的文件"; start = 50; span = 25; break;
                case "verify": label = "核对卸载结果"; start = 75; span = 18; break;
                case "commit": label = "清理卸载记录"; start = 93; span = 4; break;
                case "rollback": SetStatus("正在恢复项目", "卸载未完成，正在恢复本次修改。", true); Log("正在恢复本次卸载修改。"); return;
                default: return;
            }
            detailLabel.Text = label + (total > 0 ? "  " + done + " / " + total : "");
            if (total > 0) {
                progressBar.Style = ProgressBarStyle.Continuous;
                progressBar.Value = Math.Max(progressBar.Value, Math.Min(97, start + span * done / total));
            }
            Log(detailLabel.Text);
        });
    }

    private EngineResult RunEngine(string target, bool preview)
    {
        string outputFile = Path.Combine(Path.GetTempPath(), "codex-dsh-installer-" + Guid.NewGuid().ToString("n") + ".txt");
        try {
            if (preview || !File.Exists(engineCopy)) File.Copy(enginePath, engineCopy, true);
            // EncodedCommand avoids shell interpolation of a pasted path and makes PS 5.1
            // use UTF-8 on its redirected stdout/stderr just like PowerShell 7.
            string command = "$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); & " + PsQuote(engineCopy) +
                " -Action Uninstall -Target " + PsQuote(target) + " -UninstallerSelf " + PsQuote(exePath) +
                " -OutputFile " + PsQuote(outputFile) + " -NonInteractive -Progress" + (preview ? " -PlanOnly" : " -Yes") +
                " *>&1 | ForEach-Object { [Console]::WriteLine([string]$_) }; exit $LASTEXITCODE";
            var info = new ProcessStartInfo(powerShellHost, "-NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command))) {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = target,
                RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8
            };
            using (var process = new Process { StartInfo = info }) {
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { ReceiveLine(e.Data); };
                process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { ReceiveLine(e.Data); };
                process.Start();
                process.BeginOutputReadLine(); process.BeginErrorReadLine();
                process.WaitForExit();
                return new EngineResult { Code = process.ExitCode };
            }
        } catch (Exception) {
            ReceiveLine("无法启动或读取卸载进程，请检查 PowerShell 和卸载包。");
            return new EngineResult { Code = 6 };
        } finally {
            try { if (File.Exists(outputFile)) File.Delete(outputFile); } catch (Exception) { }
        }
    }
    private static string PsQuote(string value) { return "'" + value.Replace("'", "''") + "'"; }
    private sealed class EngineResult { internal int Code; }
}

internal sealed class FlatInstallerButton : Button
{
    internal bool Primary;
    internal FlatInstallerButton() { FlatStyle = FlatStyle.Flat; FlatAppearance.BorderSize = 0; }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        var rect = new Rectangle(1, 1, Width - 3, Height - 3);
        using (var path = new GraphicsPath()) {
            const int d = 12;
            path.AddArc(rect.Left, rect.Top, d, d, 180, 90);
            path.AddArc(rect.Right - d, rect.Top, d, d, 270, 90);
            path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
            path.AddArc(rect.Left, rect.Bottom - d, d, d, 90, 90); path.CloseFigure();
            using (var brush = new SolidBrush(Enabled ? BackColor : Color.FromArgb(226, 232, 240))) e.Graphics.FillPath(brush, path);
            using (var pen = new Pen(Primary ? BackColor : Color.FromArgb(203, 213, 225))) e.Graphics.DrawPath(pen, path);
        }
        TextRenderer.DrawText(e.Graphics, Text, Font, rect, Enabled ? ForeColor : Color.FromArgb(148, 163, 184), TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
        if (Focused && ShowFocusCues) ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(rect, -5, -5));
    }
}

internal static class ProjectFolderBrowser
{
    internal static string Select(IWin32Window owner, string initialDirectory)
    {
        IFileDialog dialog = null; IShellItem initial = null, result = null;
        try {
            dialog = (IFileDialog)new FileOpenDialog();
            uint options; dialog.GetOptions(out options);
            dialog.SetOptions(options | 0x20U | 0x40U | 0x800U | 0x8U | 0x2000000U);
            dialog.SetTitle("选择要卸载工具包的项目文件夹");
            dialog.SetOkButtonLabel("选择此文件夹");
            Guid iid = typeof(IShellItem).GUID;
            Marshal.ThrowExceptionForHR(SHCreateItemFromParsingName(initialDirectory, IntPtr.Zero, ref iid, out initial));
            dialog.SetDefaultFolder(initial); dialog.SetFolder(initial);
            int hr = dialog.Show(owner.Handle);
            if (hr == unchecked((int)0x800704C7)) return null;
            Marshal.ThrowExceptionForHR(hr);
            dialog.GetResult(out result);
            IntPtr path; result.GetDisplayName(0x80058000U, out path);
            try { return Marshal.PtrToStringUni(path); } finally { Marshal.FreeCoTaskMem(path); }
        } catch (COMException) {
            using (var fallback = new FolderBrowserDialog { Description = "选择项目文件夹", SelectedPath = initialDirectory, ShowNewFolderButton = false })
                return fallback.ShowDialog(owner) == DialogResult.OK ? fallback.SelectedPath : null;
        } finally {
            if (result != null) Marshal.ReleaseComObject(result);
            if (initial != null) Marshal.ReleaseComObject(initial);
            if (dialog != null) Marshal.ReleaseComObject(dialog);
        }
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IShellItem item);
    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    private class FileOpenDialog { }
    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint count, IntPtr specs); void SetFileTypeIndex(uint index); void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie); void Unadvise(uint cookie);
        void SetOptions(uint options); void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item); void SetFolder(IShellItem item); void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name); void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void GetResult(out IShellItem item); void AddPlace(IShellItem item, uint location);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result); void SetClientGuid(ref Guid guid); void ClearClientData(); void SetFilter(IntPtr filter);
    }
    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint type, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }
}
