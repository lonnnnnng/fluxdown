# macOS 原生桌面端 12 协议验证报告

## 结论

2026-08-05 在 macOS 14.7.4 上启动当前源码构建的 `FluxDown.app`，通过原生 Tauri 窗口逐项新建并启动 12 类协议任务。结果如下：

- HTTP、HTTPS、WebDAV transport、WebDAVS transport、FTP、FTPS、SFTP、SMB、m3u8/HLS、Torrent、Magnet 共 11 类完成真实下载、文件落盘、大小和 SHA-256 校验。
- ed2k 成功唤起迅雷并把链接移交给外部客户端。测试链接使用占位 hash，迅雷明确显示“链接失效”，因此本项只证明系统移交通路正常，不代表 ed2k 资源下载完成。
- WebDAV/WebDAVS 当前只验证协议 URL 到 HTTP/HTTPS transport 的映射和文件下载，不代表 `PROPFIND`、目录遍历等完整 WebDAV 能力已经通过。

## 验证环境

| 项目 | 内容 |
| --- | --- |
| 操作系统 | macOS 14.7.4 |
| 应用 | `target/release/bundle/macos/FluxDown.app` |
| 原生可执行文件 | `target/release/bundle/macos/FluxDown.app/Contents/MacOS/fluxdown-desktop` |
| 验证入口 | `npm run verify:macos-desktop-gui-protocols` |
| 队列隔离 | 使用临时 `XDG_DATA_HOME`，不读写用户正式队列 |
| 本轮局域网地址 | `192.168.1.8` |
| 保留工作目录 | `/private/var/folders/8b/_k4z7q5n4kg7sq5g800_mcs00000gn/T/fluxdown-macos-gui-protocols-6elzrd_4` |

## 结果明细

任务时间来自队列记录；“验证耗时”包含 GUI 输入、异步识别、状态轮询和文件校验，因此不能用于评估小文件的网络吞吐。

| 协议 | 测试地址/资源 | 落盘大小 | SHA-256 | 任务开始/结束（北京时间） | 验证耗时 | 结论 |
| --- | --- | ---: | --- | --- | ---: | --- |
| HTTP | `http://192.168.1.8:62160/http.txt` | 31 B | `d4d10c779f3e248d37248e2cf3afc7a25dd30f80d70b2746349597f17b233d83` | 23:14:34 / 23:14:34 | 6.109 s | 真实落盘通过 |
| HTTPS | `https://192.168.1.8:62161/https.txt?allowBadCertificate=true` | 32 B | `0bd544d4e93b2f21d130243a7f5f439d19f4dcb71e1e1774a86e52fedffa83b7` | 23:14:40 / 23:14:40 | 5.929 s | 自签证书显式 opt-in 后真实落盘通过 |
| WebDAV | `webdav://192.168.1.8:62160/webdav.txt` | 33 B | `14dac87b3de95b2ef9d524a9057519e82b1086e028d36ee1bd2327ac7f48a310` | 23:14:46 / 23:14:46 | 6.013 s | HTTP transport 映射真实落盘通过 |
| WebDAVS | `webdavs://192.168.1.8:62161/webdavs.txt?allowBadCertificate=true` | 34 B | `220dd5a8622012738a8aed0b137b9ff5b351c0c10e8b620b19467086196e632a` | 23:14:52 / 23:14:52 | 5.962 s | HTTPS transport 映射真实落盘通过 |
| FTP | `ftp://flux:fluxpass@192.168.1.8:62162/ftp-sample.txt` | 30 B | `876160b890e6d90906ddb47247b236c2cb4a868b0b4c34d67d4096329f1c741f` | 23:14:58 / 23:14:58 | 5.893 s | EPSV/RETR 真实落盘通过 |
| FTPS | `ftps://flux:fluxpass@192.168.1.8:62163/ftps-sample.txt?allowBadCertificate=true` | 31 B | `c2700b8abc8269413132a6f319653a1b3395ac506f6c859ce0f0da621a6689b9` | 23:15:04 / 23:15:04 | 5.965 s | 显式 FTPS 控制和数据连接真实落盘通过 |
| m3u8/HLS | `http://192.168.1.8:62160/playlist.m3u8` | 26,462 B | `78d122965d9c93f30094af8190ea403e4a2e4409e2a125c65bcbb2c2177a2436` | 23:15:09 / 23:15:09 | 5.221 s | 输出 `.mp4`；H.264/AAC，时长 2.043 秒，`ffprobe` 通过 |
| SFTP | `sftp://flux:fluxpass@192.168.1.8:62183/upload/macos-gui-sftp-sample.txt` | 31 B | `2dc777f7c4506497c25075725e249a8fed1ba069d743bf0dc0ed2421873e09d3` | 23:15:15 / 23:15:16 | 5.979 s | 密码认证和真实落盘通过 |
| SMB | `smb://flux:fluxpass@192.168.1.8:49257/flux/macos-gui-smb-sample.txt` | 30 B | `1641d420d25b7f31317938c4158c1bebe90136d56adb01c6cf31af2a6e9eb4d5` | 23:15:22 / 23:15:22 | 6.056 s | SMB2/3 共享真实落盘通过 |
| Torrent | 本地文件 `p2p/macos-gui-p2p-sample.torrent` | 34 B | `fe3405c854cfad26bd13dc2733762447d8229b3014e4ab4aff50f91abc040c21` | 23:15:28 / 23:15:38 | 15.637 s | metadata、真实文件名回写和下载校验通过 |
| Magnet | `magnet:?xt=urn:btih:b33adcecf0f541d848fcf88697aaf16643c4e730&dn=macos-gui-p2p-sample.txt&tr=http%3A%2F%2F192.168.1.8%3A49261%2Fannounce` | 34 B | `fe3405c854cfad26bd13dc2733762447d8229b3014e4ab4aff50f91abc040c21` | 23:15:43 / 23:15:48 | 10.068 s | metadata 获取、真实文件名回写和下载校验通过 |
| ed2k | `ed2k://\|file\|macos-gui-ed2k-sample.bin\|12\|0123456789ABCDEF0123456789ABCDEF\|/` | - | - | 23:15:53 / 23:15:53 | 5.329 s | FluxDown 到迅雷的系统移交通过；资源链接无效，未下载 |

