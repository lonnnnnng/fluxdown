# 下载验证状态

截至 2026-06-18，FluxDown 还没有完成“每一端安装或启动后实际下载成功”的全端端到端验证；Android 真机已经补过一轮正常 App 下载验证，macOS CLI 已补充本地 HTTP/HLS/Torrent/Magnet、公网 WebDAVS/FTP/SFTP/IPFS、本地自签 HTTPS/WebDAVS/FTPS 和自定义 IPFS gateway 真实下载验证，macOS GUI 已完成本地构建、启动、基础界面渲染和 Tauri command 级真实 HTTP 下载验证。

本页用于区分两类容易混淆的结论：

- 构建、测试、CI 和 Release artifact 校验：确认代码能编译、测试能跑、产物存在且非空。
- 真实下载端到端验证：在目标平台安装或启动对应 CLI/GUI/App，添加下载任务，并确认文件真实写入完成。

当前可以确认的是构建和自动化测试覆盖较多，Android 真机覆盖了一批真实下载场景，macOS CLI 覆盖了更多协议的下载闭环；但仍不能表述为“所有端都下载验证通过”。

## 分端结论

| 端 | 当前验证情况 | 是否完成真实下载 E2E |
| --- | --- | --- |
| 桌面 CLI | Rust 单元测试、CLI 集成测试、队列测试、本地 HTTP/HLS/Torrent/Magnet、公网 WebDAVS/FTP/SFTP/IPFS、本地自签 HTTPS/WebDAVS/FTPS、自定义 IPFS gateway、限速、失败重试、暂停继续、运行中删除和并发排队均已验证。 | 部分完成 |
| macOS GUI | 已完成 Tauri `.app` 构建、本地启动、窗口渲染、设置/任务操作 Tauri command 回归测试，以及 Tauri command 级 HTTP/HLS/WebDAV/IPFS 单任务真实下载和队列真实下载。Computer Use/AppleScript 鼠标自动化会触发 macOS “允许 Codex 控制其他 App”权限弹窗，`tauri-driver` 在本机 macOS 返回 `not supported on this platform`，尚未完成纯 GUI 点击创建任务并下载的闭环。 | 部分完成 |
| Windows GUI | 已有 CI/Docker 构建产物和 artifact 检查。没有在 Windows 上安装或运行 GUI 完成下载验证。 | 未完成 |
| Linux GUI | 已有 Linux GUI 可执行文件、`.deb`、`.rpm` artifact 检查。没有安装包后通过界面完成下载验证。 | 未完成 |
| Android App | 已在 Redmi Note 8 Pro 真机安装并通过正常 App 队列完成本地 HTTP/HTTPS/FTP/FTPS/SFTP/SMB/IPFS、小 HLS、小 torrent、小 magnet，以及 2026-06-14 媒体级 HLS、单文件 torrent、单文件 magnet、多文件 torrent 和多文件 magnet 选择下载验证。 | 部分完成 |
| iPhone App | 已有 simulator / unsigned device 编译产物检查。缺少签名 IPA，也没有在 iPhone 或模拟器中完成 App 内下载验证。 | 未完成 |

## 分协议结论

| 协议/能力 | 当前验证情况 | 备注 |
| --- | --- | --- |
| HTTP/HTTPS | CLI 和核心层有本地下载验证；2026-06-18 macOS CLI 已验证直接下载、队列下载、限速、失败重试、暂停继续、运行中删除、并发排队，以及本地自签 HTTPS opt-in。 | 证据最充分。 |
| WebDAV/WebDAVS | 核心层验证了 URL 到 HTTP/HTTPS 传输的映射；2026-06-18 macOS CLI 已验证公网 WebDAVS transport 和本地自签 WebDAVS transport，CLI/桌面 command 均有队列回归覆盖。 | 仍未覆盖完整 WebDAV 方法，例如 PROPFIND/目录遍历。 |
| m3u8/HLS | 核心层覆盖本地 HLS playlist、AES-128 分片和 master playlist 首个变体；Android 真机和 macOS CLI 均已验证媒体级 HLS 可生成最终 `.mp4`，CLI 直连/队列和桌面 command 均有本地 HLS fixture 回归。 | 仍需要更多公网和边界 playlist 验证。 |
| FTP/FTPS | 2026-06-18 macOS CLI 已验证公网 FTP 和本地自签 FTPS 下载闭环。 | Rebex 公网 FTPS 仍失败，错误为 `InvalidContentType`；本地可控 FTPS fixture 已通过。 |
| SFTP | 2026-06-18 macOS CLI 已验证公网 SFTP 下载闭环。 | 仍缺少本地 SFTP fixture 的 macOS CLI 回归。 |
| SMB | 有实现和 URL 解析测试。 | 缺少真实 SMB 共享下载闭环。 |
| BitTorrent `.torrent` | Android 真机已验证本地小种子、媒体级单文件种子和多文件种子选择下载；macOS CLI 已验证单文件和多文件本地种子真实下载、真实文件名/目录名和 SHA-256。 | Windows/Linux GUI 仍需要真实下载验证。 |
| Magnet | Android 真机已验证本地小磁力、媒体级单文件 magnet 和多文件 magnet 选择下载；macOS CLI 已验证本地 magnet metadata 获取、真实文件名和 SHA-256。 | Windows/Linux GUI 仍需要真实下载验证。 |
| ed2k | 核心层验证了 aMule `ed2k` CLI 移交路径。 | FluxDown 不掌控外部客户端的实际下载完成状态。 |
| IPFS | 2026-06-18 macOS CLI 已验证公网 IPFS 网关下载和本地自定义 gateway 下载，CLI/桌面 command 均有自定义 gateway 队列回归覆盖。 | 仍不运行本地 IPFS 节点。 |

