#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${HOME:?HOME is required}/fluxdown-ios-sftp.XXXXXX")"
SSHD_PID=""

cleanup() {
  set +e
  if [[ -n "$SSHD_PID" ]]; then
    kill "$SSHD_PID" >/dev/null 2>&1
    wait "$SSHD_PID" >/dev/null 2>&1
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

for tool in flutter ipconfig python3 shasum ssh-keygen ssh-keyscan sshd wc; do
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
  local deadline=$((SECONDS + 20))
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
      echo "timed out waiting for iOS SFTP fixture on $host:$port" >&2
      return 1
    fi
    sleep 0.2
  done
}

DEVICES_JSON="$TMP_DIR/flutter-devices.json"
(
  cd "$ROOT_DIR/apps/mobile"
  flutter devices --machine > "$DEVICES_JSON"
)

DEVICE_LINE="$(node - "$DEVICES_JSON" <<'NODE'
const fs = require('node:fs');

const devices = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const requested = process.env.FLUXDOWN_IOS_DEVICE_ID?.trim();
const iosDevices = devices.filter((device) => device.targetPlatform === 'ios');
const device = requested
  ? iosDevices.find((item) => item.id === requested || item.name === requested)
  : iosDevices.find((item) => item.emulator) ?? iosDevices[0];

if (!device) {
  process.exit(78);
}

process.stdout.write([device.id, device.emulator ? 'simulator' : 'device', device.name].join('\t'));
NODE
)" || {
  echo "没有可用于 SFTP 回归的 iOS 目标；请先启动 simulator 或连接真机。" >&2
  exit 78
}
IFS=$'\t' read -r DEVICE_ID DEVICE_KIND DEVICE_NAME <<< "$DEVICE_LINE"

# 作者: long
# 模拟器与 Mac 共用 localhost；物理 iPhone 必须通过局域网地址访问本机 SSH fixture，避免把 127.0.0.1 误当成 Mac 地址。
if [[ "$DEVICE_KIND" == "simulator" ]]; then
  BIND_HOST="127.0.0.1"
  SOURCE_HOST="127.0.0.1"
else
  BIND_HOST="0.0.0.0"
  SOURCE_HOST="${FLUXDOWN_E2E_HOST:-}"
  if [[ -z "$SOURCE_HOST" ]]; then
    SOURCE_HOST="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}' | xargs -I{} ipconfig getifaddr {} 2>/dev/null || true)"
  fi
  if [[ -z "$SOURCE_HOST" ]]; then
    echo "物理 iPhone 回归需要 FLUXDOWN_E2E_HOST=<Mac 局域网地址>。" >&2
    exit 79
  fi
fi

SFTP_PORT="$(free_port)"
REMOTE_DIR="$TMP_DIR/remote"
mkdir -p "$REMOTE_DIR"
SAMPLE_NAME="fixture.txt"
EXPECTED_CONTENT=$'mobile sftp private key fixture\n'
printf '%s' "$EXPECTED_CONTENT" > "$REMOTE_DIR/$SAMPLE_NAME"
EXPECTED_SIZE="$(wc -c < "$REMOTE_DIR/$SAMPLE_NAME" | tr -d ' ')"
PASSPHRASE="fluxdown-ios-sftp-passphrase"
USERNAME="${USER:?USER is required for the local OpenSSH fixture}"

# 作者: long
# 服务端只接受本次生成的加密 Ed25519 私钥；known_hosts 单独采集当前 host key，确保测试同时覆盖认证和主机身份校验。
ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/host_key"
ssh-keygen -q -t ed25519 -N "$PASSPHRASE" -f "$TMP_DIR/client_key"
cp "$TMP_DIR/client_key.pub" "$TMP_DIR/authorized_keys"

cat > "$TMP_DIR/sshd_config" <<EOF
ListenAddress $BIND_HOST
Port $SFTP_PORT
HostKey $TMP_DIR/host_key
AuthorizedKeysFile $TMP_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
AllowUsers $USERNAME
StrictModes no
Subsystem sftp internal-sftp
PidFile $TMP_DIR/sshd.pid
LogLevel ERROR
EOF

/usr/sbin/sshd -D -e -f "$TMP_DIR/sshd_config" > "$TMP_DIR/sshd.log" 2>&1 &
SSHD_PID=$!
wait_for_sftp_banner "$SOURCE_HOST" "$SFTP_PORT"

KNOWN_HOSTS="$TMP_DIR/known_hosts"
ssh-keyscan -T 5 -p "$SFTP_PORT" "$SOURCE_HOST" > "$KNOWN_HOSTS" 2>/dev/null
if [[ ! -s "$KNOWN_HOSTS" ]]; then
  echo "ssh-keyscan returned no host keys" >&2
  exit 1
fi

REMOTE_PATH="/$(basename "$TMP_DIR")/remote/$SAMPLE_NAME"
KNOWN_HOSTS_BASE64="$(base64 < "$KNOWN_HOSTS" | tr -d '\n')"
PRIVATE_KEY_BASE64="$(base64 < "$TMP_DIR/client_key" | tr -d '\n')"
EXPECTED_CONTENT_BASE64="$(printf '%s' "$EXPECTED_CONTENT" | base64 | tr -d '\n')"

echo "iOS/mobile SFTP private-key fixture"
echo "  device: $DEVICE_NAME ($DEVICE_ID, $DEVICE_KIND)"
echo "  source: sftp://$USERNAME@$SOURCE_HOST:$SFTP_PORT$REMOTE_PATH"
echo "  bytes:  $EXPECTED_SIZE"

cd "$ROOT_DIR/apps/mobile"
flutter test integration_test/sftp_private_key_e2e_test.dart \
  -d "$DEVICE_ID" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_PORT="$SFTP_PORT" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_HOST="$SOURCE_HOST" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_USERNAME="$USERNAME" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_REMOTE_PATH="$REMOTE_PATH" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_KNOWN_HOSTS="$KNOWN_HOSTS_BASE64" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_PRIVATE_KEY="$PRIVATE_KEY_BASE64" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_PASSPHRASE="$PASSPHRASE" \
  --dart-define=FLUXDOWN_MOBILE_SFTP_EXPECTED_CONTENT_BASE64="$EXPECTED_CONTENT_BASE64"

echo "iOS/mobile SFTP private-key verification passed"
