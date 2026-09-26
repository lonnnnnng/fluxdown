# Android 真机协议测试报告

## 2026-09-26 `1.0.25` Release 完整协议验收

本轮在 Redmi Note 8 Pro 真机上使用 `1.0.25 (26)` Release APK 运行完整协议矩阵。
为了让 Release APK 在 Android 沙盒限制下留下可复核证据，临时自检构建会把结构化
报告写入应用专属外部目录；自检完成后已重新构建并安装普通 Release APK。

### 环境与门禁

- 设备：Redmi Note 8 Pro，adb serial `wsvwypiz7xwslvl7`，Android 16。
- 包名与版本：`dev.fluxdown.mobile`，`1.0.25 (26)`。
- 普通 Release APK：`107,753,056` bytes，SHA-256
  `edd491b4b1ffdd95e1971a45d8d88eb1d59dd7f0449c9c6ccffe704d0c229c07`。
- 普通 Release 启动回验：重新安装后 `pidof dev.fluxdown.mobile` 返回进程，
  `dumpsys package` 显示 `versionName=1.0.25`、`versionCode=26`。
- 本地服务：HTTP/HTTPS `8767/9443`，FTP/FTPS `2021/2121`，SFTP `2222`，
  SMB `445`，BT tracker `6969`，Transmission seeder `51415`；Mac 地址
  `192.168.1.8`。HTTP 资源使用 USB reverse 的 `8767` 映射，避免旧服务目录残留。
- 设备报告：`/sdcard/Android/data/dev.fluxdown.mobile/files/fluxdown-e2e-report.json`，
  `exitStatus=0`、`failures=[]`；报告中的每个用例都有独立 `case_N` 输出目录。

### Release 协议结果

| 协议 | 资源与结果 | 证据 |
| --- | --- | --- |
| HTTP | 本地 `http.txt`，通过 | `finished`，`8/8 B`，SHA-256 `bc18d24ba27d60df18ebee3e50398330a976782fa5f3713bc1a6cebf560764b1` |
| HTTPS | 本地自签 `https.txt`，通过 | `finished`，`13/13 B`，SHA-256 `611db50d838121c0f8ea6dced34ec8905b92b92cb929d1f1a7d639e17cbbc096` |
| WebDAV | `http.txt`，通过 | `finished`，`8/8 B`，SHA-256 `bc18d24ba27d60df18ebee3e50398330a976782fa5f3713bc1a6cebf560764b1` |
| WebDAVS | `https.txt`，通过 | `finished`，`13/13 B`，SHA-256 `611db50d838121c0f8ea6dced34ec8905b92b92cb929d1f1a7d639e17cbbc096` |
| FTP | `readme.txt`，通过 | `finished`，`11/11 B`，SHA-256 `e18c2e7832f45b5981d9029e058d70da3f85da713a1fbae5276bdde8c819db59` |
| FTPS | `readme.txt`，通过 | `finished`，`11/11 B`，SHA-256 `e18c2e7832f45b5981d9029e058d70da3f85da713a1fbae5276bdde8c819db59` |
| SFTP | `sftp.txt`，通过 | `finished`，`8/8 B`，SHA-256 `bc18d24ba27d60df18ebee3e50398330a976782fa5f3713bc1a6cebf560764b1` |
| SMB | `smb.txt`，通过 | `finished`，`8/8 B`，SHA-256 `bc18d24ba27d60df18ebee3e50398330a976782fa5f3713bc1a6cebf560764b1` |
| HLS / m3u8 | 合法 H.264 播放列表，输出 MP4 | `finished`，`16,035 B`，SHA-256 `7433678e5021cd89e2ca51d1a4d24fa46d1ee15302c76dc558da69cac55ab7ac`，文件头含 `ftyp` |
| Torrent | 多文件种子，仅选择 `payload.bin` | `finished`，`8,388,608/8,388,608 B`，SHA-256 `2daeb1f36095b44b318410b3f4e8b5d989dcc7bb023d1426c492dab0a3053e74` |
| Magnet | 同一多文件资源，仅选择 `payload.bin` | `finished`，`8,388,608/8,388,608 B`，SHA-256 `2daeb1f36095b44b318410b3f4e8b5d989dcc7bb023d1426c492dab0a3053e74`；与 Torrent 使用独立输出目录 |
| ed2k | 无外部 handler，预期边界 | `failed`，错误包含 `No installed app can handle this ed2k link` |

