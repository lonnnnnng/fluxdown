# FluxDown Mobile

[English](README.md)

FluxDown 的 Flutter Android/iOS App。

App 保存本地 JSON 队列，允许用户启动或暂停单个任务，也可以从队列工具栏以有界并发运行已排队任务。

## 命令

```sh
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release
cd android && ./gradlew bundleRelease
flutter build ios --simulator
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios-framework --no-profile --no-release
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --export-options-plist=ios/ExportOptions.plist
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
cd ../.. && npm run mobile:ios:simulator:verify
cd ../.. && npm run mobile:ios:verify
cd ../.. && npm run mobile:ios:ipa:signed
```

Android debug APK 会写入 `build/app/outputs/flutter-apk/app-debug.apk`。
Android release APK 会写入 `build/app/outputs/flutter-apk/app-release.apk`。
Android App Bundle 会写入 `build/app/outputs/bundle/release/app-release.aab`。

Android 商店签名时，复制 `android/key.properties.example` 为 `android/key.properties`，让 `storeFile` 指向 upload keystore，并填写密码和 alias。真实 `android/key.properties` 和 keystore 文件会被 git 忽略。如果 `android/key.properties` 不存在，release 构建会回退到 debug signing，用于安装和打包检查。

iOS simulator 构建可在安装匹配 simulator runtime 时验证 App，不需要 Apple 签名。iOS framework 构建可在不配置 Apple signing team 的情况下验证 Flutter App 和插件编译。若本地 shell 默认使用 ASCII，请为 CocoaPods 设置 `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8`。Device build 可以通过 `--no-codesign` 编译到签名前阶段，但部署到 iPhone 或生成签名 archive 需要在 Xcode 中配置 Apple Development Team 和 provisioning profile。签名配置完成后，`flutter build ipa --export-options-plist=ios/ExportOptions.plist` 是 App Store export 路径。也可以从仓库根目录运行 `npm run mobile:ios:ipa:signed`，导入和 CI 相同的 base64 签名变量并构建签名 IPA。

Simulator 和 unsigned device app bundle 由仓库根目录的验证脚本检查。
