#!/usr/bin/env python3
"""FluxDown 协议夹具：FTP / FTPS 服务。

作者: long
Android 真机协议矩阵需要真实 FTP 服务端，桌面验证脚本历史上依赖 Docker，
但本机 Docker daemon 不可用时无法启动。这里用 pyftpdlib 起一个最小服务端，
被动端口固定成小范围，方便 `adb reverse` 逐条映射（设备侧只能拿到固定端口）。
"""
from __future__ import annotations

import argparse

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer


def main() -> None:
    parser = argparse.ArgumentParser(description="FTP/FTPS fixture server for FluxDown protocol matrix.")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2121)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--user", default="fluxdown")
    parser.add_argument("--password", default="fluxdown")
    parser.add_argument("--tls-cert", default="")
    parser.add_argument("--tls-key", default="")
    parser.add_argument("--passive-from", type=int, default=31000)
    parser.add_argument("--passive-to", type=int, default=31009)
    args = parser.parse_args()

    authorizer = DummyAuthorizer()
    authorizer.add_user(args.user, args.password, args.directory, perm="elradfmwMT")

    if args.tls_cert and args.tls_key:
        handler_class = TLS_FTPHandler
        handler_class.certfile = args.tls_cert
        handler_class.keyfile = args.tls_key
        handler_class.tls_control_required = False
        handler_class.tls_data_required = False
        scheme = "ftps"
    else:
        handler_class = FTPHandler
        scheme = "ftp"

    handler_class.authorizer = authorizer
    handler_class.passive_ports = range(args.passive_from, args.passive_to + 1)
    handler_class.banner = "FluxDown fixture FTP ready"

    server = FTPServer((args.bind, args.port), handler_class)
    print(
        f"{scheme}://{args.user}:{args.password}@{args.bind}:{args.port}/ ready "
        f"(passive {args.passive_from}-{args.passive_to})",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
