#!/usr/bin/env bash
# Kotlin Android 12 类协议真机验证（一条命令可复跑）
#
# 作者: long
# 流程：起回环夹具 → adb reverse 映射 → 推夹具清单进应用私有目录 →
#      跑 ProtocolMatrixTest（走真实 Rust 队列）→ 拉结构化结果 → 生成/更新报告。
#
# 用法：
#   scripts/verify-android-kotlin-protocols.sh                 # 全矩阵 + 生成报告
#   scripts/verify-android-kotlin-protocols.sh --keep-fixtures # 结束后不关夹具
#   ANDROID_SERIAL=xxx scripts/verify-android-kotlin-protocols.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FLUXDOWN_FIXTURE_DIR="${FLUXDOWN_FIXTURE_DIR:-/tmp/fluxdown-android-fixtures}"
SERIAL="${ANDROID_SERIAL:-}"
# adb 也读 ANDROID_SERIAL：设为空串会被当成「序列号为空的设备」（device '' not found）。
[[ -n "$SERIAL" ]] || unset ANDROID_SERIAL
PKG="dev.fluxdown.mobile.kotlin"
VARIANT="debug"
TEST_CLASS="dev.fluxdown.android.ProtocolMatrixTest"
REPORT="${REPORT_PATH:-$ROOT_DIR/docs/android-kotlin-protocol-report-$(date +%Y%m%d).md}"
KEEP_FIXTURES=0
ONLY_PROTOCOLS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-fixtures) KEEP_FIXTURES=1; shift ;;
    --variant) VARIANT="$2"; shift 2 ;;
    --only) ONLY_PROTOCOLS="$2"; shift 2 ;;
    --report) REPORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

ADB_BIN="${ADB:-adb}"

# 作者: long
# 变体决定三件事：被测包名、APK 路径、gradle 安装任务。
# releaseTest 是 release 的 clone（initWith(release)）：同一套 R8 混淆配置，额外加测试专用 keep，
# 换 debug 签名 + applicationIdSuffix .releaseTest，所以能和 debug 包共存。
# 为什么不用已发布的正式签名 release APK：AGP 生成 androidTest APK 时会排除“被测 APK 已提供”的类，
# 调试版 test APK 里只有 kotlin/jvm/internal/Intrinsics 的引用而无定义；正式包被 R8 重命名了 kotlin.**，
# 于是 instrumentation 直接 NoClassDefFoundError（堆栈落在 AppComponentFactoryRegistry.instantiateApplication）。
case "$VARIANT" in
  debug)
    PKG="dev.fluxdown.mobile.kotlin"
    APK_PATH="$ROOT_DIR/apps/android/app/build/outputs/apk/debug/app-debug.apk"
    INSTALL_TASKS=(:app:installDebug :app:installDebugAndroidTest)
    GRADLE_EXTRA=()
    ;;
  releaseTest)
    PKG="dev.fluxdown.mobile.kotlin.releaseTest"
    APK_PATH="$ROOT_DIR/apps/android/app/build/outputs/apk/releaseTest/app-releaseTest.apk"
    INSTALL_TASKS=(:app:installReleaseTest :app:installReleaseTestAndroidTest)
    GRADLE_EXTRA=(-PfluxdownReleaseInstrumentation=true)
    ;;
  *)
    echo "unknown variant: ${VARIANT}（可选 debug | releaseTest）" >&2
    exit 1
    ;;
esac
adb_cmd() {
  if [[ -n "$SERIAL" ]]; then "$ADB_BIN" -s "$SERIAL" "$@"; else "$ADB_BIN" "$@"; fi
}

