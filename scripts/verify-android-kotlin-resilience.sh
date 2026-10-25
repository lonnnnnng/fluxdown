#!/usr/bin/env bash
# Kotlin Android 韧性验证：进程被系统回收、设备 idle 长时下载、真实磁盘写满
#
# 作者: long
# 前两项在真机上跑（走真实 Rust 队列 + 前台服务），第三项在 macOS 上用 1 MiB 磁盘镜像跑同一条
# Rust 下载路径：设备侧没有 root，无法让 /data 真的写满，所以用真实内核返回的 ENOSPC 验证映射。
#
# 用法：
#   scripts/verify-android-kotlin-resilience.sh              # 全部三个场景
#   scripts/verify-android-kotlin-resilience.sh kill         # 只跑进程被杀恢复
#   scripts/verify-android-kotlin-resilience.sh idle         # 只跑设备 idle 长时下载
#   scripts/verify-android-kotlin-resilience.sh enospc       # 只跑真实 ENOSPC
#   ANDROID_SERIAL=xxx scripts/verify-android-kotlin-resilience.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERIAL="${ANDROID_SERIAL:-}"
[[ -n "$SERIAL" ]] || unset ANDROID_SERIAL
ADB_BIN="${ADB:-adb}"
PKG="${RESILIENCE_PKG:-dev.fluxdown.mobile.kotlin}"
TEST_CLASS="dev.fluxdown.android.RustQueueInstrumentationTest"
RUNNER="$PKG.test/androidx.test.runner.AndroidJUnitRunner"
PORT="${RESILIENCE_PORT:-9103}"
RATE="${RESILIENCE_RATE:-2097152}"
BYTES="${RESILIENCE_BYTES:-50331648}"
WORK="${FLUXDOWN_RESILIENCE_DIR:-/tmp/fluxdown-android-resilience}"
# 队列在应用内部存储，宿主只能读应用自己镜像出来的进度探针。
REMOTE="/sdcard/Android/data/$PKG/files/resilience"
REPORT="${REPORT_PATH:-$ROOT_DIR/docs/android-kotlin-resilience-report-$(date +%Y%m%d).md}"
SCENARIO="${1:-all}"
case "$SCENARIO" in
  all|kill|idle|enospc) ;;
  *) echo "unknown scenario: ${SCENARIO}（可选 all | kill | idle | enospc）" >&2; exit 1 ;;
esac

LOG="$WORK/logs"
mkdir -p "$WORK/payload" "$LOG"

adb_cmd() {
  if [[ -n "$SERIAL" ]]; then "$ADB_BIN" -s "$SERIAL" "$@"; else "$ADB_BIN" "$@"; fi
}

SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" >/dev/null 2>&1 || true; fi
  adb_cmd reverse --remove "tcp:$PORT" >/dev/null 2>&1 || true
  adb_cmd shell dumpsys deviceidle unforce >/dev/null 2>&1 || true
  adb_cmd shell dumpsys battery reset >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 作者: long
# 载荷必须可复现：宿主脚本自己算摘要，客户端只报告“下到了什么”，两边独立比对。
prepare_payload() {
  python3 - "$WORK/payload/resilience.bin" "$BYTES" <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
block = bytes((index * 37 + 11) % 251 for index in range(65536))
with open(path, "wb") as handle:
    written = 0
    while written < size:
        chunk = min(len(block), size - written)
        handle.write(block[:chunk])
        written += chunk
PY
  python3 - "$WORK/payload/enospc.bin" 8388608 <<'PY'
import sys
path, size = sys.argv[1], int(sys.argv[2])
with open(path, "wb") as handle:
    written = 0
    while written < size:
        handle.write(b"fluxdown-enospc")
        written += 16
PY
}

start_server() {
  echo "启动回环 HTTP 服务（总带宽 $((RATE / 1024)) KiB/s，端口 ${PORT}）"
  python3 "$ROOT_DIR/scripts/range-http-server.py" \
    --bind 127.0.0.1 --port "$PORT" \
    --directory "$WORK/payload" \
    --bytes-per-second "$RATE" --chunk-bytes 65536 \
    > "$LOG/server.log" 2>&1 &
  SERVER_PID=$!
  local deadline=$((SECONDS + 20))
  while [[ $SECONDS -lt $deadline ]]; do
    if grep -q "Serving" "$LOG/server.log"; then break; fi
    sleep 0.2
  done
  grep -q "Serving" "$LOG/server.log" || { echo "夹具服务未启动：" >&2; cat "$LOG/server.log" >&2; exit 1; }
  adb_cmd reverse "tcp:$PORT" "tcp:$PORT" >/dev/null
}

