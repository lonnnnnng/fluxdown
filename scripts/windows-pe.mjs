// 作者: long
// 直接检查实际 EXE 的 PE 文件头，防止构建脚本忽略 GUI 子系统声明；只校验启动类型，不改写发行文件。
export function verifyWindowsSubsystem(bytes, expected) {
  if (bytes.length < 64 || bytes.toString('ascii', 0, 2) !== 'MZ') {
    throw new Error('invalid PE: missing DOS header')
  }
  const pe = bytes.readUInt32LE(0x3c)
  if (pe < 64 || pe > bytes.length - 24 || bytes.readUInt32LE(pe) !== 0x00004550) {
    throw new Error('invalid PE: missing PE signature or COFF header')
  }
  const optional = pe + 24
  const size = bytes.readUInt16LE(pe + 20)
  if (size < 70 || optional + size > bytes.length) {
    throw new Error('invalid PE: truncated optional header')
  }
  const magic = bytes.readUInt16LE(optional)
  if (magic !== 0x10b && magic !== 0x20b) {
    throw new Error('invalid PE: unsupported optional header magic')
  }
  // 作者: long
  // PE32 与 PE32+ 的 Subsystem 都在可选头偏移 68；GUI=2，CLI=3，不能把安装器的 GUI 标记当作主程序的。
  const actual = bytes.readUInt16LE(optional + 68)
  if (actual !== expected) {
    throw new Error(`Windows PE subsystem must be ${expected === 2 ? 'GUI' : 'Console'} (${expected}), got ${actual}`)
  }
  return actual
}
