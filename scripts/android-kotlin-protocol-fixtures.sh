#!/usr/bin/env bash
# FluxDown 协议夹具编排脚本（Android 真机协议矩阵专用）
#
# 作者: long
# 为什么存在：Android Kotlin 真机协议矩阵需要 12 类协议的稳定夹具，历史上依赖
# 192.168.1.8 上的常驻服务与 Docker。本机 Docker daemon 不可用、局域网主机也不可达时，
# 用本脚本在回环地址上起全部夹具，再通过 `adb reverse` 逐端口映射到设备侧，
# 使设备用 127.0.0.1:<port> 就能访问，不依赖局域网与防火墙配置。
#
# 用法：
#   scripts/android-kotlin-protocol-fixtures.sh up          # 起全部夹具 + adb reverse，输出 manifest
#   scripts/android-kotlin-protocol-fixtures.sh down        # 停止夹具并清理 adb reverse
#   scripts/android-kotlin-protocol-fixtures.sh urls        # 打印当前 manifest
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="${FLUXDOWN_FIXTURE_DIR:-${TMPDIR:-/tmp}/fluxdown-android-fixtures}"
# 作者: long
# FTP/FTPS/SFTP 需要 pyftpdlib/paramiko，SMB 需要 impacket；系统 python 在 PEP 668 下无法
# 直接 pip install，所以优先复用本地 venv。以前只给 SMB 做了这层回退，FTP/SFTP 会直接抛
# ModuleNotFoundError，表现为「fixture ftp failed to listen on port 2121」，排查成本很高。
if [[ -n "${FLUXDOWN_FIXTURE_PYTHON:-}" ]]; then
  PYTHON="$FLUXDOWN_FIXTURE_PYTHON"
elif [[ -x /tmp/fxvenv/bin/python ]]; then
  PYTHON=/tmp/fxvenv/bin/python
else
  PYTHON=python3
fi
ADB_BIN="${ADB:-adb}"
SERIAL="${ANDROID_SERIAL:-}"
# adb 自己也读 ANDROID_SERIAL：变量存在但为空串时，adb 会当作「序列号为空的设备」
# 直接报 `adb: error: device '' not found`，表现为夹具全部起不来。这里统一清掉空值。
[[ -n "$SERIAL" ]] || unset ANDROID_SERIAL
MANIFEST="$FIXTURE_DIR/manifest.json"

HTTP_PORT="${HTTP_PORT:-9101}"
HTTPS_PORT="${HTTPS_PORT:-9443}"
FTP_PORT="${FTP_PORT:-2121}"
FTPS_PORT="${FTPS_PORT:-2990}"
SFTP_PORT="${SFTP_PORT:-2222}"
SMB_PORT="${SMB_PORT:-1445}"
TRACKER_PORT="${TRACKER_PORT:-6969}"
PEER_PORT="${PEER_PORT:-51413}"
FTP_PASSIVE_FROM="${FTP_PASSIVE_FROM:-31000}"
FTP_PASSIVE_TO="${FTP_PASSIVE_TO:-31009}"

FTP_USER="fluxdown"
FTP_PASSWORD="fluxdown"

adb_cmd() {
  if [[ -n "$SERIAL" ]]; then
    "$ADB_BIN" -s "$SERIAL" "$@"
  else
    "$ADB_BIN" "$@"
  fi
}

log() {
  printf '%s\n' "$*" >&2
}

stop_fixtures() {
  local pid_file="$FIXTURE_DIR/pids"
  if [[ -f "$pid_file" ]]; then
    while read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" >/dev/null 2>&1 || true
    done < "$pid_file"
    rm -f "$pid_file"
  fi
  local port
  for port in "$HTTP_PORT" "$HTTPS_PORT" "$FTP_PORT" "$FTPS_PORT" "$SFTP_PORT" "$SMB_PORT" \
    "$TRACKER_PORT" "$PEER_PORT"; do
    local pid
    pid="$(lsof -nP -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill $pid >/dev/null 2>&1 || true
  done
  local passive
  for passive in $(seq "$FTP_PASSIVE_FROM" "$FTP_PASSIVE_TO"); do
    local pid
    pid="$(lsof -nP -tiTCP:"$passive" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill $pid >/dev/null 2>&1 || true
  done
  log "fixtures stopped"
}

wait_for_port() {
  local port="$1" label="$2" attempts=60
  while (( attempts > 0 )); do
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
    attempts=$((attempts - 1))
  done
  log "fixture $label failed to listen on port $port"
  return 1
}

