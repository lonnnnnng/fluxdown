import { readdir, rm } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

const repoRoot = fileURLToPath(new URL('..', import.meta.url))
const bundleDirs = ['target/release/bundle/macos', 'target/release/bundle/dmg']

await Promise.all(
  bundleDirs.map(async (dir) => {
    let entries
    const absoluteDir = join(repoRoot, dir)
    try {
      entries = await readdir(absoluteDir)
    } catch (error) {
      if (error?.code === 'ENOENT') return
      throw error
    }

    await Promise.all(
      entries
        .filter((entry) => /^rw\.\d+\..+\.dmg$/.test(entry))
        .map((entry) => rm(join(absoluteDir, entry), { force: true })),
    )
  }),
)
