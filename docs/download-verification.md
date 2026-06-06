# 下载验证状态

截至 2026-06-06，FluxDown 还没有完成“每一端安装或启动后实际下载成功”的全端端到端验证。

本页用于区分两类容易混淆的结论：

- 构建、测试、CI 和 Release artifact 校验：确认代码能编译、测试能跑、产物存在且非空。
- 真实下载端到端验证：在目标平台安装或启动对应 CLI/GUI/App，添加下载任务，并确认文件真实写入完成。

当前可以确认的是前者覆盖较多，后者只覆盖了核心层和少量协议场景，不能表述为“所有端都下载验证通过”。

## 分端结论

| 端 | 当前验证情况 | 是否完成真实下载 E2E |
| --- | --- | --- |
| 桌面 CLI | Rust 单元测试、CLI 集成测试、队列测试和本地 HTTP 下载检查覆盖最多。 | 部分完成 |
| macOS GUI | 已有 Tauri 构建、DMG 和 CI artifact 检查。没有安装 GUI 后通过界面完成下载验证。 | 未完成 |
| Windows GUI | 已有 CI/Docker 构建产物和 artifact 检查。没有在 Windows 上安装或运行 GUI 完成下载验证。 | 未完成 |
| Linux GUI | 已有 Linux GUI 可执行文件、`.deb`、`.rpm` artifact 检查。没有安装包后通过界面完成下载验证。 | 未完成 |
| Android App | 已有 Flutter 测试、APK/AAB 构建和 artifact 检查。没有安装到模拟器或真机后通过 App 完成下载验证。 | 未完成 |
| iPhone App | 已有 simulator / unsigned device 编译产物检查。缺少签名 IPA，也没有在 iPhone 或模拟器中完成 App 内下载验证。 | 未完成 |

## 分协议结论

| 协议/能力 | 当前验证情况 | 备注 |
| --- | --- | --- |
| HTTP/HTTPS | CLI 和核心层有本地下载验证。 | 证据最充分。 |
| WebDAV/WebDAVS | 核心层验证了 URL 到 HTTP/HTTPS 传输的映射和本地下载路径。 | 仍需要真实 WebDAV 服务端验证。 |
| m3u8/HLS | 核心层覆盖本地 HLS playlist、AES-128 分片和 master playlist 首个变体。 | 仍需要真实公网 playlist 验证。 |
| FTP/FTPS | 有实现和 URL 解析测试。 | 缺少真实 FTP/FTPS 服务端下载闭环。 |
| SFTP | 有实现和 URL 解析测试。 | 缺少真实 SFTP 服务端下载闭环。 |
| SMB | 有实现和 URL 解析测试。 | 缺少真实 SMB 共享下载闭环。 |
| BitTorrent `.torrent` | 有实现路径。 | 缺少真实 torrent 下载完成验证。 |
| Magnet | 有磁力链接识别和添加路径。 | 缺少真实 magnet 下载完成验证。 |
| ed2k | 核心层验证了 aMule `ed2k` CLI 移交路径。 | FluxDown 不掌控外部客户端的实际下载完成状态。 |
| IPFS | 有网关映射实现。 | 缺少真实 IPFS 网关下载闭环。 |

## 当前准确表述

FluxDown 已经具备多端架构、构建产物、CI/Release artifact 校验和部分核心协议下载测试，但尚未完成每个平台 CLI/GUI/App 安装或启动后的真实下载端到端验证。

在完成目标系统上的安装、启动、任务添加、下载完成和文件校验前，不应宣称对应端已经通过下载验证。

## 后续验证建议

1. 先建立可重复测试资源：本地 HTTP/WebDAV、FTP、SFTP、SMB 服务和小体积 HLS playlist。
2. 逐端验证最小闭环：CLI、macOS GUI、Linux GUI、Windows GUI、Android App、iPhone App。
3. 每次验证记录：平台、版本、安装方式、下载源、输出路径、文件大小、校验和、失败日志。
4. 再补真实公网协议：torrent、magnet、IPFS、ed2k 外部客户端移交。
