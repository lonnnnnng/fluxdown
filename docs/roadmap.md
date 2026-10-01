# 路线图

核对日期：2026-10-01。源码基线：`android-kotlin-migration` / 当前工作树（P2-05 凭据与连接安全，桌面端与移动端 SFTP known_hosts 配置入口已补齐）；当前 Kotlin 预览源码版本：`1.0.28-kotlin-alpha.4`，桌面稳定版为 `1.0.27`。本文按源码汇总功能，运行结论引用已有报告和本轮验证，不把隔离 UI 或命令层结果写成原生 GUI/移动端全量验收。

状态口径：**已实现**表示有实际代码和入口；**部分实现**表示仍有端侧差异或功能缺口；**待验证**表示缺少目标版本、目标设备的运行证据；**规划**表示尚未交付。构建成功、模拟数据 UI 测试、历史真机通过不能互相替代。

## 已有功能

### 下载与队列

| 功能 | 当前实现 | 边界 |
| --- | --- | --- |
| 链接识别与协议执行 | 识别 12 类协议；HTTP、HTTPS、WebDAV、WebDAVS、FTP、FTPS、SFTP、SMB、Torrent、Magnet、HLS 共 11 类内建下载；ed2k 移交外部客户端。 | ed2k 移交成功不是文件下载完成；WebDAV(S) 当前复用 HTTP(S) 文件传输，不是目录管理。 |
| 新建与命名 | 根据链接优先生成文件名，支持用户另存；Torrent/Magnet 使用 metadata 和真实落盘信息修正名称。 | 获取 metadata 依赖网络和可用 peer；各端多文件选择入口尚未完全一致。 |
| 并发排队 | 桌面与移动设置支持 1-30 个并发，默认 5；超出并发数的任务排队。CLI `run` 可指定并发。 | 手动暂停、已移交和失败任务需按各自状态处理，不等同于等待下载。 |
| 下载线程 | 桌面、移动和 CLI 设置支持 1-32，默认 16；HTTP Range 和 HLS 分片已接入并行下载。 | 不是所有协议都按线程数建立同样数量的连接。 |
| 失败重试 | 桌面与移动设置支持自动重试 0-10 次，默认 3；0 表示不重试。CLI `start/run` 有重试参数；仅连接中断、超时、HTTP 408/429/5xx 等瞬态错误自动重试。 | 重试不包含首次尝试；认证、权限、磁盘满、资源失效、无 peer 和协议参数错误直接失败并给出操作提示。 |
| 网速限制 | 各端下载路径已有可选限速；桌面/core 支持每任务限速覆盖默认配置。 | 不配置时不主动限速，但不保证任何资源都能跑满带宽；字段名保留历史 `mbps`，界面显示 `MB/s`（字节），内部按 `1024²` 字节/秒换算。 |
| 生命周期与恢复 | 添加、开始、暂停、继续、重新下载、删除；本地队列持久化，异常中断恢复和快速暂停后继续已有处理与回归测试。 | 断点续传依赖协议、服务器及部分文件；不能承诺所有资源都从原字节位置恢复。 |
| 文件完整性 | 桌面、CLI、移动新建任务支持可选 SHA-256，最终单文件不匹配时按失败处理。 | Torrent 多文件目录不是一个可直接套用单文件 SHA-256 的产物。 |

### 各端入口与体验

下表的移动列表示 Android/iOS 共用 Flutter 实现，不表示 iPhone 真机已经验收。

