# 构建与发布文档

## 版本来源

当前版本号维护在：

- `package.json`
- `apps/desktop/package.json`
- Rust workspace `Cargo.toml`
- Flutter `apps/mobile/pubspec.yaml`

当前版本号为 `1.0.16`，包含 FFI/桌面详情与跨进程队列修复、精简发行策略和包体优化，见 [发行说明](releases/1.0.16.md)。发布标签使用 `v<version>`，GitHub Release 作业会校验标签版本和 `package.json` 版本一致。`v1.0.15` 因 Linux CLI 回归失败未发布，保留原标签；后续发版使用新版本号，不覆盖已有标签。

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
npm run mobile:analyze
npm run mobile:test
npm run verify:apple
npm run verify:apple:current
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

`npm run verify:apple` 会串联 `npm run verify:macos` 和 `npm run verify:ios`，用于当前 macOS 桌面/CLI 与 iOS 构建产物的非前台总验收。它不会启动前台桌面 GUI，也不会自动启动 iOS simulator；iOS App 内下载 smoke 仍需在已有 iOS 目标时单独执行 `npm run verify:ios:integration`。

`npm run verify:apple:current` 会串联 `npm run verify:apple` 和 `npm run verify:apple:runtime`，用于当前阶段 Apple 侧构建/产物与 iOS simulator 下载 smoke 的一键复验；真机和签名 readiness 的 `78` 结果仍代表外部条件未就绪。

如果需要补充 iOS 运行态下载证据，执行：

```sh
npm run verify:apple:runtime
```

该入口默认后台启动可用 iOS simulator、启用 TS HLS 探针，并把真机/签名 readiness 的 `78` 结果归类为外部条件未就绪。

## CLI 构建

```sh
cargo build -p fluxdown-cli --release
./target/release/fluxdown doctor
```

CI 会在 Linux、Windows 和 macOS 分别构建 CLI，并上传：

- `fluxdown-cli-linux`
- `fluxdown-cli-windows`
- `fluxdown-cli-macos`

三平台 CI 在上传前使用实际 Release CLI 执行版本检查、`detect/add/pause/resume/run/list/download`，下载隔离 HTTP/Range 夹具并验证大小与 SHA-256。`fluxdown-cli-<platform>-smoke` 留存 JSON 报告，不进入公开 Assets。本地可执行：

```sh
npm run verify:release-cli-smoke -- /absolute/path/to/fluxdown dist/cli-smoke/report.json
```

脚本不会构建程序、启动 GUI 或操作默认用户队列。它只覆盖基础 CLI 下载流程，不替代所有协议测试或安装包内 GUI 验收。

## 桌面 GUI 构建

```sh
npm ci
npm run desktop:build
```

开发时运行 `npm run desktop:dev`；只检查前端时运行 `npm run desktop:web`。Web 预览不代表原生 Tauri 下载能力可用。

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

