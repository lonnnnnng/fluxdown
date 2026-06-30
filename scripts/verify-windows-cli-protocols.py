#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import hashlib
import http.server
import json
import os
import pathlib
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any


ROOT_DIR = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_FLUXDOWN = ROOT_DIR / "target" / "debug" / "fluxdown.exe"
TRANSMISSION_IMAGE = "lscr.io/linuxserver/transmission:latest"
SFTP_IMAGE = "atmoz/sftp"
SMB_IMAGE = "dperson/samba"
CID = "bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244"


class VerifyError(RuntimeError):
    pass


@dataclass
class CaseResult:
    id: str
    protocol: str
    source: str
    status: str
    output_path: str | None = None
    bytes_written: int | None = None
    sha256: str | None = None
    expectation: str = ""
    detail: str = ""
    command: str = ""
    duration_ms: int = 0


@dataclass
class Context:
    fluxdown: pathlib.Path
    work_dir: pathlib.Path
    keep_work_dir: bool
    results: list[CaseResult] = field(default_factory=list)
    processes: list[subprocess.Popen[Any]] = field(default_factory=list)
    http_servers: list[http.server.ThreadingHTTPServer] = field(default_factory=list)
    ftp_fixtures: list["FtpFixture"] = field(default_factory=list)
    containers: list[str] = field(default_factory=list)