| 功能 | 桌面 GUI | Android / iOS | CLI |
| --- | --- | --- | --- |
| 主界面 | 下载列表与设置两页；紧凑状态侧栏、指标栏、任务行。 | 下载列表与设置；固定顶部、状态 tab、紧凑任务行。 | 命令和 JSON 输出，不适用 GUI。 |
| 状态与进度 | 状态筛选和数量、进度、下载大小、时间、实时/平均速度、ETA。 | 状态 tab 和数量、背景进度、下载大小、开始/结束时间、耗时、实时/平均速度；独立“已移交”状态。 | `list` 查看队列状态和任务数据。 |
| 任务操作 | 点击开始/暂停；右键、长按或三点菜单进入复制链接、属性、打开、分享、重下等操作。 | 点击开始/暂停，长按打开操作菜单；Torrent 文件夹可进入详情。 | `add/list/start/run/pause/resume/remove/download`。 |
| 新建入口 | 弹框、剪贴板填入、自动命名、另存、单任务保存路径。 | 弹框标题栏剪贴板与扫码、自动命名、另存、单任务目录覆盖。 | 链接参数、`--name`、`--output`；无扫码交互。 |
| 保存位置 | 设置默认目录，单任务可覆盖；支持原生目录选择和路径文本输入。 | 系统目录选择、保存与回显、单任务覆盖、磁盘总量/已用/可用展示。 | 输出路径参数与队列存储路径参数。 |
| 数量与速度设置 | 数字输入配置并发、线程、重试、限速并持久化。 | 数字输入配置并发、线程、重试、限速并持久化。 | 由命令参数配置；默认值和参数范围不应直接等同 GUI。 |
| Torrent 多文件选择 | metadata 解析后在新建弹框展示文件树并支持多选，保存文件编号；详情支持已落盘文件打开。 | metadata 解析后弹出多文件选择，保存选择结果，支持文件夹详情与已落盘文件预览。 | 重复传入 `--torrent-file-index` 选择文件。 |
| Torrent 详情 | 文件清单、逐文件已下载量/百分比、tracker、peer、会话速度/ETA；运行中逐文件速度按轮询样本计算，静态 metadata 进度和速度显示未知。 | 文件清单与任务总进度；下载中逐文件完成字节未知，尚无真实逐文件速度。 | 当前以任务级输出为主，无对应详情命令。 |
| HLS | 清晰度 variant 选择、分片缓存恢复、可选保留 TS；默认尝试 FFmpeg 转 MP4，失败保留 TS。 | VOD、AES-128、fMP4、BYTERANGE、TS 转 MP4；移动端新建任务可指定 variant/保留 TS，Android arm64 通过 `MediaExtractor/MediaMuxer` 完成传统 TS→MP4，并在切换多轨前重置 extractor；空 playlist 会直接失败。 | CLI、Rust FFI 和移动端已共享 HLS 字段；Rust 缓存绑定 playlist 来源并校验分片完整性，合并阶段按序流式读取，并通过约 6 MiB 多分片并发流式合并回归；Android Redmi 真机已完成手持二维码实拍回填、双轨/B 帧/多音频夹具、仅音频/仅视频/空/损坏 TS instrumentation、HLS TS→MP4、variant/fMP4 输出验证；完整多音轨 rendition 选择受设备媒体栈轨道暴露能力限制，Android 真机更大媒体/异常网络长时间验证和 iPhone 真机仍待目标环境。 |
| 平台集成与诊断 | 托盘、关窗驻留、单实例、完成/失败通知、可关闭的剪贴板监听、窗口尺寸恢复、更新检查与安装包下载。 | 有原生扫码、文件选择、打开/分享入口；不等于已有系统级长期后台下载。 | `detect/support/doctor` 用于识别及后端诊断。 |

### 工程与发行

