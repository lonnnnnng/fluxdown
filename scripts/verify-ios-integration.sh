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

select_ios_device() {
  node - "$DEVICES_JSON" <<'NODE'
const fs = require('node:fs');
const devices = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const requested = process.env.FLUXDOWN_IOS_DEVICE_ID?.trim();
const canBootSimulator = process.env.FLUXDOWN_IOS_BOOT_SIMULATOR === '1';
let device;
if (requested) {
  device = devices.find((item) => item.id === requested || item.name === requested);
  if (!device) {
    if (canBootSimulator) {
      process.exit(2);
    }
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
}

set +e
DEVICE_LINE="$(select_ios_device)"
DEVICE_STATUS=$?
set -e

if [ "$DEVICE_STATUS" -eq 2 ] && [ "${FLUXDOWN_IOS_BOOT_SIMULATOR:-0}" = "1" ]; then
  SIMCTL_DEVICES_JSON="$TMP_DIR/simctl-devices.json"
  xcrun simctl list devices available --json > "$SIMCTL_DEVICES_JSON"
  set +e
  BOOT_LINE="$(node - "$SIMCTL_DEVICES_JSON" <<'NODE'
const fs = require('node:fs');
const data = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const requested = process.env.FLUXDOWN_IOS_DEVICE_ID?.trim();

const candidates = [];
for (const [runtime, devices] of Object.entries(data.devices ?? {})) {
  if (!runtime.includes('iOS')) {
    continue;
  }
  for (const device of devices) {
    if (device.isAvailable === false) {
      continue;
    }
    candidates.push({ ...device, runtime });
  }
}

let device;
if (requested) {
  device = candidates.find((item) => item.udid === requested || item.name === requested);
  if (!device) {
    console.error(`Requested iOS simulator was not found: ${requested}`);
    process.exit(3);
  }
} else {
  device =
    candidates.find((item) => item.state === 'Booted' && item.name.startsWith('iPhone')) ??
    candidates.find((item) => item.name === 'iPhone 16 Pro') ??
    candidates.find((item) => item.name.startsWith('iPhone')) ??
    candidates[0];
}

if (!device) {
  process.exit(2);
}

process.stdout.write([device.udid, device.name, device.state].join('\t'));
NODE
)"
  BOOT_STATUS=$?
  set -e
  if [ "$BOOT_STATUS" -eq 2 ]; then
    DEVICE_STATUS=2
  elif [ "$BOOT_STATUS" -ne 0 ]; then
    exit "$BOOT_STATUS"
  else
    IFS=$'\t' read -r BOOT_UDID BOOT_NAME BOOT_STATE <<< "$BOOT_LINE"
    echo "  boot simulator: $BOOT_NAME ($BOOT_UDID, $BOOT_STATE)"
    if [ "$BOOT_STATE" != "Booted" ]; then
      # 作者: long
      # 只有显式开启 FLUXDOWN_IOS_BOOT_SIMULATOR 时才通过 simctl 启动模拟器，默认路径不会抢占用户前台。
      xcrun simctl boot "$BOOT_UDID"
      xcrun simctl bootstatus "$BOOT_UDID" -b
    fi
    (
      cd apps/mobile
      flutter devices --machine > "$DEVICES_JSON"
    )
    set +e
    DEVICE_LINE="$(select_ios_device)"
    DEVICE_STATUS=$?
    set -e
  fi
fi

if [ "$DEVICE_STATUS" -eq 2 ]; then
  cat >&2 <<'EOF'
iOS integration target is not available.

Start an iOS simulator manually or connect an iPhone, then rerun:
  npm run verify:ios:integration

Optional environment:
  FLUXDOWN_IOS_DEVICE_ID=<device-id-or-name>
  FLUXDOWN_E2E_HOST=<mac-lan-ip-for-physical-iphone>
  FLUXDOWN_IOS_BOOT_SIMULATOR=1

By default this script does not boot Simulator.app, so it will not steal the foreground UI.
Set FLUXDOWN_IOS_BOOT_SIMULATOR=1 only when a background simulator boot is acceptable.
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
HLS_BYTERANGE_AVAILABLE=0
HLS_TS_AVAILABLE=0
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -hide_banner -loglevel error \
    -f lavfi -i testsrc=size=160x90:rate=15 \
    -t 1 \
    -c:v libx264 \
    -pix_fmt yuv420p \
    -f hls \
    -hls_segment_type fmp4 \
    -hls_fmp4_init_filename init.mp4 \
    -hls_time 1 \
    -hls_playlist_type vod \
    -hls_segment_filename "$TMP_DIR/hls/seg_%03d.m4s" \
    "$TMP_DIR/hls/index.m3u8"
  HLS_AVAILABLE=1

  if [ "${FLUXDOWN_IOS_INCLUDE_TS_HLS:-0}" = "1" ]; then
    mkdir -p "$TMP_DIR/hls-ts"
    # 作者: long
    # TS HLS 走 iOS 原生 remux 通道，目前属于专项探针；默认不纳入 smoke，避免 AVFoundation 已知限制让日常验证变红。
    ffmpeg -hide_banner -loglevel error \
      -f lavfi -i testsrc=size=160x90:rate=15 \
      -f lavfi -i sine=frequency=1000:sample_rate=44100 \
      -t 1 \
      -shortest \
      -c:v libx264 \
      -pix_fmt yuv420p \
      -c:a aac \
      -b:a 64k \
      -f hls \
      -hls_segment_type mpegts \
      -hls_time 1 \
      -hls_playlist_type vod \
      -hls_segment_filename "$TMP_DIR/hls-ts/seg_%03d.ts" \
      "$TMP_DIR/hls-ts/index.m3u8"
    HLS_TS_AVAILABLE=1
  fi

  SEGMENT_FILES=("$TMP_DIR"/hls/seg_*.m4s)
  if [ -f "$TMP_DIR/hls/init.mp4" ] && [ -e "${SEGMENT_FILES[0]}" ]; then
    mkdir -p "$TMP_DIR/hls-byterange"
    BYTERANGE_MEDIA="$TMP_DIR/hls-byterange/media.mp4"
    # 作者: long
    # iOS 自检需要覆盖单文件 fMP4 HLS，BYTERANGE 场景会把 init 和 m4s 片段放进同一个资源并强制客户端发起 Range 请求。
    cat "$TMP_DIR/hls/init.mp4" "${SEGMENT_FILES[@]}" > "$BYTERANGE_MEDIA"
    INIT_BYTES="$(wc -c < "$TMP_DIR/hls/init.mp4" | tr -d ' ')"
    OFFSET="$INIT_BYTES"
    {
      printf '%s\n' '#EXTM3U'
      printf '%s\n' '#EXT-X-VERSION:7'
      printf '#EXT-X-MAP:URI="media.mp4",BYTERANGE="%s@0"\n' "$INIT_BYTES"
      for segment_file in "${SEGMENT_FILES[@]}"; do
        SEGMENT_BYTES="$(wc -c < "$segment_file" | tr -d ' ')"
        printf '%s\n' '#EXTINF:1,'
        printf '#EXT-X-BYTERANGE:%s@%s\n' "$SEGMENT_BYTES" "$OFFSET"
        printf '%s\n' 'media.mp4'
        OFFSET=$((OFFSET + SEGMENT_BYTES))
      done
      printf '%s\n' '#EXT-X-ENDLIST'
    } > "$TMP_DIR/hls-byterange/index.m3u8"
    HLS_BYTERANGE_AVAILABLE=1
  fi
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
  node - "$BASE_URL" "$HTTP_BYTES" "$HTTP_TEXT" "$HLS_AVAILABLE" "$HLS_BYTERANGE_AVAILABLE" "$HLS_TS_AVAILABLE" <<'NODE'
const [baseUrl, httpBytes, httpText, hlsAvailable, hlsByteRangeAvailable, hlsTsAvailable] = process.argv.slice(2);
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

if (hlsByteRangeAvailable === '1') {
  cases.push({
    id: 'ios-hls-byterange-local',
    source: `${baseUrl}/hls-byterange/index.m3u8`,
    fileName: 'ios-hls-byterange.mp4',
    maxBytes: 10 * 1024 * 1024,
    expectedHeadHexContains: '66747970',
    timeoutSeconds: 120,
  });
}

if (hlsTsAvailable === '1') {
  cases.push({
    id: 'ios-hls-ts-local',
    source: `${baseUrl}/hls-ts/index.m3u8`,
    fileName: 'ios-hls-ts.mp4',
    maxBytes: 10 * 1024 * 1024,
    expectedHeadHexContains: '66747970',
    timeoutSeconds: 120,
  });
}

process.stdout.write(JSON.stringify(cases));
NODE
)"

