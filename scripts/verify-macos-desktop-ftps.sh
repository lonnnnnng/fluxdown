#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-desktop-ftps.XXXXXX")"
FTPS_PID=""

cleanup() {
  set +e
  if [[ -n "$FTPS_PID" ]]; then
    kill "$FTPS_PID" >/dev/null 2>&1
    wait "$FTPS_PID" >/dev/null 2>&1
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for tool in cargo openssl python3 shasum; do
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
      echo "timed out waiting for FTPS fixture on $host:$port" >&2
      cat "$log_file" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

cat > "$TMP_DIR/ftps_fixture.py" <<'PY'
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
    try:
        data = tls_context.wrap_socket(data, server_side=True)
        data.sendall(payload)
        # 作者: long
        # rustls 会检查 FTPS 数据连接是否正常关闭；unwrap 会发送 close_notify，避免把 fixture 误判为传输错误。
        data = data.unwrap()
    finally:
        try:
            data.close()
        except OSError:
            pass


def handle_client(conn, args, payload):
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.load_cert_chain(args.certfile, args.keyfile)
    control_tls = False
    data_tls = None
    file = conn.makefile("rwb", buffering=0)
    send_line(file, "220 FluxDown fixture FTPS")
    passive_listener = None

    while True:
        command = recv_line(file)
        if command is None:
            break
        upper = command.upper()

        if upper == "AUTH TLS":
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
            # 桌面 FTPS 回归只覆盖下载链路所需能力，避免把目录浏览等未验证能力误写进证据。
            send_line(file, "211-Features")
            send_line(file, " SIZE")
            send_line(file, " REST STREAM")
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
    parser.add_argument("--certfile", required=True)
    parser.add_argument("--keyfile", required=True)
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

FTPS_PORT="$(free_port)"
FIXTURE_DIR="$TMP_DIR/fixtures"
mkdir -p "$FIXTURE_DIR"

export FLUXDOWN_DESKTOP_FTPS_FILE_NAME="desktop-ftps.txt"
printf 'fluxdown desktop ftps sample\n' > "$FIXTURE_DIR/$FLUXDOWN_DESKTOP_FTPS_FILE_NAME"
export FLUXDOWN_DESKTOP_FTPS_SHA256
FLUXDOWN_DESKTOP_FTPS_SHA256="$(shasum -a 256 "$FIXTURE_DIR/$FLUXDOWN_DESKTOP_FTPS_FILE_NAME" | awk '{print $1}')"
export FLUXDOWN_DESKTOP_FTPS_SOURCE="ftps://flux:fluxpass@127.0.0.1:$FTPS_PORT/$FLUXDOWN_DESKTOP_FTPS_FILE_NAME?allowBadCertificate=true"

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_DIR/ftps.key" \
  -out "$TMP_DIR/ftps.crt" \
  -days 1 \
  -subj "/CN=127.0.0.1" >/dev/null 2>&1

python3 "$TMP_DIR/ftps_fixture.py" \
  --port "$FTPS_PORT" \
  --file "$FIXTURE_DIR/$FLUXDOWN_DESKTOP_FTPS_FILE_NAME" \
  --certfile "$TMP_DIR/ftps.crt" \
  --keyfile "$TMP_DIR/ftps.key" \
  > "$TMP_DIR/ftps.log" 2>&1 &
FTPS_PID="$!"
wait_for_tcp 127.0.0.1 "$FTPS_PORT" "$TMP_DIR/ftps.log"

echo "macOS desktop FTPS fixture"
echo "  source: $FLUXDOWN_DESKTOP_FTPS_SOURCE"
echo "  file:   $FLUXDOWN_DESKTOP_FTPS_FILE_NAME"
echo "  sha256: $FLUXDOWN_DESKTOP_FTPS_SHA256"

cd "$ROOT_DIR"
cargo test -p fluxdown-desktop desktop_manual_downloads_ftps_task_through_queue -- --ignored --nocapture