## 发现并处理的问题

1. HTTP fixture 的默认监听 backlog 只有 5，桌面默认 8 个下载线程会偶发 `Connection reset by peer`。测试 fixture 已提升到 64，避免把服务端容量问题误判为 FluxDown 下载失败。
2. FTP fixture 的 EPSV 数据端口原先只绑定 `127.0.0.1`，使用局域网地址访问时控制连接成功但数据连接失败。现在控制和数据端口统一绑定实验室地址。
3. macOS 首次访问局域网服务需要本地网络权限。桌面 bundle 已增加 `NSLocalNetworkUsageDescription`。
4. 迅雷会监听系统剪切板并弹出新建任务，干扰自动化。macOS GUI 脚本改为通过辅助功能焦点直接写入输入框，不修改系统剪切板。

## 证据

- 原始结构化结果：[macos-desktop-gui-protocol-e2e-20260805.json](artifacts/macos-desktop-gui-protocol-e2e-20260805.json)
- 完成队列截图：[macos-desktop-gui-queue-20260805.png](artifacts/macos-desktop-gui-queue-20260805.png)
- 跨平台资源清单：[protocol-test-resources.md](protocol-test-resources.md)
- 本轮所有落盘文件仍保留在上述临时工作目录，已再次独立计算 SHA-256，11 个文件均与 JSON 记录一致。

## 复跑说明

复跑前需要构建 release CLI 和 macOS `.app`，确保 Docker Desktop 正常，并给当前终端或自动化宿主授予 macOS“辅助功能”权限：

```sh
npm --workspace apps/desktop run build
npm run desktop:build
npm run verify:macos-desktop-gui-protocols
```

脚本会占用前台 FluxDown 窗口，动态创建 HTTP(S)、FTP(S)、SFTP、SMB、tracker 和 seeder，结束后清理服务。每次复跑的局域网端口和 P2P info hash 可能变化，应以新生成的 JSON 为准。