make_payloads() {
  mkdir -p "$FIXTURE_DIR"/{www,www/dav,www/hls,ftp,sftp,smb,torrent,tls,logs}
  "$PYTHON" - "$FIXTURE_DIR" <<'PY'
import hashlib
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])

def write(path: pathlib.Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.stat().st_size != len(data):
        path.write_bytes(data)

# 1 MiB HTTP/HTTPS/WebDAV 载荷：内容确定，便于报告里给出稳定的 SHA-256。
http_payload = bytes((index * 37 + 11) % 256 for index in range(1024 * 1024))
write(root / "www" / "http-1mb.bin", http_payload)
write(root / "www" / "dav" / "webdav-1mb.bin", http_payload)

# HLS：5 个分片，每个 188*1024 字节。TS 要求每 188 字节以 0x47 同步字节开头，
# 否则核心或重封装器会判为非法传输流，矩阵里就会出现"假失败"。
for index in range(5):
    size = 188 * 1024
    segment = bytearray(((index + 1) * 53 + offset) % 256 for offset in range(size))
    for offset in range(0, size, 188):
        segment[offset] = 0x47
    write(root / "www" / "hls" / f"segment-{index}.ts", bytes(segment))

playlist = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:0"]
for index in range(5):
    playlist.append("#EXTINF:2.0,")
    playlist.append(f"segment-{index}.ts")
playlist.append("#EXT-X-ENDLIST")
write(root / "www" / "hls" / "index.m3u8", ("\n".join(playlist) + "\n").encode())

# Torrent 载荷 2 MiB，同时放进 seeder 目录，transmission 启动时校验后直接做种。
torrent_payload = bytes((index * 91 + 7) % 256 for index in range(2 * 1024 * 1024))
write(root / "torrent" / "torrent-2mb.bin", torrent_payload)

# FTP/SFTP/SMB 各自独立目录，避免夹具互相覆盖。
write(root / "ftp" / "ftp-1mb.bin", http_payload)
write(root / "sftp" / "sftp-1mb.bin", http_payload)
write(root / "smb" / "smb-1mb.bin", http_payload)

manifest = {}
for name in [
    "www/http-1mb.bin",
    "www/dav/webdav-1mb.bin",
    "ftp/ftp-1mb.bin",
    "sftp/sftp-1mb.bin",
    "smb/smb-1mb.bin",
    "torrent/torrent-2mb.bin",
]:
    path = root / name
    manifest[name] = {
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
hls = root / "www" / "hls"
hls_files = sorted(p.name for p in hls.iterdir())
manifest["www/hls"] = {
    "files": hls_files,
    "bytes": sum((hls / name).stat().st_size for name in hls_files),
}
print(pathlib.Path(root / "payload-sha256.json").write_text(
    __import__("json").dumps(manifest, indent=2, sort_keys=True), encoding="utf-8"
))
PY
}

make_certs() {
  local cert="$FIXTURE_DIR/tls/cert.pem" key="$FIXTURE_DIR/tls/key.pem"
  if [[ -f "$cert" && -f "$key" ]]; then
    return 0
  fi
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$key" -out "$cert" -days 30 \
    -subj "/CN=127.0.0.1" \
    -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
}

require_fixture_python_deps() {
  local missing
  missing="$("$PYTHON" - <<'PY' 2>/dev/null
import importlib.util
missing = [m for m in ("pyftpdlib", "paramiko") if importlib.util.find_spec(m) is None]
print(" ".join(missing))
PY
)" || true
  if [[ -n "$missing" ]]; then
    log "fixture python ($PYTHON) 缺少依赖: $missing"
    log "修复: python3 -m venv /tmp/fxvenv && /tmp/fxvenv/bin/pip install pyftpdlib paramiko impacket"
    return 1
  fi
}

