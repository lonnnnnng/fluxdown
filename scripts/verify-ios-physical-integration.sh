#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-ios-physical.XXXXXX")"
DEVICES_JSON="$TMP_DIR/flutter-devices.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "iOS physical-device download verification"
echo "  root: $ROOT_DIR"

(
  cd apps/mobile
  flutter devices --machine > "$DEVICES_JSON"
)

set +e
DEVICE_LINE="$(
  node - "$DEVICES_JSON" <<'NODE'
const fs = require('node:fs');

const devices = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const requested = process.env.FLUXDOWN_IOS_DEVICE_ID?.trim();
const physical = devices.filter(
  (device) => device.targetPlatform === 'ios' && !device.emulator,
);

let device;
if (requested) {
  device = physical.find((item) => item.id === requested || item.name === requested);
} else {
  device = physical[0];
}

if (!device) {
  if (requested) {
    console.error(`Requested physical iPhone is not ready: ${requested}`);
  } else {
    console.error('No physical iPhone is ready for Flutter deployment.');
  }
  process.exit(78);
}

process.stdout.write([device.id, device.name].join('\t'));
NODE
)"
DEVICE_STATUS=$?
set -e

if [ "$DEVICE_STATUS" -ne 0 ]; then
  npm run verify:ios:device-readiness
  exit "$DEVICE_STATUS"
fi

IFS=$'\t' read -r DEVICE_ID DEVICE_NAME <<< "$DEVICE_LINE"

infer_lan_host() {
  if [ -n "${FLUXDOWN_E2E_HOST:-}" ]; then
    printf '%s\n' "$FLUXDOWN_E2E_HOST"
    return 0
  fi

  local default_iface
  default_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}' || true)"
  if [ -n "$default_iface" ]; then
    ipconfig getifaddr "$default_iface" 2>/dev/null && return 0
  fi

  local iface
  for iface in en0 en1 en2 en3 en4 bridge100; do
    ipconfig getifaddr "$iface" 2>/dev/null && return 0
  done

  return 1
}

set +e
LAN_HOST="$(infer_lan_host)"
HOST_STATUS=$?
set -e

if [ "$HOST_STATUS" -ne 0 ] || [ -z "$LAN_HOST" ]; then
  cat >&2 <<'EOF'
Physical iPhone verification needs a Mac LAN address.

Set it explicitly and rerun:
  FLUXDOWN_E2E_HOST=<mac-lan-ip> npm run verify:ios:physical-integration
EOF
  exit 79
fi

echo "  device: $DEVICE_NAME ($DEVICE_ID)"
echo "  host:   $LAN_HOST"

# 作者: long
# 真机不能访问 Mac 的 127.0.0.1，这个专用入口强制把 fixture 地址切到局域网 IP，避免误把 simulator smoke 当成 iPhone 验收。
export FLUXDOWN_IOS_DEVICE_ID="$DEVICE_ID"
export FLUXDOWN_E2E_HOST="$LAN_HOST"
export FLUXDOWN_IOS_INCLUDE_TS_HLS="${FLUXDOWN_IOS_INCLUDE_TS_HLS:-1}"

npm run verify:ios:integration
