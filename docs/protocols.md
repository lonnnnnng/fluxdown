# 协议支持矩阵

本文档记录当前代码库的协议支持状态。状态分为：

- 内建：FluxDown 自身实现下载流程。
- 移交：提交给外部命令、系统 URL handler 或已安装 App。
- 计划中：已识别但当前不可执行。

## 总表

| 协议 | 识别方式 | 桌面 CLI/GUI | Android/iPhone App | 备注 |
| --- | --- | --- | --- | --- |
| HTTP | `http://` | 内建 | 内建 | 支持进度、暂停、Range 续传。 |
| HTTPS | `https://` | 内建 | 内建 | 支持 URL 用户名密码基础认证，移动端主要走普通 HTTP client。 |
| WebDAV | `webdav://` | 内建 | 内建 | 映射到 HTTP 下载。 |
| WebDAVS | `webdavs://` | 内建 | 内建 | 映射到 HTTPS 下载。 |
| FTP | `ftp://` | 内建 | 内建 | 被动模式、二进制传输、REST 续传。 |
| FTPS | `ftps://` | 内建 | 内建 | 依赖 TLS 支持和服务端兼容性。 |
| SFTP | `sftp://` | 内建 | 内建 | 当前要求密码认证；不支持密钥文件配置。 |
| SMB | `smb://` | 内建 | 内建 | SMB2/3 文件下载。 |
| `.torrent` | URL 或路径以 `.torrent` 结尾 | 内建 | 内建 | 桌面用 `librqbit`，移动端用 `libtorrent_flutter`。 |
| Magnet | `magnet:?` | 内建 | 内建 | 依赖 torrent 后端。 |
| ed2k | `ed2k://` | 移交 | 移交 | 桌面优先 aMule `ed2k` CLI，否则系统 handler；移动端移交兼容 App。 |
| m3u8/HLS | URL 或路径以 `.m3u8` 结尾 | 内建 | 内建 | VOD 播放列表，支持 AES-128 分片；移动端 Android 转封装输出 `.mp4`。 |
| IPFS | `ipfs://` | 内建 | 内建 | 映射到 `https://ipfs.io/ipfs/...` 公共网关。 |
| Unknown | 未匹配 | 计划中 | 计划中 | 不会执行下载。 |

## 桌面端细节

桌面端下载能力在 `crates/fluxdown-core/src/downloader.rs` 中实现，CLI 和 Tauri GUI 共用这一层。

### HTTP/HTTPS

- 使用 `reqwest` 流式下载。
- 如果目标文件已存在，会发送 `Range: bytes=<existing>-`。
- 服务端返回 `206 Partial Content` 时追加写入；返回 `200 OK` 时重新覆盖写入。
- 支持从 URL 中提取用户名和密码并使用 Basic Auth。
- 文件名从 URL path 推断，缺失时使用 `download.bin`，也可由用户指定。

### WebDAV/WebDAVS

- `webdav://` 转换为 `http://`。
- `webdavs://` 转换为 `https://`。
- 下载执行复用 HTTP/HTTPS 实现。
- 当前不实现 PROPFIND、目录遍历、上传或删除。

### FTP/FTPS

- 使用 `suppaftp`。
- 支持被动模式和二进制传输。
- 使用服务器 `SIZE` 获取总大小，使用 `REST` 从部分文件大小恢复。
- FTPS 依赖服务端 TLS 行为，兼容性需要按目标服务器验证。

### SFTP

- 使用 `ssh2`。
- URL 需要包含主机、用户名和密码。
- 通过远程文件 size 和本地部分文件长度实现偏移续传。
- 当前未提供 SSH private key、known_hosts 校验策略或跳板机配置。

### SMB

- 使用 `smb2`。
- 解析 `smb://` URL 中的主机、共享名和远程路径。
- 支持文件下载、进度和取消。
- 当前不实现目录同步或递归下载。

### BitTorrent 和 Magnet

- 使用 `librqbit`。
- `.torrent` 可以是本地文件或 URL。
- Magnet 通过 torrent session 添加。
- 当前任务模型记录整体任务状态，不提供每个文件、peer、tracker 的完整细节。

