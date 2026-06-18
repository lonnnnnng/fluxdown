# FluxDown

[English](README.en.md)

FluxDown 是一款面向桌面和移动端的多协议下载器，包含 CLI、桌面 GUI 和移动 App。

## 目标平台

- 桌面端：Windows、macOS、Linux
  - CLI：`fluxdown`
  - GUI：Tauri + React
- 移动端：Android、iPhone
  - App：Flutter
- 共享引擎：Rust core crate

## 文档

- [文档索引](docs/README.md)
- [需求文档](docs/requirements.md)
- [业务文档](docs/business.md)
- [技术架构](docs/architecture.md)
- [协议支持矩阵](docs/protocols.md)
- [下载验证状态](docs/download-verification.md)
- [构建与发布](docs/build-release.md)
- [第三方许可证清单](docs/third-party-licenses.md)
- [运维与安全](docs/operations-security.md)
- [路线图](docs/roadmap.md)

## 当前版本重点

- 默认文档入口为中文，英文 README 保留在 [README.en.md](README.en.md)。
- 桌面端 GUI 收敛为下载列表和设置两页，Windows、macOS、Linux 共用同一套 Tauri UI。
- Android 队列页按状态分组，任务项显示开始/结束时间、总耗时、已下载/总大小、实时速度和平均速度。
- 新建任务支持剪切板、二维码扫描、协议/后端状态预览、另存文件名和保存位置选择。
- 设置页支持下载保存位置、并发下载数、下载线程数、自动重试数和最大下载网速。
- Torrent/Magnet 获取 metadata 后会展示真实文件名；Android 已支持多文件选择，桌面 CLI/Tauri command 已支持按文件编号选择下载内容。
- CLI 输出和桌面展示会脱敏 URL 中的用户名和密码，原始链接仍可用于下载和复制。
- CLI 和桌面端会把另存文件名规范化为单文件名，避免异常文件名写出保存目录。
- CLI 和桌面客户端新建任务支持可选 SHA-256 校验，校验失败会让直连命令报错或队列任务进入失败状态。
- 桌面队列默认使用平台原生数据目录，macOS 会兼容读取并迁移旧版 `~/.local/share/fluxdown/queue.json`。
- macOS、Windows、Android、iOS 已补充当前阶段的界面截图和验证记录；Windows 已完成 CLI 直连/队列 HTTP 真下载和 GUI 前台 HTTP 真下载闭环。
- macOS 已完成 release CLI 多协议脚本化真实下载、桌面 Tauri command 多协议真实下载，以及 GUI 前台 HTTP/HLS/Torrent/Magnet 下载闭环。
- Android 真机已补充本地协议资源和媒体级 HLS、torrent、magnet 前台 App 验证；iOS 当前完成模拟器界面和构建产物验证，签名 IPA 与真机下载闭环仍待补。
- Linux 当前仅完成 CLI/GUI 构建产物存在性检查，尚未在 Linux 桌面环境中完成真实 GUI 下载验证。
- 仓库自有代码采用 MIT License，第三方依赖和移动端 GPL 风险见 [第三方许可证清单](docs/third-party-licenses.md)。

## 界面截图

### Windows 桌面端

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/artifacts/readme/windows/queue.png" alt="Windows 下载列表" width="320"> | <img src="docs/artifacts/readme/windows/new-task.png" alt="Windows 新建任务" width="320"> | <img src="docs/artifacts/readme/windows/settings.png" alt="Windows 设置" width="320"> |

### macOS 桌面端

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/artifacts/readme/macos/queue.png" alt="macOS 下载列表" width="320"> | <img src="docs/artifacts/readme/macos/new-task.png" alt="macOS 新建任务" width="320"> | <img src="docs/artifacts/readme/macos/settings.png" alt="macOS 设置" width="320"> |

### Android 真机

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/artifacts/readme/android-real-device/queue.png" alt="Android 下载列表" width="220"> | <img src="docs/artifacts/readme/android-real-device/new-task.png" alt="Android 新建任务" width="220"> | <img src="docs/artifacts/readme/android-real-device/settings.png" alt="Android 设置" width="220"> |

### iOS 模拟器

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/artifacts/readme/ios-simulator/queue.jpg" alt="iOS 下载列表" width="220"> | <img src="docs/artifacts/readme/ios-simulator/new-task.jpg" alt="iOS 新建任务" width="220"> | <img src="docs/artifacts/readme/ios-simulator/settings.jpg" alt="iOS 设置" width="220"> |

## 验证进度

