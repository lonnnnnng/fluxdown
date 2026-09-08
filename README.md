# FluxDown

[English](README.en.md)

FluxDown 是一款面向桌面端和移动端的多协议下载器。当前版本为 [1.0.15](https://github.com/lonnnnnng/fluxdown/releases/tag/v1.0.15)。以下功能说明以当前源码为准，历史验证单独标注。

## 当前状态

- 桌面端支持 Windows、macOS、Linux，包含 `fluxdown` CLI 和 Tauri + React GUI。
- 移动端支持 Android 和 iPhone，使用 Flutter App。
- 桌面端 GUI 收敛为下载列表和设置两页，并采用紧凑的状态侧栏、传输指标栏和任务表格；移动端首页保留任务队列和设置入口。
- 桌面任务行支持点击开始/暂停，右键、长按或三点按钮打开操作菜单；菜单集中提供复制、打开、分享、属性、重新下载和删除。
- 新建任务支持输入链接、自动识别协议、自动命名、另存文件名和保存位置；桌面、CLI 和移动端均支持可选 SHA-256 文件校验，移动端还支持扫码和剪切板填入链接。
- 设置项包含下载保存位置、并发下载数、下载线程数、自动重试数和最大下载网速。
- 桌面端支持系统托盘、关闭窗口驻留、单实例、完成/失败通知和可关闭的剪贴板监听；包含检查更新、下载安装包和窗口尺寸恢复。
- 桌面任务显示预计剩余时间（ETA），支持每任务限速；每任务配置优先于全局限速。移动端目前仍使用全局下载设置。
- 支持 HTTP/HTTPS、WebDAV/WebDAVS、FTP/FTPS、m3u8/HLS、SFTP、SMB、`.torrent`、Magnet 和 ed2k 移交。
- Torrent/Magnet 获取 metadata 后会展示真实文件名；移动端支持文件选择和文件夹详情，桌面 CLI/Tauri command 支持按文件编号选择。桌面详情面板展示文件、tracker、peer 和会话速率；当前源码已补齐运行中分文件进度，静态 metadata 不冒充下载进度。
- 移动端 HLS 会输出最终 `.mp4`，已有 fMP4、BYTERANGE 和 TS HLS smoke。桌面/core 另支持 master 清晰度选择、分片缓存恢复和保留 TS；默认转封装取决于 FFmpeg 可用性。
- 移动端限速、暂停取消、FTP/SFTP/SMB/HLS 分块取消和 Torrent 速度配置已接入统一下载控制器；ed2k 外部移交成功后使用 `handedOff` 状态，不冒充 FluxDown 内建下载完成。
- CLI 和桌面端会脱敏 URL 中的用户名和密码，并把另存文件名规范化为单文件名。
- 移动端协议识别优先通过 FFI 调用 Rust，库不可用时回退 Dart；队列与实际下载仍由 Dart/移动原生适配器执行，尚未统一到 Rust 下载引擎。
- 普通提交和 tag 推送不会触发 GitHub Actions；只有明确打包或发版时才手动运行流水线。

### 1.0.15 更新（2026-09-08）

iOS Rust 部署目标及 Runner 静态链接、移动端 FFI JSON 解码/内存释放、桌面 Torrent 分文件进度与轮询竞态已修复。公开 Assets 精简为 11 个上传文件，加源码包共 13 项。本地构建和定向测试通过，但没有重跑各端完整协议下载。详见 [发行说明](docs/releases/1.0.15.md) 和 [修复验证报告](docs/bugfix-verification-20260908.md)。

## 界面截图

### macOS 桌面端

历史界面图，采集于 2026-08-04 至 08-06（`1.0.8`/`1.0.9` 阶段），不展示后续托盘、更新及 Torrent 详情增强。

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/artifacts/readme/macos/queue.png" alt="macOS 下载列表" width="320"> | <img src="docs/artifacts/readme/macos/new-task.png" alt="macOS 新建任务" width="320"> | <img src="docs/artifacts/readme/macos/settings.png" alt="macOS 设置" width="320"> |

### Android 真机（Redmi Note 8 Pro）

以下为 2026-08-20 的 `1.0.10+11` release APK 真机截图，不是当前源码的新一轮截图；尚未包含后来新增的 SHA-256 输入项。

| 下载列表 | 新建任务 | 设置 |
| --- | --- | --- |
| <img src="docs/screenshots/android-redmi-gap-fixes.png" alt="Android 真机下载列表" width="220"> | <img src="docs/screenshots/android-new-task-gap-fixes.png" alt="Android 真机新建任务" width="220"> | <img src="docs/screenshots/android-settings-gap-fixes.png" alt="Android 真机设置" width="220"> |

## 验证边界

| 平台 | 已验证 | 仍需补充 |
| --- | --- | --- |
| macOS 桌面/CLI | release CLI 覆盖 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet 和队列控制；桌面 GUI 前台已完成 12 类协议真实验证；Tauri command 覆盖 HTTP/HLS/WebDAV/FTP/FTPS/SFTP/SMB/Torrent/Magnet。 | ed2k 仍按产品定义移交外部客户端；WebDAV/WebDAVS 已验证传输映射，完整目录遍历仍需单独补。 |
| Windows 桌面/CLI | CI 产物已发布；Windows 开发机完成 CLI 12 协议真实用例验证和原生 Tauri GUI 前台 12 协议验证，ed2k 按产品定义完成系统移交验证。`1.0.11` 又用公网真实资源（Cloudflare、curl.se、Apple BipBop、Rebex、Debian）复验了 CLI 与原生 GUI 的 HTTP/HTTPS、FTP、SFTP、HLS、队列控制和限速，见 [Windows 真实资源验证报告](docs/windows-real-resource-verification.md)。 | ed2k 不是 FluxDown 内建下载完成；GUI 验证使用 E2E 专用窗口和隔离队列。FTPS 对强制 TLS 会话复用的服务器（vsftpd 默认配置、Rebex）暂不支持数据传输，由 suppaftp 引擎上游限制决定（[suppaftp#93](https://github.com/veeso/suppaftp/issues/93)）。 |
| Linux 桌面/CLI | CI 已生成 Linux CLI、GUI 可执行文件、`.deb`、`.rpm` 并做非空检查。 | 尚未在 Linux 桌面环境安装 GUI 并完成真实下载。 |
| Android App | 历史 `1.0.4` 真机覆盖多协议及单/多文件 Torrent/Magnet；`1.0.10+11` 在 Redmi Note 8 Pro 复验安装、启动、队列、新建、设置、扫码/剪切板入口和保存位置容量面板。本次 Flutter 测试 50 项通过，含 host Rust FFI 测试，不等于 Android 原生库实机验证。 | 当前源码完整协议下载、FFI 原生打包/加载仍需真机复验；商店分发前还需签名、许可证和后台策略复验。 |
| iOS App | 历史 simulator 已完成 HTTP、fMP4/BYTERANGE/TS HLS smoke；2026-09-08 本地 simulator 与 unsigned device app 构建通过，最终二进制均检查到 8 个 FFI 导出符号；构建产物保留在 Actions Artifacts。 | 本次未新增 App 内下载验证。签名 IPA、iPhone 真机扫码、文件选择、分享/打开仍待补；Release 不提供普通用户可安装的 iOS 包。 |

上表中的历史下载验证不能替代当前版本回归。完整证据见 [下载验证状态](docs/download-verification.md)。

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
npm ci
npm run desktop:build
```

macOS 构建产物位于 `target/release/bundle/macos/FluxDown.app`。原生开发调试运行 `npm run desktop:dev`；仅预览前端运行 `npm run desktop:web`。

### Android

```sh
cd apps/mobile
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
```

上述 Flutter 命令不会自动编译 Android Rust 库。要验证 FFI 路径，先按 [移动端 FFI 构建](docs/build-release.md#移动端-rust-ffi) 生成 `jniLibs`；未打包时协议识别回退 Dart，不能据此判定 FFI 可用。

### iOS

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
cd apps/mobile
flutter build ios --simulator
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
```

Runner 构建阶段自动编译并静态链接 Rust FFI，最低部署版本为 iOS 15.0。签名 IPA 还需要 Apple certificate、provisioning profile、Team ID 和 keychain 密码，详见 [构建与发布](docs/build-release.md)。

## 发布产物

从 `v1.0.15` 起，常规 Release 只公开以下 11 个文件，加上 GitHub 自动提供的 ZIP/TAR.GZ 源码包后共 13 项：

| 用途 | 下载内容 |
| --- | --- |
| 手机安装 | Android release APK |
| 桌面安装 | Windows x64 Setup EXE、macOS ARM64 DMG、Linux x64 DEB/RPM |
| 命令行 | Windows x64、macOS ARM64、Linux x64 CLI |
| 校验与说明 | release manifest（大小/SHA-256）、LICENSE、第三方许可证清单 |

Debug APK、AAB、iOS 验证包、MSI、裸桌面程序和 macOS App 目录继续保留在对应构建的 Actions Artifacts，不进入普通用户下载区。当前签名与验证边界见 [发行说明](docs/releases/1.0.15.md)。

Release 页面：[FluxDown 1.0.15](https://github.com/lonnnnnng/fluxdown/releases/tag/v1.0.15)。

## 文档

- [文档索引](docs/README.md)
- [需求文档](docs/requirements.md)
- [技术架构](docs/architecture.md)
- [协议支持矩阵](docs/protocols.md)
- [下载验证状态](docs/download-verification.md)
- [2026-09-08 修复验证与文档差异](docs/bugfix-verification-20260908.md)
- [构建与发布](docs/build-release.md)
- [第三方许可证清单](docs/third-party-licenses.md)
- [运维与安全](docs/operations-security.md)
- [路线图](docs/roadmap.md)

## 许可证

FluxDown 自有代码采用 MIT License，见 [LICENSE](LICENSE)。移动端 torrent/magnet 使用的 `libtorrent_flutter` 包含 GPL 许可原生组件，正式分发商店版本前需要完成许可证义务审查；详情见 [第三方许可证清单](docs/third-party-licenses.md)。
