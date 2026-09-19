"""Local desktop adapter. Existing toolkit/Monitor implementations remain unchanged."""
from __future__ import annotations

import base64
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, build_opener, ProxyHandler, HTTPRedirectHandler

import yaml

ACTIVE = {"starting", "running", "cancelling", "queued"}
MAX_JSON = 8 * 1024 * 1024


class DesktopError(Exception):
    pass


class OfflineError(DesktopError):
    pass


def same_path(left, right):
    return bool(left and right) and os.path.normcase(str(Path(left).resolve())) == os.path.normcase(str(Path(right).resolve()))


def read_json(path, limit=MAX_JSON):
    try:
        with Path(path).open("rb") as stream:
            raw = stream.read(limit + 1)
        if len(raw) > limit:
            raise DesktopError("本地记录过大，请检查文件。")
        return json.loads(raw.decode("utf-8-sig"))
    except (OSError, ValueError, UnicodeError) as error:
        raise DesktopError("无法读取本地记录，请检查文件是否完整。") from error


def atomic_json(path, value):
    path = Path(path)
    # Preferences must not be redirected into an unrelated location by a junction/symlink.
    for parent in [path, *path.parents]:
        if parent.is_symlink() or getattr(parent, "is_junction", lambda: False)():
            raise DesktopError("设置目录不能位于符号链接或目录联接中。")
    name = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, name = tempfile.mkstemp(prefix=".desktop-", suffix=".tmp", dir=path.parent)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    except OSError as error:
        raise DesktopError("无法保存桌面设置，请检查目录权限和可用空间。") from error
    finally:
        if name:
            Path(name).unlink(missing_ok=True)


def toolkit_base():
    return Path(os.environ.get("CODEX_DSH_TEAM_BASE_DIR") or
                str(Path(os.environ.get("LOCALAPPDATA") or Path.home()) / "CodexDshTeam"))


class Store:
    def __init__(self, base=None):
        self.base = Path(base) if base else toolkit_base()
        self.path = self.base / "desktop" / "state.json"
        self.data = {"schema": 1, "projects": []}
        self.warning = ""
        if self.path.exists():
            try:
                data = read_json(self.path)
                if not isinstance(data, dict) or data.get("schema") != 1 or not isinstance(data.get("projects"), list):
                    raise DesktopError("桌面设置格式不正确。")
                for project in data["projects"]:
                    if (not isinstance(project, dict) or
                            any(not isinstance(project.get(key), str) for key in
                                ("workspace", "name", "conversationLabel", "conversationId")) or
                            not Path(project["workspace"]).is_absolute()):
                        raise DesktopError("项目记录格式不正确。")
                self.data = data
            except DesktopError:
                self.warning = "桌面记录损坏，已保留原文件。请先备份或修复后再保存。"

    @property
    def projects(self):
        return self.data["projects"]

    def save(self):
        if self.warning:
            raise DesktopError(self.warning)
        atomic_json(self.path, self.data)

    def add_project(self, workspace, label="", conversation_id=""):
        path = Path(workspace).resolve()
        if not path.is_dir():
            raise DesktopError("请选择一个存在的项目文件夹。")
        existing = next((p for p in self.projects if same_path(p["workspace"], path)), None)
        if existing:
            return existing
        project = {"workspace": str(path), "name": path.name or str(path),
                   "conversationLabel": label.strip(), "conversationId": conversation_id.strip()}
        self.projects.append(project)
        try:
            self.save()
        except Exception:
            self.projects.remove(project)
            raise
        return project

    def set_source(self, directory):
        catalog = read_source(directory)
        atomic_json(self.base / "user-settings-source.json", {
            "schema": "codex-dsh-user-settings-source/v1", "userDshHome": catalog["directory"]})
        return catalog

    def candidates(self):
        candidates = []
        saved = self.base / "user-settings-source.json"
        if saved.exists():
            try:
                record = read_json(saved)
                value = record.get("userDshHome") if isinstance(record, dict) else None
                if isinstance(value, str) and value:
                    candidates.append(("上次选择", value))
            except DesktopError:
                pass
        for name in ("DSH_USER_HOME", "DSH_HOME"):
            if os.environ.get(name):
                candidates.append((name, os.environ[name]))
        candidates.append(("用户默认目录", str(Path.home() / ".dsh")))
        found = []
        for source, directory in candidates:
            if any(same_path(directory, item["directory"]) for item in found):
                continue
            if (Path(directory) / "settings.yaml").is_file():
                try:
                    found.append({**read_source(directory), "source": source})
                except DesktopError:
                    found.append({"directory": str(Path(directory).resolve()), "source": source,
                                  "error": "配置文件无法解析", "provider": "", "model": ""})
        return found


