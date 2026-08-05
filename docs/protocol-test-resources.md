# 跨平台协议测试资源清单

本清单供 Android、iOS、macOS、Windows、Linux 和 CLI 复用。资源分为“公网可直接访问”和“需要重启本地实验室”两类。通过标准仍以真实落盘及大小或 SHA-256 校验为准，协议识别、任务创建或系统移交不能替代下载完成。

## 公网小体积资源

下列地址已在 2026-08-05 从当前 macOS 环境完成连通性或内容验证。公网服务可能变化，跨平台正式回归前应先重新探测状态。

| 协议 | 地址 | 体积 | 当前状态 | 用途与限制 |
| --- | --- | ---: | --- | --- |
| HTTP | `http://speedtest.tele2.net/1MB.zip` | 1 MiB | 已验证 HTTP 200 和 `Content-Length: 1048576` | 静态小文件，优先作为公网 HTTP 回归资源 |
| HTTPS | `https://proof.ovh.net/files/1Mb.dat` | 1 MiB | 已验证 HTTP 200 和 `Content-Length: 1048576` | OVH 测速资源，优先作为公网 HTTPS 回归资源 |
| HTTPS 备选 | `https://speed.cloudflare.com/__down?bytes=1048576` | 1 MiB | 已验证 HTTP 200 | 动态内容，适合连通性和大小校验，不适合作固定 hash |
| FTP | `ftp://demo:password@test.rebex.net/readme.txt` | 379 B | 已真实读取 | Rebex 官方只读测试账号 `demo/password` |
| SFTP | `sftp://demo:password@test.rebex.net/readme.txt` | 379 B | 已通过系统 SFTP 客户端真实读取 | 与 FTP 同一份 readme，可比对内容或 SHA-256 |
| HLS | `https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8` | 完整流未限定 | 已确认返回有效多码率 `#EXTM3U` | 适合解析/兼容性测试，不满足稳定小于 10 MB 的回归约束 |
| WebDAV transport | `webdav://speedtest.tele2.net/1MB.zip` | 1 MiB | 候选 | FluxDown 当前将其映射为 HTTP transport，不代表完整 WebDAV 方法验证 |
| WebDAVS transport | `webdavs://proof.ovh.net/files/1Mb.dat` | 1 MiB | 候选 | FluxDown 当前将其映射为 HTTPS transport，不代表完整 WebDAV 方法验证 |

当前没有确认稳定、无需注册且适合自动回归的公网 FTPS、完整 WebDAV、SMB、Torrent 和 Magnet 小资源。FTPS Rebex 兼容性用例在现有实现下仍会出现 TLS data connection 兼容问题，不应作为通过基线；SMB 不应暴露到公网。

## 2026-08-05 macOS GUI 证据地址

以下地址是本轮真实验证时使用的完整地址。动态服务已在测试结束后清理，所以它们用于留存证据，不能假定当前仍在监听。

```text
HTTP     http://192.168.1.8:62160/http.txt
HTTPS    https://192.168.1.8:62161/https.txt?allowBadCertificate=true
WebDAV   webdav://192.168.1.8:62160/webdav.txt
WebDAVS  webdavs://192.168.1.8:62161/webdavs.txt?allowBadCertificate=true
FTP      ftp://flux:fluxpass@192.168.1.8:62162/ftp-sample.txt
FTPS     ftps://flux:fluxpass@192.168.1.8:62163/ftps-sample.txt?allowBadCertificate=true
HLS      http://192.168.1.8:62160/playlist.m3u8
SFTP     sftp://flux:fluxpass@192.168.1.8:62183/upload/macos-gui-sftp-sample.txt
SMB      smb://flux:fluxpass@192.168.1.8:49257/flux/macos-gui-smb-sample.txt
Magnet   magnet:?xt=urn:btih:b33adcecf0f541d848fcf88697aaf16643c4e730&dn=macos-gui-p2p-sample.txt&tr=http%3A%2F%2F192.168.1.8%3A49261%2Fannounce
ed2k     ed2k://|file|macos-gui-ed2k-sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/
```

本轮 torrent 文件仍保留在：

```text
/private/var/folders/8b/_k4z7q5n4kg7sq5g800_mcs00000gn/T/fluxdown-macos-gui-protocols-6elzrd_4/p2p/macos-gui-p2p-sample.torrent
```

ed2k 地址使用占位 hash，只适合验证系统 URL handler 移交。它不是有效下载资源，后续其他端验证时必须继续标记为“移交通路”，不能标记为“真实下载完成”。

## 需要重启实验室的协议

| 协议 | 原因 | 推荐方式 |
| --- | --- | --- |
| HTTPS / WebDAVS | 需要可控自签证书和固定内容 hash | 由 macOS GUI 验证脚本动态启动 TLS fixture |
| FTPS | 公网服务端 TLS 模式差异大 | 使用脚本内显式 FTPS fixture，并带 `allowBadCertificate=true` |
| SFTP | 公网账号可能限流或变更 | 使用 Docker `atmoz/sftp` 只读 fixture |
| SMB | 不适合公网暴露 | 使用 Docker Samba 局域网共享 |
| Torrent / Magnet | 必须存在可控 tracker 和活跃 seeder | 使用同一小 payload 动态生成 torrent 和 magnet |
| 完整 WebDAV | 当前只覆盖 transport 映射 | 后续增加支持 `PROPFIND` 的本地 WebDAV 服务和目录用例 |

## 复用方式

macOS 原生桌面端可执行：

```sh
npm run verify:macos-desktop-gui-protocols
```

脚本会重新生成可从同一局域网访问的动态地址，并把本次完整地址、落盘路径、大小和 SHA-256 写入：

```text
docs/artifacts/macos-desktop-gui-protocol-e2e-20260805.json
```

后续移动端或其他电脑验证时，不应直接复用旧随机端口。应先启动实验室，再把新 JSON 中的 `source` 地址转换为目标设备可访问的 Mac 局域网地址。Android 使用 USB 时可对 HTTP(S) 端口使用 `adb reverse`；SFTP、SMB、FTP(S) 和 P2P 仍应使用真实局域网地址。
