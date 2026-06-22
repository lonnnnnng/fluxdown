# 下载验证状态

截至 2026-06-23，FluxDown 已完成 macOS、Windows、Android、iOS 当前阶段的界面截图和验证记录，但还不能表述为“所有平台、所有协议、所有前台 GUI/App 路径都已完成真实下载验证”。Android 真机已经补过一轮正常 App 下载验证；macOS CLI 已补充可重复脚本化 HTTP/HLS/HLS BYTERANGE/FTP/FTPS/SFTP/SMB/Torrent/Magnet、本地 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet、公网 WebDAVS/FTP/SFTP/IPFS、本地自签 HTTPS/WebDAVS/FTPS 和自定义 IPFS gateway 真实下载验证；macOS GUI 已完成本地构建、启动、基础界面渲染、纯 GUI HTTP/HLS/Torrent/Magnet 新建任务下载闭环，Tauri command 级真实 HTTP/HLS/HLS BYTERANGE/WebDAV/FTP/FTPS/SFTP/SMB/IPFS/Torrent/Magnet 下载验证，以及 1.0.3 非 GUI 总验收复跑；iOS 已在 Flutter 3.41.9 / Xcode 16.2 上完成 analyze、Flutter 测试、framework build、simulator build、unsigned device build、artifact 校验、URL scheme 配置校验，并在 iOS simulator 中跑通 App 内 HTTP/fMP4 HLS/fMP4 BYTERANGE HLS 下载 smoke。Windows 已完成本机 release 构建、CLI HTTP 直连/队列真实下载、Tauri command HTTP 队列下载，以及真实 GUI 前台 HTTP 下载闭环；Linux 目前只有 CLI/GUI 构建产物和包文件存在性检查，尚未在 Linux 桌面环境完成真实 GUI 下载验证。按当前安排，本阶段保留已覆盖的 GUI/App 前台验证证据，剩余协议和平台差距继续通过后续专项验证收口。

本页用于区分两类容易混淆的结论：

- 构建、测试、CI 和 Release artifact 校验：确认代码能编译、测试能跑、产物存在且非空。
- 真实下载端到端验证：在目标平台安装或启动对应 CLI/GUI/App，添加下载任务，并确认文件真实写入完成。

macOS 桌面、macOS CLI 和 iOS 当前目标的短清单见 [Apple 目标验收清单](apple-verification.md)。

当前可以确认的是构建和自动化测试覆盖较多，Android 真机覆盖了一批真实下载场景，macOS CLI/GUI 覆盖了更多协议的下载闭环，Windows CLI/GUI 已完成 HTTP 最小闭环；但仍不能表述为“所有端、所有协议都下载验证通过”。

## 当前进度

截至 2026-06-23，远端 `main` 已包含本轮 macOS CLI、桌面 command、Windows 客户端和 README 截图收口提交；本轮继续补充 1.0.3 macOS/iOS 复验记录：

- `dc1ed64`：CLI `remove` 和桌面 `remove_download` 会先恢复异常残留的 `running` 任务，再移出队列，避免删除结果继续展示假下载中状态。
- `606eac2`：验证报告已记录上述删除入口修复、测试计数和 macOS 非 GUI 总验收结果。
- `3137027`：合并 Windows 端依赖/前端修复、Windows CLI/GUI 构建与下载验证，以及 Windows README 截图。

当前 macOS 阶段已完成非 GUI 验证收口：`cargo fmt --check`、严格 Clippy、core/CLI/desktop 测试、release CLI 真实协议 fixture、桌面 Tauri command fixture、macOS artifact 校验、许可证检查和 CI 手动触发策略检查均已通过。Windows 阶段已完成本机 release 构建、CLI HTTP 直连/队列、Tauri command HTTP 队列、GUI 前台 HTTP 下载和 SHA-256 落盘校验。后续重点是 Linux GUI、iPhone 真机/签名 IPA，以及 Windows/macOS 剩余 GUI 前台协议点击验证。

2026-06-23 复验发现并修复了 macOS 验证脚本顺序问题：`verify:macos-cli-release` 原本会在桌面 DMG 构建前执行完整 `verify:macos-artifacts`，导致 1.0.3 环境下缺少 `FluxDown_1.0.3_aarch64.dmg` 时失败；现在 release CLI 阶段改为 `verify:macos-cli-artifact`，只校验刚构建出的 CLI，完整 `.app`/DMG 校验仍在 `verify:macos-desktop-command` 生成桌面产物后执行。

2026-06-23 02:27 CST 复跑 `npm run verify:apple` 通过：覆盖 macOS CLI release 协议 fixture、macOS 桌面 Tauri command fixture、`.app`/DMG artifact、许可证、CI 手动触发策略、iOS framework、iOS simulator build、iOS unsigned device build 和移动端 URL scheme。随后复跑 `npm run verify:ios:integration`，当前没有 iOS 目标时按预期以 78 退出，且默认不会启动 simulator；需要真实 App 内下载 smoke 时，可手动启动 simulator、连接 iPhone，或显式设置 `FLUXDOWN_IOS_BOOT_SIMULATOR=1`。

2026-06-23 03:44 CST 复跑 `npm run verify:apple` 通过；同轮在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 复跑 `npm run verify:ios:integration` 通过。脚本改为 simulator 下构建隐藏自检 App、staged install 后用 `simctl launch --console` 收集结构化结果，避免 Flutter 覆盖安装偶发卡死。结果：`ios-http-local` 下载完成 `29` bytes；`ios-hls-local` 使用标准 fMP4 HLS fixture，输出 `ios-hls.mp4` 为 `4815` bytes，`outputHeadHex` 包含 `66747970`，状态 `finished`。

2026-06-23 04:11 CST 复跑 `npm run verify:ios:integration` 通过：脚本选中 iOS 18.3 simulator `FluxDownTemp2-iPhone16`，本地 fixture `http://127.0.0.1:51158`；`ios-http-local` 下载完成 `29` bytes，`ios-hls-local` 输出 `ios-hls.mp4` 为 `4815` bytes，文件头包含 `ftyp`。同轮 `npm run verify:ios:device-readiness` 返回 `78`，物理 iPhone `LMY 18.6.2 (00008030-001905801E50802E)` 仍是 Xcode Offline 状态，暂不能做 iPhone 真机部署验证。

2026-06-23 04:16 CST 复跑 `npm run verify:macos` 通过：覆盖基础 Rust/desktop 测试、release CLI HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet/队列控制真实 fixture、桌面 command FTPS/SFTP/SMB/Torrent/Magnet live fixture、`FluxDown.app`/`FluxDown_1.0.3_aarch64.dmg` artifact 校验、许可证检查和 CI 手动触发策略检查。

2026-06-23 04:25 CST 新增移动端 HLS BYTERANGE 支持并复验：Dart 下载器会解析 `#EXT-X-MAP` 的 `BYTERANGE` 和媒体分片 `#EXT-X-BYTERANGE`，对同一资源发起 HTTP Range 请求后按播放列表顺序输出 fMP4/MP4。`flutter analyze` 通过，`flutter test` 通过 35 个测试；`npm run verify:ios:integration` 新增 `ios-hls-byterange-local`，在 iOS 18.3 simulator 上输出 `ios-hls-byterange.mp4`，`4815` bytes，文件头包含 `ftyp`。

