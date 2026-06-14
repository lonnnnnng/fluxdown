# FluxDown

[English](README.en.md)

FluxDown 是一个跨平台下载器工作区。

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
- [运维与安全](docs/operations-security.md)
- [路线图](docs/roadmap.md)

## 当前版本重点

- 默认文档入口为中文，英文 README 保留在 [README.en.md](README.en.md)。
- Android 队列页按状态分组，任务项显示开始/结束时间、总耗时、已下载/总大小、实时速度和平均速度。
- 新建任务支持剪切板、二维码扫描、另存文件名和保存位置选择。
- 设置页支持下载保存位置、并发下载数、下载线程数、自动重试数和最大下载网速。
- Torrent/Magnet 获取 metadata 后会展示真实文件名；多文件资源会弹出选择列表。
- Android 真机已补充本地协议资源和媒体级 HLS、torrent、magnet 前台 App 验证。

## 协议路线

任务模型识别这些传输类型：

- HTTP 和 HTTPS
- WebDAV 和 WebDAVS
- FTP 和 FTPS
- BitTorrent `.torrent`
- Magnet 磁力链接
- ed2k
- m3u8 / HLS
- SFTP
- SMB
- IPFS

桌面端执行引擎已经实现 HTTP/HTTPS 直链下载、基于 HTTP 传输的 WebDAV/WebDAVS 文件下载、FTP/FTPS 下载、密码认证 SFTP 下载、SMB2/3 共享文件下载、BitTorrent `.torrent` 和 Magnet 下载、ed2k 通过 aMule `ed2k` CLI 提交并在缺失时退回系统 URL handler、IPFS 网关下载，以及 VOD m3u8/HLS 播放列表下载，包括 AES-128 加密分片。

移动端 App 使用本地 JSON 队列，可以执行单个任务，也可以用有界并发运行队列。移动端支持 HTTP/HTTPS 和 WebDAV/WebDAVS 下载，包含进度、暂停和 HTTP Range 续传；也支持 FTP/FTPS 被动模式与 REST 续传、SFTP 密码认证与偏移续传、SMB2/3 文件下载、通过原生 libtorrent 绑定下载 BitTorrent `.torrent` 和 Magnet、IPFS 网关下载，以及 VOD m3u8/HLS 播放列表下载，包括 AES-128 加密分片，并在 Android 端转封装为最终 `.mp4` 文件。ed2k 链接会移交给设备上已安装的 eMule/aMule 兼容 App。

移动端 torrent 支持使用 `libtorrent_flutter`，它包含 GPL 许可的原生组件。正式分发商店版本前需要确认许可证义务。

## 常用命令

```sh
cargo run -p fluxdown-cli -- detect "https://example.com/file.zip"
cargo run -p fluxdown-cli -- support "magnet:?xt=urn:btih:..."
cargo run -p fluxdown-cli -- doctor
cargo run -p fluxdown-cli -- download "https://example.com/file.zip" --output ./downloads
cargo run -p fluxdown-cli -- add "https://example.com/file.zip" --output ./downloads
cargo run -p fluxdown-cli -- list
cargo run -p fluxdown-cli -- start "<task-id>"
cargo run -p fluxdown-cli -- run --concurrency 2
cargo run -p fluxdown-cli -- pause "<task-id>"
cargo run -p fluxdown-cli -- resume "<task-id>"
cargo run -p fluxdown-cli -- remove "<task-id>"
cargo build -p fluxdown-cli --release
./target/release/fluxdown doctor
npm install
npm run desktop:web
npm run desktop:build
npm run desktop:dmg
npm run verify:ci-config
npm run verify:artifacts
npm run verify:linux-cli
npm run verify:linux-gui
npm run verify:windows-cli
npm run verify:windows-gui
npm run verify:release
npm run verify:mobile-url-schemes
npm run release:prepare
npm run release:stage
npm run release:manifest
npm run release:manifest:verify
npm run mobile:ios:simulator:verify
npm run mobile:ios:verify
npm run mobile:ios:ipa:signed
npm run audit:release
npm run desktop:linux:docker
npm run desktop:windows-cli:docker
npm run desktop:windows-gui:docker
cd apps/mobile && flutter analyze
cd apps/mobile && flutter test
cd apps/mobile && flutter build apk --debug
cd apps/mobile && flutter build apk --release
cd apps/mobile/android && ./gradlew bundleRelease
cd apps/mobile && flutter build ios --simulator
cd apps/mobile && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios-framework --no-profile --no-release
cd apps/mobile && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --export-options-plist=ios/ExportOptions.plist
cd apps/mobile && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
cd apps/mobile && flutter run
```

`download` 会立即执行一个下载源并打印 JSON 摘要。`add` 会把任务持久化到队列。`start` 按任务 id 执行队列任务，并把最终状态写回队列。默认队列文件为 `$XDG_DATA_HOME/fluxdown/queue.json` 或 `~/.local/share/fluxdown/queue.json`；CLI 可通过 `--store /path/to/queue.json` 覆盖。

