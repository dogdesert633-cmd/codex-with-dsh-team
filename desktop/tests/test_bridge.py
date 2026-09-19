"""Optional Windows package integration. No real DSH/model task is dispatched."""
import json
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend
from test_backend import protect, source_at


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="desktop-bridge-")
        self.root = Path(self.temp.name)
        self.workspace = self.root / "空白项目 [demo]"
        self.workspace.mkdir()
        self.addCleanup(self.temp.cleanup)

    def invoke(self, action, **kwargs):
        return subprocess.run(backend.bridge_command(action, self.workspace, **kwargs), capture_output=True,
                              timeout=90, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

    def dependency_fixture(self):
        skill = self.workspace / ".agents/skills/mcp-to-dsh"
        (skill / "node_modules/fixture").mkdir(parents=True)
        (skill / "package.json").write_text('{"name":"mcp-to-dsh-skill"}')
        (skill / "package-lock.json").write_text('{}')
        (skill / "node_modules/fixture/file.txt").write_text("dependency")
        (skill / "SKILL.md").write_text("keep skill")
        (skill / "scripts").mkdir()
        shutil.copy2(Path(__file__).resolve().parents[2] / "payload/.agents/skills/mcp-to-dsh/scripts/DshTeamCommon.ps1",
                     skill / "scripts/DshTeamCommon.ps1")
        (self.workspace / "node_modules").mkdir()
        (self.workspace / "node_modules/game.txt").write_text("keep project dependency")
        return skill

    def test_uninstall_only_skill_dependencies_and_is_repeatable_on_ps5_and_ps7(self):
        for shell in dict.fromkeys([backend.power_shell(), str(Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")]):
            with self.subTest(shell=shell):
                skill = self.workspace / ".agents/skills/mcp-to-dsh"
                if not skill.exists():
                    skill = self.dependency_fixture()
                else:
                    (skill / "node_modules").mkdir()
                    (skill / "node_modules/file.txt").write_text("dependency")
                for _ in range(2):
                    command = backend.bridge_command("RemoveDependencies", self.workspace)
                    command[0] = shell
                    result = subprocess.run(command, capture_output=True, timeout=25)
                    self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", "replace") + result.stderr.decode("utf-8", "replace"))
                    self.assertFalse((skill / "node_modules").exists())
                    self.assertEqual((skill / "SKILL.md").read_text(), "keep skill")
                    self.assertEqual((self.workspace / "node_modules/game.txt").read_text(), "keep project dependency")

    def test_uninstall_refuses_junction_before_removing_any_content(self):
        skill = self.dependency_fixture()
        other = self.root / "outside"
        other.mkdir()
        (other / "keep.txt").write_text("keep")
        link = skill / "node_modules/external"
        command = [backend.power_shell(), "-NoProfile", "-Command", "New-Item -ItemType Junction -Path $env:FIXTURE_LINK -Target $env:FIXTURE_TARGET | Out-Null"]
        with patch.dict(os.environ, {"FIXTURE_LINK": str(link), "FIXTURE_TARGET": str(other)}):
            subprocess.run(command, check=True, capture_output=True, timeout=20)
        try:
            result = self.invoke("RemoveDependencies")
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue((skill / "node_modules/fixture/file.txt").exists())
            self.assertEqual((other / "keep.txt").read_text(), "keep")
        finally:
            # Remove the junction itself, never traverse or delete the target.
            os.rmdir(link)

    @unittest.skipUnless(os.environ.get("DESKTOP_TEST_TOOLKIT_PACKAGE"), "Set DESKTOP_TEST_TOOLKIT_PACKAGE to test the complete bundle")
    def test_install_into_empty_non_git_project_preserves_user_files(self):
        package = Path(os.environ["DESKTOP_TEST_TOOLKIT_PACKAGE"])
        (self.workspace / "user-note.txt").write_text("用户原有文件", encoding="utf-8")
        result = self.invoke("Install", package=package)
        self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", "replace")[-2000:] + result.stderr.decode("utf-8", "replace"))
        self.assertIn(b"@@TK_PROGRESS@@|commit|1|1", result.stdout)
        for skill in ("mcp-to-dsh", "dsh-role-boundaries", "codex-team"):
            self.assertTrue((self.workspace / ".agents/skills" / skill / "SKILL.md").is_file())
        self.assertTrue((self.workspace / "CodexDshTeamToolkit.Uninstall.exe").is_file())
        self.assertEqual((self.workspace / "user-note.txt").read_text(encoding="utf-8"), "用户原有文件")
        self.assertFalse((self.workspace / ".git").exists())

    @unittest.skipUnless(os.environ.get("DESKTOP_TEST_TOOLKIT_PACKAGE") and os.environ.get("DESKTOP_TEST_PREVIOUS_PACKAGE"), "Set both package paths to test the existing-user update")
    def test_previous_release_updates_launchers_and_preserves_dependencies_and_user_files(self):
        previous = Path(os.environ["DESKTOP_TEST_PREVIOUS_PACKAGE"])
        current = Path(os.environ["DESKTOP_TEST_TOOLKIT_PACKAGE"])
        result = subprocess.run([backend.power_shell(), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
            str(previous / "install/Invoke-Toolkit.ps1"), "-Action", "Install", "-Target", str(self.workspace),
            "-PackageRoot", str(previous), "-NonInteractive", "-Yes"], capture_output=True, timeout=90)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode("utf-8", "replace"))
        note = self.workspace / "my-game.txt"
        note.write_text("keep game")
        skill = self.workspace / ".agents/skills/mcp-to-dsh"
        modules = skill / "node_modules"
        modules.mkdir()
        (modules / "keep.txt").write_text("keep installed dependency")
        removed = self.invoke("RemoveDependencies", package=current)
        self.assertEqual(removed.returncode, 0, (removed.stdout + removed.stderr).decode("utf-8", "replace"))
        self.assertFalse(modules.exists())
        self.assertTrue((skill / "SKILL.md").is_file())
        modules.mkdir()
        (modules / "keep.txt").write_text("keep installed dependency")
        result = self.invoke("Install", package=current)
        self.assertEqual(result.returncode, 0, (result.stdout + result.stderr).decode("utf-8", "replace"))
        self.assertEqual(backend.read_json(self.workspace / ".codex-dsh-team-toolkit/manifest.json")["version"], "1.3.0")
        self.assertEqual((skill / "scripts/start_dsh_team.ps1").read_bytes(),
                         (current / "payload/.agents/skills/mcp-to-dsh/scripts/start_dsh_team.ps1").read_bytes())
        self.assertEqual(note.read_text(), "keep game")
        self.assertEqual((modules / "keep.txt").read_text(), "keep installed dependency")

    def test_start_forwards_selected_source_without_model_check_on_ps5_and_ps7(self):
        script = self.workspace / ".agents/skills/mcp-to-dsh/scripts/start_dsh_team.ps1"
        script.parent.mkdir(parents=True)
        common = Path(__file__).resolve().parents[2] / 'payload/.agents/skills/mcp-to-dsh/scripts/DshTeamCommon.ps1'
        shutil.copy2(common, script.parent / common.name)
        script.write_text("""param([string]$Workspace,[string]$UserDshHome,[string]$TeamDshHome,[string]$InstallId,[string]$InstallManifestPath,[switch]$SkipDshCheck,[switch]$NoBrowser,[switch]$NonInteractive)
. (Join-Path $PSScriptRoot 'DshTeamCommon.ps1')
Assert-UserDshHomeReadOnlySource -UserDshHome $UserDshHome -TeamDshHome $TeamDshHome | Out-Null
$resolved = Resolve-DshTeamHome -Requested $TeamDshHome -Workspace $Workspace -InstallId $InstallId -AllowCreate
Push-Location -LiteralPath $Workspace
try {
    $node = Get-Command node.exe
    $probe = Start-DshMonitorProcess -FilePath $node.Source -ArgumentList '--version' -WorkingDirectory $Workspace -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Workspace 'probe-output.log') -RedirectStandardError (Join-Path $Workspace 'probe-error.log') -PassThru
    if (-not $probe.WaitForExit(10000)) { throw 'fixture did not exit' }
} catch { Write-Output ('FIXTURE: ' + $_.Exception.Message); throw } finally { Pop-Location }
@{ workspace=$Workspace; source=$UserDshHome; team=$resolved.TeamDshHome; manifest=$InstallManifestPath; skipCheck=[bool]$SkipDshCheck; noBrowser=[bool]$NoBrowser; nonInteractive=[bool]$NonInteractive } | ConvertTo-Json -Compress
exit 0
""", encoding="utf-8-sig")
        source = self.root / "用户配置"
        source.mkdir()
        (source / "settings.yaml").write_text("user: unchanged", encoding="utf-8")
        legacy = self.root / "旧 home-acp"
        legacy.mkdir()
        (legacy / "settings.yaml").write_text("legacy: unchanged", encoding="utf-8")
        candidates = [backend.power_shell(), str(Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")]
        for shell in dict.fromkeys(candidates):
            with self.subTest(shell=shell):
                command = backend.bridge_command("Start", self.workspace, source=source)
                command[0] = shell
                base = self.root / Path(shell).stem
                with patch.dict(os.environ, {"CODEX_DSH_TEAM_BASE_DIR": str(base), "REMOTE_TO_DSH_HOME": str(legacy)}):
                    result = subprocess.run(command, capture_output=True, timeout=25, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", "replace") + result.stderr.decode("utf-8", "replace"))
                data = json.loads(result.stdout.decode("utf-8-sig").splitlines()[-1])
                team, manifest = Path(data.pop("team")), Path(data.pop("manifest"))
                self.assertEqual(team.parent, base / "runtimes")
                self.assertEqual(manifest, base / "install.json")
                self.assertTrue((team / ".codex-dsh-team-home.json").is_file())
                self.assertTrue((self.workspace / "probe-output.log").read_text().startswith("v"))
                self.assertEqual(data, {"workspace": str(self.workspace), "source": str(source), "skipCheck": True, "noBrowser": True, "nonInteractive": True})
                self.assertEqual(list(source.iterdir()), [source / "settings.yaml"])
                self.assertEqual(list(legacy.iterdir()), [legacy / "settings.yaml"])
                self.assertEqual((source / "settings.yaml").read_text(), "user: unchanged")
                self.assertEqual((legacy / "settings.yaml").read_text(), "legacy: unchanged")

    @unittest.skipUnless(os.environ.get("DESKTOP_TEST_DSH_MODULES"), "Set DESKTOP_TEST_DSH_MODULES for offline real-launcher validation")
    def test_real_start_with_legacy_home_uses_owned_runtime_and_selected_default(self):
        skill = self.workspace / ".agents/skills/mcp-to-dsh"
        payload = Path(__file__).resolve().parents[2] / "payload/.agents/skills/mcp-to-dsh"
        shutil.copytree(payload, skill, ignore=shutil.ignore_patterns("node_modules"))
        shutil.copytree(os.environ["DESKTOP_TEST_DSH_MODULES"], skill / "node_modules")
        source = source_at(self.root / "用户 DSH 配置")
        (source / ".credentials.yaml").write_text("FIXTURE_API_KEY: fake-not-a-real-key\n", encoding="utf-8")
        source_before = {p.name: p.read_bytes() for p in source.iterdir()}
        legacy = source_at(self.root / "旧 home-acp")
        base = self.root / "桌面运行数据"
        with patch.dict(os.environ, {"CODEX_DSH_TEAM_BASE_DIR": str(base), "REMOTE_TO_DSH_HOME": str(legacy)}):
            try:
                started = self.invoke("Start", source=source)
                self.assertEqual(started.returncode, 0, started.stdout.decode("utf-8", "replace")[-5000:] + started.stderr.decode("utf-8", "replace"))
                state = backend.MonitorClient(self.workspace).snapshot()
                self.assertTrue(state["online"])
                self.assertEqual(state["settings"]["effective"], {"provider": "chosen-provider", "model": "chosen-model"})
                self.assertEqual(state["runs"], [])
                self.assertTrue(backend.same_path(state["health"]["dshUserHome"], source))
                team = Path(state["health"]["dshHome"])
                self.assertEqual(team.parent, base / "runtimes")
                self.assertTrue((team / ".codex-dsh-team-home.json").is_file())
                self.assertEqual(source_before, {p.name: p.read_bytes() for p in source.iterdir()})
                self.assertEqual(list(legacy.iterdir()), [legacy / "settings.yaml"])
            finally:
                stopped = self.invoke("Stop")
                self.assertEqual(stopped.returncode, 0, stopped.stderr.decode("utf-8", "replace"))

    @unittest.skipUnless(shutil.which("node"), "Node is required for the local process fixture")
    def test_discover_reuse_and_stop_only_owned_fixture_process(self):
        script = self.workspace / ".agents/skills/mcp-to-dsh/src/server.mjs"
        script.parent.mkdir(parents=True)
        # This process is a local HTTP fixture, not the actual DSH Monitor/agent.
        script.write_text("""import {createServer} from 'node:http';
import {join} from 'node:path';
const workspace = process.argv[process.argv.indexOf('--workspace') + 1];
const service = createServer((req,res) => {
  const body = req.url === '/api/health' ? {ok:true,service:'dsh-team-monitor',workspace,dshHome:join(workspace,'team')} : {};
  res.writeHead(200, {'Content-Type':'application/json'}); res.end(JSON.stringify(body));
});
service.listen(0,'127.0.0.1',()=>console.log(JSON.stringify({port:service.address().port})));
""", encoding="utf-8")
        child = subprocess.Popen([shutil.which("node"), str(script), "--workspace", str(self.workspace)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            data = json.loads(child.stdout.readline())
            record = {"workspace": str(self.workspace), "url": f"http://127.0.0.1:{data['port']}", "pid": child.pid,
                      "dsh_home": str(self.workspace / "team"), "token_scheme": "dpapi-current-user",
                      "access_token_protected": protect("fixture-desktop-token")}
            backend.atomic_json(self.workspace / "artifacts/dsh-monitor/server.json", record)
            self.assertIn(str(self.workspace), backend.discover_monitors())
            self.assertTrue(backend.MonitorClient(self.workspace).snapshot()["online"])
            for action in ("Install", "Prepare", "RemoveDependencies"):
                self.assertNotEqual(self.invoke(action).returncode, 0)
                self.assertIsNone(child.poll())
            # No installed launcher exists here: a successful Start must reuse the live process.
            self.assertEqual(self.invoke("Start", source=self.root).returncode, 0)
            self.assertIsNone(child.poll())
            command = backend.stop_command(self.workspace)
            stopped = subprocess.run(command, capture_output=True, timeout=25, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            self.assertEqual(stopped.returncode, 0)
            child.wait(timeout=8)
            self.assertIsNone(backend.existing_monitor(self.workspace))
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=8)
            child.stdout.close()
            child.stderr.close()

    @unittest.skipUnless(os.environ.get("DESKTOP_TEST_DSH_MODULES"), "Set DESKTOP_TEST_DSH_MODULES for direct launcher regression")
    def test_real_direct_launch_ignores_legacy_home_and_reuses_one_team_on_ps5_ps7(self):
        self.workspace = self.root / "直接启动 中文项目"
        self.workspace.mkdir()
        skill = self.workspace / ".agents/skills/mcp-to-dsh"
        payload = Path(__file__).resolve().parents[2] / "payload/.agents/skills/mcp-to-dsh"
        shutil.copytree(payload, skill, ignore=shutil.ignore_patterns("node_modules"))
        shutil.copytree(os.environ["DESKTOP_TEST_DSH_MODULES"], skill / "node_modules")
        source = source_at(self.root / "user-config")
        (source / ".credentials.yaml").write_text("FIXTURE_API_KEY: fake-not-a-real-key\n")
        legacy = source_at(self.root / "legacy-home")
        originals = {str(p): p.read_bytes() for directory in (source, legacy) for p in directory.iterdir()}
        hosts = list(dict.fromkeys([backend.power_shell(), str(Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")]))
        with patch.dict(os.environ, {"CODEX_DSH_TEAM_BASE_DIR": str(self.root / "isolated-base"), "REMOTE_TO_DSH_HOME": str(legacy)}):
            for shell in hosts:
                with self.subTest(shell=shell):
                    command = [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(skill / "scripts/start_dsh_team.ps1"),
                               "-Workspace", str(self.workspace), "-UserDshHome", str(source), "-NonInteractive", "-NoBrowser", "-SkipDshCheck"]
                    try:
                        started = subprocess.run(command, capture_output=True, timeout=90)
                        self.assertEqual(started.returncode, 0, (started.stdout + started.stderr).decode("utf-8", "replace")[-6000:])
                        record_path = self.workspace / "artifacts/dsh-monitor/server.json"
                        before = record_path.read_bytes()
                        record = backend.read_json(record_path)
                        state = backend.MonitorClient(self.workspace).snapshot()
                        self.assertTrue(state["online"])
                        self.assertEqual(state["settings"]["effective"], {"provider": "chosen-provider", "model": "chosen-model"})
                        self.assertEqual(state["runs"], [])
                        self.assertTrue(backend.same_path(Path(record["dsh_home"]).parent, self.root / "isolated-base/runtimes"))
                        # Both entry points reuse the existing process without sync/restart.
                        for args in (command, [shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                                     str(skill / "scripts/start_dsh_monitor.ps1"), "-Workspace", str(self.workspace), "-Background", "-AutoPort"]):
                            reused = subprocess.run(args, capture_output=True, timeout=25)
                            self.assertEqual(reused.returncode, 0, (reused.stdout + reused.stderr).decode("utf-8", "replace"))
                            self.assertEqual(before, record_path.read_bytes())
                        # Explicit conflicting target is not silently adopted, even with a live team.
                        refused = subprocess.run(command + ["-TeamDshHome", str(legacy)], capture_output=True, timeout=25)
                        self.assertNotEqual(refused.returncode, 0)
                        self.assertTrue(backend.MonitorClient(self.workspace).snapshot()["online"])
                        self.assertEqual(originals, {str(p): p.read_bytes() for directory in (source, legacy) for p in directory.iterdir()})
                        self.assertFalse((legacy / ".codex-dsh-team-home.json").exists())
                        # Lost records cannot create an extra background team.
                        record_path.unlink()
                        refused = subprocess.run(command, capture_output=True, timeout=25)
                        self.assertNotEqual(refused.returncode, 0)
                        self.assertFalse(record_path.exists())
                    finally:
                        stopped = self.invoke("Stop")
                        self.assertEqual(stopped.returncode, 0, stopped.stdout.decode("utf-8", "replace"))

    @unittest.skipUnless(shutil.which("node") and os.name == "nt", "Windows Node process/handle fixture")
    def test_missing_record_stop_releases_log_held_by_child_and_preserves_other_project(self):
        script = self.workspace / ".agents/skills/mcp-to-dsh/src/server.mjs"
        script.parent.mkdir(parents=True)
        script.write_text("""import {spawn} from 'node:child_process';
const worker=spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:['ignore','ignore',2]});
console.log(JSON.stringify({childPid:worker.pid}));
setInterval(()=>{},1000);
""", encoding="utf-8")
        log = self.workspace / "artifacts/dsh-monitor/server-stderr.log"
        log.parent.mkdir(parents=True)
        other = self.root / "other-project"
        other.mkdir()
        other_script = other / ".agents/skills/mcp-to-dsh/src/server.mjs"
        other_script.parent.mkdir(parents=True)
        other_script.write_text("setInterval(()=>{},1000);", encoding="utf-8")
        sibling = subprocess.Popen([shutil.which("node"), str(other_script), "--workspace", str(other)],
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        with log.open("wb") as stream:
            parent = subprocess.Popen([shutil.which("node"), str(script), "--workspace", str(self.workspace)],
                                      stdout=subprocess.PIPE, stderr=stream, creationflags=subprocess.CREATE_NO_WINDOW)
        handle = None
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        try:
            worker = json.loads(parent.stdout.readline())["childPid"]
            handle = kernel.OpenProcess(0x100001, False, worker)
            self.assertTrue(handle)
            self.assertFalse((log.parent / "server.json").exists())
            with self.assertRaises(PermissionError):
                log.rename(log.with_suffix(".moved"))
            self.assertIn(str(self.workspace), backend.discover_monitors())
            state = backend.poll_projects([{"workspace": str(self.workspace)}])[str(self.workspace)]
            self.assertFalse(state["online"])
            self.assertTrue(state["canStop"])
            with self.assertRaises(backend.DesktopError):
                backend.existing_monitor(self.workspace)
            result = self.invoke("Stop")
            self.assertEqual(result.returncode, 0, result.stdout.decode("utf-8", "replace") + result.stderr.decode("utf-8", "replace"))
            parent.wait(timeout=5)
            self.assertEqual(kernel.WaitForSingleObject(handle, 5000), 0)
            log.rename(log.with_suffix(".moved"))
            self.assertIsNone(sibling.poll(), "Unrelated project's Monitor must stay running")
        finally:
            if parent.poll() is None:
                parent.terminate()
                parent.wait(timeout=5)
            if handle:
                if kernel.WaitForSingleObject(handle, 0) != 0:
                    kernel.TerminateProcess(handle, 1)
                    kernel.WaitForSingleObject(handle, 5000)
                kernel.CloseHandle(handle)
            parent.stdout.close()
            sibling.terminate()
            sibling.wait(timeout=5)

    @unittest.skipUnless(shutil.which("node"), "Node fixture")
    def test_unrelated_server_script_is_not_treated_as_monitor(self):
        script = self.root / "server.mjs"
        script.write_text("setInterval(()=>{},1000);", encoding="utf-8")
        child = subprocess.Popen([shutil.which("node"), str(script), "--workspace", str(self.workspace)],
                                 creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        try:
            self.assertNotIn(str(self.workspace), backend.discover_monitors())
            self.assertEqual(self.invoke("Stop").returncode, 0)
            self.assertIsNone(child.poll())
        finally:
            child.terminate()
            child.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
