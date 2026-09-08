# FluxDown Mobile

[English](README.md)

FluxDown 的 Flutter Android/iOS App。

App 保存本地 JSON 队列，按设置的并发数自动调度排队任务。点击任务开始/暂停，长按打开操作菜单；新建任务支持扫码/剪切板、文件命名、保存位置与可选 SHA-256 校验。

协议识别优先调用 Rust FFI，不可用时回退 Dart；实际队列与下载控制器仍由 Dart/移动原生适配器执行，尚未切换到 Rust 队列引擎。见 [FFI 构建与测试](../../docs/build-release.md#移动端-rust-ffi) 和 [当前验证边界](../../docs/bugfix-verification-20260908.md)。

## 命令

以下命令在 `apps/mobile` 执行。Android Rust `.so` 必须先通过 cargo-ndk 单独编译；iOS 需安装 `aarch64-apple-ios`、`aarch64-apple-ios-sim` 和 `x86_64-apple-ios` 三个 Rust targets，Runner 会自动编译/链接 FFI，最低 iOS 15.0。

```sh
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
flutter build appbundle --release
flutter build ios --simulator
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios-framework --no-profile --no-release
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --export-options-plist=ios/ExportOptions.plist
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
```

从仓库根目录验证最终 iOS App 与 FFI 导出：

```sh
npm run mobile:ios:simulator:verify
npm run mobile:ios:verify
```

直接运行 `flutter test` 会跳过 4 项原生库测试。按构建文档传入 `FLUXDOWN_FFI_TEST_LIBRARY` 才会调用真实 host Rust 库；host 测试不能替代 Android/iOS 原生设备验证。

Android debug APK 会写入 `build/app/outputs/flutter-apk/app-debug.apk`。
Android release APK 会写入 `build/app/outputs/flutter-apk/app-release.apk`。
Android App Bundle 会写入 `build/app/outputs/bundle/release/app-release.aab`。

Android 商店签名时，复制 `android/key.properties.example` 为 `android/key.properties`，让 `storeFile` 指向 upload keystore，并填写密码和 alias。真实 `android/key.properties` 和 keystore 文件会被 git 忽略。如果 `android/key.properties` 不存在，release 构建会回退到 debug signing，用于安装和打包检查。

iOS simulator 构建可在安装匹配 simulator runtime 时验证 App，不需要 Apple 签名。iOS framework 构建可在不配置 Apple signing team 的情况下验证 Flutter App 和插件编译。若本地 shell 默认使用 ASCII，请为 CocoaPods 设置 `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。Device build 可以通过 `--no-codesign` 编译到签名前阶段，但部署到 iPhone 或生成签名 archive 需要在 Xcode 中配置 Apple Development Team 和 provisioning profile。签名配置完成后，`flutter build ipa --export-options-plist=ios/ExportOptions.plist` 是 App Store export 路径。也可以从仓库根目录运行 `npm run mobile:ios:ipa:signed`，导入和 CI 相同的 base64 签名变量并构建签名 IPA。

Simulator 和 unsigned device app bundle 由仓库根目录的验证脚本检查。
