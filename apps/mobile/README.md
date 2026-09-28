# FluxDown Mobile

[中文](README.zh-CN.md)

Flutter Android/iOS app for FluxDown.

The app keeps a local JSON queue and automatically schedules waiting tasks up to the configured concurrency. Task rows start/pause on tap; long press opens actions. New tasks support QR/clipboard input, file naming, output location, and optional SHA-256 verification. Settings can import an SFTP `known_hosts` file and store password or private-key credentials in platform secure storage for host-key verification and authentication.

Protocol detection and Torrent/Magnet metadata inspection use Rust FFI. When the native library is available, the production entry routes
HTTP/HTTPS/WebDAV(S)/HLS and metadata-confirmed Torrent/Magnet tasks through the Rust queue; a missing or failed Rust metadata call blocks creation of a new Torrent/Magnet task, while SFTP private keys and ed2k remain on the Dart/native adapters. See [FFI build
and test instructions](../../docs/build-release.md#移动端-rust-ffi) and [current verification boundaries](../../docs/bugfix-verification-20260908.md).

## Commands

Run from `apps/mobile`. Android Rust `.so` files must be built separately using cargo-ndk before Flutter packaging. iOS requires the `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios` Rust targets; Runner builds/links FFI automatically with an iOS 15.0 minimum.

```sh
flutter analyze
flutter test
flutter build apk --debug
flutter build apk --release --split-per-abi --target-platform android-arm64
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk build/app/outputs/flutter-apk/app-release.apk
flutter build appbundle --release
flutter build ios --simulator
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios-framework --no-profile --no-release
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --export-options-plist=ios/ExportOptions.plist
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ios --no-codesign
```

From the repository root, check the final iOS app bundles and FFI exports:

```sh
npm run mobile:ios:simulator:verify
npm run mobile:ios:verify
```

Plain `flutter test` skips the four native-library cases. Pass `FLUXDOWN_FFI_TEST_LIBRARY` as described in the build guide to test a real host Rust library; this does not replace Android/iOS native-device verification.

The Android debug APK is written to `build/app/outputs/flutter-apk/app-debug.apk`.
The Android Release APK is built for `arm64-v8a` only and is written to `build/app/outputs/flutter-apk/app-release.apk`. The Android App Bundle is also restricted to `arm64-v8a` by the Gradle ABI filter and is written to `build/app/outputs/bundle/release/app-release.aab`.

For Android store signing, copy `android/key.properties.example` to `android/key.properties`, point `storeFile` at the upload keystore, and fill in the passwords and alias. The real `android/key.properties` and keystore files are ignored by git. If `android/key.properties` is absent, release builds fall back to debug signing for install and packaging checks.

The iOS simulator build validates the app without Apple signing when a matching simulator runtime is installed. The iOS framework build validates the Flutter app and plugin compilation without an Apple signing team. Set `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` for CocoaPods on local shells that default to ASCII. A device build can be compiled up to signing with `--no-codesign`, but deploying to an iPhone or producing a signed archive requires an Apple Development Team and provisioning profile in Xcode. `flutter build ipa --export-options-plist=ios/ExportOptions.plist` is the App Store export path once signing is configured. From the repository root, `npm run mobile:ios:ipa:signed` can import the same base64 signing variables used by CI and build a signed IPA.
The simulator and unsigned device app bundles are checked by the repository root verification scripts.