def read_source(directory):
    path = Path(directory).expanduser().resolve()
    settings = path / "settings.yaml"
    if not settings.is_file():
        raise DesktopError("这个文件夹中没有 settings.yaml，请选择 DSH 配置目录。")
    try:
        if settings.stat().st_size > 2 * 1024 * 1024:
            raise DesktopError("settings.yaml 过大，无法作为配置读取。")
        data = yaml.safe_load(settings.read_text(encoding="utf-8-sig"))
        if not isinstance(data, dict):
            raise ValueError()
        default = data.get("agent-default-model") or {}
        provider, model = default.get("provider"), default.get("model")
        providers = ((data.get("llm-pi-ai") or {}).get("providers") or {})
        if not isinstance(providers, dict):
            raise ValueError()
        public = [{"id": str(name), "models": [str(m["id"]) for m in ((spec or {}).get("models") or [])
                                               if isinstance(m, dict) and isinstance(m.get("id"), str)]}
                  for name, spec in providers.items() if isinstance(spec, dict)]
        return {"directory": str(path), "provider": str(provider or ""), "model": str(model or ""),
                "providers": public, "credentialsPresent": (path / ".credentials.yaml").is_file(),
                "error": "" if provider and model else "请在 DSH 中设置 agent-default-model 默认模型。"}
    except (yaml.YAMLError, OSError, ValueError, TypeError, AttributeError) as error:
        # YAML errors can contain source lines with secrets. Never return them to the UI/log.
        raise DesktopError("settings.yaml 无法解析，请先在 DSH 中修正配置。") from error


def power_shell():
    executable = shutil.which("pwsh.exe") or shutil.which("powershell.exe")
    if not executable:
        raise DesktopError("找不到 PowerShell，请检查 Windows 运行环境。")
    return executable


def asset_root():
    return Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parent))


def program_directory():
    return Path(sys.executable).parent if getattr(sys, "frozen", False) else Path(__file__).resolve().parent.parent


def bundled_toolkit():
    for root in (program_directory() / "toolkit", asset_root() / "toolkit",
                 Path(__file__).resolve().parent.parent / "dist" / "toolkit"):
        if (root / "release-manifest.json").is_file():
            return root
    return None


def bridge_command(action, workspace=None, source=None, package=None, pid=None):
    args = [power_shell(), "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", str(asset_root() / "bridge.ps1"), "-Action", action]
    for flag, value in (("-Workspace", workspace), ("-UserDshHome", source), ("-PackageRoot", package),
                        ("-MonitorProcessId", pid)):
        if value is not None:
            args.extend([flag, str(value)])
    return args


