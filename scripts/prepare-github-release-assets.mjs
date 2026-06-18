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

copyProjectLegalAssets()
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

function copyProjectLegalAssets() {
  // long: Release 页面直接暴露许可证文本，用户无需下载安装包也能审查自有 MIT 许可和第三方依赖风险。
  copyAsset(resolve(root, 'LICENSE'), `FluxDown-${version}-LICENSE.txt`)
  copyAsset(resolve(root, 'docs/third-party-licenses.md'), `FluxDown-${version}-THIRD-PARTY-LICENSES.md`)
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

这是由 GitHub Actions 构建的多平台发布版本。

## 本次重点

- 移动端队列页重新整理为更紧凑的状态 tab 和任务列表，任务卡片显示开始时间、结束时间、总耗时、已下载/总大小、实时速度和平均速度。
- 新建任务改为队列页右下角入口，支持粘贴、扫码、另存文件名和保存位置选择。
- 设置页改为更紧凑的中文默认文档风格，并提供并发下载数、下载线程数、自动重试数、最大下载网速和下载保存位置配置。
- Android 下载执行支持并发排队、线程数配置、失败重试和可选限速；HTTP Range 服务可用于验证多线程吞吐。
- Torrent 和 Magnet 在拿到 libtorrent metadata 后会把任务名更新为真实文件名；多文件资源会弹出选择列表，只下载用户选择的内容。
- HLS 在 Android 端会生成最终 .mp4 文件，并已用本地媒体级 HLS、单文件种子、单文件 Magnet、多文件种子和多文件 Magnet 做真机前台 App 验证。
- 文档默认入口改为中文，并补充协议测试用例、Android 真机协议报告和下载验证边界说明。

## Assets

${assetList}

签名 iOS IPA 和 debug framework 产物仅在 Apple signing secrets 配置完成后包含。
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
