#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import re
import sys
import threading
import time
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class GlobalRateLimiter:
    """服务级令牌桶：多连接下载时也按总带宽限速，而不是每条连接各算一份。"""

    def __init__(self, rate: int) -> None:
        self.rate = rate
        self._lock = threading.Lock()
        self._next_free = time.monotonic()

    def consume(self, amount: int) -> None:
        if self.rate <= 0 or amount <= 0:
            return
        with self._lock:
            now = time.monotonic()
            start = max(now, self._next_free)
            self._next_free = start + amount / self.rate
            delay = self._next_free - now
        if delay > 0:
            time.sleep(delay)


class RangeRequestHandler(SimpleHTTPRequestHandler):
    range_start: int | None = None
    range_end: int | None = None
    # 作者: long
    # 长时下载验证需要可控的吞吐量：按字节预算限速，同时把 Range 请求头写进日志，
    # 这样“断点续传”是被服务端日志证明的，而不是靠客户端自称。
    bytes_per_second: int = 0
    chunk_bytes: int = 64 * 1024
    limiter: "GlobalRateLimiter" = GlobalRateLimiter(0)

    def end_headers(self) -> None:
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        if not os.path.exists(path):
            self.send_error(404, "File not found")
            return None

        file_handle = open(path, "rb")
        file_size = os.fstat(file_handle.fileno()).st_size
        start, end = self._parse_range(file_size)
        if start is None or end is None:
            self.send_response(200)
            self.send_header("Content-type", self.guess_type(path))
            self.send_header("Content-Length", str(file_size))
            self.send_header("Last-Modified", self.date_time_string(os.path.getmtime(path)))
            self.end_headers()
            self.range_start = None
            self.range_end = None
            return file_handle

        if start >= file_size or end < start:
            file_handle.close()
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.end_headers()
            return None

        end = min(end, file_size - 1)
        file_handle.seek(start)
        self.range_start = start
        self.range_end = end
        self.send_response(206)
        self.send_header("Content-type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Last-Modified", self.date_time_string(os.path.getmtime(path)))
        self.end_headers()
        return file_handle

    def copyfile(self, source, outputfile) -> None:
        if self.range_start is None or self.range_end is None:
            file_size = os.fstat(source.fileno()).st_size
            self._stream(source, file_size, outputfile)
            return

        remaining = self.range_end - self.range_start + 1
        self._stream(source, remaining, outputfile)

    def _stream(self, source, remaining: int, outputfile) -> None:
        chunk_bytes = self.chunk_bytes if self.bytes_per_second > 0 else 1024 * 1024
        while remaining > 0:
            chunk = source.read(min(chunk_bytes, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)
            self.limiter.consume(len(chunk))

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write(
            "%s - %s [range=%s]\n" % (self.address_string(), fmt % args, self.headers.get("Range") or "-")
        )
        sys.stderr.flush()

    def _parse_range(self, file_size: int) -> tuple[int | None, int | None]:
        header = self.headers.get("Range")
        if not header:
            return None, None

        match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
        if not match:
            return None, None

        start_text, end_text = match.groups()
        if not start_text and not end_text:
            return None, None
        if not start_text:
            suffix_length = int(end_text)
            return max(0, file_size - suffix_length), file_size - 1

        start = int(start_text)
        end = int(end_text) if end_text else file_size - 1
        return start, end


def main() -> None:
    parser = argparse.ArgumentParser(description="Serve files with HTTP Range support.")
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--directory", default=os.getcwd())
    parser.add_argument("--tls-cert", default="")
    parser.add_argument("--tls-key", default="")
    parser.add_argument("--bytes-per-second", type=int, default=0, help="限速：0 表示不限速")
    parser.add_argument("--chunk-bytes", type=int, default=64 * 1024)
    args = parser.parse_args()

    RangeRequestHandler.bytes_per_second = max(args.bytes_per_second, 0)
    RangeRequestHandler.chunk_bytes = max(args.chunk_bytes, 1024)
    RangeRequestHandler.limiter = GlobalRateLimiter(RangeRequestHandler.bytes_per_second)
    handler = partial(RangeRequestHandler, directory=args.directory)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    scheme = "http"
    if args.tls_cert and args.tls_key:
        import ssl

        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    # 作者: long
    # 端口传 0 时系统会分配可用端口，日志必须输出真实端口，方便本地验证脚本直接读取服务地址。
    host, port = server.server_address[:2]
    print(f"Serving {args.directory} on {scheme}://{host}:{port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