def discover_monitors():
    """Enumerate only running Node monitor processes; never scan directories or port ranges."""
    try:
        result = subprocess.run(bridge_command("Discover"), capture_output=True, timeout=12,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if result.returncode:
            raise DesktopError("暂时无法检测运行中的 Monitor，可直接添加项目目录。")
        data = json.loads(result.stdout.decode("utf-8-sig"))
        if not isinstance(data, list):
            raise ValueError()
        return [str(Path(row["workspace"]).resolve()) for row in data
                if isinstance(row, dict) and Path(row.get("workspace", "")).is_dir()
                and (Path(row["workspace"]) / "artifacts/dsh-monitor/server.json").is_file()]
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise DesktopError("检测没有完成，可通过“添加项目”选择目录。") from error


def decrypt_token(encoded):
    if os.name != "nt":
        raise DesktopError("Monitor 身份验证需要 Windows 当前用户。")

    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]

    try:
        raw = base64.b64decode(encoded, validate=True)
        if len(raw) > 65536:
            raise ValueError()
        buffer = (ctypes.c_ubyte * len(raw)).from_buffer_copy(raw)
        incoming, outgoing = Blob(len(raw), buffer), Blob()
        crypt = ctypes.WinDLL("crypt32", use_last_error=True)
        crypt.CryptUnprotectData.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.c_void_p,
                                            ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
        crypt.CryptUnprotectData.restype = wintypes.BOOL
        if not crypt.CryptUnprotectData(ctypes.byref(incoming), None, None, None, None, 1, ctypes.byref(outgoing)):
            raise ValueError()
        try:
            return ctypes.string_at(outgoing.data, outgoing.size).decode("utf-8")
        finally:
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.LocalFree.argtypes = [ctypes.c_void_p]
            kernel.LocalFree.restype = ctypes.c_void_p
            kernel.LocalFree(outgoing.data)
    except (ValueError, UnicodeError, OSError, TypeError) as error:
        raise DesktopError("无法解密 Monitor 访问凭证，请使用启动它的 Windows 用户。") from error


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        fp.close()
        raise DesktopError("Monitor 返回了重定向，已拒绝发送访问凭证。")


class MonitorClient:
    def __init__(self, workspace, decoder=decrypt_token):
        self.workspace = str(Path(workspace).resolve())
        self.record = read_json(Path(workspace) / "artifacts/dsh-monitor/server.json", 65536)
        if not isinstance(self.record, dict):
            raise DesktopError("Monitor 记录格式不正确。")
        if not same_path(self.record.get("workspace"), self.workspace):
            raise DesktopError("Monitor 记录属于其他项目，已拒绝连接。")
        url = self.record.get("url", "")
        try:
            parsed = urlsplit(url)
            if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or not parsed.port or
                    parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.path not in ("", "/")):
                raise ValueError()
        except (ValueError, TypeError):
            raise DesktopError("Monitor 地址必须是本机 127.0.0.1 的 HTTP 地址。") from None
        self.url = f"http://127.0.0.1:{parsed.port}"
        self.authorized = self.record.get("token_scheme") == "dpapi-current-user"
        # Old plaintext records are never consumed. Health-only discovery remains available.
        self._token = decoder(self.record.get("access_token_protected", "")) if self.authorized else ""
        self.opener = build_opener(ProxyHandler({}), NoRedirect())

    def request(self, endpoint, method="GET", body=None, timeout=2):
        if not self.authorized and endpoint != "/api/health":
            raise DesktopError("旧版 Monitor 仅支持概览，请用新版启动器启动后再操作。")
        headers = {"X-DSH-Monitor-Token": self._token} if self.authorized else {}
        encoded = None
        if body is not None:
            encoded = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        req = Request(self.url + endpoint, data=encoded, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=timeout) as response:
                raw = response.read(MAX_JSON + 1)
                if len(raw) > MAX_JSON:
                    raise DesktopError("Monitor 数据量较大，请打开网页查看详情。")
                result = json.loads(raw.decode("utf-8"))
                if not isinstance(result, dict):
                    raise ValueError()
                return result
        except HTTPError as error:
            messages = {401: "Monitor 身份验证失败，请刷新连接。", 403: "Monitor 拒绝了此操作。",
                        409: "Monitor 正在处理其他操作或设置已变化，请刷新后重试。"}
            message = messages.get(error.code, f"Monitor 操作未完成（HTTP {error.code}）。")
            error.close()
            raise DesktopError(message) from None
        except (URLError, TimeoutError, OSError) as error:
            raise OfflineError("Monitor 未响应，可能尚未启动或已经退出。") from error
        except (UnicodeError, ValueError) as error:
            raise DesktopError("Monitor 返回的数据无法识别。") from error

    def verify(self):
        health = self.request("/api/health")
        if health.get("service") != "dsh-team-monitor" or not same_path(health.get("workspace"), self.workspace):
            raise DesktopError("此地址不是该项目的 DSH Monitor。")
        if not same_path(health.get("dshHome"), self.record.get("dsh_home")):
            raise DesktopError("Monitor 运行目录与记录不一致，请重新连接。")
        # Verify the token before considering the endpoint connected/usable.
        settings = self.request("/api/model-settings") if self.authorized else {}
        return health, settings

    def snapshot(self):
        health, settings = self.verify()
        runs = self.request("/api/runs") if self.authorized else {}
        # Don't keep entire event streams or prompts in the desktop state.
        public = [{key: row.get(key) for key in ("id", "agentId", "formalRole", "title", "status", "sessionId",
                                                 "effectiveModelSelection", "requestedModelSelection", "startUtc", "endUtc")}
                  for row in runs.get("runs", []) if isinstance(row, dict)]
        public.sort(key=lambda row: row.get("startUtc") or "", reverse=True)
        return {"online": True, "limited": not self.authorized, "url": self.url, "health": health, "settings": settings, "runs": public,
                "active": sum(row.get("status") in ACTIVE for row in public),
                "error": "旧版 Monitor 仅提供地址概览，请用新版启动器启动后查看会话。" if not self.authorized else ""}

    def sync(self, expected_source):
        health, _ = self.verify()
        actual = health.get("dshUserHome") or self.record.get("dsh_user_home")
        if not same_path(actual, expected_source):
            raise DesktopError("此 Monitor 使用另一份 DSH 配置。请先停止它，再使用选定目录重新启动。")
        return self.request("/api/sync-settings", "POST", timeout=180)

    def choose_model(self, selection, revision):
        self.verify()
        return self.request("/api/model-settings", "PATCH", {"selection": selection, "expectedRevision": revision})