结论：`1.0.25` Release APK 在该真机上 12 项矩阵全部达到预期，11 项真实落盘，
ed2k 按未安装外部客户端的预期边界失败。Release 自检首轮曾因旧 HTTP/FTP/HLS/Torrent
夹具目录不一致出现资源不存在，核对服务目录后改用当前夹具重跑并通过；首轮不计入结论。

## 2026-09-26 `1.0.24` Release 完整协议验收

本轮在 Redmi Note 8 Pro 真机上使用 Release 编译模式执行完整协议矩阵。协议自检
构建只临时增加了 logcat 取证通道，没有开启 `debuggable`，也没有改变下载逻辑；
矩阵结束后已撤回取证代码，重新构建并安装普通 Release APK 做启动回验。

### 环境与门禁

- 设备：Redmi Note 8 Pro，adb serial `wsvwypiz7xwslvl7`，Android 16。
- 包名与版本：`dev.fluxdown.mobile`，`1.0.24 (25)`。
- 普通 Release APK：`104,347,924` bytes，SHA-256
  `a16961745a52b7b0dfa0697b8904b8d2add41e66236a2130915f904f75973ea4`。
- 普通 Release 启动回验：进程保持运行，`MainActivity` 处于 resumed，无
  `FATAL EXCEPTION`；`run-as` 返回 `package not debuggable`。
- 本地服务：HTTP/HTTPS `8765/9443`，FTP/FTPS `2021/2121`，SFTP `2222`，
  SMB `445`，BT tracker `6969`，Transmission seeder `51413`；Mac 地址
  `192.168.1.8`。
- 真机访问本机 HTTP/HTTPS 资源前执行：
  `adb -s wsvwypiz7xwslvl7 reverse tcp:8765 tcp:8765` 和
  `adb -s wsvwypiz7xwslvl7 reverse tcp:9443 tcp:9443`。

### Release 协议结果

| 协议 | 资源与结果 | 证据 |
| --- | --- | --- |
| HTTP | `http://127.0.0.1:8765/http.txt`，通过 | `finished`，`8/8 B` |
| HTTPS | `https://127.0.0.1:9443/https.txt`，通过 | `finished`，`13/13 B`，允许本地测试证书 |
| WebDAV | `webdav://127.0.0.1:8765/http.txt`，通过 | `finished`，`8/8 B`；移动端复用 HTTP transport |
| WebDAVS | `webdavs://127.0.0.1:9443/https.txt`，通过 | `finished`，`13/13 B`；移动端复用 HTTPS transport |
| FTP | `ftp://flux:fluxpass@192.168.1.8:2021/ftp.txt`，通过 | `finished`，`8/8 B` |
| FTPS | `ftps://flux:fluxpass@192.168.1.8:2121/ftp.txt`，通过 | `finished`，`8/8 B`，允许本地测试证书 |
| SFTP | `sftp://flux:fluxpass@192.168.1.8:2222/upload/sftp.txt`，通过 | `finished`，`8/8 B` |
| SMB | `smb://flux:fluxpass@192.168.1.8/flux/smb.txt`，通过 | `finished`，`8/8 B` |
| HLS / m3u8 | `valid-playlist.m3u8`，通过 | 输出 `hls-release.mp4`，`16,035 B`，文件头包含 `ftyp` |
| Torrent | 多文件种子，仅选择 `payload.bin`，通过 | metadata 真实解析，`finished`，`8,388,608/8,388,608 B` |
| Magnet | 同一多文件资源，仅选择 `payload.bin`，通过 | metadata 真实解析，`finished`，`8,388,608/8,388,608 B` |
| ed2k | 无外部 handler，预期边界 | `failed`，错误包含 `No installed app can handle this ed2k link` |

