import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, relative, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const command = process.argv[2] ?? 'write'
const version = readPackageVersion()
const releaseDir = `dist/release/FluxDown-${version}`
const manifestPath = resolve(root, releaseDir, 'FluxDown-release-manifest.json')
const macosDmgName = `FluxDown_${version}_aarch64.dmg`
const macosReleaseDmgName = `FluxDown-${version}-macos-aarch64.dmg`
const linuxDebName = `FluxDown-${version}-linux-amd64.deb`
const linuxRpmName = `FluxDown-${version}-linux-x86_64.rpm`
const androidApkName = `FluxDown-${version}-android-release.apk`
const androidAabName = `FluxDown-${version}-android-release.aab`
const iosSimulatorName = `FluxDown-${version}-ios-simulator-Runner.app.tar.gz`
const iosDeviceUnsignedName = `FluxDown-${version}-ios-device-unsigned-Runner.app.tar.gz`
const iosDebugAppFrameworkName = `FluxDown-${version}-ios-debug-App.xcframework.tar.gz`
const iosDebugFlutterFrameworkName = `FluxDown-${version}-ios-debug-Flutter.xcframework.tar.gz`

const artifacts = [
  {
    id: 'desktop-macos-cli',
    platform: 'macos',
    surface: 'desktop-cli',
    type: 'file',
    path: 'target/release/fluxdown',
  },
  {
    id: 'desktop-macos-gui-app',
    platform: 'macos',
    surface: 'desktop-gui',
    type: 'directory',
    path: 'target/release/bundle/macos/FluxDown.app',
  },
  {
    id: 'desktop-macos-gui-dmg',
    platform: 'macos',
    surface: 'desktop-gui',
    type: 'file',
    path: `target/release/bundle/dmg/${macosDmgName}`,
  },
  {
    id: 'desktop-linux-cli',
    platform: 'linux-amd64',
    surface: 'desktop-cli',
    type: 'file',
    path: 'dist/linux-amd64/fluxdown',
  },
  {
    id: 'desktop-linux-gui-executable',
    platform: 'linux-amd64',
    surface: 'desktop-gui',
    type: 'file',
    path: 'dist/linux-gui/fluxdown-desktop',
  },
  {
    id: 'desktop-linux-gui-deb',
    platform: 'linux-amd64',
    surface: 'desktop-gui',
    type: 'glob',
    path: 'dist/linux-gui/*.deb',
  },
  {
    id: 'desktop-linux-gui-rpm',
    platform: 'linux-amd64',
    surface: 'desktop-gui',
    type: 'glob',
    path: 'dist/linux-gui/*.rpm',
  },
  {
    id: 'desktop-windows-cli',
    platform: 'windows-x86_64',
    surface: 'desktop-cli',
    type: 'file',
    path: 'dist/windows-gnu/fluxdown.exe',
  },
  {
    id: 'desktop-windows-gui-executable',
    platform: 'windows-x86_64',
    surface: 'desktop-gui',
    type: 'file',
    path: 'dist/windows-gui-gnu/fluxdown-desktop.exe',
  },
  {
    id: 'desktop-windows-gui-webview2-loader',
    platform: 'windows-x86_64',
    surface: 'desktop-gui',
    type: 'file',
    path: 'dist/windows-gui-gnu/WebView2Loader.dll',
  },
  {
    id: 'mobile-android-apk',
    platform: 'android',
    surface: 'mobile-app',
    type: 'file',
    path: 'apps/mobile/build/app/outputs/flutter-apk/app-release.apk',
  },
  {
    id: 'mobile-android-aab',
    platform: 'android',
    surface: 'mobile-app',
    type: 'file',
    path: 'apps/mobile/build/app/outputs/bundle/release/app-release.aab',
  },
  {
    id: 'mobile-ios-simulator-app',
    platform: 'ios-simulator',
    surface: 'mobile-app',
    type: 'directory',
    path: 'apps/mobile/build/ios/iphonesimulator/Runner.app',
  },
  {
    id: 'mobile-ios-device-unsigned-app',
    platform: 'ios-device',
    surface: 'mobile-app',
    type: 'directory',
    path: 'apps/mobile/build/ios/iphoneos/Runner.app',
    signing: 'unsigned',
  },
  {
    id: 'mobile-ios-debug-app-framework',
    platform: 'ios',
    surface: 'mobile-build-validation',
    type: 'directory',
    path: 'apps/mobile/build/ios/framework/Debug/App.xcframework',
  },
  {
    id: 'mobile-ios-debug-flutter-framework',
    platform: 'ios',
    surface: 'mobile-build-validation',
    type: 'directory',
    path: 'apps/mobile/build/ios/framework/Debug/Flutter.xcframework',
  },
  {
    id: 'release-desktop-macos-cli',
    platform: 'macos',
    surface: 'desktop-cli',
    type: 'file',
    path: `${releaseDir}/desktop/macos/fluxdown-macos-aarch64`,
  },
  {
    id: 'release-desktop-macos-gui-dmg',
    platform: 'macos',
    surface: 'desktop-gui',
    type: 'file',
    path: `${releaseDir}/desktop/macos/${macosReleaseDmgName}`,
  },
  {
    id: 'release-desktop-linux-cli',
    platform: 'linux-amd64',
    surface: 'desktop-cli',
    type: 'file',
    path: `${releaseDir}/desktop/linux/fluxdown-linux-amd64`,
  },
  {
    id: 'release-desktop-linux-gui-executable',
    platform: 'linux-amd64',
    surface: 'desktop-gui',
    type: 'file',
    path: `${releaseDir}/desktop/linux/fluxdown-desktop-linux-amd64`,
  },
  {
    id: 'release-desktop-linux-gui-deb',
    platform: 'linux-amd64',
    surface: 'desktop-gui',
    type: 'file',
    path: `${releaseDir}/desktop/linux/${linuxDebName}`,
  },
  {
    id: 'release-desktop-linux-gui-rpm',
    platform: 'linux-amd64',
    surface: 'desktop-gui',
    type: 'file',
    path: `${releaseDir}/desktop/linux/${linuxRpmName}`,
  },
  {
    id: 'release-desktop-windows-cli',
    platform: 'windows-x86_64',
    surface: 'desktop-cli',
    type: 'file',
    path: `${releaseDir}/desktop/windows/fluxdown-windows-x86_64.exe`,
  },
  {
    id: 'release-desktop-windows-gui-executable',
    platform: 'windows-x86_64',
    surface: 'desktop-gui',
    type: 'file',
    path: `${releaseDir}/desktop/windows/fluxdown-desktop-windows-x86_64.exe`,
  },
  {
    id: 'release-desktop-windows-gui-webview2-loader',
    platform: 'windows-x86_64',
    surface: 'desktop-gui',
    type: 'file',
    path: `${releaseDir}/desktop/windows/WebView2Loader.dll`,
  },
  {
    id: 'release-mobile-android-apk',
    platform: 'android',
    surface: 'mobile-app',
    type: 'file',
    path: `${releaseDir}/mobile/android/${androidApkName}`,
  },
  {
    id: 'release-mobile-android-aab',
    platform: 'android',
    surface: 'mobile-app',
    type: 'file',
    path: `${releaseDir}/mobile/android/${androidAabName}`,
  },
  {
    id: 'release-mobile-ios-simulator-app-archive',
    platform: 'ios-simulator',
    surface: 'mobile-app',
    type: 'file',
    path: `${releaseDir}/mobile/ios/${iosSimulatorName}`,
  },
  {
    id: 'release-mobile-ios-device-unsigned-app-archive',
    platform: 'ios-device',
    surface: 'mobile-app',
    type: 'file',
    path: `${releaseDir}/mobile/ios/${iosDeviceUnsignedName}`,
    signing: 'unsigned',
  },
  {
    id: 'release-mobile-ios-debug-app-framework-archive',
    platform: 'ios',
    surface: 'mobile-build-validation',
    type: 'file',
    path: `${releaseDir}/mobile/ios/${iosDebugAppFrameworkName}`,
  },
  {
    id: 'release-mobile-ios-debug-flutter-framework-archive',
    platform: 'ios',
    surface: 'mobile-build-validation',
    type: 'file',
    path: `${releaseDir}/mobile/ios/${iosDebugFlutterFrameworkName}`,
  },
  {
    id: 'release-license',
    platform: 'all',
    surface: 'legal',
    type: 'file',
    path: `${releaseDir}/licenses/LICENSE`,
  },
  {
    id: 'release-third-party-licenses',
    platform: 'all',
    surface: 'legal',
    type: 'file',
    path: `${releaseDir}/licenses/THIRD-PARTY-LICENSES.md`,
  },
  {
    id: 'release-mobile-ios-ipa',
    platform: 'ios-device',
    surface: 'mobile-app',
    type: 'optional-glob',
    path: `${releaseDir}/mobile/ios/*.ipa`,
    signing: 'apple-distribution',
    note: 'Requires Apple signing certificate and provisioning profile.',
  },
]

