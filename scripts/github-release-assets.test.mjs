import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, resolve } from 'node:path'
import test from 'node:test'
import { publicReleaseAssetNames, verifyPublicReleaseAssets } from './verify-github-release-assets.mjs'

const root = resolve(import.meta.dirname, '..')
const version = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
const required = [
  'fluxdown-cli-linux/fluxdown',
  'fluxdown-cli-macos/fluxdown',
  'fluxdown-cli-windows/fluxdown.exe',
  'fluxdown-desktop-macos/bundle/FluxDown.dmg',
  'fluxdown-desktop-linux/bundle/FluxDown.deb',
  'fluxdown-desktop-linux/bundle/FluxDown.rpm',
  'fluxdown-desktop-windows/bundle/FluxDown-setup.exe',
  'fluxdown-android-release-apk/app-release.apk',
]
const internal = [
  'fluxdown-android-debug-apk/app-debug.apk',
  'fluxdown-android-release-aab/app-release.aab',
  'fluxdown-desktop-windows/fluxdown-desktop.exe',
  'fluxdown-desktop-windows/bundle/FluxDown.msi',
  'fluxdown-desktop-linux/fluxdown-desktop',
  'fluxdown-desktop-macos/FluxDown.app/Contents/MacOS/fluxdown-desktop',
  'fluxdown-ios-simulator/Runner.app/Runner',
  'fluxdown-ios-device-unsigned/Runner.app/Runner',
  'fluxdown-ios-release-ipa/FluxDown.ipa',
  'fluxdown-ffi-ios-static/libfluxdown_ffi.a',
  'fluxdown-android-symbols/app.android-arm64.symbols',
  'fluxdown-android-symbols/mapping.txt',
  'fluxdown-ios-symbols/app.ios-arm64.symbols',
]

function fixture(t, inputs = [...required, ...internal]) {
  const directory = mkdtempSync(resolve(tmpdir(), 'fluxdown-release-policy-'))
  // 作者: long
  // 测试仅创建和清理自身的临时假产物，不能触碰本地正式安装包或真实 Release 下载目录。
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const raw = resolve(directory, 'raw')
  const assets = resolve(directory, 'assets')
  for (const name of inputs) {
    const path = resolve(raw, name)
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, `isolated release policy fixture: ${name}\n`)
  }
  return {
    raw, assets,
    prepare: () => spawnSync(process.execPath, [resolve(root, 'scripts/prepare-github-release-assets.mjs'), raw, assets], { encoding: 'utf8' }),
  }
}

test('publishes exactly 11 files and leaves development artifacts out', (t) => {
  const data = fixture(t)
  const result = data.prepare()
  assert.equal(result.status, 0, result.stderr)
  assert.equal(readdirSync(data.assets).length, 11)
  assert.deepEqual(verifyPublicReleaseAssets(data.assets, version), publicReleaseAssetNames(version))
  assert.equal(publicReleaseAssetNames(version).filter((name) => name.endsWith('.apk')).length, 1)
  assert.equal(publicReleaseAssetNames(version).filter((name) => /debug|ios-|\.aab$|\.msi$|\.app\.tar\.gz$|fluxdown-desktop-/.test(name)).length, 0)
  const notes = readFileSync(resolve(data.assets, '../RELEASE_NOTES.md'), 'utf8')
  assert.match(notes, /Assets 共 13 项/)
  assert.match(notes, new RegExp(`releases/download/v${version}/FluxDown-${version}-windows-x86_64-setup.exe`))
})

for (const [platform, artifact, binaryName, extension] of [
  ['macos-aarch64', 'fluxdown-cli-macos', 'fluxdown', 'tar.gz'],
  ['linux-amd64', 'fluxdown-cli-linux', 'fluxdown', 'tar.gz'],
  ['windows-x86_64', 'fluxdown-cli-windows', 'fluxdown.exe', 'zip'],
]) {
  test(`CLI archive preserves ${platform} bytes and notices`, (t) => {
    const data = fixture(t)
    const prepared = data.prepare()
    assert.equal(prepared.status, 0, prepared.stderr)
    const archive = resolve(data.assets, `fluxdown-${version}-${platform}.${extension}`)
    const unpacked = resolve(data.assets, '../unpacked')
    mkdirSync(unpacked)
    const options = { env: { ...process.env, LC_ALL: 'C' } }
    if (extension === 'zip') execFileSync('unzip', ['-q', archive, '-d', unpacked], options)
    else execFileSync('tar', ['-xzf', archive, '-C', unpacked], options)
    assert.deepEqual(readdirSync(unpacked).sort(), [binaryName, 'LICENSE.txt', 'THIRD-PARTY-LICENSES.md'].sort())
    assert.deepEqual(readFileSync(resolve(unpacked, binaryName)), readFileSync(resolve(data.raw, artifact, binaryName)))
    assert.deepEqual(readFileSync(resolve(unpacked, 'LICENSE.txt')), readFileSync(resolve(root, 'LICENSE')))
    if (extension !== 'zip') assert.equal(statSync(resolve(unpacked, binaryName)).mode & 0o111, 0o111)
  })
}

test('public preparation does not require internal artifacts', (t) => {
  const result = fixture(t, required).prepare()
  assert.equal(result.status, 0, result.stderr)
})

test('fails when a user installer is missing', (t) => {
  const result = fixture(t, required.filter((name) => !name.endsWith('.apk'))).prepare()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /found 0/)
})

test('fails instead of guessing between multiple installers', (t) => {
  const result = fixture(t, [...required, 'fluxdown-desktop-windows/bundle/Other-setup.exe']).prepare()
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /found 2/)
})

test('does not clear or reuse a nonempty output directory', (t) => {
  const data = fixture(t)
  mkdirSync(data.assets)
  const marker = resolve(data.assets, 'existing.txt')
  writeFileSync(marker, 'preserve')
  assert.notEqual(data.prepare().status, 0)
  assert.equal(readFileSync(marker, 'utf8'), 'preserve')
})

test('rejects unexpected public assets', (t) => {
  const data = fixture(t)
  assert.equal(data.prepare().status, 0)
  writeFileSync(resolve(data.assets, 'app-debug.apk'), 'unexpected')
  assert.throws(() => verifyPublicReleaseAssets(data.assets, version), /公开资产清单不匹配/)
})

test('rejects changed file content after preparing the manifest', (t) => {
  const data = fixture(t)
  assert.equal(data.prepare().status, 0)
  writeFileSync(resolve(data.assets, `FluxDown-${version}-android-release.apk`), 'tampered')
  assert.throws(() => verifyPublicReleaseAssets(data.assets, version), /SHA-256 不匹配/)
})

test('rejects duplicate entries in the manifest', (t) => {
  const data = fixture(t)
  assert.equal(data.prepare().status, 0)
  const path = resolve(data.assets, `FluxDown-${version}-release-manifest.json`)
  const manifest = JSON.parse(readFileSync(path, 'utf8'))
  manifest.assets.push(manifest.assets[0])
  writeFileSync(path, JSON.stringify(manifest))
  assert.throws(() => verifyPublicReleaseAssets(data.assets, version), /manifest清单不匹配/)
})
