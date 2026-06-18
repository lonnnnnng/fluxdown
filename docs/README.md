# FluxDown 文档索引

本目录记录 FluxDown 当前版本的产品、业务、技术、交付和运维安全信息。文档基于当前代码库编写，描述已经落地的能力、已知限制和下一步建设方向。

## 文档目录

- [需求文档](requirements.md)：产品目标、平台范围、用户流程、验收标准和非目标。
- [业务文档](business.md)：产品定位、用户场景、价值主张、发布渠道、合规与运营边界。
- [技术架构](architecture.md)：仓库结构、核心模块、队列模型、协议调度、端侧边界和关键依赖。
- [协议支持矩阵](protocols.md)：HTTP、FTP、BitTorrent、Magnet、ed2k、m3u8/HLS、SFTP、SMB、IPFS 等协议在桌面端和移动端的支持状态。
- [下载验证状态](download-verification.md)：区分构建/产物校验和真实下载端到端验证，记录各端与各协议当前验证边界。
- [协议端到端测试用例](protocol-e2e-test-cases.md)：跨平台复用的 10 MB 以下协议下载测试矩阵。
- [Android 真机协议测试报告](android-real-device-protocol-report.md)：Android 真机协议下载实测结果和未覆盖项。
- [构建与发布](build-release.md)：本地构建命令、CI 作业、发布产物、签名配置和版本发布流程。
- [第三方许可证清单](third-party-licenses.md)：项目自有许可证、主要直接依赖和移动端 GPL 风险边界。
- [运维与安全](operations-security.md)：本地数据、凭据处理、第三方后端、许可证、隐私假设和排障入口。
- [路线图](roadmap.md)：短期、中期和长期改进项。

## 当前产品面

FluxDown 是一个跨平台下载器工作区：

- 桌面端：Windows、macOS、Linux，包含 CLI 和 Tauri + React GUI。
- 移动端：Android 和 iPhone，使用 Flutter App。
- 共享核心：Rust core crate 提供协议检测、任务模型、任务存储、队列运行器和桌面下载执行能力。

当前版本号为 `1.0.2`。发布流水线在 `.github/workflows/build.yml` 中定义，只允许在 GitHub Actions 页面手动触发，并且必须显式选择 `run_mode=package` 或 `run_mode=release`；普通代码推送和 `v*` 标签推送都不会自动执行。

## 当前版本重点

- GitHub 默认 README 已切换为中文，英文入口保留为 `README.en.md`。
- Android 队列页显示任务状态、开始/结束时间、总耗时、已下载/总大小、实时速度和平均速度。
- 新建任务支持下载链接输入、剪切板读取、二维码扫描、另存文件名和保存位置选择。
- 设置页提供下载保存位置、并发下载数、下载线程数、自动重试数和最大下载网速。
- 下载执行逻辑接入并发排队、线程数、失败重试和可选限速配置。
- Torrent/Magnet 在获取 metadata 后使用真实文件名；Android 已支持多文件选择，桌面 CLI/Tauri command 已支持按文件编号选择下载内容。
- CLI JSON 输出、命令错误、桌面属性页和任务错误展示会脱敏 URL 用户名和密码，原始链接仍保留用于下载和复制。
- CLI 和桌面端会把另存文件名规范化为单文件名，避免异常文件名写出保存目录。
- 桌面队列默认使用平台原生数据目录，macOS 会从旧版 `~/.local/share/fluxdown/queue.json` 兼容迁移到 `~/Library/Application Support/FluxDown/queue.json`。
- Android 真机已补充本地协议资源和媒体级 HLS/torrent/magnet 前台 App 验证报告。
- macOS CLI 已补充本地 HTTP/HLS/FTP/FTPS/SFTP/SMB/Torrent/Magnet、公网 WebDAVS/FTP/SFTP/IPFS、本地自签 HTTPS/WebDAVS/FTPS 和自定义 IPFS gateway 真实下载验证，也覆盖限速、重试、暂停继续和并发排队；macOS GUI 已补充构建、启动、基础渲染、纯 GUI HTTP/HLS/Torrent/Magnet 下载闭环和 Tauri command 级 HTTP/HLS/WebDAV/FTP/FTPS/SFTP/SMB/IPFS/Torrent/Magnet 下载验证，剩余纯 GUI 协议点击验证当前阶段暂缓。
- 当前阶段跳过剩余前台 GUI 点击验证，不再占用本机桌面；后续验证优先推进非 GUI 脚本化检查、文档和发布合规收口。
- 仓库根目录已补齐 MIT `LICENSE`，第三方依赖和移动端 GPL 风险见 [第三方许可证清单](third-party-licenses.md)。

## 维护原则

- 功能文档以代码事实为准，新增协议或修改实现后同步更新 [协议支持矩阵](protocols.md)。
- 下载验证结论变化后同步更新 [下载验证状态](download-verification.md)。
- 构建脚本或 CI 作业变化后同步更新 [构建与发布](build-release.md)。
- 涉及凭据、签名、第三方原生库或许可证变化时同步更新 [运维与安全](operations-security.md) 和 [第三方许可证清单](third-party-licenses.md)。
