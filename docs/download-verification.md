# 下载验证状态

截至 2026-06-18，FluxDown 还没有完成“每一端安装或启动后实际下载成功”的全端端到端验证；Android 真机已经补过一轮正常 App 下载验证，macOS CLI 已补充可重复脚本化 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet、本地 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet、公网 WebDAVS/FTP/SFTP/IPFS、本地自签 HTTPS/WebDAVS/FTPS 和自定义 IPFS gateway 真实下载验证，macOS GUI 已完成本地构建、启动、基础界面渲染、纯 GUI HTTP/HLS/Torrent/Magnet 新建任务下载闭环，以及 Tauri command 级真实 HTTP/HLS/WebDAV/FTP/FTPS/SFTP/SMB/IPFS/Torrent/Magnet 下载验证。按当前验证安排，剩余纯 GUI 协议点击验证暂缓，先转入非 GUI 的脚本化验证和文档收口。

本页用于区分两类容易混淆的结论：

- 构建、测试、CI 和 Release artifact 校验：确认代码能编译、测试能跑、产物存在且非空。
- 真实下载端到端验证：在目标平台安装或启动对应 CLI/GUI/App，添加下载任务，并确认文件真实写入完成。

当前可以确认的是构建和自动化测试覆盖较多，Android 真机覆盖了一批真实下载场景，macOS CLI 覆盖了更多协议的下载闭环；但仍不能表述为“所有端都下载验证通过”。

## 分端结论

| 端 | 当前验证情况 | 是否完成真实下载 E2E |
| --- | --- | --- |
| 桌面 CLI | Rust 单元测试、CLI 集成测试、队列测试、本地 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet、公网 WebDAVS/FTP/SFTP/IPFS、本地自签 HTTPS/WebDAVS/FTPS、自定义 IPFS gateway、限速、失败重试、暂停继续、运行中删除和并发排队均已验证；其中小体积 FTP/FTPS/SFTP/SMB/Torrent/Magnet 已补充可重复脚本化验证。 | 部分完成 |
| macOS GUI | 已完成 Tauri `.app` 构建、本地启动、窗口渲染、设置/任务操作 Tauri command 回归测试、纯 GUI HTTP/HLS/Torrent/Magnet 新建任务下载闭环，以及 Tauri command 级 HTTP/HLS/WebDAV/FTP/FTPS/SFTP/SMB/IPFS/Torrent/Magnet 单任务真实下载和队列真实下载。纯 GUI 的 FTP/FTPS/SFTP/SMB/IPFS/WebDAV 点击验证按当前阶段安排暂缓，不作为本阶段阻塞。 | 部分完成 |
| Windows GUI | 已有 CI/Docker 构建产物和 artifact 检查。没有在 Windows 上安装或运行 GUI 完成下载验证。 | 未完成 |
| Linux GUI | 已有 Linux GUI 可执行文件、`.deb`、`.rpm` artifact 检查。没有安装包后通过界面完成下载验证。 | 未完成 |
| Android App | 已在 Redmi Note 8 Pro 真机安装并通过正常 App 队列完成本地 HTTP/HTTPS/FTP/FTPS/SFTP/SMB/IPFS、小 HLS、小 torrent、小 magnet，以及 2026-06-14 媒体级 HLS、单文件 torrent、单文件 magnet、多文件 torrent 和多文件 magnet 选择下载验证。 | 部分完成 |
| iPhone App | 已有 simulator / unsigned device 编译产物检查。缺少签名 IPA，也没有在 iPhone 或模拟器中完成 App 内下载验证。 | 未完成 |

## 分协议结论

