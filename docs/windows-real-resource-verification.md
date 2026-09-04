# Windows 端真实资源下载验证报告（1.0.11）

- 日期：2026-09-05
- 平台：Windows 10 Pro x64（build 19044）
- 被测对象：`fluxdown` CLI（release 构建）与 FluxDown 桌面端（Tauri GUI，debug 构建 CDP 驱动 + release 构建）
- 方法：全部用例通过**真实公网资源**完成下载，本地不搭任何 fixture；任务使用隔离 store 与隔离输出目录。
- 网络环境说明：本机经由 Clash 系统代理（127.0.0.1:7890）上网，BT 入站端口与 DHT UDP 直连受限，直接影响 torrent/magnet 完整传输能力（见边界章节）。

## 一、CLI 真实资源用例

| 用例 | 资源 | 结果 | 证据 |
| --- | --- | --- | --- |
| doctor | - | 通过 | 退出码 0 |
| HTTPS 多线程下载 | Cloudflare `speed.cloudflare.com/__down?bytes=10485760`，`--threads 8` | 通过 | `bytes_written=10485760`，与请求字节数完全一致 |
| HTTPS + SHA-256 校验 | `curl.se/ca/cacert.pem`，`--sha256 <官方值>` | 通过 | 下载文件 SHA-256 与 `cacert.pem.sha256` 官方值一致 |
| SHA-256 拒绝 | 同上，`--sha256 0*64` | 通过 | 退出码 1，报 `Sha256Mismatch`（文件按现有语义保留供核对） |
| FTP | Rebex 公网测试服务器 `ftp://demo:password@test.rebex.net/readme.txt` | 通过 | 379 字节 |
| SFTP | Rebex `sftp://demo:password@test.rebex.net/readme.txt` | 通过 | 379 字节，与 FTP 下载内容 SHA-256 一致 |
| FTPS | Rebex `ftps://demo:password@test.rebex.net/readme.txt`（隐式 TLS 990） | **失败（上游限制）** | 控制连接 TLS/登录成功，数据连接 TLS 握手被服务器拒绝；详见第二节 |
| HLS TS | Apple BipBop 16x9 `bipbop_16x9_variant.m3u8` | 通过 | 输出 59,366,640 字节 TS |
| HLS fMP4 | Apple BipBop Advanced fMP4 `master.m3u8` | 通过 | 输出 150,481,593 字节 |
| 协议识别 | `detect`：ftp / sftp / m3u8 / magnet | 通过 | 各返回预期协议 |
| 队列 add/list/run | 3 个 Cloudflare 524288 字节文件，`run --concurrency 2` | 通过 | 3 文件全部完成且字节数正确，耗时 4s |
| URL 凭据脱敏 | `add ftp://secretuser:secretpass@...` 后输出 | 通过 | 输出 JSON 中不含明文用户名/密码 |
| 暂停/恢复生命周期 | 8MB Cloudflare 文件 start→pause→resume→run | 通过 | 文件最终完成 |
| 限速 | `--speed-limit-mbps 0.25` 下载 2MB | 通过 | 实测 10.8s（无限制约 1s），限速生效 |
| Torrent | Debian 官方种子 `debian-13.6.0-amd64-netinst.iso.torrent` | **部分验证（网络受限）** | metadata 拉取、piece 分配、peer 连接（已下载 256KB）均工作；随后无进展触发 45s stall 保护正常报错。完整传输需 P2P 友好网络，见第三节 |
| Magnet | Debian infohash magnet + 官方 tracker | **部分验证（网络受限）** | DHT/trackers 在本机网络不可达，300s 未取得 metadata 后按预期失败退出 |

## 二、发现的问题与修复

### 2.1 FTPS 数据连接失败（真实缺陷，根因在 FTPS 引擎上游）

**现象**：`ftps://demo:password@test.rebex.net/readme.txt` 控制连接 TLS 与登录成功，但数据连接建立时 rustls 报 `received corrupt message of type InvalidContentType`（偶发 `tls handshake eof`），下载失败。

**定位过程**（示例最小复现程序 + Python 矩阵实验）：

1. 与 FluxDown 完全相同的 suppaftp + tokio-rustls 栈直连同一服务器：控制连接 TLS、登录都成功，`retr_as_stream` 阶段失败 —— 与 FluxDown 行为一致，排除 FluxDown 自身实现错误。
2. Python `ssl` 矩阵实验（同一服务器、同一协议）：数据连接 TLS 会话**复用**控制连接会话时收到完整 379 字节；不复用时握手虽成功但服务器拒绝发送数据（0 字节，控制通道报 `425 Cannot secure data connection`）。
3. 结论：Rebex（及 vsftpd `require_ssl_reuse=YES` 等同类服务器）强制 FTPS 数据连接复用控制连接的 TLS 会话；suppaftp 的 rustls/native-tls 后端均无法满足（上游 issue `veeso/suppaftp#93`，v11 仍未实现）。禁用 rustls resumption、强制 TLS1.2、schannel（native-tls）后端均无法绕过，已逐一实验排除。