if (command === 'write') {
  const manifest = buildManifest()
  mkdirSync(dirname(manifestPath), { recursive: true })
  writeFileSync(`${manifestPath}.tmp`, `${JSON.stringify(manifest, null, 2)}\n`)
  renameSync(`${manifestPath}.tmp`, manifestPath)
  console.log(`release manifest written: ${relative(root, manifestPath)}`)
} else if (command === 'verify') {
  verifyManifest()
} else {
  console.error(`unknown command: ${command}`)
  console.error('usage: node scripts/release-manifest.mjs [write|verify]')
  process.exitCode = 1
}

function buildManifest() {
  const entries = artifacts.flatMap((artifact) => materializeArtifact(artifact))
  const requiredMissing = entries.filter((entry) => entry.required && !entry.present)
  if (requiredMissing.length > 0) {
    for (const entry of requiredMissing) {
      console.error(`required artifact missing: ${entry.path}`)
    }
    process.exitCode = 1
  }

  return {
    product: 'FluxDown',
    version,
    releaseDir,
    generatedAt: new Date().toISOString(),
    artifacts: entries,
  }
}

function materializeArtifact(artifact) {
  if (artifact.type === 'glob' || artifact.type === 'optional-glob') {
    const paths = expandGlob(artifact.path)
    if (paths.length === 0) {
      return [
        {
          ...baseEntry(artifact),
          type: 'file',
          required: artifact.type === 'glob',
          present: false,
          bytes: 0,
          sha256: null,
        },
      ]
    }

    return paths.map((path, index) =>
      inspectPath({
        ...artifact,
        id: paths.length === 1 ? artifact.id : `${artifact.id}-${index + 1}`,
        type: 'file',
        path,
      }),
    )
  }

  return [inspectPath(artifact)]
}