def run_command(
    args: list[str],
    *,
    cwd: pathlib.Path = ROOT_DIR,
    timeout: int = 120,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    started = time.monotonic()
    completed = subprocess.run(
        args,
        cwd=str(cwd),
        text=True,
        encoding="utf-8",
        errors="replace",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )
    if check and completed.returncode != 0:
        elapsed = int((time.monotonic() - started) * 1000)
        raise VerifyError(
            f"command failed after {elapsed}ms: {' '.join(args)}\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return completed


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wait_for_tcp(host: str, port: int, *, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1):
                return
        except OSError:
            time.sleep(0.2)
    raise VerifyError(f"timed out waiting for TCP {host}:{port}")


def wait_for_http(url: str, *, timeout: float = 30.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=1) as response:  # type: ignore[attr-defined]
                if response.status == 200:
                    return
        except Exception:
            time.sleep(0.2)
    raise VerifyError(f"timed out waiting for HTTP {url}")


def make_static_handler(routes: dict[str, bytes]) -> type[http.server.BaseHTTPRequestHandler]:
    class StaticHandler(http.server.BaseHTTPRequestHandler):
        server_version = "FluxDownWindowsFixture/1.0"

        def do_HEAD(self) -> None:
            self._serve(send_body=False)

        def do_GET(self) -> None:
            self._serve(send_body=True)

        def _serve(self, *, send_body: bool) -> None:
            parsed = urllib.parse.urlsplit(self.path)
            body = routes.get(parsed.path)
            if body is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            status = 200
            headers: dict[str, str] = {"Accept-Ranges": "bytes"}
            payload = body
            range_header = self.headers.get("Range")
            if range_header and range_header.startswith("bytes="):
                start_text, _, end_text = range_header.removeprefix("bytes=").partition("-")
                start = int(start_text or "0")
                end = int(end_text) if end_text else len(body) - 1
                start = max(0, start)
                end = min(len(body) - 1, end)
                if start <= end:
                    status = 206
                    payload = body[start : end + 1]
                    headers["Content-Range"] = f"bytes {start}-{end}/{len(body)}"

            self.send_response(status)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Content-Type", content_type_for(parsed.path))
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            if send_body:
                self.wfile.write(payload)

        def log_message(self, _format: str, *_args: Any) -> None:
            return

    return StaticHandler


def content_type_for(path: str) -> str:
    if path.endswith(".m3u8"):
        return "application/vnd.apple.mpegurl"
    if path.endswith(".ts"):
        return "video/mp2t"
    return "application/octet-stream"


def start_http_fixture(
    ctx: Context,
    *,
    host: str,
    port: int,
    routes: dict[str, bytes],
    cert_file: pathlib.Path | None = None,
    key_file: pathlib.Path | None = None,
) -> None:
    server = http.server.ThreadingHTTPServer((host, port), make_static_handler(routes))
    if cert_file and key_file:
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.load_cert_chain(str(cert_file), str(key_file))
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    ctx.http_servers.append(server)
    wait_for_tcp("127.0.0.1", port)


class FtpFixture:
    def __init__(
        self,
        *,
        port: int,
        payload: bytes,
        tls_context: ssl.SSLContext | None = None,
    ) -> None:
        self.port = port
        self.payload = payload
        self.tls_context = tls_context
        self._stop = threading.Event()
        self._listener: socket.socket | None = None
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._listener = socket.socket()
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind(("127.0.0.1", self.port))
        self._listener.listen(8)
        self._listener.settimeout(0.5)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()
        wait_for_tcp("127.0.0.1", self.port)

    def stop(self) -> None:
        self._stop.set()
        if self._listener:
            with contextlib.suppress(OSError):
                self._listener.close()

    def _serve(self) -> None:
        assert self._listener is not None
        while not self._stop.is_set():
            try:
                conn, _ = self._listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._handle_client, args=(conn,), daemon=True).start()

    def _handle_client(self, conn: socket.socket) -> None:
        file = conn.makefile("rwb", buffering=0)
        data_tls: ssl.SSLContext | None = None
        control_tls = False
        send_line(file, "220 FluxDown Windows fixture FTP")
        passive_listener: socket.socket | None = None

        try:
            while True:
                command = recv_line(file)
                if command is None:
                    return
                upper = command.upper()

                if upper == "AUTH TLS" and self.tls_context is not None:
                    send_line(file, "234 Proceed with negotiation")
                    file.close()
                    conn = self.tls_context.wrap_socket(conn, server_side=True)
                    control_tls = True
                    file = conn.makefile("rwb", buffering=0)
                elif upper.startswith("USER "):
                    send_line(file, "331 Password required")
                elif upper.startswith("PASS "):
                    send_line(file, "230 Logged in")
                elif upper == "PBSZ 0":
                    send_line(file, "200 PBSZ=0")
                elif upper == "PROT P":
                    data_tls = self.tls_context
                    send_line(file, "200 Protection set")
                elif upper == "SYST":
                    send_line(file, "215 UNIX Type: L8")
                elif upper == "FEAT":
                    send_line(file, "211-Features")
                    send_line(file, " SIZE")
                    send_line(file, " REST STREAM")
                    if self.tls_context is not None:
                        send_line(file, " AUTH TLS")
                        send_line(file, " PBSZ")
                        send_line(file, " PROT")
                    send_line(file, "211 End")
                elif upper.startswith("TYPE ") or upper.startswith("OPTS "):
                    send_line(file, "200 OK")
                elif upper.startswith("SIZE "):
                    send_line(file, f"213 {len(self.payload)}")
                elif upper.startswith("REST "):
                    send_line(file, "350 Restarting at requested offset")
                elif upper == "EPSV":
                    passive_listener = socket.socket()
                    passive_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    passive_listener.bind(("127.0.0.1", 0))
                    passive_listener.listen(1)
                    port = int(passive_listener.getsockname()[1])
                    send_line(file, f"229 Entering Extended Passive Mode (|||{port}|)")
                elif upper.startswith("RETR "):
                    if passive_listener is None:
                        send_line(file, "425 Use EPSV first")
                        continue
                    send_line(file, "150 Opening data connection")
                    self._serve_data(passive_listener, data_tls)
                    passive_listener.close()
                    passive_listener = None
                    send_line(file, "226 Transfer complete")
                elif upper == "QUIT":
                    send_line(file, "221 Bye")
                    return
                else:
                    send_line(file, "200 OK")
        finally:
            with contextlib.suppress(Exception):
                file.close()
            if control_tls and isinstance(conn, ssl.SSLSocket):
                # long: FTPS 的控制连接也必须发送 close_notify；否则 Windows 上的 rustls 会在 quit/finalize 阶段把成功传输判定为异常断开。
                with contextlib.suppress(Exception):
                    conn.unwrap()
            with contextlib.suppress(Exception):
                conn.close()

    def _serve_data(
        self,
        listener: socket.socket,
        tls_context: ssl.SSLContext | None,
    ) -> None:
        data, _ = listener.accept()
        try:
            if tls_context is not None:
                data = tls_context.wrap_socket(data, server_side=True)
            data.sendall(self.payload)
            if isinstance(data, ssl.SSLSocket):
                # long: rustls 会把没有 close_notify 的 FTPS data 连接视为异常，本地 fixture 主动完成 TLS 关闭来模拟真实服务器收尾。
                with contextlib.suppress(ssl.SSLError, OSError):
                    data.unwrap()
        finally:
            with contextlib.suppress(OSError):
                data.close()


def recv_line(file: Any) -> str | None:
    try:
        line = file.readline()
    except OSError:
        return None
    if not line:
        return None
    return line.decode("utf-8", "replace").rstrip("\r\n")


def send_line(file: Any, line: str) -> None:
    file.write((line + "\r\n").encode("utf-8"))
    file.flush()


def bencode(value: Any) -> bytes:
    if isinstance(value, int):
        return b"i" + str(value).encode("ascii") + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode("ascii") + b":" + value
    if isinstance(value, str):
        return bencode(value.encode("utf-8"))
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        items = sorted(value.items(), key=lambda item: item[0])
        return b"d" + b"".join(bencode(key) + bencode(item) for key, item in items) + b"e"
    raise TypeError(f"unsupported bencode value: {type(value)!r}")


class TrackerHandler(http.server.BaseHTTPRequestHandler):
    peers: dict[bytes, dict[bytes, tuple[str, int, float]]] = {}
    lock = threading.Lock()

    def do_GET(self) -> None:
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path == "/health":
            self._send(200, b"ok")
            return
        if parsed.path != "/announce":
            self._send(404, b"")
            return

        params = parse_raw_query(parsed.query)
        info_hash = params.get(b"info_hash")
        peer_id = params.get(b"peer_id", os.urandom(20))
        port = int(params.get(b"port", b"0") or b"0")
        event = params.get(b"event", b"")
        now = time.time()

        if not info_hash or len(info_hash) != 20 or port <= 0:
            self._send(400, bencode({b"failure reason": b"invalid announce"}))
            return

        with self.lock:
            bucket = self.peers.setdefault(info_hash, {})
            stale = [key for key, (_, _, seen) in bucket.items() if now - seen > 120]
            for key in stale:
                bucket.pop(key, None)
            if event == b"stopped":
                bucket.pop(peer_id, None)
            else:
                # long: seeder 运行在 Docker 内，但 peer 端口映射到 Windows host；tracker 固定把本地 fixture peer 暴露为 127.0.0.1，保证 host 上的 FluxDown 能连到做种端口。
                bucket[peer_id] = ("127.0.0.1", port, now)
            compact = b"".join(
                socket.inet_aton(ip) + struct.pack("!H", peer_port)
                for key, (ip, peer_port, _) in bucket.items()
                if key != peer_id
            )

        self._send(200, bencode({b"complete": 1, b"incomplete": 0, b"interval": 1, b"peers": compact}))

    def _send(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, _format: str, *_args: Any) -> None:
        return


def parse_raw_query(query: str) -> dict[bytes, bytes]:
    result: dict[bytes, bytes] = {}
    for part in query.split("&"):
        if not part:
            continue
        key, _, value = part.partition("=")
        result[urllib.parse.unquote_to_bytes(key)] = urllib.parse.unquote_to_bytes(value)
    return result


def start_tracker(ctx: Context, port: int) -> None:
    TrackerHandler.peers.clear()
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), TrackerHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    ctx.http_servers.append(server)
    wait_for_http(f"http://127.0.0.1:{port}/health")