| 协议/能力 | 当前验证情况 | 备注 |
| --- | --- | --- |
| HTTP/HTTPS | CLI 和核心层有本地下载验证；2026-06-18 macOS CLI 已验证直接下载、队列下载、限速、失败重试、暂停继续、运行中删除、并发排队，以及本地自签 HTTPS opt-in；macOS GUI 已通过真实界面点击完成 HTTP 新建任务、自动下载和文件落盘校验。 | 证据最充分。 |
| WebDAV/WebDAVS | 核心层验证了 URL 到 HTTP/HTTPS 传输的映射；2026-06-18 macOS CLI 已验证公网 WebDAVS transport 和本地自签 WebDAVS transport，CLI/桌面 command 均有队列回归覆盖。 | 仍未覆盖完整 WebDAV 方法，例如 PROPFIND/目录遍历。 |
| m3u8/HLS | 核心层覆盖本地 HLS playlist、AES-128 分片和 master playlist 首个变体；Android 真机和 macOS CLI 均已验证媒体级 HLS 可生成最终 `.mp4`，CLI 直连/队列、桌面 command 和 macOS 纯 GUI 均有本地 HLS fixture 回归；纯 GUI 真实媒体 HLS 输出 `index.mp4` 并通过 `ffprobe` 识别为 MP4 容器。 | 仍需要更多公网和边界 playlist 验证。 |
| FTP/FTPS | 2026-06-18 macOS CLI 已验证公网 FTP、本地 FTP 直连/队列和本地自签 FTPS 直连/队列下载闭环；macOS GUI command 层已验证本地 FTP 队列、单任务启动下载和本地自签 FTPS 队列下载闭环。 | Rebex 公网 FTPS 仍失败，错误为 `InvalidContentType`；本地可控 FTPS fixture 已通过。 |
| SFTP | 2026-06-18 macOS CLI 已验证公网 SFTP、本地 Docker SFTP 直连下载和队列下载；macOS GUI command 层已通过本地 Docker SFTP fixture 验证队列下载。 | 公网 Rebex 仍作为兼容性 smoke；可重复脚本已不依赖公网源。 |
| SMB | 2026-06-18 macOS CLI 已通过 Docker Samba fixture 验证直连下载和队列下载；macOS GUI command 层已通过同类 Samba fixture 验证队列下载。Android 真机也已验证过局域网 SMB 小文件下载。 | 仍未覆盖纯 GUI 点击下载闭环和 Windows/Linux 桌面真实运行。 |
| BitTorrent `.torrent` | Android 真机已验证本地小种子、媒体级单文件种子和多文件种子选择下载；macOS CLI 已验证单文件和多文件本地种子真实下载、真实文件名/目录名和 SHA-256，并通过 `scripts/verify-macos-cli-p2p.sh` 验证小 torrent 队列下载；macOS GUI command 层和纯 GUI 均已通过临时本地 tracker/seeder 验证小 torrent 下载、真实文件名回写和 SHA-256。 | Windows/Linux GUI 仍需要真实下载验证。 |
| Magnet | Android 真机已验证本地小磁力、媒体级单文件 magnet 和多文件 magnet 选择下载；macOS CLI 已验证本地 magnet metadata 获取、真实文件名和 SHA-256，并通过 `scripts/verify-macos-cli-p2p.sh` 验证小 magnet 单任务启动；macOS GUI command 层和纯 GUI 均已通过临时本地 tracker/seeder 验证小 magnet 下载、metadata 文件名回写和 SHA-256。 | Windows/Linux GUI 仍需要真实下载验证。 |
| ed2k | 核心层验证了 aMule `ed2k` CLI 移交路径。 | FluxDown 不掌控外部客户端的实际下载完成状态。 |
| IPFS | 2026-06-18 macOS CLI 已验证公网 IPFS 网关下载和本地自定义 gateway 下载，CLI/桌面 command 均有自定义 gateway 队列回归覆盖。 | 仍不运行本地 IPFS 节点。 |

## 当前准确表述

FluxDown 已经具备多端架构、构建产物、CI/Release artifact 校验、核心协议下载测试、Android 真机 App 下载验证和 macOS CLI 本地协议真实下载验证，但尚未完成每个平台 CLI/GUI/App 安装或启动后的真实下载端到端验证。

