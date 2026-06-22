#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-ios-integration.XXXXXX")"
SERVER_LOG="$TMP_DIR/server.log"
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "iOS integration download verification"
echo "  root: $ROOT_DIR"

DEVICES_JSON="$TMP_DIR/flutter-devices.json"
(
  cd apps/mobile
  flutter devices --machine > "$DEVICES_JSON"
)

set +e
DEVICE_LINE="$(node - "$DEVICES_JSON" <<'NODE'
const fs = require('node:fs');
const devices = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const requested = process.env.FLUXDOWN_IOS_DEVICE_ID?.trim();
let device;
if (requested) {
  device = devices.find((item) => item.id === requested || item.name === requested);
  if (!device) {
    console.error(`Requested iOS device was not found: ${requested}`);
    process.exit(3);
  }
  if (device.targetPlatform !== 'ios') {
    console.error(`Requested device is not an iOS target: ${device.name} (${device.targetPlatform})`);
    process.exit(4);
  }
} else {
  device =
    devices.find((item) => item.targetPlatform === 'ios' && item.emulator) ??
    devices.find((item) => item.targetPlatform === 'ios');
}

if (!device) {
  process.exit(2);
}

process.stdout.write([
  device.id,
  device.emulator ? 'simulator' : 'device',
  device.name,
].join('\t'));
NODE
)"
DEVICE_STATUS=$?
set -e

if [ "$DEVICE_STATUS" -eq 2 ]; then
  cat >&2 <<'EOF'
iOS integration target is not available.

Start an iOS simulator manually or connect an iPhone, then rerun:
  npm run verify:ios:integration

Optional environment:
  FLUXDOWN_IOS_DEVICE_ID=<device-id-or-name>
  FLUXDOWN_E2E_HOST=<mac-lan-ip-for-physical-iphone>

This script intentionally does not boot Simulator.app, so it will not steal the foreground UI.
EOF
  exit 78
fi
if [ "$DEVICE_STATUS" -ne 0 ]; then
  exit "$DEVICE_STATUS"
fi

IFS=$'\t' read -r DEVICE_ID DEVICE_KIND DEVICE_NAME <<< "$DEVICE_LINE"
# 作者: long
# 真机访问 Mac 本地 fixture 不能使用 127.0.0.1，物理设备必须走局域网地址，模拟器才复用 localhost。
if [ "$DEVICE_KIND" = "simulator" ]; then
  BIND_HOST="127.0.0.1"
  SOURCE_HOST="127.0.0.1"
else
  BIND_HOST="0.0.0.0"
  SOURCE_HOST="${FLUXDOWN_E2E_HOST:-}"
  if [ -z "$SOURCE_HOST" ]; then
    SOURCE_HOST="$(ipconfig getifaddr en0 2>/dev/null || true)"
  fi
  if [ -z "$SOURCE_HOST" ]; then
    SOURCE_HOST="$(ipconfig getifaddr en1 2>/dev/null || true)"
  fi
  if [ -z "$SOURCE_HOST" ]; then
    echo "Physical iPhone verification requires FLUXDOWN_E2E_HOST=<mac-lan-ip>." >&2
    exit 79
  fi
fi

echo "  device: $DEVICE_NAME ($DEVICE_ID, $DEVICE_KIND)"

HTTP_TEXT="fluxdown ios integration http"
printf '%s' "$HTTP_TEXT" > "$TMP_DIR/ios-http.txt"
HTTP_BYTES="$(wc -c < "$TMP_DIR/ios-http.txt" | tr -d ' ')"

mkdir -p "$TMP_DIR/hls"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -hide_banner -loglevel error \
    -f lavfi -i testsrc=size=160x90:rate=15 \
    -t 1 \
    -c:v libx264 \
    -pix_fmt yuv420p \
    -f hls \
    -hls_time 1 \
    -hls_playlist_type vod \
    -hls_segment_filename "$TMP_DIR/hls/seg_%03d.ts" \
    "$TMP_DIR/hls/index.m3u8"
  HLS_AVAILABLE=1
else
  echo "ffmpeg is not installed; HLS integration case will be skipped." >&2
  HLS_AVAILABLE=0
fi

python3 scripts/range-http-server.py \
  --bind "$BIND_HOST" \
  --port 0 \
  --directory "$TMP_DIR" > "$SERVER_LOG" 2>&1 &
SERVER_PID=$!

for _ in {1..50}; do
  if [ -s "$SERVER_LOG" ]; then
    break
  fi
  sleep 0.1
done

PORT="$(sed -n 's/^Serving .* on http:\/\/[^:]*:\([0-9][0-9]*\)$/\1/p' "$SERVER_LOG" | head -n 1)"
if [ -z "$PORT" ]; then
  echo "HTTP fixture did not start." >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

BASE_URL="http://$SOURCE_HOST:$PORT"
CASES_JSON="$(
  node - "$BASE_URL" "$HTTP_BYTES" "$HTTP_TEXT" "$HLS_AVAILABLE" <<'NODE'
const [baseUrl, httpBytes, httpText, hlsAvailable] = process.argv.slice(2);
const cases = [
  {
    id: 'ios-http-local',
    source: `${baseUrl}/ios-http.txt`,
    fileName: 'ios-http.txt',
    expectedBytes: Number(httpBytes),
    expectedText: httpText,
  },
];

if (hlsAvailable === '1') {
  cases.push({
    id: 'ios-hls-local',
    source: `${baseUrl}/hls/index.m3u8`,
    fileName: 'ios-hls.mp4',
    maxBytes: 10 * 1024 * 1024,
    expectedHeadHexContains: '66747970',
    timeoutSeconds: 120,
  });
}

process.stdout.write(JSON.stringify(cases));
NODE
)"

echo "  fixture: $BASE_URL"
(
  cd apps/mobile
  flutter test integration_test/protocol_e2e_test.dart \
    -d "$DEVICE_ID" \
    --dart-define=FLUXDOWN_E2E_CASES_JSON="$CASES_JSON"
)

echo "iOS integration download verification passed"
