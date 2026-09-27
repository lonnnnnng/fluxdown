#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_NAME="${USER:?USER is required for the local OpenSSH fixture}"
HOME_DIR="${HOME:?HOME is required for the local OpenSSH fixture}"
TMP_DIR="$(mktemp -d "$HOME_DIR/fluxdown-cli-sftp-jump.XXXXXX")"
JUMP_PID=""
TARGET_PID=""
SSH_AGENT_STARTED="false"
FLUXDOWN_BIN_PATH=""

cleanup() {
  set +e
  if [[ -n "$JUMP_PID" ]]; then
    kill "$JUMP_PID" >/dev/null 2>&1
    wait "$JUMP_PID" >/dev/null 2>&1
  fi
  if [[ -n "$TARGET_PID" ]]; then
    kill "$TARGET_PID" >/dev/null 2>&1
    wait "$TARGET_PID" >/dev/null 2>&1
  fi
  if [[ "$SSH_AGENT_STARTED" == "true" ]]; then
    ssh-agent -k >/dev/null 2>&1
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for tool in cargo python3 shasum ssh ssh-add ssh-agent ssh-keygen ssh-keyscan sshd wc; do
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
fi

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
  local label="$3"
  local deadline=$((SECONDS + 15))
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
      echo "timed out waiting for $label SFTP fixture on $host:$port" >&2
      return 1
    fi
    sleep 0.2
  done
}

