#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "iOS build and static verification"
echo "  root: $ROOT_DIR"
flutter --version
xcodebuild -version

# 作者: long
# iOS 日常验证先收拢为无签名、非前台流程，确保不依赖真机证书也能稳定证明代码可分析、可测试、可构建。
npm run mobile:analyze
npm run mobile:test
npm run mobile:ios:simulator
npm run mobile:ios:simulator:verify
npm run mobile:ios
npm run mobile:ios:verify
npm run verify:mobile-url-schemes

echo "iOS build and static verification passed"
