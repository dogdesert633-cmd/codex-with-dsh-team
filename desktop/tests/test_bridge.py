"""Optional Windows package integration. No real DSH/model task is dispatched."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend
from test_backend import protect


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

    def test_start_forwards_selected_source_without_model_check_on_ps5_and_ps7(self):
        script = self.workspace / ".agents/skills/mcp-to-dsh/scripts/start_dsh_team.ps1"
        script.parent.mkdir(parents=True)
        script.write_text("""param([string]$Workspace,[string]$UserDshHome,[switch]$SkipDshCheck,[switch]$NoBrowser,[switch]$NonInteractive)
@{ workspace=$Workspace; source=$UserDshHome; skipCheck=[bool]$SkipDshCheck; noBrowser=[bool]$NoBrowser; nonInteractive=[bool]$NonInteractive } | ConvertTo-Json -Compress
exit 0
""", encoding="utf-8-sig")
        source = self.root / "用户配置"
        source.mkdir()
        candidates = [backend.power_shell(), str(Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe")]
        for shell in dict.fromkeys(candidates):
            with self.subTest(shell=shell):
                command = backend.bridge_command("Start", self.workspace, source=source)
                command[0] = shell
                result = subprocess.run(command, capture_output=True, timeout=25, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                self.assertEqual(result.returncode, 0, result.stderr.decode("utf-8", "replace"))
                data = json.loads(result.stdout.decode("utf-8-sig"))
                self.assertEqual(data, {"workspace": str(self.workspace), "source": str(source), "skipCheck": True, "noBrowser": True, "nonInteractive": True})

    @unittest.skipUnless(shutil.which("node"), "Node is required for the local process fixture")
    def test_discover_reuse_and_stop_only_owned_fixture_process(self):
        script = self.root / "server.mjs"
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


if __name__ == "__main__":
    unittest.main()