# MIUI 禁止 run-as，但 adb shell 能读 /sdcard/Android/data；进度由应用镜像到该目录。
remote_progress() {
  adb_cmd shell "cat $REMOTE/progress.json 2>/dev/null" | tr -d '\r' | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("-,0")
    raise SystemExit
try:
    data = json.loads(raw)
except Exception:
    print("-,0")
    raise SystemExit
print(str(data.get("state") or "-") + "," + str(data.get("downloadedBytes") or 0))
'
}

wait_progress() {
  local minimum="$1" timeout="$2" deadline=$((SECONDS + $2))
  local fields state bytes
  while [[ $SECONDS -lt $deadline ]]; do
    fields="$(remote_progress)"
    state="${fields%%,*}"
    bytes="${fields##*,}"
    if [[ "$bytes" =~ ^[0-9]+$ ]] && [[ "$bytes" -gt "$minimum" ]]; then
      echo "  已下载 $bytes 字节（state=${state}）"
      return 0
    fi
    sleep 0.5
  done
  echo "  等待进度超时（最后 state=${state} bytes=${bytes}）" >&2
  return 1
}

instrument_phase() {
  local phase="$1" method="$2" timeout="$3" log="$4"
  adb_cmd shell am instrument -w -r \
    -e class "$TEST_CLASS#$method" \
    -e resiliencePhase "$phase" \
    -e resilienceUrl "http://127.0.0.1:$PORT/resilience.bin" \
    -e resilienceSha "$PAYLOAD_SHA" \
    -e resilienceBytes "$BYTES" \
    "$RUNNER" > "$log" 2>&1 || true
  if grep -q "^OK (" "$log"; then
    echo "  $phase 通过：$(grep -m1 '^OK (' "$log")"
    return 0
  fi
  echo "  $phase 失败，日志尾部：" >&2
  tail -25 "$log" >&2
  return 1
}

install_apks() {
  bash "$ROOT_DIR/scripts/android-kotlin-prepare-install.sh" --package "$PKG"
  "$ROOT_DIR/apps/mobile/android/gradlew" -p "$ROOT_DIR/apps/android" \
    :app:installDebug :app:installDebugAndroidTest \
    > "$LOG/install.log" 2>&1
}

run_kill_scenario() {
  echo "[场景 1] 进程在下载中被系统回收 → 恢复为 paused/interrupted → 续传校验摘要"
  adb_cmd shell "rm -rf $REMOTE && mkdir -p $REMOTE"
  # 阶段一按设计会被杀，所以直接起 am instrument，不按“通过”判定。
  adb_cmd shell am instrument -w -r \
    -e class "$TEST_CLASS#resiliencePhaseStartThrottledDownload" \
    -e resiliencePhase start \
    -e resilienceUrl "http://127.0.0.1:$PORT/resilience.bin" \
    -e resilienceSha "$PAYLOAD_SHA" \
    -e resilienceBytes "$BYTES" \
    "$RUNNER" > "$LOG/kill-start.log" 2>&1 &
  local start_job=$!
  if ! wait_progress 4194304 240; then
    kill "$start_job" 2>/dev/null || true
    return 1
  fi
  PARTIAL_BYTES="$(remote_progress | awk -F, '{print $2}')"

  echo "  强制杀进程：am force-stop $PKG"
  adb_cmd shell am force-stop "$PKG"
  local deadline=$((SECONDS + 60))
  while kill -0 "$start_job" 2>/dev/null && [[ $SECONDS -lt $deadline ]]; do sleep 0.5; done
  kill "$start_job" 2>/dev/null || true
  wait "$start_job" 2>/dev/null || true
  if grep -q "^OK (" "$LOG/kill-start.log"; then
    echo "  警告：阶段一未被杀，它自己跑完了" >&2
  fi
  echo "  被杀前已下载 ${PARTIAL_BYTES:-0} 字节"

  instrument_phase verify resiliencePhaseVerifyRecoveryAfterProcessKill 900 "$LOG/kill-verify.log" || return 1
  RANGE_RESUMES="$(grep -c 'range=bytes=[1-9]' "$LOG/server.log" || true)"
  RANGE_TOTAL="$(grep -c 'range=bytes=' "$LOG/server.log" || true)"
  echo "  服务端收到 Range 请求 $RANGE_TOTAL 次，其中非 0 偏移续传 $RANGE_RESUMES 次"
  if [[ "${RANGE_RESUMES:-0}" -lt 1 ]]; then
    echo "  续传期间没有观测到非 0 偏移的 Range 请求，断点续传未被证明" >&2
    return 1
  fi
}

