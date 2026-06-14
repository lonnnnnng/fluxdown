# Android 真机协议测试报告

## 运行上下文

- 日期：2026-06-13，Asia/Shanghai。
- 设备：Redmi Note 8 Pro，adb id `wsvwypiz7xwslvl7`。
- App 包名：`dev.fluxdown.mobile`。
- 测试入口：`apps/mobile/integration_test/protocol_e2e_test.dart`。
- 规则：测试资源优先低于 10 MB。本轮基线通过项均低于 1 MB。

## 资源选择

公网资源只选择明确用于测试或体积很小的公开样例。最终 Android
基线使用本地实验室资源，便于在不同设备网络和其他平台重复验证。
SMB、WebDAV 实验共享等不适合暴露到公网的协议，统一在
`docs/protocol-e2e-test-cases.md` 中按本地实验室资源描述。

## 结果摘要

- Android 真机通过：HTTP、HTTPS、FTP、FTPS、SFTP、WebDAV transport、
  WebDAVS transport、m3u8/HLS、SMB、BitTorrent `.torrent`、Magnet、IPFS
  gateway 下载。
- 边界验证：ed2k。FluxDown 会把 ed2k 移交给外部 Android App；当前设备未安装
  ed2k handler，因此预期结果是明确的无 handler 失败。
- 重要区别：移动端 WebDAV/WebDAVS 当前复用 HTTP/HTTPS transport。该结果证明
  FluxDown 的 scheme 映射和文件写入路径，不代表已经覆盖 `PROPFIND` 等完整
  WebDAV 方法。

## 2026-06-14 前台 App 媒体级回归

本轮使用同一台 Redmi Note 8 Pro 上的正常前台 App 验证，不再使用 Flutter
integration-test 的 "Test starting..." 页面。实验室主机为 `192.168.1.7`，手机为
`192.168.1.18`，源视频是本地合法文件
`/Users/long/Downloads/20260614.mp4`。App 重新构建 debug APK 后安装到真机，并以
`dev.fluxdown.mobile/.MainActivity` 启动。

本地服务：

- HTTP 资源服务：`http://192.168.1.7:8766`
- 本地 tracker：`http://192.168.1.7:6969/announce`
- Transmission 做种端口：`192.168.1.7:51413`

测试资源：

- HLS：`http://192.168.1.7:8766/hls/index.m3u8`
- 单文件种子：`http://192.168.1.7:8766/torrent/20260614.torrent`
- 单文件磁力：
  `magnet:?xt=urn:btih:687ef6e568cf998d7ce9d2e52a973f919b8ff37a&dn=20260614.mp4&tr=http%3A%2F%2F192.168.1.7%3A6969%2Fannounce`
- 多文件种子：
  `http://192.168.1.7:8766/multi_torrent/20260614_bundle.torrent`
- 多文件磁力：
  `magnet:?xt=urn:btih:5aa3ec33f8be1e153a5b2fc07160f65f5f431885&dn=20260614_bundle&tr=http%3A%2F%2F192.168.1.7%3A6969%2Fannounce`

| Case id | 协议 | 初始卡片名 | 最终卡片名 | 结果 | 证据 |
| --- | --- | --- | --- | --- | --- |
| `hls-local-media` | m3u8/HLS | `index.mp4` | `index.mp4` | 通过 | `state=finished`，`downloadedBytes=387821943`，`totalBytes=387821943`；最终文件 `hls/index.mp4` 存在，大小 388593397 bytes。Android remux 生成最终 `.mp4`。 |
| `torrent-local-media-single` | `.torrent` | `20260614.torrent` | `20260614.mp4` | 通过 | libtorrent metadata 含 1 个文件，`selectedTorrentFileIndexes=[0]`；`state=finished`，`downloadedBytes=388617898`，`totalBytes=388617898`；最终文件存在，大小 388617898 bytes。 |
| `magnet-local-media-single` | Magnet | `magnet-download` | `20260614.mp4` | 通过 | libtorrent metadata 含 1 个文件，`selectedTorrentFileIndexes=[0]`；`state=finished`，`downloadedBytes=388617898`，`totalBytes=388617898`；最终文件存在，大小 388617898 bytes。 |
| `torrent-local-media-multi-selection` | `.torrent` | `20260614_bundle.torrent` | `20260614.mp4` | 通过 | App 弹出多文件选择框，包含 `20260614_bundle/20260614.mp4` 和 `20260614_bundle/readme.txt`。仅选择 index `0`；任务持久化 `torrentName=20260614_bundle`、两个 `torrentFiles`、`selectedTorrentFileIndexes=[0]`。进度总量只计算所选视频大小 `388617898` bytes。最终视频存在，`readme.txt` 未作为输出文件写出。 |
| `magnet-local-media-multi-selection` | Magnet | `magnet-bundle` | `20260614.mp4` | 通过 | Magnet metadata 到达后弹出同样的多文件选择框。仅选择 index `0`；任务持久化 `torrentName=20260614_bundle`、两个 `torrentFiles`、`selectedTorrentFileIndexes=[0]`。最终视频存在，`readme.txt` 未作为输出文件写出。 |

