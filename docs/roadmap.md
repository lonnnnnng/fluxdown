# 路线图

本文档记录 FluxDown 后续建设方向，不代表当前已经实现。

## 近期

- 已补齐顶层 `LICENSE`、人工维护的第三方许可证清单、轻量清单校验和 Release 随包许可证文本；后续补完整传递依赖 license bundle 和更严格的依赖审计。
- 已将根 README 收敛为短快速开始、截图和关键文档入口；详细构建、签名、产物和 CI 信息继续维护在 `docs/`。
- 已完成桌面端两页式 UI 重构：下载列表采用紧凑状态侧栏、横向指标栏和高密度任务行，设置页统一分组和字号；任务行支持点击开始/暂停及右键、长按、三点菜单操作。
- 已统一桌面端和移动端的天蓝色/白色主题与常规字重，并完成 macOS 原生窗口和 Android 真机 release UI 截图复验。
- 已为桌面队列路径接入平台原生数据目录：macOS 使用 `~/Library/Application Support/FluxDown/queue.json`，Windows 使用 `%APPDATA%/FluxDown/queue.json`，Linux/Unix 保持 XDG 路径；macOS 会兼容读取旧版 `~/.local/share/fluxdown/queue.json`。
- 已增加 URL 凭据脱敏，CLI JSON 输出、命令错误、桌面属性页和任务错误展示不再暴露 URL 中的用户名和密码；原始队列数据仍保留真实链接用于下载和复制。
- 已增加下载文件名规范化，CLI/桌面端会把用户另存名、协议推断名和旧队列文件名收敛为单文件名，避免异常文件名写出保存目录。
- 已为桌面 CLI、桌面 GUI command 和共享 Rust 下载核心增加按任务 SHA-256 校验；CLI `download`/`add` 和桌面新建任务均可配置期望 hash，校验失败会让直连命令报错或队列任务失败。
- 扩展 CLI 集成测试，覆盖队列生命周期和更多协议检测样例。
- 为 HLS、FTP、SFTP、SMB 增加更多边界单元测试。
- 为移动端 App 增加协议下载 mock 测试和队列恢复测试。

## 中期

- ✅ 已完成（`1.0.13`）：统一任务 schema v1 已文档化（[task-schema.md](task-schema.md)），移动端通过 `FluxDownCoreTask` 投影与 FFI 信封对齐；`crates/fluxdown-ffi` 提供 C ABI 动态库，移动端 `dart:ffi` 绑定已就绪，可在 Android/iOS 打包 Rust core（见 FFI crate 文档注释）。
- ✅ 已完成（`1.0.13`）：任务行展示预计剩余时间（ETA）；新建任务支持每任务限速（Mbps），队列执行时优先于全局限速。
- ✅ 已完成（`1.0.13`）：Torrent 任务详情面板：文件列表（含分文件进度）、tracker 列表、peer 聚合计数（活跃/连接中/排队/发现）、下载/上传速率与 ETA；运行中任务走实时会话快照，未运行任务静态解析 `.torrent`。
- ✅ 已完成（`1.0.13`）：HLS 增强：master playlist 的清晰度 variant 选择（新建任务内联下拉）、分片落盘断点恢复（暂停/失败后重跑只补缺失分片）、可选保留 TS 原始流（跳过 ffmpeg 转封装）。
- ✅ 已完成（`1.0.13`）：移动端任务模型与新建任务 UI 补齐 SHA-256 校验字段，下载完成后用 pointycastle 哈希校验产物，不匹配按失败处理。
- 将移动端已经保留的二维码扫描页重新接入新建任务弹框，并恢复不抢占主操作层级的剪切板入口。
- 移动端下载控制器切换到 FFI 复用 Rust core（绑定层已就绪，逐步替换自实现协议栈）。
- ed2k 增加更明确的外部客户端配置和状态回传能力。

## 长期

- 跨设备队列同步和远程控制。
- 浏览器扩展或系统分享扩展，用于快速添加下载任务。
- 远程 Web 控制台和 headless daemon。
- 插件化协议后端，让高级用户接入 aria2、yt-dlp 或企业内网后端。
- 更完整的后台下载体验，尤其是 Android foreground service 和 iOS 后台策略。
- 商店分发材料：隐私政策、许可证页面、合规说明和自动化截图。

## 技术债

- 移动端和桌面端协议能力存在两套实现，长期维护成本较高（FFI 绑定已就绪，收敛进行中）。
- JSON 队列适合早期和本地调试，但多进程并发和 schema migration 能力有限。
- 当前错误分类主要面向开发者，用户可读性还需要增强。
- Release 产物校验已有基础，但缺少代码签名、公证和产物签名链路。
- 许可证清单已有轻量校验，但完整传递依赖 license bundle、依赖审计和 GitHub Actions 阻断项仍未完成。
