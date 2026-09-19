"""Exercise the desktop at file/HTTP/process boundaries, using synthetic local data."""
import base64
import ctypes
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import backend


def protect(value):
    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]
    raw = value.encode("utf-8")
    buffer = (ctypes.c_ubyte * len(raw)).from_buffer_copy(raw)
    incoming, outgoing = Blob(len(raw), buffer), Blob()
    crypt = ctypes.WinDLL("crypt32", use_last_error=True)
    crypt.CryptProtectData.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                                      ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    crypt.CryptProtectData.restype = wintypes.BOOL
    if not crypt.CryptProtectData(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
        raise OSError("DPAPI test encryption failed")
    try:
        return base64.b64encode(ctypes.string_at(outgoing.data, outgoing.size)).decode("ascii")
    finally:
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.LocalFree.argtypes = [ctypes.c_void_p]
        kernel.LocalFree(outgoing.data)


def source_at(path):
    path.mkdir(parents=True, exist_ok=True)
    (path / "settings.yaml").write_text("""llm-pi-ai:
  providers:
    first-provider:
      apiKey: do-not-expose-fixture-key
      baseURL: https://example.invalid/secret-path
      models:
        - id: first-model
    chosen-provider:
      models:
        - id: chosen-model
agent-default-model:
  provider: chosen-provider
  model: chosen-model
""", encoding="utf-8")
    return path


class LocalMonitor:
    def __init__(self, workspace):
        self.workspace = workspace
        self.calls = []
        self.health = {"service": "dsh-team-monitor", "ok": True, "workspace": str(workspace),
                       "dshHome": str(workspace / "team"), "dshUserHome": str(workspace / "source")}
        self.settings = {"revision": 7, "mode": "dsh-default", "effective": {"provider": "chosen-provider", "model": "chosen-model"},
                         "providers": [{"id": "chosen-provider", "models": [{"id": "chosen-model"}, {"id": "other-model"}]}]}
        self.forced_status = None
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def respond(self):
                body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"null")
                fixture.calls.append((self.command, self.path, dict(self.headers), body))
                status = fixture.forced_status or 200
                if self.path != "/api/health" and self.headers.get("X-DSH-Monitor-Token") != "fixture-token":
                    status = 401
                if self.path == "/redirect":
                    self.send_response(302)
                    self.send_header("Location", f"http://127.0.0.1:{fixture.server.server_port}/forbidden-target")
                    self.end_headers()
                    return
                payload = fixture.health if self.path == "/api/health" else fixture.settings
                if self.path == "/api/runs":
                    payload = {"runs": [{"id": "r1", "status": "running", "sessionId": "real-fixture-session",
                                         "startUtc": "2026-09-19", "prompt": "DO-NOT-KEEP", "events": ["PRIVATE-EVENT"]}]}
                if self.path == "/api/sync-settings":
                    payload = {"provider": "chosen-provider", "model": "chosen-model", "changed": True}
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            do_GET = do_PATCH = do_POST = respond

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.record = {"workspace": str(workspace), "url": f"http://127.0.0.1:{self.server.server_port}",
                       "dsh_home": str(workspace / "team"), "dsh_user_home": str(workspace / "source"),
                       "pid": 2147483000, "token_scheme": "dpapi-current-user", "access_token_protected": "fixture"}
        self.save()

    def save(self):
        backend.atomic_json(self.workspace / "artifacts/dsh-monitor/server.json", self.record)

    def client(self):
        return backend.MonitorClient(self.workspace, decoder=lambda _: "fixture-token")

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dsh-desktop-test-")
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def test_default_is_explicit_not_first_provider_and_secrets_are_not_projected(self):
        source = source_at(self.root / "配置")
        (source / ".credentials.yaml").write_text("NEVER-READ-THIS", encoding="utf-8")
        public = backend.read_source(source)
        self.assertEqual((public["provider"], public["model"]), ("chosen-provider", "chosen-model"))
        self.assertTrue(public["credentialsPresent"])
        for secret in ("NEVER-READ-THIS", "do-not-expose", "baseURL", "secret-path"):
            self.assertNotIn(secret, json.dumps(public))

    def test_saved_source_priority_and_no_foreign_settings(self):
        saved, other = source_at(self.root / "saved"), source_at(self.root / "other")
        store = backend.Store(self.root / "state")
        before = (saved / "settings.yaml").read_bytes()
        store.set_source(saved)
        with patch.dict(os.environ, {"DSH_USER_HOME": str(other), "DSH_HOME": str(saved)}), patch.object(Path, "home", return_value=self.root / "empty-home"):
            found = store.candidates()
        self.assertEqual([r["directory"] for r in found], [str(saved), str(other)])
        self.assertEqual(before, (saved / "settings.yaml").read_bytes())
        self.assertEqual(set(backend.read_json(store.base / "user-settings-source.json")), {"schema", "userDshHome"})

    def test_invalid_source_does_not_replace_saved_path_or_leak_yaml(self):
        store = backend.Store(self.root / "state")
        store.set_source(source_at(self.root / "good"))
        before = (store.base / "user-settings-source.json").read_bytes()
        bad = self.root / "bad"
        bad.mkdir()
        (bad / "settings.yaml").write_text("apiKey: [DO-NOT-SHOW", encoding="utf-8")
        with self.assertRaises(backend.DesktopError) as caught:
            store.set_source(bad)
        self.assertNotIn("DO-NOT-SHOW", str(caught.exception))
        self.assertEqual(before, (store.base / "user-settings-source.json").read_bytes())

    def test_discovery_retains_broken_saved_source_and_rejects_runtime_copy(self):
        store = backend.Store(self.root / "state")
        saved = source_at(self.root / "saved")
        store.set_source(saved)
        (saved / "settings.yaml").unlink()
        runtime = source_at(self.root / "runtime")
        (runtime / ".codex-dsh-team-home.json").write_text("{}")
        with patch.dict(os.environ, {"DSH_HOME": str(runtime), "DSH_USER_HOME": ""}), patch.object(Path, "home", return_value=self.root):
            rows = store.candidates()
        self.assertEqual(rows[0]["source"], "上次选择")
        self.assertTrue(rows[0]["error"])
        self.assertIn("运行副本", rows[1]["error"])
        self.assertTrue(all(row["error"] for row in rows))

    def test_corrupt_project_records_are_preserved(self):
        store = backend.Store(self.root / "state")
        for bad in ([], {"schema": 1, "projects": [None]}, {"schema": 1, "projects": [{"workspace": 123}]}):
            backend.atomic_json(store.path, bad)
            original = store.path.read_bytes()
            reopened = backend.Store(store.base)
            self.assertTrue(reopened.warning)
            with self.assertRaises(backend.DesktopError):
                reopened.add_project(self.root)
            self.assertEqual(original, store.path.read_bytes())

    def test_projects_roundtrip_and_deduplication(self):
        store = backend.Store(self.root / "state")
        store.add_project(self.root, "对话示例", "thread-id")
        store.add_project(self.root / ".")
        reopened = backend.Store(store.base)
        self.assertEqual(len(reopened.projects), 1)
        self.assertEqual(reopened.projects[0]["conversationId"], "thread-id")

    def test_write_error_is_user_readable(self):
        with patch("backend.os.replace", side_effect=PermissionError):
            with self.assertRaises(backend.DesktopError):
                backend.atomic_json(self.root / "state.json", {})


class MonitorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dsh-monitor-test-")
        self.root = Path(self.temp.name)
        self.service = LocalMonitor(self.root)
        self.addCleanup(self.temp.cleanup)
        self.addCleanup(self.service.close)

    def test_snapshot_checks_identity_and_projects_only_summary(self):
        with patch.dict(os.environ, {"HTTP_PROXY": "http://127.0.0.1:1", "NO_PROXY": ""}):
            result = self.service.client().snapshot()
        self.assertTrue(result["online"])
        self.assertEqual(result["active"], 1)
        self.assertEqual(result["runs"][0]["sessionId"], "real-fixture-session")
        self.assertNotIn("DO-NOT-KEEP", json.dumps(result))
        self.assertNotIn("PRIVATE-EVENT", json.dumps(result))

    def test_wrong_workspace_or_team_home_is_rejected_before_mutation(self):
        for field in ("workspace", "dshHome"):
            old = self.service.health[field]
            self.service.health[field] = str(self.root / "unrelated")
            with self.assertRaises(backend.DesktopError):
                self.service.client().choose_model(None, 7)
            self.service.health[field] = old
        self.assertFalse(any(call[0] != "GET" for call in self.service.calls))

    def test_address_must_be_exact_loopback_and_without_redirect(self):
        for url in ("https://127.0.0.1:1234", "http://localhost:1234", "http://example.com:1234", "http://u:p@127.0.0.1:1234", "http://127.0.0.1:1234?secret=1", "http://127.0.0.1:1234/path"):
            self.service.record["url"] = url
            self.service.save()
            with self.assertRaises(backend.DesktopError):
                self.service.client()
        self.service.record["url"] = f"http://127.0.0.1:{self.service.server.server_port}"
        self.service.save()
        with self.assertRaises(backend.DesktopError):
            self.service.client().request("/redirect")
        self.assertFalse(any(call[1] == "/forbidden-target" for call in self.service.calls))

    def test_legacy_records_are_health_only(self):
        self.service.record.pop("token_scheme")
        self.service.record["access_token"] = "PLAINTEXT-NOT-USED"
        self.service.save()
        client = self.service.client()
        self.assertTrue(client.snapshot()["limited"])
        self.assertEqual([call[1] for call in self.service.calls], ["/api/health"])
        self.assertNotIn("X-Dsh-Monitor-Token", self.service.calls[0][2])
        with self.assertRaises(backend.DesktopError):
            client.choose_model(None, 7)
        self.assertFalse(any(call[0] != "GET" for call in self.service.calls))

    def test_sync_rejects_foreign_source_and_passes_selected_source(self):
        client = self.service.client()
        with self.assertRaises(backend.DesktopError):
            client.sync(self.root / "other-user")
        self.assertFalse(any(call[0] == "POST" for call in self.service.calls))
        result = client.sync(self.root / "source")
        self.assertEqual(result["provider"], "chosen-provider")
        self.assertEqual(self.service.calls[-1][:2], ("POST", "/api/sync-settings"))

    def test_model_override_and_follow_default_use_revision(self):
        client = self.service.client()
        selection = {"provider": "chosen-provider", "model": "other-model"}
        client.choose_model(selection, 7)
        self.assertEqual(self.service.calls[-1][3], {"selection": selection, "expectedRevision": 7})
        client.choose_model(None, 8)
        self.assertEqual(self.service.calls[-1][3], {"selection": None, "expectedRevision": 8})

    def test_auth_failure_does_not_become_offline_or_restart_authorization(self):
        self.service.forced_status = 401
        with patch("backend.decrypt_token", return_value="fixture-token"):
            # The constructor's bound default decoder is intentionally not patched; use a client double here.
            with patch("backend.MonitorClient", return_value=self.service.client()):
                with self.assertRaises(backend.DesktopError) as caught:
                    backend.existing_monitor(self.root)
        self.assertNotIsInstance(caught.exception, backend.OfflineError)

    def test_stop_bridge_refuses_unrelated_pid(self):
        result = subprocess.run(backend.bridge_command("Stop", self.root, pid=os.getpid()), capture_output=True, timeout=20,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.service.client().snapshot()["online"])


class PlatformTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows DPAPI")
    def test_current_user_dpapi_roundtrip(self):
        self.assertEqual(backend.decrypt_token(protect("fake-desktop-token-中文")), "fake-desktop-token-中文")
        with self.assertRaises(backend.DesktopError):
            backend.decrypt_token("not-dpapi")

    def test_secrets_are_redacted_from_logs(self):
        text = backend.safe_log("apiKey=secret-one access_token: secret-two Authorization: Bearer secret-three sk-abcdefghijklmnop")
        for secret in ("secret-one", "secret-two", "secret-three", "sk-abcdefgh"):
            self.assertNotIn(secret, text)


if __name__ == "__main__":
    unittest.main()
