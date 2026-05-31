#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/mobile"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
KEYCHAIN_PATH="${IOS_KEYCHAIN_PATH:-$HOME/Library/Keychains/fluxdown-signing.keychain-db}"
CERTIFICATE_PATH="$APP_DIR/ios/signing/ios-signing.p12"
PROFILE_PATH="$APP_DIR/ios/signing/ios-profile.mobileprovision"
PROFILE_PLIST="$APP_DIR/ios/signing/ios-profile.plist"
EXPORT_OPTIONS="$APP_DIR/ios/ExportOptions.local.plist"

require_env() {
  local name="$1"
  if [ -z "${!name:-}" ]; then
    echo "$name is required." >&2
    exit 1
  fi
}

require_env IOS_CERTIFICATE_BASE64
require_env IOS_CERTIFICATE_PASSWORD
require_env IOS_PROVISIONING_PROFILE_BASE64
require_env IOS_KEYCHAIN_PASSWORD
require_env APPLE_TEAM_ID

mkdir -p "$APP_DIR/ios/signing" "$PROFILE_DIR"
chmod 700 "$APP_DIR/ios/signing"

echo "$IOS_CERTIFICATE_BASE64" | base64 --decode > "$CERTIFICATE_PATH"
echo "$IOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$PROFILE_PATH"
chmod 600 "$CERTIFICATE_PATH" "$PROFILE_PATH"

security create-keychain -p "$IOS_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" 2>/dev/null || true
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$IOS_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERTIFICATE_PATH" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security list-keychain -d user -s "$KEYCHAIN_PATH" $(security list-keychains -d user | sed 's/[ "]//g')
security set-key-partition-list -S apple-tool:,apple: -s -k "$IOS_KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST"
PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print UUID' "$PROFILE_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print Name' "$PROFILE_PLIST")
APP_IDENTIFIER=$(/usr/libexec/PlistBuddy -c 'Print Entitlements:application-identifier' "$PROFILE_PLIST")
EXPECTED_IDENTIFIER="$APPLE_TEAM_ID.dev.fluxdown.mobile"
if [ "$APP_IDENTIFIER" != "$EXPECTED_IDENTIFIER" ]; then
  echo "Provisioning profile application identifier '$APP_IDENTIFIER' does not match '$EXPECTED_IDENTIFIER'." >&2
  exit 1
fi
cp "$PROFILE_PATH" "$PROFILE_DIR/$PROFILE_UUID.mobileprovision"

/usr/libexec/PlistBuddy -c 'Clear dict' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :method string app-store' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $APPLE_TEAM_ID" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :provisioningProfiles dict' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:dev.fluxdown.mobile string $PROFILE_NAME" "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :stripSwiftSymbols bool true' "$EXPORT_OPTIONS"
/usr/libexec/PlistBuddy -c 'Add :uploadSymbols bool true' "$EXPORT_OPTIONS"
plutil -lint "$EXPORT_OPTIONS"

cd "$APP_DIR"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 flutter build ipa --export-options-plist="$EXPORT_OPTIONS"

cd "$ROOT"
node scripts/verify-artifacts.mjs file apps/mobile/build/ios/ipa/*.ipa
