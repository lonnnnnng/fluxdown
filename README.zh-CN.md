# FluxDown

[English](README.en.md)

FluxDown 是一款面向桌面端和移动端的多协议下载器。当前版本为 `1.0.5`，最新发布见 [FluxDown 1.0.5](https://github.com/lonnnnnng/fluxdown/releases/tag/v1.0.5)。

## 当前状态

- 桌面端支持 Windows、macOS、Linux，包含 `fluxdown` CLI 和 Tauri + React GUI。
- 移动端支持 Android 和 iPhone，使用 Flutter App。
- 桌面端 GUI 收敛为下载列表和设置两页；移动端首页保留任务队列和设置入口。
- 新建任务支持粘贴链接、二维码扫描、保存文件名、保存位置和 SHA-256 校验。
- 设置项包含下载保存位置、并发下载数、下载线程数、自动重试数和最大下载网速。
- 支持 HTTP/HTTPS、WebDAV/WebDAVS、FTP/FTPS、m3u8/HLS、SFTP、SMB、`.torrent`、Magnet 和 ed2k 移交。
- Torrent/Magnet 获取 metadata 后会展示真实文件名；Android 支持多文件选择，桌面 CLI/Tauri command 支持按文件编号选择。
- HLS 下载会输出最终 `.mp4`；移动端已覆盖 fMP4、BYTERANGE 和 TS HLS smoke。
- CLI 和桌面端会脱敏 URL 中的用户名和密码，并把另存文件名规范化为单文件名。
- 普通提交和 tag 推送不会触发 GitHub Actions；只有明确打包或发版时才手动运行流水线。

## 界面截图

### macOS 桌面端

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/artifacts/readme/macos/queue.png" alt="macOS 下载列表" width="320"> | <img src="docs/artifacts/readme/macos/new-task.png" alt="macOS 新建任务" width="320"> | <img src="docs/artifacts/readme/macos/settings.png" alt="macOS 设置" width="320"> |

### Android 模拟器（Pixel_9）

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/artifacts/readme/android-emulator/queue.png" alt="Android 模拟器下载列表" width="220"> | <img src="docs/artifacts/readme/android-emulator/new-task.png" alt="Android 模拟器新建任务" width="220"> | <img src="docs/artifacts/readme/android-emulator/settings.png" alt="Android 模拟器设置" width="220"> |

## 验证边界

| 平台 | 已验证 | 仍需补充 |
| --- | --- | --- |
| macOS 桌面/CLI | release CLI 覆盖 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet 和队列控制；桌面 GUI 前台覆盖 HTTP/HLS/Torrent/Magnet；Tauri command 覆盖 HTTP/HLS/WebDAV/FTP/FTPS/SFTP/SMB/Torrent/Magnet。 | 纯 GUI 的 FTP/FTPS/SFTP/SMB/WebDAV 点击闭环后续单独补。 |
| Windows 桌面/CLI | CI 产物已发布；Windows 开发机完成 CLI 12 协议真实用例验证和原生 Tauri GUI 前台 12 协议验证，ed2k 按产品定义完成系统移交验证。 | ed2k 不是 FluxDown 内建下载完成；GUI 验证使用 E2E 专用窗口和隔离队列。 |
| Linux 桌面/CLI | CI 已生成 Linux CLI、GUI 可执行文件、`.deb`、`.rpm` 并做非空检查。 | 尚未在 Linux 桌面环境安装 GUI 并完成真实下载。 |
| Android App | Redmi Note 8 Pro 真机已覆盖本地 HTTP/HTTPS/FTP/FTPS/SFTP/SMB、小 HLS、小 torrent、小 magnet，以及媒体级 HLS、单/多文件 torrent 和 magnet。Pixel_9 模拟器已更新当前界面截图。 | 商店分发前还需签名、许可证和后台策略复验。 |
| iOS App | CI 已生成 iOS simulator app 和 unsigned device app；iOS simulator 已完成 HTTP、fMP4 HLS、BYTERANGE HLS、TS HLS 下载 smoke。 | 签名 IPA、iPhone 真机安装、扫码、文件选择、分享/打开等真机能力仍待补。 |

完整证据见 [下载验证状态](docs/download-verification.md)。

## 快速开始

### CLI

```sh
cargo run -p fluxdown-cli -- doctor
cargo run -p fluxdown-cli -- detect "https://example.com/file.zip"
cargo run -p fluxdown-cli -- download "https://example.com/file.zip" --output ./downloads
cargo run -p fluxdown-cli -- add "https://example.com/file.zip" --output ./downloads
cargo run -p fluxdown-cli -- run --concurrency 2
```

`download` 会立即执行下载并打印 JSON 摘要；`add` 会写入队列；`run` 按并发数执行队列。`--sha256 <64位hex>` 可用于校验最终文件。

### 桌面端

```sh
npm install
npm run desktop:build
```

macOS 构建产物位于 `target/release/bundle/macos/FluxDown.app`。开发调试可运行 `npm run desktop:web` 和 `npm run desktop:dev`。

### Android

```sh
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

### iOS

```sh
cd apps/mobile
flutter build ios --simulator
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
```

签名 IPA 需要 Apple certificate、provisioning profile、Team ID 和 keychain 密码，详见 [构建与发布](docs/build-release.md)。

## 发布产物

`v1.0.5` Release 已包含：

- Android debug APK、release APK、release AAB
- iOS simulator app、unsigned device app
- macOS CLI、`.app.tar.gz`、DMG
- Windows CLI、桌面 exe、MSI、NSIS installer
- Linux CLI、桌面可执行文件、deb、rpm
- release manifest、LICENSE、第三方许可证清单

Release 页面：[FluxDown 1.0.5](https://github.com/lonnnnnng/fluxdown/releases/tag/v1.0.5)

## 文档

- [文档索引](docs/README.md)
- [需求文档](docs/requirements.md)
- [技术架构](docs/architecture.md)
- [协议支持矩阵](docs/protocols.md)
- [下载验证状态](docs/download-verification.md)
- [构建与发布](docs/build-release.md)
- [第三方许可证清单](docs/third-party-licenses.md)
- [运维与安全](docs/operations-security.md)
- [路线图](docs/roadmap.md)

## 许可证

FluxDown 自有代码采用 MIT License，见 [LICENSE](LICENSE)。移动端 torrent/magnet 使用的 `libtorrent_flutter` 包含 GPL 许可原生组件，正式分发商店版本前需要完成许可证义务审查；详情见 [第三方许可证清单](docs/third-party-licenses.md)。
