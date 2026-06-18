import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const thirdPartyLicenses = readFileSync(resolve(root, 'docs/third-party-licenses.md'), 'utf8')

const requiredRustDependencies = readCargoWorkspaceDependencies()
const requiredDesktopDependencies = readDesktopRuntimeDependencies()
const requiredMobileDependencies = readMobileRuntimeDependencies()

let hasError = false

verifyDocumentMentions('Rust workspace', requiredRustDependencies)
verifyDocumentMentions('Desktop runtime', requiredDesktopDependencies)
verifyDocumentMentions('Flutter mobile runtime', requiredMobileDependencies)
verifyRiskCallout()

if (!hasError) {
  console.log('ok licenses docs/third-party-licenses.md covers direct release dependencies')
}

function verifyDocumentMentions(group, dependencies) {
  for (const dependency of dependencies) {
    const marker = dependency.startsWith('@') ? dependency : `\`${dependency}\``
    if (!thirdPartyLicenses.includes(marker)) {
      console.error(`license verification failed: ${group} dependency ${dependency} is missing from docs/third-party-licenses.md`)
      hasError = true
    }
  }
}

function verifyRiskCallout() {
  if (!thirdPartyLicenses.includes('libtorrent_flutter') || !thirdPartyLicenses.includes('GPL')) {
    console.error('license verification failed: libtorrent_flutter GPL risk callout is missing')
    hasError = true
  }
}

function readCargoWorkspaceDependencies() {
  const cargoToml = readFileSync(resolve(root, 'Cargo.toml'), 'utf8')
  const block = extractTomlBlock(cargoToml, 'workspace.dependencies')
  return block
    .split(/\r?\n/)
    .map((line) => line.replace(/#.*/, '').trim())
    .filter(Boolean)
    .map((line) => line.match(/^([A-Za-z0-9_-]+)\s*=/)?.[1])
    .filter(Boolean)
    .sort((a, b) => a.localeCompare(b))
}

function readDesktopRuntimeDependencies() {
  const packageJson = JSON.parse(readFileSync(resolve(root, 'apps/desktop/package.json'), 'utf8'))
  return Object.keys(packageJson.dependencies ?? {}).sort((a, b) => a.localeCompare(b))
}

function readMobileRuntimeDependencies() {
  const pubspec = readFileSync(resolve(root, 'apps/mobile/pubspec.yaml'), 'utf8')
  const dependencies = extractYamlDependencyBlock(pubspec, 'dependencies')
  return dependencies
    .filter((dependency) => dependency !== 'flutter')
    .sort((a, b) => a.localeCompare(b))
}

function extractTomlBlock(source, blockName) {
  const lines = source.split(/\r?\n/)
  const start = lines.findIndex((line) => line.trim() === `[${blockName}]`)
  if (start === -1) {
    throw new Error(`Cargo.toml is missing [${blockName}]`)
  }

  const block = []
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index]
    // long: 许可证清单只覆盖当前 TOML 段的直接依赖，遇到新段立即停止，避免把 workspace 其他配置误判成依赖。
    if (/^\s*\[.+\]\s*$/.test(line)) {
      break
    }
    block.push(line)
  }
  return block.join('\n')
}

function extractYamlDependencyBlock(source, blockName) {
  const lines = source.split(/\r?\n/)
  const start = lines.findIndex((line) => line === `${blockName}:`)
  if (start === -1) {
    throw new Error(`apps/mobile/pubspec.yaml is missing ${blockName}:`)
  }

  const dependencies = []
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index]
    if (/^[A-Za-z_][\w-]*:\s*$/.test(line)) {
      break
    }
    const match = line.match(/^\s{2}([A-Za-z0-9_]+):\s*/)
    if (match) {
      dependencies.push(match[1])
    }
  }
  return dependencies
}

if (hasError) {
  process.exitCode = 1
}
