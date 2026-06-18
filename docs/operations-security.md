# 运维与安全文档

## 本地数据

FluxDown 当前是本地优先产品，没有服务端账号和云同步。

### 桌面端

桌面队列文件默认路径：

```text
$XDG_DATA_HOME/fluxdown/queue.json
~/.local/share/fluxdown/queue.json
./fluxdown/queue.json
```

优先级由运行时环境决定。CLI 可以通过 `--store` 指定队列文件：

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

当前版本没有独立凭据库。若下载 URL 中包含用户名和密码，例如：

```text
https://user:password@example.com/file.zip
sftp://user:password@example.com/path/file.zip
```

这些信息仍会保存在队列 JSON 中，因为下载执行、复制原始链接和断点恢复需要使用真实 URL。当前版本已经在以下展示出口做了脱敏：

- CLI 输出。
- CLI 顶层错误。
- 桌面属性页。
- 桌面任务错误和 toast 错误。

这些信息仍可能会出现在：

- 队列 JSON。
- Shell 历史。
- 用户主动上传的日志或截图。

建议：

- 避免在共享机器或共享队列文件中使用明文凭据 URL。
- 对临时 token 设置短有效期。
- 不要把队列 JSON 直接贴到 issue、日志或聊天工具中。
- 后续版本应考虑引入 OS keychain、凭据引用和更完整的日志脱敏。

## 文件系统权限

- 桌面端可以写入用户指定的输出目录，权限由操作系统控制。
- 移动端受 App 沙盒限制。
- 部分平台的外部目录、后台写入和文件选择能力需要额外系统权限或平台适配。

## 网络与协议风险

| 协议 | 风险 | 建议 |
| --- | --- | --- |
| HTTP | 明文传输，可被中间人观察或篡改。 | 优先使用 HTTPS。 |
| HTTPS | URL token 仍可能泄漏到本地队列和日志。 | 使用短期 token，避免共享队列。 |
| FTP | 明文凭据和内容。 | 优先使用 FTPS/SFTP。 |
| FTPS | 兼容性取决于服务端 TLS 配置。 | 对目标服务器做实际验证。 |
| SFTP | 当前缺少 known_hosts 策略和密钥认证配置。 | 只连接可信主机，后续补主机校验。 |
| SMB | 常用于内网，凭据和权限范围敏感。 | 使用最小权限账户。 |
| BitTorrent/Magnet | 公开 peer 网络暴露 IP，内容合规风险高。 | 仅下载有权访问的内容。 |
| ed2k | 由外部客户端处理，FluxDown 无法控制其行为。 | 确认外部客户端可信。 |
| m3u8/HLS | 可能涉及版权、鉴权和 DRM。 | 只下载合法来源，不绕过 DRM。 |
| IPFS | 公共网关可用性和隐私不可控。 | 需要稳定性时考虑自建网关或节点。 |

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
- 当前不提供队列 schema migration；修改任务结构前应考虑兼容旧 JSON。

## 安全改进 backlog

- URL 凭据脱敏。
- OS keychain/Keychain/Keystore 集成。
- SFTP known_hosts 校验和密钥认证。
- 下载文件校验和验证。
- Release artifact 签名和校验说明。
- 沙盒权限最小化审查。
- 依赖许可证自动生成和发布前阻断检查。