2026-06-23 04:38 CST 新增 macOS core/CLI/桌面 command 的 HLS BYTERANGE 支持并复验：Rust core 会解析 `#EXT-X-BYTERANGE`，对同一媒体资源发起 HTTP Range 请求，并支持省略 `@offset` 的连续 byte-range 分片。`cargo test -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop` 通过，当前 CLI 单元 1、CLI 集成 33、core 68、desktop 非 ignored 32 / ignored 7；严格 Clippy 通过；`npm run verify:macos-cli-http-hls` 和 `npm run verify:macos-cli-release-http-hls` 均通过，新增 HLS BYTERANGE 输出 SHA-256 为 `df20d9dcdbecbf0dce43b2148bbc312626f8a384660bbdaf33cbcb46e985886e`。

2026-06-23 04:50 CST 推送 `a7b2c67` 后复验 iOS：`npm run verify:ios:device-readiness` 返回 `78`，物理 iPhone `LMY 18.6.2 (00008030-001905801E50802E)` 仍为 Offline；`npm run verify:ios:integration` 在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 通过，HTTP 输出 `29` bytes，fMP4 HLS 与 fMP4 BYTERANGE HLS 均输出 `4815` bytes 且文件头包含 `ftyp`；`npm run verify:ios` 通过，覆盖 analyze、35 个 Flutter 测试、framework、simulator app、unsigned device app 和 URL scheme。

2026-06-23 04:56 CST 为 `scripts/verify-ios-integration.sh` 增加 iOS TS HLS 专项探针：默认 smoke 不启用该用例，保持 HTTP/fMP4 HLS/fMP4 BYTERANGE HLS 通过；显式设置 `FLUXDOWN_IOS_INCLUDE_TS_HLS=1` 时会生成视频+AAC 的 MPEG-TS HLS 并要求输出 MP4。当前 simulator 结果仍失败，`ios-hls-ts-local` 下载了 `15604` bytes 后在原生 remux 阶段返回 `AVFoundationErrorDomain -11838`，错误原因为 `The operation is not supported for this media.`。

## 分端结论

| 端 | 当前验证情况 | 是否完成真实下载 E2E |
| --- | --- | --- |
| 桌面 CLI | Rust 单元测试、CLI 集成测试、队列测试、本地 HTTP/HLS/HLS BYTERANGE/FTP/FTPS/SFTP/SMB/Torrent/Magnet、公网 WebDAVS/FTP/SFTP/IPFS、本地自签 HTTPS/WebDAVS/FTPS、自定义 IPFS gateway、限速、失败重试、暂停继续、运行中删除和并发排队均已验证；其中小体积 FTP/FTPS/SFTP/SMB/Torrent/Magnet 已补充可重复脚本化验证。 | 部分完成 |
| macOS GUI | 已完成 Tauri `.app` 构建、本地启动、窗口渲染、设置/任务操作 Tauri command 回归测试、纯 GUI HTTP/HLS/Torrent/Magnet 新建任务下载闭环，以及 Tauri command 级 HTTP/HLS/HLS BYTERANGE/WebDAV/FTP/FTPS/SFTP/SMB/IPFS/Torrent/Magnet 单任务真实下载和队列真实下载。纯 GUI 的 FTP/FTPS/SFTP/SMB/IPFS/WebDAV 点击验证按当前阶段安排暂缓，不作为本阶段阻塞。 | 部分完成 |
| Windows GUI | 已在 Windows 开发机完成本机 release 构建，生成 `target/release/fluxdown-desktop.exe`、MSI 和 NSIS installer；CLI release 二进制完成 HTTP 直连下载和队列下载，Tauri command 完成 HTTP 队列下载，真实 GUI 前台完成本地 HTTP 下载闭环，落盘 `1048576` bytes，SHA-256 与源文件一致。 | 部分完成 |
| Linux GUI | 已有 Linux GUI 可执行文件、`.deb`、`.rpm` artifact 检查。没有安装包后通过界面完成下载验证。 | 未完成 |
| Android App | 已在 Redmi Note 8 Pro 真机安装并通过正常 App 队列完成本地 HTTP/HTTPS/FTP/FTPS/SFTP/SMB/IPFS、小 HLS、小 torrent、小 magnet，以及 2026-06-14 媒体级 HLS、单文件 torrent、单文件 magnet、多文件 torrent 和多文件 magnet 选择下载验证。 | 部分完成 |
| iOS App | 已有 iOS simulator 截图；2026-06-23 在 Flutter 3.41.9 / Xcode 16.2 上通过 `flutter analyze`、`flutter test`、simulator build、unsigned device build、artifact 校验和 URL scheme 配置验证；同日通过 iOS simulator App 内 HTTP 与 fMP4 HLS 下载 smoke。缺少签名 IPA，也没有在 iPhone 真机中完成扫码、文件选择、分享/打开、HLS/Torrent/Magnet 等真机下载验证。 | 部分完成 |

## 分协议结论

