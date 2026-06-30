#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT_DIR / "target" / "debug" / "fluxdown-desktop.exe"
DEFAULT_FLUXDOWN = ROOT_DIR / "target" / "debug" / "fluxdown.exe"
DEFAULT_DEV_URL = "http://localhost:5173/"
DEFAULT_OUTPUT_JSON = (
    ROOT_DIR
    / "docs"
    / "artifacts"
    / "windows-desktop-gui-protocol-e2e-20260630.json"
)
DEFAULT_QUEUE_SCREENSHOT = (
    ROOT_DIR / "docs" / "artifacts" / "windows-desktop-gui-queue-20260630.png"
)
DEFAULT_SETTINGS_SCREENSHOT = (
    ROOT_DIR / "docs" / "artifacts" / "windows-desktop-gui-settings-20260630.png"
)


class VerifyError(RuntimeError):
    pass


def load_cli_module() -> Any:
    module_path = ROOT_DIR / "scripts" / "verify-windows-cli-protocols.py"
    spec = importlib.util.spec_from_file_location("windows_cli_protocols", module_path)
    if spec is None or spec.loader is None:
        raise VerifyError(f"cannot load fixture module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


cli = load_cli_module()


@dataclass
class GuiCaseSpec:
    id: str
    protocol: str
    source: str
    output_name: str
    expected_sha256: str | None
    expected_bytes: bytes | None
    expectation: str
    timeout: int = 120
    torrent_indices: str = ""


@dataclass
class GuiCaseResult:
    id: str
    protocol: str
    source: str
    status: str
    gui_state: str | None = None
    output_path: str | None = None
    bytes_written: int | None = None
    sha256: str | None = None
    expectation: str = ""
    detail: str = ""
    duration_ms: int = 0


@dataclass
class GuiContext:
    app: pathlib.Path
    fluxdown: pathlib.Path
    work_dir: pathlib.Path
    keep_work_dir: bool
    debug_port: int
    output_json: pathlib.Path
    queue_screenshot: pathlib.Path
    settings_screenshot: pathlib.Path
    results: list[GuiCaseResult] = field(default_factory=list)
    processes: list[subprocess.Popen[Any]] = field(default_factory=list)
    owned_dev_server: bool = False
    settings_validation: dict[str, Any] = field(default_factory=dict)
    page_identity: dict[str, Any] = field(default_factory=dict)


class CdpClient:
    def __init__(self, websocket_url: str):
        parsed = urllib.parse.urlparse(websocket_url)
        if parsed.scheme != "ws" or not parsed.hostname or not parsed.port:
            raise VerifyError(f"unsupported websocket url: {websocket_url}")
        self.host = parsed.hostname
        self.port = parsed.port
        self.path = parsed.path
        if parsed.query:
            self.path += f"?{parsed.query}"
        self.socket = socket.create_connection((self.host, self.port), timeout=10)
        self.next_id = 1
        self._handshake()

    def close(self) -> None:
        with contextlib.suppress(Exception):
            self._send_frame(b"", opcode=0x8)
        with contextlib.suppress(Exception):
            self.socket.close()

    def _handshake(self) -> None:
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        request = (
            f"GET {self.path} HTTP/1.1\r\n"
            f"Host: {self.host}:{self.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        self.socket.sendall(request.encode("ascii"))
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.socket.recv(4096)
            if not chunk:
                break
            response += chunk
        if b" 101 " not in response.split(b"\r\n", 1)[0]:
            raise VerifyError(f"CDP websocket handshake failed: {response[:200]!r}")

    def command(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        message_id = self.next_id
        self.next_id += 1
        payload = json.dumps(
            {"id": message_id, "method": method, "params": params or {}},
            separators=(",", ":"),
        ).encode("utf-8")
        self._send_frame(payload, opcode=0x1)
        while True:
            message = self._recv_message()
            if message.get("id") != message_id:
                continue
            if "error" in message:
                raise VerifyError(f"CDP command {method} failed: {message['error']}")
            return message.get("result", {})

    def evaluate(self, expression: str) -> Any:
        result = self.command(
            "Runtime.evaluate",
            {
                "expression": expression,
                "awaitPromise": True,
                "returnByValue": True,
                "userGesture": True,
            },
        )
        if "exceptionDetails" in result:
            details = result["exceptionDetails"]
            text = details.get("text") or details.get("exception", {}).get("description")
            raise VerifyError(f"runtime evaluation failed: {text}\n{expression}")
        value = result.get("result", {})
        if "value" in value:
            return value["value"]
        if value.get("type") == "undefined":
            return None
        return value

    def screenshot(self, path: pathlib.Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = self.command(
            "Page.captureScreenshot",
            {"format": "png", "captureBeyondViewport": False},
        )["data"]
        path.write_bytes(base64.b64decode(data))

    def _send_frame(self, payload: bytes, *, opcode: int) -> None:
        first = 0x80 | opcode
        length = len(payload)
        if length < 126:
            header = bytes([first, 0x80 | length])
        elif length <= 0xFFFF:
            header = bytes([first, 0x80 | 126]) + length.to_bytes(2, "big")
        else:
            header = bytes([first, 0x80 | 127]) + length.to_bytes(8, "big")
        mask = os.urandom(4)
        masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        self.socket.sendall(header + mask + masked)

    def _recv_message(self) -> dict[str, Any]:
        fragments: list[bytes] = []
        while True:
            first, second = self._read_exact(2)
            final = bool(first & 0x80)
            opcode = first & 0x0F
            masked = bool(second & 0x80)
            length = second & 0x7F
            if length == 126:
                length = int.from_bytes(self._read_exact(2), "big")
            elif length == 127:
                length = int.from_bytes(self._read_exact(8), "big")
            mask = self._read_exact(4) if masked else b""
            payload = self._read_exact(length) if length else b""
            if masked:
                payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))

            if opcode == 0x8:
                raise VerifyError("CDP websocket closed")
            if opcode == 0x9:
                self._send_frame(payload, opcode=0xA)
                continue
            if opcode in (0x1, 0x0):
                fragments.append(payload)
                if final:
                    return json.loads(b"".join(fragments).decode("utf-8"))

    def _read_exact(self, length: int) -> bytes:
        chunks: list[bytes] = []
        remaining = length
        while remaining > 0:
            chunk = self.socket.recv(remaining)
            if not chunk:
                raise VerifyError("unexpected EOF while reading CDP websocket")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)


class GuiDriver:
    def __init__(self, client: CdpClient):
        self.client = client
        self.client.command("Runtime.enable")
        self.client.command("Page.enable")

    def close(self) -> None:
        self.client.close()

    def page_identity(self) -> dict[str, Any]:
        return self.evaluate(
            """
            (() => ({
              title: document.title,
              url: location.href,
              readyState: document.readyState,
              bodyTextLength: document.body ? document.body.innerText.length : 0
            }))()
            """
        )

    def evaluate(self, expression: str) -> Any:
        return self.client.evaluate(expression)

    def screenshot(self, path: pathlib.Path) -> None:
        self.client.screenshot(path)

    def wait_for_testid(self, testid: str, timeout: float = 15.0) -> Any:
        return self.wait_for(
            f"""
            (() => {{
              const el = document.querySelector('[data-testid="{testid}"]');
              return el ? {{ visible: true, text: el.innerText || el.value || "" }} : null;
            }})()
            """,
            timeout=timeout,
            label=f"data-testid={testid}",
        )

    def click_testid(self, testid: str) -> None:
        self.click_selector(f'[data-testid="{testid}"]')

    def click_selector(self, selector: str) -> None:
        self.evaluate(
            f"""
            (() => {{
              const selector = {json.dumps(selector)};
              const el = document.querySelector(selector);
              if (!el) throw new Error(`missing selector ${{selector}}`);
              if ("disabled" in el && el.disabled) throw new Error(`disabled selector ${{selector}}`);
              el.scrollIntoView({{ block: "center", inline: "center" }});
              el.click();
              return true;
            }})()
            """
        )

    def fill_testid(self, testid: str, value: str) -> None:
        self.fill_selector(f'[data-testid="{testid}"]', value)

    def fill_selector(self, selector: str, value: str) -> None:
        self.evaluate(
            f"""
            (() => {{
              const selector = {json.dumps(selector)};
              const value = {json.dumps(value)};
              const el = document.querySelector(selector);
              if (!el) throw new Error(`missing selector ${{selector}}`);
              el.focus();
              const descriptor = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), "value");
              if (descriptor && descriptor.set) {{
                descriptor.set.call(el, value);
              }} else {{
                el.value = value;
              }}
              el.dispatchEvent(new InputEvent("input", {{ bubbles: true, inputType: "insertText", data: value }}));
              el.dispatchEvent(new Event("change", {{ bubbles: true }}));
              return el.value;
            }})()
            """
        )

    def wait_for(self, expression: str, *, timeout: float, label: str) -> Any:
        deadline = time.monotonic() + timeout
        last_value: Any = None
        while time.monotonic() < deadline:
            last_value = self.evaluate(expression)
            if last_value:
                return last_value
            time.sleep(0.25)
        raise VerifyError(f"timed out waiting for {label}; last value={last_value!r}")

    def task_snapshot(self, output_dir: pathlib.Path) -> dict[str, Any] | None:
        return self.evaluate(
            f"""
            (() => {{
              const outputDir = {json.dumps(str(output_dir))};
              const rows = Array.from(document.querySelectorAll('[data-testid="task-row"]'));
              const row = rows.find((candidate) => candidate.dataset.taskOutputDir === outputDir);
              if (!row) return null;
              return {{
                state: row.dataset.taskState || row.dataset.state || "",
                protocol: row.dataset.taskProtocol || "",
                title: row.dataset.taskTitle || "",
                text: row.innerText || ""
              }};
            }})()
            """
        )

    def wait_task_state(
        self,
        output_dir: pathlib.Path,
        target_states: set[str],
        *,
        timeout: float,
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        snapshot: dict[str, Any] | None = None
        while time.monotonic() < deadline:
            snapshot = self.task_snapshot(output_dir)
            if snapshot and snapshot.get("state") in target_states:
                return snapshot
            time.sleep(0.5)
        raise VerifyError(
            f"timed out waiting for task {output_dir} in {sorted(target_states)}; "
            f"last snapshot={snapshot!r}"
        )


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def http_ok(url: str, *, timeout: float = 2.0) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:  # type: ignore[attr-defined]
            return 200 <= int(response.status) < 500
    except Exception:
        return False


def wait_for_http(url: str, *, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if http_ok(url, timeout=1.0):
            return
        time.sleep(0.25)
    raise VerifyError(f"timed out waiting for HTTP {url}")


def read_json_url(url: str) -> Any:
    with urllib.request.urlopen(url, timeout=2) as response:  # type: ignore[attr-defined]
        return json.loads(response.read().decode("utf-8"))


def wait_for_cdp_endpoint(port: int, *, timeout: float = 30.0) -> str:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            targets = read_json_url(f"http://127.0.0.1:{port}/json/list")
            pages = [
                target
                for target in targets
                if target.get("type") == "page" and target.get("webSocketDebuggerUrl")
            ]
            for page in pages:
                url = str(page.get("url", ""))
                title = str(page.get("title", ""))
                if "localhost:5173" in url or "FluxDown" in title:
                    return str(page["webSocketDebuggerUrl"])
            if pages:
                return str(pages[0]["webSocketDebuggerUrl"])
        except Exception as error:
            last_error = error
        time.sleep(0.5)
    raise VerifyError(f"timed out waiting for WebView2 CDP endpoint: {last_error}")


def spawn_process(
    ctx: GuiContext,
    args: list[str],
    *,
    env: dict[str, str] | None = None,
    cwd: pathlib.Path = ROOT_DIR,
) -> subprocess.Popen[Any]:
    process = subprocess.Popen(
        args,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    ctx.processes.append(process)
    return process


def ensure_dev_server(ctx: GuiContext, dev_url: str) -> None:
    if http_ok(dev_url, timeout=3.0):
        return
    spawn_process(
        ctx,
        ["npm.cmd", "--workspace", "apps/desktop", "run", "dev", "--", "--host", "localhost"],
    )
    ctx.owned_dev_server = True
    wait_for_http(dev_url, timeout=60.0)


def launch_native_app(ctx: GuiContext, dev_url: str) -> GuiDriver:
    ensure_dev_server(ctx, dev_url)
    env = os.environ.copy()
    env["XDG_DATA_HOME"] = str(ctx.work_dir / "xdg")
    env["FLUXDOWN_E2E_DEV_URL"] = dev_url
    env["FLUXDOWN_E2E_WEBVIEW2_ARGS"] = (
        f"--remote-debugging-port={ctx.debug_port} --remote-allow-origins=*"
    )
    env["FLUXDOWN_E2E_WEBVIEW2_DATA_DIR"] = str(ctx.work_dir / "webview2")
    spawn_process(ctx, [str(ctx.app)], env=env)
    websocket_url = wait_for_cdp_endpoint(ctx.debug_port, timeout=45.0)
    driver = GuiDriver(CdpClient(websocket_url))
    driver.wait_for_testid("queue-page", timeout=30.0)
    return driver


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_output_file(output_dir: pathlib.Path, expected_sha256: str) -> pathlib.Path:
    if not output_dir.exists():
        raise VerifyError(f"output dir does not exist: {output_dir}")
    candidates = [path for path in output_dir.rglob("*") if path.is_file()]
    for candidate in candidates:
        if sha256_file(candidate) == expected_sha256:
            return candidate
    listed = ", ".join(str(path) for path in candidates[:20])
    raise VerifyError(f"no output file with expected sha256 in {output_dir}; files={listed}")


def run_settings_validation(driver: GuiDriver, ctx: GuiContext) -> dict[str, Any]:
    driver.click_testid("settings-button")
    driver.wait_for_testid("settings-page", timeout=10.0)

    section_rows = {
        "general": ["outputDir", "autoStart", "refreshIntervalMs"],
        "download": ["concurrency", "threadCount", "retryAttempts", "speedLimitMbps"],
        "protocol": [],
        "storage": ["fileNaming", "sha256", "torrentFileSelection", "openWhenFinished"],
        "security": ["redactUrl", "redactError", "externalBackendNotice"],
        "diagnostics": [],
    }
    visited: dict[str, Any] = {}
    for section, expected_rows in section_rows.items():
        driver.click_selector(
            f'[data-testid="settings-nav-button"][data-section="{section}"]'
        )
        time.sleep(0.2)
        rows = driver.evaluate(
            """
            (() => Array.from(document.querySelectorAll("[data-setting-row]"))
              .map((row) => row.dataset.settingRow)
              .filter(Boolean))()
            """
        )
        if expected_rows and rows != expected_rows:
            raise VerifyError(f"settings section {section} rows mismatch: {rows}")
        visited[section] = {"rows": rows}

        if section == "general":
            driver.fill_testid("setting-output-dir", str(ctx.work_dir / "settings-default"))
            auto_start = driver.evaluate(
                """
                (() => document.querySelector('[data-testid="setting-auto-start"]')
                  ?.getAttribute("aria-pressed"))()
                """
            )
            if auto_start == "true":
                driver.click_testid("setting-auto-start")
            driver.fill_testid("setting-refresh-interval", "500")
        elif section == "download":
            # 作者: long
            # GUI 验证必须由脚本显式点击“开始队列”，所以先把并发和自动启动压到确定值，避免后台自动运行掩盖前台交互问题。
            driver.fill_testid("setting-concurrency", "1")
            driver.fill_testid("setting-thread-count", "1")
            driver.fill_testid("setting-retry-attempts", "1")
            driver.fill_testid("setting-speed-limit", "0")
        elif section == "protocol":
            driver.click_testid("settings-check-backend-button")
            notice = driver.wait_for(
                """
                (() => {
                  const notice = document.querySelector('[data-settings-notice="detail"]');
                  return notice && notice.innerText.includes("后端自检") ? notice.innerText : null;
                })()
                """,
                timeout=15.0,
                label="settings backend check notice",
            )
            backends = driver.evaluate(
                """
                (() => Array.from(document.querySelectorAll("[data-protocol-backend]"))
                  .map((item) => item.dataset.protocolBackend)
                  .filter(Boolean))()
                """
            )
            protocols = driver.evaluate(
                """
                (() => Array.from(document.querySelectorAll("[data-protocol-chip]"))
                  .map((item) => ({
                    protocol: item.dataset.protocolChip,
                    executable: item.dataset.protocolExecutable === "true",
                  }))
                  .filter((item) => item.protocol))()
                """
            )
            if not backends or not protocols:
                raise VerifyError("settings protocol section missing backend or protocol evidence")
            visited[section] = {
                "rows": rows,
                "notice": notice,
                "backends": backends,
                "protocols": protocols,
            }
        elif section == "diagnostics":
            health_score = driver.evaluate(
                """
                (() => document.querySelector('[data-testid="settings-health-panel"]')
                  ?.dataset.healthScore ?? null)()
                """
            )
            backends = driver.evaluate(
                """
                (() => Array.from(document.querySelectorAll("[data-diagnostics-backend]"))
                  .map((item) => item.dataset.diagnosticsBackend)
                  .filter(Boolean))()
                """
            )
            if health_score is None or not backends:
                raise VerifyError("settings diagnostics section missing health or backend evidence")
            visited[section] = {
                "rows": rows,
                "health_score": int(health_score),
                "backends": backends,
            }

    driver.screenshot(ctx.settings_screenshot)
    driver.click_testid("settings-save-button")
    driver.click_testid("settings-detail-back-button")
    driver.wait_for_testid("queue-page", timeout=10.0)
    return {"status": "passed", "sections": visited}


def add_gui_task(
    driver: GuiDriver,
    case: GuiCaseSpec,
    output_dir: pathlib.Path,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    driver.click_testid("new-task-button")
    driver.wait_for_testid("new-task-dialog", timeout=10.0)
    driver.fill_testid("new-task-source", case.source)
    time.sleep(0.3)
    driver.fill_testid("new-task-file-name", case.output_name)
    driver.fill_testid("new-task-output-dir", str(output_dir))
    if case.expected_sha256:
        driver.fill_testid("new-task-sha256", case.expected_sha256)
    if case.torrent_indices:
        driver.wait_for_testid("new-task-torrent-indices", timeout=5.0)
        driver.fill_testid("new-task-torrent-indices", case.torrent_indices)
    driver.click_testid("new-task-create")
    driver.wait_for(
        f"""
        (() => {{
          const outputDir = {json.dumps(str(output_dir))};
          return Array.from(document.querySelectorAll('[data-testid="task-row"]'))
            .some((row) => row.dataset.taskOutputDir === outputDir);
        }})()
        """,
        timeout=15.0,
        label=f"task row for {case.id}",
    )


def run_gui_case(driver: GuiDriver, ctx: GuiContext, case: GuiCaseSpec) -> GuiCaseResult:
    output_dir = ctx.work_dir / "downloads" / case.id
    started = time.monotonic()
    add_gui_task(driver, case, output_dir)
    snapshot = driver.task_snapshot(output_dir)
    if snapshot and snapshot.get("state") in {"queued", "paused"}:
        driver.click_testid("start-queue-button")

    target_states = {"finished", "failed"} if case.protocol == "ed2k" else {"finished"}
    snapshot = driver.wait_task_state(output_dir, target_states, timeout=case.timeout)
    duration_ms = int((time.monotonic() - started) * 1000)
    gui_state = str(snapshot.get("state"))

    if case.protocol == "ed2k":
        detail = str(snapshot.get("text", "")).replace("\n", " | ")
        accepted_failure = any(
            token.lower() in detail.lower()
            for token in [
                "system handoff failed",
                "no application",
                "cannot find",
                "not found",
                "不可用",
                "失败",
            ]
        )
        if gui_state == "failed" and not accepted_failure:
            raise VerifyError(f"unexpected ed2k GUI failure text: {detail}")
        return GuiCaseResult(
            id=case.id,
            protocol=case.protocol,
            source=case.source,
            status="passed",
            gui_state=gui_state,
            expectation=case.expectation,
            detail=detail,
            duration_ms=duration_ms,
        )

    if gui_state != "finished":
        detail = str(snapshot.get("text", "")).replace("\n", " | ")
        raise VerifyError(f"{case.id} GUI state={gui_state}: {detail}")
    if not case.expected_sha256:
        raise VerifyError(f"{case.id} is missing expected sha256")
    output_path = find_output_file(output_dir, case.expected_sha256)
    actual_sha = sha256_file(output_path)
    if case.expected_bytes is not None and output_path.read_bytes() != case.expected_bytes:
        raise VerifyError(f"{case.id} output content mismatch: {output_path}")
    return GuiCaseResult(
        id=case.id,
        protocol=case.protocol,
        source=case.source,
        status="passed",
        gui_state=gui_state,
        output_path=str(output_path),
        bytes_written=output_path.stat().st_size,
        sha256=actual_sha,
        expectation=case.expectation,
        detail=str(snapshot.get("title", "")),
        duration_ms=duration_ms,
    )


def local_cases(fixtures: dict[str, Any]) -> list[GuiCaseSpec]:
    payloads: dict[str, bytes] = fixtures["payloads"]
    http_port = fixtures["http_port"]
    https_port = fixtures["https_port"]
    ftp_port = fixtures["ftp_port"]
    ftps_port = fixtures["ftps_port"]
    return [
        GuiCaseSpec(
            "win-gui-http-local",
            "http",
            f"http://127.0.0.1:{http_port}/http.txt",
            "windows-gui-http.txt",
            cli.sha256_bytes(payloads["http"]),
            payloads["http"],
            "原生 Tauri GUI 新建 HTTP 任务，点击开始队列后真实落盘并校验 SHA-256",
        ),
        GuiCaseSpec(
            "win-gui-https-local-self-signed",
            "https",
            f"https://127.0.0.1:{https_port}/https.txt?allowBadCertificate=true",
            "windows-gui-https.txt",
            cli.sha256_bytes(payloads["https"]),
            payloads["https"],
            "原生 Tauri GUI 通过 HTTPS 自签证书 opt-in 真实落盘",
        ),
        GuiCaseSpec(
            "win-gui-webdav-local-transport",
            "webdav",
            f"webdav://127.0.0.1:{http_port}/webdav.txt",
            "windows-gui-webdav.txt",
            cli.sha256_bytes(payloads["webdav"]),
            payloads["webdav"],
            "原生 Tauri GUI WebDAV transport 映射 HTTP 后真实落盘",
        ),
        GuiCaseSpec(
            "win-gui-webdavs-local-transport",
            "webdavs",
            f"webdavs://127.0.0.1:{https_port}/webdavs.txt?allowBadCertificate=true",
            "windows-gui-webdavs.txt",
            cli.sha256_bytes(payloads["webdavs"]),
            payloads["webdavs"],
            "原生 Tauri GUI WebDAVS transport 映射 HTTPS 后真实落盘",
        ),
        GuiCaseSpec(
            "win-gui-ftp-local",
            "ftp",
            f"ftp://flux:fluxpass@127.0.0.1:{ftp_port}/ftp-sample.txt",
            "windows-gui-ftp.txt",
            cli.sha256_bytes(payloads["ftp"]),
            payloads["ftp"],
            "原生 Tauri GUI FTP EPSV/RETR 数据连接真实落盘",
        ),
        GuiCaseSpec(
            "win-gui-ftps-local-explicit",
            "ftps",
            f"ftps://flux:fluxpass@127.0.0.1:{ftps_port}/ftps-sample.txt?allowBadCertificate=true",
            "windows-gui-ftps.txt",
            cli.sha256_bytes(payloads["ftps"]),
            payloads["ftps"],
            "原生 Tauri GUI 显式 FTPS 控制和数据连接 TLS 真实落盘",
        ),
        GuiCaseSpec(
            "win-gui-m3u8-local-vod",
            "m3u8",
            f"http://127.0.0.1:{http_port}/playlist.m3u8",
            "windows-gui-hls.ts",
            cli.sha256_bytes(payloads["m3u8"]),
            payloads["m3u8"],
            "原生 Tauri GUI VOD m3u8 两个分片按顺序合并落盘",
        ),
        GuiCaseSpec(
            "win-gui-ipfs-local-gateway",
            "ipfs",
            f"ipfs://{cli.CID}/readme.txt?gateway={urllib.parse.quote(f'http://127.0.0.1:{http_port}', safe='')}",
            "windows-gui-ipfs.txt",
            cli.sha256_bytes(payloads["ipfs"]),
            payloads["ipfs"],
            "原生 Tauri GUI IPFS gateway= 本地兼容网关真实落盘",
        ),
    ]


def prepare_sftp_case(ctx: GuiContext, fixture_ctx: Any) -> GuiCaseSpec:
    if not cli.docker_available():
        raise VerifyError("Docker is required for SFTP fixture")
    port = cli.free_port()
    upload = ctx.work_dir / "sftp-upload"
    upload.mkdir(parents=True, exist_ok=True)
    payload = b"fluxdown windows gui sftp sample\n"
    sample_name = "windows-gui-sftp-sample.txt"
    (upload / sample_name).write_bytes(payload)
    container = f"fluxdown-win-gui-sftp-{os.getpid()}"
    fixture_ctx.containers.append(container)
    cli.docker(
        fixture_ctx,
        [
            "run",
            "-d",
            "--platform",
            "linux/amd64",
            "--name",
            container,
            "-p",
            f"127.0.0.1:{port}:22",
            "-v",
            cli.mount_arg(upload, "/home/flux/upload", readonly=True),
            cli.SFTP_IMAGE,
            "flux:fluxpass:::upload",
        ],
        timeout=180,
    )
    cli.wait_for_sftp_banner("127.0.0.1", port, fixture_ctx, container)
    return GuiCaseSpec(
        "win-gui-sftp-local-docker",
        "sftp",
        f"sftp://flux:fluxpass@127.0.0.1:{port}/upload/{sample_name}",
        "windows-gui-sftp.txt",
        cli.sha256_bytes(payload),
        payload,
        "原生 Tauri GUI Docker SFTP 密码认证读取远端文件并落盘",
        timeout=120,
    )


def prepare_smb_case(ctx: GuiContext, fixture_ctx: Any) -> GuiCaseSpec:
    if not cli.docker_available():
        raise VerifyError("Docker is required for SMB fixture")
    port = cli.free_port()
    share = ctx.work_dir / "smb-share"
    share.mkdir(parents=True, exist_ok=True)
    payload = b"fluxdown windows gui smb sample\n"
    sample_name = "windows-gui-smb-sample.txt"
    (share / sample_name).write_bytes(payload)
    container = f"fluxdown-win-gui-smb-{os.getpid()}"
    fixture_ctx.containers.append(container)
    cli.docker(
        fixture_ctx,
        [
            "run",
            "-d",
            "--name",
            container,
            "-p",
            f"127.0.0.1:{port}:445",
            "-v",
            cli.mount_arg(share, "/share", readonly=True),
            cli.SMB_IMAGE,
            "-u",
            "flux;fluxpass",
            "-s",
            "flux;/share;yes;no;no;flux",
        ],
        timeout=180,
    )
    cli.wait_for_tcp("127.0.0.1", port, timeout=45)
    return GuiCaseSpec(
        "win-gui-smb-local-docker",
        "smb",
        f"smb://flux:fluxpass@127.0.0.1:{port}/flux/{sample_name}",
        "windows-gui-smb.txt",
        cli.sha256_bytes(payload),
        payload,
        "原生 Tauri GUI Docker Samba SMB2/3 共享读取文件并落盘",
        timeout=140,
    )


def prepare_p2p_cases(ctx: GuiContext, fixture_ctx: Any) -> list[GuiCaseSpec]:
    if not cli.docker_available():
        raise VerifyError("Docker is required for torrent/magnet fixture")
    tracker_port = cli.free_port()
    rpc_port = cli.free_port()
    peer_port = cli.free_port()
    cli.start_tracker(fixture_ctx, tracker_port)

    seed = ctx.work_dir / "p2p" / "seed"
    seed.mkdir(parents=True, exist_ok=True)
    sample_name = "windows-gui-p2p-sample.txt"
    payload = b"fluxdown windows gui torrent sample\n"
    (seed / sample_name).write_bytes(payload)
    torrent_file = ctx.work_dir / "p2p" / "windows-gui-p2p-sample.torrent"
    tracker_url = f"http://host.docker.internal:{tracker_port}/announce"
    cli.docker(
        fixture_ctx,
        [
            "run",
            "--rm",
            "-v",
            cli.mount_arg(ctx.work_dir / "p2p", "/work"),
            "--entrypoint",
            "transmission-create",
            cli.TRANSMISSION_IMAGE,
            "-o",
            "/work/windows-gui-p2p-sample.torrent",
            "-t",
            tracker_url,
            f"/work/seed/{sample_name}",
        ],
        timeout=180,
    )
    show = cli.docker(
        fixture_ctx,
        [
            "run",
            "--rm",
            "-v",
            cli.mount_arg(ctx.work_dir / "p2p", "/work"),
            "--entrypoint",
            "transmission-show",
            cli.TRANSMISSION_IMAGE,
            "/work/windows-gui-p2p-sample.torrent",
        ],
        timeout=120,
    )
    info_hash = cli.parse_transmission_hash(show.stdout)
    container = f"fluxdown-win-gui-transmission-{os.getpid()}"
    fixture_ctx.containers.append(container)
    cli.docker(
        fixture_ctx,
        [
            "run",
            "-d",
            "--name",
            container,
            "-p",
            f"127.0.0.1:{rpc_port}:9091",
            "-p",
            f"127.0.0.1:{peer_port}:{peer_port}",
            "-v",
            cli.mount_arg(ctx.work_dir / "p2p", "/work"),
            "--entrypoint",
            "transmission-daemon",
            cli.TRANSMISSION_IMAGE,
            "-g",
            "/work/config",
            "-w",
            "/work/seed",
            "-p",
            "9091",
            "-P",
            str(peer_port),
            "-r",
            "0.0.0.0",
            "-a",
            "127.0.0.1,0.0.0.0",
            "-T",
            "--no-dht",
            "--no-portmap",
            "--foreground",
        ],
        timeout=180,
    )
    cli.wait_for_transmission(fixture_ctx, container)
    cli.docker(
        fixture_ctx,
        ["exec", container, "transmission-remote", "127.0.0.1:9091", "-a", "/work/windows-gui-p2p-sample.torrent"],
        timeout=60,
    )
    cli.docker(
        fixture_ctx,
        ["exec", container, "transmission-remote", "127.0.0.1:9091", "-t", "all", "--reannounce"],
        timeout=60,
    )
    cli.wait_for_tcp("127.0.0.1", peer_port, timeout=30)
    cli.wait_for_tracker_peer(fixture_ctx, container, info_hash, peer_port)

    expected_sha = cli.sha256_bytes(payload)
    magnet = (
        f"magnet:?xt=urn:btih:{info_hash}&dn={urllib.parse.quote(sample_name)}"
        f"&tr={urllib.parse.quote(tracker_url, safe='')}"
    )
    return [
        GuiCaseSpec(
            "win-gui-torrent-local-docker-seed",
            "torrent",
            str(torrent_file),
            "windows-gui-p2p-sample.torrent",
            expected_sha,
            payload,
            "原生 Tauri GUI 本地 .torrent + Docker Transmission 做种后真实文件落盘",
            timeout=200,
        ),
        GuiCaseSpec(
            "win-gui-magnet-local-docker-seed",
            "magnet",
            magnet,
            "windows-gui-magnet",
            expected_sha,
            payload,
            "原生 Tauri GUI 同一 Docker seeder 通过 magnet 获取 metadata 后真实文件落盘",
            timeout=220,
        ),
    ]


def ed2k_case(ctx: GuiContext) -> GuiCaseSpec:
    return GuiCaseSpec(
        "win-gui-ed2k-system-handoff",
        "ed2k",
        "ed2k://|file|windows-gui-ed2k-sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/",
        "windows-gui-ed2k-sample.bin",
        None,
        None,
        "原生 Tauri GUI 创建并启动 ed2k 任务；验证系统/aMule 移交成功或清晰失败，不冒充内建下载",
        timeout=45,
    )


def write_results(ctx: GuiContext) -> None:
    ctx.output_json.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "platform": sys.platform,
        "desktop_app": str(ctx.app),
        "dev_url": DEFAULT_DEV_URL,
        "debug_port": ctx.debug_port,
        "work_dir": str(ctx.work_dir),
        "page_identity": ctx.page_identity,
        "settings_validation": ctx.settings_validation,
        "screenshots": {
            "settings": str(ctx.settings_screenshot),
            "queue": str(ctx.queue_screenshot),
        },
        "results": [asdict(result) for result in ctx.results],
    }
    ctx.output_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def cleanup(ctx: GuiContext, fixture_ctx: Any) -> None:
    for process in reversed(ctx.processes):
        if process.poll() is None:
            # 作者: long
            # 验证脚本只清理自己启动的 Tauri/Vite 进程树，避免残留调试端口和后台窗口影响下一轮 GUI 验证。
            with contextlib.suppress(Exception):
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=15,
                )
    cli.cleanup(fixture_ctx)
    if not ctx.keep_work_dir:
        shutil.rmtree(ctx.work_dir, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify FluxDown Windows native Tauri desktop GUI protocol downloads."
    )
    parser.add_argument("--app", type=pathlib.Path, default=DEFAULT_APP)
    parser.add_argument("--fluxdown", type=pathlib.Path, default=DEFAULT_FLUXDOWN)
    parser.add_argument("--output-json", type=pathlib.Path, default=DEFAULT_OUTPUT_JSON)
    parser.add_argument("--queue-screenshot", type=pathlib.Path, default=DEFAULT_QUEUE_SCREENSHOT)
    parser.add_argument("--settings-screenshot", type=pathlib.Path, default=DEFAULT_SETTINGS_SCREENSHOT)
    parser.add_argument("--work-dir", type=pathlib.Path)
    parser.add_argument("--keep-work-dir", action="store_true")
    parser.add_argument("--skip-docker", action="store_true")
    parser.add_argument("--debug-port", type=int, default=0)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    app = args.app.resolve()
    if not app.exists():
        raise VerifyError(f"desktop app binary does not exist: {app}")
    fluxdown = args.fluxdown.resolve()
    work_dir = args.work_dir or pathlib.Path(tempfile.mkdtemp(prefix="fluxdown-win-gui-protocols-"))
    work_dir.mkdir(parents=True, exist_ok=True)
    ctx = GuiContext(
        app=app,
        fluxdown=fluxdown,
        work_dir=work_dir.resolve(),
        keep_work_dir=args.keep_work_dir,
        debug_port=args.debug_port or free_port(),
        output_json=args.output_json.resolve(),
        queue_screenshot=args.queue_screenshot.resolve(),
        settings_screenshot=args.settings_screenshot.resolve(),
    )
    fixture_ctx = cli.Context(
        fluxdown=fluxdown,
        work_dir=ctx.work_dir,
        keep_work_dir=True,
    )
    driver: GuiDriver | None = None
    print(f"Native desktop app: {ctx.app}")
    print(f"Work dir: {ctx.work_dir}")
    print(f"CDP port: {ctx.debug_port}")
    try:
        fixtures = cli.setup_basic_fixtures(fixture_ctx)
        cases = local_cases(fixtures)
        if not args.skip_docker:
            cases.append(prepare_sftp_case(ctx, fixture_ctx))
            cases.append(prepare_smb_case(ctx, fixture_ctx))
            cases.extend(prepare_p2p_cases(ctx, fixture_ctx))
        else:
            print("[SKIP] Docker-backed SFTP/SMB/Torrent/Magnet GUI cases")
        cases.append(ed2k_case(ctx))

        driver = launch_native_app(ctx, DEFAULT_DEV_URL)
        ctx.page_identity = driver.page_identity()
        if not ctx.page_identity.get("bodyTextLength"):
            raise VerifyError(f"native window rendered blank page: {ctx.page_identity}")
        ctx.settings_validation = run_settings_validation(driver, ctx)

        for case in cases:
            print(f"[GUI] {case.id} {case.protocol}")
            result = run_gui_case(driver, ctx, case)
            ctx.results.append(result)
            print(f"[PASS] {case.id} state={result.gui_state} sha={result.sha256 or 'n/a'}")

        driver.screenshot(ctx.queue_screenshot)
        expected_protocols = {
            "http",
            "https",
            "webdav",
            "webdavs",
            "ftp",
            "ftps",
            "ed2k",
            "m3u8",
            "ipfs",
        }
        if not args.skip_docker:
            expected_protocols.update({"sftp", "smb", "torrent", "magnet"})
        passed_protocols = {result.protocol for result in ctx.results if result.status == "passed"}
        missing = sorted(expected_protocols - passed_protocols)
        if missing:
            raise VerifyError(f"missing GUI protocol results: {', '.join(missing)}")
        write_results(ctx)
        print(f"Result JSON: {ctx.output_json}")
        print(f"Queue screenshot: {ctx.queue_screenshot}")
        print(f"Settings screenshot: {ctx.settings_screenshot}")
        return 0
    finally:
        if driver:
            driver.close()
        write_results(ctx)
        cleanup(ctx, fixture_ctx)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        raise SystemExit(1)