def poll_projects(projects):
    results = {}
    for project in projects:
        path = project["workspace"]
        try:
            results[path] = MonitorClient(path).snapshot()
        except DesktopError as error:
            results[path] = {"online": False, "active": 0, "runs": [], "error": str(error), "url": ""}
        except Exception:
            results[path] = {"online": False, "active": 0, "runs": [], "error": "暂时无法读取 Monitor 状态。", "url": ""}
    return results


def safe_log(text):
    text = re.sub(r"(?i)(authorization\s*[:=]\s*bearer\s+)\S+", r"\1<已隐藏>", text)
    text = re.sub(r"(?i)((?:[\w-]*(?:api[_-]?key|token|password|secret)[\w-]*)\s*[:=]\s*)[^\s,;]+", r"\1<已隐藏>", text)
    return re.sub(r"\bsk-[A-Za-z0-9_-]{12,}\b", "<已隐藏>", text)


def readiness(workspace):
    root = Path(workspace) / ".agents/skills/mcp-to-dsh"
    return {"installed": (root / "scripts/start_dsh_team.ps1").is_file(),
            "dependencies": (root / "node_modules/@deepseek-ai/dsh/lib/bin.js").is_file(),
            "node": shutil.which("node.exe") or shutil.which("node") or "",
            "globalDsh": shutil.which("dsh.cmd") or shutil.which("dsh") or ""}


def existing_monitor(workspace):
    if not (Path(workspace) / "artifacts/dsh-monitor/server.json").is_file():
        return None
    try:
        return MonitorClient(workspace).snapshot()
    except OfflineError:
        return None


def stop_command(workspace):
    client = MonitorClient(workspace)
    client.verify()
    if not client.authorized:
        raise DesktopError("旧版 Monitor 只能查看概览，请在它原来的启动窗口中停止。")
    pid = client.record.get("pid")
    if not isinstance(pid, int) or pid <= 0:
        raise DesktopError("Monitor 记录缺少可靠的进程标识，无法从桌面停止。")
    return bridge_command("Stop", workspace, pid=pid)