| 协议/能力 | 当前验证情况 | 备注 |
| --- | --- | --- |
| HTTP/HTTPS | CLI 和核心层有本地下载验证；2026-06-18 macOS CLI 已验证直接下载、队列下载、限速、失败重试、暂停继续、运行中删除、并发排队，以及本地自签 HTTPS opt-in；macOS GUI 已通过真实界面点击完成 HTTP 新建任务、自动下载和文件落盘校验；2026-06-19 Windows CLI 已验证 HTTP 直连/队列下载，Windows GUI 已通过真实界面完成 HTTP 下载和 SHA-256 落盘校验。 | 证据最充分。 |
| WebDAV/WebDAVS | 核心层验证了 URL 到 HTTP/HTTPS 传输的映射；2026-06-18 macOS CLI 已验证公网 WebDAVS transport 和本地自签 WebDAVS transport，CLI/桌面 command 均有队列回归覆盖。 | 仍未覆盖完整 WebDAV 方法，例如 PROPFIND/目录遍历。 |
| m3u8/HLS | 核心层覆盖本地 HLS playlist、AES-128 分片、master playlist 首个变体和 TS BYTERANGE 分片；Android 真机和 macOS CLI 均已验证媒体级 HLS 可生成最终 `.mp4`，CLI 直连/队列、桌面 command 和 macOS 纯 GUI 均有本地 HLS fixture 回归；macOS CLI release 与桌面 command 已验证 HLS BYTERANGE 真实落盘；纯 GUI 真实媒体 HLS 输出 `index.mp4` 并通过 `ffprobe` 识别为 MP4 容器；iOS simulator 已通过 App 内 fMP4 HLS 和 fMP4 BYTERANGE HLS smoke，两个输出文件头均包含 `ftyp`。 | iOS 本地 TS HLS 转 MP4 仍受 AVFoundation 限制，需要 FFmpeg 或更完整 TS muxer；仍需要更多公网和边界 playlist 验证。 |
| FTP/FTPS | 2026-06-18 macOS CLI 已验证公网 FTP、本地 FTP 直连/队列和本地自签 FTPS 直连/队列下载闭环；macOS GUI command 层已验证本地 FTP 队列、单任务启动下载和本地自签 FTPS 队列下载闭环。 | Rebex 公网 FTPS 仍失败，错误为 `InvalidContentType`；本地可控 FTPS fixture 已通过。 |
| SFTP | 2026-06-18 macOS CLI 已验证公网 SFTP、本地 Docker SFTP 直连下载和队列下载；macOS GUI command 层已通过本地 Docker SFTP fixture 验证队列下载。 | 公网 Rebex 仍作为兼容性 smoke；可重复脚本已不依赖公网源。 |
| SMB | 2026-06-18 macOS CLI 已通过 Docker Samba fixture 验证直连下载和队列下载；macOS GUI command 层已通过同类 Samba fixture 验证队列下载。Android 真机也已验证过局域网 SMB 小文件下载。 | 仍未覆盖纯 GUI 点击下载闭环和 Linux 桌面真实运行；Windows GUI 当前只覆盖 HTTP 前台闭环。 |
| BitTorrent `.torrent` | Android 真机已验证本地小种子、媒体级单文件种子和多文件种子选择下载；macOS CLI 已验证单文件、多文件本地种子和按文件编号选择下载，包含真实文件名/目录名和 SHA-256，并通过 `scripts/verify-macos-cli-p2p.sh` 验证小 torrent 队列下载和多文件 torrent 单文件选择；macOS GUI command 层和纯 GUI 均已通过临时本地 tracker/seeder 验证小 torrent 下载、真实文件名回写和 SHA-256，Tauri command 层已补充多文件 torrent 单文件选择和真实落盘路径定位。 | Windows/Linux GUI 仍需要 torrent 前台真实下载验证；桌面前台 GUI metadata 文件列表交互本阶段跳过。 |
| Magnet | Android 真机已验证本地小磁力、媒体级单文件 magnet 和多文件 magnet 选择下载；macOS CLI 已验证本地 magnet metadata 获取、真实文件名、SHA-256 和按文件编号选择下载，并通过 `scripts/verify-macos-cli-p2p.sh` 验证小 magnet 单任务启动和多文件 magnet 单文件选择；macOS GUI command 层和纯 GUI 均已通过临时本地 tracker/seeder 验证小 magnet 下载、metadata 文件名回写和 SHA-256，Tauri command 层已补充多文件 magnet 单文件选择和真实落盘路径定位。 | Windows/Linux GUI 仍需要 magnet 前台真实下载验证；桌面前台 GUI metadata 文件列表交互本阶段跳过。 |
| ed2k | 核心层验证了 aMule `ed2k` CLI 移交路径。 | FluxDown 不掌控外部客户端的实际下载完成状态。 |
| IPFS | 2026-06-18 macOS CLI 已验证公网 IPFS 网关下载和本地自定义 gateway 下载，CLI/桌面 command 均有自定义 gateway 队列回归覆盖。 | 仍不运行本地 IPFS 节点。 |

## 当前准确表述

FluxDown 已经具备多端架构、构建产物、CI/Release artifact 校验、核心协议下载测试、Android 真机 App 下载验证、macOS CLI/GUI 本地协议真实下载验证，以及 Windows CLI/GUI HTTP 最小闭环验证，但尚未完成每个平台、每个协议、每种 GUI/App 前台路径的真实下载端到端验证。

在完成目标系统上的安装、启动、任务添加、下载完成和文件校验前，不应宣称对应端已经通过下载验证。

## 后续验证建议

1. 先建立可重复测试资源：本地 HTTP/WebDAV、FTP、SFTP、SMB 服务和小体积 HLS playlist。
2. 逐端验证最小闭环：Linux GUI、iPhone App、Windows/macOS 剩余 GUI 前台协议点击验证；后续在不影响本机使用时再补。
3. 每次验证记录：平台、版本、安装方式、下载源、输出路径、文件大小、校验和、失败日志。
4. 再补真实公网协议：torrent、magnet、IPFS、ed2k 外部客户端移交。
5. 发布前补齐自动化许可证扫描和随包许可证文本，当前人工清单见 [第三方许可证清单](third-party-licenses.md)。

## 2026-06-23 macOS CLI/GUI 与 iOS 验证记录

### 环境

- 平台：macOS 本机，仓库分支 `main`。
- 记录起点提交：`a7ad01e`；后续追加 iOS 验证脚本入口。
- 构建版本：`1.0.3`。
- Flutter：`3.41.9`。
- Xcode：`16.2`。
- 验证边界：本轮不启动前台 GUI，不构建签名 IPA，不宣称 iPhone 真机 App 内真实下载闭环完成；当前可用 iOS 目标是 simulator `FluxDownTemp2-iPhone16`，物理 iPhone `LMY` 仍为 Xcode Offline。`verify:ios:integration` 默认不会启动模拟器，只有显式设置 `FLUXDOWN_IOS_BOOT_SIMULATOR=1` 时才会通过 `simctl` 尝试后台启动可用 iPhone simulator。

### 结果

