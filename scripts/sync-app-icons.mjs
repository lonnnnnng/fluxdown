import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'

const root = resolve(import.meta.dirname, '..')
const sourceDir = resolve(root, 'apps/desktop/src-tauri/icons')
const mobileAndroidDir = resolve(root, 'apps/mobile/android/app/src/main/res')
const mobileIosDir = resolve(root, 'apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset')

// 作者: long
// 桌面 Tauri 图标是唯一品牌源；集中复制生成后的平台资源，避免 Flutter 端继续保留默认图标。
const androidDensities = ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']
for (const density of androidDensities) {
  for (const name of ['ic_launcher.png', 'ic_launcher_round.png', 'ic_launcher_foreground.png']) {
    copy(
      join(sourceDir, 'android', `mipmap-${density}`, name),
      join(mobileAndroidDir, `mipmap-${density}`, name),
    )
  }
}
copy(
  join(sourceDir, 'android', 'mipmap-anydpi-v26', 'ic_launcher.xml'),
  join(mobileAndroidDir, 'mipmap-anydpi-v26', 'ic_launcher.xml'),
)
copy(
  join(sourceDir, 'android', 'values', 'ic_launcher_background.xml'),
  join(mobileAndroidDir, 'values', 'ic_launcher_background.xml'),
)

const iosIcons = [
  ['AppIcon-20x20@1x.png', 'Icon-App-20x20@1x.png'],
  ['AppIcon-20x20@2x.png', 'Icon-App-20x20@2x.png'],
  ['AppIcon-20x20@3x.png', 'Icon-App-20x20@3x.png'],
  ['AppIcon-29x29@1x.png', 'Icon-App-29x29@1x.png'],
  ['AppIcon-29x29@2x.png', 'Icon-App-29x29@2x.png'],
  ['AppIcon-29x29@3x.png', 'Icon-App-29x29@3x.png'],
  ['AppIcon-40x40@2x.png', 'Icon-App-40x40@2x.png'],
  ['AppIcon-40x40@3x.png', 'Icon-App-40x40@3x.png'],
  ['AppIcon-60x60@2x.png', 'Icon-App-60x60@2x.png'],
  ['AppIcon-60x60@3x.png', 'Icon-App-60x60@3x.png'],
  ['AppIcon-76x76@1x.png', 'Icon-App-76x76@1x.png'],
  ['AppIcon-76x76@2x.png', 'Icon-App-76x76@2x.png'],
  ['AppIcon-83.5x83.5@2x.png', 'Icon-App-83.5x83.5@2x.png'],
  ['AppIcon-512@2x.png', 'Icon-App-1024x1024@1x.png'],
]
for (const [source, destination] of iosIcons) {
  copy(join(sourceDir, 'ios', source), join(mobileIosDir, destination))
}

// 作者: long
// Web 预览和桌面窗口使用同一份品牌图形，避免构建产物仍显示旧的 Vite 紫色闪电。
writeFileSync(
  resolve(root, 'apps/desktop/public/favicon.svg'),
  readFileSync(join(sourceDir, 'source.svg')),
)

function copy(source, destination) {
  mkdirSync(dirname(destination), { recursive: true })
  copyFileSync(source, destination)
}

console.log('synced desktop FluxDown icon assets to Android, iOS, and web favicon')
