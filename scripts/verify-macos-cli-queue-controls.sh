#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-cli-queue-controls.XXXXXX")"
SERVER_PID=""
FLUXDOWN_BIN_PATH=""

cleanup() {
  set +e
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1
  fi
  wait >/dev/null 2>&1
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for tool in python3 shasum; do
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
if data is None:
    print("")
else:
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

assert_empty_tasks() {
  local file="$1"
  python3 - "$file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    tasks = json.load(handle)
if tasks:
    raise SystemExit(f"expected empty task list, got {tasks!r}")
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
      echo "timed out waiting for queue-control fixture server" >&2
      cat "$log_file" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

wait_for_task_progress() {
  local store="$1"
  local task_id="$2"
  local out_file="$3"
  local deadline=$((SECONDS + 20))
  while true; do
    fluxdown --store "$store" list > "$out_file"
    if python3 - "$out_file" "$task_id" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    tasks = json.load(handle)
for task in tasks:
    if task.get("id") == sys.argv[2] and task.get("state") == "running" and task.get("downloaded_bytes", 0) > 0:
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for task $task_id progress" >&2
      cat "$out_file" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

server_stat() {
  python3 - "$BASE_URL" "$1" <<'PY'
import json
import sys
import urllib.request

base_url, key = sys.argv[1:]
with urllib.request.urlopen(f"{base_url}/__stats", timeout=5) as response:
    data = json.load(response)
print(data[key])
PY
}

reset_server_stats() {
  python3 - "$BASE_URL" <<'PY'
import sys
import urllib.request

with urllib.request.urlopen(f"{sys.argv[1]}/__reset", timeout=5) as response:
    response.read()
PY
}

SERVER_LOG="$TMP_DIR/http-server.log"
python3 - "$TMP_DIR" > "$SERVER_LOG" 2>&1 <<'PY' &
import json
import pathlib
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = pathlib.Path(sys.argv[1])
payloads = {
    "/slow.bin": bytes(index % 251 for index in range(768 * 1024)),
    "/remove.bin": bytes((index * 3) % 251 for index in range(768 * 1024)),
    "/flaky.bin": b"fluxdown retry payload\n",
    "/parallel-a.bin": bytes(index % 199 for index in range(512 * 1024)),
    "/parallel-b.bin": bytes((index * 5) % 199 for index in range(512 * 1024)),
}
stats = {
    "flaky_requests": 0,
    "active_parallel": 0,
    "max_active_parallel": 0,
}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return

    def do_GET(self):
        if self.path == "/__stats":
            self.send_json()
            return
        if self.path == "/__reset":
            with lock:
                stats["active_parallel"] = 0
                stats["max_active_parallel"] = 0
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/flaky.bin":
            with lock:
                stats["flaky_requests"] += 1
                attempt = stats["flaky_requests"]
            if attempt == 1:
                body = b"temporary failure\n"
                self.send_response(500)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                return
        body = payloads.get(self.path)
        if body is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        is_parallel = self.path.startswith("/parallel-")
        if is_parallel:
            with lock:
                stats["active_parallel"] += 1
                stats["max_active_parallel"] = max(
                    stats["max_active_parallel"],
                    stats["active_parallel"],
                )
        try:
            self.send_payload(body)
        finally:
            if is_parallel:
                with lock:
                    stats["active_parallel"] -= 1

    def send_json(self):
        with lock:
            body = json.dumps(stats).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_payload(self, body):
        start = 0
        end = len(body) - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            raw_start, _, raw_end = range_header.removeprefix("bytes=").partition("-")
            start = int(raw_start or 0)
            end = int(raw_end or end)
            end = min(end, len(body) - 1)
            status = 206
        chunk = body[start : end + 1]
        self.send_response(status)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(chunk)))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(body)}")
        self.send_header("Connection", "close")
        self.end_headers()
        # 作者: long
        # 队列控制验证依赖任务处于可观察的运行窗口，fixture 故意慢速发送，才能稳定触发暂停、删除和并发槽位检查。
        chunks = list(range(0, len(chunk), 8192))
        for index, offset in enumerate(chunks):
            self.wfile.write(chunk[offset : offset + 8192])
            self.wfile.flush()
            if index + 1 < len(chunks):
                time.sleep(0.03)

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(f"http://127.0.0.1:{server.server_port}", flush=True)
server.serve_forever()
PY
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

DOWNLOAD_DIR="$TMP_DIR/downloads"
PAUSE_STORE="$TMP_DIR/pause-queue.json"
REMOVE_STORE="$TMP_DIR/remove-queue.json"
RETRY_STORE="$TMP_DIR/retry-queue.json"
mkdir -p "$DOWNLOAD_DIR/pause" "$DOWNLOAD_DIR/remove" "$DOWNLOAD_DIR/retry" "$DOWNLOAD_DIR/parallel-one" "$DOWNLOAD_DIR/parallel-two"