在完成目标系统上的安装、启动、任务添加、下载完成和文件校验前，不应宣称对应端已经通过下载验证。

## 后续验证建议

1. 先建立可重复测试资源：本地 HTTP/WebDAV、FTP、SFTP、SMB 服务和小体积 HLS playlist。
2. 逐端验证最小闭环：CLI、Linux GUI、Windows GUI、Android App、iPhone App；macOS 剩余纯 GUI 协议点击验证当前阶段暂缓，后续在不影响本机使用时再补。
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

剩余纯 GUI 协议点击验证暂缓后，本阶段继续执行以下非 GUI 检查，覆盖 CLI 真实下载和桌面端 Tauri command 下载闭环。

| 检查项 | 结果 |
| --- | --- |
| `cargo fmt --check` | 通过：Rust 代码格式已校验。 |
| `cargo clippy -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop --all-targets -- -D warnings` | 通过：已修复 HTTP Range/FTP 内部参数结构、队列进度暂停判断、路径参数类型、HLS 辅助函数位置、ed2k 测试 PATH 锁和桌面端嵌套判断等 Clippy 门禁问题。 |
| `cargo test -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop` | 通过：CLI 单元 1、CLI 集成 19、core 48、desktop 20。 |
| `cargo clippy -p fluxdown-cli --all-targets -- -D warnings` | 通过：修复 release CLI 不支持 `--version` 的基础可用性问题后，CLI 专项 Clippy 通过。 |
| `cargo test -p fluxdown-cli` | 通过：CLI 单元 1、CLI 集成 19。 |
| `npm run verify:macos-cli-ftp-ftps` | 通过：脚本启动临时 FTP 和显式 TLS FTPS fixture，验证 CLI FTP/FTPS 直连下载和队列下载。 |
| `npm run verify:macos-cli-http-hls` | 通过：脚本启动临时 Range HTTP server，验证 CLI HTTP 直连/队列和 HLS 直连/队列/单任务启动。 |
| `scripts/verify-macos-cli-p2p.sh` | 通过：脚本创建临时小文件、生成 torrent/magnet、启动本地 tracker 和 Transmission seeder，验证 CLI `.torrent` 队列下载和 magnet `start` 单任务下载。 |
| `npm run verify:macos-cli-sftp` | 通过：脚本启动临时 Docker SFTP 服务，等待 SSH banner 后验证 CLI SFTP 直连下载和队列下载。 |
| `npm run verify:macos-cli-smb` | 通过：脚本启动临时 Docker Samba 共享，验证 CLI SMB 直连下载和队列下载。 |
| `npm run verify:macos-desktop-ftps` | 通过：脚本启动临时显式 TLS FTPS fixture，运行桌面 command ignored 测试，验证 FTPS 队列下载、输出路径和 SHA-256。 |
| `npm run verify:macos-desktop-p2p` | 通过：脚本创建临时小文件、生成 torrent/magnet、启动本地 tracker 和 Transmission seeder，只运行 2 个 P2P ignored 桌面 command 测试，避免误触发其他协议 fixture 用例。 |
| `npm run verify:macos-desktop-smb` | 通过：脚本启动临时 Docker Samba 共享，运行桌面 command ignored 测试，验证 SMB 队列下载、输出路径和 SHA-256。 |
| `npm run verify:macos-desktop-sftp` | 通过：脚本启动临时 Docker SFTP 服务，等待 SSH banner 后运行桌面 command ignored 测试，验证队列下载、输出路径和 SHA-256。 |
| `cargo build -p fluxdown-cli --release` | 通过，生成 `target/release/fluxdown`。 |
| `npm --workspace apps/desktop run build` | 通过。 |
| `npm run desktop:build` | 通过，生成 `target/release/bundle/macos/FluxDown.app`。 |
| `npm run desktop:dmg` | 通过，生成 `target/release/bundle/dmg/FluxDown_1.0.2_aarch64.dmg`，大小 `8679773` bytes。 |
| `node scripts/verify-artifacts.mjs desktop-macos` | 通过，校验 `target/release/fluxdown-desktop`、`target/release/bundle/macos/FluxDown.app` 和 `target/release/bundle/dmg/FluxDown_1.0.2_aarch64.dmg` 均存在且非空。 |
| `target/release/fluxdown --version` | 通过，输出 `fluxdown 1.0.2`。 |
| `target/release/fluxdown doctor` | 通过；内建 HTTP/HTTPS/WebDAV/FTP/FTPS/Torrent/Magnet/m3u8/SFTP/SMB/IPFS 可执行；ed2k 为系统移交，当前 PATH 缺少可选 `ed2k` CLI。 |
| Release CLI smoke | 通过：`target/release/fluxdown detect 'https://example.com/file.zip'` 输出 `Https`，`support` 返回可执行状态，`doctor` JSON 中 HTTP 为 executable。 |