echo "  fixture: $BASE_URL"
if [ "$DEVICE_KIND" = "simulator" ]; then
  (
    cd apps/mobile
    flutter build ios --simulator \
      --dart-define=FLUXDOWN_E2E_AUTO_RUN=true \
      --dart-define=FLUXDOWN_E2E_CASES_JSON="$CASES_JSON"
  )

  STAGED_APP="$TMP_DIR/Runner.app"
  xattr -cr apps/mobile/build/ios/iphonesimulator/Runner.app
  ditto --noextattr --norsrc apps/mobile/build/ios/iphonesimulator/Runner.app "$STAGED_APP"

  # 作者: long
  # CoreSimulator 覆盖安装 Flutter app 时偶发不返回，simulator 验证改为 staged app 干净安装后用控制台输出收集结构化结果。
  xcrun simctl uninstall "$DEVICE_ID" dev.fluxdown.mobile >/dev/null 2>&1 || true
  xcrun simctl install "$DEVICE_ID" "$STAGED_APP"

  APP_DATA_CONTAINER="$(xcrun simctl get_app_container "$DEVICE_ID" dev.fluxdown.mobile data)"
  E2E_OUTPUT_LOG="$APP_DATA_CONTAINER/tmp/fluxdown-e2e-output.log"
  rm -f "$E2E_OUTPUT_LOG"
  LAUNCH_LOG="$TMP_DIR/ios-launch.log"
  SIMCTL_CHILD_FLUXDOWN_E2E_OUTPUT_PATH="$E2E_OUTPUT_LOG" xcrun simctl launch \
    --console \
    --terminate-running-process \
    "$DEVICE_ID" \
    dev.fluxdown.mobile > "$LAUNCH_LOG" 2>&1 &
  LAUNCH_PID=$!
  LAUNCH_TIMED_OUT=0
  E2E_DONE=0
  for _ in {1..240}; do
    if [ -f "$E2E_OUTPUT_LOG" ] && grep -q '^FLUXDOWN_E2E_STATUS ' "$E2E_OUTPUT_LOG"; then
      E2E_DONE=1
      break
    fi
    if ! kill -0 "$LAUNCH_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if kill -0 "$LAUNCH_PID" >/dev/null 2>&1; then
    if [ "$E2E_DONE" -eq 1 ]; then
      xcrun simctl terminate "$DEVICE_ID" dev.fluxdown.mobile >/dev/null 2>&1 || true
    else
      LAUNCH_TIMED_OUT=1
      xcrun simctl terminate "$DEVICE_ID" dev.fluxdown.mobile >/dev/null 2>&1 || true
    fi
    kill "$LAUNCH_PID" >/dev/null 2>&1 || true
  fi
  set +e
  wait "$LAUNCH_PID"
  LAUNCH_STATUS=$?
  set -e
  if [ -s "$LAUNCH_LOG" ]; then
    cat "$LAUNCH_LOG"
  fi
  if [ -f "$E2E_OUTPUT_LOG" ]; then
    cat "$E2E_OUTPUT_LOG"
    RESULT_LOG="$E2E_OUTPUT_LOG"
  else
    RESULT_LOG="$LAUNCH_LOG"
  fi
  if [ "$LAUNCH_TIMED_OUT" -eq 1 ]; then
    echo "iOS simulator E2E app did not exit within 240 seconds." >&2
    exit 1
  fi
  if [ "$E2E_DONE" -eq 1 ]; then
    LAUNCH_STATUS=0
  fi
  if [ "$LAUNCH_STATUS" -ne 0 ]; then
    exit "$LAUNCH_STATUS"
  fi
  if ! grep -q '^FLUXDOWN_E2E_SUMMARY ' "$RESULT_LOG"; then
    echo "iOS simulator E2E app did not print FLUXDOWN_E2E_SUMMARY." >&2
    exit 1
  fi
  if grep -q '^FLUXDOWN_E2E_FATAL ' "$RESULT_LOG"; then
    exit 1
  fi
  if ! grep -q '^FLUXDOWN_E2E_STATUS .*"exitStatus":0' "$RESULT_LOG"; then
    echo "iOS simulator E2E app reported a failed status." >&2
    exit 1
  fi
else
  (
    cd apps/mobile
    flutter test integration_test/protocol_e2e_test.dart \
      -d "$DEVICE_ID" \
      --dart-define=FLUXDOWN_E2E_CASES_JSON="$CASES_JSON"
  )
fi

echo "iOS integration download verification passed"