def create_tls_files(work_dir: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    cert_file = work_dir / "localhost.crt"
    key_file = work_dir / "localhost.key"
    helper = work_dir / "make_cert.py"
    venv_dir = work_dir / "cert-venv"
    helper.write_text(
        """
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID
from datetime import datetime, timedelta, timezone
import ipaddress
import pathlib
import sys

cert_path = pathlib.Path(sys.argv[1])
key_path = pathlib.Path(sys.argv[2])
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "127.0.0.1")])
cert = (
    x509.CertificateBuilder()
    .subject_name(subject)
    .issuer_name(issuer)
    .public_key(key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(datetime.now(timezone.utc) - timedelta(days=1))
    .not_valid_after(datetime.now(timezone.utc) + timedelta(days=30))
    .add_extension(
        x509.SubjectAlternativeName([
            x509.DNSName("localhost"),
            x509.IPAddress(ipaddress.ip_address("127.0.0.1")),
        ]),
        critical=False,
    )
    .sign(key, hashes.SHA256())
)
cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
key_path.write_bytes(
    key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
)
""".strip(),
        encoding="utf-8",
    )
    run_command([sys.executable, "-m", "venv", str(venv_dir)], timeout=120)
    python = venv_dir / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    run_command([str(python), "-m", "pip", "install", "--quiet", "cryptography"], timeout=240)
    run_command([str(python), str(helper), str(cert_file), str(key_file)], timeout=30)
    return cert_file, key_file


def fluxdown_download(
    ctx: Context,
    *,
    case_id: str,
    protocol: str,
    source: str,
    output_dir: pathlib.Path,
    name: str | None,
    expected_sha256: str | None,
    expected_bytes: bytes | None = None,
    timeout: int = 120,
    extra_args: list[str] | None = None,
    expectation: str = "",
) -> CaseResult:
    output_dir.mkdir(parents=True, exist_ok=True)
    args = [str(ctx.fluxdown), "download", source, "--output", str(output_dir)]
    if name:
        args.extend(["--name", name])
    if expected_sha256:
        args.extend(["--sha256", expected_sha256])
    if extra_args:
        args.extend(extra_args)

    started = time.monotonic()
    completed = run_command(args, timeout=timeout)
    duration_ms = int((time.monotonic() - started) * 1000)
    try:
        summary = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise VerifyError(f"{case_id} did not return JSON: {error}\n{completed.stdout}") from error

    output_path = pathlib.Path(summary["output_path"])
    if not output_path.exists():
        raise VerifyError(f"{case_id} output path missing: {output_path}")
    actual_sha = sha256_file(output_path)
    if expected_sha256 and actual_sha != expected_sha256:
        raise VerifyError(f"{case_id} sha mismatch: expected {expected_sha256}, got {actual_sha}")
    if expected_bytes is not None and output_path.read_bytes() != expected_bytes:
        raise VerifyError(f"{case_id} output content mismatch: {output_path}")
    if summary.get("protocol") != protocol:
        raise VerifyError(f"{case_id} protocol mismatch: {summary.get('protocol')} != {protocol}")

    result = CaseResult(
        id=case_id,
        protocol=protocol,
        source=source,
        status="passed",
        output_path=str(output_path),
        bytes_written=int(summary.get("bytes_written", output_path.stat().st_size)),
        sha256=actual_sha,
        expectation=expectation,
        detail=f"display_name={summary.get('display_name')}; backend={summary.get('backend')}",
        command=" ".join(args),
        duration_ms=duration_ms,
    )
    ctx.results.append(result)
    print(f"[PASS] {case_id} {protocol} {result.bytes_written} bytes {actual_sha}")
    return result


def record_case(ctx: Context, result: CaseResult) -> None:
    ctx.results.append(result)
    print(f"[{result.status.upper()}] {result.id} {result.protocol} {result.detail}")


def setup_basic_fixtures(ctx: Context) -> dict[str, Any]:
    http_port = free_port()
    https_port = free_port()
    ftp_port = free_port()
    ftps_port = free_port()

    cert_file, key_file = create_tls_files(ctx.work_dir)
    http_payload = b"fluxdown windows http sample\n"
    https_payload = b"fluxdown windows https sample\n"
    webdav_payload = b"fluxdown windows webdav sample\n"
    webdavs_payload = b"fluxdown windows webdavs sample\n"
    ipfs_payload = b"Hello IPFS"
    seg1 = b"windows hls segment one\n"
    seg2 = b"windows hls segment two\n"
    playlist = (
        b"#EXTM3U\n"
        b"#EXT-X-VERSION:3\n"
        b"#EXT-X-TARGETDURATION:1\n"
        b"#EXTINF:1.0,\n"
        b"seg1.ts\n"
        b"#EXTINF:1.0,\n"
        b"seg2.ts\n"
        b"#EXT-X-ENDLIST\n"
    )

    plain_routes = {
        "/http.txt": http_payload,
        "/webdav.txt": webdav_payload,
        f"/ipfs/{CID}/readme.txt": ipfs_payload,
        "/playlist.m3u8": playlist,
        "/seg1.ts": seg1,
        "/seg2.ts": seg2,
    }
    tls_routes = {
        "/https.txt": https_payload,
        "/webdavs.txt": webdavs_payload,
    }
    start_http_fixture(ctx, host="127.0.0.1", port=http_port, routes=plain_routes)
    start_http_fixture(
        ctx,
        host="127.0.0.1",
        port=https_port,
        routes=tls_routes,
        cert_file=cert_file,
        key_file=key_file,
    )

    ftp_payload = b"fluxdown windows ftp sample\n"
    ftps_payload = b"fluxdown windows ftps sample\n"
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.load_cert_chain(str(cert_file), str(key_file))
    ftp = FtpFixture(port=ftp_port, payload=ftp_payload)
    ftps = FtpFixture(port=ftps_port, payload=ftps_payload, tls_context=tls_context)
    ftp.start()
    ftps.start()
    ctx.ftp_fixtures.extend([ftp, ftps])

    return {
        "http_port": http_port,
        "https_port": https_port,
        "ftp_port": ftp_port,
        "ftps_port": ftps_port,
        "payloads": {
            "http": http_payload,
            "https": https_payload,
            "webdav": webdav_payload,
            "webdavs": webdavs_payload,
            "ipfs": ipfs_payload,
            "m3u8": seg1 + seg2,
            "ftp": ftp_payload,
            "ftps": ftps_payload,
        },
    }


def run_local_transport_cases(ctx: Context, fixtures: dict[str, Any]) -> None:
    payloads: dict[str, bytes] = fixtures["payloads"]
    http_port = fixtures["http_port"]
    https_port = fixtures["https_port"]
    ftp_port = fixtures["ftp_port"]
    ftps_port = fixtures["ftps_port"]

    cases = [
        (
            "win-http-local",
            "http",
            f"http://127.0.0.1:{http_port}/http.txt",
            "windows-http.txt",
            payloads["http"],
            "HTTP 本地文件真实落盘，校验 SHA-256",
        ),
        (
            "win-https-local-self-signed",
            "https",
            f"https://127.0.0.1:{https_port}/https.txt?allowBadCertificate=true",
            "windows-https.txt",
            payloads["https"],
            "HTTPS 自签证书显式 opt-in 后真实落盘",
        ),
        (
            "win-webdav-local-transport",
            "webdav",
            f"webdav://127.0.0.1:{http_port}/webdav.txt",
            "windows-webdav.txt",
            payloads["webdav"],
            "WebDAV transport 映射到 HTTP 后真实落盘",
        ),
        (
            "win-webdavs-local-transport",
            "webdavs",
            f"webdavs://127.0.0.1:{https_port}/webdavs.txt?allowBadCertificate=true",
            "windows-webdavs.txt",
            payloads["webdavs"],
            "WebDAVS transport 映射到 HTTPS 后真实落盘",
        ),
        (
            "win-ftp-local",
            "ftp",
            f"ftp://flux:fluxpass@127.0.0.1:{ftp_port}/ftp-sample.txt",
            "windows-ftp.txt",
            payloads["ftp"],
            "FTP EPSV/RETR 真实数据连接落盘",
        ),
        (
            "win-ftps-local-explicit",
            "ftps",
            f"ftps://flux:fluxpass@127.0.0.1:{ftps_port}/ftps-sample.txt?allowBadCertificate=true",
            "windows-ftps.txt",
            payloads["ftps"],
            "显式 FTPS 控制和数据连接 TLS 落盘",
        ),
        (
            "win-ipfs-local-gateway",
            "ipfs",
            f"ipfs://{CID}/readme.txt?gateway={urllib.parse.quote(f'http://127.0.0.1:{http_port}', safe='')}",
            "windows-ipfs.txt",
            payloads["ipfs"],
            "IPFS gateway= 本地兼容网关真实落盘",
        ),
    ]
    for case_id, protocol, source, name, payload, expectation in cases:
        fluxdown_download(
            ctx,
            case_id=case_id,
            protocol=protocol,
            source=source,
            output_dir=ctx.work_dir / "downloads" / case_id,
            name=name,
            expected_sha256=sha256_bytes(payload),
            expected_bytes=payload,
            expectation=expectation,
        )

    fluxdown_download(
        ctx,
        case_id="win-m3u8-local-vod",
        protocol="m3u8",
        source=f"http://127.0.0.1:{http_port}/playlist.m3u8",
        output_dir=ctx.work_dir / "downloads" / "win-m3u8-local-vod",
        name="windows-hls.ts",
        expected_sha256=sha256_bytes(payloads["m3u8"]),
        expected_bytes=payloads["m3u8"],
        expectation="VOD m3u8 两个分片按顺序合并落盘；本机无 ffmpeg 时按 core 设计回退 TS",
    )


def docker_available() -> bool:
    return shutil.which("docker") is not None and run_command(
        ["docker", "version", "--format", "{{.Server.Version}}"],
        timeout=20,
        check=False,
    ).returncode == 0


def docker(ctx: Context, args: list[str], *, timeout: int = 120, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run_command(["docker", *args], timeout=timeout, check=check)


def mount_arg(path: pathlib.Path, target: str, readonly: bool = False) -> str:
    suffix = ":ro" if readonly else ""
    return f"{path.resolve()}:{target}{suffix}"


def run_sftp_case(ctx: Context) -> None:
    if not docker_available():
        raise VerifyError("Docker is required for SFTP fixture")
    port = free_port()
    upload = ctx.work_dir / "sftp-upload"
    upload.mkdir(parents=True, exist_ok=True)
    payload = b"fluxdown windows sftp sample\n"
    sample_name = "windows-sftp-sample.txt"
    (upload / sample_name).write_bytes(payload)
    container = f"fluxdown-win-sftp-{os.getpid()}"
    ctx.containers.append(container)
    docker(
        ctx,
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
            mount_arg(upload, "/home/flux/upload", readonly=True),
            SFTP_IMAGE,
            "flux:fluxpass:::upload",
        ],
        timeout=180,
    )
    wait_for_sftp_banner("127.0.0.1", port, ctx, container)
    fluxdown_download(
        ctx,
        case_id="win-sftp-local-docker",
        protocol="sftp",
        source=f"sftp://flux:fluxpass@127.0.0.1:{port}/upload/{sample_name}",
        output_dir=ctx.work_dir / "downloads" / "win-sftp-local-docker",
        name="windows-sftp.txt",
        expected_sha256=sha256_bytes(payload),
        expected_bytes=payload,
        timeout=120,
        expectation="Docker SFTP 密码认证读取远端文件并落盘",
    )


def wait_for_sftp_banner(host: str, port: int, ctx: Context, container: str) -> None:
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=1) as sock:
                sock.settimeout(1)
                if sock.recv(256).startswith(b"SSH-"):
                    return
        except OSError:
            time.sleep(0.3)
    logs = docker(ctx, ["logs", container], check=False, timeout=20)
    raise VerifyError(f"timed out waiting for SFTP banner\n{logs.stdout}\n{logs.stderr}")


