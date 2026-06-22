#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "Apple platform runtime verification"
echo "  root: $ROOT_DIR"

for tool in npm flutter xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

# 作者: long
# 运行态验收补足 verify:apple 的静态构建边界：默认只后台启动 simulator，不打开桌面 GUI，也不要求真实 iPhone 或签名材料必须就绪。
export FLUXDOWN_IOS_BOOT_SIMULATOR="${FLUXDOWN_IOS_BOOT_SIMULATOR:-1}"
export FLUXDOWN_IOS_INCLUDE_TS_HLS="${FLUXDOWN_IOS_INCLUDE_TS_HLS:-1}"
npm run verify:ios:integration

run_readiness_check() {
  local label="$1"
  shift
  set +e
  "$@"
  local code=$?
  set -e

  if [ "$code" -eq 0 ]; then
    echo "  $label: ready"
    return 0
  fi
  if [ "$code" -eq 78 ]; then
    echo "  $label: not ready yet (external condition, exit 78)"
    return 0
  fi

  echo "  $label: unexpected failure (exit $code)" >&2
  return "$code"
}

run_readiness_check "iOS physical device" npm run verify:ios:device-readiness
run_readiness_check "iOS signing inputs" npm run verify:ios:signing-readiness

echo "Apple platform runtime verification passed"
