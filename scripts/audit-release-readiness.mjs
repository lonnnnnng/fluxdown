import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const version = readPackageVersion()
const macosDmgName = `FluxDown_${version}_aarch64.dmg`
const releaseDir = `dist/release/FluxDown-${version}`

const requiredProtocols = [
  'http',
  'https',
  'webdav',
  'webdavs',
  'ftp',
  'ftps',
  'torrent',
  'magnet',
  'ed2k',
  'm3u8',
  'sftp',
  'smb',
  'ipfs',
]

const checks = [
  {
    label: 'Rust protocol model covers requested transfer families',
    kind: 'source-contains',
    file: 'crates/fluxdown-core/src/protocol.rs',
    values: ['Http', 'Https', 'Webdav', 'Webdavs', 'Ftp', 'Ftps', 'Torrent', 'Magnet', 'Ed2k', 'M3u8', 'Sftp', 'Smb', 'Ipfs'],
  },
  {
    label: 'Desktop engine dispatches implemented transfer families',
    kind: 'source-contains',
    file: 'crates/fluxdown-core/src/downloader.rs',
    values: [
      'download_http',
      'download_webdav',
      'download_ftp',
      'download_torrent',
      'download_m3u8',
      'download_sftp',
      'download_with_ed2k',
      'download_smb',
      'download_ipfs_gateway',
    ],
  },
  {
    label: 'Desktop ed2k supports aMule CLI backend with system handoff fallback',
    kind: 'source-contains',
    file: 'crates/fluxdown-core/src/downloader.rs',
    values: ['Backend::Amule', 'run_ed2k_cli', 'open::that'],
  },
  {
    label: 'Desktop CLI supports direct one-shot downloads',
    kind: 'source-contains',
    file: 'crates/fluxdown-cli/src/main.rs',
    values: ['Command::Download', 'DownloadEngine::new()', 'download_with_options'],
  },
  {
    label: 'Desktop CLI direct download command is integration tested',
    kind: 'source-contains',
    file: 'crates/fluxdown-cli/tests/download_command.rs',
    values: ['download_command_fetches_http_file', 'CARGO_BIN_EXE_fluxdown'],
  },
  {
    label: 'Desktop CLI queue workflow is integration tested',
    kind: 'source-contains',
    file: 'crates/fluxdown-cli/tests/download_command.rs',
    values: ['queue_commands_add_list_and_run_http_task', '--store', 'add', 'list', 'run', 'queued.bin'],
  },
  {
    label: 'Desktop GUI starts tasks through the shared progress-aware runner',
    kind: 'source-contains',
    file: 'apps/desktop/src-tauri/src/main.rs',
    values: ['TaskRunReport', 'run_task_with_options(&id, options)'],
  },
  {
    label: 'Desktop GUI polls persisted progress while downloads are active',
    kind: 'source-contains',
    file: 'apps/desktop/src/App.tsx',
    values: ['activeTaskId', 'window.setInterval', 'list_downloads'],
  },
  {
    label: 'Core stored-task runner persists progress and handles pause',
    kind: 'source-contains',
    file: 'crates/fluxdown-core/src/runner.rs',
    values: ['run_task', 'download_with_control', 'set_progress', 'DownloadState::Paused'],
  },
  {
    label: 'Desktop queue store uses atomic replacement writes',
    kind: 'source-contains',
    file: 'crates/fluxdown-core/src/store.rs',
    values: ['persist_atomically', 'NamedTempFile::new_in', '.persist(path)', 'sync_all'],
  },
  {
    label: 'Mobile app detects requested transfer families',
    kind: 'source-contains',
    file: 'apps/mobile/lib/src/protocol.dart',
    values: requiredProtocols,
  },
  {
    label: 'Mobile task store uses atomic replacement writes',
    kind: 'source-contains',
    file: 'apps/mobile/lib/src/task_store.dart',
    values: ['.tmp', 'writeAsString', 'flush: true', 'rename(file.path)'],
  },
  {
    label: 'Mobile runner dispatches implemented transfer families',
    kind: 'source-contains',
    file: 'apps/mobile/lib/src/mobile_downloader.dart',
    values: ['downloadHttp', 'webdav', 'webdavs', 'downloadFtp', 'downloadSftp', 'downloadM3u8', 'downloadTorrent', 'downloadSmb', 'handOffEd2kTask'],
  },
  {
    label: 'Mobile app can run queued tasks with bounded concurrency',
    kind: 'source-contains',
    file: 'apps/mobile/lib/src/download_controller.dart',
    values: ['MobileQueueRunReport', 'runQueued', 'concurrency.clamp', 'Future.wait'],
  },
  {
    label: 'Mobile queue runner is integration tested',
    kind: 'source-contains',
    file: 'apps/mobile/test/widget_test.dart',
    values: ['mobile controller runs queued tasks with bounded concurrency', '_FakeMobileDownloadRunner', 'runner.maxActive'],
  },
  {
    label: 'Mobile ed2k handoff is declared in Android and iOS platform config',
    kind: 'source-contains',
    file: 'package.json',
    values: ['verify:mobile-url-schemes', 'verify-mobile-url-schemes.mjs'],
  },
  {
    label: 'Mobile ed2k handoff is executable through the controller',
    kind: 'source-contains',
    file: 'apps/mobile/test/widget_test.dart',
    values: ['mobile controller hands off ed2k tasks to an external app', 'MobileDownloadRunner.withLauncher', 'ed2kLauncher'],
  },
  {
    label: 'Android app can query ed2k URL handlers',
    kind: 'source-contains',
    file: 'apps/mobile/android/app/src/main/AndroidManifest.xml',
    values: ['android.intent.action.VIEW', 'android:scheme="ed2k"'],
  },
  {
    label: 'iPhone app can query ed2k URL handlers',
    kind: 'source-contains',
    file: 'apps/mobile/ios/Runner/Info.plist',
    values: ['LSApplicationQueriesSchemes', '<string>ed2k</string>'],
  },
  {
    label: 'Desktop HLS supports master playlists and AES-128 segments',
    kind: 'source-contains',
    file: 'crates/fluxdown-core/src/downloader.rs',
    values: ['downloads_hls_master_playlist_through_first_variant', 'downloads_aes128_hls_playlist', 'MasterPlaylist', 'AES-128'],
  },
  {
    label: 'Mobile HLS supports master playlists and AES-128 segments',
    kind: 'source-contains',
    file: 'apps/mobile/test/widget_test.dart',
    values: ['downloads m3u8 master playlists through the first variant', 'downloads AES-128 encrypted m3u8 playlists'],
  },
  {
    label: 'macOS CLI artifact exists',
    kind: 'file',
    path: 'target/release/fluxdown',
  },
  {
    label: 'macOS GUI app bundle exists',
    kind: 'dir',
    path: 'target/release/bundle/macos/FluxDown.app',
  },
  {
    label: 'macOS DMG exists',
    kind: 'file',
    path: `target/release/bundle/dmg/${macosDmgName}`,
  },
  {
    label: 'Linux CLI artifact exists',
    kind: 'file',
    path: 'dist/linux-amd64/fluxdown',
  },
  {
    label: 'Linux GUI executable exists',
    kind: 'file',
    path: 'dist/linux-gui/fluxdown-desktop',
  },
  {
    label: 'Linux GUI deb package exists',
    kind: 'glob',
    path: 'dist/linux-gui/*.deb',
  },
  {
    label: 'Linux GUI rpm package exists',
    kind: 'glob',
    path: 'dist/linux-gui/*.rpm',
  },
  {
    label: 'Windows CLI artifact exists',
    kind: 'file',
    path: 'dist/windows-gnu/fluxdown.exe',
  },
  {
    label: 'Windows GUI artifact exists',
    kind: 'file',
    path: 'dist/windows-gui-gnu/fluxdown-desktop.exe',
  },
  {
    label: 'Windows GUI WebView2 loader exists',
    kind: 'file',
    path: 'dist/windows-gui-gnu/WebView2Loader.dll',
  },
  {
    label: 'Android release APK exists',
    kind: 'file',
    path: 'apps/mobile/build/app/outputs/flutter-apk/app-release.apk',
  },
  {
    label: 'Android release AAB exists',
    kind: 'file',
    path: 'apps/mobile/build/app/outputs/bundle/release/app-release.aab',
  },
  {
    label: 'iPhone debug framework compile artifact exists',
    kind: 'dir',
    path: 'apps/mobile/build/ios/framework/Debug/App.xcframework',
  },
  {
    label: 'iPhone Flutter framework compile artifact exists',
    kind: 'dir',
    path: 'apps/mobile/build/ios/framework/Debug/Flutter.xcframework',
  },
  {
    label: 'iPhone simulator app bundle exists',
    kind: 'dir',
    path: 'apps/mobile/build/ios/iphonesimulator/Runner.app',
  },
  {
    label: 'Unsigned iPhone device app bundle exists',
    kind: 'dir',
    path: 'apps/mobile/build/ios/iphoneos/Runner.app',
  },
  {
    label: 'Windows CLI and GUI are configured in CI',
    kind: 'source-contains',
    file: '.github/workflows/build.yml',
    values: ['windows-latest', 'fluxdown-cli-windows', 'fluxdown-desktop-windows', 'desktop-windows-ci', 'target/release/fluxdown-desktop.exe'],
  },
  {
    label: 'iPhone simulator artifact is configured in CI',
    kind: 'source-contains',
    file: '.github/workflows/build.yml',
    values: ['fluxdown-ios-simulator', 'build ios --simulator', 'fluxdown-ios-device-unsigned', 'build ios --no-codesign'],
  },
  {
    label: 'Local Windows CLI and GUI cross-build scripts exist',
    kind: 'source-contains',
    file: 'package.json',
    values: ['desktop:windows-cli:docker', 'desktop:windows-gui:docker'],
  },
  {
    label: 'Mobile iOS simulator build command exists',
    kind: 'source-contains',
    file: 'package.json',
    values: ['mobile:ios:simulator'],
  },
  {
    label: 'Mobile unsigned iPhone build command exists',
    kind: 'source-contains',
    file: 'package.json',
    values: ['mobile:ios'],
  },
  {
    label: 'Local signed iPhone IPA helper exists',
    kind: 'source-contains',
    file: 'package.json',
    values: ['mobile:ios:ipa:signed', 'build-ios-ipa-local.sh'],
  },
  {
    label: 'Release manifest tooling exists',
    kind: 'source-contains',
    file: 'package.json',
    values: ['release:stage', 'release:manifest', 'release:manifest:verify', 'release:prepare', 'release-manifest.mjs'],
  },
  {
    label: 'Release manifest artifact exists',
    kind: 'file',
    path: `${releaseDir}/FluxDown-release-manifest.json`,
  },
  {
    label: 'Staged release artifact verification exists',
    kind: 'source-contains',
    file: 'package.json',
    values: ['verify:release', 'verify-artifacts.mjs release'],
  },
  {
    label: 'Release manifest records checksums for packaged artifacts',
    kind: 'source-contains',
    file: 'scripts/release-manifest.mjs',
    values: ['createHash', 'sha256', 'hashDirectory', 'release-mobile-ios-ipa'],
  },
  {
    label: 'Local iOS signing script validates manual export inputs',
    kind: 'source-contains',
    file: 'scripts/build-ios-ipa-local.sh',
    values: ['IOS_CERTIFICATE_BASE64', 'IOS_PROVISIONING_PROFILE_BASE64', 'APPLE_TEAM_ID', 'flutter build ipa'],
  },
  {
    label: 'Signed iPhone IPA exists locally',
    kind: 'optional-glob',
    path: 'apps/mobile/build/ios/ipa/*.ipa',
    note: 'Requires Apple signing certificate and provisioning profile.',
  },
]