**修复动作**：

- `suppaftp` 8.0.3 → 11.0.0：获得数据通道 `close_notify` 优雅关闭（严格 TLS 1.3 服务器必需，上游 changelog 标注对 test.rebex.net 复现）、CR/LF 命令注入防护、多行应答解析修复和 Windows 兼容修复。
- 新增 `DownloadError::FtpsDataTls`：FTPS 数据阶段错误不再报晦涩的 `Secure error: ...`，改为携带可操作提示（指向 TLS 会话复用限制与上游 issue）。
- 新增 2 个单元测试覆盖错误映射与提示文案；`cargo test -p fluxdown-core` 69 项全部通过。

**剩余边界**：对强制 TLS 会话复用的 FTPS 服务器（vsftpd 默认配置、Rebex 测试服务器），数据传输在 suppaftp 实现会话复用前仍不可用；不强制复用的 FTPS 服务器不受影响（本项目此前本地 fixture FTPS 用例仍通过）。该限制记录于 README 验证边界与本文档。

### 2.2 Torrent/Magnet 在受限网络的 stall 保护

Debian 官方种子验证确认 metadata、piece 分配与 peer 连接正常，但本机 BT 入站与 DHT 直连受限导致完整传输无法在此环境完成；`TORRENT_STALL_TIMEOUT` 45 秒无进展保护按设计工作，错误信息明确（`check tracker and peers`）。属于环境限制而非缺陷。

## 三、验证边界

| 项 | 状态 | 说明 |
| --- | --- | --- |
| FTPS 强制会话复用服务器 | 不支持（上游） | 待 `veeso/suppaftp#93`；其它 FTPS 服务器不受影响 |
| Torrent/Magnet 完整真实传输 | 本环境无法完成 | 需 BT 入站/DHT 可达的网络；建议在常规家用宽带（无强限制）复验 |
| WebDAV/SMB | 未列入本次真实资源用例 | 公网无可靠的匿名真实 WebDAV/SMB 服务器；沿用项目本地 fixture 验证结论 |
| ed2k | 按产品定义移交外部客户端，不构成内建下载 | 与既有文档一致 |

## 四、桌面 GUI 真实资源用例

debug 构建 `fluxdown-desktop.exe` + WebView2 CDP（复用项目 E2E 机制：`FLUXDOWN_E2E_DEV_URL` / `FLUXDOWN_E2E_WEBVIEW2_ARGS`），通过真实 GUI 前台点击「新建任务」填入公网资源并等待任务行进入完成态：

| 用例 | 资源 | 结果 | 证据 |
| --- | --- | --- | --- |
| GUI 启动 | vite dev server + Tauri WebView | 通过 | `queue-page` 渲染 |
| HTTP | Cloudflare 5MB | 通过 | 任务 `finished`，输出 5,242,880 字节 |
| FTP | Rebex readme.txt | 通过 | 任务 `finished`，379 字节 |
| SFTP | Rebex readme.txt | 通过 | 任务 `finished`，379 字节 |
| HLS | Apple BipBop TS | 通过 | 任务 `finished`，59,366,640 字节 |

## 五、结论

- Windows CLI 与桌面 GUI 的 HTTP/HTTPS（含多线程、限速、SHA-256）、FTP、SFTP、HLS（TS 与 fMP4）、队列控制、URL 脱敏在真实公网资源下全部通过。
- FTPS 暴露并修复了错误提示与引擎版本问题，硬性限制（强制 TLS 会话复用的服务器）由上游 `suppaftp#93` 决定，已文档化。
- Torrent/Magnet 引擎链路（metadata、peer、stall 保护）行为验证通过；完整传输受本机网络环境限制，建议在 P2P 友好网络复验。

验证脚本（本报告全部用例的可复现入口，随验证产物存档）：

- `verify_real_resources.py`：CLI 基础协议（HTTP/FTP/FTPS/SFTP/HLS/detect）
- `verify_extra_cases.py`：队列控制、SHA-256、脱敏、暂停恢复
- `verify_torrent_cases.py` / `verify_webseed_torrent.py`：P2P
- `verify_gui_real.py`：桌面 GUI CDP 真实资源用例
