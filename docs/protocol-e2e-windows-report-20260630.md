# Windows CLI 13 协议真实下载验证报告

验证时间：2026-06-30 01:49 CST
验证环境：Windows 开发机，`target/debug/fluxdown.exe`，FluxDown `1.0.4`
验证命令：`python scripts/verify-windows-cli-protocols.py --keep-work-dir`
原始证据：`docs/artifacts/windows-cli-protocol-e2e-20260630.json`

## 结论

本轮 Windows CLI 对当前支持的 13 种协议逐一执行了真实用例验证。HTTP、HTTPS、WebDAV、WebDAVS、FTP、FTPS、m3u8/HLS、SFTP、SMB、Torrent、Magnet、IPFS 均完成真实下载落盘，并校验输出文件 SHA-256。ed2k 当前产品定义为系统/aMule 移交协议，本轮验证了 CLI 能完成系统移交通路；FluxDown 不声明外部 ed2k 客户端的最终下载完成状态。

本轮未发现 FluxDown core/CLI 下载实现需要修改的问题。过程中修复了新增 Windows 验证脚本的两个 fixture 问题：FTPS fixture 补齐 TLS `close_notify` 收尾，P2P tracker 补齐 `complete`/`incomplete` 字段以匹配 `librqbit` HTTP tracker 响应结构。

## 验证矩阵

| 协议 | 用例 | 真实资源/服务 | 结果 | 字节数 | SHA-256 |
| --- | --- | --- | --- | ---: | --- |
| HTTP | `win-http-local` | 本地 HTTP 文件服务 | 通过 | 29 | `4b21578d7e688e10e3022a5d0cb630e8e69c0aaabded4b85193f124dc3332367` |
| HTTPS | `win-https-local-self-signed` | 本地 HTTPS 自签证书，显式 `allowBadCertificate=true` | 通过 | 30 | `cc3ebe482bc02e3a2a620cecf7af4494127a601d97c1118022b9240a8bdbd348` |
| WebDAV | `win-webdav-local-transport` | `webdav://` 映射到本地 HTTP transport | 通过 | 31 | `a10150697e18cfa7514b650d6c0a177f8e843df0cda2a7b24d2f4023b851db97` |
| WebDAVS | `win-webdavs-local-transport` | `webdavs://` 映射到本地 HTTPS transport | 通过 | 32 | `554627841a921f67b3b1f22cab53d908f78f25cc2b74591f21da8f082d8ea1c1` |
| FTP | `win-ftp-local` | 本地 FTP fixture，EPSV/RETR 数据连接 | 通过 | 28 | `51e3ec3c46ae4903d6acc26ceff6d42ce29402966850f0fdf76d54c03ae7f19f` |
| FTPS | `win-ftps-local-explicit` | 本地显式 FTPS fixture，控制/数据连接 TLS | 通过 | 29 | `a449606cbe0666e54c511bdaae62ef4ba22bf8793d0ab203803abf54099090d2` |
| m3u8/HLS | `win-m3u8-local-vod` | 本地 VOD playlist，两段 TS 分片 | 通过 | 48 | `7ecf9fe1bba3dd832ea1a76fdf837034bb91028068a3e6d954f37a58d49d46f1` |
| SFTP | `win-sftp-local-docker` | Docker `atmoz/sftp` 密码认证文件服务 | 通过 | 29 | `906a6c969496df690b9a1abae5c5fecb23024c3b3874b94026f72fa287b2574c` |
| SMB | `win-smb-local-docker` | Docker `dperson/samba` SMB2/3 共享 | 通过 | 28 | `9233ff29c61650d79a29d411b72991ab7efc106bf9844a2606b815f674afdac4` |
| Torrent | `win-torrent-local-docker-seed` | 本地 `.torrent` + Docker Transmission 做种 + 本地 tracker | 通过 | 32 | `408d5a0c192e7ec194079f486c29e1dfb9a82cb0817b7763aa37c652de702702` |
| Magnet | `win-magnet-local-docker-seed` | 同一 Transmission seeder，通过 magnet 获取 metadata | 通过 | 32 | `408d5a0c192e7ec194079f486c29e1dfb9a82cb0817b7763aa37c652de702702` |
| IPFS | `win-ipfs-local-gateway` | `ipfs://` + 本地兼容 HTTP gateway | 通过 | 10 | `206f158bef5fbaeddee314d74b90d9259c5e2abee372bbac8f3c6e65fbb0d87b` |
| ed2k | `win-ed2k-system-handoff` | `ed2k://` 系统 URL handler 移交 | 通过 | 0 | 不适用 |

## 说明

- 所有内建下载协议均不是只做识别测试，而是执行 CLI `download`，确认输出文件存在、字节数匹配，并校验 SHA-256。
- m3u8/HLS 在当前 Windows 机器没有 `ffmpeg` 的情况下按 core 设计回退输出 `.ts`，验证内容为两个分片按播放列表顺序合并后的文件。
- Torrent/Magnet 使用合法小体积本地 payload，Transmission 在 Docker 中做种；本地 tracker 会等到 seeder announce 后再启动 FluxDown，避免把 peer 未就绪误判为产品失败。
- ed2k 当前不是内建下载协议栈，验证标准是能移交给 aMule CLI 或系统 URL handler；本轮 Windows 环境返回 `system-handoff` 成功。