| 检查项 | 结果 |
| --- | --- |
| `npm run verify:apple` | 通过：串联 `npm run verify:macos` 和 `npm run verify:ios`，完成当前 macOS 桌面/CLI 与 iOS 构建产物的非前台总验收；不会启动前台桌面 GUI，也不会自动启动 iOS simulator。 |
| `npm run verify:ios` | 通过：该脚本汇总 `flutter --version`、`xcodebuild -version`、`mobile:analyze`、`mobile:test`、iOS framework build/artifact 校验、iOS simulator build/artifact 校验、无签名 device build/artifact 校验和移动端 URL scheme 校验；用于日常非前台 iOS 构建验证。 |
| `npm run verify:ios:integration` | 通过：在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 上生成本地 HTTP/fMP4 HLS/BYTERANGE HLS fixture，构建隐藏自检 App，staged install 后通过 `simctl launch --console` 收集结果；`ios-http-local` 输出 `29` bytes，`ios-hls-local` 和 `ios-hls-byterange-local` 均输出 `4815` bytes，`outputHeadHex` 包含 `66747970`。显式设置 `FLUXDOWN_IOS_INCLUDE_TS_HLS=1` 可额外启用 TS HLS 专项探针，当前用于复现 `AVFoundationErrorDomain -11838`。 |
| `npm run verify:macos` | 通过：覆盖 `cargo fmt --check`、严格 Clippy、core/CLI/desktop 测试、release CLI HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet/队列控制真实 fixture、CLI-only artifact 校验、desktop command FTPS/SFTP/SMB/Torrent/Magnet fixture、完整 macOS artifact 校验、许可证和 CI 手动触发策略检查；04:38 单独复跑 Rust 测试后当前计数为 core 68、CLI 单元 1、CLI 集成 33、desktop 非 ignored 32 / ignored 7。 |
| `npm run verify:macos-cli-artifact` | 通过：校验 `target/release/fluxdown` 存在且非空，大小 `14689536` bytes；`--version` 输出 `fluxdown 1.0.3`，`detect/support/doctor` 均通过。 |
| `npm run desktop:dmg` | 通过：生成 `target/release/bundle/macos/FluxDown.app` 和 `target/release/bundle/dmg/FluxDown_1.0.3_aarch64.dmg`；本轮 04:16 复验 DMG 大小 `8731864` bytes，`hdiutil verify` checksum 通过；`.app` ad-hoc 签名校验通过。 |
| macOS 验证脚本修复 | 已修复：`verify:macos-cli-release` 不再在 CLI 阶段要求桌面 DMG 存在，改为调用 `verify:macos-cli-artifact`；完整桌面 artifact 校验仍由 `verify:macos-desktop-command` 在 DMG 构建后执行。 |
| `flutter analyze` | 通过：`No issues found!`。 |
| `flutter test` | 通过：35 个移动端测试全部通过，覆盖协议识别、队列状态、并发、重试、限速、线程数、HTTP/WebDAV/IPFS/TS HLS/fMP4 HLS/fMP4 BYTERANGE HLS/FTP 下载和续传。 |
| `npm run mobile:ios:framework` + `npm run mobile:ios:framework:verify` | 通过：生成并校验 `apps/mobile/build/ios/framework/Debug/App.xcframework` 和 `apps/mobile/build/ios/framework/Debug/Flutter.xcframework`。 |
| `npm run mobile:ios:simulator` + `npm run mobile:ios:simulator:verify` | 通过：Xcode 构建 `build/ios/iphonesimulator/Runner.app` 成功，artifact 目录存在；目录大小约 `195M`。 |
| `npm run mobile:ios` + `npm run mobile:ios:verify` | 通过：无代码签名 device 构建 `build/ios/iphoneos/Runner.app` 成功，Flutter 输出大小 `34.6MB`，artifact 目录存在。 |
| `npm run verify:mobile-url-schemes` | 通过：Android 和 iOS 均声明 `ed2k` URL 查询能力。 |
| iOS integration test | 通过 simulator smoke：`ios-http-local`、`ios-hls-local` 和 `ios-hls-byterange-local` 均为 `finished`，HLS 使用 fMP4 fixture 产出真实 `.mp4`；iPhone 真机和 iOS TS HLS 转 MP4 仍留作后续专项验证。 |
| `npm run verify:ios:device-readiness` | 通过边界判定：该入口只读 `flutter devices --machine` 和 `xcrun xctrace list devices`；当前本机可见 iPhone `LMY 18.6.2 (00008030-001905801E50802E)` 但状态为 Offline，命令按预期以 `78` 退出，需解锁、信任 Mac、确认 Developer Mode 或 USB/无线连接后再跑真机下载验证。 |

## 2026-06-19 Windows CLI/GUI 验证记录

### 环境

- 平台：Windows 开发机，仓库分支 `main`。
- 构建版本：`1.0.2`。
- 构建产物：`target/release/fluxdown.exe`、`target/release/fluxdown-desktop.exe`、`target/release/bundle/msi/FluxDown_1.0.2_x64_en-US.msi`、`target/release/bundle/nsis/FluxDown_1.0.2_x64-setup.exe`。
- 队列隔离：GUI 验证使用临时 `XDG_DATA_HOME`，避免写入真实用户队列。

### 结果

| 检查项 | 结果 |
| --- | --- |
| Windows 桌面 release 构建 | 通过：`npm run desktop:build` 完成 TypeScript/Vite 构建、Rust release 编译、MSI 和 NSIS installer 打包。 |
| CLI HTTP 直连下载 | 通过：本机 `127.0.0.1` HTTP fixture，`target/release/fluxdown.exe download ... --sha256 ...` 输出 `49` bytes，SHA-256 `f6c3a0ba74df3cfcbcd498c84119df954868d8981cecc1ac86a013828106e6c7` 匹配。 |
| CLI HTTP 队列下载 | 通过：同一 fixture 经 `add -> run` 完成，输出 `49` bytes，SHA-256 同源文件。 |
| Tauri command HTTP 队列下载 | 通过：`cargo test -p fluxdown-desktop desktop_commands_download_http_task_through_queue` 运行 1 个测试，结果 `1 passed`。 |
| GUI 前台 HTTP 下载闭环 | 通过：启动真实 `fluxdown-desktop.exe` 窗口，通过前台界面点击新建任务，输入 `http://127.0.0.1:8766/gui-payload.bin`、保存目录和 SHA-256，任务显示 `已完成`，进度 `1.0 MB / 1.0 MB`；落盘 `gui-payload.bin` 大小 `1048576` bytes，SHA-256 `042d84d3772b8cc9080a8f388c428c11d88f8566e5a38fda322fc8ea33492cfc` 与源文件一致，队列 JSON 状态为 `finished`。 |
| 前端和安全校验 | 通过：`npm.cmd --workspace apps/desktop run lint`、`npm.cmd --workspace apps/desktop run build`、`npm.cmd audit`、`cargo fmt --check` 均通过。 |
| README 截图 | 通过：Windows 下载列表、新建任务、设置三张截图已保存到 `docs/artifacts/readme/windows/` 并加入 README。 |

## 2026-06-18 macOS CLI/GUI 验证记录

### 环境

