#!/usr/bin/env python3
"""FluxDown 协议夹具：SFTP 服务。

作者: long
用 paramiko 起一个只读 SFTP 服务端，覆盖 Android 真机矩阵里的 SFTP 下载路径。
只支持密码认证，主机密钥在启动时生成并打印指纹，便于验证 known_hosts 导入边界。
"""
from __future__ import annotations

import argparse
import logging
import os
import socket
import threading

import paramiko


class FixtureServer(paramiko.ServerInterface):
    def __init__(self, user: str, password: str) -> None:
        self.user = user
        self.password = password
        self.event = threading.Event()

    def check_auth_password(self, username: str, password: str) -> int:
        if username == self.user and password == self.password:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username: str) -> str:
        return "password"

    def check_channel_request(self, kind: str, chanid: int) -> int:
        if kind == "session":
            return paramiko.OPEN_SUCCEEDED
        return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED


def handle(client: socket.socket, host_key: paramiko.PKey, root: str, user: str, password: str) -> None:
    transport = paramiko.Transport(client)
    transport.add_server_key(host_key)
    # 作者: long
    # 子系统处理器拿到的是 Transport 而不是 ServerInterface，root 必须显式传进去；
    # 否则 getattr(server, "root") 会回落成进程工作目录，客户端 stat 远程文件必然失败。
    RootedSFTPServer.root = os.path.abspath(root)
    transport.set_subsystem_handler("sftp", paramiko.SFTPServer, RootedSFTPServer)
    server = FixtureServer(user, password)
    server.root = root
    try:
        transport.start_server(server=server)
        channel = transport.accept(20)
        if channel is None:
            transport.close()
            return
        while transport.is_active():
            threading.Event().wait(0.5)
    except Exception:
        # 作者: long
        # 不能静默吞异常：SFTP 失败时真机只看到"下载失败"，服务端必须留下握手/KEX 细节。
        logging.exception("sftp fixture session failed")
    finally:
        transport.close()


class RootedSFTPServer(paramiko.SFTPServerInterface):
    """把 SFTP 路径限制在夹具目录内。"""

    root: str = ""

    def __init__(self, server, *args, **kwargs) -> None:
        super().__init__(server, *args, **kwargs)
        self.root = RootedSFTPServer.root or os.path.abspath(os.getcwd())

    def _realpath(self, path: str) -> str:
        joined = os.path.abspath(os.path.join(self.root, path.lstrip("/")))
        if not joined.startswith(self.root):
            return self.root
        return joined

    # 作者: long
    # paramiko 的 SFTPServerInterface 默认实现全部返回 SFTP_OP_UNSUPPORTED，
    # 所以这里不能 super().stat(...) 转发，必须用 os 真实现；否则客户端 stat 直接失败。
    def list_folder(self, path: str):
        target = self._realpath(path)
        try:
            entries = []
            for name in sorted(os.listdir(target)):
                attr = paramiko.SFTPAttributes.from_stat(os.stat(os.path.join(target, name)))
                attr.filename = name
                entries.append(attr)
            return entries
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def stat(self, path: str):
        try:
            return paramiko.SFTPAttributes.from_stat(os.stat(self._realpath(path)))
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def lstat(self, path: str):
        try:
            return paramiko.SFTPAttributes.from_stat(os.lstat(self._realpath(path)))
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def open(self, path: str, flags, attr):
        target = self._realpath(path)
        try:
            descriptor = os.open(target, flags)
            handle = paramiko.SFTPHandle(flags)
            handle.filename = target
            handle.readfile = os.fdopen(descriptor, "rb")
            return handle
        except OSError as error:
            return paramiko.SFTPServer.convert_errno(error.errno)

    def remove(self, path: str):
        return paramiko.SFTP_PERMISSION_DENIED

    def mkdir(self, path: str, attr):
        return paramiko.SFTP_PERMISSION_DENIED

    def rmdir(self, path: str):
        return paramiko.SFTP_PERMISSION_DENIED

    def rename(self, oldpath: str, newpath: str):
        return paramiko.SFTP_PERMISSION_DENIED


def main() -> None:
    parser = argparse.ArgumentParser(description="SFTP fixture server for FluxDown protocol matrix.")
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=2222)
    parser.add_argument("--directory", required=True)
    parser.add_argument("--user", default="fluxdown")
    parser.add_argument("--password", default="fluxdown")
    parser.add_argument("--host-key", default="")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    if args.host_key and os.path.exists(args.host_key):
        host_key = paramiko.RSAKey(filename=args.host_key)
    else:
        host_key = paramiko.RSAKey.generate(2048)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.bind, args.port))
    listener.listen(16)
    fingerprint = host_key.get_fingerprint().hex()
    print(
        f"sftp://{args.user}:{args.password}@{args.bind}:{args.port}/ ready "
        f"(root {args.directory}, rsa fingerprint {fingerprint})",
        flush=True,
    )
    while True:
        client, _ = listener.accept()
        threading.Thread(
            target=handle, args=(client, host_key, args.directory, args.user, args.password), daemon=True
        ).start()


if __name__ == "__main__":
    main()