- **共享边界已明确**：桌面 GUI/CLI 共用 Rust core。移动端协议识别和 Torrent/Magnet metadata 预览统一走 Rust FFI，metadata 失败直接阻止新建任务；native 库可用时 HTTP/HTTPS/WebDAV(S)/HLS 和已完成 metadata 选择的 Torrent/Magnet 优先走 Rust 队列，SFTP 私钥和 ed2k 外部移交仍由 Dart/移动原生适配器执行。C ABI、JSON 解码、内存释放、iOS Runner 链接和运行时密码凭据透传已落地。
- **本地数据可靠性**：桌面使用平台原生数据目录，兼容 macOS 旧队列路径；Rust canonical 队列使用跨进程旁路锁、原子替换和 `deleted_task_ids` tombstone，Flutter 仅保存 `handedOff` 投影。旧双队列迁移有前快照、pending journal 恢复和按任务时间戳合并；P2-03 的单一活动队列收敛已完成。
- **输出安全**：CLI/桌面已做文件名规范化及 URL 凭据展示脱敏；桌面/CLI 已支持 OS 系统凭据库引用，移动端也已通过 Keystore/Keychain 保存引用对应的凭据。使用引用的任务只在队列保存 `credential_ref`，移动端密码凭据通过 Rust FFI 或 Dart 运行时临时使用，私钥仍只在 Dart SFTP 握手期间加载；旧 URL 凭据任务仍保留真实链接用于下载和复制。
- **测试基础**：已有 Rust core/CLI 队列与协议测试、Flutter 控制器/UI/FFI 测试、桌面隔离 UI 回归、跨平台 HTTP/Range smoke、可复用协议资源和真机报告。后续按平台与异常场景缺口补充用例。
- **发行策略**：只有明确打包/发版后才手动运行流水线；后续公开 10 个上传文件，加 GitHub 自动源码包共 12 项。CLI 三平台压缩包和两份许可说明继续保留，manifest 仅用于内部大小及 SHA-256 校验，不在 Release Notes 展示文件校验表格。内部调试、商店和 iOS 验证产物保留 Actions Artifacts；已有资产白名单、缺包、大小及 SHA-256 回验。
- **包体与许可证**：Android 沿用 Flutter Release 默认 R8/资源压缩；已配置 Rust 链接裁剪、Dart 符号分离、未使用字体清理和归档压缩，保留协议能力和 Android ABI 范围。已有 MIT LICENSE、主要第三方许可证清单与随包文本，完整传递依赖审计仍待补齐。
- **`1.0.17` Windows 修复**：Release 桌面 EXE 改用 GUI 子系统，CLI 保留 Console；可选后端探测禁止新建控制台。发布门禁检查真实 PE 文件头，正式安装器内主程序也已回验；前台启动/托盘操作仍需实测。

## 验证进度

