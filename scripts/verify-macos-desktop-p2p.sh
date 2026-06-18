#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_RESOURCES_DIR="$ROOT_DIR/../local_protocol_resources"
TRACKER_SCRIPT="$LOCAL_RESOURCES_DIR/local_bt_tracker.py"

if [[ ! -f "$TRACKER_SCRIPT" ]]; then
  echo "missing local tracker script: $TRACKER_SCRIPT" >&2
  exit 1
fi

for tool in python3 transmission-create transmission-daemon transmission-remote transmission-show shasum cargo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-desktop-p2p.XXXXXX")"
TRACKER_PID=""
TRANSMISSION_PID=""
RPC_PORT=""

free_port() {
  python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

wait_for_url() {
  local url="$1"
  local deadline=$((SECONDS + 15))
  until python3 - "$url" <<'PY'
import sys
import urllib.request

try:
    with urllib.request.urlopen(sys.argv[1], timeout=1) as response:
        sys.exit(0 if response.status == 200 else 1)
except Exception:
    sys.exit(1)
PY
  do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for $url" >&2
      return 1
    fi
    sleep 0.2
  done
}

wait_for_transmission() {
  local endpoint="127.0.0.1:$RPC_PORT"
  local deadline=$((SECONDS + 20))
  until transmission-remote "$endpoint" -l >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for transmission RPC $endpoint" >&2
      return 1
    fi
    sleep 0.3
  done
}

cleanup() {
  set +e
  if [[ -n "$RPC_PORT" ]]; then
    transmission-remote "127.0.0.1:$RPC_PORT" --exit >/dev/null 2>&1
  fi
  if [[ -n "$TRANSMISSION_PID" ]]; then
    kill "$TRANSMISSION_PID" >/dev/null 2>&1
  fi
  if [[ -n "$TRACKER_PID" ]]; then
    kill "$TRACKER_PID" >/dev/null 2>&1
  fi
  wait >/dev/null 2>&1
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

TRACKER_PORT="$(free_port)"
RPC_PORT="$(free_port)"
PEER_PORT="$(free_port)"
SEED_DIR="$TMP_DIR/seed"
CONFIG_DIR="$TMP_DIR/transmission"
mkdir -p "$SEED_DIR" "$CONFIG_DIR"

SAMPLE_NAME="fluxdown-p2p-sample.txt"
SAMPLE_FILE="$SEED_DIR/$SAMPLE_NAME"
TORRENT_FILE="$TMP_DIR/fluxdown-p2p-sample.torrent"
TRACKER_URL="http://127.0.0.1:$TRACKER_PORT/announce"

printf 'fluxdown desktop p2p sample\n' > "$SAMPLE_FILE"
EXPECTED_SHA256="$(shasum -a 256 "$SAMPLE_FILE" | awk '{print $1}')"

transmission-create \
  -o "$TORRENT_FILE" \
  -t "$TRACKER_URL" \
  "$SAMPLE_FILE" >/dev/null

INFO_HASH="$(transmission-show "$TORRENT_FILE" | awk '/Hash v1:/ {print $3; exit}')"
TRACKER_ENCODED="$(python3 - "$TRACKER_URL" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)"
MAGNET_URI="magnet:?xt=urn:btih:$INFO_HASH&dn=$SAMPLE_NAME&tr=$TRACKER_ENCODED"

python3 "$TRACKER_SCRIPT" --host 127.0.0.1 --port "$TRACKER_PORT" \
  > "$TMP_DIR/tracker.log" 2>&1 &
TRACKER_PID="$!"
wait_for_url "http://127.0.0.1:$TRACKER_PORT/health"

transmission-daemon \
  -g "$CONFIG_DIR" \
  -w "$SEED_DIR" \
  -p "$RPC_PORT" \
  -P "$PEER_PORT" \
  -r 127.0.0.1 \
  -a 127.0.0.1 \
  --no-dht \
  --no-portmap \
  --foreground \
  > "$TMP_DIR/transmission.log" 2>&1 &
TRANSMISSION_PID="$!"
wait_for_transmission

transmission-remote "127.0.0.1:$RPC_PORT" -a "$TORRENT_FILE" >/dev/null
transmission-remote "127.0.0.1:$RPC_PORT" -t all --reannounce >/dev/null

echo "macOS desktop P2P fixture"
echo "  torrent: $TORRENT_FILE"
echo "  magnet:  $MAGNET_URI"
echo "  sha256:  $EXPECTED_SHA256"

cd "$ROOT_DIR"
FLUXDOWN_DESKTOP_P2P_TORRENT="$TORRENT_FILE" \
FLUXDOWN_DESKTOP_P2P_MAGNET="$MAGNET_URI" \
FLUXDOWN_DESKTOP_P2P_FILE_NAME="$SAMPLE_NAME" \
FLUXDOWN_DESKTOP_P2P_SHA256="$EXPECTED_SHA256" \
  cargo test -p fluxdown-desktop desktop_manual_downloads_single_file_torrent_through_queue -- --ignored --nocapture

# long: cargo test 的过滤是子串匹配，P2P 脚本只跑 magnet 用例，避免误触发 SFTP/SMB/FTPS 手动 fixture 测试。
FLUXDOWN_DESKTOP_P2P_TORRENT="$TORRENT_FILE" \
FLUXDOWN_DESKTOP_P2P_MAGNET="$MAGNET_URI" \
FLUXDOWN_DESKTOP_P2P_FILE_NAME="$SAMPLE_NAME" \
FLUXDOWN_DESKTOP_P2P_SHA256="$EXPECTED_SHA256" \
  cargo test -p fluxdown-desktop desktop_manual_starts_single_file_magnet_task -- --ignored --nocapture