let failed = 0
let warned = 0

for (const check of checks) {
  const result = runCheck(check)
  if (result.status === 'FAIL') failed += 1
  if (result.status === 'WARN') warned += 1
  const suffix = result.detail ? ` - ${result.detail}` : ''
  console.log(`${result.status.padEnd(4)} ${check.label}${suffix}`)
}

console.log('')
console.log(`Release readiness: ${failed} failed, ${warned} warning${warned === 1 ? '' : 's'}.`)
if (failed > 0) {
  process.exitCode = 1
}

function runCheck(check) {
  if (check.kind === 'file') {
    return verifyFile(check.path)
  }
  if (check.kind === 'dir') {
    return verifyDir(check.path)
  }
  if (check.kind === 'glob') {
    return verifyGlob(check.path, false)
  }
  if (check.kind === 'optional-glob') {
    return verifyGlob(check.path, true, check.note)
  }
  if (check.kind === 'source-contains') {
    return verifySourceContains(check.file, check.values)
  }
  return { status: 'FAIL', detail: `unknown check kind ${check.kind}` }
}

function verifyFile(relativePath) {
  const path = resolve(root, relativePath)
  if (!existsSync(path)) {
    return { status: 'FAIL', detail: `${relativePath} missing` }
  }

  const stat = statSync(path)
  if (!stat.isFile()) {
    return { status: 'FAIL', detail: `${relativePath} is not a file` }
  }
  if (stat.size === 0) {
    return { status: 'FAIL', detail: `${relativePath} is empty` }
  }
  return { status: 'PASS', detail: `${stat.size} bytes` }
}