### ed2k

- `doctor` 会检查 aMule `ed2k` CLI。
- 如果 `ed2k` CLI 可用，桌面端通过该命令提交链接。
- 如果命令不可用，退回系统 URL handler。
- FluxDown 不掌控外部客户端的实际下载进度和完成状态。

### m3u8/HLS

- 使用 `m3u8-rs` 解析播放列表。
- 支持 VOD media playlist。
- 遇到 master playlist 时选择第一个 variant。
- 支持 AES-128 CBC 分片解密。
- 将分片顺序写入一个 `.ts` 文件。
- 不支持 DRM、SAMPLE-AES、直播滚动窗口、复杂码率选择或转封装。

### IPFS

- `ipfs://<cid>/<path>` 映射到 `https://ipfs.io/ipfs/<cid>/<path>`。
- 实际可用性、速度和内容可访问性取决于公共网关。
- 当前不运行本地 IPFS 节点，也不使用 `ipfs` CLI 拉取。

## 移动端细节

移动端下载能力在 `apps/mobile/lib/src` 中实现。

### HTTP/HTTPS/WebDAV/IPFS

- 使用 Dart `http` client。
- 支持进度、暂停和 Range 续传。
- WebDAV/WebDAVS 和 IPFS 在移动端也通过 HTTP 兼容路径下载。

### FTP/FTPS

- 使用移动端自定义 FTP client。
- 支持被动模式、二进制模式、进度、暂停和 REST 续传。

### SFTP

- 使用 `dartssh2`。
- 当前聚焦密码认证。
- 支持远程 size 和 offset 读取。

### SMB

- 使用 `dart_smb2`。
- 支持 SMB2/3 文件下载、进度和取消。

### BitTorrent 和 Magnet

- 使用 `libtorrent_flutter`。
- 支持 `.torrent` 文件和 Magnet 链接。
- `.torrent` URL 会先下载到临时文件再添加到引擎。
- 拿到 libtorrent metadata 后会读取真实文件列表，卡片名从 `.torrent`
  文件名或临时 magnet 名称更新为真实下载文件名。
- 单文件种子会自动选择该文件；多文件种子会弹出文件列表供用户选择，
  并把未选文件的 libtorrent priority 设为 0。
- 任务 JSON 会保存 `torrentName`、`torrentFiles` 和
  `selectedTorrentFileIndexes`，用于恢复展示、打开和分享。
- 该依赖带有 GPL 原生组件，正式分发前必须审查许可证义务。

### ed2k

- 使用 `url_launcher` 打开 `ed2k://` 链接。
- Android manifest 声明 `ed2k` VIEW query。
- iOS Info.plist 声明 `LSApplicationQueriesSchemes`。
- 需要用户设备安装 eMule/aMule 兼容 App。

### m3u8/HLS

- 支持 VOD playlist、master playlist 首个 variant 和 AES-128 分片解密。
- Android 端先写入临时 TS，再转封装为最终 `.mp4` 文件。
- 暂不承诺直播、DRM 或复杂码率选择。

## 支持状态命令

桌面 CLI 可用于确认当前机器上协议和后端是否可执行：

```sh
cargo run -p fluxdown-cli -- detect "https://example.com/file.zip"
cargo run -p fluxdown-cli -- support "ed2k://|file|example|..."
cargo run -p fluxdown-cli -- doctor
```

`doctor` 的结果会包含每个后端的可用性和说明。内建后端总是可用；ed2k 可能因 aMule CLI 缺失而退回系统 handler。

## 已知限制

- URL 中携带的用户名和密码可能进入队列 JSON 和日志输出，不建议在共享环境中明文使用敏感凭据。
- 断点续传依赖服务端或后端支持，不能保证所有资源都可恢复。
- 移交型协议无法提供完整进度和完成状态。
- 移动端后台下载能力受 Android/iOS 系统策略影响，当前以 App 前台执行为主要路径。
- P2P 协议的可用性受网络环境、tracker、peer、移动系统限制和平台审核政策影响。
