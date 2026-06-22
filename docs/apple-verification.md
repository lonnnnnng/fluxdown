# Apple 目标验收清单

本文档只跟踪当前目标范围：macOS 桌面端、macOS CLI 端和 iOS 端。它不替代完整下载验证报告，只用于快速判断当前目标哪些证据已经落地，哪些还需要前台设备或签名条件。

## 当前结论

| 目标项 | 当前状态 | 已有证据 | 剩余缺口 |
| --- | --- | --- | --- |
| macOS CLI | 非前台验收已通过 | `npm run verify:apple` 已串联 `npm run verify:macos`；release CLI 覆盖 HTTP/HLS、HLS BYTERANGE、FTP/FTPS、SFTP、SMB、Torrent/Magnet、队列控制和 artifact 校验。 | 真实公网边界资源仍可继续扩展，但当前本地可重复 fixture 已覆盖主要协议闭环。 |
| macOS 桌面端 | 非前台 command/artifact 验收已通过，既有前台 GUI 最小闭环已记录 | `npm run verify:apple` 已串联桌面 Tauri command fixture、`.app`/DMG 构建、ad-hoc 签名和 checksum；桌面 command 已覆盖 HLS BYTERANGE；历史前台 GUI 已覆盖 HTTP、HLS、Torrent、Magnet。 | 纯 GUI 前台的 FTP/FTPS、SFTP、SMB、IPFS、WebDAV 点击下载闭环仍按当前阶段暂缓。 |
| iOS 构建与静态验证 | 已通过 | `npm run verify:apple` 已串联 `flutter analyze`、`flutter test`、iOS framework build、simulator build、unsigned device build、artifact 校验和 URL scheme 校验；`npm run verify:ios:signing-readiness` 已能独立检查签名输入。 | 签名 IPA 需要 Apple 证书、provisioning profile、Team ID 和 keychain 密码输入；当前本机没有 codesigning identity 和匹配 profile。 |
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

2026-06-23 05:20 CST 增强 iOS 真机/签名前置检查：`npm run verify:ios:device-readiness` 继续返回 `78`，现在会额外输出 `xcdevice-unavailable`，当前 `LMY iPhone 11 18.6.2 (22G100)` 不可用，Xcode 原因为 `Browsing on the local area network for LMY`，建议解锁、接线或同局域网并开启 Developer Mode；新增 `npm run verify:ios:signing-readiness`，当前返回 `78`，缺少 `IOS_CERTIFICATE_BASE64`、`IOS_CERTIFICATE_PASSWORD`、`IOS_PROVISIONING_PROFILE_BASE64`、`IOS_KEYCHAIN_PASSWORD`、`APPLE_TEAM_ID`，本机 `codesigning-identities: none`，也没有匹配 `dev.fluxdown.mobile` 的 provisioning profile。

2026-06-23 05:42 CST 复跑当前 `origin/main` 的 Apple 非前台总验收与 iOS App 内下载 smoke：`npm run verify:apple` 通过，覆盖 macOS release CLI 多协议 fixture、macOS 桌面 command/artifact、许可证、CI 手动触发策略、iOS analyze/test/framework/simulator/unsigned device build 和 URL scheme；`FLUXDOWN_IOS_INCLUDE_TS_HLS=1 FLUXDOWN_IOS_BOOT_SIMULATOR=1 npm run verify:ios:integration` 在 iOS 18.3 simulator `FluxDownTemp2-iPhone16` 通过，HTTP 输出 `29` bytes，fMP4 HLS 与 BYTERANGE HLS 均输出 `4815` bytes，TS HLS 输出 `19884` bytes，MP4 输出头均包含 `66747970`；真机和签名前置检查仍按预期返回 `78`，物理 iPhone `LMY` 仍为 `xcdevice-unavailable`，签名自动化仍缺 5 个签名环境变量、codesigning identity 和匹配 provisioning profile。

2026-06-23 05:55 CST 新增 `npm run verify:ios:physical-integration` 真机专用入口：该入口只选择物理 iPhone，不会回退到 simulator；会自动推断 Mac 局域网地址并传给 `verify:ios:integration`，默认打开 TS HLS 探针。当前本机复跑按预期返回 `78`，因为 Flutter 没有可部署的物理 iPhone，脚本已串起 `npm run verify:ios:device-readiness` 并输出 `LMY` 的 `xcdevice-unavailable` 状态。

2026-06-23 05:56 CST 增强 `npm run verify:ios:signing-readiness`：签名环境变量齐全时会在临时目录中验证 provisioning profile 可解码、未过期且匹配 `dev.fluxdown.mobile`，并用临时 keychain 验证 p12 密码和 codesigning identity；本地 IPA 构建脚本同步改为用 `printf` 和 macOS/GNU 兼容 base64 解码。当前缺少真实签名材料时仍按预期返回 `78`；使用假 base64 材料复跑会输出 `env-invalid` 并在构建 IPA 前失败。

2026-06-23 06:05 CST 新增并复跑 `npm run verify:apple:runtime` 通过：该入口默认后台使用 iOS simulator，启用 TS HLS 探针，串联 iOS App 内 HTTP/fMP4 HLS/BYTERANGE HLS/TS HLS 下载 smoke，并汇总 iPhone 真机和签名 readiness。当前 simulator `FluxDownTemp2-iPhone16` 上 4 个用例均为 `finished`：HTTP `29` bytes，fMP4 HLS `4815` bytes，BYTERANGE HLS `4815` bytes，TS HLS `19884` bytes；物理 iPhone 和签名输入仍按预期报告 `78` 外部条件未就绪。

2026-06-23 06:21 CST 新增并首跑 `npm run verify:apple:current` 通过：该入口顺序串联 `npm run verify:apple` 与 `npm run verify:apple:runtime`，覆盖 macOS CLI release 多协议 fixture、macOS 桌面 command/artifact、iOS 静态构建和 iOS simulator 运行态下载 smoke。iOS simulator 本轮 HTTP 输出 `29` bytes，fMP4 HLS 和 BYTERANGE HLS 均输出 `4815` bytes，TS HLS 输出 `19884` bytes；物理 iPhone `LMY` 与签名输入继续按预期报告 `78` 外部条件未就绪。

## 推荐验收命令

日常非前台总验收：

```sh
npm run verify:apple
```

当前阶段 Apple 总验收：

```sh
npm run verify:apple:current
```

iOS 运行态补充验收：

```sh
npm run verify:apple:runtime
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

真机恢复可部署后，优先使用真机专用下载验收入口。该入口不会误选 simulator，并会自动尝试使用 Mac 局域网 IP：

```sh
npm run verify:ios:physical-integration
```

先确认签名 IPA 自动化输入是否齐全：

```sh
npm run verify:ios:signing-readiness
```

如自动推断的地址不对，可显式传入 Mac 局域网地址：

```sh
FLUXDOWN_E2E_HOST=<mac-lan-ip> \
npm run verify:ios:physical-integration
```

## 完成判定

当前目标还不能标记为完全完成：iOS simulator 已补 HTTP/fMP4 HLS/fMP4 BYTERANGE HLS/TS HLS App 内下载 smoke，但 iPhone 真机、签名 IPA 和真机专属能力仍未验证。若继续坚持不占用前台 GUI，macOS 桌面剩余纯 GUI 协议点击项应继续保持为“暂缓，不作为当前非前台验收阻塞项”；如果恢复前台 GUI 验证，则需要逐项记录点击、下载完成、落盘路径和 hash 证据。