def run_smb_case(ctx: Context) -> None:
    if not docker_available():
        raise VerifyError("Docker is required for SMB fixture")
    port = free_port()
    share = ctx.work_dir / "smb-share"
    share.mkdir(parents=True, exist_ok=True)
    payload = b"fluxdown windows smb sample\n"
    sample_name = "windows-smb-sample.txt"
    (share / sample_name).write_bytes(payload)
    container = f"fluxdown-win-smb-{os.getpid()}"
    ctx.containers.append(container)
    docker(
        ctx,
        [
            "run",
            "-d",
            "--name",
            container,
            "-p",
            f"127.0.0.1:{port}:445",
            "-v",
            mount_arg(share, "/share", readonly=True),
            SMB_IMAGE,
            "-u",
            "flux;fluxpass",
            "-s",
            "flux;/share;yes;no;no;flux",
        ],
        timeout=180,
    )
    wait_for_tcp("127.0.0.1", port, timeout=45)
    source = f"smb://flux:fluxpass@127.0.0.1:{port}/flux/{sample_name}"
    deadline = time.monotonic() + 45
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            fluxdown_download(
                ctx,
                case_id="win-smb-local-docker",
                protocol="smb",
                source=source,
                output_dir=ctx.work_dir / "downloads" / "win-smb-local-docker",
                name="windows-smb.txt",
                expected_sha256=sha256_bytes(payload),
                expected_bytes=payload,
                timeout=120,
                expectation="Docker Samba SMB2/3 共享读取文件并落盘",
            )
            return
        except Exception as error:
            last_error = error
            time.sleep(1)
    logs = docker(ctx, ["logs", container], check=False, timeout=20)
    raise VerifyError(f"SMB fixture did not become ready: {last_error}\n{logs.stdout}\n{logs.stderr}")


