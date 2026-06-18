# 构建与发布文档

## 版本来源

当前版本号维护在：

- `package.json`
- `apps/desktop/package.json`
- Rust workspace `Cargo.toml`
- Flutter `apps/mobile/pubspec.yaml`

当前版本为 `1.0.3`。发布标签使用 `v<version>`，例如 `v1.0.3`。GitHub Release 作业会校验标签版本和 `package.json` 版本一致。

## 本地依赖

建议本地准备：

- Rust stable toolchain。
- Node.js 22 和 npm。
- Flutter stable。
- Android JDK 17 和 Android SDK。
- Xcode 与 CocoaPods，用于 iOS/macOS 构建。
- Docker，用于 Linux/Windows 交叉构建辅助脚本。

不同平台构建还需要对应系统工具链：

- Linux GUI：WebKitGTK、AppIndicator、librsvg、patchelf、rpm。
- Windows GUI installer：推荐使用 GitHub Actions 的 `windows-latest`。
- macOS DMG/iOS：需要 macOS runner 或本地 macOS。

## 常用检查

```sh
cargo test -p fluxdown-core -p fluxdown-cli
npm --workspace apps/desktop run build
cd apps/mobile && flutter analyze
cd apps/mobile && flutter test
npm run verify:macos
npm run verify:ci-config
npm run verify:mobile-url-schemes
```

完整 workspace 检查：

```sh
npm test
```

`npm test` 会运行 Rust 测试、桌面前端构建和 Flutter 测试。它需要本机已配置 Flutter。

`npm run verify:macos` 是当前 macOS 非 GUI 总验收入口，会覆盖格式检查、严格 Clippy、core/CLI/desktop 测试、release CLI 全协议 fixture、桌面端 Tauri command fixture、macOS 产物校验和 CI 手动触发策略校验；它不会启动前台 GUI。

## CLI 构建

```sh
cargo build -p fluxdown-cli --release
./target/release/fluxdown doctor
```

CI 会在 Linux、Windows 和 macOS 分别构建 CLI，并上传：

- `fluxdown-cli-linux`
- `fluxdown-cli-windows`
- `fluxdown-cli-macos`

## 桌面 GUI 构建

```sh
npm install
npm run desktop:web
npm run desktop:build
```

macOS DMG：

```sh
npm run desktop:dmg
```

`desktop:dmg` 使用 `scripts/create-macos-dmg.mjs`，避免依赖 Finder AppleScript，适合 CI/headless 环境。

Docker 辅助构建：

```sh
npm run desktop:linux:docker
npm run desktop:windows-cli:docker
npm run desktop:windows-gui:docker
```

本地验证：

```sh
npm run verify:linux-cli
npm run verify:linux-gui
npm run verify:windows-cli
npm run verify:windows-gui
```

## Android 构建

```sh
cd apps/mobile
flutter build apk --debug
flutter build apk --release
cd android && ./gradlew bundleRelease
```

输出：

- `apps/mobile/build/app/outputs/flutter-apk/app-debug.apk`
- `apps/mobile/build/app/outputs/flutter-apk/app-release.apk`
- `apps/mobile/build/app/outputs/bundle/release/app-release.aab`

### Android 签名

本地正式签名：

1. 复制 `apps/mobile/android/key.properties.example` 为 `apps/mobile/android/key.properties`。
2. 设置 `storePassword`、`keyPassword`、`keyAlias`、`storeFile`。
3. 确认真实 `key.properties` 和 keystore 不进入版本控制。

如果 `key.properties` 不存在，release 构建会回退到 debug signing，适合安装测试和打包检查，不适合商店发布。

CI 签名 secrets：

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

## iOS 构建

模拟器验证：

```sh
cd apps/mobile
flutter build ios --simulator
```

无签名 device 编译验证：

```sh
cd apps/mobile
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
```

iOS framework 验证：

```sh
cd apps/mobile
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios-framework --no-profile --no-release
```

签名 IPA：

```sh
npm run mobile:ios:ipa:signed
```

或直接：

```sh
cd apps/mobile
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --export-options-plist=ios/ExportOptions.plist
```

### iOS 签名

签名 IPA 需要：

- Apple Developer Team。
- `.p12` 分发证书。
- 匹配 `dev.fluxdown.mobile` 的 App Store provisioning profile。
- 导出配置。

CI secrets：

- `IOS_CERTIFICATE_BASE64`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `IOS_KEYCHAIN_PASSWORD`
- `APPLE_TEAM_ID`

没有这些 secrets 时，CI 会跳过签名 IPA，但仍构建 simulator 和 unsigned device 验证产物。当前 workflow 中 iOS debug frameworks 也只在签名 secrets 齐全时构建，以避开当前 macOS/Flutter 签名检查限制。

