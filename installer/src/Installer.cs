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
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
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
        guiMode = !unattended && !planOnly;

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

        if (guiMode)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (InstallerWindow window = new InstallerWindow(package, target, FindPowerShellHost(), exeDirectory))
            {
                Application.Run(window);
                return window.ResultCode;
            }
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

internal sealed class InstallerWindow : Form
{
    private readonly string packageRoot, powerShellHost, exeDirectory;
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

    internal InstallerWindow(string packageRoot, string initialTarget, string powerShellHost, string exeDirectory)
    {
        this.packageRoot = packageRoot;
        this.powerShellHost = powerShellHost;
        this.exeDirectory = exeDirectory;
        Text = "Codex × DSH Team Toolkit · 安装";
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
        header.Controls.Add(new Label { Text = "让 Codex 带队，让 DSH 分担任务", Font = new Font(Font.FontFamily, 20F, FontStyle.Bold), AutoSize = true, Location = new Point(0, 3) });
        header.Controls.Add(new Label { Text = "Codex × DSH Team Toolkit  /  v1.1.0", ForeColor = Color.FromArgb(100, 116, 139), AutoSize = true, Location = new Point(2, 48) });
        root.Controls.Add(header, 0, 0);

        var features = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
        foreach (string text in new string[] { "01  通用团队规则", "02  DSH 角色边界", "03  调用与任务监控" })
            features.Controls.Add(new Label { Text = text, AutoSize = true, Padding = new Padding(13, 8, 13, 8), Margin = new Padding(0, 0, 10, 0), BackColor = Color.White, ForeColor = Accent });
        root.Controls.Add(features, 0, 1);

        var directory = new TableLayoutPanel { Dock = DockStyle.Fill, BackColor = Color.White, Padding = new Padding(16, 10, 16, 10), RowCount = 3, ColumnCount = 2, Margin = new Padding(0, 0, 0, 12) };
        directory.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        directory.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 106));
        directory.RowStyles.Add(new RowStyle(SizeType.Absolute, 22));
        directory.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
        directory.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        var pathLabel = new Label { Text = "安装到你的项目", AutoSize = true, Font = new Font(Font, FontStyle.Bold) };
        directory.Controls.Add(pathLabel, 0, 0);
        directory.SetColumnSpan(pathLabel, 2);
        targetPathInput = new TextBox { Name = "targetPathInput", Dock = DockStyle.Fill, Margin = new Padding(0, 3, 10, 3), BorderStyle = BorderStyle.FixedSingle, Text = initialTarget ?? "" };
        browseButton = MakeButton("browseButton", "浏览…", false);
        browseButton.Dock = DockStyle.Fill;
        browseButton.Margin = new Padding(0);
        directory.Controls.Add(targetPathInput, 0, 1);
        directory.Controls.Add(browseButton, 1, 1);
        var hint = new Label { Text = "选择一个已有文件夹，空白项目也可以直接安装。", AutoSize = true, ForeColor = Color.FromArgb(100, 116, 139), Margin = new Padding(0, 3, 0, 0) };
        directory.Controls.Add(hint, 0, 2);
        directory.SetColumnSpan(hint, 2);
        root.Controls.Add(directory, 0, 2);

        statusPanel = new Panel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(238, 242, 255), Margin = new Padding(0, 0, 0, 8), Padding = new Padding(15, 9, 15, 9) };
        statusLabel = new Label { Name = "statusLabel", Text = "选择项目，准备开始", Font = new Font(Font.FontFamily, 12F, FontStyle.Bold), Dock = DockStyle.Top, Height = 25, ForeColor = Accent };
        detailLabel = new Label { Name = "detailLabel", Text = "先检查安装清单，确认后再写入文件。", Dock = DockStyle.Fill, Padding = new Padding(0, 5, 0, 0) };
        statusPanel.Controls.Add(detailLabel);
        statusPanel.Controls.Add(statusLabel);
        root.Controls.Add(statusPanel, 0, 3);
        progressBar = new ProgressBar { Name = "progressBar", Dock = DockStyle.Fill, Margin = new Padding(0, 1, 0, 9), Maximum = 100 };
        root.Controls.Add(progressBar, 0, 4);

        var logs = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, BackColor = Color.White, Padding = new Padding(14, 9, 14, 10), Margin = new Padding(0) };
        logs.RowStyles.Add(new RowStyle(SizeType.Absolute, 27));
        logs.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        logs.Controls.Add(new Label { Text = "安装日志", AutoSize = true, Font = new Font(Font, FontStyle.Bold) }, 0, 0);
        logBox = new TextBox { Name = "logBox", Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, BorderStyle = BorderStyle.None, BackColor = Color.White, ForeColor = Color.FromArgb(71, 85, 105), Font = new Font("Consolas", 9F), WordWrap = true };
        logs.Controls.Add(logBox, 0, 1);
        root.Controls.Add(logs, 0, 5);

        var footer = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, WrapContents = false, Padding = new Padding(0, 14, 0, 0), Margin = new Padding(0) };
        installButton = MakeButton("installButton", "检查安装", true);
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
        Log("欢迎使用。选择项目后，点击“检查安装”。");
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
        FormClosing += delegate(object sender, FormClosingEventArgs e) {
            if (busy) { e.Cancel = true; detailLabel.Text = "正在处理安装，请等待完成后再关闭窗口。"; }
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
        installButton.Text = "检查安装";
        progressBar.Value = 0;
        SetStatus("选择项目，准备开始", "检查通过后，还需要点击“开始安装”进行确认。", false);
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
        SetStatus("未完成安装", message + "（错误码 " + code + "）", true);
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
        if (!File.Exists(Path.Combine(packageRoot, @"install\Invoke-Toolkit.ps1")) || !File.Exists(Path.Combine(packageRoot, "release-manifest.json"))) {
            ShowFailure(5, "安装包不完整，请完整解压 ZIP 后重新打开安装程序。"); return;
        }
        if (string.IsNullOrEmpty(powerShellHost)) { ShowFailure(2, "未找到可用的 PowerShell。"); return; }
        bool preview = !planned || !string.Equals(target, plannedTarget, StringComparison.OrdinalIgnoreCase);
        plannedTarget = target;
        SetBusy(true);
        State = preview ? "checking" : "installing";
        SetStatus(preview ? "正在检查安装" : "正在安装", preview ? "正在核对文件清单，此步骤不会写入项目。" : "正在准备文件，请保持窗口打开。", false);
        progressBar.Value = 0;
        progressBar.Style = ProgressBarStyle.Marquee;
        Log(preview ? "开始检查安装包与项目目录。" : "已确认安装，开始处理文件。");
        Task.Factory.StartNew(() => RunEngine(target, preview)).ContinueWith(task => OnUi(delegate {
            SetBusy(false);
            progressBar.Style = ProgressBarStyle.Continuous;
            if (task.IsFaulted) { ShowFailure(6, "安装进程发生异常，请查看日志后重试。"); return; }
            EngineResult result = task.Result;
            if (result.Code != 0) { ShowFailure(result.Code, "请查看下方日志中的原因，处理后重新检查。"); return; }
            ResultCode = 0;
            if (preview) {
                planned = true;
                State = "ready";
                progressBar.Value = 0;
                installButton.Text = "开始安装";
                SetStatus("检查通过，可以安装", "请核对项目路径与日志中的文件清单，再点击“开始安装”。", false);
                Log("检查通过。尚未写入项目，等待你确认安装。");
            } else {
                installed = true;
                State = "success";
                progressBar.Value = 100;
                SetStatus("安装完成", "首次使用前准备运行依赖和 DSH 配置，然后在项目中运行 start_dsh_team.cmd。", false);
                statusLabel.ForeColor = Color.FromArgb(21, 128, 61);
                statusPanel.BackColor = Color.FromArgb(240, 253, 244);
                installButton.Visible = false;
                openProjectButton.Visible = true;
                closeButton.Text = "完成";
                AcceptButton = closeButton;
                SetBusy(false);
                Log("安装完成。三个 Skill 和启动入口已经准备好。");
            }
        }));
    }

    private void ReceiveLine(string line)
    {
        if (string.IsNullOrEmpty(line)) return;
        OnUi(delegate {
            if (!line.StartsWith("@@TK_PROGRESS@@|", StringComparison.Ordinal)) { Log(line); return; }
            string[] parts = line.Split('|');
            int done, total;
            if (parts.Length != 4 || !int.TryParse(parts[2], out done) || !int.TryParse(parts[3], out total) || done < 0 || total < done) return;
            string label; int start, span;
            switch (parts[1]) {
                case "preflight": label = "检查安装条件"; start = 0; span = 8; break;
                case "stage": label = "准备安装文件"; start = 8; span = 42; break;
                case "apply": label = "写入项目文件"; start = 50; span = 25; break;
                case "verify": label = "核对安装结果"; start = 75; span = 18; break;
                case "commit": label = "完成安装记录"; start = 93; span = 4; break;
                case "rollback": SetStatus("正在恢复项目", "安装未完成，正在恢复本次修改。", true); Log("正在恢复本次安装修改。"); return;
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
            // EncodedCommand avoids shell interpolation of a pasted path and makes PS 5.1
            // use UTF-8 on its redirected stdout/stderr just like PowerShell 7.
            string command = "$ProgressPreference = 'SilentlyContinue'; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); & " + PsQuote(Path.Combine(packageRoot, @"install\Invoke-Toolkit.ps1")) +
                " -Action Install -Target " + PsQuote(target) + " -PackageRoot " + PsQuote(packageRoot) +
                " -OutputFile " + PsQuote(outputFile) + " -NonInteractive -Progress" + (preview ? " -PlanOnly" : " -Yes") +
                " *>&1 | ForEach-Object { [Console]::WriteLine([string]$_) }; exit $LASTEXITCODE";
            var info = new ProcessStartInfo(powerShellHost, "-NoProfile -NonInteractive -OutputFormat Text -ExecutionPolicy Bypass -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(command))) {
                UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = packageRoot,
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
            ReceiveLine("无法启动或读取安装进程，请检查 PowerShell 和安装包。");
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
            dialog.SetTitle("选择要安装工具包的项目文件夹");
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

internal static class ConsoleWindow
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    internal static extern IntPtr GetConsoleWindow();
}
