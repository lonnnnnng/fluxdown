# FluxDown Desktop

Tauri + React desktop GUI for FluxDown.

## Commands

```sh
npm run dev
npm run build
npm run tauri:build
npm run tauri:dmg
```

`tauri:build` builds the native app bundle only. On macOS it produces `target/release/bundle/macos/FluxDown.app`.

`tauri:dmg` runs `tauri:build` and then creates `target/release/bundle/dmg/FluxDown_<version>_aarch64.dmg` through the repository `scripts/create-macos-dmg.mjs` helper. The helper intentionally avoids Finder AppleScript so the DMG can be produced from CI and headless environments.

On Windows and Linux, `tauri:build` lets Tauri use its normal platform bundle targets. The repository CI uploads the generated installer formats from `target/release/bundle`.
