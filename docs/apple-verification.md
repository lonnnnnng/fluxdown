# Apple 目标验收清单

本文档只跟踪当前目标范围：macOS 桌面端、macOS CLI 端和 iOS 端。它不替代完整下载验证报告，只用于快速判断当前目标哪些证据已经落地，哪些还需要前台设备或签名条件。

## 当前结论

| 目标项 | 当前状态 | 已有证据 | 剩余缺口 |
| --- | --- | --- | --- |
| macOS CLI | 非前台验收已通过 | `npm run verify:apple` 已串联 `npm run verify:macos`；release CLI 覆盖 HTTP/HLS、HLS BYTERANGE、FTP/FTPS、SFTP、SMB、Torrent/Magnet、队列控制和 artifact 校验。 | 真实公网边界资源仍可继续扩展，但当前本地可重复 fixture 已覆盖主要协议闭环。 |
| macOS 桌面端 | 非前台 command/artifact 验收已通过，既有前台 GUI 最小闭环已记录 | `npm run verify:apple` 已串联桌面 Tauri command fixture、`.app`/DMG 构建、ad-hoc 签名和 checksum；桌面 command 已覆盖 HLS BYTERANGE；历史前台 GUI 已覆盖 HTTP、HLS、Torrent、Magnet。 | 纯 GUI 前台的 FTP/FTPS、SFTP、SMB、IPFS、WebDAV 点击下载闭环仍按当前阶段暂缓。 |
| iOS 构建与静态验证 | 已通过 | `npm run verify:apple` 已串联 `flutter analyze`、`flutter test`、iOS framework build、simulator build、unsigned device build、artifact 校验和 URL scheme 校验。 | 签名 IPA 需要 Apple 证书和 provisioning profile。 |
| iOS App 内下载 | simulator smoke 已通过 | `npm run verify:ios:integration` 已在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 上完成 App 内 HTTP、fMP4 HLS 和 fMP4 BYTERANGE HLS 下载；显式设置 `FLUXDOWN_IOS_INCLUDE_TS_HLS=1` 后，TS HLS 也已通过同一 simulator 下载并输出 MP4。HTTP 输出 `29` bytes，fMP4 HLS 输出 `4815` bytes，TS HLS 输出 `19884` bytes，文件头均符合预期。脚本默认不自动启动模拟器，显式设置 `FLUXDOWN_IOS_BOOT_SIMULATOR=1` 时才会尝试通过 `simctl` 启动可用 iPhone simulator。 | iPhone 真机、签名 IPA、扫码/文件选择/分享打开等真机能力仍待证书和设备窗口补验；TS HLS 当前先覆盖 H.264/AAC VOD 主流路径，仍需更多公网和编码边界验证。 |

## 本轮复验记录

2026-06-23 02:27 CST 已复跑 `npm run verify:apple`，macOS CLI、macOS 桌面 command/artifact、iOS framework、iOS simulator build、iOS unsigned device build 和 URL scheme 校验均通过。随后复跑 `npm run verify:ios:integration`，在没有 iOS 目标时按预期以 78 退出，且没有启动 simulator。

2026-06-23 03:44 CST 复跑 `npm run verify:apple` 通过：macOS CLI release 多协议 fixture、macOS 桌面 command/artifact、许可证、CI 手动触发策略、iOS framework、iOS simulator build、iOS unsigned device build 和 URL scheme 均通过。随后在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 复跑 `npm run verify:ios:integration` 通过：`ios-http-local` 完成 `29` bytes，`ios-hls-local` 完成 fMP4 HLS 输出 `ios-hls.mp4`，`4815` bytes，`outputHeadHex` 含 `66747970`。

2026-06-23 04:11 CST 再次复跑 `npm run verify:ios:integration` 通过：脚本选中 iOS 18.3 simulator `FluxDownTemp2-iPhone16`，本地 fixture `http://127.0.0.1:51158`；`ios-http-local` 完成 `29` bytes，`ios-hls-local` 完成 fMP4 HLS 输出 `ios-hls.mp4`，`4815` bytes，`outputHeadHex` 含 `66747970`。同轮 `npm run verify:ios:device-readiness` 按预期返回 `78`：物理 iPhone `LMY 18.6.2 (00008030-001905801E50802E)` 仍处于 Offline，不能进行真机部署验证。

