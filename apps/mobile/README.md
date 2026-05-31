# FluxDown Mobile

Flutter Android/iOS app for FluxDown.

The app keeps a local JSON queue, lets a user start or pause individual tasks, and can run queued tasks with bounded concurrency from the queue toolbar.

## Commands

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

The Android debug APK is written to `build/app/outputs/flutter-apk/app-debug.apk`.
The Android release APK is written to `build/app/outputs/flutter-apk/app-release.apk`.
The Android App Bundle is written to `build/app/outputs/bundle/release/app-release.aab`.

For Android store signing, copy `android/key.properties.example` to `android/key.properties`, point `storeFile` at the upload keystore, and fill in the passwords and alias. The real `android/key.properties` and keystore files are ignored by git. If `android/key.properties` is absent, release builds fall back to debug signing for install and packaging checks.

The iOS simulator build validates the app without Apple signing when a matching simulator runtime is installed. The iOS framework build validates the Flutter app and plugin compilation without an Apple signing team. Set `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` for CocoaPods on local shells that default to ASCII. A device build can be compiled up to signing with `--no-codesign`, but deploying to an iPhone or producing a signed archive requires an Apple Development Team and provisioning profile in Xcode. `flutter build ipa --export-options-plist=ios/ExportOptions.plist` is the App Store export path once signing is configured. From the repository root, `npm run mobile:ios:ipa:signed` can import the same base64 signing variables used by CI and build a signed IPA.
The simulator and unsigned device app bundles are checked by the repository root verification scripts.