Flutter 移动端队列文件保存在 App documents 目录下的 `fluxdown/queue.json`。下载输出默认在 App 沙盒内的 `downloads` 文件夹，用户可在 App 中修改。
移动端 ed2k 移交依赖平台 URL handler 可见性。Android manifest 声明了 `ed2k` VIEW query，iOS Info.plist 声明了 `ed2k` 的 `LSApplicationQueriesSchemes`；`npm run verify:mobile-url-schemes` 会检查两端配置。

## 构建产物

- `npm run desktop:build` 构建 Tauri 桌面 App bundle。在 macOS 上会生成 `target/release/bundle/macos/FluxDown.app`。
- `npm run desktop:dmg` 使用不依赖 Finder 的 `hdiutil` 流程，创建 `target/release/bundle/dmg/FluxDown_<version>_aarch64.dmg`。这样可以避免 CI/headless 环境中的 Finder AppleScript 超时。
- `cd apps/mobile && flutter build apk --debug` 生成 `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`。
- `cd apps/mobile && flutter build apk --release` 生成 `apps/mobile/build/app/outputs/flutter-apk/app-release.apk`。
- `cd apps/mobile/android && ./gradlew bundleRelease` 生成 Google Play 可上传的 `apps/mobile/build/app/outputs/bundle/release/app-release.aab`。
- `cd apps/mobile && flutter build ios --simulator` 在安装匹配 iOS simulator runtime 时验证 iOS 项目，不需要 Apple 签名。
- `cd apps/mobile && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios-framework --no-profile --no-release` 在 Apple 签名材料可用时创建 iOS debug frameworks。当前 macOS runner 上 Flutter 会在该命令前做签名身份检查，所以 CI 只在 iOS 签名 secrets 配置后执行。
- `cd apps/mobile && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --export-options-plist=ios/ExportOptions.plist` 在 Apple 签名、Team 和 provisioning 配置完成后创建 App Store IPA。
- `npm run mobile:ios:ipa:signed` 将 base64 编码的 Apple 签名材料导入本地临时 keychain，生成手动导出配置，构建签名 App Store IPA，并验证 `apps/mobile/build/ios/ipa/*.ipa`。
- `cd apps/mobile && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign` 验证 device build 到签名前阶段。可部署到 iPhone 的构建仍需要 Apple Development Team 和 provisioning profile。
- `npm run verify:artifacts` 检查本地 CLI、桌面 DMG、Android APK/AAB 和 iOS debug frameworks 等 release 产物存在且非空。
- `docker run --rm --platform linux/amd64 -v "$PWD":/work -w /work rust:1-bookworm bash -lc '/usr/local/cargo/bin/cargo test -p fluxdown-core -p fluxdown-cli --target-dir /work/target-linux-docker && /usr/local/cargo/bin/cargo build -p fluxdown-cli --release --target-dir /work/target-linux-docker && mkdir -p dist/linux-amd64 && cp target-linux-docker/release/fluxdown dist/linux-amd64/fluxdown'` 在 Docker 可用时本地构建并测试 Linux amd64 CLI 产物。
- `npm run verify:linux-cli` 检查 Docker 构建的 Linux CLI 产物存在且非空。
- `npm run desktop:linux:docker` 在隔离 Docker 环境中使用 Node 22 构建 Linux amd64 Tauri GUI，并把产物复制到 `dist/linux-gui`。
- `npm run verify:linux-gui` 检查 Docker 构建的 Linux GUI 可执行文件以及 `.deb`、`.rpm` 包存在且非空。
- `npm run desktop:windows-cli:docker` 通过 Docker 交叉构建 Windows x86_64 CLI，并暂存 `dist/windows-gnu/fluxdown.exe`。
- `npm run verify:windows-cli` 检查 Docker 构建的 Windows CLI 产物存在且非空。
- `npm run desktop:windows-gui:docker` 通过 Docker 交叉构建 Windows x86_64 GUI 可执行文件，并暂存 `dist/windows-gui-gnu/fluxdown-desktop.exe` 和 `WebView2Loader.dll`。
- `npm run verify:windows-gui` 检查 Docker 构建的 Windows GUI 可执行文件和相邻 WebView2 loader 存在且非空。
- `npm run mobile:ios:simulator:verify` 检查 Flutter 构建的本地 iPhone simulator app bundle。
- `npm run mobile:ios:verify` 检查 Flutter 构建的本地 unsigned iPhone device app bundle。
- `npm run release:stage` 将本地 release 输出复制和归档到 `dist/release/FluxDown-<version>` 下的平台目录。
- `npm run verify:release` 检查 staged release 目录包含预期的桌面 CLI、桌面 GUI、Android 和 unsigned iPhone/simulator/framework 产物。
- `npm run release:manifest` 写入 `dist/release/FluxDown-<version>/FluxDown-release-manifest.json`，记录原始构建输出和 staged release 产物的平台、界面、大小和 SHA-256。`.app`、`.xcframework` 等目录产物使用文件聚合哈希。
- `npm run release:manifest:verify` 重新计算当前本地产物，并和 `dist/release/FluxDown-<version>/FluxDown-release-manifest.json` 校验。
- `npm run release:prepare` 一次性执行 staging、manifest 生成、staged artifact 校验和 manifest 校验。
- `npm run audit:release` 检查协议覆盖和可用本地 release 产物，并把缺失本地 iPhone IPA 等签名依赖缺口作为 warning 报告。

