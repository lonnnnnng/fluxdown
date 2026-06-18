# 需求文档

## 背景

FluxDown 面向需要在多设备上处理不同来源下载任务的用户。目标是提供一个统一下载器，覆盖常见直链、文件服务器、P2P、流媒体播放列表和特殊链接，并在桌面端提供 CLI 与 GUI，在移动端提供 App。

## 产品目标

- 支持主流传输类型：HTTP/HTTPS、WebDAV/WebDAVS、FTP/FTPS、BitTorrent `.torrent`、Magnet、ed2k、m3u8/HLS、SFTP、SMB 和 IPFS。
- 覆盖主要平台：Windows、macOS、Linux、Android、iPhone。
- 桌面端同时提供 CLI 和 GUI，满足自动化脚本与日常图形操作两类场景。
- 移动端提供本地队列、开始、暂停、删除和批量运行能力。
- 对下载任务提供统一状态模型，便于未来同步、远程控制和任务迁移。

## 用户角色

- 普通下载用户：通过 GUI 或 App 添加链接，查看进度，暂停或继续任务。
- 命令行用户：使用 `fluxdown` CLI 检测协议、检查后端、立即下载或管理本地队列。
- 发布维护者：使用本地脚本和 GitHub Actions 构建多端产物，准备 GitHub Release。
- 技术集成方：基于 Rust core 的任务模型或 CLI JSON 输出集成到自动化系统。

## 范围

### 桌面端 CLI

CLI 需要支持：

- `detect`：识别输入源协议。
- `support`：输出协议运行时支持状态。
- `doctor`：检查内建和外部后端可用性。
- `download`：立即执行单个下载并输出 JSON 摘要。
- `add`、`list`、`start`、`run`、`pause`、`resume`、`remove`：管理本地下载队列。
- 通过 `--store` 覆盖默认队列文件路径。

### 桌面端 GUI

桌面 GUI 需要支持：

- 输入下载源、输出目录和可选文件名。
- 展示协议识别和支持状态。
- 添加任务到本地队列。
- 查看任务列表、任务状态、错误信息和下载进度。
- 对任务执行开始、暂停、继续、删除。
- 批量运行队列并支持并发数参数。

当前 GUI 通过 Tauri command 调用 Rust core，和 CLI 使用同一个桌面队列文件。

### 移动端 App

移动端 App 需要支持：

- Android 和 iPhone 本地运行。
- 本地 JSON 队列持久化。
- 添加、删除、开始、暂停任务。
- 运行队列，使用有界并发。
- HTTP/HTTPS 和可映射到 HTTP 的协议支持进度、暂停和断点续传。
- ed2k 链接移交给系统中已安装的兼容 App。

移动端不要求提供 CLI。

## 关键用户流程

### 立即下载

1. 用户提供下载源和输出目录。
2. 系统识别协议。
3. 系统选择内建后端或外部移交后端。
4. 下载器写入目标文件。
5. 完成后返回协议、后端、输出路径、写入字节数、断点续传起点和总大小。

### 队列下载

1. 用户添加任务到队列。
2. 任务初始状态为 `queued`。
3. 用户单独启动任务或运行整个队列。
4. 运行器将任务置为 `running`，下载过程中周期性写入进度。
5. 完成后状态变为 `finished`；失败后状态变为 `failed` 并记录错误；暂停后状态变为 `paused`。

### 暂停和继续

1. 用户对运行中的任务执行暂停。
2. 运行器检测队列状态变化并触发取消令牌。
3. 下载器停止写入并保留部分文件。
4. 用户继续时任务回到 `queued`，再次运行时由协议后端尝试从已有文件大小继续。

断点续传依赖协议和服务端能力。HTTP 需要服务端支持 `Range`；FTP 使用 `REST`；SFTP 使用偏移读取；部分协议或外部移交后端可能无法精确恢复。

## 协议需求

| 协议 | 需求 |
| --- | --- |
| HTTP/HTTPS | 直链下载、文件名推断、基础认证、进度、暂停、Range 续传。 |
| WebDAV/WebDAVS | 映射为 HTTP/HTTPS 文件 GET 下载，复用 HTTP 下载能力。 |
| FTP/FTPS | 被动模式、二进制传输、进度、暂停、REST 续传。 |
| SFTP | 密码认证、文件大小读取、偏移续传。 |
| SMB | SMB2/3 文件下载、进度、取消。 |
| BitTorrent `.torrent` | 支持本地或远程 torrent 源，下载到指定目录；拿到 metadata 后使用真实文件列表更新任务名，多文件种子必须允许用户选择下载内容。 |
| Magnet | 通过 torrent 引擎添加 magnet 链接；拿到 metadata 后使用真实文件列表更新任务名，多文件 magnet 必须允许用户选择下载内容。 |
| ed2k | 桌面优先使用 aMule `ed2k` CLI，否则系统 URL handler；移动端移交系统兼容 App。 |
| m3u8/HLS | 支持 VOD 播放列表、主播放列表首个变体、AES-128 分片解密；移动端 Android 输出最终 `.mp4`。 |
| IPFS | 将 `ipfs://` 映射到公共网关下载。 |

## 非功能需求

- 跨平台构建：CI 必须能生成 CLI、桌面 GUI、Android、iOS 验证产物。
- 本地优先：任务队列和下载状态默认保存在本机，不依赖云服务。
- 可观测：CLI 命令和运行报告使用 JSON 输出，便于脚本读取。
- 可恢复：支持协议应尽量保留部分文件并复用已有字节。
- 可发布：标签版本和 `package.json` 版本必须一致后才能发布 Release。

## 非目标

- 当前不提供云同步账号体系。
- 当前不提供远程 Web 控制台。
- 当前不实现原生 ed2k 协议栈，只做 aMule/系统/App 移交。
- 当前不提供下载内容安全扫描、版权判断或资源索引服务。
- 当前不承诺直播 HLS、DRM HLS、DASH 或复杂自适应流完整支持。
- 当前不承诺移动端后台长期下载在所有系统版本上保持运行；这需要进一步的系统后台任务设计。

## 验收标准

- `cargo test -p fluxdown-core -p fluxdown-cli` 通过。
- `npm --workspace apps/desktop run build` 通过。
- `cd apps/mobile && flutter analyze && flutter test` 通过。
- `.github/workflows/build.yml` 能在 GitHub Actions 中构建并上传多端产物。
- 在 `v<package.json version>` 标签 ref 上手动运行流水线，并设置 `run_mode=release` 后，发布作业能上传 Release assets。
- 文档中的协议支持状态和当前代码实现一致。
