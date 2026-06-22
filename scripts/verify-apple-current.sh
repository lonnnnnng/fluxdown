#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Apple current-stage verification"
echo "  root: $ROOT_DIR"

for tool in npm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

# 作者: long
# 当前阶段总验收显式串联构建/产物门禁和 iOS 运行态 smoke，避免只跑其中一半就误判 Apple 目标已经复验完整。
npm run verify:apple
npm run verify:apple:runtime

echo "Apple current-stage verification passed"