Windows CLI 和原始 Windows GUI 可执行文件可以用 Docker 在本地交叉构建。在 installer 外分发或测试 Docker 交叉构建的原始 Windows GUI 可执行文件时，请把 `WebView2Loader.dll` 放在同一目录。Windows installer 包（`.msi` 和 NSIS `.exe`）在 CI 的 `windows-latest` 上构建和验证，因为 Tauri 桌面 bundle 需要 Windows 桌面工具链；该 CI artifact 会上传 installer 和原始 Windows GUI 可执行文件。

## Android 签名

本地 Android release 构建会使用 `apps/mobile/android/key.properties`。复制 `apps/mobile/android/key.properties.example`，设置密码、alias 和 keystore 文件，并确保真实 `key.properties` 和 keystore 不进入版本控制。如果文件不存在，release 构建会回退到 debug signing，因此 APK/AAB 仍可用于本地安装测试。

CI 在设置以下 repository secrets 后可以产出签名 Android release artifact：

- `ANDROID_KEYSTORE_BASE64`：base64 编码的 upload keystore。
- `ANDROID_KEYSTORE_PASSWORD`：keystore 密码。
- `ANDROID_KEY_ALIAS`：upload key alias。
- `ANDROID_KEY_PASSWORD`：upload key 密码。

没有这些 secrets 时，CI 仍会使用 debug signing 构建 release APK/AAB，用于安装和打包检查。

## iOS 签名

本地 iPhone IPA 构建需要仓库外的 Apple 签名材料：Apple team、distribution certificate，以及 bundle id `dev.fluxdown.mobile` 的 App Store provisioning profile。仓库中的 `apps/mobile/ios/ExportOptions.plist` 配置为 App Store export 和 automatic signing。`npm run mobile:ios:ipa:signed` 使用和 CI 相同的签名输入，把解码后的凭据写入被忽略的 `apps/mobile/ios/signing/`，写入被忽略的 `apps/mobile/ios/ExportOptions.local.plist`，并验证生成的 IPA。

CI 总是构建 simulator 和 unsigned device iOS artifact 作为编译检查。当以下 repository secrets 设置完成后，CI 还会构建 debug frameworks 并上传签名 IPA：

- `IOS_CERTIFICATE_BASE64`：base64 编码的 `.p12` distribution certificate。
- `IOS_CERTIFICATE_PASSWORD`：`.p12` 证书密码。
- `IOS_PROVISIONING_PROFILE_BASE64`：base64 编码的 `dev.fluxdown.mobile` `.mobileprovision` profile。
- `IOS_KEYCHAIN_PASSWORD`：CI 临时 keychain 密码。
- `APPLE_TEAM_ID`：拥有 provisioning profile 的 Apple Developer Team ID。

没有这些 secrets 时，CI 会跳过 IPA 步骤，但仍通过 simulator 和 unsigned device 构建验证 Flutter iPhone 项目。debug framework 构建也受 iOS 签名 secret 集合控制，因为当前 macOS/Flutter runner 会在该命令完成前做签名身份检查。

## CI 产物

`.github/workflows/build.yml` 会针对产品目标平台验证并打包项目：

- `fluxdown-cli-linux`：Linux CLI 二进制，暂存名为 `fluxdown`。
- `fluxdown-cli-windows`：Windows CLI 二进制，暂存名为 `fluxdown.exe`。
- `fluxdown-cli-macos`：macOS CLI 二进制，暂存名为 `fluxdown`。
- `fluxdown-desktop-linux`：Linux Tauri GUI 产物，包括 `.deb`、`.rpm` 和原始可执行文件。
- `fluxdown-desktop-windows`：Windows Tauri GUI 产物，例如 `.msi`、NSIS `.exe` 和 runner 生成的原始可执行文件。
- `fluxdown-desktop-macos`：macOS `FluxDown.app` 和不依赖 Finder 的 DMG。
- `fluxdown-android-debug-apk`：Android debug APK。
- `fluxdown-android-release-apk`：使用当前 repository 签名配置的 Android release APK。
- `fluxdown-android-release-aab`：使用当前 repository 签名配置的 Android release App Bundle。
- `fluxdown-ios-debug-frameworks`：Flutter App 和插件的 iOS debug framework 构建输出。
- `fluxdown-ios-simulator`：安装匹配 simulator runtime 时生成的 iPhone simulator app bundle。
- `fluxdown-ios-device-unsigned`：无代码签名构建的 unsigned iPhone device app bundle。
- `fluxdown-ios-release-ipa`：签名 iPhone App Store IPA，仅在 iOS signing secrets 配置完成后生成。
