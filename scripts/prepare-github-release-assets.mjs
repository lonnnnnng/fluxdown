import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { basename, dirname, join, relative, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const version = readPackageVersion()
const [rawArg = 'dist/github-release/raw', assetsArg = 'dist/github-release/assets'] = process.argv.slice(2)
const rawDir = resolve(root, rawArg)
const assetsDir = resolve(root, assetsArg)
const outputRoot = dirname(assetsDir)
const preparedAssets = []

if (!existsSync(rawDir)) {
  throw new Error(`downloaded artifact directory is missing: ${relativeFromRoot(rawDir)}`)
}

rmSync(assetsDir, { recursive: true, force: true })
mkdirSync(assetsDir, { recursive: true })

copyRequiredFile('fluxdown-cli-linux', (file) => basename(file) === 'fluxdown', `fluxdown-${version}-linux-amd64`)
copyRequiredFile('fluxdown-cli-macos', (file) => basename(file) === 'fluxdown', `fluxdown-${version}-macos-aarch64`)
copyRequiredFile(
  'fluxdown-cli-windows',
  (file) => basename(file).toLowerCase() === 'fluxdown.exe',
  `fluxdown-${version}-windows-x86_64.exe`,
)

copyRequiredFile(
  'fluxdown-desktop-macos',
  (file) => basename(file).toLowerCase().endsWith('.dmg'),
  `FluxDown-${version}-macos-aarch64.dmg`,
)
archiveRequiredDirectory(
  'fluxdown-desktop-macos',
  (dir) => basename(dir) === 'FluxDown.app',
  `FluxDown-${version}-macos-aarch64.app.tar.gz`,
)

copyRequiredFile(
  'fluxdown-desktop-linux',
  (file) => basename(file) === 'fluxdown-desktop',
  `fluxdown-desktop-${version}-linux-amd64`,
)
copyRequiredFile(
  'fluxdown-desktop-linux',
  (file) => basename(file).toLowerCase().endsWith('.deb'),
  `FluxDown-${version}-linux-amd64.deb`,
)
copyRequiredFile(
  'fluxdown-desktop-linux',
  (file) => basename(file).toLowerCase().endsWith('.rpm'),
  `FluxDown-${version}-linux-x86_64.rpm`,
)

copyRequiredFile(
  'fluxdown-desktop-windows',
  (file) => basename(file).toLowerCase().endsWith('.msi'),
  `FluxDown-${version}-windows-x86_64.msi`,
)
copyRequiredFile(
  'fluxdown-desktop-windows',
  (file) => basename(file).toLowerCase().endsWith('.exe') && basename(file).toLowerCase() !== 'fluxdown-desktop.exe',
  `FluxDown-${version}-windows-x86_64-setup.exe`,
)
copyRequiredFile(
  'fluxdown-desktop-windows',
  (file) => basename(file).toLowerCase() === 'fluxdown-desktop.exe',
  `fluxdown-desktop-${version}-windows-x86_64.exe`,
)

copyRequiredFile(
  'fluxdown-android-debug-apk',
  (file) => basename(file) === 'app-debug.apk',
  `FluxDown-${version}-android-debug.apk`,
)
copyRequiredFile(
  'fluxdown-android-release-apk',
  (file) => basename(file) === 'app-release.apk',
  `FluxDown-${version}-android-release.apk`,
)
copyRequiredFile(
  'fluxdown-android-release-aab',
  (file) => basename(file) === 'app-release.aab',
  `FluxDown-${version}-android-release.aab`,
)

archiveRequiredIosApp(
  'fluxdown-ios-simulator',
  `FluxDown-${version}-ios-simulator-Runner.app.tar.gz`,
)
archiveRequiredIosApp(
  'fluxdown-ios-device-unsigned',
  `FluxDown-${version}-ios-device-unsigned-Runner.app.tar.gz`,
)

archiveOptionalDirectory(
  'fluxdown-ios-debug-frameworks',
  (dir) => basename(dir) === 'App.xcframework',
  `FluxDown-${version}-ios-debug-App.xcframework.tar.gz`,
)
archiveOptionalDirectory(
  'fluxdown-ios-debug-frameworks',
  (dir) => basename(dir) === 'Flutter.xcframework',
  `FluxDown-${version}-ios-debug-Flutter.xcframework.tar.gz`,
)
copyOptionalFile(
  'fluxdown-ios-release-ipa',
  (file) => basename(file).toLowerCase().endsWith('.ipa'),
  `FluxDown-${version}-ios-release.ipa`,
)

writeManifest()
writeReleaseNotes()

console.log(`prepared ${preparedAssets.length} release assets in ${relativeFromRoot(assetsDir)}`)

function copyRequiredFile(artifactName, predicate, assetName) {
  const file = requireEntry(artifactName, 'file', predicate)
  copyAsset(file, assetName)
}

function copyOptionalFile(artifactName, predicate, assetName) {
  const file = findEntry(artifactName, 'file', predicate)
  if (!file) {
    console.warn(`optional artifact skipped: ${artifactName}`)
    return
  }
  copyAsset(file, assetName)
}

function archiveRequiredDirectory(artifactName, predicate, assetName) {
  const directory = requireEntry(artifactName, 'directory', predicate)
  archivePaths([{ path: directory, name: basename(directory) }], assetName)
}

function archiveRequiredIosApp(artifactName, assetName) {
  const bundleDirectory = findEntry(artifactName, 'directory', (dir) => basename(dir) === 'Runner.app')
  if (bundleDirectory) {
    archivePaths([{ path: bundleDirectory, name: 'Runner.app' }], assetName)
    return
  }

  const artifactDir = resolve(rawDir, artifactName)
  const runnerBinary = resolve(artifactDir, 'Runner')
  const infoPlist = resolve(artifactDir, 'Info.plist')
  if (!existsSync(runnerBinary) || !existsSync(infoPlist)) {
    throw new Error(`required iOS Runner.app contents not found in artifact ${artifactName}`)
  }

  archivePaths([{ path: artifactDir, name: 'Runner.app' }], assetName)
}

function archiveOptionalDirectory(artifactName, predicate, assetName) {
  const directory = findEntry(artifactName, 'directory', predicate)
  if (!directory) {
    console.warn(`optional artifact skipped: ${artifactName}/${assetName}`)
    return
  }
  archivePaths([{ path: directory, name: basename(directory) }], assetName)
}

function copyAsset(source, assetName) {
  const destination = resolve(assetsDir, assetName)
  copyFileSync(source, destination)
  recordAsset(destination)
}

function archivePaths(entries, assetName) {
  const stagingDir = resolve(outputRoot, `.stage-${assetName}`)
  const destination = resolve(assetsDir, assetName)
  rmSync(stagingDir, { recursive: true, force: true })
  mkdirSync(stagingDir, { recursive: true })

  for (const entry of entries) {
    const result = spawnSync('cp', ['-R', entry.path, resolve(stagingDir, entry.name)], { stdio: 'pipe' })
    if (result.status !== 0) {
      throw new Error(`failed to stage ${relativeFromRoot(entry.path)}: ${result.stderr.toString().trim()}`)
    }
  }

  const result = spawnSync('tar', ['-czf', destination, '-C', stagingDir, '.'], { stdio: 'pipe' })
  rmSync(stagingDir, { recursive: true, force: true })
  if (result.status !== 0) {
    throw new Error(`failed to archive ${assetName}: ${result.stderr.toString().trim()}`)
  }

  recordAsset(destination)
}

function requireEntry(artifactName, kind, predicate) {
  const entry = findEntry(artifactName, kind, predicate)
  if (!entry) {
    throw new Error(`required ${kind} not found in artifact ${artifactName}`)
  }
  return entry
}

function findEntry(artifactName, kind, predicate) {
  const artifactDir = resolve(rawDir, artifactName)
  if (!existsSync(artifactDir)) {
    return null
  }

  const entries = listEntries(artifactDir)
  return entries
    .filter((entry) => {
      const stat = statSync(entry)
      return kind === 'file' ? stat.isFile() : stat.isDirectory()
    })
    .filter(predicate)
    .sort((a, b) => a.localeCompare(b))[0] ?? null
}

function listEntries(path) {
  const entries = []
  for (const child of readdirSync(path, { withFileTypes: true })) {
    const childPath = join(path, child.name)
    entries.push(childPath)
    if (child.isDirectory()) {
      entries.push(...listEntries(childPath))
    }
  }
  return entries
}

function recordAsset(path) {
  const stat = statSync(path)
  if (!stat.isFile() || stat.size === 0) {
    throw new Error(`prepared asset is empty or invalid: ${relativeFromRoot(path)}`)
  }

  preparedAssets.push({
    name: basename(path),
    bytes: stat.size,
    sha256: hashFile(path),
  })
}

function writeManifest() {
  const manifestPath = resolve(assetsDir, `FluxDown-${version}-release-manifest.json`)
  const manifest = {
    product: 'FluxDown',
    version,
    generatedAt: new Date().toISOString(),
    assets: preparedAssets.sort((a, b) => a.name.localeCompare(b.name)),
  }
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)
  recordAsset(manifestPath)
}

function writeReleaseNotes() {
  const assetList = preparedAssets
    .filter((asset) => !asset.name.endsWith('-release-manifest.json'))
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((asset) => `- ${asset.name}`)
    .join('\n')

  const notes = `# FluxDown ${version}

Multi-platform release built by GitHub Actions.

## Assets

${assetList}

Signed iOS IPA and debug framework assets are included only when Apple signing secrets are configured.
`
  writeFileSync(resolve(outputRoot, 'RELEASE_NOTES.md'), notes)
}

function hashFile(path) {
  return createHash('sha256').update(readFileSync(path)).digest('hex')
}

function readPackageVersion() {
  return JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
}

function relativeFromRoot(path) {
  return relative(root, path) || '.'
}