## 当前准确表述

FluxDown 已经具备多端架构、构建产物、CI/Release artifact 校验、核心协议下载测试、Android 真机 App 下载验证和 macOS CLI 本地协议真实下载验证，但尚未完成每个平台 CLI/GUI/App 安装或启动后的真实下载端到端验证。

在完成目标系统上的安装、启动、任务添加、下载完成和文件校验前，不应宣称对应端已经通过下载验证。

## 后续验证建议

1. 先建立可重复测试资源：本地 HTTP/WebDAV、FTP、SFTP、SMB 服务和小体积 HLS playlist。
2. 逐端验证最小闭环：CLI、macOS GUI、Linux GUI、Windows GUI、Android App、iPhone App。
3. 每次验证记录：平台、版本、安装方式、下载源、输出路径、文件大小、校验和、失败日志。
4. 再补真实公网协议：torrent、magnet、IPFS、ed2k 外部客户端移交。

## 2026-06-18 macOS CLI/GUI 验证记录

### 环境

- 平台：macOS 本机，仓库分支 `main`。
- 构建版本：`1.0.2`。
- 本地资源目录：`../local_protocol_resources`。
- 本机局域网 IP：`192.168.1.7`，本轮 CLI 下载主要使用 `127.0.0.1` 本地服务。
- 本地 HTTP 服务：`python3 -m http.server 8765 --bind 127.0.0.1 --directory ../local_protocol_resources`。
- 本地 Torrent tracker：`python3 ../local_protocol_resources/local_bt_tracker.py --host 0.0.0.0 --port 6969`。
- 本地 seeder：`transmission-daemon -g ../local_protocol_resources/transmission-config -f`。

### 构建和自动化检查

| 检查项 | 结果 |
| --- | --- |
| `cargo test -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop` | 通过：CLI 单元 1、CLI 集成 19、core 48、desktop 18。 |
| `cargo build -p fluxdown-cli --release` | 通过，生成 `target/release/fluxdown`。 |
| `npm --workspace apps/desktop run build` | 通过。 |
| `npm run desktop:build` | 通过，生成 `target/release/bundle/macos/FluxDown.app`。 |
| `target/release/fluxdown doctor` | 通过；内建 HTTP/HTTPS/WebDAV/FTP/FTPS/Torrent/Magnet/m3u8/SFTP/SMB/IPFS 可执行；ed2k 为系统移交，当前 PATH 缺少可选 `ed2k` CLI。 |

### CLI 真实下载