| 平台 | 已完成验证 | 当前边界 |
| --- | --- | --- |
| Windows 桌面端 | 本机 release 构建、CLI HTTP 直连下载、CLI 队列下载、Tauri command HTTP 队列下载、真实 GUI 前台 HTTP 下载和文件 SHA-256 校验均已通过；README 已补充 Windows 下载列表、新建任务和设置截图。 | GUI 前台点击目前只覆盖 HTTP；FTP/FTPS/SFTP/SMB/IPFS/WebDAV/Torrent/Magnet 仍主要依赖 CLI 或 Tauri command 真实下载验证。 |
| macOS 桌面端 | release CLI 已覆盖 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet 和队列控制；GUI 前台已覆盖 HTTP/HLS/Torrent/Magnet；Tauri command 已覆盖 HTTP/HLS/WebDAV/FTP/FTPS/SFTP/SMB/IPFS/Torrent/Magnet。 | 纯 GUI 的 FTP/FTPS/SFTP/SMB/IPFS/WebDAV 点击闭环后续单独补。 |
| Linux 桌面端 | 已有 Linux CLI、GUI 可执行文件、`.deb`、`.rpm` 等构建产物和非空检查。 | 尚未在 Linux 桌面环境安装或启动 GUI 完成真实下载验证。 |
| Android 真机 | Redmi Note 8 Pro 前台 App 已覆盖本地 HTTP/HTTPS/FTP/FTPS/SFTP/SMB/IPFS、小 HLS、小 torrent、小 magnet，以及媒体级 HLS、单/多文件 torrent 和 magnet。 | 正式商店分发前还需要签名、许可证和更多后台策略验证。 |
| iOS 模拟器 | 已补充模拟器界面截图、Flutter simulator/unsigned device 构建产物和 URL scheme 配置验证。 | 暂未完成签名 IPA、iPhone 真机安装和 App 内真实下载闭环。 |

完整证据、命令和未覆盖项见 [下载验证状态](docs/download-verification.md)。

## 协议路线

FluxDown 识别 HTTP/HTTPS、WebDAV/WebDAVS、FTP/FTPS、`.torrent`、Magnet、ed2k、m3u8/HLS、SFTP、SMB 和 IPFS。桌面端 CLI/GUI 共用 Rust 下载核心；移动端 App 使用 Flutter 本地队列，并在 Android/iOS 上把 HLS 输出为最终 `.mp4` 文件。

完整协议实现、平台差异和已知限制见 [协议支持矩阵](docs/protocols.md)。真实下载验证边界见 [下载验证状态](docs/download-verification.md)。

## 快速开始

### CLI

```sh
cargo run -p fluxdown-cli -- doctor
cargo run -p fluxdown-cli -- detect "https://example.com/file.zip"
cargo run -p fluxdown-cli -- download "https://example.com/file.zip" --output ./downloads
cargo run -p fluxdown-cli -- add "https://example.com/file.zip" --output ./downloads
cargo run -p fluxdown-cli -- run --concurrency 2
```

`download` 会立即执行下载并打印 JSON 摘要；`add` 会把任务写入队列；`run` 按并发数执行排队任务。`download` 和 `add` 可传 `--sha256 <64位hex>` 校验最终文件，直连校验失败会返回非零，队列校验失败会把任务标记为 `failed`。macOS 默认队列文件位于 `~/Library/Application Support/FluxDown/queue.json`；`XDG_DATA_HOME` 或 CLI `--store /path/to/queue.json` 可覆盖默认路径，旧版 `~/.local/share/fluxdown/queue.json` 会在新路径不存在时自动读取并迁移。

### 桌面端

```sh
npm install
npm run desktop:build
```

macOS 构建完成后，桌面 App 位于 `target/release/bundle/macos/FluxDown.app`。开发调试可运行 `npm run desktop:web` 和 `npm run desktop:dev`。
Windows 本机具备桌面工具链时，`npm run desktop:build` 会生成 `target/release/fluxdown-desktop.exe`、MSI 和 NSIS installer；当前 Windows 机已经通过 GUI 前台 HTTP 下载闭环验证。

### 移动端

```sh
cd apps/mobile && flutter analyze
cd apps/mobile && flutter test
cd apps/mobile && flutter build apk --debug
cd apps/mobile && flutter build ios --simulator
cd apps/mobile && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
```

Flutter 移动端队列文件保存在 App documents 目录下的 `fluxdown/queue.json`。下载输出默认在 App 沙盒内的 `downloads` 文件夹，用户可在 App 中修改。
移动端 ed2k 移交依赖平台 URL handler 可见性；`npm run verify:mobile-url-schemes` 会检查 Android 和 iOS 配置。

## 验证和发布

```sh
npm run verify:macos
npm run verify:ci-config
npm run verify:mobile-url-schemes
```

`npm run verify:macos` 是当前 macOS 非 GUI 总验收入口，不启动前台 GUI。普通提交和标签推送不会触发 GitHub Actions；只有明确打包或发版时，才在 Actions 页面手动运行 workflow。完整构建、签名、产物和发布流程见 [构建与发布](docs/build-release.md)。

## 许可证

FluxDown 自有代码采用 MIT License，见 [LICENSE](LICENSE)。移动端 torrent/magnet 使用的 `libtorrent_flutter` 包含 GPL 许可原生组件，正式分发商店版本前需要完成许可证义务审查；详情见 [第三方许可证清单](docs/third-party-licenses.md)。