- 平台：macOS 本机，仓库分支 `main`。
- 本轮非 GUI 总验收复验提交：`dc1ed64`。
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
| `cargo clippy -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop --all-targets -- -D warnings` | 通过：严格 Clippy 通过；覆盖既有队列/协议修复、URL 脱敏、CLI 错误包装、桌面展示改动、平台原生队列路径，以及本轮 CLI/桌面客户端 SHA-256 校验能力。 |
| `cargo test -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop` | 通过：CLI 单元 1、CLI 集成 33、core 67、desktop 31，desktop 另有 7 个需 live fixture 的 ignored 用例；覆盖直连下载 SHA-256 成功/失败、非法 hash 在 `--restart` 清理前失败、非法 hash 在 CLI `add` 和桌面 `enqueue_download` 时提前拒绝且不写入队列、队列任务 SHA-256 持久化和失败状态、macOS CLI 默认队列写入 `~/Library/Application Support/FluxDown/queue.json`、旧版 macOS Unix 队列读取和下次写入迁移、CLI `pause/resume/remove` 直接恢复异常残留的 running 任务，暂停和删除保留中断提示，继续清理旧中断提示、torrent 文件编号排序去重与队列持久化、多文件种子单选文件时 summary 指向真实 metadata 目录落盘路径、桌面 command 层 SHA-256 成功和 mismatch 失败、桌面 command 列表刷新、暂停按钮、删除入口和继续按钮恢复异常残留的 running 任务、桌面 command 首次 500 后自动重试成功、桌面 command 重新下载已完成任务会替换旧文件，以及桌面 command 运行中暂停/恢复后续传完成。 |
| `cargo test -p fluxdown-core task::tests::redacts -- --nocapture` | 通过：验证任务展示副本会隐藏 URL 用户名和密码，也会处理嵌套 gateway URL。 |
| `cargo test -p fluxdown-cli queue_commands_redact_url_credentials_from_json_output -- --nocapture` | 通过：验证 CLI `add/list` JSON 输出隐藏 `ftp://user:p%40ss@...` 凭据，同时队列文件仍保存原始链接用于真实下载。 |
| `cargo test -p fluxdown-core task::tests::redacts_credentials_from_magnet_tracker_urls_in_text -- --nocapture` + `cargo test -p fluxdown-cli --test download_command queue_commands_redact_magnet_tracker_credentials_from_json_output -- --nocapture` | 通过：验证错误文本和 CLI `add/list` JSON 输出会隐藏 magnet tracker 嵌套 URL 中的用户名和密码，队列文件仍保留原始 magnet 链接用于真实下载。 |
| `cargo test -p fluxdown-core store::tests:: -- --nocapture` | 通过：验证 `XDG_DATA_HOME` 显式覆盖、macOS 默认使用 `~/Library/Application Support/FluxDown/queue.json`，以及新路径缺失时读取旧版 `~/.local/share/fluxdown/queue.json` 并在写入时迁移。 |
| `cargo test -p fluxdown-core protocol::tests:: -- --nocapture` + `cargo test -p fluxdown-cli --test download_command -- --nocapture` | 通过：CLI `detect` 输出改为与队列 JSON 一致的稳定小写协议名，覆盖 HTTP/HTTPS/WebDAV/FTP/SFTP/SMB/IPFS/Torrent/Magnet/ed2k/m3u8/unknown。 |
| `cargo test -p fluxdown-core -- --nocapture` + `cargo test -p fluxdown-cli --test download_command -- --nocapture` + `cargo test -p fluxdown-desktop resolves_legacy_unsafe_file_name_inside_output_dir -- --nocapture` | 通过：下载文件名统一规范化为单文件名，覆盖用户自定义文件名、HTTP/HLS/FTP/SFTP/SMB 推断文件名、旧队列任务重跑候选路径、CLI 真实 HTTP 落盘和桌面 command 输出路径解析，避免 `../`、路径分隔符和跨平台非法字符写出保存目录。 |
| `cargo test -p fluxdown-core task::tests::validates_sha256_text_before_queueing_tasks -- --nocapture` + `cargo test -p fluxdown-cli --test download_command queue_add_rejects_invalid_sha256_without_writing_queue -- --nocapture` | 通过：共享 SHA-256 规则接受 `sha256:` 前缀和大小写输入，拒绝非法值；CLI `add --sha256 not-a-sha256` 会直接失败，且不会创建队列文件。 |
| `cargo test -p fluxdown-core task::tests::normalizes_expected_sha256_when_creating_task -- --nocapture` + `cargo test -p fluxdown-cli --test download_command -- --nocapture` | 通过：验证 `expected_sha256` 兼容旧队列 JSON、输入规范化为小写 64 位 hash、CLI `download --sha256` 成功时 summary 返回实际 hash、hash 不匹配时直连命令失败，非法 hash 不会在 `--restart` 时先删除旧文件，非法 hash 不会进入队列，队列任务校验失败时进入 `failed` 并记录 mismatch 错误。 |
| `cargo test -p fluxdown-desktop -- --nocapture` | 通过：desktop 非 ignored 用例 31 个通过，7 个 live fixture 用例保持 ignored；验证桌面新建任务可保存可选 SHA-256 和 torrent 文件编号，非法 SHA-256 会在 `enqueue_download` 阶段直接拒绝且不写入队列，队列下载成功时保留期望 hash，hash 不匹配时任务进入 `failed` 并记录 mismatch 错误；覆盖首次 HTTP 500 后按 `retry_attempts` 再次请求并下载成功；覆盖已完成任务通过 `restart_existing` 重新下载时删除旧文件、重新请求且不走 Range 续传；覆盖列表刷新会把异常残留的 running 任务恢复为 `paused` 并保留已下载进度，暂停按钮可直接保留为 `paused` 并展示中断提示，删除入口可先恢复中断态再移出队列，继续按钮可直接把这类任务恢复为 `queued`；覆盖运行中任务暂停为 `paused`、恢复为 `queued`、再次运行后通过 Range 续传完成并校验最终文件内容。 |
| `cargo test -p fluxdown-cli --test download_command queue_commands_use_macos_native_default_store_path -- --nocapture` | 通过：在隔离临时 `HOME` 且空 `XDG_DATA_HOME` 下执行真实 CLI `add/list`，队列写入 `home/Library/Application Support/FluxDown/queue.json`，且不会新建旧版 `home/.local/share/fluxdown/queue.json`。 |
| `cargo test -p fluxdown-cli --test download_command queue_commands_migrate_legacy_macos_store_on_next_write -- --nocapture` | 通过：先用真实 CLI 在旧版 `home/.local/share/fluxdown/queue.json` 写入任务，再用默认 macOS 环境执行 `list` 读取旧任务，随后执行默认 `add`，确认新旧任务一起写入 `home/Library/Application Support/FluxDown/queue.json`。 |
| `cargo test -p fluxdown-cli --test download_command queue_resume_recovers_stale_running_task_before_transition -- --nocapture` | 通过：构造异常残留的 running 队列任务后直接执行真实 CLI `resume`，确认无需先 `list`，任务会恢复为 `queued`，保留已下载进度并清理旧中断提示。 |
| `cargo test -p fluxdown-cli --test download_command queue_pause_recovers_stale_running_task_before_transition -- --nocapture` | 通过：构造异常残留的 running 队列任务后直接执行真实 CLI `pause`，确认无需先 `list`，任务会恢复为 `paused`，保留已下载进度并展示“任务中断，已暂停，可继续下载”。 |
| `cargo test -p fluxdown-cli --test download_command queue_remove_recovers_stale_running_task_before_removal -- --nocapture` | 通过：构造异常残留的 running 队列任务后直接执行真实 CLI `remove`，确认删除前会恢复为 `paused`，返回值保留已下载进度和中断提示，随后队列为空。 |
| `cargo test -p fluxdown-desktop desktop_pause_download_recovers_stale_running_task_before_transition -- --nocapture` | 通过：构造异常残留的 running 桌面队列任务后直接调用 `pause_download`，确认桌面暂停入口会恢复为 `paused`，保留进度并保留中断提示。 |
| `cargo test -p fluxdown-desktop desktop_remove_download_recovers_stale_running_task_before_removal -- --nocapture` | 通过：构造异常残留的 running 桌面队列任务后直接调用 `remove_download`，确认桌面删除入口会先恢复中断状态，再把任务移出队列。 |
| `npm --workspace apps/desktop run build` | 通过：桌面前端新建任务协议/后端状态预览、SHA-256 输入、属性弹框、任务错误和 toast 错误脱敏改动完成 TypeScript 编译和 Vite 构建。 |
| `npm run verify:licenses` | 通过：检查 Rust workspace、桌面运行时依赖和 Flutter 移动端运行时依赖均已列入第三方许可证清单，并确认 `libtorrent_flutter` GPL 风险提示仍保留。 |
| `npm run verify:macos` | 通过：已在提交 `dc1ed64` 复跑当前 macOS 非 GUI 总验收入口，串起 `cargo fmt --check`、严格 Clippy、core/CLI/desktop 测试、`npm run verify:macos-cli-release`、`npm run verify:macos-desktop-command`、`npm run verify:licenses` 和 `npm run verify:ci-config`。 |
| `npm run audit:release` | 已执行：代码覆盖类检查已通过，包括 CLI 直连下载、桌面 command 任务启动、前端进度轮询、协议模型、移动端队列和 CI 配置；iOS framework、simulator 和 unsigned device 产物均已存在。当前未进入发版/打包阶段，因此 Linux/Windows 本地产物和 Release staging manifest 仍不存在，审计结果为 `8 failed, 1 warning`，这些产物缺口不作为本阶段阻塞。 |
| `cargo clippy -p fluxdown-cli --all-targets -- -D warnings` | 通过：修复 release CLI 不支持 `--version` 的基础可用性问题后，CLI 专项 Clippy 通过。 |
| `cargo test -p fluxdown-cli` | 通过：CLI 单元 1、CLI 集成 33。 |
| `npm run verify:macos-cli-release` | 通过：一键重新构建 `target/release/fluxdown`，依次运行 release CLI 的 HTTP/HLS、FTP/FTPS、SFTP、SMB、Torrent/Magnet、队列控制真实下载脚本，并执行 `npm run verify:macos-cli-artifact` 校验 CLI 产物。 |
| `npm run verify:macos-cli-ftp-ftps` | 通过：脚本启动临时 FTP 和显式 TLS FTPS fixture，验证 CLI FTP/FTPS 直连下载和队列下载。 |
| `npm run verify:macos-cli-http-hls` | 通过：脚本启动临时 Range HTTP server，验证 CLI HTTP 直连/队列和 HLS 直连/队列/单任务启动。 |
| `npm run verify:macos-cli-release-http-hls` | 通过：复用 HTTP/HLS fixture，但强制使用 `target/release/fluxdown`，验证 release CLI 二进制的 HTTP 直连/队列、HLS 直连/队列/单任务启动和 SHA-256 落盘校验。 |
| `npm run verify:macos-cli-release-ftp-ftps` | 通过：强制使用 `target/release/fluxdown`，验证 release CLI 二进制的 FTP/FTPS 直连下载、队列下载和 SHA-256 落盘校验。 |
| `npm run verify:macos-cli-release-sftp` | 通过：强制使用 `target/release/fluxdown`，验证 release CLI 二进制的 SFTP 直连下载、队列下载和 SHA-256 落盘校验。 |
| `npm run verify:macos-cli-release-smb` | 通过：强制使用 `target/release/fluxdown`，验证 release CLI 二进制的 SMB 直连下载、队列下载和 SHA-256 落盘校验；脚本已改为等待真实 SMB 下载 readiness，避免 Samba TCP 已打开但协议未准备好时偶发 `Disconnected from server`。 |
| `npm run verify:macos-cli-release-p2p` | 通过：强制使用 `target/release/fluxdown`，验证 release CLI 二进制的 `.torrent add -> run -> list` 和 magnet `add -> start -> list`，任务名会回写为真实文件名且 SHA-256 匹配。 |
| `npm run verify:macos-cli-release-queue-controls` | 通过：强制使用 `target/release/fluxdown`，启动本地慢速 HTTP fixture，验证 release CLI 的运行中暂停/继续、运行中删除、失败重试、`start --restart` 重新下载替换旧文件、并发 1 串行和并发 2 并行，以及所有完成文件的 SHA-256 落盘校验。 |
| `scripts/verify-macos-cli-p2p.sh` | 通过：脚本创建临时小文件和双文件 torrent、生成 torrent/magnet、启动本地 tracker 和 Transmission seeder，验证 CLI `.torrent` 队列下载、magnet `start` 单任务下载，以及 `.torrent`/magnet 在直连 `download` 和队列 `add -> run` 路径下通过 `--torrent-file-index 0` 只下载选中文件且未选文件不写出非空内容。 |
| `npm run verify:macos-cli-sftp` | 通过：脚本启动临时 Docker SFTP 服务，等待 SSH banner 后验证 CLI SFTP 直连下载和队列下载。 |
| `npm run verify:macos-cli-smb` | 通过：脚本启动临时 Docker Samba 共享，验证 CLI SMB 直连下载和队列下载。 |
| `npm run verify:macos-desktop-ftps` | 通过：脚本启动临时显式 TLS FTPS fixture，运行桌面 command ignored 测试，验证 FTPS 队列下载、输出路径和 SHA-256。 |
| `npm run verify:macos-desktop-command` | 通过：一键运行 `cargo test -p fluxdown-desktop`、`npm run desktop:dmg`、桌面 command FTPS/SFTP/SMB/Torrent/Magnet fixture 和 `npm run verify:macos-artifacts`，全程不启动前台 GUI。 |
| `npm run verify:macos-desktop-p2p` | 通过：脚本创建临时小文件和双文件 torrent、生成 torrent/magnet、启动本地 tracker 和 Transmission seeder，只运行 4 个 P2P ignored 桌面 command 测试，覆盖 torrent 队列下载、magnet 单任务启动、多文件 torrent 单文件选择和多文件 magnet 单文件选择，避免误触发其他协议 fixture 用例。 |
| `npm run verify:macos-desktop-smb` | 通过：脚本启动临时 Docker Samba 共享，运行桌面 command ignored 测试，验证 SMB 队列下载、输出路径和 SHA-256。 |
| `npm run verify:macos-desktop-sftp` | 通过：脚本启动临时 Docker SFTP 服务，等待 SSH banner 后运行桌面 command ignored 测试，验证队列下载、输出路径和 SHA-256。 |
| `cargo build -p fluxdown-cli --release` | 通过，生成 `target/release/fluxdown`。 |
| `npm --workspace apps/desktop run build` | 通过。 |
| `npm run desktop:build` | 通过，生成 `target/release/bundle/macos/FluxDown.app`。 |
| `npm run desktop:dmg` | 通过，打包前会对 `FluxDown.app` 执行本地 ad-hoc bundle 签名并通过 `codesign --verify --deep --strict`，生成 `target/release/bundle/dmg/FluxDown_1.0.2_aarch64.dmg`，大小 `8728841` bytes。该签名只证明本地产物完整，不代表开发者证书签名或 notarization 已完成。 |
| `node scripts/verify-artifacts.mjs desktop-macos` | 通过，校验 `target/release/fluxdown-desktop`、`target/release/bundle/macos/FluxDown.app` 和 `target/release/bundle/dmg/FluxDown_1.0.2_aarch64.dmg` 均存在且非空。 |
| `npm run verify:macos-artifacts` | 通过：校验 release CLI 文件、桌面二进制、`.app` 目录、`Info.plist` 元数据、bundle 可执行文件、CLI `--version/detect/support/doctor`、`.app` ad-hoc 签名和 dmg checksum；校验脚本会在 `hdiutil verify` 前后清理当前 FluxDown DMG 的临时挂载并短重试，避免 `资源暂时不可用` 造成误报失败。 |
| Release 许可证随包文本 | 通过：本地 `release:stage` 和 GitHub Release assets 准备脚本会输出项目 `LICENSE` 与 `docs/third-party-licenses.md` 副本，`verify:release` 会检查本地 Release staging 中的许可证文件存在且非空。 |
| `target/release/fluxdown --version` | 通过，输出 `fluxdown 1.0.2`。 |
| `target/release/fluxdown doctor` | 通过；内建 HTTP/HTTPS/WebDAV/FTP/FTPS/Torrent/Magnet/m3u8/SFTP/SMB/IPFS 可执行；ed2k 为系统移交，当前 PATH 缺少可选 `ed2k` CLI。 |
| Release CLI smoke | 通过：`target/release/fluxdown detect 'https://example.com/file.zip'` 输出 `https`，`support` 返回可执行状态，`doctor` JSON 中 HTTP 为 executable；release 二进制还通过了 HTTP/HLS、FTP/FTPS、SFTP、SMB、Torrent/Magnet 脚本化真实下载闭环。 |

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
| 小体积 Torrent/Magnet 脚本化回归 | `scripts/verify-macos-cli-p2p.sh` 临时生成的 `fluxdown-cli-p2p-sample.txt`、`.torrent`、magnet、双文件 torrent 和双文件 magnet | 通过，`.torrent` 通过 `add -> run -> list` 队列路径完成，magnet 通过 `add -> start -> list` 单任务路径完成；两者均把任务名回写为真实 `fluxdown-cli-p2p-sample.txt`。双文件 torrent 和双文件 magnet 均在直连 `download` 和队列 `add -> run` 路径下通过 `--torrent-file-index 0` 只下载 `a-selected.bin`，输出 SHA-256 匹配，`display_name` 和 `output_path` 指向真实选中文件，`b-skipped.bin` 未写出非空内容。 |
| 限速 | `seg_00047.ts`，`--speed-limit-mbps 0.5` | 通过，4.7 MB 文件耗时约 10 秒。 |
| 重新下载 | `npm run verify:macos-cli-release-queue-controls` 的本地 restart fixture；CLI 集成 `queue_start_restart_replaces_existing_http_output`；桌面 command `restart_existing` fixture | 通过，release CLI 脚本确认同一个已完成任务执行 `start --restart` 会重新请求源文件、替换被改写的旧输出、最终 SHA-256 匹配，且服务端没有收到 `Range` 请求；CLI 集成和桌面 command 用例也覆盖同类重新下载行为。 |
| 失败重试 | 404 源，`--retry-attempts 2`；一次 500 后恢复的 HTTP 源默认不传 `--retry-attempts`；`npm run verify:macos-cli-release-queue-controls` 的本地 flaky fixture；桌面 command flaky HTTP fixture | 通过，显式重试 2 次时服务端看到 3 次请求，任务最终 `failed` 并记录 404 错误；默认不传重试参数时会自动重试 1 次并完成下载，显式 `--retry-attempts 0` 表示不重试；release CLI 脚本确认首次 500、重试后完成且 SHA-256 匹配；桌面 command 用例确认首次 500 后第二次请求成功并真实落盘。 |
| 暂停/继续 | `seg_00047.ts` 限速下载中暂停，再 `resume` 和 `run`；`npm run verify:macos-cli-release-queue-controls` 的本地慢速 HTTP fixture | 通过，暂停时 partial 文件约 0.9 MB，恢复后完成，SHA-256 与源文件一致；release CLI 脚本确认任务运行中可暂停为 `paused`、恢复为 `queued`，再次运行后完成并通过 SHA-256 校验。 |
| CLI 跨进程暂停/恢复 | 一个 CLI 进程执行 `run --speed-limit-mbps 0.05`，另一个 CLI 进程执行 `pause <id>`，随后 `resume <id>` 并再次 `run` | 通过，运行中任务先变为 `paused` 并保留 partial 文件和已下载进度；恢复后通过 HTTP Range 续传完成，最终文件内容匹配源数据；release CLI 队列控制脚本已覆盖同类跨进程路径。 |
| CLI 跨进程删除运行中任务 | 一个 CLI 进程执行 `run --speed-limit-mbps 0.05`，另一个 CLI 进程执行 `remove <id>` | 通过，`run` 成功退出，任务不会被下载协程重新写回队列，最终 `list` 为空；release CLI 队列控制脚本已覆盖同类跨进程路径。 |
| 并发排队 | 两个约 4.5 MB 文件，`--speed-limit-mbps 1`；`npm run verify:macos-cli-release-queue-controls` 的本地并发 fixture | 通过，并发 1 耗时约 9 秒且串行开始；并发 2 耗时约 5 秒且同时开始。CLI 默认不传 `--concurrency` 时按 1 串行执行；核心队列测试还验证了 3 个队列任务在并发 2 时最多只会同时启动 2 个；release CLI 脚本用服务端 active 计数确认并发 1 只保持 1 个下载请求，并发 2 可同时运行 2 个下载请求。 |
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
| UI 渲染 | 通过，截图确认中文下载列表、全部/排队中/下载中/已暂停/已完成/失败状态 tabs、设置入口和右下角新建按钮正常显示；新建任务弹框已通过构建验证具备协议/后端状态预览和 SHA-256 输入。 |
| 纯 GUI HTTP 下载闭环 | 通过，启动隔离 `XDG_DATA_HOME=/tmp/fluxdown-gui-e2e-current/xdg` 的 `.app`，使用本地 `http://127.0.0.1:63791/gui-e2e-current.txt`，通过真实界面点击右下角新建按钮、填写下载链接和保存路径 `/tmp/fluxdown-gui-e2e-current/downloads`、点击创建任务；队列显示 `gui-e2e-current.txt` 已完成，落盘文件 `32` bytes，SHA-256 `57c6b733535bb64389ec4264db3e54fea8519328f5c75dee84e4b812d2a7c26b` 与源文件一致，队列 JSON 状态为 `finished`。 |
| 纯 GUI HLS MP4 下载闭环 | 通过，使用 ffmpeg 生成真实媒体 HLS，启动隔离 `XDG_DATA_HOME=/tmp/fluxdown-gui-hls-mp4-e2e/xdg` 的 `.app`，通过界面输入 `http://127.0.0.1:63793/hls/index.m3u8` 和保存路径 `/tmp/fluxdown-gui-hls-mp4-e2e/downloads`；任务完成后输出 `index.mp4`，大小 `24996` bytes，SHA-256 `b84982ecc8ae75a13cb82c9d33445a1534a4162071b5c96d147c14e2d0f61652`，`ffprobe` 显示 `format_name=mov,mp4,m4a,3gp,3g2,mj2`、`duration=3.000000`。 |
| 纯 GUI Torrent 下载闭环 | 通过，常驻本地 tracker、Transmission seeder 和 HTTP torrent 文件服务，界面输入 `http://127.0.0.1:63804/fluxdown-gui-torrent-sample-two.torrent` 和保存路径 `/tmp/fluxdown-gui-p2p-e2e2/downloads`；任务完成后文件名从 `.torrent` 回写为真实 `fluxdown-gui-torrent-sample-two.txt`，落盘 `32` bytes，SHA-256 `bcc656966bcc3e468f1a0bdaad3635aa80f1dc0673eec34e633da68c2dc1a650` 与源文件一致。 |
| 纯 GUI Magnet 下载闭环 | 通过，复用同一个 tracker/seeder，界面输入本地 magnet 链接和保存路径 `/tmp/fluxdown-gui-p2p-e2e2/downloads-magnet`；metadata 获取后文件名回写为真实 `fluxdown-gui-torrent-sample-two.txt`，落盘 `32` bytes，SHA-256 `bcc656966bcc3e468f1a0bdaad3635aa80f1dc0673eec34e633da68c2dc1a650` 与源文件一致，队列 JSON 状态为 `finished`。 |
| Tauri command 回归 | 通过，桌面测试覆盖任务输出路径、HLS 输出路径、暂停/恢复边界、运行中暂停后恢复续传、失败后自动重试、已完成任务重新下载、手动启动并发约束、并发 1-30 / 线程 1-32 / 重试 0-10 / 限速的设置边界、保存路径解析、可选 SHA-256 校验，`start_download` 单任务 HTTP/HLS/WebDAV/FTP/IPFS/Magnet 真实下载，以及 `enqueue_download -> list_downloads -> run_queue -> list_downloads` 的 HTTP、HLS、WebDAV transport、FTP、SFTP、SMB、Torrent 和自定义 IPFS gateway 真实下载闭环。HTTP command 用例还覆盖 `task_output_path` 和 `remove_download`：删除任务会移出队列，但不会误删已下载文件；运行中任务被 `remove_download` 删除后，`run_queue` 正常收尾且任务不会复活；运行中任务被 `pause_download` 暂停后可 `resume_download` 回队列，并通过 Range 续传完成同一个本地文件；首次 HTTP 500 会按 `retry_attempts` 再次请求并落盘成功；已完成任务通过 `restart_existing` 重新下载会替换旧文件且不发送 Range 请求。 |
| Tauri command HTTP 下载 | 通过，测试启动临时 HTTP fixture，隔离 `XDG_DATA_HOME` 队列路径，创建任务、运行队列并校验 `desktop-command.txt` 内容为 `fluxdown-desktop-command-e2e`；同一用例验证桌面 command 可保存 `expected_sha256`，正确 hash 下载完成，错误 hash 会让任务进入 `failed` 并记录 mismatch 错误。 |
| Tauri command 单任务启动 | 通过，测试启动临时 HTTP、HLS、WebDAV transport 和 IPFS gateway fixture，隔离 `XDG_DATA_HOME` 队列路径，创建任务后调用 `start_download`；HTTP/WebDAV/IPFS 校验任务直接进入 `finished`、`task_output_path` 指向真实文件且内容正确，HLS 校验最终产物名回写、`segments_written=2` 且内容与分片拼接结果一致；`restart_existing=true` 校验已完成 HTTP 任务会重新请求源文件并替换旧输出。 |
| Tauri command HLS 下载 | 通过，测试启动临时 HLS playlist/segment fixture，隔离 `XDG_DATA_HOME` 队列路径，创建 `.m3u8` 任务、运行队列并校验最终产物名回写到任务列表，`task_output_path` 指向实际 `.ts`/`.mp4` 文件且内容与分片拼接结果一致。 |
| Tauri command WebDAV 下载 | 通过，测试将 `webdav://` 映射到临时 HTTP fixture，校验实际请求路径和输出 `desktop-webdav.txt` 内容。 |
| Tauri command FTP 下载 | 通过，测试启动最小 FTP fixture，覆盖 `USER/PASS` 登录、`SIZE`、`EPSV` 被动数据连接和 `RETR` 文件传输；队列运行输出 `desktop-ftp.txt`，单任务启动输出 `desktop-start-ftp.txt`，均完成真实落盘和内容校验。 |
| Tauri command FTPS 下载 | 通过，`npm run verify:macos-desktop-ftps` 启动临时显式 TLS FTPS fixture，创建队列任务并运行，输出 `desktop-ftps.txt`，SHA-256 为 `d6cb380c4e7c29040d313a7ca940d613a97dab978fd019f7bf78212bb5c1e804`。 |
| Tauri command SFTP 下载 | 通过，`npm run verify:macos-desktop-sftp` 启动临时 Docker SFTP 服务，创建队列任务并运行，输出 `desktop-sftp.txt`，SHA-256 为 `3ebbcf6008be2428d11747c8ab05b55b4518a591d96ec188d5aa9df76a5f3a0f`。 |
| Tauri command SMB 下载 | 通过，`npm run verify:macos-desktop-smb` 启动临时 Docker Samba 共享，创建队列任务并运行，输出 `desktop-smb.txt`，SHA-256 为 `9511a9c1777dcaaf7652c0b8090a9c71a8b1dbd8f11e520141afdcef244c1929`。 |
| Tauri command IPFS gateway 下载 | 通过，测试将 `ipfs://...?...gateway=` 映射到临时 gateway fixture，校验实际请求 `/ipfs/<cid>/readme.txt` 和输出 `desktop-ipfs.txt` 内容。 |
| Tauri command Torrent/Magnet 下载 | 通过，`npm run verify:macos-desktop-p2p` 创建临时 `fluxdown-p2p-sample.txt` 和双文件 torrent/magnet，生成 tracker 为 `127.0.0.1` 的 `.torrent` 和 magnet，启动本地 tracker 与 Transmission seeder；ignored 测试确认 `.torrent` 队列下载会把任务名从 `queued-sample.torrent` 回写为真实 `fluxdown-p2p-sample.txt`，magnet 单任务启动会把任务名从 `magnet-download` 回写为真实文件名，两者输出 SHA-256 均为 `112be889b60bcb800675ca97f2dfd42a2394f80c0176c11cbd4456cacf25faa7`；多文件 torrent 和多文件 magnet 均通过文件编号 `0` 只下载 `a-selected.bin`，任务卡片名回写为真实文件名，`task_output_path` 可在保存目录下递归定位真实落盘文件。 |
| 纯 GUI 其他协议下载闭环 | 本阶段暂缓。当前纯 GUI 点击已验证 HTTP、HLS、Torrent、Magnet；FTP、FTPS、SFTP、SMB、IPFS、WebDAV 仍停留在 Tauri command 或 CLI 层真实下载验证。为避免占用本机前台操作，剩余纯 GUI 点击验证先不继续执行，后续单独安排。 |
| 剩余前台 GUI 点击验证阶段 | 已按当前安排跳过。该阶段不是本轮阻塞项；后续如果恢复 GUI 验证，需要单独打开前台 App 并重新记录每个协议的点击、下载、落盘和 hash 证据。 |

### 清理状态

验证结束后已确认无 `http.server 63791/63793/63804/8765/63810`、`local_bt_tracker`、`transmission-daemon`、`fluxdown-desktop` 残留进程，`63791`、`63793`、`63804`、`63805`、`63806`、`63807`、`8765`、`63810`、`6969`、`51413` 端口无监听；CLI HTTP/HLS 和 FTP/FTPS 脚本使用临时随机端口并在退出时清理服务进程和临时目录，CLI 和桌面 P2P 脚本也会清理 tracker、Transmission 和临时目录，CLI/桌面 SFTP 与 SMB 脚本会清理临时容器和共享目录。