fluxdown() {
  if [[ -n "$FLUXDOWN_BIN_PATH" ]]; then
    "$FLUXDOWN_BIN_PATH" "$@"
  else
    cargo run --quiet -p fluxdown-cli -- "$@"
  fi
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

JUMP_PORT="$(free_port)"
TARGET_PORT="$(free_port)"
REMOTE_DIR="$TMP_DIR/remote"
OUTPUT_DIR="$TMP_DIR/output"
mkdir -p "$REMOTE_DIR" "$OUTPUT_DIR"

SAMPLE_NAME="fluxdown-sftp-jump-sample.bin"
printf 'fluxdown jump e2e payload for sftp\n' > "$REMOTE_DIR/$SAMPLE_NAME"
EXPECTED_SIZE="$(wc -c < "$REMOTE_DIR/$SAMPLE_NAME" | tr -d ' ')"
EXPECTED_SHA256="$(shasum -a 256 "$REMOTE_DIR/$SAMPLE_NAME" | awk '{print $1}')"

# 作者: long
# 双服务使用独立 host key，才能分别验证跳板和目标主机的身份边界，而不是只验证其中一跳。
ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/jump_host"
ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/target_host"
ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/client"
ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/bad_jump_host"
cp "$TMP_DIR/client.pub" "$TMP_DIR/jump-authorized_keys"
cp "$TMP_DIR/client.pub" "$TMP_DIR/target-authorized_keys"

cat > "$TMP_DIR/jump_sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $JUMP_PORT
HostKey $TMP_DIR/jump_host
AuthorizedKeysFile $TMP_DIR/jump-authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
AllowUsers $USER_NAME
StrictModes no
AllowTcpForwarding yes
Subsystem sftp internal-sftp
PidFile $TMP_DIR/jump.pid
LogLevel ERROR
EOF

cat > "$TMP_DIR/target_sshd_config" <<EOF
ListenAddress 127.0.0.1
Port $TARGET_PORT
HostKey $TMP_DIR/target_host
AuthorizedKeysFile $TMP_DIR/target-authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
AllowUsers $USER_NAME
StrictModes no
AllowTcpForwarding yes
Subsystem sftp internal-sftp
PidFile $TMP_DIR/target.pid
LogLevel ERROR
EOF

eval "$(ssh-agent -s)" >/dev/null
SSH_AGENT_STARTED="true"
ssh-add "$TMP_DIR/client" >/dev/null
/usr/sbin/sshd -D -e -f "$TMP_DIR/jump_sshd_config" > "$TMP_DIR/jump.log" 2>&1 &
JUMP_PID=$!
/usr/sbin/sshd -D -e -f "$TMP_DIR/target_sshd_config" > "$TMP_DIR/target.log" 2>&1 &
TARGET_PID=$!
wait_for_sftp_banner 127.0.0.1 "$JUMP_PORT" "jump"
wait_for_sftp_banner 127.0.0.1 "$TARGET_PORT" "target"

JUMP_KNOWN_HOSTS="$TMP_DIR/jump_known_hosts"
TARGET_KNOWN_HOSTS="$TMP_DIR/target_known_hosts"
ssh-keyscan -T 5 -p "$JUMP_PORT" 127.0.0.1 > "$JUMP_KNOWN_HOSTS" 2>/dev/null
ssh-keyscan -T 5 -p "$TARGET_PORT" 127.0.0.1 > "$TARGET_KNOWN_HOSTS" 2>/dev/null
if [[ ! -s "$JUMP_KNOWN_HOSTS" || ! -s "$TARGET_KNOWN_HOSTS" ]]; then
  echo "failed to collect isolated SFTP host keys" >&2
  exit 1
fi

SOURCE="sftp://$USER_NAME@127.0.0.1:$TARGET_PORT/$(basename "$TMP_DIR")/remote/$SAMPLE_NAME"
JUMP_URL="sftp://$USER_NAME@127.0.0.1:$JUMP_PORT/"
REPORT="$TMP_DIR/result.json"

echo "macOS CLI SFTP jump fixture"
echo "  source: $SOURCE"
echo "  bytes:  $EXPECTED_SIZE"
echo "  sha256: $EXPECTED_SHA256"

fluxdown download "$SOURCE" \
  --output "$OUTPUT_DIR" \
  --name jump.bin \
  --sftp-known-hosts "$TARGET_KNOWN_HOSTS" \
  --sftp-jump "$JUMP_URL" \
  --sftp-jump-known-hosts "$JUMP_KNOWN_HOSTS" > "$REPORT"
python3 - "$REPORT" "$EXPECTED_SIZE" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_size = int(sys.argv[2])
assert report["protocol"] == "sftp", report
assert report["backend"] == "built-in", report
assert report["bytes_written"] == expected_size, report
assert report["total_bytes"] == expected_size, report
PY
assert_sha256 "$OUTPUT_DIR/jump.bin" "$EXPECTED_SHA256"

# 作者: long
# 错误跳板指纹必须在建立目标连接前失败，且不能留下半成品输出。
BAD_JUMP_KNOWN_HOSTS="$TMP_DIR/bad_jump_known_hosts"
ssh-keyscan -T 5 -p "$TARGET_PORT" 127.0.0.1 > "$BAD_JUMP_KNOWN_HOSTS" 2>/dev/null
printf '[127.0.0.1]:%s %s\n' "$JUMP_PORT" "$(cat "$TMP_DIR/bad_jump_host.pub")" >> "$BAD_JUMP_KNOWN_HOSTS"
if fluxdown download "$SOURCE" \
  --output "$OUTPUT_DIR" \
  --name bad.bin \
  --sftp-known-hosts "$TARGET_KNOWN_HOSTS" \
  --sftp-jump "$JUMP_URL" \
  --sftp-jump-known-hosts "$BAD_JUMP_KNOWN_HOSTS" \
  > "$TMP_DIR/bad.json" 2> "$TMP_DIR/bad.err"; then
  echo "invalid jump host key unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'SFTP 主机身份校验失败' "$TMP_DIR/bad.err"
if [[ -e "$OUTPUT_DIR/bad.bin" ]]; then
  echo "invalid jump host key created an output file" >&2
  exit 1
fi

echo "macOS CLI SFTP jump verification passed"
echo "  bytes:  $EXPECTED_SIZE"
echo "  sha256: $EXPECTED_SHA256"
echo "  bad jump known_hosts: rejected before output creation"