SLOW_SHA256="$(python3 - <<'PY' | shasum -a 256 | awk '{print $1}'
import sys
sys.stdout.buffer.write(bytes(index % 251 for index in range(768 * 1024)))
PY
)"
REMOVE_SHA256="$(python3 - <<'PY' | shasum -a 256 | awk '{print $1}'
import sys
sys.stdout.buffer.write(bytes((index * 3) % 251 for index in range(768 * 1024)))
PY
)"
FLAKY_SHA256="$(printf 'fluxdown retry payload\n' | shasum -a 256 | awk '{print $1}')"
PARALLEL_A_SHA256="$(python3 - <<'PY' | shasum -a 256 | awk '{print $1}'
import sys
sys.stdout.buffer.write(bytes(index % 199 for index in range(512 * 1024)))
PY
)"
PARALLEL_B_SHA256="$(python3 - <<'PY' | shasum -a 256 | awk '{print $1}'
import sys
sys.stdout.buffer.write(bytes((index * 5) % 199 for index in range(512 * 1024)))
PY
)"

echo "macOS CLI queue-control fixture"
echo "  base:       $BASE_URL"
if [[ -n "$FLUXDOWN_BIN_PATH" ]]; then
  echo "  binary:     $FLUXDOWN_BIN_PATH"
else
  echo "  binary:     cargo run -p fluxdown-cli"
fi

cd "$ROOT_DIR"

PAUSE_ADD="$TMP_DIR/pause-add.json"
PAUSE_START="$TMP_DIR/pause-start.json"
PAUSE_LIST="$TMP_DIR/pause-list.json"
PAUSE_RESUME="$TMP_DIR/pause-resume.json"
PAUSE_RUN="$TMP_DIR/pause-run.json"
fluxdown --store "$PAUSE_STORE" add "$BASE_URL/slow.bin" \
  --output "$DOWNLOAD_DIR/pause" \
  --name pause.bin \
  --sha256 "$SLOW_SHA256" \
  > "$PAUSE_ADD"
PAUSE_ID="$(json_get "$PAUSE_ADD" "id")"
fluxdown --store "$PAUSE_STORE" start "$PAUSE_ID" > "$PAUSE_START" 2> "$TMP_DIR/pause-start.err" &
PAUSE_PID="$!"
wait_for_task_progress "$PAUSE_STORE" "$PAUSE_ID" "$PAUSE_LIST"
fluxdown --store "$PAUSE_STORE" pause "$PAUSE_ID" > "$TMP_DIR/pause-command.json"
wait "$PAUSE_PID"
fluxdown --store "$PAUSE_STORE" list > "$PAUSE_LIST"
assert_task_value "$PAUSE_LIST" "$PAUSE_ID" "state" "paused"
fluxdown --store "$PAUSE_STORE" resume "$PAUSE_ID" > "$PAUSE_RESUME"
assert_json_value "$PAUSE_RESUME" "state" "queued"
fluxdown --store "$PAUSE_STORE" run --concurrency 1 --threads 4 > "$PAUSE_RUN"
fluxdown --store "$PAUSE_STORE" list > "$PAUSE_LIST"
assert_json_value "$PAUSE_RUN" "finished" "1"
assert_task_value "$PAUSE_LIST" "$PAUSE_ID" "state" "finished"
assert_sha256 "$DOWNLOAD_DIR/pause/pause.bin" "$SLOW_SHA256"

REMOVE_ADD="$TMP_DIR/remove-add.json"
REMOVE_LIST="$TMP_DIR/remove-list.json"
fluxdown --store "$REMOVE_STORE" add "$BASE_URL/remove.bin" \
  --output "$DOWNLOAD_DIR/remove" \
  --name remove.bin \
  --sha256 "$REMOVE_SHA256" \
  > "$REMOVE_ADD"
REMOVE_ID="$(json_get "$REMOVE_ADD" "id")"
fluxdown --store "$REMOVE_STORE" start "$REMOVE_ID" --speed-limit-mbps 0.05 > "$TMP_DIR/remove-start.json" 2> "$TMP_DIR/remove-start.err" &
REMOVE_PID="$!"
wait_for_task_progress "$REMOVE_STORE" "$REMOVE_ID" "$REMOVE_LIST"
fluxdown --store "$REMOVE_STORE" remove "$REMOVE_ID" > "$TMP_DIR/remove-command.json"
wait "$REMOVE_PID"
fluxdown --store "$REMOVE_STORE" list > "$REMOVE_LIST"
assert_empty_tasks "$REMOVE_LIST"

