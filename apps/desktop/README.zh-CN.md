# FluxDown Desktop

[English](README.md)

FluxDown 的 Tauri + React 桌面 GUI。

## 命令

```sh
npm run dev
npm run build
npm run tauri:build
npm run tauri:dmg
```

`tauri:build` 只构建原生 App bundle。在 macOS 上会生成 `target/release/bundle/macos/FluxDown.app`。

`tauri:dmg` 会先运行 `tauri:build`，然后通过仓库中的 `scripts/create-macos-dmg.mjs` 辅助脚本创建标准拖拽安装镜像 `target/release/bundle/dmg/FluxDown_<version>_aarch64.dmg`。打开 DMG 后，将 `FluxDown.app` 拖到同一窗口中的“应用程序”入口完成安装；安装后从 `/Applications/FluxDown.app` 启动，不需要再次点击 DMG。脚本刻意避开 Finder AppleScript，因此可以在 CI 和 headless 环境中生成 DMG。

在 Windows 和 Linux 上，`tauri:build` 会让 Tauri 使用常规的平台 bundle target。仓库 CI 会从 `target/release/bundle` 上传生成的 installer 格式。
