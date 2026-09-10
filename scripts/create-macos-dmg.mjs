import { readFileSync } from 'node:fs'
import { cp, mkdir, mkdtemp, rm, stat, symlink } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { spawn } from 'node:child_process'
import { tmpdir } from 'node:os'

const repoRoot = fileURLToPath(new URL('..', import.meta.url))
const version = JSON.parse(readFileSync(join(repoRoot, 'package.json'), 'utf8')).version
const appPath = join(repoRoot, 'target/release/bundle/macos/FluxDown.app')
const dmgPath = join(repoRoot, `target/release/bundle/dmg/FluxDown_${version}_aarch64.dmg`)

async function ensureAppBundle() {
  const metadata = await stat(appPath).catch(() => null)
  if (!metadata?.isDirectory()) {
    throw new Error(`Missing app bundle: ${appPath}`)
  }
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: 'inherit' })
    child.on('error', reject)
    child.on('exit', (code) => {
      if (code === 0) {
        resolve()
      } else {
        reject(new Error(`${command} exited with code ${code}`))
      }
    })
  })
}

await ensureAppBundle()
await signAppBundle()
await mkdir(dirname(dmgPath), { recursive: true })
await rm(dmgPath, { force: true })
const stagingPath = await mkdtemp(join(tmpdir(), 'fluxdown-dmg-'))
try {
  // 作者: long
  // DMG 的根目录必须同时包含应用本体和 /Applications 入口；直接把 .app 作为 srcfolder
  // 只会生成“打开即运行”的镜像，用户每次都要重新点击 DMG，无法完成常规安装。
  await cp(appPath, join(stagingPath, 'FluxDown.app'), {
    recursive: true,
    dereference: false,
  })
  await symlink('/Applications', join(stagingPath, 'Applications'), 'dir')
  await run('hdiutil', [
    'create',
    '-volname',
    'FluxDown',
    '-srcfolder',
    stagingPath,
    '-ov',
    '-format',
    'UDZO',
    // 作者: long
    // 只提高现有 zlib 容器压缩等级，不改变镜像格式和系统兼容性。
    '-imagekey',
    'zlib-level=9',
    dmgPath,
  ])
  console.log(`Created macOS installer DMG: ${dmgPath}`)
} finally {
  await rm(stagingPath, { recursive: true, force: true })
}

async function signAppBundle() {
  // 作者: long
  // 本地打包没有开发者证书时也要进行 ad-hoc bundle 签名，确保 Info.plist 和资源被封入签名，避免 dmg 内的 .app 只有 linker signature。
  await run('codesign', ['--force', '--deep', '--sign', '-', appPath])
  await run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath])
}