| 用例 | 下载源 | 结果 |
| --- | --- | --- |
| HTTP 直接下载 | `http://127.0.0.1:8765/multi/20260614_bundle/readme.txt` | 通过，输出 `readme.txt`，SHA-256 为 `4b75951c517de7955172428fa7030caa7ad837580bcee33095208491031eaf93`。 |
| HTTP 多线程直连下载 | 本地支持 `HEAD` 和 `Range` 的 HTTP fixture，`download --threads 4` | 通过，CLI 层触发多个 HTTP Range 请求，输出文件内容与源 payload 完全一致。 |
| HTTP 队列下载 | 同上，通过 `add`、`list`、`run --concurrency 1 --threads 4` | 通过，任务 `queued -> finished`，`total_bytes=43`，输出 hash 一致。 |
| HLS 媒体下载 | `http://127.0.0.1:8765/hls/index.m3u8`；本地两分片 HLS fixture，`fluxdown download --name cli-hls.m3u8`、`add -> run -> list` 队列路径和 `add -> start -> list` 单任务路径 | 媒体级手动验证通过，232 个分片输出 `index.mp4`，大小 `388653222` bytes；`ffprobe` 可识别为 `mov,mp4,m4a,3gp,3g2,mj2`，duration `1514.481333`。CLI 集成回归通过，确认 `.m3u8` 任务输出最终 `.ts` 产物、JSON summary 包含 `segments_written=2`、队列和单任务启动都会把最终文件名回写为 `.ts`，文件内容等于两个分片拼接结果。 |
| 单文件 Torrent | `../local_protocol_resources/torrent/20260614.torrent` | 通过，metadata 后输出真实文件名 `20260614.mp4`，SHA-256 为 `4df2d9155b5714274f91beda0029041d9ef880f2996172adfd5bc5e29db42650`。 |
| 单文件 Magnet | `../local_protocol_resources/torrent/20260614.magnet.txt` 中的 magnet | 通过，metadata 后输出真实文件名 `20260614.mp4`，SHA-256 同源文件。 |
| 多文件 Torrent | `../local_protocol_resources/multi_torrent/20260614_bundle.torrent` | 通过，输出真实目录 `20260614_bundle`，内部 `20260614.mp4` 和 `readme.txt` 的 SHA-256 均与源文件一致。 |
| 限速 | `seg_00047.ts`，`--speed-limit-mbps 0.5` | 通过，4.7 MB 文件耗时约 10 秒。 |
| 失败重试 | 404 源，`--retry-attempts 2`；一次 500 后恢复的 HTTP 源默认不传 `--retry-attempts` | 通过，显式重试 2 次时服务端看到 3 次请求，任务最终 `failed` 并记录 404 错误；默认不传重试参数时会自动重试 1 次并完成下载，显式 `--retry-attempts 0` 表示不重试。 |
| 暂停/继续 | `seg_00047.ts` 限速下载中暂停，再 `resume` 和 `run` | 通过，暂停时 partial 文件约 0.9 MB，恢复后完成，SHA-256 与源文件一致。 |
| CLI 跨进程暂停/恢复 | 一个 CLI 进程执行 `run --speed-limit-mbps 0.05`，另一个 CLI 进程执行 `pause <id>`，随后 `resume <id>` 并再次 `run` | 通过，运行中任务先变为 `paused` 并保留 partial 文件和已下载进度；恢复后通过 HTTP Range 续传完成，最终文件内容匹配源数据。 |
| CLI 跨进程删除运行中任务 | 一个 CLI 进程执行 `run --speed-limit-mbps 0.05`，另一个 CLI 进程执行 `remove <id>` | 通过，`run` 成功退出，任务不会被下载协程重新写回队列，最终 `list` 为空。 |
| 并发排队 | 两个约 4.5 MB 文件，`--speed-limit-mbps 1` | 通过，并发 1 耗时约 9 秒且串行开始；并发 2 耗时约 5 秒且同时开始。CLI 默认不传 `--concurrency` 时按 1 串行执行；核心队列测试还验证了 3 个队列任务在并发 2 时最多只会同时启动 2 个。 |
| 公网 WebDAVS transport | `webdavs://cloudflare.com/cdn-cgi/trace`；本地 WebDAV queue fixture | 公网 transport 通过，输出 `196` bytes，内容包含 `ip=`，SHA-256 为 `74008f0b855c810153841264bdc2136ce5fda697c658876c8932994b78a6727c`。CLI 队列回归通过，确认 `webdav://` 映射到预期 HTTP 路径，任务 `finished` 后保留用户指定文件名并写入完整 payload。 |
| 公网 FTP | `ftp://demo:password@test.rebex.net/readme.txt` | 通过，输出 `379` bytes，SHA-256 为 `b004de45d8a133e9713a369f9c912237e8ad35dd9140c0279d27bada067797f4`。 |
| 公网 SFTP | `sftp://demo:password@test.rebex.net/readme.txt` | 通过，输出 `379` bytes，SHA-256 同 FTP Rebex readme。 |
| 公网 IPFS | `ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244`；本地自定义 gateway queue fixture | 公网 gateway 通过，输出 `Hello IPFS`，`11` bytes，SHA-256 为 `651c56a2438ce5db7a62fe4009ff146ce58cbe8f97cc83ffa2e7c42d461f3ae7`。CLI 队列回归通过，确认 `ipfs://...?...gateway=` 映射到 `/ipfs/<cid>/readme.txt`，任务完成后保留用户指定文件名并写入完整 payload。 |
| 本地 HTTPS 自签 | `https://127.0.0.1:9444/https.txt?allowBadCertificate=true` | 通过，输出 `https-sample\n`，`13` bytes，SHA-256 为 `611db50d838121c0f8ea6dced34ec8905b92b92cb929d1f1a7d639e17cbbc096`。 |
| 本地 WebDAVS 自签 transport | `webdavs://127.0.0.1:9444/https.txt?allowBadCertificate=true` | 通过，输出内容和 SHA-256 同本地 HTTPS。 |
| 本地 FTPS 自签 | `ftps://flux:fluxpass@127.0.0.1:2121/readme.txt?allowBadCertificate=true` | 通过，输出 `ftps-sample\n`，`12` bytes，SHA-256 为 `f304ffd059e25791aa2be46be8d7191d3dfad846aa5addded1e232d4f5e44cc0`。 |
| 本地 IPFS gateway | `ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244/readme.txt?gateway=http%3A%2F%2F127.0.0.1%3A8769` | 通过，输出 `Hello IPFS`，`10` bytes，SHA-256 为 `206f158bef5fbaeddee314d74b90d9259c5e2abee372bbac8f3c6e65fbb0d87b`。 |
| 公网 FTPS 兼容性 | `ftps://demo:password@test.rebex.net/readme.txt` | 未通过，错误为 `Secure error: Secure error: received corrupt message of type InvalidContentType`；该公网源不作为通过标准，保留为兼容性观察项。 |