### CLI 真实下载

| 用例 | 下载源 | 结果 |
| --- | --- | --- |
| HTTP 直接下载 | `http://127.0.0.1:8765/multi/20260614_bundle/readme.txt` | 通过，输出 `readme.txt`，SHA-256 为 `4b75951c517de7955172428fa7030caa7ad837580bcee33095208491031eaf93`。 |
| HTTP 多线程直连下载 | 本地支持 `HEAD` 和 `Range` 的 HTTP fixture，`download --threads 4` | 通过，CLI 层触发多个 HTTP Range 请求，输出文件内容与源 payload 完全一致。 |
| HTTP 队列下载 | 同上，通过 `add`、`list`、`run --concurrency 1 --threads 4` | 通过，任务 `queued -> finished`，`total_bytes=43`，输出 hash 一致。 |
| HTTP 脚本化回归 | `npm run verify:macos-cli-http-hls` 临时生成的 `range.bin` | 通过，直连 `download --threads 4` 和 `add -> run -> list --threads 4` 队列路径均完成，输出 SHA-256 为 `31a1f9dea0169551092d05e8bf4a446228c8c3eb4c9b713c66adcb7fd53c89be`。 |
| HLS 媒体下载 | `http://127.0.0.1:8765/hls/index.m3u8`；本地两分片 HLS fixture，`fluxdown download --name cli-hls.m3u8`、`add -> run -> list` 队列路径和 `add -> start -> list` 单任务路径 | 媒体级手动验证通过，232 个分片输出 `index.mp4`，大小 `388653222` bytes；`ffprobe` 可识别为 `mov,mp4,m4a,3gp,3g2,mj2`，duration `1514.481333`。CLI 集成回归通过，确认 `.m3u8` 任务输出最终 `.ts` 产物、JSON summary 包含 `segments_written=2`、队列和单任务启动都会把最终文件名回写为 `.ts`，文件内容等于两个分片拼接结果。 |
| HLS 脚本化回归 | `npm run verify:macos-cli-http-hls` 临时生成的两分片 playlist | 通过，直连 `download`、`add -> run -> list` 队列路径和 `add -> start -> list` 单任务路径均完成，`segments_written=2`，任务名从 `.m3u8` 回写为 `.ts`，输出 SHA-256 为 `e7549c4e2515ab3407a659e9ba66778d7c846d779f0026c36d62ec58b3f5b01e`。 |
| 单文件 Torrent | `../local_protocol_resources/torrent/20260614.torrent` | 通过，metadata 后输出真实文件名 `20260614.mp4`，SHA-256 为 `4df2d9155b5714274f91beda0029041d9ef880f2996172adfd5bc5e29db42650`。 |
| 单文件 Magnet | `../local_protocol_resources/torrent/20260614.magnet.txt` 中的 magnet | 通过，metadata 后输出真实文件名 `20260614.mp4`，SHA-256 同源文件。 |
| 多文件 Torrent | `../local_protocol_resources/multi_torrent/20260614_bundle.torrent` | 通过，输出真实目录 `20260614_bundle`，内部 `20260614.mp4` 和 `readme.txt` 的 SHA-256 均与源文件一致。 |
| 小体积 Torrent/Magnet 脚本化回归 | `scripts/verify-macos-cli-p2p.sh` 临时生成的 `fluxdown-cli-p2p-sample.txt`、`.torrent` 和 magnet | 通过，`.torrent` 通过 `add -> run -> list` 队列路径完成，magnet 通过 `add -> start -> list` 单任务路径完成；两者均把任务名回写为真实 `fluxdown-cli-p2p-sample.txt`，输出 SHA-256 为 `a40673900248536479693b16710628925f18643bf01b20208da668b9ad101b24`。 |
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
| 本地 FTP | `npm run verify:macos-cli-ftp-ftps` 临时启动的 FTP fixture | 通过，CLI `download` 直连路径和 `add -> run -> list` 队列路径均完成，输出 `24` bytes，SHA-256 为 `8a3e04ea4d1a0fe96d6f591601719d0c95ed965ded0dfad65e8304b2aba0c946`。 |
| 本地 FTPS 自签 | `npm run verify:macos-cli-ftp-ftps` 临时启动的显式 TLS FTPS fixture，URL 带 `allowBadCertificate=true` | 通过，CLI `download` 直连路径和 `add -> run -> list` 队列路径均完成，输出 `25` bytes，SHA-256 为 `2e67c9cda58b774fc2fcd7ad641f9b4aec2b89214689e4d604d5274985610a2b`。 |
| 本地 SFTP | `npm run verify:macos-cli-sftp` 临时启动的 Docker SFTP 服务 | 通过，CLI `download` 直连路径和 `add -> run -> list` 队列路径均完成，输出 `25` bytes，SHA-256 为 `cacf85d1bd51f37a2495d0ab4efa648c88a33bb8b23b95d2570db2a7887ba4a2`。 |
| 本地 IPFS gateway | `ipfs://bafkreidfdrlkeq4m4xnxuyx6iae76fdm4wgl5d4xzsb77ixhyqwumhz244/readme.txt?gateway=http%3A%2F%2F127.0.0.1%3A8769` | 通过，输出 `Hello IPFS`，`10` bytes，SHA-256 为 `206f158bef5fbaeddee314d74b90d9259c5e2abee372bbac8f3c6e65fbb0d87b`。 |
| 本地 SMB | `npm run verify:macos-cli-smb` 临时启动的 Docker Samba 共享 | 通过，CLI `download` 直连路径和 `add -> run -> list` 队列路径均完成，输出 `24` bytes，SHA-256 为 `51cf86999e8a6da6ad6f341936ce75097ea6dd7adbddeab105b7241b88914ca4`。 |
| 公网 FTPS 兼容性 | `ftps://demo:password@test.rebex.net/readme.txt` | 未通过，错误为 `Secure error: Secure error: received corrupt message of type InvalidContentType`；该公网源不作为通过标准，保留为兼容性观察项。 |

