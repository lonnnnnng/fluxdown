import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')

const androidManifest = readFileSync(
  resolve(root, 'apps/mobile/android/app/src/main/AndroidManifest.xml'),
  'utf8',
)
const iosInfo = readFileSync(
  resolve(root, 'apps/mobile/ios/Runner/Info.plist'),
  'utf8',
)

if (
  !androidManifest.includes('android.intent.action.VIEW') ||
  !androidManifest.includes('android:scheme="ed2k"')
) {
  console.error('AndroidManifest.xml is missing an ed2k VIEW query.')
  process.exitCode = 1
} else {
  console.log('ok Android ed2k URL query')
}

if (
  !iosInfo.includes('<key>LSApplicationQueriesSchemes</key>') ||
  !iosInfo.includes('<string>ed2k</string>')
) {
  console.error('Info.plist is missing LSApplicationQueriesSchemes ed2k.')
  process.exitCode = 1
} else {
  console.log('ok iOS ed2k URL query')
}
