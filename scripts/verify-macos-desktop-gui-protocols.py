#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import hashlib
import importlib.util
import json
import os
import pathlib
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_APP = (
    ROOT_DIR
    / "target"
    / "release"
    / "bundle"
    / "macos"
    / "FluxDown.app"
    / "Contents"
    / "MacOS"
    / "fluxdown-desktop"
)
DEFAULT_FLUXDOWN = ROOT_DIR / "target" / "release" / "fluxdown"
DEFAULT_OUTPUT_JSON = (
    ROOT_DIR
    / "docs"
    / "artifacts"
    / "macos-desktop-gui-protocol-e2e-20260805.json"
)
DEFAULT_QUEUE_SCREENSHOT = (
    ROOT_DIR / "docs" / "artifacts" / "macos-desktop-gui-queue-20260805.png"
)


class VerifyError(RuntimeError):
    pass


def load_windows_gui_module() -> Any:
    module_path = ROOT_DIR / "scripts" / "verify-windows-desktop-gui-protocols.py"
    spec = importlib.util.spec_from_file_location("windows_desktop_gui_protocols", module_path)
    if spec is None or spec.loader is None:
        raise VerifyError(f"cannot load fixture module: {module_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


win = load_windows_gui_module()
cli = win.cli


@dataclass
class MacCaseResult:
    id: str
    protocol: str
    source: str
    status: str
    gui_state: str | None = None
    output_path: str | None = None
    bytes_written: int | None = None
    sha256: str | None = None
    started_at_ms: int | None = None
    finished_at_ms: int | None = None
    duration_ms: int = 0
    expectation: str = ""
    detail: str = ""


@dataclass
class MacContext:
    app: pathlib.Path
    fluxdown: pathlib.Path
    work_dir: pathlib.Path
    keep_work_dir: bool
    output_json: pathlib.Path
    queue_screenshot: pathlib.Path
    results: list[MacCaseResult] = field(default_factory=list)
    app_process: subprocess.Popen[Any] | None = None

    @property
    def xdg_dir(self) -> pathlib.Path:
        return self.work_dir / "xdg"

    @property
    def store_path(self) -> pathlib.Path:
        return self.xdg_dir / "fluxdown" / "queue.json"


class MacAccessibilityDriver:
    def __init__(self, process_name: str = "fluxdown-desktop"):
        self.process_name = process_name

    def _osascript(self, lines: list[str], *, timeout: int = 20) -> str:
        command = ["osascript"]
        for line in lines:
            command.extend(["-e", line])
        result = subprocess.run(
            command,
            cwd=ROOT_DIR,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            raise VerifyError(f"AppleScript failed: {detail}")
        return result.stdout.strip()

    def wait_for_window(self, timeout: float = 30.0) -> None:
        deadline = time.monotonic() + timeout
        last_error = ""
        while time.monotonic() < deadline:
            try:
                output = self._osascript(
                    [
                        'tell application "System Events"',
                        f'if exists process "{self.process_name}" then',
                        f'tell process "{self.process_name}" to return name of window 1',
                        "end if",
                        "end tell",
                    ],
                    timeout=5,
                )
                if output == "FluxDown":
                    return
            except Exception as error:
                last_error = str(error)
            time.sleep(0.25)
        raise VerifyError(f"timed out waiting for native FluxDown window: {last_error}")

    def activate(self) -> None:
        self._osascript(
            [
                'tell application "System Events"',
                f'tell process "{self.process_name}" to set frontmost to true',
                "end tell",
            ]
        )

    def click_main_button(self, name: str) -> None:
        self.activate()
        self._osascript(
            [
                'tell application "System Events"',
                f'tell process "{self.process_name}"',
                f'click button {json.dumps(name, ensure_ascii=False)} of group 1 of UI element 1 of scroll area 1 of group 1 of group 1 of window 1',
                "end tell",
                "end tell",
            ]
        )

    def _dialog_control_rect(self, role: str, group_index: int) -> tuple[int, int, int, int]:
        reference = (
            f"{role} 1 of group {group_index} of UI element 1 of scroll area 1 "
            "of group 1 of group 1 of window 1"
        )
        output = self._osascript(
            [
                'tell application "System Events"',
                f'tell process "{self.process_name}" to return {{position of {reference}, size of {reference}}}',
                "end tell",
            ]
        )
        values = [int(value.strip()) for value in output.split(",")]
        if len(values) != 4:
            raise VerifyError(f"unexpected accessibility rect for {role} group {group_index}: {output}")
        return values[0], values[1], values[2], values[3]

    def _paste_control(self, role: str, group_index: int, value: str) -> None:
        x, y, width, height = self._dialog_control_rect(role, group_index)
        point_x = x + min(max(width // 3, 20), width - 4)
        point_y = y + max(height // 2, 4)
        self._paste_at(point_x, point_y, value)

    def _paste_at(self, point_x: int, point_y: int, value: str) -> None:
        self.activate()
        self._osascript(
            [
                'tell application "System Events"',
                f"click at {{{point_x}, {point_y}}}",
                f'set focusedElement to value of attribute "AXFocusedUIElement" of process "{self.process_name}"',
                f'set value of focusedElement to {json.dumps(value, ensure_ascii=False)}',
                "end tell",
            ]
        )

    def _dialog_control_value(self, role: str, group_index: int) -> str:
        reference = (
            f"{role} 1 of group {group_index} of UI element 1 of scroll area 1 "
            "of group 1 of group 1 of window 1"
        )
        return self._osascript(
            [
                'tell application "System Events"',
                f'tell process "{self.process_name}" to return value of {reference}',
                "end tell",
            ]
        )

    def _click_dialog_button(self, name: str, torrent_like: bool) -> None:
        group_index = 7 if torrent_like else 6
        self.activate()
        self._osascript(
            [
                'tell application "System Events"',
                f'tell process "{self.process_name}"',
                f'click button {json.dumps(name, ensure_ascii=False)} of group {group_index} of UI element 1 of scroll area 1 of group 1 of group 1 of window 1',
                "end tell",
                "end tell",
            ]
        )

    def add_task(self, case: Any, output_dir: pathlib.Path) -> None:
        output_dir.mkdir(parents=True, exist_ok=True)
        self.click_main_button("新建")
        time.sleep(0.3)

        self._paste_control("text area", 2, case.source)
        # 作者: long
        # 链接输入后桌面端会异步识别协议并重绘弹框；等待重绘完成后再逐项读取新的辅助功能矩形，避免使用旧坐标。
        time.sleep(0.8)
        self._paste_control("text field", 3, case.output_name)
        self._paste_control("text field", 4, str(output_dir))
        if case.expected_sha256:
            self._paste_control("text field", 5, case.expected_sha256)
        torrent_like = case.protocol in {"torrent", "magnet"}
        if torrent_like and case.torrent_indices:
            self._paste_control("text field", 6, case.torrent_indices)
        expected_values = [
            ("text area", 2, case.source),
            ("text field", 3, case.output_name),
            ("text field", 4, str(output_dir)),
        ]
        if case.expected_sha256:
            expected_values.append(("text field", 5, case.expected_sha256))
        for role, group_index, expected in expected_values:
            actual = self._dialog_control_value(role, group_index)
            if actual != expected:
                raise VerifyError(
                    f"dialog field mismatch {role} group={group_index}: expected={expected!r} actual={actual!r}"
                )
        self._click_dialog_button("创建任务", torrent_like)

    def start_queue(self) -> None:
        self.click_main_button("开始队列")

    def screenshot_window(self, path: pathlib.Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.activate()
        output = self._osascript(
            [
                'tell application "System Events"',
                f'tell process "{self.process_name}" to return {{position of window 1, size of window 1}}',
                "end tell",
            ]
        )
        x, y, width, height = [int(value.strip()) for value in output.split(",")]
        result = subprocess.run(
            ["screencapture", "-x", f"-R{x},{y},{width},{height}", str(path)],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode != 0 or not path.exists():
            raise VerifyError(result.stderr.strip() or f"failed to capture {path}")

    def dismiss_modal(self) -> None:
        self.activate()
        # 作者: long
        # ed2k 外部移交完成后前端可能仍保留文件确认弹层；截图前发送 Escape，只关闭当前弹层，不改变已经完成的任务状态。
        self._osascript(
            [
                'tell application "System Events"',
                f'tell process "{self.process_name}" to key code 53',
                "end tell",
            ]
        )
        time.sleep(0.5)


def read_tasks(store_path: pathlib.Path) -> list[dict[str, Any]]:
    if not store_path.exists():
        return []
    for _ in range(5):
        try:
            payload = json.loads(store_path.read_text(encoding="utf-8"))
            return list(payload.get("tasks", []))
        except (OSError, json.JSONDecodeError):
            time.sleep(0.1)
    return []


def find_task(store_path: pathlib.Path, output_dir: pathlib.Path) -> dict[str, Any] | None:
    expected = str(output_dir)
    return next(
        (task for task in read_tasks(store_path) if str(task.get("output_dir")) == expected),
        None,
    )


def wait_for_task(
    store_path: pathlib.Path,
    output_dir: pathlib.Path,
    states: set[str] | None,
    *,
    timeout: float,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    snapshot: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        snapshot = find_task(store_path, output_dir)
        if snapshot and (states is None or str(snapshot.get("state")) in states):
            return snapshot
        time.sleep(0.25)
    raise VerifyError(
        f"timed out waiting for task {output_dir} states={sorted(states) if states else 'created'}; "
        f"last={snapshot}"
    )


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def find_output_file(output_dir: pathlib.Path, expected_sha256: str) -> pathlib.Path:
    candidates = [path for path in output_dir.rglob("*") if path.is_file()]
    for candidate in candidates:
        if sha256_file(candidate) == expected_sha256:
            return candidate
    listed = ", ".join(str(path) for path in candidates[:20])
    raise VerifyError(f"no output file with expected sha256 in {output_dir}; files={listed}")


def local_lan_ip() -> str:
    route = subprocess.run(
        ["route", "-n", "get", "default"],
        capture_output=True,
        text=True,
        timeout=10,
    )
    interface = ""
    if route.returncode == 0:
        for line in route.stdout.splitlines():
            if line.strip().startswith("interface:"):
                interface = line.split(":", 1)[1].strip()
                break
    if interface:
        address = subprocess.run(
            ["ipconfig", "getifaddr", interface],
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout.strip()
        if address and not address.startswith("127."):
            return address

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.connect(("8.8.8.8", 80))
        address = str(sock.getsockname()[0])
    if address.startswith("127."):
        raise VerifyError("could not determine a non-loopback macOS LAN address")
    return address


def setup_macos_basic_fixtures(fixture_ctx: Any, host: str) -> dict[str, Any]:
    http_port = cli.free_port()
    https_port = cli.free_port()
    ftp_port = cli.free_port()
    ftps_port = cli.free_port()
    cert_file, key_file = cli.create_tls_files(fixture_ctx.work_dir)

    payloads = {
        "http": b"fluxdown macos gui http sample\n",
        "https": b"fluxdown macos gui https sample\n",
        "webdav": b"fluxdown macos gui webdav sample\n",
        "webdavs": b"fluxdown macos gui webdavs sample\n",
        "ftp": b"fluxdown macos gui ftp sample\n",
        "ftps": b"fluxdown macos gui ftps sample\n",
    }
    hls_dir = fixture_ctx.work_dir / "hls-media"
    hls_dir.mkdir(parents=True, exist_ok=True)
    playlist_path = hls_dir / "playlist.m3u8"
    # 作者: long
    # GUI 协议验收需要证明 HLS 产物是可播放媒体，而不只是文本分片被拼接；动态生成 2 秒 H.264/AAC VOD 可保持资源很小且结果可重复。
    cli.run_command(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=160x90:rate=10",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=880:sample_rate=44100",
            "-t",
            "2",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-pix_fmt",
            "yuv420p",
            "-g",
            "10",
            "-sc_threshold",
            "0",
            "-c:a",
            "aac",
            "-b:a",
            "32k",
            "-f",
            "hls",
            "-hls_time",
            "1",
            "-hls_playlist_type",
            "vod",
            "-hls_segment_filename",
            str(hls_dir / "segment-%02d.ts"),
            str(playlist_path),
        ],
        cwd=fixture_ctx.work_dir,
        timeout=60,
    )
    playlist = playlist_path.read_bytes()
    segment_names = [
        line.strip()
        for line in playlist.decode("utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]
    if not segment_names:
        raise VerifyError("ffmpeg generated an HLS playlist without media segments")
    segment_payloads = {name: (hls_dir / name).read_bytes() for name in segment_names}
    payloads["m3u8"] = b"".join(segment_payloads[name] for name in segment_names)
    hls_routes = {f"/{name}": payload for name, payload in segment_payloads.items()}
    cli.start_http_fixture(
        fixture_ctx,
        host="0.0.0.0",
        port=http_port,
        routes={
            "/http.txt": payloads["http"],
            "/webdav.txt": payloads["webdav"],
            "/playlist.m3u8": playlist,
            **hls_routes,
        },
    )
    cli.start_http_fixture(
        fixture_ctx,
        host="0.0.0.0",
        port=https_port,
        routes={
            "/https.txt": payloads["https"],
            "/webdavs.txt": payloads["webdavs"],
        },
        cert_file=cert_file,
        key_file=key_file,
    )
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.load_cert_chain(str(cert_file), str(key_file))
    ftp = cli.FtpFixture(
        port=ftp_port,
        payload=payloads["ftp"],
        bind_host="0.0.0.0",
    )
    ftps = cli.FtpFixture(
        port=ftps_port,
        payload=payloads["ftps"],
        tls_context=tls_context,
        bind_host="0.0.0.0",
    )
    ftp.start()
    ftps.start()
    fixture_ctx.ftp_fixtures.extend([ftp, ftps])
    return {
        "host": host,
        "http_port": http_port,
        "https_port": https_port,
        "ftp_port": ftp_port,
        "ftps_port": ftps_port,
        "payloads": payloads,
    }


def macos_local_cases(fixtures: dict[str, Any]) -> list[Any]:
    host = fixtures["host"]
    payloads = fixtures["payloads"]
    http_port = fixtures["http_port"]
    https_port = fixtures["https_port"]
    ftp_port = fixtures["ftp_port"]
    ftps_port = fixtures["ftps_port"]
    specs = [
        (
            "macos-gui-http-local",
            "http",
            f"http://{host}:{http_port}/http.txt",
            "macos-gui-http.txt",
            payloads["http"],
            "macOS 原生 Tauri GUI 通过局域网 HTTP 真实落盘",
        ),
        (
            "macos-gui-https-local-self-signed",
            "https",
            f"https://{host}:{https_port}/https.txt?allowBadCertificate=true",
            "macos-gui-https.txt",
            payloads["https"],
            "macOS 原生 Tauri GUI 通过自签 HTTPS opt-in 真实落盘",
        ),
        (
            "macos-gui-webdav-local-transport",
            "webdav",
            f"webdav://{host}:{http_port}/webdav.txt",
            "macos-gui-webdav.txt",
            payloads["webdav"],
            "macOS 原生 Tauri GUI WebDAV transport 映射 HTTP 后真实落盘",
        ),
        (
            "macos-gui-webdavs-local-transport",
            "webdavs",
            f"webdavs://{host}:{https_port}/webdavs.txt?allowBadCertificate=true",
            "macos-gui-webdavs.txt",
            payloads["webdavs"],
            "macOS 原生 Tauri GUI WebDAVS transport 映射 HTTPS 后真实落盘",
        ),
        (
            "macos-gui-ftp-local",
            "ftp",
            f"ftp://flux:fluxpass@{host}:{ftp_port}/ftp-sample.txt",
            "macos-gui-ftp.txt",
            payloads["ftp"],
            "macOS 原生 Tauri GUI FTP EPSV/RETR 真实落盘",
        ),
        (
            "macos-gui-ftps-local-explicit",
            "ftps",
            f"ftps://flux:fluxpass@{host}:{ftps_port}/ftps-sample.txt?allowBadCertificate=true",
            "macos-gui-ftps.txt",
            payloads["ftps"],
            "macOS 原生 Tauri GUI 显式 FTPS 控制和数据连接 TLS 真实落盘",
        ),
        (
            "macos-gui-m3u8-local-vod",
            "m3u8",
            f"http://{host}:{http_port}/playlist.m3u8",
            "macos-gui-hls.ts",
            payloads["m3u8"],
            "macOS 原生 Tauri GUI 下载 2 秒 H.264/AAC VOD m3u8，按顺序合并并通过 ffprobe 校验",
        ),
    ]
    cases = []
    for case_id, protocol, source, output_name, payload, expectation in specs:
        # 作者: long
        # HLS 会从 TS 分片重新封装为 MP4，容器字节不应和原始分片拼接 hash 相同；该用例改由 ffprobe 和实际输出 hash 验证。
        expected_sha256 = None if protocol == "m3u8" else cli.sha256_bytes(payload)
        expected_bytes = None if protocol == "m3u8" else payload
        cases.append(
            win.GuiCaseSpec(
                case_id,
                protocol,
                source,
                output_name,
                expected_sha256,
                expected_bytes,
                expectation,
            )
        )
    return cases


def prepare_macos_sftp_case(ctx: MacContext, fixture_ctx: Any, host: str) -> Any:
    port = cli.free_port()
    upload = ctx.work_dir / "sftp-upload"
    upload.mkdir(parents=True, exist_ok=True)
    payload = b"fluxdown macos gui sftp sample\n"
    sample_name = "macos-gui-sftp-sample.txt"
    (upload / sample_name).write_bytes(payload)
    container = f"fluxdown-macos-gui-sftp-{os.getpid()}"
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
            f"{port}:22",
            "-v",
            cli.mount_arg(upload, "/home/flux/upload", readonly=True),
            cli.SFTP_IMAGE,
            "flux:fluxpass:::upload",
        ],
        timeout=180,
    )
    cli.wait_for_sftp_banner("127.0.0.1", port, fixture_ctx, container)
    return win.GuiCaseSpec(
        "macos-gui-sftp-local-docker",
        "sftp",
        f"sftp://flux:fluxpass@{host}:{port}/upload/{sample_name}",
        "macos-gui-sftp.txt",
        cli.sha256_bytes(payload),
        payload,
        "macOS 原生 Tauri GUI 通过 Docker SFTP 密码认证真实落盘",
        timeout=120,
    )


def prepare_macos_smb_case(ctx: MacContext, fixture_ctx: Any, host: str) -> Any:
    port = cli.free_port()
    share = ctx.work_dir / "smb-share"
    share.mkdir(parents=True, exist_ok=True)
    payload = b"fluxdown macos gui smb sample\n"
    sample_name = "macos-gui-smb-sample.txt"
    (share / sample_name).write_bytes(payload)
    container = f"fluxdown-macos-gui-smb-{os.getpid()}"
    fixture_ctx.containers.append(container)
    cli.docker(
        fixture_ctx,
        [
            "run",
            "-d",
            "--name",
            container,
            "-p",
            f"{port}:445",
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
    return win.GuiCaseSpec(
        "macos-gui-smb-local-docker",
        "smb",
        f"smb://flux:fluxpass@{host}:{port}/flux/{sample_name}",
        "macos-gui-smb.txt",
        cli.sha256_bytes(payload),
        payload,
        "macOS 原生 Tauri GUI 通过 Docker Samba SMB2/3 共享真实落盘",
        timeout=140,
    )


def prepare_macos_p2p_cases(ctx: MacContext, fixture_ctx: Any, host: str) -> list[Any]:
    tracker_port = cli.free_port()
    rpc_port = cli.free_port()
    peer_port = cli.free_port()
    cli.start_tracker(fixture_ctx, tracker_port, advertised_ip=host)
    seed = ctx.work_dir / "p2p" / "seed"
    seed.mkdir(parents=True, exist_ok=True)
    sample_name = "macos-gui-p2p-sample.txt"
    payload = b"fluxdown macos gui torrent sample\n"
    (seed / sample_name).write_bytes(payload)
    torrent_file = ctx.work_dir / "p2p" / "macos-gui-p2p-sample.torrent"
    tracker_url = f"http://{host}:{tracker_port}/announce"
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
            "/work/macos-gui-p2p-sample.torrent",
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
            "/work/macos-gui-p2p-sample.torrent",
        ],
        timeout=120,
    )
    info_hash = cli.parse_transmission_hash(show.stdout)
    container = f"fluxdown-macos-gui-transmission-{os.getpid()}"
    fixture_ctx.containers.append(container)
    cli.docker(
        fixture_ctx,
        [
            "run",
            "-d",
            "--name",
            container,
            "-p",
            f"{rpc_port}:9091",
            "-p",
            f"{peer_port}:{peer_port}",
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
        ["exec", container, "transmission-remote", "127.0.0.1:9091", "-a", "/work/macos-gui-p2p-sample.torrent"],
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
        win.GuiCaseSpec(
            "macos-gui-torrent-local-docker-seed",
            "torrent",
            str(torrent_file),
            "macos-gui-p2p-sample.torrent",
            expected_sha,
            payload,
            "macOS 原生 Tauri GUI 通过本地 .torrent 和 Docker seeder 真实落盘",
            timeout=200,
        ),
        win.GuiCaseSpec(
            "macos-gui-magnet-local-docker-seed",
            "magnet",
            magnet,
            "macos-gui-magnet",
            expected_sha,
            payload,
            "macOS 原生 Tauri GUI 通过 magnet 获取 metadata 后真实落盘",
            timeout=220,
        ),
    ]


def launch_app(ctx: MacContext) -> MacAccessibilityDriver:
    env = os.environ.copy()
    env["XDG_DATA_HOME"] = str(ctx.xdg_dir)
    ctx.app_process = subprocess.Popen(
        [str(ctx.app)],
        cwd=ROOT_DIR,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    driver = MacAccessibilityDriver()
    driver.wait_for_window()
    driver.activate()
    time.sleep(1.0)
    return driver


def close_thunder_before_test() -> None:
    subprocess.run(
        ["osascript", "-e", 'tell application "Thunder" to quit'],
        cwd=ROOT_DIR,
        capture_output=True,
        text=True,
        timeout=15,
    )
    time.sleep(0.5)


def dismiss_thunder_after_handoff() -> None:
    subprocess.run(
        [
            "osascript",
            "-e",
            'tell application "System Events"',
            "-e",
            'if exists process "Thunder" then',
            "-e",
            'tell process "Thunder" to set frontmost to true',
            "-e",
            "key code 53",
            "-e",
            'keystroke "h" using command down',
            "-e",
            "end if",
            "-e",
            "end tell",
        ],
        cwd=ROOT_DIR,
        capture_output=True,
        text=True,
        timeout=15,
    )


def run_case(driver: MacAccessibilityDriver, ctx: MacContext, case: Any) -> MacCaseResult:
    output_dir = ctx.work_dir / "downloads" / case.id
    started = time.monotonic()
    try:
        driver.add_task(case, output_dir)
    except Exception:
        driver.screenshot_window(ctx.work_dir / f"{case.id}-dialog-failure.png")
        raise
    try:
        created = wait_for_task(ctx.store_path, output_dir, None, timeout=20)
    except Exception:
        driver.screenshot_window(ctx.work_dir / f"{case.id}-create-failure.png")
        raise
    # 作者: long
    # 用户可能开启“创建后自动开始”；先让前端完成自动启动，只有任务仍排队时才点击队列按钮，避免 start_download 与 run_queue 同时争抢同一任务。
    time.sleep(1.2)
    created = find_task(ctx.store_path, output_dir) or created
    if str(created.get("state")) in {"queued", "paused"}:
        driver.start_queue()

    target_states = {"finished", "failed"}
    task = wait_for_task(ctx.store_path, output_dir, target_states, timeout=case.timeout)
    duration_ms = int((time.monotonic() - started) * 1000)
    state = str(task.get("state"))
    detail = str(task.get("error") or "")

    if case.protocol == "ed2k":
        accepted = state == "finished" or any(
            token in detail.lower()
            for token in ["handoff", "no application", "not found", "不可用", "失败"]
        )
        if not accepted:
            raise VerifyError(f"unexpected ed2k result state={state}: {detail}")
        dismiss_thunder_after_handoff()
        return MacCaseResult(
            id=case.id,
            protocol=case.protocol,
            source=case.source,
            status="passed",
            gui_state=state,
            started_at_ms=task.get("started_at_ms"),
            finished_at_ms=task.get("finished_at_ms"),
            duration_ms=duration_ms,
            expectation=case.expectation,
            detail=detail or "系统已接收 ed2k 移交",
        )

    if state != "finished":
        raise VerifyError(f"{case.id} failed: {detail}")
    if case.protocol == "m3u8":
        media_outputs = [path for path in output_dir.rglob("*") if path.is_file()]
        if len(media_outputs) != 1:
            raise VerifyError(f"expected one HLS media output in {output_dir}, found {media_outputs}")
        output_path = media_outputs[0]
    else:
        if not case.expected_sha256:
            raise VerifyError(f"{case.id} is missing expected sha256")
        output_path = find_output_file(output_dir, case.expected_sha256)
    if case.expected_bytes is not None and output_path.read_bytes() != case.expected_bytes:
        raise VerifyError(f"{case.id} output content mismatch: {output_path}")
    if case.protocol == "m3u8":
        # 作者: long
        # HLS 文件内容匹配只能证明分片顺序正确；再用 ffprobe 确认合并结果包含真实音视频流，避免把伪媒体 fixture 记成协议通过。
        probe = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format=format_name,duration",
                "-of",
                "json",
                str(output_path),
            ],
            cwd=ROOT_DIR,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if probe.returncode != 0:
            raise VerifyError(f"ffprobe rejected HLS output {output_path}: {probe.stderr.strip()}")
        probe_payload = json.loads(probe.stdout)
        media_format = probe_payload.get("format", {})
        duration = float(media_format.get("duration") or 0)
        if duration <= 0:
            raise VerifyError(f"HLS output has no positive media duration: {probe.stdout.strip()}")
        detail = (
            f"ffprobe format={media_format.get('format_name', 'unknown')} "
            f"duration={duration:.3f}s"
        )
    return MacCaseResult(
        id=case.id,
        protocol=case.protocol,
        source=case.source,
        status="passed",
        gui_state=state,
        output_path=str(output_path),
        bytes_written=output_path.stat().st_size,
        sha256=sha256_file(output_path),
        started_at_ms=task.get("started_at_ms"),
        finished_at_ms=task.get("finished_at_ms"),
        duration_ms=duration_ms,
        expectation=case.expectation,
        detail=detail,
    )


def write_results(ctx: MacContext) -> None:
    ctx.output_json.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "platform": "macos",
        "desktop_app": str(ctx.app),
        "work_dir": str(ctx.work_dir),
        "queue_store": str(ctx.store_path),
        "queue_screenshot": str(ctx.queue_screenshot),
        "results": [asdict(result) for result in ctx.results],
    }
    ctx.output_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def cleanup(ctx: MacContext, fixture_ctx: Any) -> None:
    if ctx.app_process and ctx.app_process.poll() is None:
        # 作者: long
        # 只终止本轮验证脚本启动的独立进程组，避免关闭用户自行启动的 FluxDown 实例。
        with contextlib.suppress(ProcessLookupError):
            os.killpg(ctx.app_process.pid, signal.SIGTERM)
        with contextlib.suppress(subprocess.TimeoutExpired):
            ctx.app_process.wait(timeout=8)
    cli.cleanup(fixture_ctx)
    if not ctx.keep_work_dir:
        import shutil

        shutil.rmtree(ctx.work_dir, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify FluxDown macOS native Tauri desktop GUI protocol downloads."
    )
    parser.add_argument("--app", type=pathlib.Path, default=DEFAULT_APP)
    parser.add_argument("--fluxdown", type=pathlib.Path, default=DEFAULT_FLUXDOWN)
    parser.add_argument("--output-json", type=pathlib.Path, default=DEFAULT_OUTPUT_JSON)
    parser.add_argument("--queue-screenshot", type=pathlib.Path, default=DEFAULT_QUEUE_SCREENSHOT)
    parser.add_argument("--work-dir", type=pathlib.Path)
    parser.add_argument("--keep-work-dir", action="store_true")
    parser.add_argument("--skip-docker", action="store_true")
    return parser.parse_args()


def main() -> int:
    if sys.platform != "darwin":
        raise VerifyError("this verifier requires macOS")
    args = parse_args()
    app = args.app.resolve()
    fluxdown = args.fluxdown.resolve()
    if not app.exists():
        raise VerifyError(f"desktop app does not exist: {app}")
    if not fluxdown.exists():
        raise VerifyError(f"release CLI does not exist: {fluxdown}")

    work_dir = args.work_dir or pathlib.Path(tempfile.mkdtemp(prefix="fluxdown-macos-gui-protocols-"))
    work_dir.mkdir(parents=True, exist_ok=True)
    ctx = MacContext(
        app=app,
        fluxdown=fluxdown,
        work_dir=work_dir.resolve(),
        keep_work_dir=args.keep_work_dir,
        output_json=args.output_json.resolve(),
        queue_screenshot=args.queue_screenshot.resolve(),
    )
    fixture_ctx = cli.Context(fluxdown=fluxdown, work_dir=ctx.work_dir, keep_work_dir=True)
    print(f"Native desktop app: {ctx.app}")
    print(f"Work dir: {ctx.work_dir}")
    print(f"Queue store: {ctx.store_path}")

    driver: MacAccessibilityDriver | None = None
    try:
        host = local_lan_ip()
        print(f"LAN host: {host}")
        fixtures = setup_macos_basic_fixtures(fixture_ctx, host)
        cases = macos_local_cases(fixtures)
        if not args.skip_docker:
            cases.append(prepare_macos_sftp_case(ctx, fixture_ctx, host))
            cases.append(prepare_macos_smb_case(ctx, fixture_ctx, host))
            cases.extend(prepare_macos_p2p_cases(ctx, fixture_ctx, host))
        cases.append(
            win.GuiCaseSpec(
                "macos-gui-ed2k-system-handoff",
                "ed2k",
                "ed2k://|file|macos-gui-ed2k-sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/",
                "macos-gui-ed2k-sample.bin",
                None,
                None,
                "macOS 原生 Tauri GUI 创建并启动 ed2k 任务；验证系统/aMule 移交成功或清晰失败，不冒充内建下载",
                timeout=45,
            )
        )

        close_thunder_before_test()
        driver = launch_app(ctx)
        for case in cases:
            print(f"[GUI] {case.id} {case.protocol} {case.source}")
            result = run_case(driver, ctx, case)
            ctx.results.append(result)
            write_results(ctx)
            print(f"[PASS] {case.id} state={result.gui_state} sha={result.sha256 or 'n/a'}")

        driver.dismiss_modal()
        driver.screenshot_window(ctx.queue_screenshot)
        expected = {
            "http",
            "https",
            "webdav",
            "webdavs",
            "ftp",
            "ftps",
            "sftp",
            "smb",
            "m3u8",
            "torrent",
            "magnet",
            "ed2k",
        }
        if args.skip_docker:
            expected -= {"sftp", "smb", "torrent", "magnet"}
        passed = {result.protocol for result in ctx.results if result.status == "passed"}
        missing = sorted(expected - passed)
        if missing:
            raise VerifyError(f"missing macOS GUI protocol results: {', '.join(missing)}")
        write_results(ctx)
        print(f"Result JSON: {ctx.output_json}")
        print(f"Queue screenshot: {ctx.queue_screenshot}")
        return 0
    finally:
        write_results(ctx)
        cleanup(ctx, fixture_ctx)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        raise SystemExit(1)