### macOS GUI

| 用例 | 结果 |
| --- | --- |
| 本地 `.app` 构建 | 通过，`target/release/bundle/macos/FluxDown.app` 生成。 |
| 启动和窗口 | 通过，`FluxDown` 前台窗口尺寸约 `1180x760`，bundle id `dev.fluxdown.desktop`，版本 `1.0.2`。 |
| UI 渲染 | 通过，截图确认中文下载列表、全部/排队中/下载中/已暂停/已完成/失败状态 tabs、设置入口和右下角新建按钮正常显示。 |
| Tauri command 回归 | 通过，桌面测试覆盖任务输出路径、HLS 输出路径、暂停/恢复边界、手动启动并发约束、并发 1-30 / 线程 1-32 / 重试 0-10 / 限速的设置边界、保存路径解析，`start_download` 单任务 HTTP/HLS/WebDAV/IPFS 真实下载，以及 `enqueue_download -> list_downloads -> run_queue -> list_downloads` 的 HTTP、HLS、WebDAV transport 和自定义 IPFS gateway 真实下载闭环。HTTP command 用例还覆盖 `task_output_path` 和 `remove_download`：删除任务会移出队列，但不会误删已下载文件；运行中任务被 `remove_download` 删除后，`run_queue` 正常收尾且任务不会复活。 |
| Tauri command HTTP 下载 | 通过，测试启动临时 HTTP fixture，隔离 `XDG_DATA_HOME` 队列路径，创建任务、运行队列并校验 `desktop-command.txt` 内容为 `fluxdown-desktop-command-e2e`。 |
| Tauri command 单任务启动 | 通过，测试启动临时 HTTP、HLS、WebDAV transport 和 IPFS gateway fixture，隔离 `XDG_DATA_HOME` 队列路径，创建任务后调用 `start_download`；HTTP/WebDAV/IPFS 校验任务直接进入 `finished`、`task_output_path` 指向真实文件且内容正确，HLS 校验最终产物名回写、`segments_written=2` 且内容与分片拼接结果一致。 |
| Tauri command HLS 下载 | 通过，测试启动临时 HLS playlist/segment fixture，隔离 `XDG_DATA_HOME` 队列路径，创建 `.m3u8` 任务、运行队列并校验最终产物名回写到任务列表，`task_output_path` 指向实际 `.ts`/`.mp4` 文件且内容与分片拼接结果一致。 |
| Tauri command WebDAV 下载 | 通过，测试将 `webdav://` 映射到临时 HTTP fixture，校验实际请求路径和输出 `desktop-webdav.txt` 内容。 |
| Tauri command IPFS gateway 下载 | 通过，测试将 `ipfs://...?...gateway=` 映射到临时 gateway fixture，校验实际请求 `/ipfs/<cid>/readme.txt` 和输出 `desktop-ipfs.txt` 内容。 |
| 纯 GUI 下载闭环 | 未完成。Computer Use/AppleScript 鼠标自动化会触发 macOS “允许 Codex 控制其他 App”权限弹窗；不能在未获用户明确授权时点击系统“允许”。尝试使用 `TAURI_WEBVIEW_AUTOMATION=true` 和 `tauri-driver 2.0.6` 替代系统辅助权限，但本机返回 `tauri-driver is not supported on this platform`。 |

### 清理状态

验证结束后已确认无 `http.server 8765`、`local_bt_tracker`、`transmission-daemon`、`fluxdown-desktop` 残留进程，`8765`、`6969`、`51413` 端口无监听。
