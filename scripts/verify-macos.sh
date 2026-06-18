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

echo "macOS full non-GUI verification"
echo "  root: $ROOT_DIR"

# 作者: long
# 当前阶段不占用用户前台桌面；这里串起 macOS CLI 和桌面 command 层的质量门禁、真实下载 fixture、签名产物校验。
cargo fmt --check
cargo clippy -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop --all-targets -- -D warnings
cargo test -p fluxdown-core -p fluxdown-cli -p fluxdown-desktop
npm run verify:macos-cli-release
npm run verify:macos-desktop-command
npm run verify:licenses
npm run verify:ci-config

echo "macOS full non-GUI verification passed"
