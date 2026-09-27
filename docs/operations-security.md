# 运维与安全文档

## 本地数据

FluxDown 当前是本地优先产品，没有服务端账号和云同步。

### 桌面端

桌面队列文件默认路径：

```text
macOS: ~/Library/Application Support/FluxDown/queue.json
Windows: %APPDATA%/FluxDown/queue.json
Linux/Unix: $XDG_DATA_HOME/fluxdown/queue.json 或 ~/.local/share/fluxdown/queue.json
```

`XDG_DATA_HOME` 可显式覆盖桌面/CLI 默认队列位置；CLI 也可以通过 `--store` 指定队列文件。macOS 上如果新默认路径不存在但旧版 `~/.local/share/fluxdown/queue.json` 存在，会先读取旧队列，并在下一次写入时迁移到 `~/Library/Application Support/FluxDown/queue.json`。

```sh
fluxdown --store /path/to/queue.json list
```

队列 JSON 包含：

- 下载源 URL。
- 输出目录。
- 文件名。
- 协议和支持状态。
- 下载进度、任务状态、错误信息和时间戳。

### 移动端

移动端队列位于 App documents 目录：

```text
fluxdown/queue.json
```

下载输出默认位于 App 沙盒内的下载目录，具体路径由 App 和平台文件系统决定。

## 凭据处理

桌面端和 CLI 已支持系统凭据库引用。凭据内容由 macOS Keychain、Windows Credential Manager
或 Linux Secret Service 保存，普通队列只保存引用名，不保存用户名、密码或私钥：

```sh
read -r -s FLUXDOWN_PASSWORD
printf '%s' "$FLUXDOWN_PASSWORD" | fluxdown credential set office-sftp --username user
unset FLUXDOWN_PASSWORD
fluxdown add \
  --credential-ref office-sftp \
  'sftp://example.com/incoming/file.bin'
fluxdown credential delete office-sftp
```

凭据引用目前适用于 HTTP/HTTPS、WebDAV/WebDAVS、FTP/FTPS、SFTP 和 SMB。运行时才从系统凭据库
读取认证信息并临时注入请求；URL 已经包含用户名或密码时，不能再同时传入凭据引用。移动端还可把
SFTP 私钥和可选口令保存到 Android Keystore/iOS Keychain，私钥只在本次 SFTP 握手期间交给
`dartssh2`，不会写入 URL 或任务 JSON。私钥引用仅适用于 SFTP；Torrent、Magnet、HLS 和 ed2k
不接受该引用，避免把不兼容的认证信息误传给协议后端。

如果不使用凭据引用，仍可直接把用户名和密码写入下载 URL，例如：

```text
https://user:password@example.com/file.zip
sftp://user:password@example.com/path/file.zip
```

这类兼容写法仍会保存在队列 JSON 中，因为下载执行、复制原始链接和断点恢复需要使用真实 URL。
以下展示出口会脱敏：

- CLI 输出。
- CLI 顶层错误。
- 桌面属性页。
- 桌面任务错误和 toast 错误。


即使使用凭据引用，以下信息也可能出现在：

- 队列 JSON。
- Shell 历史。
- 用户主动上传的日志或截图。

建议：

- 优先使用系统凭据库引用，不要把密码写入 URL、队列或 shell 历史。
- 对临时 token 设置短有效期。
- 不要把队列 JSON 直接贴到 issue、日志或聊天工具中。
- 凭据引用本身不是密码；删除系统凭据后，引用仍会保留在任务中，但运行时会明确失败且不会自动重试。
- Android/iOS 已通过 `flutter_secure_storage` 使用 Android Keystore/iOS Keychain 保存密码、SFTP 私钥和私钥口令；设置页管理引用，新建任务只选择引用名。移动端密码凭据在运行时读取后，通过本次 Rust FFI 运行参数或 Dart 请求临时使用，任务 JSON 仍只保存 `credentialRef`；SFTP 私钥只在 Dart 握手期间加载，不进入 Rust native 队列。移动端设置页已支持导入 OpenSSH `known_hosts` 并在 SFTP 握手时校验主机指纹；Android 真机和 iOS simulator 已验证加密私钥、匹配和错误指纹拒绝，移动端仍不接入系统 ssh-agent 或跳板机，iOS 物理真机待设备条件满足后补验。