2026-06-23 04:16 CST 复跑 `npm run verify:macos` 通过：覆盖 Rust/desktop 基础测试、release CLI HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet/队列控制 fixture、桌面 command FTPS/SFTP/SMB/Torrent/Magnet live fixture、`FluxDown.app`/`FluxDown_1.0.3_aarch64.dmg` artifact 校验、许可证检查和 CI 手动触发策略检查。

2026-06-23 04:25 CST 新增并验证移动端 HLS BYTERANGE 支持：`flutter analyze` 通过，`flutter test` 通过 35 个测试；`npm run verify:ios:integration` 在同一 iOS simulator 上新增 `ios-hls-byterange-local`，输出 `ios-hls-byterange.mp4` 为 `4815` bytes，`outputHeadHex` 含 `66747970`。

2026-06-23 04:38 CST 新增并验证 macOS core/CLI/桌面 command 的 HLS BYTERANGE 支持：`cargo test -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop` 通过，当前 core 68、CLI 单元 1、CLI 集成 33、desktop 非 ignored 32 / ignored 7；`cargo clippy -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop --all-targets -- -D warnings` 通过；`npm run verify:macos-cli-http-hls` 和 `npm run verify:macos-cli-release-http-hls` 均通过，新增 HLS BYTERANGE 输出 SHA-256 为 `df20d9dcdbecbf0dce43b2148bbc312626f8a384660bbdaf33cbcb46e985886e`。

2026-06-23 04:50 CST 推送提交 `a7b2c67` 后复验 iOS：`npm run verify:ios:device-readiness` 按预期返回 `78`，物理 iPhone `LMY 18.6.2 (00008030-001905801E50802E)` 仍为 Offline；`npm run verify:ios:integration` 在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 通过，`ios-http-local` 输出 `29` bytes，`ios-hls-local` 和 `ios-hls-byterange-local` 均输出 `4815` bytes 且文件头包含 `66747970`；`npm run verify:ios` 通过，覆盖 analyze、35 个 Flutter 测试、iOS framework、simulator app、unsigned device app 和 URL scheme 校验。

2026-06-23 04:56 CST 新增 iOS TS HLS 专项探针：默认 `npm run verify:ios:integration` 仍只跑稳定的 HTTP/fMP4 HLS/fMP4 BYTERANGE HLS smoke 并通过；显式设置 `FLUXDOWN_IOS_INCLUDE_TS_HLS=1` 时会额外生成视频+AAC 的 MPEG-TS HLS 用例。探针最初在 simulator 上复现 `AVFoundationErrorDomain -11838`。

2026-06-23 05:10 CST 新增 Dart 内置 H.264/AAC TS -> fragmented MP4 remuxer 后复跑：`flutter analyze` 通过，`flutter test` 通过 36 个测试，新增 MPEG-TS HLS 测试会在本机有 ffmpeg 时生成真实 TS HLS 并用 ffprobe 校验输出；`FLUXDOWN_IOS_INCLUDE_TS_HLS=1 npm run verify:ios:integration` 在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 通过，`ios-hls-ts-local` 状态 `finished`，输出 `19884` bytes，`outputHeadHex` 包含 `66747970`。

## 推荐验收命令

日常非前台总验收：

```sh
npm run verify:apple
```

iOS App 内下载 smoke：

```sh
npm run verify:ios:integration
```

如果允许脚本在后台启动一个可用 iPhone simulator，可显式开启：

```sh
FLUXDOWN_IOS_BOOT_SIMULATOR=1 npm run verify:ios:integration
```

iOS TS HLS 转 MP4 专项探针：

```sh
FLUXDOWN_IOS_INCLUDE_TS_HLS=1 npm run verify:ios:integration
```

先确认真机是否已经能被 Flutter 部署：

```sh
npm run verify:ios:device-readiness
```

连接真机下载验证时，如果 iPhone 需要访问 Mac 上的本地 fixture，显式传入 Mac 局域网地址：

```sh
FLUXDOWN_IOS_DEVICE_ID=<device-id-or-name> \
FLUXDOWN_E2E_HOST=<mac-lan-ip> \
npm run verify:ios:integration
```

## 完成判定

当前目标还不能标记为完全完成：iOS simulator 已补 HTTP/fMP4 HLS/fMP4 BYTERANGE HLS/TS HLS App 内下载 smoke，但 iPhone 真机、签名 IPA 和真机专属能力仍未验证。若继续坚持不占用前台 GUI，macOS 桌面剩余纯 GUI 协议点击项应继续保持为“暂缓，不作为当前非前台验收阻塞项”；如果恢复前台 GUI 验证，则需要逐项记录点击、下载完成、落盘路径和 hash 证据。