cleanup() {
  if [[ "$KEEP_FIXTURES" -eq 0 ]]; then
    bash "$ROOT_DIR/scripts/android-kotlin-protocol-fixtures.sh" down >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "[1/5] 启动协议夹具"
bash "$ROOT_DIR/scripts/android-kotlin-protocol-fixtures.sh" up

echo "[2/5] 安装 $VARIANT 与 androidTest APK"
# 作者: long
# 正式 Release 与 debug 共用 applicationId 但签名不同：装过正式签名包时，installDebug 会直接
# 失败在 INSTALL_FAILED_UPDATE_INCOMPATIBLE，connected/install 任务看上去像“什么都没跑”。
# 这里先比对证书摘要，只在确实冲突时卸载（脚本内部会提示数据丢失，--keep-data 可保留数据目录）。
bash "$ROOT_DIR/scripts/android-kotlin-prepare-install.sh" --package "$PKG"
# 用 installXxx + am instrument 而不是 connectedXxxAndroidTest：
# gradle 的 connected 任务在跑完会卸载 APK，连应用外部私有目录一起删掉，导致结果拉不回来。
"$ROOT_DIR/apps/mobile/android/gradlew" -p "$ROOT_DIR/apps/android" \
  "${GRADLE_EXTRA[@]}" \
  "${INSTALL_TASKS[@]}" \
  > "$FLUXDOWN_FIXTURE_DIR/logs/install.log" 2>&1

# 作者: long
# 环境门禁：把包名/版本/APK 摘要落到 env.json，报告直接引用，避免“哪一版跑出来的”说不清。
APK_SHA256="$(shasum -a 256 "$APK_PATH" | awk '{print $1}')"
VERSION_NAME="$(adb_cmd shell dumpsys package "$PKG" | tr -d '\r' | grep -m1 versionName | cut -d= -f2)"
VERSION_CODE="$(adb_cmd shell dumpsys package "$PKG" | tr -d '\r' | grep -m1 versionCode | cut -d= -f2 | awk '{print $1}')"
DEVICE_MODEL="$(adb_cmd shell getprop ro.product.model | tr -d '\r')"
python3 "$ROOT_DIR/scripts/fixtures/write_env.py" \
  "$FLUXDOWN_FIXTURE_DIR/env.json" \
  "$PKG" "$VERSION_NAME" "$VERSION_CODE" "$APK_SHA256" "$DEVICE_MODEL" "$SERIAL" "$VARIANT"

# 本机 MIUI 禁止 `run-as`（SELinux fromRunAs 被拒），改用 /sdcard/Android/data/<pkg>/files，
# adb shell 对该目录有读写权限，而 getExternalFilesDir(null) 正好指向它。
adb_cmd shell "mkdir -p /sdcard/Android/data/$PKG/files"
adb_cmd push "$FLUXDOWN_FIXTURE_DIR/manifest.json" "/sdcard/Android/data/$PKG/files/protocol-manifest.json" >/dev/null
adb_cmd shell "rm -f /sdcard/Android/data/$PKG/files/protocol-matrix-results.json"

echo "[3/5] 运行真机协议矩阵: ${TEST_CLASS}"
set +e
if [[ -n "$ONLY_PROTOCOLS" ]]; then
  adb_cmd shell am instrument -w -r \
    -e class "$TEST_CLASS" \
    -e protocolMatrix true \
    -e protocols "$ONLY_PROTOCOLS" \
    "$PKG.test/androidx.test.runner.AndroidJUnitRunner" \
    > "$FLUXDOWN_FIXTURE_DIR/logs/instrumentation.log" 2>&1
else
  adb_cmd shell am instrument -w -r \
    -e class "$TEST_CLASS" \
    -e protocolMatrix true \
    "$PKG.test/androidx.test.runner.AndroidJUnitRunner" \
    > "$FLUXDOWN_FIXTURE_DIR/logs/instrumentation.log" 2>&1
fi
INSTRUMENT_STATUS=$?
if grep -q "^OK (" "$FLUXDOWN_FIXTURE_DIR/logs/instrumentation.log"; then
  TEST_STATUS=0
else
  TEST_STATUS=1
fi
set -e

echo "[4/5] 拉取结构化结果"
adb_cmd pull "/sdcard/Android/data/$PKG/files/protocol-matrix-results.json" "$FLUXDOWN_FIXTURE_DIR/results.json" >/dev/null 2>&1 || true
if [[ ! -s "$FLUXDOWN_FIXTURE_DIR/results.json" ]]; then
  echo "未取到结果文件，instrumentation 日志尾部：" >&2
  tail -40 "$FLUXDOWN_FIXTURE_DIR/logs/instrumentation.log" >&2
  exit 1
fi
# 清单留在设备上会让默认 instrumentation 套件误跑矩阵（无夹具必失败），拉完即删。
adb_cmd shell "rm -f /sdcard/Android/data/$PKG/files/protocol-manifest.json" >/dev/null 2>&1 || true

echo "[5/5] 生成报告：$REPORT"
python3 "$ROOT_DIR/scripts/fixtures/protocol_report.py" \
  --manifest "$FLUXDOWN_FIXTURE_DIR/manifest.json" \
  --results "$FLUXDOWN_FIXTURE_DIR/results.json" \
  --report "$REPORT" \
  --test-status "$TEST_STATUS" \
  --env "$FLUXDOWN_FIXTURE_DIR/env.json"

echo "instrumentation 退出码: ${TEST_STATUS} (am instrument 原始退出码 ${INSTRUMENT_STATUS})"
exit "$TEST_STATUS"
