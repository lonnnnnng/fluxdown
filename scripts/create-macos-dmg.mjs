import { readFileSync } from 'node:fs'
import { mkdir, rm, stat } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { spawn } from 'node:child_process'

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
await mkdir(dirname(dmgPath), { recursive: true })
await rm(dmgPath, { force: true })
await run('hdiutil', [
  'create',
  '-volname',
  'FluxDown',
  '-srcfolder',
  appPath,
  '-ov',
  '-format',
  'UDZO',
  dmgPath,
])
