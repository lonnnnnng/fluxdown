# FluxDown Desktop

[中文](README.zh-CN.md)

Tauri + React desktop GUI for FluxDown.

## Commands

```sh
npm run dev
npm run build
npm run tauri:build
npm run tauri:dmg
```

`tauri:build` builds the native app bundle only. On macOS it produces `target/release/bundle/macos/FluxDown.app`.

`tauri:dmg` runs `tauri:build` and then creates a standard drag-to-install image at `target/release/bundle/dmg/FluxDown_<version>_aarch64.dmg` through the repository `scripts/create-macos-dmg.mjs` helper. Open the DMG and drag `FluxDown.app` onto the `Applications` entry in the same window; after installation, launch `/Applications/FluxDown.app` without opening the DMG again. The helper intentionally avoids Finder AppleScript so the DMG can be produced from CI and headless environments.

On Windows and Linux, `tauri:build` lets Tauri use its normal platform bundle targets. The repository CI uploads the generated installer formats from `target/release/bundle`.
