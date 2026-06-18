#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-cli-ftp-ftps.XXXXXX")"
FTP_PID=""
FTPS_PID=""

cleanup() {
  set +e
  if [[ -n "$FTP_PID" ]]; then
    kill "$FTP_PID" >/dev/null 2>&1
    wait "$FTP_PID" >/dev/null 2>&1
  fi
  if [[ -n "$FTPS_PID" ]]; then
    kill "$FTPS_PID" >/dev/null 2>&1
    wait "$FTPS_PID" >/dev/null 2>&1
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for tool in cargo openssl python3 shasum wc; do
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
  local log_file="$3"
  local label="$4"
  local deadline=$((SECONDS + 15))
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
      echo "timed out waiting for $label fixture on $host:$port" >&2
      cat "$log_file" >&2 || true
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

write_fixture_server() {
  cat > "$TMP_DIR/ftp_fixture.py" <<'PY'
import argparse
import pathlib
import socket
import ssl
import threading


def recv_line(file):
    line = file.readline()
    if not line:
        return None
    return line.decode("utf-8", "replace").rstrip("\r\n")


def send_line(file, line):
    file.write((line + "\r\n").encode("utf-8"))
    file.flush()


def serve_data(listener, payload, tls_context):
    data, _ = listener.accept()
    wrapped = tls_context is not None
    try:
        if wrapped:
            data = tls_context.wrap_socket(data, server_side=True)
        data.sendall(payload)
        if wrapped:
            # 作者: long
            # FTPS 客户端使用 rustls，会把缺少 close_notify 的数据连接视为异常；fixture 要模拟正常服务器收尾。
            data = data.unwrap()
    finally:
        try:
            data.close()
        except OSError:
            pass


def handle_client(conn, args, payload):
    tls_context = None
    data_tls = None
    control_tls = False
    if args.tls:
        tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls_context.load_cert_chain(args.certfile, args.keyfile)

    file = conn.makefile("rwb", buffering=0)
    send_line(file, "220 FluxDown fixture FTP")
    passive_listener = None

    while True:
        command = recv_line(file)
        if command is None:
            break
        upper = command.upper()

        if upper == "AUTH TLS" and tls_context is not None:
            send_line(file, "234 Proceed with negotiation")
            file.close()
            conn = tls_context.wrap_socket(conn, server_side=True)
            control_tls = True
            file = conn.makefile("rwb", buffering=0)
        elif upper.startswith("USER "):
            send_line(file, "331 Password required")
        elif upper.startswith("PASS "):
            send_line(file, "230 Logged in")
        elif upper == "PBSZ 0":
            send_line(file, "200 PBSZ=0")
        elif upper == "PROT P":
            data_tls = tls_context
            send_line(file, "200 Protection set")
        elif upper == "SYST":
            send_line(file, "215 UNIX Type: L8")
        elif upper == "FEAT":
            # 作者: long
            # 这个本地 fixture 只声明 FluxDown 下载链路会使用的能力，避免把目录遍历等未验证语义混进下载闭环。
            send_line(file, "211-Features")
            send_line(file, " SIZE")
            send_line(file, " REST STREAM")
            if tls_context is not None:
                send_line(file, " AUTH TLS")
                send_line(file, " PBSZ")
                send_line(file, " PROT")
            send_line(file, "211 End")
        elif upper.startswith("OPTS ") or upper.startswith("TYPE "):
            send_line(file, "200 OK")
        elif upper.startswith("SIZE "):
            send_line(file, f"213 {len(payload)}")
        elif upper.startswith("REST "):
            send_line(file, "350 Restarting at requested offset")
        elif upper == "EPSV":
            passive_listener = socket.socket()
            passive_listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            passive_listener.bind(("127.0.0.1", 0))
            passive_listener.listen(1)
            port = passive_listener.getsockname()[1]
            send_line(file, f"229 Entering Extended Passive Mode (|||{port}|)")
        elif upper.startswith("RETR "):
            if passive_listener is None:
                send_line(file, "425 Use EPSV first")
                continue
            send_line(file, "150 Opening data connection")
            thread = threading.Thread(
                target=serve_data,
                args=(passive_listener, payload, data_tls),
                daemon=True,
            )
            thread.start()
            thread.join()
            passive_listener.close()
            passive_listener = None
            send_line(file, "226 Transfer complete")
        elif upper == "QUIT":
            send_line(file, "221 Bye")
            break
        else:
            send_line(file, "200 OK")

    try:
        file.close()
    except OSError:
        pass
    try:
        if control_tls:
            conn = conn.unwrap()
        conn.close()
    except OSError:
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--certfile")
    parser.add_argument("--keyfile")
    args = parser.parse_args()
    payload = pathlib.Path(args.file).read_bytes()

    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", args.port))
    listener.listen(8)
    print(f"ready 127.0.0.1:{args.port}", flush=True)
    while True:
        conn, _ = listener.accept()
        threading.Thread(target=handle_client, args=(conn, args, payload), daemon=True).start()


if __name__ == "__main__":
    main()
PY
}

verify_protocol() {
  local protocol="$1"
  local source="$2"
  local expected_size="$3"
  local expected_sha256="$4"
  local direct_dir="$5"
  local queue_dir="$6"
  local store="$7"

  local direct_json="$TMP_DIR/$protocol-direct.json"
  local add_json="$TMP_DIR/$protocol-add.json"
  local run_json="$TMP_DIR/$protocol-run.json"
  local list_json="$TMP_DIR/$protocol-list.json"

  mkdir -p "$direct_dir" "$queue_dir"
  fluxdown download "$source" \
    --output "$direct_dir" \
    --name "direct-$protocol.txt" \
    > "$direct_json"
  assert_json_value "$direct_json" "protocol" "$protocol"
  assert_json_value "$direct_json" "display_name" "direct-$protocol.txt"
  assert_json_value "$direct_json" "bytes_written" "$expected_size"
  assert_json_value "$direct_json" "total_bytes" "$expected_size"
  assert_sha256 "$direct_dir/direct-$protocol.txt" "$expected_sha256"

  fluxdown --store "$store" add "$source" \
    --output "$queue_dir" \
    --name "queue-$protocol.txt" \
    > "$add_json"
  local task_id
  task_id="$(json_get "$add_json" "id")"
  fluxdown --store "$store" run --concurrency 1 > "$run_json"
  fluxdown --store "$store" list > "$list_json"
  assert_json_value "$run_json" "started" "1"
  assert_json_value "$run_json" "finished" "1"
  assert_task_value "$list_json" "$task_id" "state" "finished"
  assert_task_value "$list_json" "$task_id" "file_name" "queue-$protocol.txt"
  assert_sha256 "$queue_dir/queue-$protocol.txt" "$expected_sha256"
}

write_fixture_server

FTP_PORT="$(free_port)"
FTPS_PORT="$(free_port)"
FIXTURE_DIR="$TMP_DIR/fixtures"
DOWNLOAD_DIR="$TMP_DIR/downloads"
STORE="$TMP_DIR/queue.json"
mkdir -p "$FIXTURE_DIR" "$DOWNLOAD_DIR"

FTP_FILE="$FIXTURE_DIR/ftp-sample.txt"
FTPS_FILE="$FIXTURE_DIR/ftps-sample.txt"
printf 'fluxdown cli ftp sample\n' > "$FTP_FILE"
printf 'fluxdown cli ftps sample\n' > "$FTPS_FILE"
FTP_SIZE="$(wc -c < "$FTP_FILE" | tr -d ' ')"
FTPS_SIZE="$(wc -c < "$FTPS_FILE" | tr -d ' ')"
FTP_SHA256="$(shasum -a 256 "$FTP_FILE" | awk '{print $1}')"
FTPS_SHA256="$(shasum -a 256 "$FTPS_FILE" | awk '{print $1}')"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_DIR/ftps.key" \
  -out "$TMP_DIR/ftps.crt" \
  -days 1 \
  -subj "/CN=127.0.0.1" >/dev/null 2>&1

python3 "$TMP_DIR/ftp_fixture.py" \
  --port "$FTP_PORT" \
  --file "$FTP_FILE" \
  > "$TMP_DIR/ftp.log" 2>&1 &
FTP_PID="$!"
wait_for_tcp 127.0.0.1 "$FTP_PORT" "$TMP_DIR/ftp.log" "FTP"

python3 "$TMP_DIR/ftp_fixture.py" \
  --port "$FTPS_PORT" \
  --file "$FTPS_FILE" \
  --tls \
  --certfile "$TMP_DIR/ftps.crt" \
  --keyfile "$TMP_DIR/ftps.key" \
  > "$TMP_DIR/ftps.log" 2>&1 &
FTPS_PID="$!"
wait_for_tcp 127.0.0.1 "$FTPS_PORT" "$TMP_DIR/ftps.log" "FTPS"

FTP_SOURCE="ftp://flux:fluxpass@127.0.0.1:$FTP_PORT/ftp-sample.txt"
FTPS_SOURCE="ftps://flux:fluxpass@127.0.0.1:$FTPS_PORT/ftps-sample.txt?allowBadCertificate=true"

echo "macOS CLI FTP/FTPS fixture"
echo "  ftp:        $FTP_SOURCE"
echo "  ftp sha:    $FTP_SHA256"
echo "  ftps:       $FTPS_SOURCE"
echo "  ftps sha:   $FTPS_SHA256"

cd "$ROOT_DIR"

verify_protocol "ftp" "$FTP_SOURCE" "$FTP_SIZE" "$FTP_SHA256" \
  "$DOWNLOAD_DIR/ftp-direct" \
  "$DOWNLOAD_DIR/ftp-queue" \
  "$STORE"

verify_protocol "ftps" "$FTPS_SOURCE" "$FTPS_SIZE" "$FTPS_SHA256" \
  "$DOWNLOAD_DIR/ftps-direct" \
  "$DOWNLOAD_DIR/ftps-queue" \
  "$STORE"

echo "macOS CLI FTP/FTPS verification passed"