最终自检状态：`FLUXDOWN_E2E_STATUS {"exitStatus":0,"failures":[]}`。
Torrent/Magnet 均观察到 metadata、文件优先级更新、piece 完成和 finished；磁力
链接的公共 tracker 拉取增加 8 秒上限，超时后继续使用用户提供的 tracker。

## 2026-09-25 `1.0.22` 源码工作树前台验收

本节只记录当前源码工作树重新构建的本地 Release APK，不代表已经发布的
`v1.0.22` Release 资产包含本节修复。设备和入口均为正常前台 App，不使用
Flutter integration test 的 `Test starting...` 页面。

### 环境与资源

- 设备：Redmi Note 8 Pro，adb serial `wsvwypiz7xwslvl7`，Android 16。
- 包名：`dev.fluxdown.mobile`；本地构建显示 `versionName=1.0.22`、`versionCode=23`。
- 构建命令：`npm run mobile:android:release`；APK 大小约 `105.7 MB`。
- 安装命令：`adb -s wsvwypiz7xwslvl7 install -r apps/mobile/build/app/outputs/flutter-apk/app-release.apk`。
- HTTP/HLS 服务：`python3 scripts/range-http-server.py --bind 0.0.0.0 --port 8765 --directory /tmp/fluxdown-e2e-hls`。
- USB 映射：`adb -s wsvwypiz7xwslvl7 reverse tcp:8765 tcp:8765`。
- 资源：`http://127.0.0.1:8765/http-small.txt`（21 B）、
  `http://127.0.0.1:8765/playlist.m3u8`（两段 TS，输出 24 B）。

### 前台结果

| 用例 | 操作与结果 | 证据 |
| --- | --- | --- |
| HTTP 小文件，修复前 | 使用默认 16 线程新建任务，收到完整 `21 B` 后进入失败 | 任务卡片显示 `文件读写失败`、`21 B / 21 B`；服务端收到多个 Range 请求。 |
| HTTP 小文件，修复后 | 新增任务，保持设置中的 16 线程，正常完成 | 任务卡片显示 `已完成 100%`、`HTTP · 127.0.0.1/http-small.txt`、`21 B / 21 B`；同一资源未再出现文件读写失败。 |
| HLS 小播放列表 | 新建任务，识别为 `M3U8 · 移动端内建`，文件名自动为 `playlist.mp4` | 任务卡片显示 `已完成 100%`、`M3U8 · 127.0.0.1/playlist.m3u8`、`24 B / 24 B`。 |
| 设置保存与回显 | 设置页读取并显示下载保存位置、并发、线程、重试 | 真机页面回显 `/data/user/0/dev.fluxdown.mobile/app_flutter/downloads`、`5`、`16`、`3`；版本显示 `v1.0.22`。 |

### 本轮代码修复与自动化回归

- HTTP Range 分片现在按资源大小限制并发：每个分片至少保留 1 KiB，极小文件自动回退单流，大文件仍按用户配置使用多线程。
- 新增 21 B 文件在 16 线程配置下回退单流的 Flutter 回归测试。
- `downloads HTTP files with multiple Range threads` 通过；新增
  `uses a single stream for tiny HTTP files with many configured threads` 通过。
- 当前未把暂停/继续的长文件真机尝试写成通过：本轮长任务操作期间设备外部测试应用抢占前台，未形成可审计的完整暂停、继续和重启恢复证据，后续需在稳定前台环境补测。

