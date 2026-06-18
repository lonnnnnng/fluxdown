# 第三方许可证清单

截至 2026-06-18，本项目自有代码采用 MIT License，许可证正文见仓库根目录 [LICENSE](../LICENSE)。

本清单用于发布前审查和 README 说明，不替代各依赖包自带的完整许可证文本。最终对外发布时，应以锁文件、构建产物和依赖包随附许可证为准重新生成完整 NOTICE / licenses bundle。

## 直接依赖概览

### Rust workspace

| 依赖 | 用途 | 许可证 |
| --- | --- | --- |
| `anyhow` | 错误处理 | MIT OR Apache-2.0 |
| `clap` | CLI 参数解析 | MIT OR Apache-2.0 |
| `reqwest` | HTTP/HTTPS/WebDAV/IPFS gateway 传输 | MIT OR Apache-2.0 |
| `tokio` | 异步运行时 | MIT |
| `serde` / `serde_json` | 队列和命令 JSON 序列化 | MIT OR Apache-2.0 |
| `librqbit` | BitTorrent / Magnet 下载 | Apache-2.0 |
| `m3u8-rs` | HLS playlist 解析 | MIT |
| `suppaftp` | FTP/FTPS 下载 | MIT OR Apache-2.0 |
| `ssh2` | SFTP 下载 | MIT OR Apache-2.0 |
| `smb2` | SMB2/3 下载 | MIT |
| `tauri` / `tauri-build` | 桌面 GUI 宿主和构建 | Apache-2.0 OR MIT |
| `aes` / `cbc` | HLS AES-128 解密 | MIT OR Apache-2.0 |
| `open` | ed2k 系统 URL handler 回退 | MIT |
| `futures-util` | 下载流处理和异步组合 | MIT OR Apache-2.0 |
| `percent-encoding` | URL 参数编码和 gateway 参数处理 | MIT OR Apache-2.0 |
| `thiserror` | 核心错误类型定义 | MIT OR Apache-2.0 |
| `url` | URL 解析和协议参数处理 | MIT OR Apache-2.0 |
| `uuid` | 下载任务 ID 生成 | Apache-2.0 OR MIT |
| `webpki-roots` | rustls 根证书集合 | CDLA-Permissive-2.0 |
| `tempfile` | 测试和验证脚本临时目录 | MIT OR Apache-2.0 |

### 桌面前端

| 依赖 | 用途 | 许可证 |
| --- | --- | --- |
| `@tauri-apps/api` | 前端调用 Tauri command | Apache-2.0 OR MIT |
| `react` / `react-dom` | 桌面 GUI 视图层 | MIT |
| `vite` | 前端构建 | MIT |
| `typescript` | 类型检查和构建 | Apache-2.0 |

### Flutter 移动端

| 依赖 | 用途 | 许可证审查状态 |
| --- | --- | --- |
| `http` | HTTP/WebDAV 下载 | 发布前需随锁文件生成完整许可证文本。 |
| `cupertino_icons` | iOS 风格图标资源 | MIT |
| `path` | 本地路径拼接和文件名处理 | BSD-3-Clause |
| `path_provider` | Android/iOS 下载目录解析 | BSD-3-Clause |
| `uuid` | 移动端下载任务 ID 生成 | MIT |
| `dartssh2` | SFTP 下载 | 发布前需随锁文件生成完整许可证文本。 |
| `dart_smb2` | SMB 下载 | 发布前需随锁文件生成完整许可证文本。 |
| `pointycastle` | HLS AES-128 解密 | 发布前需随锁文件生成完整许可证文本。 |
| `libtorrent_flutter` | BitTorrent / Magnet 下载 | 包含 GPL 许可原生组件，发布商店版本前必须完成 GPL 义务审查。 |
| `mobile_scanner` | 新建任务二维码扫描 | 发布前需随锁文件生成完整许可证文本。 |
| `file_picker` | 下载保存位置选择 | 发布前需随锁文件生成完整许可证文本。 |
| `open_filex` / `share_plus` | 打开和分享下载文件 | 发布前需随锁文件生成完整许可证文本。 |
| `shared_preferences` | 设置项持久化 | 发布前需随锁文件生成完整许可证文本。 |
| `url_launcher` | ed2k 外部 App 移交 | 发布前需随锁文件生成完整许可证文本。 |

## 发布前必须处理

1. 继续生成 Rust、npm、Flutter 三类依赖的完整许可证文本包；当前 Release assets 已随包提供项目 `LICENSE` 和本清单。
2. 单独评估 `libtorrent_flutter` 及其原生 libtorrent 组件的 GPL 义务；未完成前，不应把移动端 torrent/magnet 版本作为闭源商店正式包分发。
3. 检查 Linux 桌面包、Windows installer、macOS DMG、Android APK/AAB 和 iOS IPA 中实际打入的依赖，确保清单和产物一致。
4. 如果后续加入 aria2、yt-dlp、FFmpeg 或其他外部二进制，需要在本清单中单独列出其许可证和再分发义务。

## 当前验证边界

- 已补齐项目自有 MIT License 文本。
- 已列出当前主要直接依赖和移动端 GPL 风险点。
- 已增加轻量许可证清单校验：`npm run verify:licenses` 会检查 Rust workspace、桌面运行时依赖和 Flutter 移动端运行时依赖是否在本清单中出现，并校验 `libtorrent_flutter` GPL 风险提示仍然存在。
- Release staging 和 GitHub Release 资产准备脚本已随包输出项目 `LICENSE` 与本清单；但还没有生成所有传递依赖的完整 LICENSE bundle，也未把许可证审计设为 GitHub Actions 阻断项。
