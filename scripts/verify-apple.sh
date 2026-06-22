#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Apple platform non-GUI verification"
echo "  root: $ROOT_DIR"

for tool in cargo npm flutter xcodebuild; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

# 作者: long
# 当前目标聚焦 macOS 桌面/CLI 与 iOS 构建验证；这里明确只串联非前台入口，避免普通验收误启动 GUI 或设备 App。
npm run verify:macos
npm run verify:ios

echo "Apple platform non-GUI verification passed"
