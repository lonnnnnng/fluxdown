#!/usr/bin/env python3
"""FluxDown 协议夹具：最小 BitTorrent HTTP tracker。

作者: long
Torrent/Magnet 真机验证需要一个可 announce 的 tracker。公网 tracker 不稳定，
本机 Docker 也不可用，所以这里实现一个只做内存 peer 交换的最小 tracker：
announce 返回 compact peer 列表，供 librqbit 与本地 seeder 建连。

配合 `adb reverse tcp:<peer-port> tcp:<peer-port>` 使用：seeder 通过回环注册，
设备侧拿到的 peer 地址同样是 127.0.0.1，正好落到 adb 反向映射上。
"""
from __future__ import annotations

import argparse
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote_to_bytes

PEERS: dict[bytes, dict[bytes, tuple[str, int]]] = {}
LOCK = threading.Lock()


def bencode(value) -> bytes:
    if isinstance(value, int):
        return b"i%de" % value
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, str):
        return bencode(value.encode())
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        out = b"d"
        for key in sorted(value.keys()):
            out += bencode(key) + bencode(value[key])
        return out + b"e"
    raise TypeError(f"cannot bencode {type(value)!r}")


def parse_query(raw: str) -> dict[str, bytes]:
    params: dict[str, bytes] = {}
    for chunk in raw.split("&"):
        if not chunk:
            continue
        name, _, value = chunk.partition("=")
        params[unquote_to_bytes(name).decode("latin-1")] = unquote_to_bytes(value)
    return params


class TrackerHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, fmt: str, *args) -> None:  # noqa: A003 - 静默日志，避免污染脚本输出
        return

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler 约定
        path, _, raw_query = self.path.partition("?")
        if path != "/announce":
            self.send_error(404, "not a tracker announce endpoint")
            return
        params = parse_query(raw_query)
        info_hash = params.get("info_hash", b"")
        peer_id = params.get("peer_id", b"")
        if not info_hash or not peer_id:
            self.send_error(400, "missing info_hash or peer_id")
            return
        try:
            port = int(params.get("port", b"0"))
        except ValueError:
            port = 0
        try:
            left = int(params.get("left", b"0"))
        except ValueError:
            left = 0
        event = params.get("event", b"").decode("latin-1")

        with LOCK:
            bucket = PEERS.setdefault(info_hash, {})
            if event == "stopped":
                bucket.pop(peer_id, None)
            elif port > 0:
                bucket[peer_id] = (self.client_address[0], port, left)
            compact = b"".join(
                b"".join(int(part).to_bytes(1, "big") for part in peer[0].split("."))
                + peer[1].to_bytes(2, "big")
                for known_id, peer in bucket.items()
                # 只向下载方推荐真正的做种者：
                # 夹具环境里所有 peer 的回环地址都是 127.0.0.1，若把其他下载端（包括本机上一轮的旧 peer_id）
                # 也推给 librqbit，它会把 127.0.0.1:<自己的监听端口> 当成 peer 去连自己，
                # 白白占掉连接槽位，导致真正能提供数据的 seeder 长时间不被连上。
                if known_id != peer_id and peer[2] == 0
            )
            peer_count = len(bucket)
            complete = sum(1 for peer in bucket.values() if peer[2] == 0)
            incomplete = peer_count - complete

        # librqbit 的 TrackerResponse 把 complete/incomplete 当必填字段：缺了就直接反序列化失败，
        # announce 被当成错误处理、Peer 列表被丢掉（表现为“无可用 Peer”），所以这里必须给全。
        payload = bencode(
            {
                "interval": 15,
                "min interval": 5,
                "complete": complete,
                "incomplete": incomplete,
                "peers": compact,
            }
        )
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        print(
            f"announce {info_hash.hex()[:12]} event={event or 'none'} peers={peer_count}"
            f" from={self.client_address[0]}:{self.client_address[1]}"
            f" peer_id={peer_id!r} port={port} raw={raw_query[:120]!r}",
            flush=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Minimal HTTP BitTorrent tracker for FluxDown fixtures.")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6969)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.bind, args.port), TrackerHandler)
    print(f"tracker http://{args.bind}:{args.port}/announce ready", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