需要随包使用 Rust 协议识别时，先执行下文 [移动端 Rust FFI](#移动端-rust-ffi) 的 Android 编译命令。单独执行 Flutter 构建不会生成 Rust `.so`，缺库时 App 会回退到 Dart 协议识别。

```sh
cd apps/mobile
flutter build apk --debug
flutter build apk --release --split-debug-info=build/symbols/android
flutter build appbundle --release --split-debug-info=build/symbols/android
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

### Windows 代码签名

CI 的 Windows CLI 与桌面产物支持 Authenticode 签名（SHA-256 摘要 + RFC3161 时间戳），secrets 未配置时自动跳过、不阻断打包。首次启用签名：

1. 购买代码签名证书并导出为 `.pfx`（含私钥）。
2. 在仓库 Settings → Secrets → Actions 添加：
   - `WINDOWS_PFX_BASE64`：`.pfx` 文件的 base64 内容（本机可用 `certutil -encode cert.pfx cert.b64` 生成，取内容体）。
   - `WINDOWS_PFX_PASSWORD`：该 `.pfx` 的导出密码。
   - 可选 `WINDOWS_TIMESTAMP_URL`：自定义 RFC3161 时间戳服务器，默认 `http://timestamp.digicert.com`。
3. 重新手动运行 Build workflow；日志里 `sign-windows-artifacts: signed N file(s)` 即签名成功，被签的文件包括 Windows CLI、桌面 exe、NSIS 安装包与 MSI。

签名依赖 Windows runner 自带的 Windows Kits `signtool`；签名逻辑在 `scripts/sign-windows-artifacts.mjs`。未签名分发的现状是用户首次运行会触发 SmartScreen 提示——正式对外分发前强烈建议启用签名。

## 移动端 Rust FFI

`crates/fluxdown-ffi` 提供 ABI 1 的协议识别、支持状态与队列 C 接口。产品当前只接入 FFI 优先的协议识别；Flutter 下载控制器仍调用 Dart/移动原生适配器。原生队列绑定可独立测试，不等于移动端已切换下载引擎。请求字段与返回值见 [任务模型与 FFI](task-schema.md)。

### Android 原生库

需要已安装 Android NDK、`cargo-ndk` 和三个 Rust targets。从仓库根目录执行，与手动 CI 的 Android 步骤一致：

```sh
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo ndk --target arm64-v8a --target armeabi-v7a --target x86_64 --platform 24 \
  -o apps/mobile/android/app/src/main/jniLibs build --release \
  -p fluxdown-ffi --features fluxdown-core/vendored-openssl
```

产出的 `arm64-v8a` / `armeabi-v7a` / `x86_64` 三个 `libfluxdown_ffi.so` 会被 Flutter 打进 APK/AAB。Android 使用 `DynamicLibrary.open('libfluxdown_ffi.so')`；仍需在对应 ABI 设备上验证加载，host 测试不能替代这一步。

### iOS 静态链接

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
bash scripts/build-ios-ffi.sh
```

- 脚本默认构建真机 arm64 静态库；Runner 的 `Build FluxDown FFI` 阶段会根据 `PLATFORM_NAME` / `ARCHS` 构建真机或模拟器库，多模拟器架构使用 `lipo` 合并。
- Rust 与 C 依赖共用 `IPHONEOS_DEPLOYMENT_TARGET=15.0`，与 Runner 对齐。不要让 Rust 默认部署目标与 Xcode SDK/Runner 目标分离。
- 产物分别位于 `target/ffi-ios/iphoneos/libfluxdown_ffi.a` 和 `target/ffi-ios/iphonesimulator/libfluxdown_ffi.a`，不能因为两者都是 arm64 就混用。
- `ios/Flutter/FluxDownFfi.xcconfig` 链入静态库和系统依赖，并保留 8 个 C ABI 导出，避免 Release dead-strip 后 `DynamicLibrary.process()` 找不到符号。Debug/Release 配置均包含该文件。
- 手动 CI 复用同一脚本，并上传真机静态库 `fluxdown-ffi-ios-static`。静态库 artifact 不是可安装 App，也不能单独证明 Runner 已正确链接。

### FFI 回归测试

在仓库根目录先构建 host 库，再从 `apps/mobile` 运行 Flutter 测试。macOS 示例：

```sh
cargo build --locked -p fluxdown-ffi
cd apps/mobile
flutter test --dart-define=FLUXDOWN_FFI_TEST_LIBRARY="$(cd ../.. && pwd)/target/debug/libfluxdown_ffi.dylib"
```

Linux 库为 `target/debug/libfluxdown_ffi.so`，Windows 为 `target/debug/fluxdown_ffi.dll`，参数须指向当前 host 的绝对路径，不是 Android/iOS 交叉编译产物。Android CI job 在 Linux host 编译该库并传入 Flutter 测试。

`test/core_ffi_test.dart` 覆盖信封解析、ABI/版本、12 类协议识别、Unicode 队列、错误透传，以及真实本地 HTTP 下载后的内容与大小核验。不传该参数时原生库相关的 4 项会跳过，仅跑 Dart 信封测试；不能把这一结果写成 FFI 验证通过。

`queueRun` 是同步阻塞调用，未来接入产品必须在隔离线程/isolate 中执行，并补齐进度、取消和队列控制接口；当前测试把 HTTP 服务放在独立 isolate，避免服务端与 FFI 调用互相阻塞。

## iOS 构建

先安装上节列出的三个 Rust iOS targets；Runner 会自动编译并链接 FFI。2026-09-08 已在 Xcode 16.2 / Rust 1.97.1 / Flutter 3.41.9 本地通过以下两种 App 构建，但未重跑远端 CI 或真机下载。

模拟器验证：

```sh
cd apps/mobile
flutter build ios --simulator
```

无签名 device 编译验证：

```sh
cd apps/mobile
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign --split-debug-info=build/symbols/ios
```

回到仓库根目录检查最终产物，而不是只检查 `.a` 是否存在：

```sh
npm run mobile:ios:simulator:verify
npm run mobile:ios:verify
```

这两个入口检查 App 内 `Runner` / `Runner.debug.dylib` 的 8 个 FFI 导出符号。符号检查和 unsigned 构建不代替 iOS App 运行验证或签名验证。

iOS framework 验证：

```sh
cd apps/mobile
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios-framework --no-profile --no-release
```

或使用顶层脚本同时构建并校验 framework、simulator app、unsigned device app：

```sh
npm run verify:ios
```

签名 IPA：

```sh
npm run verify:ios:signing-readiness
npm run mobile:ios:ipa:signed
```

或直接：

```sh
cd apps/mobile
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --split-debug-info=build/symbols/ios --export-options-plist=ios/ExportOptions.plist
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

没有这些 secrets 时，CI 会跳过签名 IPA，但仍构建 simulator 和 unsigned device 验证产物。本地 `npm run verify:ios` 会额外构建并校验 debug `App.xcframework` 和 `Flutter.xcframework`，用于补充 iOS framework 编译证据。

真机下载验收独立于 IPA 签名。iPhone 已能被 Flutter 部署后，运行：

```sh
npm run verify:ios:physical-integration
```

该入口只选择物理 iPhone，不会回退到 simulator；如果自动推断的 Mac 局域网地址不对，可以显式设置 `FLUXDOWN_E2E_HOST=<mac-lan-ip>`。

## 公开发行策略

从 `1.0.16` 开始，GitHub Release 固定公开 11 个上传文件；另有 GitHub 自动生成的 ZIP/TAR.GZ 源码包，页面共 13 项。

| 分类 | 公开文件 | 数量 |
| --- | --- | --- |
| 用户安装 | Android release APK、Windows x64 Setup、macOS ARM64 DMG、Linux x64 DEB/RPM | 5 |
| 命令行 | Windows x64 CLI ZIP、macOS ARM64 / Linux x64 CLI TAR.GZ | 3 |
| 核验与许可 | release manifest、LICENSE、第三方许可证说明 | 3 |

Debug APK、AAB、iOS simulator/unsigned app、可选签名 IPA/framework、Windows MSI、裸桌面程序和 macOS App 构建目录继续由各 CI job 构建、检查、上传为 Actions Artifacts，不自动进入公开下载区。CI Artifacts 受仓库保留期限制，不是永久的用户发行渠道。旧 Release 的资产不批量删除。

桌面在线更新当前依赖 Windows `-setup.exe`、macOS `.dmg` 和 Linux `.deb` 的命名，调整公开资产时必须同时检查 `matches_platform_asset` 的匹配规则。

`scripts/prepare-github-release-assets.mjs` 只提取公开文件，要求输出目录为空，拒绝缺失或多个候选文件；发行正文读取 `docs/releases/<version>.md`，避免重复使用旧版本说明。`scripts/verify-github-release-assets.mjs` 校验精确的 11 项白名单和 manifest 中 10 项的大小/SHA-256（manifest 不包含自身哈希）。

```sh
npm run verify:ci-config
node scripts/prepare-github-release-assets.mjs <ci-artifacts-directory> <new-empty-assets-directory>
npm run verify:github-release -- <new-empty-assets-directory>
```

`verify:ci-config` 同时运行 11 项隔离发布回归，覆盖公开数量、内部产物排除、缺包、多候选、不清理已有输出目录、多余文件、哈希变化、重复 manifest 项，以及三平台 CLI 解压内容与 Unix 可执行权限。

### 包体与符号

- Rust Release 保持默认 `opt-level=3` 和 `panic=unwind`，启用 Thin LTO、`codegen-units=1` 和 debug info 裁剪；CLI/桌面额外裁剪符号表，移动 FFI 保留导出。不要使用 `panic=abort`，否则 FFI 的异常恢复语义会变化。
- Flutter Android Release 已由插件开启 R8 及资源裁剪，不需要再加宽泛 keep 规则；未使用的 `cupertino_icons` 字体依赖已移除，不影响 Flutter 的 Cupertino 控件。
- 使用 `npm run mobile:android:release`、`npm run mobile:android:aab`、`npm run mobile:ios` 打包，会传入 `--split-debug-info`。保留 `apps/mobile/build/symbols/android` / `ios`，异常堆栈用同一版本、同一架构的 `.symbols` 配合 `flutter symbolize` 还原。没有启用 Dart 标识符混淆。
- CI 将 Dart 符号和 R8 mapping 归档为 `fluxdown-android-symbols` / `fluxdown-ios-symbols`，不公开到 Release；本地构建也应保留这些输出，不混用不同版本符号。
- Android 仍构建三 ABI 通用 APK；Windows NSIS 保留默认 LZMA，RPM 使用 XZ level 6，DMG 保持 UDZO 格式但提高 zlib 压缩等级。DEB 由 Tauri 构建，受益于二进制裁剪，未增加额外系统依赖。
- CLI 压缩包内只放平台二进制和两份许可证；Unix 归档设置可执行权限。打包依赖标准 `tar` / `zip` 工具，回归解包另用 `unzip`。
- 比较口径和测量结果见 [包体优化记录](release-size-optimization.md)。

## 内部完整归档

以下原有入口用于本地完整测试/归档，仍要求多端内部产物，不等于公开 Release 的 11 项白名单，也不会上传文件：

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

内部归档目录位于：

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
- `release`：手动运行在 `v*` 标签 ref 上，并选择 `run_mode=release` 时，整理公开白名单文件、校验大小/哈希，再发布 GitHub Release。内部产物不会因为已经构建就自动公开。

流水线只在明确需要打包或发版时，通过 GitHub Actions 页面手动触发 `workflow_dispatch` 运行。普通代码提交推送到 `main` 只同步代码，不触发打包流水线；推送 `v*` 标签也只同步标签，不自动触发流水线。手动触发时必须选择 `run_mode`：需要打包时选择 `package`，需要发版时选择 `release` 并切换到对应 `v*` 标签 ref。选择 `release` 但 ref 不是 `v*` 标签时，预检会立刻失败，避免误跑整套多平台构建。Actions 页面里事件为 `push` 的记录是旧版配置留下的历史执行记录，当前配置不会因普通 push 继续新增。

`npm run verify:ci-config` 检查脚本语法、手动触发/同 ref 去重/标签发布门槛，并运行公开资产回归。手动流水线在 preflight 阶段先执行这些检查，避免等多平台编译完才发现发布策略错误。

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
| `fluxdown-ffi-ios-static` | iPhone arm64 Rust 静态库，独立构建证据，不是 App 安装包。 |
| `fluxdown-ios-release-ipa` | 签名 IPA，仅 secrets 齐全时生成。 |

## 发布流程

1. 更新版本号，确保 `package.json`、桌面包、Rust workspace 和 Flutter 版本一致。
2. 运行本地检查和必要的平台构建。
3. 运行 `npm run audit:release` 查看发布准备状态。
4. 提交代码并推送到 `main`。这一步只同步代码，不触发 GitHub Actions 打包流水线。
5. 创建并推送与新版本一致的 `v<version>` 标签；先确认标签不存在，不重写已发布标签。
6. 在 GitHub Actions 页面手动运行 `Build` workflow，选择刚推送的 `v*` 标签 ref，并设置 `run_mode=release`。
7. 从 Release 下载回验全部 11 个公开文件的大小/SHA-256、版本/包名，检查页面含源码包共 13 项；不要把只检查 CI 工作目录写成远端资产验证通过。

## 常见问题

- Linux GUI 构建失败：检查 WebKitGTK 和系统依赖是否安装。
- Windows GUI raw executable 无法单独运行：确认 `WebView2Loader.dll` 与 exe 同目录。
- Android release artifact 是 debug 签名：说明未配置 Android signing secrets 或本地 `key.properties`。
- iOS IPA 缺失：说明 Apple signing secrets 不完整或 provisioning profile 不匹配。
- Release 作业拒绝发布：检查 tag 名称是否与 `package.json` 版本一致。
