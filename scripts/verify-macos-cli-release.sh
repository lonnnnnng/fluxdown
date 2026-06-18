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

echo "macOS release CLI verification"
echo "  root: $ROOT_DIR"

# 作者: long
# release CLI 验证必须先重新构建交付二进制，避免误用上一次构建残留导致报告和当前代码不一致。
cargo build -p fluxdown-cli --release

npm run verify:macos-cli-release-http-hls
npm run verify:macos-cli-release-ftp-ftps
npm run verify:macos-cli-release-sftp
npm run verify:macos-cli-release-smb
npm run verify:macos-cli-release-p2p
npm run verify:macos-cli-release-queue-controls
npm run verify:macos-artifacts

echo "macOS release CLI verification passed"