> 历史验证记录：本文协议结果采集自 `1.0.4`（`versionCode=5`），不代表当前 `1.0.8+9` 已重新完成全部协议下载。2026-08-04 仅在同一台 Redmi Note 8 Pro 上安装并复验当前 release APK 的启动、任务页、新建弹框和设置页 UI。

## 2026-07-01 公开动画 Torrent/Magnet 前台验证

用户希望使用动画资源验证磁力链接和种子下载。为避免引入疑似未授权资源站内容，
本轮改用 Blender 官方公开下载目录中的小体积动画/视频资源，并在本地生成
`.torrent` 与 magnet 做真机前台 App 流程验证。

测试环境：

- 设备：Redmi Note 8 Pro，adb id `wsvwypiz7xwslvl7`。
- App：`dev.fluxdown.mobile`，`versionName=1.0.4`。
- Mac 局域网地址：`192.168.1.12`。
- tracker：`http://192.168.1.12:6969/announce`。
- torrent HTTP：`http://192.168.1.12:8767/torrent/`。
- Transmission 做种端口：`192.168.1.12:51423`。
- 输入方式：正常打开前台 App，点击右下角新建任务按钮，在弹框中输入链接后点击
  “开始下载”；未使用隐藏 integration runner。

资源：

| 资源 | 来源 | 大小 | 源文件 SHA-256 |
| --- | --- | --- | --- |
| `ton_bug_1999.mpg` | `https://download.blender.org/demo/movies/ton_bug_1999.mpg` | 2,217,876 B | `e663add649d93aa6d286952ca8e5ac6cf1ce3d658cbb518d2e377bbd22b6a19c` |
| `seamcut_blender242.mov` | `https://download.blender.org/demo/movies/seamcut_blender242.mov` | 3,844,547 B | `17a1640e27cb48b6e2d576665fbc73a3de8c1d673c72fa9b2dd9ba153a3a77a1` |

本轮链接：

| 类型 | 链接 |
| --- | --- |
| `ton_bug_1999.mpg` torrent | `http://192.168.1.12:8767/torrent/ton_bug_1999.torrent` |
| `ton_bug_1999.mpg` magnet | `magnet:?xt=urn:btih:7c4a088c3b3b9a12dcede8fad6236ebeb6bb5326&dn=ton_bug_1999_magnet.mpg&tr=http%3A%2F%2F192.168.1.12%3A6969%2Fannounce` |
| `seamcut_blender242.mov` torrent | `http://192.168.1.12:8767/torrent/seamcut_blender242.torrent` |
| `seamcut_blender242.mov` magnet | `magnet:?xt=urn:btih:42f3705be45018174248467cef5e9fe6c8aaab86&dn=seamcut_blender242_magnet.mov&tr=http%3A%2F%2F192.168.1.12%3A6969%2Fannounce` |

说明：magnet 验证使用 `*_magnet.*` 文件名生成独立种子，避免命中同名 torrent
任务已经落盘的输出文件缓存；内容与对应源文件一致。

结果：

| Case | 协议 | 队列文件名 | 结果 | 队列证据 | 落盘 SHA-256 |
| --- | --- | --- | --- | --- | --- |
| `open-animation-ton-torrent` | Torrent | `ton_bug_1999.mpg` | 通过 | `state=finished`，`downloadedBytes=2217876/2217876`，开始 `01:57:47`，结束 `01:57:48` | `e663add649d93aa6d286952ca8e5ac6cf1ce3d658cbb518d2e377bbd22b6a19c` |
| `open-animation-seamcut-torrent` | Torrent | `seamcut_blender242.mov` | 通过 | `state=finished`，`downloadedBytes=3844547/3844547`，开始 `01:59:29`，结束 `01:59:30` | `17a1640e27cb48b6e2d576665fbc73a3de8c1d673c72fa9b2dd9ba153a3a77a1` |
| `open-animation-ton-magnet` | Magnet | `ton_bug_1999_magnet.mpg` | 通过 | `state=finished`，`downloadedBytes=2217876/2217876`，开始 `02:02:13`，结束 `02:02:23` | `e663add649d93aa6d286952ca8e5ac6cf1ce3d658cbb518d2e377bbd22b6a19c` |
| `open-animation-seamcut-magnet` | Magnet | `seamcut_blender242_magnet.mov` | 通过 | `state=finished`，`downloadedBytes=3844547/3844547`，开始 `02:04:01`，结束 `02:04:13` | `17a1640e27cb48b6e2d576665fbc73a3de8c1d673c72fa9b2dd9ba153a3a77a1` |