当前发行流水线 [34223531407](https://github.com/lonnnnnng/fluxdown/actions/runs/34223531407) 的 10 个作业已通过，正式 11 个附件已回下载校验。详细命令、环境与报告见 [下载验证状态](download-verification.md)，下表不把旧版结果升级为当前版本全量通过。

| 平台 | 当前源码与既有证据 | 历史运行证据 | 仍待补验 |
| --- | --- | --- | --- |
| Android | Kotlin arm64 工作树 `1.0.28-kotlin-alpha.4` 已在 Redmi Note 8 Pro（Android 16，`wsvwypiz7xwslvl7`）完成 Gradle JVM 单测、默认 connected instrumentation、局域网 Torrent/Magnet 重复入队参数化回归、Activity 退后台前台服务回归、传输中断自动恢复和系统级 Wi-Fi 切换回归；真实二维码识别、双轨/B 帧/多音频、仅音频、仅视频、空/损坏 TS、Rust 回环队列、HTTP 416 回退、503 瞬态重试和 Rust HLS 核心回归均有证据；手持相机实拍回填也已人工确认；此前 Release APK 的 Flutter/Rust FFI smoke 仍保留。 | 同设备已通过暂停、继续、重启恢复、Torrent/Magnet metadata 多文件选择、目录详情和任务指标；本轮二维码、媒体轨道保留、HLS 缓存/流式合并、过期 Range 文件清理、重复入队、Activity 退后台、响应体中断恢复和 Wi-Fi 切换后的 Range 恢复均有自动化或真机证据。 | ed2k 仍按外部 handler 边界；完整多音轨 rendition、真实系统 ENOSPC、系统低内存回收/长期后台和正式签名分发按环境补验。 |
| iOS simulator | `FLUXDOWN_IOS_INCLUDE_TS_HLS=1 FLUXDOWN_IOS_BOOT_SIMULATOR=1 npm run verify:ios:integration` 已通过当前工作树：HTTP、fMP4 HLS、BYTERANGE HLS、TS HLS 均真实落盘；Rust queue integration 的 HTTP/HLS/variant 也通过；`npm run verify:ios:ui` 已真实启动 App 并完成任务页/设置页切换和存储统计检查。 | App 内历史 HTTP、fMP4/BYTERANGE/TS HLS smoke。 | 新建任务表单的 simulator UI 断言、iPhone 真机扫码、目录选择、分享/打开、Torrent/Magnet 仍待签名设备。 |
| iPhone 真机 | unsigned device app 构建及 FFI 导出检查；没有签名 IPA。 | 尚无完整真机验收。 | 签名安装后扫码、目录选择、打开/分享、HTTP/HLS/Torrent/Magnet 和恢复流程。 |
| macOS 桌面 | 当前工作树 `.app` 前台 GUI 协议回归通过：HTTP、HTTPS、WebDAV、WebDAVS、FTP、FTPS、HLS、SFTP、SMB、Torrent、Magnet 真实落盘并校验 SHA-256，ed2k 完成系统移交；CLI 队列控制回归也通过。该证据尚未重新打包为 `1.0.27` DMG。 | 2026-08-05 原生 GUI 12 类协议流程。 | 当前版托盘、更新和更多手工交互仍可继续补验；本轮证据见 `docs/artifacts/macos-desktop-gui-protocol-e2e-20260927.json`。 |
| Windows 桌面 | 本轮按用户要求跳过。 | 构建、正式安装器内 EXE 为 GUI `Subsystem=2`；历史原生 GUI 12 协议流程。 | 当前 `1.0.27` 安装启动、托盘和下载回归待 Windows 环境恢复后补验。 |
| Linux 桌面 | 本轮按用户要求跳过；保留 GUI、DEB/RPM 构建与发布资产校验。 | 缺少 Linux 原生 GUI 真实下载记录。 | 当前版安装启动、HTTP/队列和全协议运行待 Linux 环境恢复后补验。 |
| 三平台 CLI | Windows/macOS/Linux 实际执行版本、`detect/add/pause/resume/run/list/download`；HTTP/Range 大小与 SHA-256 正确。macOS 正式归档另有本机复跑。 | macOS/Windows 有更多协议和队列控制报告。 | 当前版跨平台完整协议矩阵，重点补 Linux 除 HTTP 以外的协议运行证据。 |

## 近期优先项

以下是建议顺序，不承诺具体发布日期。先补现有功能和真实运行证据，再扩展产品范围。

| 编号 | 要做的功能/验证 | 当前缺口 | 完成标准 |
| --- | --- | --- | --- |
| P1-01 | 当前发行版跨端验收 | Android 上一版 `1.0.26` Release 启动与 Rust 队列 smoke、iOS simulator HTTP/HLS/queue、macOS 当前工作树 GUI 12 协议和 CLI 队列控制均已收口；iPhone 真机、Windows/Linux 本轮跳过。 | 已完成可用环境的构建、启动、下载 smoke 和回归记录；剩余环境恢复后按同一资源和字段补验，不提前宣称全平台完成。 |
| P1-02 | Torrent 文件夹体验补齐 | 桌面新建弹框文件树多选、真实文件名回写、完成文件打开和路径安全校验已完成，并通过当前 macOS GUI P2P 回归；移动端选择结果重启可恢复，详情页按磁盘已写入数据展示逐文件指标。移动 libtorrent bridge 尚未暴露 piece 级逐文件进度/网络速度，当前速度是 UI 采样值。 | 桌面与移动端选择结果可持久化、重启可恢复；无法取得 piece 级数据时明确显示“已写入/未知”，避免把预分配文件长度冒充网络进度；补齐原生 GUI、Android/iOS 运行证据。 |
| P1-03 | HLS 配置跨端对齐 | 代码、core/移动自动化测试、Android Redmi 真机 variant/TS 队列下载、iOS simulator variant/TS/HLS smoke 已完成；iPhone 真机的 variant/TS 运行证据仍缺。 | Android 和 simulator 已由真实 FFI 队列落盘验证；iPhone 设备可用后补跑同一矩阵，不能用 FFI 识别测试替代。 |
| P1-04 | 设置与保存位置一致性 | macOS 桌面前台已验证目录、并发、线程、重试、限速保存/回显和无效目录提示；移动临时目录权限问题已修复并通过自动化回归。 | 代码和可用环境验证完成；Windows/Linux/iPhone 的原生目录权限和并发限速仍按各自环境补验。 |
| P1-05 | 错误处理与异常恢复 | 错误分类、可操作提示、不可恢复错误不重试、HLS 非瞬态错误不重试、截断保护、启动恢复和移动加载恢复均已由 core/CLI/桌面/Flutter 回归覆盖；本轮新增未知协议/超长下载源/二维码摄像头异常提示并通过 Flutter UI 回归。 | 真实磁盘满、系统撤销目录权限、iOS/Android 后台被杀和无 peer 长时间运行仍需目标设备/实验室环境，属于外部验收而非代码缺口。 |

## 中期建设

### Android Kotlin 重写（进行中）

第一阶段已建立 `apps/android` 原生 Compose 宿主和 Rust JNI bridge，现阶段与 Flutter 并存，使用独立包名和 arm64-only 构建。当前已接通 Rust 异步队列运行、状态轮询、并发/线程/重试/限速透传、真实 HTTP/Torrent 下载、暂停/继续、失败重试、完成任务重新下载和 Torrent 多文件选择；已在 Redmi 真机完成本地 HTTP、局域网 Peer 资源和 Android SAF 目录复制验证。已完成任务操作面板、FileProvider 本地文件打开/分享、SAF `content://` 文件打开/分享、凭据失效后的可操作失败提示，以及 HLS variant 编号/保留 TS 参数透传和持久化。一级页面系统返回已增加退出确认，扫码页面已接入 CameraX + ML Kit，并完成真实二维码位图识别、手持相机实拍回填和真机 instrumentation；前台服务已完成通知权限、后台保活和队列摘要通知验证。Rust HLS 分片缓存现已具备来源摘要、长度/SHA-256 完整性校验和临时文件提交，最终合并改为按序流式读取；Android 双轨/B 帧/多音频夹具、仅音频/仅视频、空/损坏 TS、Rust 回环队列和 HTTP 416 回退自动化已通过，但完整多音轨选择仍受设备媒体栈能力限制。Kotlin Release 已准备 `key.properties` 签名入口但尚未配置正式证书；后续重点是更长/复杂媒体和 iPhone 真机，在正式签名与跨端验收完成前，不把 Kotlin 预览包当作正式 Android Release。

| 编号 | 方向 | 交付条件 |
| --- | --- | --- |
| P2-01 | 移动下载引擎逐步收敛到 Rust | **已完成（混合边界）**：非阻塞单任务/队列运行句柄、状态轮询、Torrent/Magnet metadata 异步读取、暂停/继续/重置/删除、句柄回收、并发/线程/重试/限速透传、canonical schema v2、tombstone、旧任务执行回退和运行时密码凭据均已落地。native 库可用时 HTTP/HTTPS/WebDAV(S)/HLS 与完成 metadata 选择的 Torrent/Magnet 走 Rust；metadata 失败直接阻止新建任务，SFTP 私钥和 ed2k 外部移交保留端侧适配器。Rust/FFI/Flutter 回归及 Flutter Android 三 ABI 真机 HTTP/HLS 队列验证通过；Kotlin 预览另有 arm64 真机 HTTP 和局域网 Torrent 多文件选择/下载证据。 |
| P2-02 | 系统后台下载 | **已完成（平台能力边界）**：Flutter Android/iOS 原有后台通道保持不变；Kotlin 预览新增 `dataSync` foreground service、通知 channel、队列摘要和真机切后台保活验证。应用被系统回收后，启动恢复会把无句柄的 running 任务转为 paused/queued，不能承诺 Kotlin 预览或 iOS 永久后台、force-stop 后继续执行。 |
| P2-03 | 队列格式演进 | **已完成**：Rust canonical schema v2、`deleted_task_ids` tombstone、旁路锁、原子回写、迁移前快照、`.queue-migration/manifest.json` 事务标记、启动恢复、按 `updatedAt` 冲突合并和全量 upsert 均已覆盖；未知状态不会降级成 queued。Rust core/FFI、Flutter analyze/test、canonical 回退读取和 Android 真机迁移/删除 tombstone/HLS 队列回归通过。 |
| P2-04 | ed2k 外部客户端集成 | **已完成（移交通路边界）**：桌面优先调用 aMule `ed2k` CLI，缺失时使用系统 URL handler；Android/iOS 使用 `url_launcher`。成功移交统一落为 `handed-off`/`handedOff`，保存后端和时间，不冒充 `finished`；无 handler 明确失败，暂停/继续拒绝移交终态，显式重试才清理移交信息。第三方客户端的进度、完成回传、最终路径和客户端选择不在 FluxDown 可控范围内，因此不虚构为已实现。 |
| P2-05 | 凭据与连接安全 | **已完成（支持边界）**：桌面/CLI 使用系统凭据库引用，支持 HTTP/HTTPS、WebDAV(S)、FTP(S)、SFTP、SMB；SFTP 支持 known_hosts、SSH agent 和单跳跳板，错误指纹不自动重试。移动端使用 Android Keystore/iOS Keychain 保存密码、SFTP 私钥和口令；密码凭据可通过 Rust FFI 运行时参数或 Dart 请求临时使用，私钥固定走 Dart SFTP 握手，任务 JSON 只保存引用。Android 真机和 iOS simulator 的私钥、known_hosts、错误指纹回归通过；移动端 ssh-agent、跳板机及 iOS 物理真机仍明确不支持/待环境补验。 |
| P2-06 | 正式签名与合规分发 | Android Kotlin 已补齐与 Flutter 一致的 `key.properties` 配置入口和 debug 回退门禁；正式证书、升级兼容验证、Windows Authenticode、macOS 签名/公证、iOS 签名安装、传递依赖许可证材料和移动端 GPL 义务审查仍未完成。 |

当前正式签名边界：`1.0.17` Android APK 使用 `Android Debug` 测试证书，Windows 未做 Authenticode，macOS 为 ad-hoc，iOS 只提供构建验证包。脚本或 secrets 配置入口存在，不代表正式分发已就绪，详见 [发行说明](releases/1.0.17.md)。

## 长期候选

以下尚未实现，也未承诺纳入下一版本：

- 浏览器扩展和系统分享扩展，将网页或其他 App 的链接送入下载队列。
- headless daemon 与 Web 控制台，先定义鉴权、任务隔离和远程文件访问边界。
- 跨设备队列同步和远程控制，明确链接凭据、文件本体与队列元数据的同步范围。
- 插件化协议后端，可选择接入 aria2、yt-dlp 或企业内网后端，避免把核心下载器变成必须依赖全部外部工具的壳。

当前不承诺原生 ed2k 网络引擎、HLS DRM/直播录制、WebDAV 上传/目录同步或 SMB 递归下载。增加这些能力需单独评估，不应把“能够识别链接”写成“完整支持该协议的全部功能”。

## 核对与维护

- 协议和执行：[协议矩阵](protocols.md)、[Rust 下载器](../crates/fluxdown-core/src/downloader.rs)、[队列运行器](../crates/fluxdown-core/src/runner.rs)、[CLI 参数](../crates/fluxdown-cli/src/main.rs)。
- 端侧入口：[桌面 UI](../apps/desktop/src/App.tsx)、[移动 UI](../apps/mobile/lib/main.dart)、[移动控制器](../apps/mobile/lib/src/download_controller.dart)、[移动下载器](../apps/mobile/lib/src/mobile_downloader.dart)。
- 共享边界：[技术架构](architecture.md)、[任务模型与 FFI](task-schema.md)、[C ABI](../crates/fluxdown-ffi/src/lib.rs)。
- 验收与交付：[测试资源](protocol-test-resources.md)、[跨平台用例](protocol-e2e-test-cases.md)、[下载验证状态](download-verification.md)、[构建发布](build-release.md)、[包体记录](release-size-optimization.md)。

功能落地时同步更新本页对应行及源码/测试入口；真实验证补上版本、平台和报告链接后，才能从“待验证”移出。只有用户明确要求打包或发版时才运行发布流水线，普通文档或代码推送不触发。