function verifyDir(relativePath) {
  const path = resolve(root, relativePath)
  if (!existsSync(path)) {
    return { status: 'FAIL', detail: `${relativePath} missing` }
  }

  const stat = statSync(path)
  if (!stat.isDirectory()) {
    return { status: 'FAIL', detail: `${relativePath} is not a directory` }
  }
  if (readdirSync(path).length === 0) {
    return { status: 'FAIL', detail: `${relativePath} is empty` }
  }
  return { status: 'PASS', detail: relativePath }
}

function verifyGlob(relativePattern, optional, note = '') {
  const dirPath = resolve(root, dirname(relativePattern))
  if (!existsSync(dirPath)) {
    return {
      status: optional ? 'WARN' : 'FAIL',
      detail: `${relativePattern} parent directory missing${note ? `; ${note}` : ''}`,
    }
  }

  const pattern = basename(relativePattern)
  const regex = new RegExp(`^${pattern.split('*').map(escapeRegExp).join('.*')}$`)
  const matches = readdirSync(dirPath).filter((entry) => regex.test(entry))
  if (matches.length === 0) {
    return {
      status: optional ? 'WARN' : 'FAIL',
      detail: `${relativePattern} matched no files${note ? `; ${note}` : ''}`,
    }
  }

  const bad = matches.find((entry) => {
    const stat = statSync(resolve(dirPath, entry))
    return !stat.isFile() || stat.size === 0
  })
  if (bad) {
    return { status: 'FAIL', detail: `${relativePattern} matched invalid file ${bad}` }
  }

  return { status: 'PASS', detail: matches.join(', ') }
}

function verifySourceContains(relativePath, values) {
  const path = resolve(root, relativePath)
  if (!existsSync(path)) {
    return { status: 'FAIL', detail: `${relativePath} missing` }
  }

  const source = readFileSync(path, 'utf8').toLowerCase()
  const missing = values.filter((value) => !source.includes(String(value).toLowerCase()))
  if (missing.length > 0) {
    return { status: 'FAIL', detail: `missing ${missing.join(', ')}` }
  }

  return { status: 'PASS', detail: relativePath }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function readPackageVersion() {
  return JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
}