结论：Android 真机前台 App 流程下，公开动画资源的 `.torrent` 和 magnet 均可完成
metadata 识别、自动命名、队列完成状态更新和文件落盘；落盘 SHA-256 与源文件一致。

## 2026-07-01 最新前台 App 复测

本轮继续使用 Redmi Note 8 Pro 真机正常 App UI，不使用隐藏 integration runner
作为证据。设备 adb id 为 `wsvwypiz7xwslvl7`，App 包名为
`dev.fluxdown.mobile`，安装版本显示 `versionName=1.0.4`、`versionCode=5`。

测试方式：

- 通过右下角“新建任务”按钮打开新建弹框，输入下载链接后点击“开始下载”。
- 通过 `run-as dev.fluxdown.mobile` 读取 App 队列 JSON 和落盘文件，仅作为结果取证。
- 本轮已全局移除 IPFS，因此 IPFS 不再纳入协议总数和测试用例。
- 当前有效协议口径为 12 类：HTTP、HTTPS、WebDAV、WebDAVS、FTP、FTPS、
  SFTP、SMB、m3u8/HLS、Torrent、Magnet、ed2k。

### 资源和服务

- Mac 局域网地址：`192.168.1.12`。
- FTPS：`ftps://flux:fluxpass@192.168.1.12:2121/ftps.txt?allowBadCertificate=true`。
- SMB：`smb://flux:fluxpass@192.168.1.12/flux/sample.txt`。
- Torrent/Magnet 本地实验室：
  - tracker：`http://192.168.1.12:6969/announce`
  - torrent HTTP：`http://192.168.1.12:8099/android-single.torrent`
  - magnet：`magnet:?xt=urn:btih:fb11339dd7ff771f67d5d21c1f77f07aee67249a&dn=android-p2p-single.txt&tr=http%3A%2F%2F192.168.1.12%3A6969%2Fannounce`
  - Transmission 做种端口：`192.168.1.12:51423`
- 公网小资源：
  - HTTP：`http://example.com/`
  - HTTPS：`https://cloudflare.com/cdn-cgi/trace`
  - WebDAV transport：`webdav://example.com/`
  - WebDAVS transport：`webdavs://cloudflare.com/cdn-cgi/trace`
  - FTP/SFTP：`ftp://demo:password@test.rebex.net/readme.txt`、
    `sftp://demo:password@test.rebex.net/readme.txt`
  - HLS：`https://raw.githubusercontent.com/shaka-project/shaka-player/main/test/test/assets/hls-ts-aac/playlist.m3u8`

### 结果矩阵

