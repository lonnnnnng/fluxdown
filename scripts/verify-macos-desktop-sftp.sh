#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-desktop-sftp.XXXXXX")"
CONTAINER_NAME="fluxdown-sftp-desktop-$$"

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

wait_for_sftp_banner() {
  local host="$1"
  local port="$2"
  local deadline=$((SECONDS + 30))
  until python3 - "$host" "$port" <<'PY'
import socket
import sys

host, port = sys.argv[1], int(sys.argv[2])
try:
    with socket.create_connection((host, port), timeout=1) as sock:
        sock.settimeout(1)
        banner = sock.recv(256)
except OSError:
    sys.exit(1)
if not banner.startswith(b"SSH-"):
    sys.exit(1)
PY
  do
    if (( SECONDS >= deadline )); then
      echo "timed out waiting for SFTP fixture on $host:$port" >&2
      docker logs "$CONTAINER_NAME" >&2 || true
      return 1
    fi
    sleep 0.2
  done
}

SFTP_PORT="$(free_port)"
UPLOAD_DIR="$TMP_DIR/upload"
mkdir -p "$UPLOAD_DIR"

export FLUXDOWN_DESKTOP_SFTP_FILE_NAME="desktop-sftp.txt"
printf 'fluxdown desktop sftp sample\n' > "$UPLOAD_DIR/$FLUXDOWN_DESKTOP_SFTP_FILE_NAME"
export FLUXDOWN_DESKTOP_SFTP_SHA256
FLUXDOWN_DESKTOP_SFTP_SHA256="$(shasum -a 256 "$UPLOAD_DIR/$FLUXDOWN_DESKTOP_SFTP_FILE_NAME" | awk '{print $1}')"
export FLUXDOWN_DESKTOP_SFTP_SOURCE="sftp://flux:fluxpass@127.0.0.1:$SFTP_PORT/upload/$FLUXDOWN_DESKTOP_SFTP_FILE_NAME"

docker run -d --platform linux/amd64 --name "$CONTAINER_NAME" \
  -p "127.0.0.1:$SFTP_PORT:22" \
  -v "$UPLOAD_DIR:/home/flux/upload:ro" \
  atmoz/sftp \
  flux:fluxpass:::upload >/dev/null
# long: Docker 端口可连接不代表 SSHD 已准备好，等到 banner 后再交给 libssh2，避免偶发 Failed getting banner。
wait_for_sftp_banner 127.0.0.1 "$SFTP_PORT"

echo "macOS desktop SFTP fixture"
echo "  source: $FLUXDOWN_DESKTOP_SFTP_SOURCE"
echo "  file:   $FLUXDOWN_DESKTOP_SFTP_FILE_NAME"
echo "  sha256: $FLUXDOWN_DESKTOP_SFTP_SHA256"

cd "$ROOT_DIR"
cargo test -p fluxdown-desktop desktop_manual_downloads_sftp_task_through_queue -- --ignored --nocapture
