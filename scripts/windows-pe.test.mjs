import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import { verifyWindowsSubsystem } from './windows-pe.mjs'

function fixture(magic = 0x20b, subsystem = 2) {
  const bytes = Buffer.alloc(512)
  bytes.write('MZ')
  bytes.writeUInt32LE(128, 0x3c)
  bytes.writeUInt32LE(0x00004550, 128)
  bytes.writeUInt16LE(240, 148)
  bytes.writeUInt16LE(magic, 152)
  bytes.writeUInt16LE(subsystem, 220)
  return bytes
}

for (const magic of [0x10b, 0x20b]) {
  for (const subsystem of [2, 3]) {
    test(`accepts PE ${magic.toString(16)} subsystem ${subsystem}`, () => {
      assert.equal(verifyWindowsSubsystem(fixture(magic, subsystem), subsystem), subsystem)
    })
  }
}

test('rejects console desktop and GUI CLI binaries', () => {
  assert.throws(() => verifyWindowsSubsystem(fixture(0x20b, 3), 2), /must be GUI \(2\), got 3/)
  assert.throws(() => verifyWindowsSubsystem(fixture(), 3), /must be Console \(3\), got 2/)
})

test('rejects incomplete and invalid PE headers without out-of-bounds reads', () => {
  assert.throws(() => verifyWindowsSubsystem(Buffer.alloc(63), 2), /invalid PE/)
  assert.throws(() => verifyWindowsSubsystem(Buffer.alloc(512), 2), /invalid PE/)
  assert.throws(() => verifyWindowsSubsystem(fixture().subarray(0, 200), 2), /invalid PE/)
  assert.throws(() => verifyWindowsSubsystem(fixture(0x107), 2), /invalid PE/)
  for (const offset of [0, 500, 0xffff_ffff]) {
    const bytes = fixture()
    bytes.writeUInt32LE(offset, 0x3c)
    assert.throws(() => verifyWindowsSubsystem(bytes, 2), /invalid PE/)
  }
  const signature = fixture()
  signature.writeUInt32LE(0, 128)
  assert.throws(() => verifyWindowsSubsystem(signature, 2), /invalid PE/)
  const size = fixture()
  size.writeUInt16LE(69, 148)
  assert.throws(() => verifyWindowsSubsystem(size, 2), /invalid PE/)
})

for (const [name, expected] of [
  ['fluxdown-desktop.exe', 2],
  ['fluxdown-desktop-windows-x86_64.exe', 2],
  ['fluxdown.exe', 3],
  ['fluxdown-windows-x86_64.exe', 3],
]) {
  test(`artifact command enforces subsystem for ${name}`, (t) => {
    const directory = mkdtempSync(join(tmpdir(), 'fluxdown-pe-'))
    // 作者: long
    // 这里只生成不可执行的文件头夹具测试发布门禁，不启动应用，也不触碰已下载的正式安装包。
    t.after(() => rmSync(directory, { recursive: true, force: true }))
    const path = join(directory, name)
    const run = () => spawnSync(process.execPath, [fileURLToPath(new URL('./verify-artifacts.mjs', import.meta.url)), 'file', path], { encoding: 'utf8' })
    writeFileSync(path, fixture(0x20b, expected))
    assert.equal(run().status, 0)
    writeFileSync(path, fixture(0x20b, expected === 2 ? 3 : 2))
    const rejected = run()
    assert.equal(rejected.status, 1)
    assert.match(rejected.stderr, /Windows PE subsystem must be/)
  })
}
