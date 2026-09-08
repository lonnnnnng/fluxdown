import { createHash } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { basename, dirname, join, relative, resolve } from 'node:path'
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

copyRequiredFile('fluxdown-cli-linux', (name) => name === 'fluxdown', `fluxdown-${version}-linux-amd64`)
copyRequiredFile('fluxdown-cli-macos', (name) => name === 'fluxdown', `fluxdown-${version}-macos-aarch64`)
copyRequiredFile('fluxdown-cli-windows', (name) => name === 'fluxdown.exe', `fluxdown-${version}-windows-x86_64.exe`)
copyRequiredFile('fluxdown-desktop-macos', (name) => name.endsWith('.dmg'), `FluxDown-${version}-macos-aarch64.dmg`)
copyRequiredFile('fluxdown-desktop-linux', (name) => name.endsWith('.deb'), `FluxDown-${version}-linux-amd64.deb`)
copyRequiredFile('fluxdown-desktop-linux', (name) => name.endsWith('.rpm'), `FluxDown-${version}-linux-x86_64.rpm`)
copyRequiredFile('fluxdown-desktop-windows', (name) => name.endsWith('-setup.exe'), `FluxDown-${version}-windows-x86_64-setup.exe`)
copyRequiredFile('fluxdown-android-release-apk', (name) => name === 'app-release.apk', `FluxDown-${version}-android-release.apk`)

// 作者: long
// Debug APK、AAB、iOS 验证包、MSI、裸桌面程序与 macOS app 压缩包继续保留为 Actions Artifacts，不公开到 Release。
copyAsset(resolve(root, 'LICENSE'), `FluxDown-${version}-LICENSE.txt`)
copyAsset(resolve(root, 'docs/third-party-licenses.md'), `FluxDown-${version}-THIRD-PARTY-LICENSES.md`)
writeManifest()
verifyPublicReleaseAssets(assetsDir, version)
writeReleaseNotes()
console.log(`prepared ${preparedAssets.length} public release assets in ${relative(root, assetsDir)}`)

function copyRequiredFile(artifactName, predicate, assetName) {
  const artifactDir = resolve(rawDir, artifactName)
  const matches = existsSync(artifactDir)
    ? listFiles(artifactDir).filter((file) => predicate(basename(file).toLowerCase()))
    : []
  if (matches.length !== 1) throw new Error(`expected exactly one ${assetName} in ${artifactName}, found ${matches.length}`)
  copyAsset(matches[0], assetName)
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
  const bytes = statSync(destination).size
  if (!bytes) throw new Error(`prepared asset is empty: ${name}`)
  preparedAssets.push({ name, bytes, sha256: createHash('sha256').update(readFileSync(destination)).digest('hex') })
}

function writeManifest() {
  const name = `FluxDown-${version}-release-manifest.json`
  const manifest = { product: 'FluxDown', version, generatedAt: new Date().toISOString(), assets: [...preparedAssets].sort((a, b) => a.name.localeCompare(b.name)) }
  const bytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`)
  writeFileSync(resolve(assetsDir, name), bytes)
  preparedAssets.push({ name, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') })
}

function writeReleaseNotes() {
  const changelog = readFileSync(resolve(root, `docs/releases/${version}.md`), 'utf8').trim()
  const download = (name) => `https://github.com/lonnnnnng/fluxdown/releases/download/v${version}/${name}`
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

[Windows x64](${download(`fluxdown-${version}-windows-x86_64.exe`)}) · [macOS ARM64](${download(`fluxdown-${version}-macos-aarch64`)}) · [Linux x64](${download(`fluxdown-${version}-linux-amd64`)})

## 资产说明

本次公开 11 个文件，加上 GitHub 自动提供的 2 个源码压缩包，Assets 共 13 项。文件大小与 SHA-256 见 [release manifest](${download(`FluxDown-${version}-release-manifest.json`)})。

Debug APK、AAB、iOS simulator/unsigned app、MSI、裸桌面程序和 macOS app 构建目录仅保留在对应 Actions Artifacts，不再混入用户下载区。iOS 目前没有面向普通用户的可安装发行包。

[项目许可证](${download(`FluxDown-${version}-LICENSE.txt`)}) · [第三方许可证](${download(`FluxDown-${version}-THIRD-PARTY-LICENSES.md`)})
`
  writeFileSync(resolve(dirname(assetsDir), 'RELEASE_NOTES.md'), notes)
}