RETRY_ADD="$TMP_DIR/retry-add.json"
RETRY_RUN="$TMP_DIR/retry-run.json"
RETRY_LIST="$TMP_DIR/retry-list.json"
fluxdown --store "$RETRY_STORE" add "$BASE_URL/flaky.bin" \
  --output "$DOWNLOAD_DIR/retry" \
  --name retry.bin \
  --sha256 "$FLAKY_SHA256" \
  > "$RETRY_ADD"
RETRY_ID="$(json_get "$RETRY_ADD" "id")"
fluxdown --store "$RETRY_STORE" run --concurrency 1 --retry-attempts 1 > "$RETRY_RUN"
fluxdown --store "$RETRY_STORE" list > "$RETRY_LIST"
assert_json_value "$RETRY_RUN" "finished" "1"
assert_task_value "$RETRY_LIST" "$RETRY_ID" "state" "finished"
assert_sha256 "$DOWNLOAD_DIR/retry/retry.bin" "$FLAKY_SHA256"
if [[ "$(server_stat flaky_requests)" != "2" ]]; then
  echo "expected flaky fixture to be requested twice" >&2
  exit 1
fi

PARALLEL_ONE_STORE="$TMP_DIR/parallel-one.json"
PARALLEL_ONE_RUN="$TMP_DIR/parallel-one-run.json"
PARALLEL_ONE_LIST="$TMP_DIR/parallel-one-list.json"
reset_server_stats
fluxdown --store "$PARALLEL_ONE_STORE" add "$BASE_URL/parallel-a.bin" \
  --output "$DOWNLOAD_DIR/parallel-one" \
  --name parallel-a.bin \
  --sha256 "$PARALLEL_A_SHA256" \
  > "$TMP_DIR/parallel-one-a.json"
fluxdown --store "$PARALLEL_ONE_STORE" add "$BASE_URL/parallel-b.bin" \
  --output "$DOWNLOAD_DIR/parallel-one" \
  --name parallel-b.bin \
  --sha256 "$PARALLEL_B_SHA256" \
  > "$TMP_DIR/parallel-one-b.json"
fluxdown --store "$PARALLEL_ONE_STORE" run --concurrency 1 > "$PARALLEL_ONE_RUN"
fluxdown --store "$PARALLEL_ONE_STORE" list > "$PARALLEL_ONE_LIST"
assert_json_value "$PARALLEL_ONE_RUN" "finished" "2"
assert_sha256 "$DOWNLOAD_DIR/parallel-one/parallel-a.bin" "$PARALLEL_A_SHA256"
assert_sha256 "$DOWNLOAD_DIR/parallel-one/parallel-b.bin" "$PARALLEL_B_SHA256"
PARALLEL_ONE_MAX_ACTIVE="$(server_stat max_active_parallel)"
if [[ "$PARALLEL_ONE_MAX_ACTIVE" != "1" ]]; then
  echo "expected concurrency=1 to keep one active parallel fixture request, got $PARALLEL_ONE_MAX_ACTIVE" >&2
  exit 1
fi

PARALLEL_TWO_STORE="$TMP_DIR/parallel-two.json"
PARALLEL_TWO_RUN="$TMP_DIR/parallel-two-run.json"
reset_server_stats
fluxdown --store "$PARALLEL_TWO_STORE" add "$BASE_URL/parallel-a.bin" \
  --output "$DOWNLOAD_DIR/parallel-two" \
  --name parallel-a.bin \
  --sha256 "$PARALLEL_A_SHA256" \
  > "$TMP_DIR/parallel-two-a.json"
fluxdown --store "$PARALLEL_TWO_STORE" add "$BASE_URL/parallel-b.bin" \
  --output "$DOWNLOAD_DIR/parallel-two" \
  --name parallel-b.bin \
  --sha256 "$PARALLEL_B_SHA256" \
  > "$TMP_DIR/parallel-two-b.json"
fluxdown --store "$PARALLEL_TWO_STORE" run --concurrency 2 > "$PARALLEL_TWO_RUN"
assert_json_value "$PARALLEL_TWO_RUN" "finished" "2"
assert_sha256 "$DOWNLOAD_DIR/parallel-two/parallel-a.bin" "$PARALLEL_A_SHA256"
assert_sha256 "$DOWNLOAD_DIR/parallel-two/parallel-b.bin" "$PARALLEL_B_SHA256"
PARALLEL_TWO_MAX_ACTIVE="$(server_stat max_active_parallel)"
if [[ "$PARALLEL_TWO_MAX_ACTIVE" != "2" ]]; then
  echo "expected concurrency=2 to run two active parallel fixture requests, got $PARALLEL_TWO_MAX_ACTIVE" >&2
  exit 1
fi

echo "macOS CLI queue-control verification passed"
