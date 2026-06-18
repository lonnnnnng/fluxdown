import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { basename, dirname, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const profile = process.argv[2] ?? 'local'
const extra = process.argv.slice(3)
const version = readPackageVersion()
const releaseDir = `dist/release/FluxDown-${version}`
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

const profiles = {
  local: [
    ['file', 'target/release/fluxdown'],
    ['file', 'target/release/fluxdown-desktop'],
    ['dir', 'target/release/bundle/macos/FluxDown.app'],
    ['file', `target/release/bundle/dmg/${macosDmgName}`],
    ['file', 'apps/mobile/build/app/outputs/flutter-apk/app-release.apk'],
    ['file', 'apps/mobile/build/app/outputs/bundle/release/app-release.aab'],
    ['dir', 'apps/mobile/build/ios/framework/Debug/App.xcframework'],
    ['dir', 'apps/mobile/build/ios/framework/Debug/Flutter.xcframework'],
    ['dir', 'apps/mobile/build/ios/iphonesimulator/Runner.app'],
    ['dir', 'apps/mobile/build/ios/iphoneos/Runner.app'],
  ],
  'linux-cli': [
    ['file', 'dist/linux-amd64/fluxdown'],
  ],
  'linux-gui': [
    ['file', 'dist/linux-gui/fluxdown-desktop'],
    ['glob', 'dist/linux-gui/*.deb'],
    ['glob', 'dist/linux-gui/*.rpm'],
  ],
  'linux-gui-ci': [
    ['file', 'target/release/fluxdown-desktop'],
    ['glob', 'target/release/bundle/deb/*.deb'],
    ['glob', 'target/release/bundle/rpm/*.rpm'],
  ],
  'windows-cli': [
    ['file', 'dist/windows-gnu/fluxdown.exe'],
  ],
  'windows-gui': [
    ['file', 'dist/windows-gui-gnu/fluxdown-desktop.exe'],
    ['file', 'dist/windows-gui-gnu/WebView2Loader.dll'],
  ],
  'desktop-macos': [
    ['file', 'target/release/fluxdown-desktop'],
    ['dir', 'target/release/bundle/macos/FluxDown.app'],
    ['file', `target/release/bundle/dmg/${macosDmgName}`],
  ],
  'desktop-windows': [
    ['file', 'target/release/fluxdown-desktop.exe'],
    ['glob', 'target/release/bundle/msi/*.msi'],
    ['glob', 'target/release/bundle/nsis/*.exe'],
  ],
  'desktop-windows-ci': [
    ['file', 'target/release/fluxdown-desktop.exe'],
    ['glob', 'target/release/bundle/msi/*.msi'],
    ['glob', 'target/release/bundle/nsis/*.exe'],
  ],
  android: [
    ['file', 'apps/mobile/build/app/outputs/flutter-apk/app-release.apk'],
    ['file', 'apps/mobile/build/app/outputs/bundle/release/app-release.aab'],
  ],
  'ios-framework': [
    ['dir', 'apps/mobile/build/ios/framework/Debug/App.xcframework'],
    ['dir', 'apps/mobile/build/ios/framework/Debug/Flutter.xcframework'],
  ],
  'ios-simulator': [
    ['dir', 'apps/mobile/build/ios/iphonesimulator/Runner.app'],
  ],
  'ios-device-unsigned': [
    ['dir', 'apps/mobile/build/ios/iphoneos/Runner.app'],
  ],
  'ci-config': [
    ['file', '.github/workflows/build.yml'],
    ['file', 'apps/mobile/ios/ExportOptions.plist'],
    ['file', 'apps/mobile/ios/ExportOptions.ci.plist'],
  ],
  release: [
    ['file', `${releaseDir}/FluxDown-release-manifest.json`],
    ['file', `${releaseDir}/desktop/macos/fluxdown-macos-aarch64`],
    ['file', `${releaseDir}/desktop/macos/${macosReleaseDmgName}`],
    ['file', `${releaseDir}/desktop/linux/fluxdown-linux-amd64`],
    ['file', `${releaseDir}/desktop/linux/fluxdown-desktop-linux-amd64`],
    ['file', `${releaseDir}/desktop/linux/${linuxDebName}`],
    ['file', `${releaseDir}/desktop/linux/${linuxRpmName}`],
    ['file', `${releaseDir}/desktop/windows/fluxdown-windows-x86_64.exe`],
    ['file', `${releaseDir}/desktop/windows/fluxdown-desktop-windows-x86_64.exe`],
    ['file', `${releaseDir}/desktop/windows/WebView2Loader.dll`],
    ['file', `${releaseDir}/mobile/android/${androidApkName}`],
    ['file', `${releaseDir}/mobile/android/${androidAabName}`],
    ['file', `${releaseDir}/mobile/ios/${iosSimulatorName}`],
    ['file', `${releaseDir}/mobile/ios/${iosDeviceUnsignedName}`],
    ['file', `${releaseDir}/mobile/ios/${iosDebugAppFrameworkName}`],
    ['file', `${releaseDir}/mobile/ios/${iosDebugFlutterFrameworkName}`],
    ['file', `${releaseDir}/licenses/LICENSE`],
    ['file', `${releaseDir}/licenses/THIRD-PARTY-LICENSES.md`],
  ],
}

function fail(message) {
  console.error(`artifact verification failed: ${message}`)
  process.exitCode = 1
}

function verify(kind, relativePath) {
  const path = resolve(root, relativePath)
  if (kind === 'glob') {
    verifyGlob(relativePath)
    return
  }

  if (!existsSync(path)) {
    fail(`${relativePath} does not exist`)
    return
  }

  const stat = statSync(path)
  if (kind === 'file') {
    if (!stat.isFile()) {
      fail(`${relativePath} is not a file`)
    } else if (stat.size === 0) {
      fail(`${relativePath} is empty`)
    } else {
      console.log(`ok file ${relativePath} (${stat.size} bytes)`)
    }
    return
  }

  if (!stat.isDirectory()) {
    fail(`${relativePath} is not a directory`)
  } else if (readdirSync(path).length === 0) {
    fail(`${relativePath} is empty`)
  } else {
    console.log(`ok dir  ${relativePath}`)
  }
}

function verifyGlob(relativePattern) {
  const dir = resolve(root, dirname(relativePattern))
  const pattern = basename(relativePattern)
  const regex = new RegExp(`^${pattern.split('*').map(escapeRegExp).join('.*')}$`)
  if (!existsSync(dir)) {
    fail(`${relativePattern} parent directory does not exist`)
    return
  }

  const matches = readdirSync(dir).filter((entry) => regex.test(entry))
  if (matches.length === 0) {
    fail(`${relativePattern} matched no files`)
    return
  }

  for (const match of matches) {
    const relativePath = `${dirname(relativePattern)}/${match}`
    verify('file', relativePath)
  }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

function readPackageVersion() {
  return JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
}

function verifyCiConfig() {
  const workflow = readFileSync(resolve(root, '.github/workflows/build.yml'), 'utf8')
  const onBlock = extractTopLevelBlock(workflow, 'on')

  if (!/^\s{2}workflow_dispatch:\s*$/m.test(onBlock)) {
    fail('.github/workflows/build.yml must keep workflow_dispatch as the only build trigger')
  }

  const triggerNames = [...onBlock.matchAll(/^\s{2}([A-Za-z_][\w-]*):\s*$/gm)].map((match) => match[1])
  const forbiddenTriggers = triggerNames.filter((name) => name !== 'workflow_dispatch')
  if (forbiddenTriggers.length > 0) {
    fail(`.github/workflows/build.yml must not auto-run on ${forbiddenTriggers.join(', ')}`)
  }

  if (!/run_mode:\s*\n\s+description:\s+"只在明确需要打包或发版时选择；普通代码推送不要运行"\s*\n\s+required:\s+true\s*\n\s+type:\s+choice\s*\n\s+default:\s+package\s*\n\s+options:\s*\n\s+- package\s*\n\s+- release/m.test(onBlock)) {
    fail('.github/workflows/build.yml must require an explicit package/release manual mode')
  }

  if (!/^concurrency:\s*$/m.test(workflow) || !/^\s{2}cancel-in-progress:\s*true\s*$/m.test(workflow)) {
    fail('.github/workflows/build.yml must cancel duplicate manual build runs for the same ref')
  }

  if (!/^\s{2}preflight:\s*$/m.test(workflow) || !/Release mode must run on a v\* tag ref/.test(workflow)) {
    fail('.github/workflows/build.yml must fail release mode early when the ref is not a v* tag')
  }

  if (!/inputs\.run_mode == 'release' && startsWith\(github\.ref, 'refs\/tags\/v'\)/.test(workflow)) {
    fail('.github/workflows/build.yml release job must require release mode on a v* tag ref')
  }

  console.log('ok ci   .github/workflows/build.yml manual-only trigger policy')
}

function extractTopLevelBlock(source, key) {
  const lines = source.split(/\r?\n/)
  const start = lines.findIndex((line) => line === `${key}:`)
  if (start === -1) {
    fail(`.github/workflows/build.yml is missing top-level ${key}: block`)
    return ''
  }

  const block = []
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index]
    // long: workflow 触发策略只允许手动入口；遇到下一个顶层键时停止，避免把 jobs 内的配置误判为触发事件。
    if (/^[A-Za-z_][\w-]*:\s*$/.test(line)) {
      break
    }
    block.push(line)
  }
  return block.join('\n')
}

if (profile === 'file') {
  for (const relativePath of extra) {
    verify('file', relativePath)
  }
} else if (profile === 'dir') {
  for (const relativePath of extra) {
    verify('dir', relativePath)
  }
} else if (profile === 'glob') {
  for (const relativePattern of extra) {
    verify('glob', relativePattern)
  }
} else if (profiles[profile]) {
  for (const [kind, relativePath] of profiles[profile]) {
    verify(kind, relativePath)
  }
  if (profile === 'ci-config') {
    verifyCiConfig()
  }
} else {
  console.error(`unknown artifact verification profile: ${profile}`)
  console.error(`known profiles: ${Object.keys(profiles).join(', ')}, file, dir`)
  process.exitCode = 1
}