最终 App 截图保存为 `docs/artifacts/android-protocol-verify-20260614.png`。
截图显示 5 个任务、5 个已完成、0 个下载中、0 个失败。队列页展示了每个任务的开始时间、
结束时间、总耗时、已下载/总大小和平均速度。

最终 logcat 扫描未发现 App 崩溃或 FluxDown 相关错误。

### 本轮修复的问题

- Android 大体积 TS 文件 HLS remux 可能阻塞。现在原生 remux 工作移出 UI 线程，并在
  `advance()` 返回 false 时停止 extractor 循环。
- Torrent 选择部分文件时，进度现在按所选文件总量计算，并把显示的已下载字节钳制在该总量内。
- Torrent metadata 处理改为串行化。多文件种子会在文件选择弹框打开期间暂停传输，应用文件优先级后再恢复，避免用户确认前下载未选文件。
- libtorrent metadata 到达后，移动端任务会持久化 `torrentName`、`torrentFiles` 和
  `selectedTorrentFileIndexes`，并把可见卡片名从 `.torrent` 文件名或临时 magnet 名称更新为真实选中文件名。

## 详细结果

| Case id | 协议 | 资源 | 限制 | Android 结果 | 证据 |
| --- | --- | --- | --- | --- | --- |
| `http-local-small` | HTTP | `http://127.0.0.1:8765/seg1.ts`，通过 `adb reverse` | 12 B | 通过 | `state=finished`，`downloadedBytes=12`，`outputBytes=12`，内容匹配 `segment-one\n`。 |
| `https-local-small` | HTTPS | `https://127.0.0.1:9443/https.txt?allowBadCertificate=true`，通过 `adb reverse` | 13 B | 通过 | `state=finished`，`downloadedBytes=13`，`outputBytes=13`，内容匹配 `https-sample\n`。 |
| `ftp-local-small` | FTP | `ftp://flux:fluxpass@192.168.1.7:2021/readme.txt` | 12 B | 通过 | `state=finished`，`downloadedBytes=12`，`outputBytes=12`，内容匹配 `ftps-sample\n`。 |
| `ftps-local-small` | FTPS | `ftps://flux:fluxpass@192.168.1.7:2121/readme.txt?allowBadCertificate=true` | 12 B | 通过 | `state=finished`，`downloadedBytes=12`，`totalBytes=12`，`outputBytes=12`，内容匹配 `ftps-sample\n`。 |
| `sftp-local-small` | SFTP | `sftp://flux:fluxpass@192.168.1.7:2222/upload/readme.txt` | 12 B | 通过 | `state=finished`，`downloadedBytes=12`，`outputBytes=12`，内容匹配 `sftp-sample\n`。 |
| `webdav-local-small` | WebDAV | `webdav://127.0.0.1:8765/seg1.ts`，通过 `adb reverse` | 12 B | 通过 | `state=finished`，`downloadedBytes=12`，`outputBytes=12`；移动端 transport 映射到 HTTP。 |
| `webdavs-local-small` | WebDAVS | `webdavs://127.0.0.1:9443/https.txt?allowBadCertificate=true`，通过 `adb reverse` | 13 B | 通过 | `state=finished`，`downloadedBytes=13`，`outputBytes=13`；移动端 transport 映射到 HTTPS。 |
| `hls-local-small` | m3u8/HLS | `http://127.0.0.1:8765/playlist.m3u8`，通过 `adb reverse` | 24 B output | 通过 | `state=finished`，`downloadedBytes=24`，`outputBytes=24`，内容匹配拼接后的分片。 |
| `smb-local-small` | SMB | `smb://flux:fluxpass@192.168.1.7/flux/sample.txt` | 11 B | 通过 | `state=finished`，`downloadedBytes=11`，`outputBytes=11`，内容匹配 `smb-sample\n`。 |
| `torrent-local-small` | BitTorrent | `http://127.0.0.1:8765/webtorrent-sample.torrent`，通过 `adb reverse` | 15 B payload | 通过 | `state=finished`，`downloadedBytes=15`，`totalBytes=15`，`outputBytes=15`，内容匹配 `torrent-sample\n`。 |
| `magnet-local-small` | Magnet | `magnet:?xt=urn:btih:fb443f977107cf6810a45c93288e63009291124d&dn=torrent-sample.txt&tr=http%3A%2F%2F192.168.1.7%3A8000%2Fannounce` | 15 B payload | 通过 | `state=finished`，`downloadedBytes=15`，`totalBytes=15`，`outputBytes=15`，内容匹配 `torrent-sample\n`。 |
| `ipfs-local-gateway-small` | IPFS | `ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244/readme.txt?gateway=http%3A%2F%2F127.0.0.1%3A8765` | 10 B | 通过 | `state=finished`，`downloadedBytes=10`，`outputBytes=10`，内容匹配 `Hello IPFS`。 |
| `ed2k-no-handler` | ed2k | `ed2k://|file|sample.bin|12|0123456789ABCDEF0123456789ABCDEF|/` | 12 B link | 预期的无 handler 边界 | `state=failed`，错误包含 `No installed app can handle this ed2k link`。Android package manager 也返回 `No activities found`。 |

