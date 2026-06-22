# Apple 目标验收清单

本文档只跟踪当前目标范围：macOS 桌面端、macOS CLI 端和 iOS 端。它不替代完整下载验证报告，只用于快速判断当前目标哪些证据已经落地，哪些还需要前台设备或签名条件。

## 当前结论

| 目标项 | 当前状态 | 已有证据 | 剩余缺口 |
| --- | --- | --- | --- |
| macOS CLI | 非前台验收已通过 | `npm run verify:apple` 已串联 `npm run verify:macos`；release CLI 覆盖 HTTP/HLS、FTP/FTPS、SFTP、SMB、Torrent/Magnet、队列控制和 artifact 校验。 | 真实公网边界资源仍可继续扩展，但当前本地可重复 fixture 已覆盖主要协议闭环。 |
| macOS 桌面端 | 非前台 command/artifact 验收已通过，既有前台 GUI 最小闭环已记录 | `npm run verify:apple` 已串联桌面 Tauri command fixture、`.app`/DMG 构建、ad-hoc 签名和 checksum；历史前台 GUI 已覆盖 HTTP、HLS、Torrent、Magnet。 | 纯 GUI 前台的 FTP/FTPS、SFTP、SMB、IPFS、WebDAV 点击下载闭环仍按当前阶段暂缓。 |
| iOS 构建与静态验证 | 已通过 | `npm run verify:apple` 已串联 `flutter analyze`、`flutter test`、iOS framework build、simulator build、unsigned device build、artifact 校验和 URL scheme 校验。 | 签名 IPA 需要 Apple 证书和 provisioning profile。 |
| iOS App 内下载 | 入口已准备，真实运行未完成 | `npm run verify:ios:integration` 会生成本地 HTTP/HLS fixture，并在已有 iOS simulator 或 iPhone 目标时运行 `apps/mobile/integration_test/protocol_e2e_test.dart`。 | 当前没有已连接或已启动的 iOS 运行目标；后续需要手动启动 simulator 或连接 iPhone 后执行该脚本。 |

## 推荐验收命令

日常非前台总验收：

```sh
npm run verify:apple
```

iOS App 内下载 smoke：

```sh
npm run verify:ios:integration
```

连接真机时，如果 iPhone 需要访问 Mac 上的本地 fixture，显式传入 Mac 局域网地址：

```sh
FLUXDOWN_IOS_DEVICE_ID=<device-id-or-name> \
FLUXDOWN_E2E_HOST=<mac-lan-ip> \
npm run verify:ios:integration
```

## 完成判定

当前目标不能标记为完全完成，原因是 iOS App 内真实下载 E2E 还没有在 iOS simulator 或 iPhone 上跑通。若继续坚持不占用前台 GUI，macOS 桌面剩余纯 GUI 协议点击项应继续保持为“暂缓，不作为当前非前台验收阻塞项”；如果恢复前台 GUI 验证，则需要逐项记录点击、下载完成、落盘路径和 hash 证据。