## 文件系统权限

- 桌面端可以写入用户指定的输出目录，权限由操作系统控制。
- 下载任务的另存文件名会被规范化为单文件名：路径分隔符、控制字符和跨平台非法字符会替换为 `_`，空名、`.` 和 `..` 会回退到默认文件名，避免任务写出用户选择的保存目录。
- 移动端受 App 沙盒限制。
- 部分平台的外部目录、后台写入和文件选择能力需要额外系统权限或平台适配。

## 网络与协议风险

| 协议 | 风险 | 建议 |
| --- | --- | --- |
| HTTP | 明文传输，可被中间人观察或篡改。 | 优先使用 HTTPS。 |
| HTTPS | URL token 仍可能泄漏到本地队列和日志。 | 使用短期 token，避免共享队列。 |
| FTP | 明文凭据和内容。 | 优先使用 FTPS/SFTP。 |
| FTPS | 兼容性取决于服务端 TLS 配置。 | 对目标服务器做实际验证。 |
| SFTP | 默认兼容模式不校验服务端主机密钥；桌面/CLI 可使用系统凭据引用、当前进程的 SSH agent 和单跳 SSH 转发，移动端密码或私钥引用均只在运行时使用。 | 生产环境和不可信网络必须通过 `--sftp-known-hosts` 或 FFI `sftpKnownHosts` 指定目标 OpenSSH known_hosts；启用跳板时还要通过 `--sftp-jump-known-hosts` 指定跳板文件。未知主机、端口或密钥不匹配会直接失败且不自动重试。移动端私钥任务目前固定走 Dart 适配器，不进入 Rust native 队列，也不支持跳板机。 |
| SMB | 常用于内网，凭据和权限范围敏感。 | 使用最小权限账户。 |
| BitTorrent/Magnet | 公开 peer 网络暴露 IP，内容合规风险高。 | 仅下载有权访问的内容。 |
| ed2k | 由外部客户端处理，FluxDown 无法控制其行为。 | 确认外部客户端可信。 |
| m3u8/HLS | 可能涉及版权、鉴权和 DRM。 | 只下载合法来源，不绕过 DRM。 |

## 外部后端与系统移交

ed2k 是当前主要移交型协议：

- 桌面端优先调用 aMule `ed2k` CLI。
- 如果 CLI 不存在，使用系统 URL handler。
- 移动端使用系统 URL launcher 打开兼容 App。

移交型协议的限制：

- FluxDown 不能保证外部客户端已安装。
- FluxDown 不能读取真实下载进度。
- 外部客户端的隐私、安全和许可证由该客户端自身决定。

`doctor` 可用于检查桌面后端：

```sh
fluxdown doctor
```

### SFTP 主机身份校验

SFTP 的 known_hosts 校验是显式开启的连接安全策略，不会自动生成、修改或接受服务端首次返回的指纹。标准端口使用 `host` 条目，非标准端口使用 `[host]:port` 条目；校验文件缺失、无法读取、没有匹配条目或密钥不一致都会在认证前失败，并被分类为不可自动重试的连接安全错误。

生产环境建议为 FluxDown 使用只读、最小范围的独立 known_hosts 文件，并通过 CLI 参数传入：

```sh
fluxdown download \
  --sftp-known-hosts "$HOME/.config/fluxdown/known_hosts" \
  'sftp://user:password@example.com:2222/incoming/file.bin'
```

桌面设置页现在可以选择 known_hosts 文件，运行队列和单任务启动会在本次运行中显式使用它；移动端设置页会把导入内容复制到应用配置并在连接时使用。移动端私钥由安全存储管理，设置页只保存引用名，任务不会携带 PEM 或口令。两端都不会把配置写入任务记录、自动生成或修改用户文件，也不会上传。不要把密码、private key 或 known_hosts 内容写入 issue、日志和截图。

桌面端和 CLI 还支持单跳 SFTP 转发。跳板地址只建议填写无密码 URL，省略密码后由当前进程可见的 SSH agent 完成跳板认证；目标主机仍使用原 SFTP URL 的用户名和认证方式。CLI 示例：