### macOS GUI

| 用例 | 结果 |
| --- | --- |
| 本地 `.app` 构建 | 通过，`target/release/bundle/macos/FluxDown.app` 生成。 |
| 启动和窗口 | 通过，`FluxDown` 前台窗口尺寸约 `1180x760`，bundle id `dev.fluxdown.desktop`，版本 `1.0.2`。 |
| UI 渲染 | 通过，截图确认中文下载列表、全部/排队中/下载中/已暂停/已完成/失败状态 tabs、设置入口和右下角新建按钮正常显示。 |
| 纯 GUI HTTP 下载闭环 | 通过，启动隔离 `XDG_DATA_HOME=/tmp/fluxdown-gui-e2e-current/xdg` 的 `.app`，使用本地 `http://127.0.0.1:63791/gui-e2e-current.txt`，通过真实界面点击右下角新建按钮、填写下载链接和保存路径 `/tmp/fluxdown-gui-e2e-current/downloads`、点击创建任务；队列显示 `gui-e2e-current.txt` 已完成，落盘文件 `32` bytes，SHA-256 `57c6b733535bb64389ec4264db3e54fea8519328f5c75dee84e4b812d2a7c26b` 与源文件一致，队列 JSON 状态为 `finished`。 |
| 纯 GUI HLS MP4 下载闭环 | 通过，使用 ffmpeg 生成真实媒体 HLS，启动隔离 `XDG_DATA_HOME=/tmp/fluxdown-gui-hls-mp4-e2e/xdg` 的 `.app`，通过界面输入 `http://127.0.0.1:63793/hls/index.m3u8` 和保存路径 `/tmp/fluxdown-gui-hls-mp4-e2e/downloads`；任务完成后输出 `index.mp4`，大小 `24996` bytes，SHA-256 `b84982ecc8ae75a13cb82c9d33445a1534a4162071b5c96d147c14e2d0f61652`，`ffprobe` 显示 `format_name=mov,mp4,m4a,3gp,3g2,mj2`、`duration=3.000000`。 |
| 纯 GUI Torrent 下载闭环 | 通过，常驻本地 tracker、Transmission seeder 和 HTTP torrent 文件服务，界面输入 `http://127.0.0.1:63804/fluxdown-gui-torrent-sample-two.torrent` 和保存路径 `/tmp/fluxdown-gui-p2p-e2e2/downloads`；任务完成后文件名从 `.torrent` 回写为真实 `fluxdown-gui-torrent-sample-two.txt`，落盘 `32` bytes，SHA-256 `bcc656966bcc3e468f1a0bdaad3635aa80f1dc0673eec34e633da68c2dc1a650` 与源文件一致。 |
| 纯 GUI Magnet 下载闭环 | 通过，复用同一个 tracker/seeder，界面输入本地 magnet 链接和保存路径 `/tmp/fluxdown-gui-p2p-e2e2/downloads-magnet`；metadata 获取后文件名回写为真实 `fluxdown-gui-torrent-sample-two.txt`，落盘 `32` bytes，SHA-256 `bcc656966bcc3e468f1a0bdaad3635aa80f1dc0673eec34e633da68c2dc1a650` 与源文件一致，队列 JSON 状态为 `finished`。 |
| Tauri command 回归 | 通过，桌面测试覆盖任务输出路径、HLS 输出路径、暂停/恢复边界、手动启动并发约束、并发 1-30 / 线程 1-32 / 重试 0-10 / 限速的设置边界、保存路径解析，`start_download` 单任务 HTTP/HLS/WebDAV/FTP/IPFS/Magnet 真实下载，以及 `enqueue_download -> list_downloads -> run_queue -> list_downloads` 的 HTTP、HLS、WebDAV transport、FTP、SFTP、SMB、Torrent 和自定义 IPFS gateway 真实下载闭环。HTTP command 用例还覆盖 `task_output_path` 和 `remove_download`：删除任务会移出队列，但不会误删已下载文件；运行中任务被 `remove_download` 删除后，`run_queue` 正常收尾且任务不会复活。 |
| Tauri command HTTP 下载 | 通过，测试启动临时 HTTP fixture，隔离 `XDG_DATA_HOME` 队列路径，创建任务、运行队列并校验 `desktop-command.txt` 内容为 `fluxdown-desktop-command-e2e`。 |
| Tauri command 单任务启动 | 通过，测试启动临时 HTTP、HLS、WebDAV transport 和 IPFS gateway fixture，隔离 `XDG_DATA_HOME` 队列路径，创建任务后调用 `start_download`；HTTP/WebDAV/IPFS 校验任务直接进入 `finished`、`task_output_path` 指向真实文件且内容正确，HLS 校验最终产物名回写、`segments_written=2` 且内容与分片拼接结果一致。 |
| Tauri command HLS 下载 | 通过，测试启动临时 HLS playlist/segment fixture，隔离 `XDG_DATA_HOME` 队列路径，创建 `.m3u8` 任务、运行队列并校验最终产物名回写到任务列表，`task_output_path` 指向实际 `.ts`/`.mp4` 文件且内容与分片拼接结果一致。 |
| Tauri command WebDAV 下载 | 通过，测试将 `webdav://` 映射到临时 HTTP fixture，校验实际请求路径和输出 `desktop-webdav.txt` 内容。 |
| Tauri command FTP 下载 | 通过，测试启动最小 FTP fixture，覆盖 `USER/PASS` 登录、`SIZE`、`EPSV` 被动数据连接和 `RETR` 文件传输；队列运行输出 `desktop-ftp.txt`，单任务启动输出 `desktop-start-ftp.txt`，均完成真实落盘和内容校验。 |
| Tauri command FTPS 下载 | 通过，`npm run verify:macos-desktop-ftps` 启动临时显式 TLS FTPS fixture，创建队列任务并运行，输出 `desktop-ftps.txt`，SHA-256 为 `d6cb380c4e7c29040d313a7ca940d613a97dab978fd019f7bf78212bb5c1e804`。 |
| Tauri command SFTP 下载 | 通过，`npm run verify:macos-desktop-sftp` 启动临时 Docker SFTP 服务，创建队列任务并运行，输出 `desktop-sftp.txt`，SHA-256 为 `3ebbcf6008be2428d11747c8ab05b55b4518a591d96ec188d5aa9df76a5f3a0f`。 |
| Tauri command SMB 下载 | 通过，`npm run verify:macos-desktop-smb` 启动临时 Docker Samba 共享，创建队列任务并运行，输出 `desktop-smb.txt`，SHA-256 为 `9511a9c1777dcaaf7652c0b8090a9c71a8b1dbd8f11e520141afdcef244c1929`。 |
| Tauri command IPFS gateway 下载 | 通过，测试将 `ipfs://...?...gateway=` 映射到临时 gateway fixture，校验实际请求 `/ipfs/<cid>/readme.txt` 和输出 `desktop-ipfs.txt` 内容。 |
| Tauri command Torrent/Magnet 下载 | 通过，`npm run verify:macos-desktop-p2p` 创建临时 `fluxdown-p2p-sample.txt`，生成 tracker 为 `127.0.0.1` 的 `.torrent` 和 magnet，启动本地 tracker 与 Transmission seeder；ignored 测试确认 `.torrent` 队列下载会把任务名从 `queued-sample.torrent` 回写为真实 `fluxdown-p2p-sample.txt`，magnet 单任务启动会把任务名从 `magnet-download` 回写为真实文件名，两者输出 SHA-256 均为 `112be889b60bcb800675ca97f2dfd42a2394f80c0176c11cbd4456cacf25faa7`。 |
| 纯 GUI 其他协议下载闭环 | 本阶段暂缓。当前纯 GUI 点击已验证 HTTP、HLS、Torrent、Magnet；FTP、FTPS、SFTP、SMB、IPFS、WebDAV 仍停留在 Tauri command 或 CLI 层真实下载验证。为避免占用本机前台操作，剩余纯 GUI 点击验证先不继续执行，后续单独安排。 |

### 清理状态

验证结束后已确认无 `http.server 63791/63793/63804/8765/63810`、`local_bt_tracker`、`transmission-daemon`、`fluxdown-desktop` 残留进程，`63791`、`63793`、`63804`、`63805`、`63806`、`63807`、`8765`、`63810`、`6969`、`51413` 端口无监听；CLI HTTP/HLS 和 FTP/FTPS 脚本使用临时随机端口并在退出时清理服务进程和临时目录，CLI 和桌面 P2P 脚本也会清理 tracker、Transmission 和临时目录，CLI/桌面 SFTP 与 SMB 脚本会清理临时容器和共享目录。
