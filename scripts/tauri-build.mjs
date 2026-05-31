import { spawn } from 'node:child_process'
import { platform } from 'node:os'

const args = ['build']
const bundles = process.env.TAURI_BUNDLES?.trim()

if (bundles) {
  args.push('--bundles', bundles)
} else if (platform() === 'darwin') {
  args.push('--bundles', 'app')
}

const child = spawn('tauri', args, {
  shell: platform() === 'win32',
  stdio: 'inherit',
})

child.on('error', (error) => {
  console.error(error)
  process.exit(1)
})

child.on('exit', (code) => {
  process.exit(code ?? 1)
})
