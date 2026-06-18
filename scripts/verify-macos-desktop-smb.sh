#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fluxdown-desktop-smb.XXXXXX")"
CONTAINER_NAME="fluxdown-samba-desktop-$$"

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

SMB_PORT="$(free_port)"
SHARE_DIR="$TMP_DIR/share"
mkdir -p "$SHARE_DIR"

export FLUXDOWN_DESKTOP_SMB_FILE_NAME="desktop-smb.txt"
printf 'fluxdown desktop smb sample\n' > "$SHARE_DIR/$FLUXDOWN_DESKTOP_SMB_FILE_NAME"
export FLUXDOWN_DESKTOP_SMB_SHA256
FLUXDOWN_DESKTOP_SMB_SHA256="$(shasum -a 256 "$SHARE_DIR/$FLUXDOWN_DESKTOP_SMB_FILE_NAME" | awk '{print $1}')"
export FLUXDOWN_DESKTOP_SMB_SOURCE="smb://flux:fluxpass@127.0.0.1:$SMB_PORT/flux/$FLUXDOWN_DESKTOP_SMB_FILE_NAME"

docker run -d --name "$CONTAINER_NAME" \
  -p "127.0.0.1:$SMB_PORT:445" \
  -v "$SHARE_DIR:/share:ro" \
  dperson/samba \
  -u 'flux;fluxpass' \
  -s 'flux;/share;yes;no;no;flux' >/dev/null
wait_for_tcp 127.0.0.1 "$SMB_PORT"

echo "macOS desktop SMB fixture"
echo "  source: $FLUXDOWN_DESKTOP_SMB_SOURCE"
echo "  file:   $FLUXDOWN_DESKTOP_SMB_FILE_NAME"
echo "  sha256: $FLUXDOWN_DESKTOP_SMB_SHA256"

cd "$ROOT_DIR"
cargo test -p fluxdown-desktop desktop_manual_downloads_smb_task_through_queue -- --ignored --nocapture