```sh
fluxdown download \
  --sftp-known-hosts "$HOME/.config/fluxdown/target_known_hosts" \
  --sftp-jump "sftp://jump-user@bastion.example.com:22/" \
  --sftp-jump-known-hosts "$HOME/.config/fluxdown/jump_known_hosts" \
  'sftp://target-user@target.example.com:22/incoming/file.bin'
```

跳板与目标的主机密钥必须分别匹配；任一文件缺失、没有对应端口条目或指纹变化都会在认证前失败。桌面设置页的跳板地址仅作为本次运行参数透传，密码不会写入设置存储，任务 JSON 也不会保存跳板配置。

## 签名材料

### Android

不要提交：

- `apps/mobile/android/key.properties`
- keystore 文件
- keystore 密码

CI 使用 GitHub Secrets 注入签名材料。没有 secrets 时 release APK/AAB 会回退到 debug signing，仅适合测试。

### iOS

不要提交：

- `.p12` 证书
- `.mobileprovision` 描述文件
- 临时 keychain
- 本地导出的 `ExportOptions.local.plist`

CI 使用临时 keychain 导入签名材料。签名 secrets 不齐全时会跳过 IPA。

## 许可证

Rust workspace 声明 MIT license，仓库根目录已补齐 [LICENSE](../LICENSE)，主要直接依赖和移动端 GPL 风险见 [第三方许可证清单](third-party-licenses.md)。需要注意：

- 移动端 torrent 依赖 `libtorrent_flutter`，包含 GPL 许可的原生组件。
- 正式分发 Android/iOS App 前必须完成第三方依赖许可证审查。
- 如果分发包含 GPL 组件的二进制，需要满足对应源码提供、许可证声明和再分发义务。

建议在发布前补充：

- 顶层 `LICENSE` 文件。
- 第三方依赖许可证清单。
- App 内许可证页面。
- Release assets 中的许可证说明。

## 隐私假设

当前版本默认不上传用户数据。仓库中也没有遥测或服务端 API。

如果后续加入遥测，应遵守：

- 默认最小化采集。
- 不采集完整 URL、文件名、本地路径、认证信息。
- 明确告知用户并提供关闭方式。
- 诊断日志在上传前做脱敏。

## 排障入口

### 协议检测

```sh
fluxdown detect "<source>"
fluxdown support "<source>"
fluxdown doctor
```

### 队列检查

```sh
fluxdown list
fluxdown --store /path/to/queue.json list
```

### 构建检查

```sh
npm run verify:ci-config
npm run verify:artifacts
npm run audit:release
```

### 移动端 URL scheme 检查

```sh
npm run verify:mobile-url-schemes
```

## 备份与恢复

- 桌面端可备份队列 JSON 和下载目录。
- 移动端可通过系统备份机制或 App 文件导出能力扩展实现备份。
- Rust canonical 队列已提供 schema v2 迁移：首次启用 native 队列时会创建迁移快照和事务标记，
  合并旧 Flutter 队列、写入 `deleted_task_ids` tombstone 后再原子提交；恢复失败会保留原始快照，
  未知状态或未来 schema 不会被降级成 `queued`。移动端 Flutter `queue.json` 仅保留 `handedOff`
  等 native 不执行的投影。

## 安全改进 backlog

- 将移动端 SFTP 私钥凭据接入 Rust native 队列（当前 Rust 仅支持运行时密码凭据）；带私钥任务固定走 Dart，密码凭据已进入 Rust FFI 临时参数路径。
- 桌面/CLI 已支持省略 SFTP 密码后调用当前进程可见的 SSH agent，并已用双临时 OpenSSH 服务真实验证单跳转发、两份 known_hosts 和错误跳板指纹拒绝；Android/iOS 仍不支持 ssh-agent 或跳板机，iOS 真机 known_hosts/私钥匹配与不匹配验收仍待补齐。
- 下载文件校验和验证。
- Release artifact 签名和校验说明。
- 沙盒权限最小化审查。
- 依赖许可证自动生成和发布前阻断检查。
