#!/usr/bin/env bash
set -euo pipefail

# 作者: long
# Kotlin 迁移预览与 Flutter 工程并存；先生成同一 Rust core 的 JNI 动态库，再构建
# arm64-v8a APK，确保迁移不会悄悄回到另一套协议实现或扩大 ABI 范围。
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NDK_HOME="${ANDROID_NDK_LATEST_HOME:-${ANDROID_NDK_HOME:-}}"
if [[ -z "$NDK_HOME" ]]; then
  NDK_HOME="$HOME/Library/Android/sdk/ndk/28.2.13676358"
fi
if [[ ! -d "$NDK_HOME" ]]; then
  echo "Android NDK not found: $NDK_HOME" >&2
  exit 1
fi

export ANDROID_NDK_HOME="$NDK_HOME"
cd "$ROOT_DIR"

cargo ndk --target arm64-v8a --platform 24 \
  -o apps/android/app/src/main/jniLibs \
  build --release -p fluxdown-android \
  --features vendored-openssl

# cargo-ndk 会把工作区依赖的 cdylib 一并复制出来；Kotlin JNI 壳已经静态链接
# `fluxdown-ffi`，保留第二份动态库只会让 APK 平白增加约 16 MB。
rm -f apps/android/app/src/main/jniLibs/arm64-v8a/libfluxdown_ffi.so

"$ROOT_DIR/apps/mobile/android/gradlew" \
  -p "$ROOT_DIR/apps/android" \
  :app:assembleDebug \
  "$@"
