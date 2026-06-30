# Windows 原生 Tauri GUI 13 协议真实下载验证报告

验证时间：2026-06-30 09:21 CST
验证环境：Windows 开发机，`target/e2e-gui/debug/fluxdown-desktop.exe`，FluxDown `1.0.4`
验证命令：`python scripts/verify-windows-desktop-gui-protocols.py --app target/e2e-gui/debug/fluxdown-desktop.exe --keep-work-dir`
原始证据：`docs/artifacts/windows-desktop-gui-protocol-e2e-20260630.json`
截图证据：`docs/artifacts/windows-desktop-gui-queue-20260630.png`、`docs/artifacts/windows-desktop-gui-settings-20260630.png`

## 结论

本轮验证使用 Windows 原生 Tauri 桌面窗口前台操作完成，不再用 CLI/core 结论替代 GUI。脚本通过 WebView2 CDP 驱动真实 `fluxdown-desktop.exe` 窗口，逐项点击设置页、创建下载任务、点击“开始队列”，并在任务列表中等待状态进入 `finished` 或 ed2k 的系统移交完成状态。

HTTP、HTTPS、WebDAV、WebDAVS、FTP、FTPS、m3u8/HLS、SFTP、SMB、Torrent、Magnet、IPFS 均通过 GUI 前台路径完成真实文件落盘和 SHA-256 校验。ed2k 当前仍按产品定义验证系统/aMule 移交，不声明 FluxDown 内建下载完成。

## 设置页验证

设置页通过原生窗口逐项切换菜单并验证行级设置项；协议能力和高级诊断不是普通表单行，原始 JSON 额外记录了后端列表、13 个协议 chip、后端自检提示和诊断健康度。

| 菜单 | 验证项 |
| --- | --- |
| 基础设置 | 默认保存位置、创建后自动开始、列表刷新间隔 |
| 下载策略 | 同时运行任务数、单任务线程数、自动重试数、最大下载网速 |
| 协议能力 | 点击“检查后端”，设置页显示“后端自检已更新” |
| 存储与完成 | 文件命名策略、SHA-256 校验、Torrent 文件选择、完成后打开 |
| 安全与隐私 | 敏感链接脱敏、错误提示脱敏、外部后端提示 |
| 高级诊断 | 能力完整度和后端状态展示 |

## 验证矩阵

| 协议 | GUI 用例 | 结果 | GUI 状态 | 字节数 | SHA-256 |
| --- | --- | --- | --- | ---: | --- |
| HTTP | `win-gui-http-local` | 通过 | `finished` | 29 | `4b21578d7e688e10e3022a5d0cb630e8e69c0aaabded4b85193f124dc3332367` |
| HTTPS | `win-gui-https-local-self-signed` | 通过 | `finished` | 30 | `cc3ebe482bc02e3a2a620cecf7af4494127a601d97c1118022b9240a8bdbd348` |
| WebDAV | `win-gui-webdav-local-transport` | 通过 | `finished` | 31 | `a10150697e18cfa7514b650d6c0a177f8e843df0cda2a7b24d2f4023b851db97` |
| WebDAVS | `win-gui-webdavs-local-transport` | 通过 | `finished` | 32 | `554627841a921f67b3b1f22cab53d908f78f25cc2b74591f21da8f082d8ea1c1` |
| FTP | `win-gui-ftp-local` | 通过 | `finished` | 28 | `51e3ec3c46ae4903d6acc26ceff6d42ce29402966850f0fdf76d54c03ae7f19f` |
| FTPS | `win-gui-ftps-local-explicit` | 通过 | `finished` | 29 | `a449606cbe0666e54c511bdaae62ef4ba22bf8793d0ab203803abf54099090d2` |
| m3u8/HLS | `win-gui-m3u8-local-vod` | 通过 | `finished` | 48 | `7ecf9fe1bba3dd832ea1a76fdf837034bb91028068a3e6d954f37a58d49d46f1` |
| IPFS | `win-gui-ipfs-local-gateway` | 通过 | `finished` | 10 | `206f158bef5fbaeddee314d74b90d9259c5e2abee372bbac8f3c6e65fbb0d87b` |
| SFTP | `win-gui-sftp-local-docker` | 通过 | `finished` | 33 | `299fe7a22946acc8b8c6c3c6c0c2dae1c097a1c1dcc682fefdf129dd3102085d` |
| SMB | `win-gui-smb-local-docker` | 通过 | `finished` | 32 | `96275ee381ea27cc8edd212f60ba558071fe48b46146dd59a5241ab4cff129a6` |
| Torrent | `win-gui-torrent-local-docker-seed` | 通过 | `finished` | 36 | `b0d8d3dae051f1f073fcc1bd6c95c8f017679a54900cae02cace594b68d16821` |
| Magnet | `win-gui-magnet-local-docker-seed` | 通过 | `finished` | 36 | `b0d8d3dae051f1f073fcc1bd6c95c8f017679a54900cae02cace594b68d16821` |
| ed2k | `win-gui-ed2k-system-handoff` | 通过 | `finished` | 不适用 | 不适用 |

## 说明

- GUI 验证脚本会为 Windows E2E 启动独立 `XDG_DATA_HOME` 和 WebView2 data directory，避免污染用户日常队列和窗口状态。
- 常规 Tauri 启动不暴露 CDP；仅当 `FLUXDOWN_E2E_WEBVIEW2_ARGS` 存在时，桌面端会创建 E2E 专用窗口并传入 WebView2 remote debugging 参数。
- SFTP、SMB、Torrent、Magnet 使用 Docker fixture；Torrent/Magnet 通过本地 tracker 和 Transmission seeder 提供合法小体积资源。
- CLI/core 13 协议证据单独保留在 [Windows CLI 13 协议真实下载验证报告](protocol-e2e-windows-report-20260630.md) 中，本报告只覆盖 Windows 原生 Tauri GUI 前台路径。
