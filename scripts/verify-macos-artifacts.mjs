import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const version = readPackageVersion()
const cliPath = resolve(root, 'target/release/fluxdown')
const desktopBinaryPath = resolve(root, 'target/release/fluxdown-desktop')
const appPath = resolve(root, 'target/release/bundle/macos/FluxDown.app')
const appExecutablePath = join(appPath, 'Contents/MacOS/fluxdown-desktop')
const infoPlistPath = join(appPath, 'Contents/Info.plist')
const dmgPath = resolve(root, `target/release/bundle/dmg/FluxDown_${version}_aarch64.dmg`)

const expectedProtocols = [
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

verifyFile(cliPath, 'target/release/fluxdown')
verifyFile(desktopBinaryPath, 'target/release/fluxdown-desktop')
verifyDirectory(appPath, 'target/release/bundle/macos/FluxDown.app')
verifyFile(appExecutablePath, 'FluxDown.app/Contents/MacOS/fluxdown-desktop')
verifyFile(infoPlistPath, 'FluxDown.app/Contents/Info.plist')
verifyFile(dmgPath, `target/release/bundle/dmg/FluxDown_${version}_aarch64.dmg`)

verifyCli()
verifyInfoPlist()
verifyAppSignature()
verifyDmg()

console.log('ok macos artifacts deep verification')

function verifyCli() {
  const versionOutput = run(cliPath, ['--version']).stdout.trim()
  assert(versionOutput === `fluxdown ${version}`, `unexpected CLI version output: ${versionOutput}`)

  const detectOutput = run(cliPath, ['detect', 'https://example.com/file.zip']).stdout.trim()
  assert(detectOutput === 'Https', `unexpected detect output: ${detectOutput}`)

  const support = JSON.parse(run(cliPath, ['support', 'https://example.com/file.zip']).stdout)
  assert(support.executable === true, 'HTTPS support must be executable')

  const doctor = JSON.parse(run(cliPath, ['doctor']).stdout)
  for (const protocol of expectedProtocols) {
    const item = doctor.protocols.find((entry) => entry.protocol === protocol)
    assert(item, `doctor missing protocol ${protocol}`)
    assert(item.configured === true, `doctor protocol ${protocol} is not configured`)
    assert(item.executable === true, `doctor protocol ${protocol} is not executable`)
  }
  console.log('ok cli   version, detect, support, doctor')
}

function verifyInfoPlist() {
  const expected = {
    CFBundleDisplayName: 'FluxDown',
    CFBundleExecutable: 'fluxdown-desktop',
    CFBundleIdentifier: 'dev.fluxdown.desktop',
    CFBundleName: 'FluxDown',
    CFBundleShortVersionString: version,
    CFBundleVersion: version,
  }

  for (const [key, value] of Object.entries(expected)) {
    const actual = plistValue(key)
    assert(actual === value, `Info.plist ${key} expected ${value}, got ${actual}`)
  }
  console.log('ok app   Info.plist metadata')
}

function verifyAppSignature() {
  // 作者: long
  // 这里校验的是本地 ad-hoc 签名完整性，不代表已经完成开发者证书签名或 notarization。
  run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath])
  console.log('ok app   ad-hoc signature')
}

function verifyDmg() {
  run('hdiutil', ['verify', dmgPath])
  console.log('ok dmg   checksum valid')
}

function plistValue(key) {
  return run('/usr/libexec/PlistBuddy', ['-c', `Print:${key}`, infoPlistPath]).stdout.trim()
}

function verifyFile(path, label) {
  if (!existsSync(path)) {
    fail(`${label} does not exist`)
  }
  const stat = statSync(path)
  if (!stat.isFile()) {
    fail(`${label} is not a file`)
  }
  if (stat.size === 0) {
    fail(`${label} is empty`)
  }
  console.log(`ok file ${label} (${stat.size} bytes)`)
}

function verifyDirectory(path, label) {
  if (!existsSync(path)) {
    fail(`${label} does not exist`)
  }
  const stat = statSync(path)
  if (!stat.isDirectory()) {
    fail(`${label} is not a directory`)
  }
  if (readdirSync(path).length === 0) {
    fail(`${label} is empty`)
  }
  console.log(`ok dir  ${label}`)
}

function run(command, args) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (result.status !== 0) {
    fail(`${command} ${args.join(' ')} failed\n${result.stderr.trim()}`)
  }
  return result
}

function readPackageVersion() {
  return JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
}

function assert(condition, message) {
  if (!condition) {
    fail(message)
  }
}

function fail(message) {
  console.error(`macOS artifact verification failed: ${message}`)
  process.exit(1)
}