start_fixtures() {
  require_fixture_python_deps
  : > "$FIXTURE_DIR/pids"
  local pids=()

  "$PYTHON" "$ROOT_DIR/scripts/range-http-server.py" --bind 127.0.0.1 --port "$HTTP_PORT" \
    --directory "$FIXTURE_DIR/www" >"$FIXTURE_DIR/logs/http.log" 2>&1 &
  pids+=($!)
  "$PYTHON" "$ROOT_DIR/scripts/range-http-server.py" --bind 127.0.0.1 --port "$HTTPS_PORT" \
    --directory "$FIXTURE_DIR/www" --tls-cert "$FIXTURE_DIR/tls/cert.pem" --tls-key "$FIXTURE_DIR/tls/key.pem" \
    >"$FIXTURE_DIR/logs/https.log" 2>&1 &
  pids+=($!)
  "$PYTHON" "$ROOT_DIR/scripts/fixtures/ftp_server.py" --bind 127.0.0.1 --port "$FTP_PORT" \
    --directory "$FIXTURE_DIR/ftp" --user "$FTP_USER" --password "$FTP_PASSWORD" \
    --passive-from "$FTP_PASSIVE_FROM" --passive-to "$FTP_PASSIVE_TO" >"$FIXTURE_DIR/logs/ftp.log" 2>&1 &
  pids+=($!)
  "$PYTHON" "$ROOT_DIR/scripts/fixtures/ftp_server.py" --bind 127.0.0.1 --port "$FTPS_PORT" \
    --directory "$FIXTURE_DIR/ftp" --user "$FTP_USER" --password "$FTP_PASSWORD" \
    --passive-from "$FTP_PASSIVE_FROM" --passive-to "$FTP_PASSIVE_TO" \
    --tls-cert "$FIXTURE_DIR/tls/cert.pem" --tls-key "$FIXTURE_DIR/tls/key.pem" \
    >"$FIXTURE_DIR/logs/ftps.log" 2>&1 &
  pids+=($!)
  "$PYTHON" "$ROOT_DIR/scripts/fixtures/sftp_server.py" --bind 127.0.0.1 --port "$SFTP_PORT" \
    --directory "$FIXTURE_DIR/sftp" --user "$FTP_USER" --password "$FTP_PASSWORD" \
    >"$FIXTURE_DIR/logs/sftp.log" 2>&1 &
  pids+=($!)
  "$PYTHON" "$ROOT_DIR/scripts/fixtures/tracker.py" --bind 127.0.0.1 --port "$TRACKER_PORT" \
    >"$FIXTURE_DIR/logs/tracker.log" 2>&1 &
  pids+=($!)

  printf '%s\n' "${pids[@]}" > "$FIXTURE_DIR/pids"

  wait_for_port "$HTTP_PORT" http
  wait_for_port "$HTTPS_PORT" https
  wait_for_port "$FTP_PORT" ftp
  wait_for_port "$FTPS_PORT" ftps
  wait_for_port "$SFTP_PORT" sftp
  wait_for_port "$TRACKER_PORT" tracker
}

start_smb() {
  local smb_python="${FLUXDOWN_SMB_PYTHON:-}"
  if [[ -z "$smb_python" ]]; then
    if [[ -x /tmp/fxvenv/bin/python ]]; then
      smb_python=/tmp/fxvenv/bin/python
    else
      smb_python="$PYTHON"
    fi
  fi
    if not "$smb_python" -c "import impacket" >/dev/null 2>&1; then
    log "skip SMB fixture: impacket not installed for $smb_python"
    return 1
  fi
  local smb_bin
  smb_bin="$(dirname "$smb_python")/smbserver.py"
  if [[ -x "$smb_bin" ]]; then
    "$smb_bin" SCRATCH "$FIXTURE_DIR/smb" -smb2support -port "$SMB_PORT" -ip 127.0.0.1 \
      >"$FIXTURE_DIR/logs/smb.log" 2>&1 &
  else
    "$smb_python" -m impacket.smbserver SCRATCH "$FIXTURE_DIR/smb" -smb2support -port "$SMB_PORT" -ip 127.0.0.1 \
      >"$FIXTURE_DIR/logs/smb.log" 2>&1 &
  fi
  printf '%s\n' "$!" >> "$FIXTURE_DIR/pids"
  wait_for_port "$SMB_PORT" smb
}

make_torrent() {
  local torrent="$FIXTURE_DIR/torrent/fluxdown-fixture.torrent"
  if [[ -f "$torrent" ]]; then
    return 0
  fi
  if ! command -v transmission-create >/dev/null 2>&1; then
    log "skip torrent fixture: transmission-create not available"
    return 1
  fi
  # 作者: long
  # 不能用 -p（private）：私有种子会让 Transmission 关闭 PEX/ut_metadata 扩展，
  # 它随后发出的 extended handshake 里就没有 `m` 字典，而 librqbit 把 `m` 当必填字段，
  # 对端会直接被判为 "missing field `m`" 断开，真机上表现为永远连不上做种者。
  transmission-create -t "http://127.0.0.1:$TRACKER_PORT/announce" \
    -o "$torrent" "$FIXTURE_DIR/torrent/torrent-2mb.bin" >/dev/null 2>&1
}

start_seeder() {
  local torrent="$FIXTURE_DIR/torrent/fluxdown-fixture.torrent"
  [[ -f "$torrent" ]] || return 1
  if ! command -v transmission-cli >/dev/null 2>&1; then
    log "skip seeder: transmission-cli not available"
    return 1
  fi
  mkdir -p "$FIXTURE_DIR/transmission"
  transmission-cli -w "$FIXTURE_DIR/torrent" -p "$PEER_PORT" -g "$FIXTURE_DIR/transmission" \
    "$torrent" >"$FIXTURE_DIR/logs/seeder.log" 2>&1 &
  printf '%s\n' "$!" >> "$FIXTURE_DIR/pids"
  sleep 4
}

