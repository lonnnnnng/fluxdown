#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-cli-smb.XXXXXX")"
CONTAINER_NAME="fluxdown-samba-cli-$$"

cleanup() {
  set +e
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for tool in cargo docker python3 shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing required tool: $tool" >&2
    exit 1
  fi
done

free_port() {
  python3 - <<'PY'
import socket

sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local deadline=$((SECONDS + 30))
  until python3 - "$host" "$port" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=1):
        pass
except OSError:
    sys.exit(1)
PY
  do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for SMB fixture on $host:$port" >&2
      docker logs "$CONTAINER_NAME" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

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

SMB_PORT="$(free_port)"
SHARE_DIR="$TMP_DIR/share"
DIRECT_DIR="$TMP_DIR/downloads/direct"
QUEUE_DIR="$TMP_DIR/downloads/queue"
STORE="$TMP_DIR/queue.json"
mkdir -p "$SHARE_DIR" "$DIRECT_DIR" "$QUEUE_DIR"

SAMPLE_NAME="fluxdown-cli-smb-sample.txt"
printf 'fluxdown cli smb sample\n' > "$SHARE_DIR/$SAMPLE_NAME"
EXPECTED_SHA256="$(shasum -a 256 "$SHARE_DIR/$SAMPLE_NAME" | awk '{print $1}')"
SOURCE="smb://flux:fluxpass@127.0.0.1:$SMB_PORT/flux/$SAMPLE_NAME"

docker run -d --name "$CONTAINER_NAME" \
  -p "127.0.0.1:$SMB_PORT:445" \
  -v "$SHARE_DIR:/share:ro" \
  dperson/samba \
  -u 'flux;fluxpass' \
  -s 'flux;/share;yes;no;no;flux' >/dev/null
wait_for_tcp 127.0.0.1 "$SMB_PORT"

echo "macOS CLI SMB fixture"
echo "  source: $SOURCE"
echo "  sha256: $EXPECTED_SHA256"

cd "$ROOT_DIR"

DIRECT_JSON="$TMP_DIR/smb-direct.json"
fluxdown download "$SOURCE" \
  --output "$DIRECT_DIR" \
  --name direct-smb.txt \
  > "$DIRECT_JSON"
assert_json_value "$DIRECT_JSON" "protocol" "smb"
assert_json_value "$DIRECT_JSON" "display_name" "direct-smb.txt"
assert_json_value "$DIRECT_JSON" "bytes_written" "24"
assert_json_value "$DIRECT_JSON" "total_bytes" "24"
assert_sha256 "$DIRECT_DIR/direct-smb.txt" "$EXPECTED_SHA256"

ADD_JSON="$TMP_DIR/smb-add.json"
RUN_JSON="$TMP_DIR/smb-run.json"
LIST_JSON="$TMP_DIR/smb-list.json"
fluxdown --store "$STORE" add "$SOURCE" \
  --output "$QUEUE_DIR" \
  --name queue-smb.txt \
  > "$ADD_JSON"
TASK_ID="$(json_get "$ADD_JSON" "id")"
fluxdown --store "$STORE" run --concurrency 1 > "$RUN_JSON"
fluxdown --store "$STORE" list > "$LIST_JSON"
assert_json_value "$RUN_JSON" "started" "1"
assert_json_value "$RUN_JSON" "finished" "1"
assert_task_value "$LIST_JSON" "$TASK_ID" "state" "finished"
assert_task_value "$LIST_JSON" "$TASK_ID" "file_name" "queue-smb.txt"
assert_sha256 "$QUEUE_DIR/queue-smb.txt" "$EXPECTED_SHA256"

echo "macOS CLI SMB verification passed"
