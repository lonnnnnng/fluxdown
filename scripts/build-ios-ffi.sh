#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
export PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$ROOT_DIR/target}"
PLATFORM_NAME="${PLATFORM_NAME:-iphoneos}"
ARCHS="${ARCHS:-arm64}"

case "$PLATFORM_NAME" in
  iphoneos|iphonesimulator) ;;
  *) echo "Unsupported iOS platform: $PLATFORM_NAME" >&2; exit 1 ;;
esac
export SDKROOT="$(xcrun --sdk "$PLATFORM_NAME" --show-sdk-path)"
OUTPUT_DIR="$ROOT_DIR/target/ffi-ios/$PLATFORM_NAME"
LIBRARIES=()

# 作者: long
# Rust 和 C 依赖必须使用 Runner 相同的最低 iOS 版本；默认 iOS 10 与新版 SDK 混用会导致链接符号缺失。
# 真机与模拟器即使同为 arm64 也不能共用产物，因此分别编译、分别存放。
for arch in $ARCHS; do
  case "$PLATFORM_NAME/$arch" in
    iphoneos/arm64) target=aarch64-apple-ios ;;
    iphonesimulator/arm64) target=aarch64-apple-ios-sim ;;
    iphonesimulator/x86_64) target=x86_64-apple-ios ;;
    *) echo "Unsupported iOS architecture: $PLATFORM_NAME/$arch" >&2; exit 1 ;;
  esac
  cargo rustc --locked --release -p fluxdown-ffi --target "$target" \
    --features fluxdown-core/vendored-openssl --crate-type staticlib
  LIBRARIES+=("$CARGO_TARGET_DIR/$target/release/libfluxdown_ffi.a")
done

mkdir -p "$OUTPUT_DIR"
if [ "${#LIBRARIES[@]}" -eq 1 ]; then
  cp "${LIBRARIES[0]}" "$OUTPUT_DIR/libfluxdown_ffi.a"
else
  xcrun lipo -create "${LIBRARIES[@]}" -output "$OUTPUT_DIR/libfluxdown_ffi.a"
fi
echo "iOS FFI ready: $OUTPUT_DIR/libfluxdown_ffi.a ($ARCHS, iOS $IPHONEOS_DEPLOYMENT_TARGET)"
