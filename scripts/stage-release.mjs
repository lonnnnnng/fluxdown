import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync } from 'node:fs'
import { copyFile, cp } from 'node:fs/promises'
import { basename, dirname, join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const version = readPackageVersion()
const releaseRoot = resolve(root, 'dist/release', `FluxDown-${version}`)

const stagedArtifacts = [
  {
    from: 'target/release/fluxdown',
    to: 'desktop/macos/fluxdown-macos-aarch64',
  },
  {
    from: 'target/release/bundle/dmg/FluxDown_0.1.0_aarch64.dmg',
    to: 'desktop/macos/FluxDown-0.1.0-macos-aarch64.dmg',
  },
  {
    from: 'dist/linux-amd64/fluxdown',
    to: 'desktop/linux/fluxdown-linux-amd64',
  },
  {
    from: 'dist/linux-gui/fluxdown-desktop',
    to: 'desktop/linux/fluxdown-desktop-linux-amd64',
  },
  {
    from: 'dist/linux-gui/FluxDown_0.1.0_amd64.deb',
    to: 'desktop/linux/FluxDown-0.1.0-linux-amd64.deb',
  },
  {
    from: 'dist/linux-gui/FluxDown-0.1.0-1.x86_64.rpm',
    to: 'desktop/linux/FluxDown-0.1.0-linux-x86_64.rpm',
  },
  {
    from: 'dist/windows-gnu/fluxdown.exe',
    to: 'desktop/windows/fluxdown-windows-x86_64.exe',
  },
  {
    from: 'dist/windows-gui-gnu/fluxdown-desktop.exe',
    to: 'desktop/windows/fluxdown-desktop-windows-x86_64.exe',
  },
  {
    from: 'dist/windows-gui-gnu/WebView2Loader.dll',
    to: 'desktop/windows/WebView2Loader.dll',
  },
  {
    from: 'apps/mobile/build/app/outputs/flutter-apk/app-release.apk',
    to: 'mobile/android/FluxDown-0.1.0-android-release.apk',
  },
  {
    from: 'apps/mobile/build/app/outputs/bundle/release/app-release.aab',
    to: 'mobile/android/FluxDown-0.1.0-android-release.aab',
  },
]

const directoryArchives = [
  {
    from: 'apps/mobile/build/ios/iphonesimulator/Runner.app',
    to: 'mobile/ios/FluxDown-0.1.0-ios-simulator-Runner.app.tar.gz',
  },
  {
    from: 'apps/mobile/build/ios/iphoneos/Runner.app',
    to: 'mobile/ios/FluxDown-0.1.0-ios-device-unsigned-Runner.app.tar.gz',
  },
  {
    from: 'apps/mobile/build/ios/framework/Debug/App.xcframework',
    to: 'mobile/ios/FluxDown-0.1.0-ios-debug-App.xcframework.tar.gz',
  },
  {
    from: 'apps/mobile/build/ios/framework/Debug/Flutter.xcframework',
    to: 'mobile/ios/FluxDown-0.1.0-ios-debug-Flutter.xcframework.tar.gz',
  },
]

const optionalGlobs = [
  {
    from: 'apps/mobile/build/ios/ipa/*.ipa',
    toDir: 'mobile/ios',
    note: 'Requires Apple signing certificate and provisioning profile.',
  },
]

await main()

async function main() {
  rmSync(releaseRoot, { recursive: true, force: true })
  mkdirSync(releaseRoot, { recursive: true })

  for (const artifact of stagedArtifacts) {
    await copyArtifact(artifact)
  }

  for (const archive of directoryArchives) {
    archiveDirectory(archive)
  }

  for (const optional of optionalGlobs) {
    await copyOptionalGlob(optional)
  }

  console.log(`release staged: ${relativeFromRoot(releaseRoot)}`)
}

async function copyArtifact({ from, to }) {
  const source = resolve(root, from)
  const destination = resolve(releaseRoot, to)
  requireFile(source, from)
  mkdirSync(dirname(destination), { recursive: true })
  await copyFile(source, destination)
}

function archiveDirectory({ from, to }) {
  const source = resolve(root, from)
  const destination = resolve(releaseRoot, to)
  requireDirectory(source, from)
  mkdirSync(dirname(destination), { recursive: true })
  const result = spawnSync('tar', ['-czf', destination, '-C', dirname(source), basename(source)], {
    stdio: 'pipe',
  })
  if (result.status !== 0) {
    const stderr = result.stderr.toString().trim()
    throw new Error(`failed to archive ${from}${stderr ? `: ${stderr}` : ''}`)
  }
}

async function copyOptionalGlob({ from, toDir, note }) {
  const matches = expandGlob(from)
  if (matches.length === 0) {
    console.warn(`optional artifact skipped: ${from}; ${note}`)
    return
  }

  for (const match of matches) {
    const destination = resolve(releaseRoot, toDir, basename(match))
    mkdirSync(dirname(destination), { recursive: true })
    await cp(resolve(root, match), destination, { recursive: true })
  }
}

function requireFile(path, label) {
  if (!existsSync(path) || !statSync(path).isFile()) {
    throw new Error(`required release artifact missing: ${label}`)
  }
}

function requireDirectory(path, label) {
  if (!existsSync(path) || !statSync(path).isDirectory()) {
    throw new Error(`required release directory missing: ${label}`)
  }
}

function expandGlob(pattern) {
  const dir = resolve(root, dirname(pattern))
  const name = basename(pattern)
  if (!existsSync(dir)) {
    return []
  }

  const regex = new RegExp(`^${name.split('*').map(escapeRegExp).join('.*')}$`)
  return readdirSync(dir)
    .filter((entry) => regex.test(entry))
    .sort()
    .map((entry) => `${dirname(pattern)}/${entry}`)
}

function readPackageVersion() {
  return JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
}

function relativeFromRoot(path) {
  return path.replace(`${root}/`, '')
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
