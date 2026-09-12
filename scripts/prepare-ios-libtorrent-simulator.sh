#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE_DIR="$ROOT_DIR/apps/mobile"
LINKED_PLUGIN_DIR="$MOBILE_DIR/ios/.symlinks/plugins/libtorrent_flutter"
LOCK_FILE="$MOBILE_DIR/pubspec.lock"

# 作者: long
# CI 在执行 pod install 前通常还没有生成 ios/.symlinks；先从锁文件确定精确版本，
# 再回退到 Pub 缓存目录，确保补丁落在 Flutter 后续会链接的同一份插件包上。
PLUGIN_VERSION="$(awk '
  /^  libtorrent_flutter:/ { in_plugin = 1; next }
  in_plugin && /^  [^ ]/ { exit }
  in_plugin && /version:/ { gsub(/["\r]/, "", $2); print $2; exit }
' "$LOCK_FILE" 2>/dev/null)"
if [[ -z "$PLUGIN_VERSION" ]]; then
  PLUGIN_VERSION="$(awk '$1 == "version:" { print $2; exit }' "$MOBILE_DIR/pubspec.yaml" | tr -d '\r')"
fi
if [[ -z "$PLUGIN_VERSION" ]]; then
  echo "Unable to determine libtorrent_flutter version from $LOCK_FILE or pubspec.yaml." >&2
  exit 2
fi

if [[ -f "$LINKED_PLUGIN_DIR/pubspec.yaml" ]]; then
  PLUGIN_DIR="$LINKED_PLUGIN_DIR"
else
  PUB_CACHE_ROOT="${PUB_CACHE:-$HOME/.pub-cache}"
  PLUGIN_DIR="$PUB_CACHE_ROOT/hosted/pub.dev/libtorrent_flutter-${PLUGIN_VERSION}"
  if [[ ! -f "$PLUGIN_DIR/pubspec.yaml" ]]; then
    echo "libtorrent_flutter $PLUGIN_VERSION is not available in the Flutter plugin link or Pub cache." >&2
    exit 2
  fi
  echo "Flutter iOS plugin symlink is not generated yet; using Pub cache package $PLUGIN_DIR."
fi

XCFRAMEWORK_DIR="$PLUGIN_DIR/ios/libtorrent_flutter.xcframework"
DEVICE_DIR="$XCFRAMEWORK_DIR/ios-arm64"
DEVICE_LIBRARY="$DEVICE_DIR/liblibtorrent_flutter.a"
SIMULATOR_DIR="$XCFRAMEWORK_DIR/ios-arm64_x86_64-simulator"
SIMULATOR_LIBRARY="$SIMULATOR_DIR/liblibtorrent_flutter.a"

if [[ -s "$DEVICE_LIBRARY" ]] && lipo -info "$DEVICE_LIBRARY" >/dev/null 2>&1 \
  && [[ -s "$SIMULATOR_LIBRARY" ]] && lipo -info "$SIMULATOR_LIBRARY" >/dev/null 2>&1; then
  echo "libtorrent_flutter iOS device and simulator slices are already present ($PLUGIN_VERSION)."
  exit 0
fi

# 作者: long
# pub.dev 包不携带预编译 iOS XCFramework，Pods 阶段通常才会下载它；这里提前补齐同一 Git 标签中的 device 和 simulator slice，保证 simulator 与 unsigned device 两条流水线都能复用。
BASE_URL="https://raw.githubusercontent.com/ayman708-UX/libtorrent_flutter/v${PLUGIN_VERSION}/ios/libtorrent_flutter.xcframework"
mkdir -p "$DEVICE_DIR/Headers"
mkdir -p "$SIMULATOR_DIR/Headers"

echo "Restoring libtorrent_flutter iOS device and simulator slices from $BASE_URL"
if [[ ! -s "$XCFRAMEWORK_DIR/Info.plist" ]]; then
  curl --fail --location --retry 3 --silent --show-error \
    "$BASE_URL/Info.plist" \
    --output "$XCFRAMEWORK_DIR/Info.plist"
fi
if ! lipo -info "$DEVICE_LIBRARY" >/dev/null 2>&1; then
  curl --fail --location --retry 3 --silent --show-error \
    "$BASE_URL/ios-arm64/liblibtorrent_flutter.a" \
    --output "$DEVICE_LIBRARY"
  curl --fail --location --retry 3 --silent --show-error \
    "$BASE_URL/ios-arm64/Headers/torrent_bridge.h" \
    --output "$DEVICE_DIR/Headers/torrent_bridge.h"
fi
if ! lipo -info "$SIMULATOR_LIBRARY" >/dev/null 2>&1; then
  curl --fail --location --retry 3 --silent --show-error \
    "$BASE_URL/ios-arm64_x86_64-simulator/liblibtorrent_flutter.a" \
    --output "$SIMULATOR_LIBRARY"
  curl --fail --location --retry 3 --silent --show-error \
    "$BASE_URL/ios-arm64_x86_64-simulator/Headers/torrent_bridge.h" \
    --output "$SIMULATOR_DIR/Headers/torrent_bridge.h"
fi

if [[ ! -s "$DEVICE_LIBRARY" || ! -s "$SIMULATOR_LIBRARY" ]]; then
  echo "Downloaded iOS XCFramework slice is empty: $DEVICE_LIBRARY or $SIMULATOR_LIBRARY" >&2
  exit 1
fi

echo "Prepared libtorrent_flutter iOS device and simulator slices."
