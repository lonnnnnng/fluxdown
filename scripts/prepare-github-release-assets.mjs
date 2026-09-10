import { createHash } from 'node:crypto'
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, relative, resolve } from 'node:path'
import { execFileSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { gzipSync } from 'node:zlib'
import { verifyPublicReleaseAssets } from './verify-github-release-assets.mjs'

const root = resolve(import.meta.dirname, '..')
const version = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
const [rawArg = 'dist/github-release/raw', assetsArg = 'dist/github-release/assets'] = process.argv.slice(2)
const rawDir = resolve(root, rawArg)
const assetsDir = resolve(root, assetsArg)
const preparedAssets = []

if (!existsSync(rawDir)) throw new Error(`downloaded artifact directory is missing: ${rawDir}`)
// 作者: long
// 使用独立空目录避免历史版本或测试资产混入公开下载区，也不清理调用方传入的已有目录。
if (existsSync(assetsDir) && readdirSync(assetsDir).length > 0) {
  throw new Error(`public release output directory must be empty: ${assetsDir}`)
}
mkdirSync(assetsDir, { recursive: true })

archiveCli('fluxdown-cli-linux', 'fluxdown', `fluxdown-${version}-linux-amd64.tar.gz`)
archiveCli('fluxdown-cli-macos', 'fluxdown', `fluxdown-${version}-macos-aarch64.tar.gz`)
archiveCli('fluxdown-cli-windows', 'fluxdown.exe', `fluxdown-${version}-windows-x86_64.zip`)
copyRequiredFile('fluxdown-desktop-macos', (name) => name.endsWith('.dmg'), `FluxDown-${version}-macos-aarch64.dmg`)
copyRequiredFile('fluxdown-desktop-linux', (name) => name.endsWith('.deb'), `FluxDown-${version}-linux-amd64.deb`)
copyRequiredFile('fluxdown-desktop-linux', (name) => name.endsWith('.rpm'), `FluxDown-${version}-linux-x86_64.rpm`)
copyRequiredFile('fluxdown-desktop-windows', (name) => name.endsWith('-setup.exe'), `FluxDown-${version}-windows-x86_64-setup.exe`)
copyRequiredFile('fluxdown-android-release-apk', (name) => name === 'app-release.apk', `FluxDown-${version}-android-release.apk`)

// 作者: long
// Debug APK、AAB、iOS 验证包、MSI、裸桌面程序与 macOS app 压缩包继续保留为 Actions Artifacts，不公开到 Release。
copyAsset(resolve(root, 'LICENSE'), `FluxDown-${version}-LICENSE.txt`)
copyAsset(resolve(root, 'docs/third-party-licenses.md'), `FluxDown-${version}-THIRD-PARTY-LICENSES.md`)
writeInternalManifest()
verifyPublicReleaseAssets(assetsDir, version)
writeReleaseNotes()
console.log(`prepared ${preparedAssets.length} public release assets in ${relative(root, assetsDir)}`)

function copyRequiredFile(artifactName, predicate, assetName) {
  copyAsset(findRequiredFile(artifactName, predicate, assetName), assetName)
}

function findRequiredFile(artifactName, predicate, assetName) {
  const artifactDir = resolve(rawDir, artifactName)
  const matches = existsSync(artifactDir)
    ? listFiles(artifactDir).filter((file) => predicate(basename(file).toLowerCase()))
    : []
  if (matches.length !== 1) throw new Error(`expected exactly one ${assetName} in ${artifactName}, found ${matches.length}`)
  return matches[0]
}

function archiveCli(artifactName, binaryName, assetName) {
  const source = findRequiredFile(artifactName, (name) => name === binaryName, assetName)
  const staging = mkdtempSync(join(tmpdir(), 'fluxdown-cli-release-'))
  try {
    const binary = join(staging, binaryName)
    copyFileSync(source, binary)
    // 作者: long
    // Actions 下载会丢失可执行位；归档前只修复临时副本，Unix 用户解压即可运行，原生二进制内容不变。
    chmodSync(binary, 0o755)
    copyFileSync(resolve(root, 'LICENSE'), join(staging, 'LICENSE.txt'))
    copyFileSync(resolve(root, 'docs/third-party-licenses.md'), join(staging, 'THIRD-PARTY-LICENSES.md'))
    const files = [binaryName, 'LICENSE.txt', 'THIRD-PARTY-LICENSES.md']
    const destination = resolve(assetsDir, assetName)
    if (assetName.endsWith('.zip')) {
      execFileSync('zip', ['-9', '-q', destination, ...files], { cwd: staging, env: { ...process.env, LC_ALL: 'C' } })
    } else {
      const tar = execFileSync('tar', ['-cf', '-', ...files], { cwd: staging, env: { ...process.env, LC_ALL: 'C' }, maxBuffer: 256 * 1024 * 1024 })
      writeFileSync(destination, gzipSync(tar, { level: 9 }))
    }
    recordAsset(assetName)
  } finally {
    // 作者: long
    // 仅清理本函数创建的临时目录，不触碰 CI 原始产物或调用方的公开输出目录。
    rmSync(staging, { recursive: true, force: true })
  }
}

function listFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name)
    return entry.isDirectory() ? listFiles(path) : entry.isFile() ? [path] : []
  })
}