reverse_ports() {
  local port
  adb_cmd reverse --remove-all >/dev/null 2>&1 || true
  for port in "$HTTP_PORT" "$HTTPS_PORT" "$FTP_PORT" "$FTPS_PORT" "$SFTP_PORT" "$SMB_PORT" \
    "$TRACKER_PORT" "$PEER_PORT"; do
    adb_cmd reverse "tcp:$port" "tcp:$port" >/dev/null
  done
  local passive
  for passive in $(seq "$FTP_PASSIVE_FROM" "$FTP_PASSIVE_TO"); do
    adb_cmd reverse "tcp:$passive" "tcp:$passive" >/dev/null
  done
}

write_manifest() {
  "$PYTHON" - "$FIXTURE_DIR" "$HTTP_PORT" "$HTTPS_PORT" "$FTP_PORT" "$FTPS_PORT" "$SFTP_PORT" \
    "$SMB_PORT" "$TRACKER_PORT" "$PEER_PORT" "$FTP_USER" "$FTP_PASSWORD" "$MANIFEST" <<'PY'
import hashlib
import json
import pathlib
import sys

(
    root,
    http_port,
    https_port,
    ftp_port,
    ftps_port,
    sftp_port,
    smb_port,
    tracker_port,
    peer_port,
    ftp_user,
    ftp_password,
    manifest_path,
) = sys.argv[1:]

root = pathlib.Path(root)
sha = json.loads((root / "payload-sha256.json").read_text(encoding="utf-8"))

def entry(name: str, **extra) -> dict:
    data = dict(sha[name])
    data.update(extra)
    return data

# 队列层只把分片拼成 TS 产物，不会把 index.m3u8 落盘，所以期望值只统计分片本身。
hls_names = [name for name in sha["www/hls"]["files"] if name.endswith(".ts")]
hls_bytes = sum((root / "www" / "hls" / name).stat().st_size for name in hls_names)
hls_digest = hashlib.sha256()
for name in hls_names:
    hls_digest.update((root / "www" / "hls" / name).read_bytes())

torrent_path = root / "torrent" / "fluxdown-fixture.torrent"
magnet = ""
torrent_sha = ""
if torrent_path.exists():
    from urllib.parse import quote

    raw = torrent_path.read_bytes()
    torrent_sha = hashlib.sha256(raw).hexdigest()
    # 直接从 torrent 里取 infohash：bencode 字典的 info 键切片太长，改用整文件哈希不可行，
    # 因此这里解析出 info 字典的字节区间再哈希。
    def find_info(raw_bytes: bytes) -> bytes:
        marker = b"4:info"
        index = raw_bytes.find(marker)
        if index < 0:
            raise SystemExit("torrent without info dict")
        start = index + len(marker)
        depth = 0
        position = start
        while position < len(raw_bytes):
            byte = raw_bytes[position : position + 1]
            if byte == b"d" or byte == b"l":
                depth += 1
            elif byte == b"e":
                if depth == 0:
                    return raw_bytes[start:position]
                depth -= 1
            elif byte == b"i":
                # 整数是 i<digits>e，必须整段跳过，否则数字会被当成字符串长度。
                position = raw_bytes.find(b"e", position) + 1
                continue
            elif byte.isdigit():
                colon = raw_bytes.find(b":", position)
                length = int(raw_bytes[position:colon])
                position = colon + 1 + length
                continue
            position += 1
        raise SystemExit("unterminated info dict")

    info_hash = hashlib.sha1(find_info(raw)).hexdigest()
    magnet = (
        f"magnet:?xt=urn:btih:{info_hash}"
        f"&dn=torrent-2mb.bin&tr={quote(f'http://127.0.0.1:{tracker_port}/announce', safe='')}"
    )

fixtures = [
    {
        "name": "http",
        "url": f"http://127.0.0.1:{http_port}/http-1mb.bin",
        "expect": entry("www/http-1mb.bin"),
        "fixture": "scripts/range-http-server.py (Range 支持)",
    },
    {
        "name": "https",
        "url": f"https://127.0.0.1:{https_port}/http-1mb.bin?allowBadCertificate=true",
        "expect": entry("www/http-1mb.bin"),
        "fixture": "scripts/range-http-server.py --tls-cert（自签 127.0.0.1）",
    },
    {
        "name": "webdav",
        "url": f"http://127.0.0.1:{http_port}/dav/webdav-1mb.bin",
        "expect": entry("www/dav/webdav-1mb.bin"),
        "fixture": "HTTP transport 映射（WebDAV 只做 GET）",
        "transportOnly": True,
    },
    {
        "name": "webdavs",
        "url": f"https://127.0.0.1:{https_port}/dav/webdav-1mb.bin?allowBadCertificate=true",
        "expect": entry("www/dav/webdav-1mb.bin"),
        "fixture": "HTTPS transport 映射（WebDAV 只做 GET）",
        "transportOnly": True,
    },
    {
        "name": "ftp",
        "url": f"ftp://{ftp_user}:{ftp_password}@127.0.0.1:{ftp_port}/ftp-1mb.bin",
        "expect": entry("ftp/ftp-1mb.bin"),
        "fixture": "scripts/fixtures/ftp_server.py (pyftpdlib)",
    },
    {
        "name": "ftps",
        "url": f"ftps://{ftp_user}:{ftp_password}@127.0.0.1:{ftps_port}/ftp-1mb.bin?allowBadCertificate=true",
        "expect": entry("ftp/ftp-1mb.bin"),
        "fixture": "scripts/fixtures/ftp_server.py --tls-cert（显式 FTPS）",
    },
    {
        "name": "sftp",
        "url": f"sftp://{ftp_user}:{ftp_password}@127.0.0.1:{sftp_port}/sftp-1mb.bin",
        "expect": entry("sftp/sftp-1mb.bin"),
        "fixture": "scripts/fixtures/sftp_server.py (paramiko)",
    },
    {
        "name": "smb",
        "url": f"smb://{ftp_user}:{ftp_password}@127.0.0.1:{smb_port}/SCRATCH/smb-1mb.bin",
        "expect": entry("smb/smb-1mb.bin"),
        "fixture": "impacket smbserver -smb2support",
    },
    {
        "name": "hls",
        "url": f"http://127.0.0.1:{http_port}/hls/index.m3u8",
        "expect": {
            "bytes": hls_bytes,
            "sha256": hls_digest.hexdigest(),
            "segments": len(hls_names),
            "note": "SHA-256 为全部分片按文件名顺序拼接后的摘要",
        },
        "fixture": "scripts/range-http-server.py 静态 m3u8 + 5 个分片",
    },
    {
        "name": "torrent",
        "url": f"http://127.0.0.1:{http_port}/torrent/fluxdown-fixture.torrent",
        "expect": entry("torrent/torrent-2mb.bin"),
        "fixture": "transmission-cli seeder + scripts/fixtures/tracker.py",
        "torrentSha256": torrent_sha,
    },
    {
        "name": "magnet",
        "url": magnet,
        "expect": entry("torrent/torrent-2mb.bin"),
        "fixture": "transmission-cli seeder + scripts/fixtures/tracker.py",
    },
    {
        "name": "ed2k",
        "url": "ed2k://|file|fluxdown-fixture.bin|1048576|31D6CFE0D16AE931B73C59D7E0C089C0|/",
        "expect": None,
        "fixture": "无内建实现：记录移交外部客户端的边界",
        "boundary": True,
    },
]

# torrent 文件需要放到 www 下才能通过 HTTP 取到
torrent_copy = root / "www" / "torrent"
torrent_copy.mkdir(parents=True, exist_ok=True)
if torrent_path.exists():
    (torrent_copy / "fluxdown-fixture.torrent").write_bytes(torrent_path.read_bytes())

manifest = {
    "fixtureDir": str(root),
    "ports": {
        "http": int(http_port),
        "https": int(https_port),
        "ftp": int(ftp_port),
        "ftps": int(ftps_port),
        "sftp": int(sftp_port),
        "smb": int(smb_port),
        "tracker": int(tracker_port),
        "peer": int(peer_port),
    },
    "fixtures": fixtures,
}
pathlib.Path(manifest_path).write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
print(manifest_path)
PY
}

cmd="${1:-up}"
case "$cmd" in
  up)
    stop_fixtures >/dev/null 2>&1 || true
    make_payloads
    make_certs
    start_fixtures
    start_smb || true
    make_torrent || true
    start_seeder || true
    reverse_ports
    write_manifest
    log "fixtures up (dir: $FIXTURE_DIR)"
    ;;
  down)
    stop_fixtures
    adb_cmd reverse --remove-all >/dev/null 2>&1 || true
    ;;
  urls)
    cat "$MANIFEST"
    ;;
  *)
    log "usage: $0 {up|down|urls}"
    exit 1
    ;;
esac
