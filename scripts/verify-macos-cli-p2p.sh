#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_RESOURCES_DIR="$ROOT_DIR/../local_protocol_resources"
TRACKER_SCRIPT="$LOCAL_RESOURCES_DIR/local_bt_tracker.py"
FLUXDOWN_BIN_PATH=""

if [[ ! -f "$TRACKER_SCRIPT" ]]; then
  echo "missing local tracker script: $TRACKER_SCRIPT" >&2
  exit 1
fi

for tool in python3 transmission-create transmission-daemon transmission-remote transmission-show shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

if [[ -n "${FLUXDOWN_BIN:-}" ]]; then
  FLUXDOWN_BIN_PATH="$FLUXDOWN_BIN"
  if [[ "$FLUXDOWN_BIN_PATH" != /* ]]; then
    FLUXDOWN_BIN_PATH="$ROOT_DIR/$FLUXDOWN_BIN_PATH"
  fi
  if [[ ! -x "$FLUXDOWN_BIN_PATH" ]]; then
    echo "FLUXDOWN_BIN is not executable: $FLUXDOWN_BIN_PATH" >&2
    exit 1
  fi
else
  if ! command -v cargo >/dev/null 2>&1; then
    echo "missing required tool: cargo" >&2
    exit 1
  fi
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-cli-p2p.XXXXXX")"
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

fluxdown() {
  if [[ -n "$FLUXDOWN_BIN_PATH" ]]; then
    "$FLUXDOWN_BIN_PATH" "$@"
  else
    cargo run --quiet -p fluxdown-cli -- "$@"
  fi
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, expression = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
for part in expression.split("."):
    if part.isdigit():
        data = data[int(part)]
    else:
        data = data[part]
print(data)
PY
}

assert_json_value() {
  local file="$1"
  local expression="$2"
  local expected="$3"
  local actual
  actual="$(json_get "$file" "$expression")"
  if [[ "$actual" != "$expected" ]]; then
    echo "expected $expression to be '$expected', got '$actual'" >&2
    echo "json file: $file" >&2
    exit 1
  fi
}

assert_task_value() {
  local file="$1"
  local task_id="$2"
  local field="$3"
  local expected="$4"
  python3 - "$file" "$task_id" "$field" "$expected" <<'PY'
import json
import sys

path, task_id, field, expected = sys.argv[1:]
with open(path, "r", encoding="utf-8") as handle:
    tasks = json.load(handle)
for task in tasks:
    if task.get("id") == task_id:
        actual = str(task.get(field))
        if actual != expected:
            raise SystemExit(
                f"expected task {task_id} field {field} to be {expected!r}, got {actual!r}"
            )
        raise SystemExit(0)
raise SystemExit(f"task {task_id} not found in {path}")
PY
}

assert_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "sha256 mismatch for $file: expected $expected, got $actual" >&2
    exit 1
  fi
}

TRACKER_PORT="$(free_port)"
RPC_PORT="$(free_port)"
PEER_PORT="$(free_port)"
SEED_DIR="$TMP_DIR/seed"
CONFIG_DIR="$TMP_DIR/transmission"
TORRENT_OUT="$TMP_DIR/downloads/torrent"
MAGNET_OUT="$TMP_DIR/downloads/magnet"
SELECTED_OUT="$TMP_DIR/downloads/selected"
STORE="$TMP_DIR/queue.json"
mkdir -p "$SEED_DIR" "$CONFIG_DIR" "$TORRENT_OUT" "$MAGNET_OUT" "$SELECTED_OUT"

SAMPLE_NAME="fluxdown-cli-p2p-sample.txt"
SAMPLE_FILE="$SEED_DIR/$SAMPLE_NAME"
TORRENT_FILE="$TMP_DIR/fluxdown-cli-p2p-sample.torrent"
MULTI_NAME="fluxdown-cli-p2p-bundle"
MULTI_DIR="$SEED_DIR/$MULTI_NAME"
SELECTED_NAME="a-selected.bin"
SKIPPED_NAME="b-skipped.bin"
MULTI_TORRENT_FILE="$TMP_DIR/fluxdown-cli-p2p-bundle.torrent"
TRACKER_URL="http://127.0.0.1:$TRACKER_PORT/announce"

printf 'fluxdown cli p2p sample\n' > "$SAMPLE_FILE"
EXPECTED_SHA256="$(shasum -a 256 "$SAMPLE_FILE" | awk '{print $1}')"
mkdir -p "$MULTI_DIR"
python3 - "$MULTI_DIR/$SELECTED_NAME" "$MULTI_DIR/$SKIPPED_NAME" <<'PY'
import pathlib
import sys

selected, skipped = (pathlib.Path(path) for path in sys.argv[1:])
selected.write_bytes(bytes(index % 251 for index in range(64 * 1024)))
skipped.write_bytes(bytes((index * 7) % 251 for index in range(64 * 1024)))
PY
SELECTED_SHA256="$(shasum -a 256 "$MULTI_DIR/$SELECTED_NAME" | awk '{print $1}')"

transmission-create \
  -o "$TORRENT_FILE" \
  -t "$TRACKER_URL" \
  "$SAMPLE_FILE" >/dev/null
transmission-create \
  -o "$MULTI_TORRENT_FILE" \
  -s 32 \
  -t "$TRACKER_URL" \
  "$MULTI_DIR" >/dev/null

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
transmission-remote "127.0.0.1:$RPC_PORT" -a "$MULTI_TORRENT_FILE" >/dev/null
transmission-remote "127.0.0.1:$RPC_PORT" -t all --reannounce >/dev/null

echo "macOS CLI P2P fixture"
echo "  torrent: $TORRENT_FILE"
echo "  multi:   $MULTI_TORRENT_FILE"
echo "  magnet:  $MAGNET_URI"
echo "  sha256:  $EXPECTED_SHA256"
echo "  selected sha256: $SELECTED_SHA256"
if [[ -n "$FLUXDOWN_BIN_PATH" ]]; then
  echo "  binary:  $FLUXDOWN_BIN_PATH"
else
  echo "  binary:  cargo run -p fluxdown-cli"
fi

cd "$ROOT_DIR"

TORRENT_ADD="$TMP_DIR/torrent-add.json"
TORRENT_RUN="$TMP_DIR/torrent-run.json"
TORRENT_LIST="$TMP_DIR/torrent-list.json"
fluxdown --store "$STORE" add "$TORRENT_FILE" --output "$TORRENT_OUT" --name queued-sample.torrent > "$TORRENT_ADD"
TORRENT_ID="$(json_get "$TORRENT_ADD" "id")"
fluxdown --store "$STORE" run --concurrency 1 --retry-attempts 1 > "$TORRENT_RUN"
fluxdown --store "$STORE" list > "$TORRENT_LIST"
assert_json_value "$TORRENT_RUN" "started" "1"
assert_json_value "$TORRENT_RUN" "finished" "1"
assert_task_value "$TORRENT_LIST" "$TORRENT_ID" "state" "finished"
assert_task_value "$TORRENT_LIST" "$TORRENT_ID" "file_name" "$SAMPLE_NAME"
assert_sha256 "$TORRENT_OUT/$SAMPLE_NAME" "$EXPECTED_SHA256"

MAGNET_ADD="$TMP_DIR/magnet-add.json"
MAGNET_START="$TMP_DIR/magnet-start.json"
MAGNET_LIST="$TMP_DIR/magnet-list.json"
fluxdown --store "$STORE" add "$MAGNET_URI" --output "$MAGNET_OUT" --name magnet-download > "$MAGNET_ADD"
MAGNET_ID="$(json_get "$MAGNET_ADD" "id")"
fluxdown --store "$STORE" start "$MAGNET_ID" --retry-attempts 1 > "$MAGNET_START"
fluxdown --store "$STORE" list > "$MAGNET_LIST"
assert_json_value "$MAGNET_START" "task.id" "$MAGNET_ID"
assert_json_value "$MAGNET_START" "task.state" "finished"
assert_json_value "$MAGNET_START" "task.file_name" "$SAMPLE_NAME"
assert_task_value "$MAGNET_LIST" "$MAGNET_ID" "state" "finished"
assert_task_value "$MAGNET_LIST" "$MAGNET_ID" "file_name" "$SAMPLE_NAME"
assert_sha256 "$MAGNET_OUT/$SAMPLE_NAME" "$EXPECTED_SHA256"

SELECT_ADD="$TMP_DIR/selected-add.json"
SELECT_RUN="$TMP_DIR/selected-run.json"
SELECT_LIST="$TMP_DIR/selected-list.json"
fluxdown --store "$STORE" add "$MULTI_TORRENT_FILE" \
  --output "$SELECTED_OUT" \
  --name selected-bundle.torrent \
  --torrent-file-index 0 \
  > "$SELECT_ADD"
SELECT_ID="$(json_get "$SELECT_ADD" "id")"
assert_json_value "$SELECT_ADD" "torrent_file_indices.0" "0"
fluxdown --store "$STORE" run --concurrency 1 --retry-attempts 1 > "$SELECT_RUN"
fluxdown --store "$STORE" list > "$SELECT_LIST"
assert_json_value "$SELECT_RUN" "started" "1"
assert_json_value "$SELECT_RUN" "finished" "1"
assert_task_value "$SELECT_LIST" "$SELECT_ID" "state" "finished"
assert_task_value "$SELECT_LIST" "$SELECT_ID" "file_name" "$SELECTED_NAME"
assert_sha256 "$SELECTED_OUT/$MULTI_NAME/$SELECTED_NAME" "$SELECTED_SHA256"
if [[ -s "$SELECTED_OUT/$MULTI_NAME/$SKIPPED_NAME" ]]; then
  echo "unselected torrent file was written: $SELECTED_OUT/$MULTI_NAME/$SKIPPED_NAME" >&2
  exit 1
fi

echo "macOS CLI P2P verification passed"
