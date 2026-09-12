#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE_DIR="$ROOT_DIR/apps/mobile"
PLUGIN_DIR="$MOBILE_DIR/ios/.symlinks/plugins/libtorrent_flutter"
PLUGIN_PUBSPEC="$PLUGIN_DIR/pubspec.yaml"
XCFRAMEWORK_DIR="$PLUGIN_DIR/ios/libtorrent_flutter.xcframework"
SIMULATOR_DIR="$XCFRAMEWORK_DIR/ios-arm64_x86_64-simulator"
SIMULATOR_LIBRARY="$SIMULATOR_DIR/liblibtorrent_flutter.a"

if [[ ! -f "$PLUGIN_PUBSPEC" ]]; then
  echo "libtorrent_flutter plugin is not linked yet; run flutter pub get first." >&2
  exit 2
fi

PLUGIN_VERSION="$(awk '$1 == "version:" { print $2; exit }' "$PLUGIN_PUBSPEC" | tr -d '\r')"
if [[ -z "$PLUGIN_VERSION" ]]; then
  echo "Unable to determine libtorrent_flutter version from $PLUGIN_PUBSPEC." >&2
  exit 2
fi

if [[ -s "$SIMULATOR_LIBRARY" ]] && lipo -info "$SIMULATOR_LIBRARY" >/dev/null 2>&1; then
  echo "libtorrent_flutter iOS simulator slice is already present ($PLUGIN_VERSION)."
  exit 0
fi

# 作者: long
# pub.dev 包可能只带真机静态库，导致 Flutter 的 simulator 链接阶段找不到对应输入；这里补回同一 Git 标签中的官方模拟器 slice，保持设备与模拟器 ABI 隔离。
BASE_URL="https://raw.githubusercontent.com/ayman708-UX/libtorrent_flutter/v${PLUGIN_VERSION}/ios/libtorrent_flutter.xcframework"
mkdir -p "$SIMULATOR_DIR/Headers"

echo "Restoring libtorrent_flutter iOS simulator slice from $BASE_URL"
curl --fail --location --retry 3 --silent --show-error \
  "$BASE_URL/Info.plist" \
  --output "$XCFRAMEWORK_DIR/Info.plist"
curl --fail --location --retry 3 --silent --show-error \
  "$BASE_URL/ios-arm64_x86_64-simulator/liblibtorrent_flutter.a" \
  --output "$SIMULATOR_LIBRARY"
curl --fail --location --retry 3 --silent --show-error \
  "$BASE_URL/ios-arm64_x86_64-simulator/Headers/torrent_bridge.h" \
  --output "$SIMULATOR_DIR/Headers/torrent_bridge.h"

if [[ ! -s "$SIMULATOR_LIBRARY" ]]; then
  echo "Downloaded iOS simulator library is empty: $SIMULATOR_LIBRARY" >&2
  exit 1
fi

echo "Prepared libtorrent_flutter iOS simulator slice: $SIMULATOR_LIBRARY"
