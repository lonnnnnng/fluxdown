#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-cli-http-hls.XXXXXX")"
SERVER_PID=""

cleanup() {
  set +e
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1
  fi
  wait >/dev/null 2>&1
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for tool in python3 shasum cargo; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

fluxdown() {
  cargo run --quiet -p fluxdown-cli -- "$@"
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

wait_for_server_log() {
  local log_file="$1"
  local deadline=$((SECONDS + 15))
  while ! grep -q 'http://127.0.0.1:' "$log_file"; do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for HTTP fixture server" >&2
      cat "$log_file" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

FIXTURE_DIR="$TMP_DIR/fixtures"
DOWNLOAD_DIR="$TMP_DIR/downloads"
STORE="$TMP_DIR/queue.json"
mkdir -p "$FIXTURE_DIR/hls" "$DOWNLOAD_DIR/direct-http" "$DOWNLOAD_DIR/queue-http" \
  "$DOWNLOAD_DIR/direct-hls" "$DOWNLOAD_DIR/queue-hls" "$DOWNLOAD_DIR/start-hls"

python3 - "$FIXTURE_DIR" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
payload = bytes(index % 251 for index in range(256 * 1024))
(root / "range.bin").write_bytes(payload)
(root / "hls" / "seg-1.ts").write_bytes(b"cli script hls segment one\n")
(root / "hls" / "seg-2.ts").write_bytes(b"cli script hls segment two\n")
(root / "hls" / "playlist.m3u8").write_text(
    "#EXTM3U\n"
    "#EXT-X-VERSION:3\n"
    "#EXTINF:1,\n"
    "seg-1.ts\n"
    "#EXTINF:1,\n"
    "seg-2.ts\n"
    "#EXT-X-ENDLIST\n",
    encoding="utf-8",
)
PY

HTTP_SHA256="$(shasum -a 256 "$FIXTURE_DIR/range.bin" | awk '{print $1}')"
HLS_SHA256="$(cat "$FIXTURE_DIR/hls/seg-1.ts" "$FIXTURE_DIR/hls/seg-2.ts" | shasum -a 256 | awk '{print $1}')"

SERVER_LOG="$TMP_DIR/http-server.log"
python3 "$ROOT_DIR/scripts/range-http-server.py" \
  --bind 127.0.0.1 \
  --port 0 \
  --directory "$FIXTURE_DIR" \
  > "$SERVER_LOG" 2>&1 &
SERVER_PID="$!"
wait_for_server_log "$SERVER_LOG"
BASE_URL="$(python3 - "$SERVER_LOG" <<'PY'
import re
import sys

text = open(sys.argv[1], "r", encoding="utf-8").read()
match = re.search(r"http://127\.0\.0\.1:\d+", text)
if not match:
    raise SystemExit("server URL not found")
print(match.group(0))
PY
)"

echo "macOS CLI HTTP/HLS fixture"
echo "  base:       $BASE_URL"
echo "  http sha:   $HTTP_SHA256"
echo "  hls sha:    $HLS_SHA256"

cd "$ROOT_DIR"

HTTP_DIRECT="$TMP_DIR/http-direct.json"
fluxdown download "$BASE_URL/range.bin" \
  --output "$DOWNLOAD_DIR/direct-http" \
  --name direct-http.bin \
  --threads 4 \
  > "$HTTP_DIRECT"
assert_json_value "$HTTP_DIRECT" "display_name" "direct-http.bin"
assert_json_value "$HTTP_DIRECT" "bytes_written" "262144"
assert_json_value "$HTTP_DIRECT" "total_bytes" "262144"
assert_sha256 "$DOWNLOAD_DIR/direct-http/direct-http.bin" "$HTTP_SHA256"

HTTP_ADD="$TMP_DIR/http-add.json"
HTTP_RUN="$TMP_DIR/http-run.json"
HTTP_LIST="$TMP_DIR/http-list.json"
fluxdown --store "$STORE" add "$BASE_URL/range.bin" \
  --output "$DOWNLOAD_DIR/queue-http" \
  --name queue-http.bin \
  > "$HTTP_ADD"
HTTP_ID="$(json_get "$HTTP_ADD" "id")"
fluxdown --store "$STORE" run --concurrency 1 --threads 4 > "$HTTP_RUN"
fluxdown --store "$STORE" list > "$HTTP_LIST"
assert_json_value "$HTTP_RUN" "started" "1"
assert_json_value "$HTTP_RUN" "finished" "1"
assert_task_value "$HTTP_LIST" "$HTTP_ID" "state" "finished"
assert_task_value "$HTTP_LIST" "$HTTP_ID" "file_name" "queue-http.bin"
assert_sha256 "$DOWNLOAD_DIR/queue-http/queue-http.bin" "$HTTP_SHA256"

HLS_DIRECT="$TMP_DIR/hls-direct.json"
fluxdown download "$BASE_URL/hls/playlist.m3u8" \
  --output "$DOWNLOAD_DIR/direct-hls" \
  --name direct-hls.m3u8 \
  > "$HLS_DIRECT"
assert_json_value "$HLS_DIRECT" "display_name" "direct-hls.ts"
assert_json_value "$HLS_DIRECT" "segments_written" "2"
assert_sha256 "$DOWNLOAD_DIR/direct-hls/direct-hls.ts" "$HLS_SHA256"

HLS_ADD="$TMP_DIR/hls-add.json"
HLS_RUN="$TMP_DIR/hls-run.json"
HLS_LIST="$TMP_DIR/hls-list.json"
fluxdown --store "$STORE" add "$BASE_URL/hls/playlist.m3u8" \
  --output "$DOWNLOAD_DIR/queue-hls" \
  --name queue-hls.m3u8 \
  > "$HLS_ADD"
HLS_ID="$(json_get "$HLS_ADD" "id")"
fluxdown --store "$STORE" run --concurrency 1 > "$HLS_RUN"
fluxdown --store "$STORE" list > "$HLS_LIST"
assert_json_value "$HLS_RUN" "started" "1"
assert_json_value "$HLS_RUN" "finished" "1"
assert_task_value "$HLS_LIST" "$HLS_ID" "state" "finished"
assert_task_value "$HLS_LIST" "$HLS_ID" "file_name" "queue-hls.ts"
assert_sha256 "$DOWNLOAD_DIR/queue-hls/queue-hls.ts" "$HLS_SHA256"

HLS_START_ADD="$TMP_DIR/hls-start-add.json"
HLS_START="$TMP_DIR/hls-start.json"
HLS_START_LIST="$TMP_DIR/hls-start-list.json"
fluxdown --store "$STORE" add "$BASE_URL/hls/playlist.m3u8" \
  --output "$DOWNLOAD_DIR/start-hls" \
  --name start-hls.m3u8 \
  > "$HLS_START_ADD"
HLS_START_ID="$(json_get "$HLS_START_ADD" "id")"
fluxdown --store "$STORE" start "$HLS_START_ID" > "$HLS_START"
fluxdown --store "$STORE" list > "$HLS_START_LIST"
assert_json_value "$HLS_START" "task.id" "$HLS_START_ID"
assert_json_value "$HLS_START" "task.state" "finished"
assert_json_value "$HLS_START" "task.file_name" "start-hls.ts"
assert_json_value "$HLS_START" "summary.segments_written" "2"
assert_task_value "$HLS_START_LIST" "$HLS_START_ID" "state" "finished"
assert_task_value "$HLS_START_LIST" "$HLS_START_ID" "file_name" "start-hls.ts"
assert_sha256 "$DOWNLOAD_DIR/start-hls/start-hls.ts" "$HLS_SHA256"

echo "macOS CLI HTTP/HLS verification passed"
