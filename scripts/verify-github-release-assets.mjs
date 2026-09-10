import { createHash } from 'node:crypto'
import { lstatSync, readFileSync, readdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const root = resolve(import.meta.dirname, '..')

export function publicReleaseAssetNames(version) {
  return [
    `FluxDown-${version}-android-release.apk`,
    `FluxDown-${version}-windows-x86_64-setup.exe`,
    `FluxDown-${version}-macos-aarch64.dmg`,
    `FluxDown-${version}-linux-amd64.deb`,
    `FluxDown-${version}-linux-x86_64.rpm`,
    `fluxdown-${version}-windows-x86_64.zip`,
    `fluxdown-${version}-macos-aarch64.tar.gz`,
    `fluxdown-${version}-linux-amd64.tar.gz`,
    `FluxDown-${version}-LICENSE.txt`,
    `FluxDown-${version}-THIRD-PARTY-LICENSES.md`,
  ].sort()
}

export function verifyPublicReleaseAssets(directory, version) {
  // 作者: long
  // 公开下载区只提供用户安装包、CLI 和说明文件；精确清单可阻止调试包或上次构建残留被误发布。
  const expected = publicReleaseAssetNames(version)
  const actual = readdirSync(directory).sort()
  assertSameNames(actual, expected, '公开资产')
  for (const name of actual) {
    const stat = lstatSync(resolve(directory, name))
    if (!stat.isFile() || stat.size === 0) throw new Error(`资产不是非空普通文件: ${name}`)
  }

  // 作者: long
  // manifest 留在公开 assets 的同级目录供 CI 使用，不上传到 Release；用户校验值由 Release Notes 展示。
  const manifest = JSON.parse(readFileSync(resolve(directory, '../release-manifest.json'), 'utf8'))
  if (manifest.product !== 'FluxDown' || manifest.version !== version || !Array.isArray(manifest.assets)) {
    throw new Error('发布清单的产品、版本或 assets 格式不正确')
  }
  assertSameNames(manifest.assets.map((asset) => asset.name).sort(), expected, 'manifest')
  // 作者: long
  // 内部 manifest 中的公开文件必须逐一核对大小与 SHA-256，避免缺包、错包和上传前内容变化。
  for (const asset of manifest.assets) {
    const bytes = readFileSync(resolve(directory, asset.name))
    const sha256 = createHash('sha256').update(bytes).digest('hex')
    if (asset.bytes !== bytes.length || asset.sha256 !== sha256) {
      throw new Error(`资产大小或 SHA-256 不匹配: ${asset.name}`)
    }
  }
  return actual
}

function assertSameNames(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}清单不匹配: expected ${JSON.stringify(expected)}, actual ${JSON.stringify(actual)}`)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    const version = JSON.parse(readFileSync(resolve(root, 'package.json'), 'utf8')).version
    const directory = resolve(root, process.argv[2] ?? 'dist/github-release/assets')
    const assets = verifyPublicReleaseAssets(directory, version)
    console.log(`ok public release: ${assets.length} assets, manifest sizes and SHA-256 verified`)
  } catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