run_idle_scenario() {
  echo "[场景 2] 前台服务 + 设备 idle 期间的长时下载"
  adb_cmd shell "rm -rf $REMOTE && mkdir -p $REMOTE"
  adb_cmd shell dumpsys battery unplug >/dev/null 2>&1 || true
  adb_cmd logcat -c >/dev/null 2>&1 || true
  # 下载必须一直跑在同一个 instrumentation 会话里：会话一收尾系统就 force-stop 被测进程。
  instrument_phase idle resiliencePhaseForegroundServiceDownloadSurvivesIdle 0 "$LOG/idle.log" &
  local idle_job=$!
  if ! wait_progress 1048576 180; then
    kill "$idle_job" 2>/dev/null || true
    return 1
  fi
  IDLE_APPLIED=no
  if adb_cmd shell dumpsys deviceidle force-idle >/dev/null 2>&1; then
    IDLE_APPLIED=yes
    adb_cmd shell dumpsys deviceidle get deep | tr -d '\r' | sed 's/^/  deviceidle deep=/'
  else
    echo "  设备不支持 dumpsys deviceidle force-idle，退化为纯长时下载" >&2
  fi
  local deadline=$((SECONDS + 600))
  while kill -0 "$idle_job" 2>/dev/null && [[ $SECONDS -lt $deadline ]]; do sleep 2; done
  adb_cmd shell dumpsys deviceidle unforce >/dev/null 2>&1 || true
  adb_cmd shell dumpsys battery reset >/dev/null 2>&1 || true
  if kill -0 "$idle_job" 2>/dev/null; then
    echo "  下载在 600 秒内没有结束" >&2
    kill "$idle_job" 2>/dev/null || true
    return 1
  fi
  wait "$idle_job" 2>/dev/null || true
  adb_cmd logcat -d -s FluxDownService > "$LOG/idle-service.log" 2>/dev/null || true
  SERVICE_FINISHED="$(grep -c 'runner terminal state=finished' "$LOG/idle-service.log" || true)"
  echo "  前台服务收尾日志命中 $SERVICE_FINISHED 次（idle 已应用=${IDLE_APPLIED}）"
  if grep -q "^OK (" "$LOG/idle.log"; then
    echo "  idle 通过：$(grep -m1 '^OK (' "$LOG/idle.log")"
    return 0
  fi
  echo "  idle 失败，日志尾部：" >&2
  tail -25 "$LOG/idle.log" >&2
  return 1
}

run_enospc_scenario() {
  echo "[场景 3] 真实 ENOSPC：1 MiB 卷上跑同一条 Rust 下载路径"
  local image="$WORK/enospc.dmg" mount_point status
  hdiutil create -size 1m -fs HFS+ -volname FluxDownFull "$image" -quiet -ov >/dev/null
  mount_point="$(hdiutil attach "$image" -nobrowse | tail -1 | awk -F'\t' '{print $NF}')"
  if [[ ! -d "$mount_point" ]]; then
    echo "  磁盘镜像挂载失败" >&2
    return 1
  fi
  set +e
  "$ROOT_DIR/target/release/fluxdown" download \
    "http://127.0.0.1:$PORT/enospc.bin" \
    --store "$WORK/enospc-store.json" \
    --output "$mount_point" --name enospc.bin --threads 1 \
    > "$LOG/enospc.log" 2>&1
  status=$?
  ENOSPC_CLI_STATUS=$status
  set -e
  hdiutil detach "$mount_point" >/dev/null 2>&1 || true
  rm -f "$image"
  echo "  CLI 退出码 $status"
  if [[ "$status" -eq 0 ]]; then
    echo "  1 MiB 卷上竟然下载成功，ENOSPC 未被触发" >&2
    return 1
  fi
  if ! grep -q "磁盘空间不足" "$LOG/enospc.log"; then
    echo "  错误信息不是磁盘空间不足：" >&2
    tail -20 "$LOG/enospc.log" >&2
    return 1
  fi
  echo "  $(grep -m1 '磁盘空间不足' "$LOG/enospc.log")"
}