function inspectPath(artifact) {
  const absolutePath = resolve(root, artifact.path)
  const entry = {
    ...baseEntry(artifact),
    required: artifact.type !== 'optional-glob',
    present: existsSync(absolutePath),
    bytes: 0,
    sha256: null,
  }

  if (!entry.present) {
    return entry
  }

  const stat = statSync(absolutePath)
  if (artifact.type === 'directory') {
    if (!stat.isDirectory()) {
      return { ...entry, present: false, error: 'expected directory' }
    }
    const digest = hashDirectory(absolutePath)
    return {
      ...entry,
      bytes: digest.bytes,
      sha256: digest.sha256,
      fileCount: digest.fileCount,
    }
  }

  if (!stat.isFile()) {
    return { ...entry, present: false, error: 'expected file' }
  }

  return {
    ...entry,
    bytes: stat.size,
    sha256: hashFile(absolutePath),
  }
}

function baseEntry(artifact) {
  return {
    id: artifact.id,
    platform: artifact.platform,
    surface: artifact.surface,
    type: artifact.type === 'optional-glob' ? 'file' : artifact.type,
    path: artifact.path,
    signing: artifact.signing ?? null,
    note: artifact.note ?? null,
  }
}

function verifyManifest() {
  if (!existsSync(manifestPath)) {
    console.error(`release manifest missing: ${relative(root, manifestPath)}`)
    process.exitCode = 1
    return
  }

  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
  const currentEntries = new Map(buildManifest().artifacts.map((entry) => [entry.id, entry]))
  let failed = 0

  for (const entry of manifest.artifacts ?? []) {
    const current = currentEntries.get(entry.id)
    if (!current) {
      console.error(`missing current artifact definition for ${entry.id}`)
      failed += 1
      continue
    }

    const fields = ['present', 'bytes', 'sha256']
    const mismatch = fields.find((field) => current[field] !== entry[field])
    if (mismatch) {
      console.error(
        `manifest mismatch for ${entry.id}: ${mismatch} expected ${entry[mismatch]} got ${current[mismatch]}`,
      )
      failed += 1
    } else {
      console.log(`ok manifest ${entry.id}`)
    }
  }

  if (failed > 0) {
    process.exitCode = 1
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

function hashFile(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

function hashDirectory(path) {
  const files = listFiles(path)
  const hash = createHash('sha256')
  let bytes = 0

  for (const file of files) {
    const relativePath = relative(path, file)
    const stat = statSync(file)
    const digest = hashFile(file)
    bytes += stat.size
    hash.update(relativePath)
    hash.update('\0')
    hash.update(String(stat.size))
    hash.update('\0')
    hash.update(digest)
    hash.update('\0')
  }

  return {
    bytes,
    fileCount: files.length,
    sha256: hash.digest('hex'),
  }
}

function listFiles(path) {
  const entries = readdirSync(path, { withFileTypes: true })
  const files = []
  for (const entry of entries) {
    const child = join(path, entry.name)
    if (entry.isDirectory()) {
      files.push(...listFiles(child))
    } else if (entry.isFile()) {
      files.push(child)
    }
  }
  return files.sort()
}

function readPackageVersion() {
  return JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}
