#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for tool in cargo npm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

echo "macOS desktop command verification"
echo "  root: $ROOT_DIR"

# 作者: long
# 这里验证的是不占前台的桌面客户端能力：Tauri command、协议 fixture、签名后的 .app/dmg 产物，不启动真实 GUI 窗口。
cargo test -p fluxdown-desktop
npm run desktop:dmg
npm run verify:macos-desktop-ftps
npm run verify:macos-desktop-sftp
npm run verify:macos-desktop-smb
npm run verify:macos-desktop-p2p
npm run verify:macos-artifacts

echo "macOS desktop command verification passed"