write_report() {
  local device_model app_version sdk
  device_model="$(adb_cmd shell getprop ro.product.model | tr -d '\r')"
  sdk="$(adb_cmd shell getprop ro.build.version.sdk | tr -d '\r')"
  app_version="$(adb_cmd shell dumpsys package "$PKG" | tr -d '\r' | grep -m1 versionName | cut -d= -f2)"
  {
    echo "# Kotlin Android 韧性验证报告（$(date +%Y-%m-%d)）"
    echo
    echo "## 1. 环境"
    echo
    echo "| 项目 | 值 |"
    echo "| --- | --- |"
    echo "| 设备 | ${device_model}（API ${sdk}） |"
    echo "| 序列号 | ${SERIAL:-$(adb_cmd get-serialno | tr -d '\r')} |"
    echo "| 应用包名 | ${PKG} |"
    echo "| 应用版本 | ${app_version} |"
    echo "| 测试载荷 | ${BYTES} 字节，SHA-256 \`${PAYLOAD_SHA}\` |"
    echo "| 回环总带宽 | $((RATE / 1024)) KiB/s |"
    echo "| 采集时间 | $(date "+%Y-%m-%d %H:%M:%S %z") |"
    echo
    echo "## 2. 结论"
    echo
    echo "| 场景 | 结果 | 关键证据 |"
    echo "| --- | --- | --- |"
    echo "| 进程被杀后恢复 | ${KILL_RESULT:-未运行} | 任务恢复为 paused + error_code=interrupted；被杀前已下载 ${PARTIAL_BYTES:-0} 字节；服务端观测到 ${RANGE_RESUMES:-0} 次非 0 偏移 Range 续传；续传完成后文件大小与 SHA-256 均与源一致 |"
    echo "| 设备 idle 长时下载 | ${IDLE_RESULT:-未运行} | force-idle 生效=${IDLE_APPLIED:-未运行}；前台服务在 idle 窗口内把整个载荷下完（收尾日志命中 ${SERVICE_FINISHED:-0} 次），摘要与源一致 |"
    echo "| 真实 ENOSPC | ${ENOSPC_RESULT:-未运行} | 1 MiB HFS+ 卷 + 8 MiB 载荷，CLI 退出码 ${ENOSPC_CLI_STATUS:-?}，错误文案命中「磁盘空间不足」 |"
    echo
    echo "## 3. 复跑方式"
    echo
    echo '```bash'
    echo "scripts/verify-android-kotlin-resilience.sh"
    echo '```'
    echo
    echo "## 4. 已知边界"
    echo
    echo "- 设备侧没有 root，无法让 /data 真正写满；ENOSPC 用 macOS 1 MiB 磁盘镜像验证同一条 Rust 下载路径，错误码映射另有 Rust 单测（\`ErrorKind::StorageFull\` → \`disk_full\`）。"
    echo "- 多连接下载（threadCount > 1）中断后不续传，会整份重下；只有单连接写最终文件才有 Range 续传语义，脚本统一用 threadCount=1。"
    echo "- 进程被杀由 \`am force-stop\` 制造，等价于用户或系统停止应用；LMK 回收后 START_STICKY 重建服务走同一条 recover 路径。"
    echo "- 队列文件在应用内部存储（Rust 进程写不到外置存储私有目录），宿主只能读应用镜像出来的 \`progress.json\`。"
  } > "$REPORT"
  echo "报告已写入 ${REPORT}"
}

echo "== 准备载荷 =="
prepare_payload
PAYLOAD_SHA="$(shasum -a 256 "$WORK/payload/resilience.bin" | awk '{print $1}')"
echo "  载荷 $BYTES 字节，SHA-256 $PAYLOAD_SHA"

start_server

if [[ "$SCENARIO" == "all" || "$SCENARIO" == "kill" || "$SCENARIO" == "idle" ]]; then
  echo "== 构建并安装 =="
  "$ROOT_DIR/scripts/build-kotlin-android.sh" > "$LOG/build.log" 2>&1
  install_apks
fi

FAILED=0
if [[ "$SCENARIO" == "all" || "$SCENARIO" == "kill" ]]; then
  if run_kill_scenario; then KILL_RESULT=通过; else KILL_RESULT=失败; FAILED=1; fi
fi
if [[ "$SCENARIO" == "all" || "$SCENARIO" == "idle" ]]; then
  if run_idle_scenario; then IDLE_RESULT=通过; else IDLE_RESULT=失败; FAILED=1; fi
fi
if [[ "$SCENARIO" == "all" || "$SCENARIO" == "enospc" ]]; then
  set +e
  run_enospc_scenario
  ENOSPC_OK=$?
  set -e
  if [[ "$ENOSPC_OK" -eq 0 ]]; then ENOSPC_RESULT=通过; else ENOSPC_RESULT=失败; FAILED=1; fi
fi

write_report
exit "$FAILED"
