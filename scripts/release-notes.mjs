const CHECKSUM_MARKER = /文件校验|校验明细|完整性校验|校验值|校验和|文件哈希|哈希值|checksums?|checksum|digest|sha-?256/i

// 作者: long
// 发布说明允许保留功能验证文字，但文件校验明细只给流水线使用，不能再次渲染到 GitHub Release 页面。
export function stripChecksumTables(markdown) {
  const lines = markdown.split(/\r?\n/)
  const output = []

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index]
    const heading = /^(#{1,6})\s+(.+?)\s*$/.exec(line.trim())

    // 作者: long
    // 兼容旧发行说明中的“文件校验”整段；按标题级别停止，避免吞掉后续下载说明。
    if (heading && CHECKSUM_MARKER.test(heading[2])) {
      const level = heading[1].length
      index += 1
      while (index < lines.length) {
        const nextHeading = /^(#{1,6})\s+/.exec(lines[index].trim())
        if (nextHeading && nextHeading[1].length <= level) break
        index += 1
      }
      index -= 1
      continue
    }

    // 作者: long
    // 只删除表头明确包含校验字段的 Markdown 表格，平台下载表等普通表格保持不变。
    const next = lines[index + 1]?.trim() ?? ''
    const separatorCells = next.replace(/^\||\|$/g, '').split('|').map((cell) => cell.trim())
    const isTableHeader = line.includes('|') && separatorCells.length > 1 && separatorCells.every((cell) => /^:?-{3,}:?$/.test(cell))
    if (isTableHeader && CHECKSUM_MARKER.test(line)) {
      index += 2
      while (index < lines.length && lines[index].includes('|')) index += 1
      index -= 1
      continue
    }

    output.push(line)
  }

  return output.join('\n').replace(/\n{3,}/g, '\n\n').trim()
}