## 使用命令

```sh
adb -s wsvwypiz7xwslvl7 reverse tcp:8765 tcp:8765

cd apps/mobile
flutter test integration_test/protocol_e2e_test.dart \
  -d wsvwypiz7xwslvl7 \
  --dart-define=FLUXDOWN_E2E_CASES_JSON='<json cases>'
```

integration test 结束后还安装并启动过 release APK。截图和窗口验证前需要保持设备亮屏：

```sh
adb -s wsvwypiz7xwslvl7 shell input keyevent KEYCODE_WAKEUP
adb -s wsvwypiz7xwslvl7 shell wm dismiss-keyguard
cd apps/mobile
flutter build apk --release
adb -s wsvwypiz7xwslvl7 install -r build/app/outputs/flutter-apk/app-release.apk
adb -s wsvwypiz7xwslvl7 shell am start -n dev.fluxdown.mobile/.MainActivity
```

前台验证显示 `dev.fluxdown.mobile/.MainActivity`、`state=RESUMED`、
`reportedDrawn=true`，并且能看到默认中文 UI、下载源输入、协议 chips 和队列控制。

## 使用的本地实验室服务

以下本地服务用于保证测试合法、小体积且可在其他平台重复：

```sh
# HTTP/HLS/.torrent fixture server
python3 -m http.server 8765 --bind 0.0.0.0

# HTTPS/WebDAVS fixture server
python3 -m http.server 9443 --bind 0.0.0.0 \
  --tls-cert /tmp/fluxdown-e2e-ftps/cert.pem \
  --tls-key /tmp/fluxdown-e2e-ftps/key.pem

# Android access to local HTTP/HTTPS fixture servers
adb -s wsvwypiz7xwslvl7 reverse tcp:8765 tcp:8765
adb -s wsvwypiz7xwslvl7 reverse tcp:9443 tcp:9443

# FTP fixture
python -m pyftpdlib -i 0.0.0.0 -p 2021 \
  -d /tmp/fluxdown-e2e-ftps \
  -u flux -P fluxpass \
  -n 192.168.1.7 \
  -r 30100-30110

# FTPS fixture
python -m pyftpdlib -i 0.0.0.0 -p 2121 \
  -d /tmp/fluxdown-e2e-ftps \
  -u flux -P fluxpass \
  --tls \
  --keyfile /tmp/fluxdown-e2e-ftps/key.pem \
  --certfile /tmp/fluxdown-e2e-ftps/cert.pem \
  --tls-control-required \
  --tls-data-required \
  -n 192.168.1.7 \
  -r 30000-30010

# SFTP fixture
docker run -d --name fluxdown-sftp -p 2222:22 \
  -v /tmp/fluxdown-e2e-sftp/upload:/home/flux/upload:ro \
  atmoz/sftp flux:fluxpass:::upload

# SMB fixture
docker run -d --name fluxdown-samba -p 445:445 \
  -v /tmp/fluxdown-e2e-smb:/share:ro \
  dperson/samba \
  -u 'flux;fluxpass' \
  -s 'flux;/share;yes;no;no;flux'

# BitTorrent tracker and seed, from /tmp/fluxdown-bt-tools
./node_modules/.bin/bittorrent-tracker --http --udp --port 8000
./node_modules/.bin/webtorrent seed /tmp/fluxdown-bt-seed/torrent-sample.txt \
  --announce http://192.168.1.7:8000/announce \
  --torrent-port 51413 \
  --keep-seeding \
  --quiet
```

## 当前缺口

- ed2k 需要设备安装外部 ed2k 客户端。FluxDown 当前只负责移交 `ed2k://` 链接，无法验证外部客户端下载完成状态。
- WebDAV/WebDAVS 在移动端仍是 transport-level 检查，因为当前移动端后端把它们映射到 HTTP/HTTPS GET。完整 WebDAV 方法覆盖需要 WebDAV 专用客户端实现和对应 fixture。
- 公网 smoke case 仍有价值，但不适合作为本设备/网络下的 Android 基线。本轮 full-suite 中，公网 Cloudflare、Rebex、example.com 检查超时，而对应本地协议资源通过。

## 备注

- 初始候选 `http://ipv4.download.thinkbroadband.com/5MB.zip`、
  `http://cachefly.cachefly.net/1mb.test` 和
  `https://speed.cloudflare.com/__down?bytes=1048576` 没有保留为 Android
  基线，因为当前设备网络对这些目标超时或连接失败。
- 当前设备的 Android system `curl` 不包含 FTP 支持，因此 FTP 通过 FluxDown 移动端自身的 FTP 实现验证。
- `flutter test` 会临时卸载并重新安装 test app。测试后又安装 release APK，用于确认真机可启动和 UI 可见。
- 最终完整本地套件在一次 integration-test 中完成，结果为 `00:08 +1: All tests passed!`。
