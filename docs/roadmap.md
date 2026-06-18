# 路线图

本文档记录 FluxDown 后续建设方向，不代表当前已经实现。

## 近期

- 已补齐顶层 `LICENSE`、人工维护的第三方许可证清单、轻量清单校验和 Release 随包许可证文本；后续补完整传递依赖 license bundle 和更严格的依赖审计。
- 已将根 README 收敛为短快速开始、截图和关键文档入口；详细构建、签名、产物和 CI 信息继续维护在 `docs/`。
- 已为桌面队列路径接入平台原生数据目录：macOS 使用 `~/Library/Application Support/FluxDown/queue.json`，Windows 使用 `%APPDATA%/FluxDown/queue.json`，Linux/Unix 保持 XDG 路径；macOS 会兼容读取旧版 `~/.local/share/fluxdown/queue.json`。
- 已增加 URL 凭据脱敏，CLI JSON 输出、命令错误、桌面属性页和任务错误展示不再暴露 URL 中的用户名和密码；原始队列数据仍保留真实链接用于下载和复制。
- 已增加下载文件名规范化，CLI/桌面端会把用户另存名、协议推断名和旧队列文件名收敛为单文件名，避免异常文件名写出保存目录。
- 扩展 CLI 集成测试，覆盖队列生命周期和更多协议检测样例。
- 为 HLS、FTP、SFTP、SMB 增加更多边界单元测试。
- 为移动端 App 增加协议下载 mock 测试和队列恢复测试。

## 中期

- 统一桌面和移动端任务 JSON schema，或提供导入导出转换工具。
- 移动端考虑通过 FFI 复用 Rust core 的协议检测和任务模型。
- 增加下载速度、剩余时间、失败重试、限速和并发策略。
- 增加按任务的校验和验证，例如 SHA-256。
- 增加更完整的 torrent 任务信息：文件列表、tracker、peer、下载/上传速率。
- HLS 增加 variant 选择、分片重试、断点恢复和可选转封装。
- IPFS 支持自定义网关或本地节点。
- ed2k 增加更明确的外部客户端配置和状态回传能力。

## 长期

- 跨设备队列同步和远程控制。
- 浏览器扩展或系统分享扩展，用于快速添加下载任务。
- 远程 Web 控制台和 headless daemon。
- 插件化协议后端，让高级用户接入 aria2、yt-dlp 或企业内网后端。
- 更完整的后台下载体验，尤其是 Android foreground service 和 iOS 后台策略。
- 商店分发材料：隐私政策、许可证页面、合规说明和自动化截图。

## 技术债

- 移动端和桌面端协议能力存在两套实现，长期维护成本较高。
- JSON 队列适合早期和本地调试，但多进程并发和 schema migration 能力有限。
- 当前错误分类主要面向开发者，用户可读性还需要增强。
- Release 产物校验已有基础，但缺少代码签名、公证和产物签名链路。
- 许可证清单已有轻量校验，但完整传递依赖 license bundle、依赖审计和 GitHub Actions 阻断项仍未完成。