## Release staging

本地准备发布目录：

```sh
npm run release:stage
npm run release:manifest
npm run verify:release
npm run release:manifest:verify
```

一键执行：

```sh
npm run release:prepare
```

发布目录位于：

```text
dist/release/FluxDown-<version>
```

Release manifest 记录平台、产物类型、大小和 SHA-256。目录型产物例如 `.app` 和 `.xcframework` 使用文件聚合哈希。

发布前还需要确认仓库根目录 [LICENSE](../LICENSE) 和 [第三方许可证清单](third-party-licenses.md) 与当前构建产物一致。移动端包含 `libtorrent_flutter` 时，必须单独完成 GPL 义务审查后再分发正式商店版本。

## GitHub Actions

`.github/workflows/build.yml` 包含五类作业：

- `rust`：Linux、Windows、macOS 上测试 core/CLI 并构建 CLI。
- `desktop`：Linux、Windows、macOS 上构建 Tauri GUI 并上传平台产物。
- `android`：分析、测试、构建 debug APK、release APK 和 AAB。
- `ios`：构建 iOS simulator、unsigned device；签名 secrets 齐全时构建 IPA。
- `release`：手动运行在 `v*` 标签 ref 上，并选择 `run_mode=release` 时，下载所有 artifact，整理 assets，发布或更新 GitHub Release。

流水线只在明确需要打包或发版时，通过 GitHub Actions 页面手动触发 `workflow_dispatch` 运行。普通代码提交推送到 `main` 只同步代码，不触发打包流水线；推送 `v*` 标签也只同步标签，不自动触发流水线。手动触发时必须选择 `run_mode`：需要打包时选择 `package`，需要发版时选择 `release` 并切换到对应 `v*` 标签 ref。选择 `release` 但 ref 不是 `v*` 标签时，预检会立刻失败，避免误跑整套多平台构建。Actions 页面里事件为 `push` 的记录是旧版配置留下的历史执行记录，当前配置不会因普通 push 继续新增。

`npm run verify:ci-config` 会检查 `.github/workflows/build.yml` 是否仍只保留 `workflow_dispatch` 入口、是否要求显式选择打包/发版模式、是否启用同 ref 手动运行去重、以及 Release 作业是否只允许在 `run_mode=release` 且 `v*` 标签 ref 上执行。

## CI 产物

| Artifact | 内容 |
| --- | --- |
| `fluxdown-cli-linux` | Linux CLI `fluxdown`。 |
| `fluxdown-cli-windows` | Windows CLI `fluxdown.exe`。 |
| `fluxdown-cli-macos` | macOS CLI `fluxdown`。 |
| `fluxdown-desktop-linux` | Linux GUI raw executable、`.deb`、`.rpm`。 |
| `fluxdown-desktop-windows` | Windows GUI raw executable、MSI、NSIS installer。 |
| `fluxdown-desktop-macos` | macOS `FluxDown.app` 和 DMG。 |
| `fluxdown-android-debug-apk` | Android debug APK。 |
| `fluxdown-android-release-apk` | Android release APK。 |
| `fluxdown-android-release-aab` | Android App Bundle。 |
| `fluxdown-ios-simulator` | iPhone simulator app bundle。 |
| `fluxdown-ios-device-unsigned` | unsigned iPhone device app bundle。 |
| `fluxdown-ios-release-ipa` | 签名 IPA，仅 secrets 齐全时生成。 |

## 发布流程

1. 更新版本号，确保 `package.json`、桌面包、Rust workspace 和 Flutter 版本一致。
2. 运行本地检查和必要的平台构建。
3. 运行 `npm run audit:release` 查看发布准备状态。
4. 提交代码并推送到 `main`。这一步只同步代码，不触发 GitHub Actions 打包流水线。
5. 创建并推送标签，例如 `git tag v1.0.3 && git push origin v1.0.3`。
6. 在 GitHub Actions 页面手动运行 `Build` workflow，选择刚推送的 `v*` 标签 ref，并设置 `run_mode=release`。
7. 在 Release 页面检查 assets 和 release notes。

## 常见问题

- Linux GUI 构建失败：检查 WebKitGTK 和系统依赖是否安装。
- Windows GUI raw executable 无法单独运行：确认 `WebView2Loader.dll` 与 exe 同目录。
- Android release artifact 是 debug 签名：说明未配置 Android signing secrets 或本地 `key.properties`。
- iOS IPA 缺失：说明 Apple signing secrets 不完整或 provisioning profile 不匹配。
- Release 作业拒绝发布：检查 tag 名称是否与 `package.json` 版本一致。
