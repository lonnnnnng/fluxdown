#!/usr/bin/env bash
# Kotlin Android 回归前处理「正式签名包已装机」导致的签名冲突
#
# 作者: long
# debug 与正式 Release 共用 applicationId `dev.fluxdown.mobile.kotlin`，但签名证书不同：
# 装过正式签名包后，Gradle 的 installDebug / connectedDebugAndroidTest 会直接失败在
#   INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package ... signatures do not match
# 并在 connected 任务里表现为 0 项测试运行，很容易被误读成「测试全过」或「测试进程崩溃」。
#
# 这里在安装前比对已装包与 debug keystore 的证书摘要，只在确实冲突时卸载，避免每次都清掉
# 用户真机上的队列/凭据/SAF 授权。
#
# 用法：
#   scripts/android-kotlin-prepare-install.sh              # 冲突则卸载（会清应用数据）
#   scripts/android-kotlin-prepare-install.sh --keep-data  # 冲突则 adb uninstall -k（保留数据）
#   scripts/android-kotlin-prepare-install.sh --dry-run    # 只报告，不动设备
#   scripts/android-kotlin-prepare-install.sh --package dev.fluxdown.mobile.kotlin.releaseTest
#   ANDROID_SERIAL=xxx scripts/android-kotlin-prepare-install.sh
set -euo pipefail

PKG="dev.fluxdown.mobile.kotlin"
SERIAL="${ANDROID_SERIAL:-}"
KEEP_DATA=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) PKG="$2"; shift 2 ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

ADB_BIN="${ADB:-adb}"
adb_cmd() {
  if [[ -n "$SERIAL" ]]; then "$ADB_BIN" -s "$SERIAL" "$@"; else "$ADB_BIN" "$@"; fi
}

if ! adb_cmd get-state >/dev/null 2>&1; then
  echo "no adb device available${SERIAL:+ (ANDROID_SERIAL=$SERIAL)}" >&2
  exit 1
fi

# 作者: long
# 先把包列表读进变量再匹配：`adb ... | grep -q` 在 pipefail 下会因为 grep 提前退出
# 给 adb 发 SIGPIPE（状态 141），把「已安装」误判成「未安装」。
installed_packages() {
  adb_cmd shell pm list packages 2>/dev/null | tr -d '\r'
}

is_installed() {
  local listing
  listing="$(installed_packages || true)"
  grep -qx "package:$PKG" <<<"$listing"
}

if ! is_installed; then
  echo "installed package: none ($PKG 未安装，无需处理签名冲突)"
  exit 0
fi

# 作者: long
# 从已装 APK 读证书摘要，而不是解析 dumpsys 的 signatures 字段：MIUI 上该字段被省略，
# 而 pm path 给出的 base.apk 可以直接 pull 出来交给 apksigner。
APKSIGNER=""
SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
if [[ -d "$SDK_ROOT/build-tools" ]]; then
  BT="$(ls -1 "$SDK_ROOT/build-tools" | sort -V | tail -1)"
  [[ -x "$SDK_ROOT/build-tools/$BT/apksigner" ]] && APKSIGNER="$SDK_ROOT/build-tools/$BT/apksigner"
fi
if [[ -z "$APKSIGNER" ]]; then
  echo "apksigner not found under $SDK_ROOT/build-tools" >&2
  exit 1
fi

installed_cert_digest() {
  local tmp_dir apk_path pulled
  tmp_dir="$(mktemp -d)"
  apk_path="$(adb_cmd shell pm path "$PKG" 2>/dev/null | tr -d '\r' | sed -n 's/^package://p' | head -n 1)"
  if [[ -z "$apk_path" ]]; then
    rm -rf "$tmp_dir"
    return 1
  fi
  pulled="$tmp_dir/base.apk"
  if ! adb_cmd pull "$apk_path" "$pulled" >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    return 1
  fi
  "$APKSIGNER" verify --print-certs "$pulled" 2>/dev/null \
    | sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1
  rm -rf "$tmp_dir"
}

debug_cert_digest() {
  local store="$HOME/.android/debug.keystore"
  [[ -f "$store" ]] || return 1
  keytool -list -v -keystore "$store" -storepass android -alias androiddebugkey 2>/dev/null \
    | sed -n 's/^[[:space:]]*SHA256: //p' | head -n 1 | tr -d ':' | tr 'A-Z' 'a-z'
}

INSTALLED_DIGEST="$(installed_cert_digest || true)"
DEBUG_DIGEST="$(debug_cert_digest || true)"

if [[ -z "$INSTALLED_DIGEST" ]]; then
  echo "installed package: $PKG (无法读取证书摘要，按未知签名处理)"
  INSTALLED_DIGEST="unknown"
fi

echo "installed cert SHA-256: $INSTALLED_DIGEST"
echo "debug keystore SHA-256: ${DEBUG_DIGEST:-unknown}"

if [[ -n "$DEBUG_DIGEST" && "$INSTALLED_DIGEST" == "$DEBUG_DIGEST" ]]; then
  echo "已装包就是 debug 签名，installDebug / connectedDebugAndroidTest 可直接覆盖安装。"
  exit 0
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "signature mismatch detected; --dry-run 下未做任何改动。若要继续回归请重新执行（去掉 --dry-run）。"
  exit 0
fi

if [[ "$KEEP_DATA" -eq 1 ]]; then
  echo "签名不一致 → adb uninstall -k $PKG（保留应用数据目录）"
  adb_cmd shell pm uninstall -k "$PKG" >/dev/null
else
  echo "签名不一致 → adb uninstall $PKG"
  echo "警告：正式签名包的应用数据（队列、设置、凭据、SAF 授权）会一并删除；"
  echo "      需要保留时改用 --keep-data（adb uninstall -k，数据目录保留但不保证可读）。"
  adb_cmd uninstall "$PKG" >/dev/null
fi

if is_installed; then
  echo "卸载失败：$PKG 仍在设备上" >&2
  exit 1
fi
echo "已卸载，后续 installDebug / connectedDebugAndroidTest 可正常覆盖安装。"