| 协议 | 结果 | 证据 |
| --- | --- | --- |
| HTTP | 通过 | 队列快照 `2026-07-01 00:22`：`state=finished`，`fileName=example.com`，`downloadedBytes=559/559`；真机落盘 `/app_flutter/downloads/example.com`，大小 559 B。 |
| HTTPS | 通过 | 队列快照：`state=finished`，`fileName=trace`，`downloadedBytes=212/212`；真机落盘存在。后续 WebDAVS 同名文件覆盖为 213 B。 |
| WebDAV | 通过 | 队列快照：`state=finished`，`fileName=example.com`，`downloadedBytes=559/559`。移动端当前按 HTTP transport 处理 WebDAV scheme。 |
| WebDAVS | 通过 | 队列快照：`state=finished`，`fileName=trace`，`downloadedBytes=213/213`；真机落盘 `/app_flutter/downloads/trace`，大小 213 B。移动端当前按 HTTPS transport 处理 WebDAVS scheme。 |
| FTP | 通过 | 队列快照：`state=finished`，`fileName=readme.txt`，`downloadedBytes=379/379`；真机落盘 `readme.txt`，大小 379 B。 |
| FTPS | 通过 | 本地 FTPS 小文件 `ftps.txt`：`state=finished`，`downloadedBytes=21/21`；真机落盘 `ftps.txt`，大小 21 B。旧的 `readme.txt` FTPS 用例因目标文件变化触发 REST 越界失败，不作为本轮通过证据。 |
| SFTP | 通过 | 队列快照：`state=finished`，`fileName=readme.txt`，`downloadedBytes=379/379`；真机落盘 `readme.txt`，大小 379 B。 |
| SMB | 通过 | 队列快照：`state=finished`，`fileName=sample.txt`，`downloadedBytes=24/24`；真机落盘 `sample.txt`，大小 24 B。 |
| m3u8/HLS | 通过 | Shaka HLS：`state=finished`，队列记录 `downloadedBytes=510847/510847`；真机落盘 `playlist.mp4`，大小 517599 B，输出为 `.mp4`。 |
| Torrent | 通过 | 通过前台新建任务输入 `http://192.168.1.12:8099/android-single.torrent`；App metadata 后把卡片名改为真实文件 `android-p2p-single.txt`；`state=finished`，`downloadedBytes=39/39`；真机落盘 `android-p2p-single.txt`，大小 39 B。 |
| Magnet | 未通过 | 使用同一做种资源的完整 magnet，App 自动识别并命名为 `android-p2p-single.txt`，但等待约 2 分钟后仍为 `state=running`、`downloadedBytes=0`、`totalBytes=null`，未拿到 metadata。 |
| ed2k | 移交通路通过 | 从 F-Droid 安装 `Mule on Android`（`org.dkf.jmule`，versionCode `39`，versionName `38`，APK SHA-256 `936a40a3f8b8b1c3f7509eb3bb4f8a8671d2eb3d3f67b41fa92fbf3c263a7493`）。FluxDown 前台新建真实链接 `ed2k://|file|en_kinect_for_windows_developer_toolkit_v1.5.2_x86_x64.exe|62599512|BB8329A4CD8FF37AAD8D25A77869192F|/` 后，系统启动 `org.dkf.jmule/.activities.MainActivity`；Mule 列表显示 `en_kinect_for_windows_developer_toolkit_v1.5.2_x86_x64.exe`、`59.70 Mb`、状态 `等待来源`。FluxDown 队列记录 `state=finished`、`downloadedBytes=0/0`，表示移交已完成，不代表 FluxDown 内建完成 ed2k 文件下载。 |

### 本轮结论

> 状态口径修正：上方历史快照中的 ed2k 记录曾写作 `state=finished`。当前移动端实现已改为 `state=handedOff`；该状态只表示链接已成功交给外部客户端，不表示 FluxDown 内建下载完成。

- 已完成真机真实下载成功：HTTP、HTTPS、WebDAV、WebDAVS、FTP、FTPS、SFTP、
  SMB、m3u8/HLS、Torrent，共 10 类。
- 已完成真机外部 App 移交：ed2k。安装 `Mule on Android` 后，FluxDown 能把
  ed2k 链接移交给外部客户端，外部客户端能创建对应传输任务并等待来源。
- 未通过：Magnet。即使使用局域网本地 tracker + Transmission 做种，当前移动端
  `libtorrent_flutter` 任务仍长时间停留在 0B/无 metadata。后续需要继续排查
  Android 端 magnet 添加、tracker announce、metadata 获取链路。

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
  WebDAVS transport、m3u8/HLS、SMB、BitTorrent `.torrent`、Magnet
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