def run_p2p_cases(ctx: Context) -> None:
    if not docker_available():
        raise VerifyError("Docker is required for torrent/magnet fixture")
    tracker_port = free_port()
    rpc_port = free_port()
    peer_port = free_port()
    start_tracker(ctx, tracker_port)

    seed = ctx.work_dir / "p2p" / "seed"
    seed.mkdir(parents=True, exist_ok=True)
    sample_name = "windows-p2p-sample.txt"
    payload = b"fluxdown windows torrent sample\n"
    (seed / sample_name).write_bytes(payload)
    torrent_file = ctx.work_dir / "p2p" / "windows-p2p-sample.torrent"
    tracker_url = f"http://host.docker.internal:{tracker_port}/announce"
    docker(
        ctx,
        [
            "run",
            "--rm",
            "-v",
            mount_arg(ctx.work_dir / "p2p", "/work"),
            "--entrypoint",
            "transmission-create",
            TRANSMISSION_IMAGE,
            "-o",
            "/work/windows-p2p-sample.torrent",
            "-t",
            tracker_url,
            f"/work/seed/{sample_name}",
        ],
        timeout=180,
    )
    show = docker(
        ctx,
        [
            "run",
            "--rm",
            "-v",
            mount_arg(ctx.work_dir / "p2p", "/work"),
            "--entrypoint",
            "transmission-show",
            TRANSMISSION_IMAGE,
            "/work/windows-p2p-sample.torrent",
        ],
        timeout=120,
    )
    info_hash = parse_transmission_hash(show.stdout)
    container = f"fluxdown-win-transmission-{os.getpid()}"
    ctx.containers.append(container)
    docker(
        ctx,
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
            mount_arg(ctx.work_dir / "p2p", "/work"),
            "--entrypoint",
            "transmission-daemon",
            TRANSMISSION_IMAGE,
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
    wait_for_transmission(ctx, container)
    docker(ctx, ["exec", container, "transmission-remote", "127.0.0.1:9091", "-a", "/work/windows-p2p-sample.torrent"], timeout=60)
    docker(ctx, ["exec", container, "transmission-remote", "127.0.0.1:9091", "-t", "all", "--reannounce"], timeout=60)
    wait_for_tcp("127.0.0.1", peer_port, timeout=30)
    wait_for_tracker_peer(ctx, container, info_hash, peer_port)

    expected_sha = sha256_bytes(payload)
    fluxdown_download(
        ctx,
        case_id="win-torrent-local-docker-seed",
        protocol="torrent",
        source=str(torrent_file),
        output_dir=ctx.work_dir / "downloads" / "win-torrent-local-docker-seed",
        name="windows-p2p-sample.torrent",
        expected_sha256=expected_sha,
        expected_bytes=payload,
        timeout=180,
        expectation="本地 .torrent + Docker Transmission 做种，metadata 后真实文件落盘",
    )

    magnet = (
        f"magnet:?xt=urn:btih:{info_hash}&dn={urllib.parse.quote(sample_name)}"
        f"&tr={urllib.parse.quote(tracker_url, safe='')}"
    )
    fluxdown_download(
        ctx,
        case_id="win-magnet-local-docker-seed",
        protocol="magnet",
        source=magnet,
        output_dir=ctx.work_dir / "downloads" / "win-magnet-local-docker-seed",
        name="windows-magnet",
        expected_sha256=expected_sha,
        expected_bytes=payload,
        timeout=180,
        expectation="同一 Docker seeder 通过 magnet 获取 metadata 后真实文件落盘",
    )


def parse_transmission_hash(output: str) -> str:
    for line in output.splitlines():
        if "Hash v1:" in line:
            return line.split("Hash v1:", 1)[1].strip()
    raise VerifyError(f"could not parse transmission hash:\n{output}")


def wait_for_transmission(ctx: Context, container: str) -> None:
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        result = docker(
            ctx,
            ["exec", container, "transmission-remote", "127.0.0.1:9091", "-l"],
            check=False,
            timeout=10,
        )
        if result.returncode == 0:
            return
        time.sleep(0.5)
    logs = docker(ctx, ["logs", container], check=False, timeout=20)
    raise VerifyError(f"timed out waiting for transmission RPC\n{logs.stdout}\n{logs.stderr}")


def wait_for_tracker_peer(ctx: Context, container: str, info_hash: str, peer_port: int) -> None:
    target = bytes.fromhex(info_hash)
    deadline = time.monotonic() + 45
    while time.monotonic() < deadline:
        with TrackerHandler.lock:
            peers = list(TrackerHandler.peers.get(target, {}).values())
        if any(port == peer_port for _, port, _ in peers):
            return
        docker(
            ctx,
            ["exec", container, "transmission-remote", "127.0.0.1:9091", "-t", "all", "--reannounce"],
            check=False,
            timeout=10,
        )
        time.sleep(1)
    listing = docker(
        ctx,
        ["exec", container, "transmission-remote", "127.0.0.1:9091", "-l"],
        check=False,
        timeout=20,
    )
    logs = docker(ctx, ["logs", container], check=False, timeout=20)
    raise VerifyError(
        "tracker did not receive the Transmission seeder announce\n"
        f"transmission:\n{listing.stdout}\n{listing.stderr}\n"
        f"logs:\n{logs.stdout}\n{logs.stderr}"
    )


def run_ed2k_case(ctx: Context) -> None:
    source = "ed2k://|file|windows-ed2k-sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/"
    output_dir = ctx.work_dir / "downloads" / "win-ed2k-handoff"
    output_dir.mkdir(parents=True, exist_ok=True)
    args = [str(ctx.fluxdown), "download", source, "--output", str(output_dir)]
    started = time.monotonic()
    completed = run_command(args, timeout=30, check=False)
    duration_ms = int((time.monotonic() - started) * 1000)
    if completed.returncode == 0:
        summary = json.loads(completed.stdout)
        result = CaseResult(
            id="win-ed2k-system-handoff",
            protocol="ed2k",
            source=source,
            status="passed",
            output_path=summary.get("output_path"),
            bytes_written=int(summary.get("bytes_written", 0)),
            expectation="ed2k 当前为系统/aMule 移交，FluxDown 只验证移交动作",
            detail=f"handoff backend={summary.get('backend')}",
            command=" ".join(args),
            duration_ms=duration_ms,
        )
        record_case(ctx, result)
        return

    error_text = f"{completed.stdout}\n{completed.stderr}".strip()
    accepted = [
        "system handoff failed",
        "No application",
        "not found",
        "cannot find",
        "The system cannot find",
        "optional ed2k CLI handoff",
    ]
    if any(token.lower() in error_text.lower() for token in accepted):
        result = CaseResult(
            id="win-ed2k-system-handoff",
            protocol="ed2k",
            source=source,
            status="passed",
            expectation="未安装 ed2k handler 时应返回清晰移交失败，不冒充下载完成",
            detail=error_text,
            command=" ".join(args),
            duration_ms=duration_ms,
        )
        record_case(ctx, result)
        return
    raise VerifyError(f"unexpected ed2k result:\n{error_text}")


def write_results(ctx: Context, output_json: pathlib.Path) -> None:
    output_json.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "platform": sys.platform,
        "fluxdown": str(ctx.fluxdown),
        "work_dir": str(ctx.work_dir),
        "results": [asdict(result) for result in ctx.results],
    }
    output_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def cleanup(ctx: Context) -> None:
    for container in reversed(ctx.containers):
        with contextlib.suppress(Exception):
            run_command(["docker", "rm", "-f", container], check=False, timeout=30)
    for fixture in ctx.ftp_fixtures:
        fixture.stop()
    for server in ctx.http_servers:
        with contextlib.suppress(Exception):
            server.shutdown()
            server.server_close()
    for process in ctx.processes:
        with contextlib.suppress(Exception):
            process.terminate()
    if not ctx.keep_work_dir:
        shutil.rmtree(ctx.work_dir, ignore_errors=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify FluxDown Windows CLI protocol downloads.")
    parser.add_argument("--fluxdown", type=pathlib.Path, default=DEFAULT_FLUXDOWN)
    parser.add_argument(
        "--output-json",
        type=pathlib.Path,
        default=ROOT_DIR / "docs" / "artifacts" / "windows-cli-protocol-e2e-20260630.json",
    )
    parser.add_argument("--work-dir", type=pathlib.Path)
    parser.add_argument("--keep-work-dir", action="store_true")
    parser.add_argument("--skip-docker", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    fluxdown = args.fluxdown.resolve()
    if not fluxdown.exists():
        raise VerifyError(f"fluxdown binary does not exist: {fluxdown}")
    work_dir = args.work_dir or pathlib.Path(tempfile.mkdtemp(prefix="fluxdown-win-protocols-"))
    work_dir.mkdir(parents=True, exist_ok=True)
    ctx = Context(fluxdown=fluxdown, work_dir=work_dir.resolve(), keep_work_dir=args.keep_work_dir)
    print(f"FluxDown binary: {ctx.fluxdown}")
    print(f"Work dir: {ctx.work_dir}")
    try:
        fixtures = setup_basic_fixtures(ctx)
        run_local_transport_cases(ctx, fixtures)
        if not args.skip_docker:
            run_sftp_case(ctx)
            run_smb_case(ctx)
            run_p2p_cases(ctx)
        else:
            print("[SKIP] Docker-backed SFTP/SMB/Torrent/Magnet cases")
        run_ed2k_case(ctx)
        protocols = {result.protocol for result in ctx.results if result.status == "passed"}
        expected = {
            "http",
            "https",
            "webdav",
            "webdavs",
            "ftp",
            "ftps",
            "torrent",
            "magnet",
            "ed2k",
            "m3u8",
            "sftp",
            "smb",
            "ipfs",
        }
        missing = sorted(expected - protocols)
        if missing:
            raise VerifyError(f"missing protocol results: {', '.join(missing)}")
        write_results(ctx, args.output_json.resolve())
        print(f"Result JSON: {args.output_json.resolve()}")
        return 0
    finally:
        cleanup(ctx)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        raise SystemExit(1)