function copyAsset(source, name) {
  const destination = resolve(assetsDir, name)
  copyFileSync(source, destination)
  recordAsset(name)
}

function recordAsset(name) {
  const destination = resolve(assetsDir, name)
  const bytes = statSync(destination).size
  if (!bytes) throw new Error(`prepared asset is empty: ${name}`)
  preparedAssets.push({ name, bytes, sha256: createHash('sha256').update(readFileSync(destination)).digest('hex') })
}

function writeInternalManifest() {
  const manifest = { product: 'FluxDown', version, generatedAt: new Date().toISOString(), assets: [...preparedAssets].sort((a, b) => a.name.localeCompare(b.name)) }
  const bytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)
  // 作者: long
  // 清单只服务于上传前完整性校验，放在 assets 外即可避免成为用户下载项；公开校验值写入 Release Notes。
  writeFileSync(resolve(dirname(assetsDir), 'release-manifest.json'), bytes)
}

function writeReleaseNotes() {
  const changelog = readFileSync(resolve(root, `docs/releases/${version}.md`), 'utf8').trim()
  const download = (name) => `https://github.com/lonnnnnng/fluxdown/releases/download/v${version}/${name}`
  const checksumRows = [...preparedAssets]
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((asset) => `| \`${asset.name}\` | ${asset.bytes} | \`${asset.sha256}\` |`)
    .join('\n')
  const notes = `# FluxDown ${version}

${changelog}

## 下载安装

| 平台 | 推荐下载 |
| --- | --- |
| Android | [Release APK](${download(`FluxDown-${version}-android-release.apk`)}) |
| Windows x64 | [安装向导 EXE](${download(`FluxDown-${version}-windows-x86_64-setup.exe`)}) |
| macOS Apple Silicon | [DMG](${download(`FluxDown-${version}-macos-aarch64.dmg`)}) |
| Linux x64 | [DEB](${download(`FluxDown-${version}-linux-amd64.deb`)}) / [RPM](${download(`FluxDown-${version}-linux-x86_64.rpm`)}) |

## 命令行版本

[Windows x64 ZIP](${download(`fluxdown-${version}-windows-x86_64.zip`)}) · [macOS ARM64 TAR.GZ](${download(`fluxdown-${version}-macos-aarch64.tar.gz`)}) · [Linux x64 TAR.GZ](${download(`fluxdown-${version}-linux-amd64.tar.gz`)})

CLI 解压后运行其中的 fluxdown/fluxdown.exe；压缩包包含许可证，Unix 可执行权限已保留。Android APK 仍兼容 arm64-v8a、armeabi-v7a 和 x86_64，没有为了减包移除架构。

## 资产说明

本次公开 10 个文件，加上 GitHub 自动提供的 2 个源码压缩包，Assets 共 12 项。内部 manifest 仅用于流水线上传前校验，不作为公开下载项。

Debug APK、AAB、iOS simulator/unsigned app、MSI、裸桌面程序和 macOS app 构建目录仅保留在对应 Actions Artifacts，不再混入用户下载区。iOS 目前没有面向普通用户的可安装发行包。

[项目许可证](${download(`FluxDown-${version}-LICENSE.txt`)}) · [第三方许可证](${download(`FluxDown-${version}-THIRD-PARTY-LICENSES.md`)})

## 文件校验

| 文件 | 字节数 | SHA-256 |
| --- | ---: | --- |
${checksumRows}
`
  writeFileSync(resolve(dirname(assetsDir), 'RELEASE_NOTES.md'), notes)
}
