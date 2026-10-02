# Android Kotlin 重写进度

核对日期：2026-10-02。当前源码版本：`1.0.28-kotlin-alpha.6`。

## 2026-10-02 Kotlin Android Alpha 6 发布前复验

- Release APK 继续启用 R8 与资源收缩，只包含 `arm64-v8a`；本地正式 Release 构建通过，当前 APK 为 `24.3 MB`，仍使用 Android Debug 证书，仅用于迁移预览和真机测试。
- 新增 `releaseTest` instrumentation 变体：使用 `.releaseTest` 独立包名复用 Release 混淆规则，补充 AndroidX tracing 与 Kotlin runner 运行时保留规则，避免测试 APK 启动阶段因 R8 类名裁剪崩溃；正式 Release 不引入测试专用保留成本。
- Redmi Note 8 Pro（`wsvwypiz7xwslvl7`）ReleaseTest HTTP 回环下载通过；带真实 Tracker/Transmission Seeder 的 Torrent/Magnet 重复入队、metadata、文件选择、Peer 下载和选中文件 SHA-256 校验均通过。
- 默认 Debug connected instrumentation 为 `24` 项通过、`3` 项按环境跳过、`0` 失败；Kotlin JVM 单测、Rust core `118/118`、Rust FFI `14/14` 和正式 Release 构建均通过。
- 本轮只发布 Android Kotlin arm64 Alpha，不重新发布桌面、CLI、iOS 或现有 Flutter Android 资产；本轮未执行提交前的正式商店签名验收。

## 2026-10-02 Kotlin Release 复验

- 按当前工作树重新执行 `npm run mobile:kotlin:release`，R8 与资源收缩成功；产物 `app-release.apk` 为 `24 MB`，SHA-256 为 `656438267bfe3e989d3098db378f582aa1bd6cb6439b56895c533a96b75468c5`，仅包含 `arm64-v8a`。当前没有 `key.properties`，因此仍使用预览用 debug 签名，不作为正式商店包。
- 将该 Release APK 覆盖安装到 Redmi Note 8 Pro（`wsvwypiz7xwslvl7`）后启动正常，logcat 无 `FATAL EXCEPTION`；任务页和新建下载弹框均可打开，剪切板、扫码、链接输入和文件名输入入口在 R8 后仍可见。
- Release UI 真实下载复验：通过 `adb reverse tcp:8765 tcp:8765` 输入本机 HTTP 文件 `lan-p2p-sample.txt`，任务真实完成 `39 B/39 B`；随后输入局域网 `.torrent` `http://192.168.1.8:53839/lan-p2p.torrent`，完成 metadata、文件选择、确认入队和真实 Peer 下载，任务卡显示目录 `lan-p2p-sample`、`39 B/39 B`，无失败任务。
- Release 自动化验收通过 `-PfluxdownReleaseInstrumentation=true` 启用独立的 `releaseTest` 变体；该变体复用 Release 的 R8/资源收缩规则并使用 `.releaseTest` 包名，不覆盖正式 Release 安装。Redmi 真机上的 ReleaseTest HTTP 回环用例和局域网 Torrent/Magnet 重复入队用例均通过；默认 Debug connected instrumentation 仍作为日常全量回归入口。
- Release 复验截图保留在 `artifacts/kotlin-release-after-install.png`、`artifacts/kotlin-release-new-task-dialog.png`、`artifacts/kotlin-release-http-download.png`、`artifacts/kotlin-release-torrent-metadata.png` 和 `artifacts/kotlin-release-torrent-complete.png`；本轮未执行提交、推送或发版。

ReleaseTest 示例命令：

```zsh
ANDROID_SERIAL=wsvwypiz7xwslvl7 \
apps/mobile/android/gradlew -p apps/android :app:connectedReleaseTestAndroidTest \
  --no-daemon -PfluxdownReleaseInstrumentation=true \
  -Pandroid.testInstrumentationRunnerArguments.class=dev.fluxdown.android.RustQueueInstrumentationTest#queueDownloadsLoopbackHttpThroughRust
```

局域网 Torrent/Magnet 用例还需要传入 `p2pTorrentUrl`、`p2pInfoHash`、`p2pTrackerUrl`、`p2pSelectedSha256`、`p2pSelectedBytes`、`p2pDirectoryName`、`p2pSelectedPath` 和 `p2pSkippedPath`，并确保 Seeder/Tracker 对真机可达。

## 2026-10-02 Torrent/Magnet HTTP 种子加载修复与真机回归

- 修复 Rust 下载引擎的 HTTP/HTTPS `.torrent` 正式下载路径：FluxDown 先读取种子字节，再统一使用 `AddTorrent::from_bytes`，避免 `AddTorrent::from_url` 在 metadata 已成功后没有继续向 Tracker announce，导致任务在 `0 B/s` 阶段立即失败。
- Torrent 会话增加 30 秒 Tracker 强制刷新；以 `live.snapshot.fetched_bytes` 和选中文件进度共同判断真实网络活动，连续 90 秒没有任何数据时释放会话并交给队列层自动重试。已有下载进度不会被清零。
- Redmi Note 8 Pro（`wsvwypiz7xwslvl7`）真机使用 `http://192.168.1.8:53839/lan-p2p.torrent` 完成 metadata、文件选择和真实 Peer 下载，任务从 `0 B/39 B` 到 `39 B/39 B`；Tracker 记录到设备 `192.168.1.21` 的 announce。
- 同一真机使用 Magnet `magnet:?xt=urn:btih:f205e41aa956b64738a07a806d66bc907c1269a8&tr=http%3A%2F%2F192.168.1.8%3A53836%2Fannounce&dn=lan-p2p-sample` 完成 metadata、文件选择和真实 Peer 下载，任务显示 `39 B/39 B`；Tracker 记录到设备 `192.168.1.21:49152` 的 announce。
- 同一真机使用公网种子 `https://bt.uump4.cc/btdown/2026/08/29/20260829195947ac4oodz35dp.torrent` 获取 4 个文件并确认加入，任务从 `56.0 MB/381.9 MB` 增长到至少 `160.0 MB/381.9 MB`，随后无数据活动超过 90 秒后进入失败；该资源的 Peer、Tracker 和 Webseed 不稳定，但任务没有立即失败或无限挂起，已有进度保持并以可诊断错误结束。
- 无 Peer 超时专项使用 `http://192.168.1.8:60843/no-peer-retry.torrent`，Tracker `http://192.168.1.8:60842/announce` 返回空 Peer 列表；真机任务保持 `0 B/29 B` 约 90 秒后进入失败，并显示“暂无可用 Peer 或 Tracker 未响应，请检查网络、Tracker 后稍后重试。”，验证了新增超时和错误提示边界。
- 同一无 Peer 夹具下，先在设置页把“自动重试次数”设为 `1`，再重新新建任务；Tracker 从真机 `192.168.1.21` 收到首次 announce，约 89 秒后再次 announce，任务最终进入 `失败(1)`，仍为 `0 B/29 B`。这证明重试次数由当前设置透传到 Rust 队列并实际消耗，未把运行中途修改设置或预置任务当成重试证据。
- Magnet metadata 超时与 Kotlin 外层等待统一为 `90` 秒；此前 Rust 详情解析内部固定 `30` 秒，移动网络下可能在 UI 仍等待时提前结束。metadata 预览会话同时使用与正式下载一致的 `30` 秒 Tracker 主动刷新。该调整只延长 metadata 发现窗口并统一 Tracker 策略，不改变下载超时、自动重试次数或任务入队条件。
- 2026-10-02 使用仍在运行的局域网 Tracker `192.168.1.8:53836`、HTTP 种子服务 `53839` 和 Transmission Seeder `53838`，通过带参数的 `connectedDebugAndroidTest` 和 ReleaseTest 变体分别真实跑通 Torrent 与 Magnet 重复入队下载；当前 `lan-p2p-sample.txt` 为 `39 B`，SHA-256 为 `abb5c5178ec9852000ec276e3da35a3c73baa2b7f8b12d00e29545f09f3cfd93`，两套测试均无失败。该用例同时验证了本轮 metadata 超时改动没有破坏 Rust Peer 下载路径。

## 2026-10-02 Torrent/Magnet 失败任务重试修复

- 失败的 Torrent/Magnet 任务点击“重试”后，会重新获取 metadata 并重新确认文件；只有新任务成功入队后才删除旧失败任务。metadata 获取失败、取消文件选择或新任务入队失败时，旧任务仍保留，避免任务列表出现重复项或任务凭空消失。
- 使用 Android SAF“下载保存位置”的任务重试时，优先恢复持久化的 `content://` 目录授权，而不是把 Rust 私有暂存目录当作用户目录传回；新任务继续写入私有暂存，完成后仍复制到用户选择的目录。
- 新增 JVM 回归覆盖 SAF 重试目录恢复和授权缺失回退；Redmi 真机已完成“失败任务重试并复制到 SAF 目录”手工回归：无 Peer 阶段任务 `0 B/22 B` 超时失败，长按选择“重试”后 metadata 文件选择正常；取消选择时任务列表仍为 `全部(1)`，再次确认后旧失败任务被替换而不是重复创建。随后将同一 HTTP 种子地址切换到真实 Transmission Seeder，重试任务完成 `22 B/22 B`，系统目录 `/sdcard/FluxDownTest/no-peer-retry.txt` 与源文件 SHA-256 均为 `bd973a8c54d8c89dbc680e8b5c532c2a76c10b67c775954215b5c736a30f7a3b`。
- 2026-10-02 低内存设备回归：默认 `connectedDebugAndroidTest` 在 CASKA 低内存模拟器上曾因后台服务用例一次性分配 `16 MiB` 测试夹具而触发 OOM；将该用例缩小为 `4 MiB`、仍保留慢速分块和退后台生命周期覆盖后，Redmi 真机报告为 `24` 个用例、`0` 失败、`3` 跳过（缺少外部 fixture 的用例按设计跳过），其余用例全部通过。这只调整测试夹具，不改变下载引擎行为。
- 详情页回归：运行中的 Torrent/Magnet 详情查询最多等待 `30` 秒；超时、metadata 会话失败或 Rust 返回非 `finished` 状态时回退到入队时持久化的目录与文件清单，不覆盖任务真实进度；无论成功、超时还是异常，都会在 `finally` 释放临时 metadata run，避免后台 run 泄漏。Kotlin 单测、编译和 Redmi 真机 connected instrumentation 均通过。
- 任务列表 UI 收口：任务卡之间取消外边距，状态色和已知总量的整卡进度背景连续显示；打开文件操作改用自动镜像图标 API，Kotlin 编译不再产生对应弃用警告。改动后 Redmi 真机 connected instrumentation 仍为 `27` 个测试、`0` 失败、`3` 跳过。
- 新建下载弹框继续收敛为链接、文件名和协议相关选项；保存位置与磁盘容量统计只保留在设置页，避免在新建流程重复展示。改动后 Kotlin 单测、编译和 Redmi 真机 connected instrumentation 均通过。

## 2026-10-01 队列闭环增量（Kotlin Alpha，未发布）

- 新增 `RustQueueInstrumentationTest` 两项真机回归：Kotlin → JNI → Rust 真实回环 HTTP 下载，以及设备上存在过期残留文件时收到 HTTP 416 后清理残留并重新下载。两项均校验任务最终为 `finished`、字节数和落盘内容，不使用预置假数据。
- 新增局域网 P2P 重复入队回归 `queueTorrentAndMagnetDuplicateSelectionDoNotCorruptSharedOutput`：在 Redmi Note 8 Pro 上使用主机 `192.168.1.8` 的真实 Tracker/Transmission Seeder，`.torrent` 和 Magnet 各重复入队两份、均只选择 `kotlin-p2p-bundle/a-selected.bin`；四个任务均进入 `finished`，最终 `65,536/65,536 B`，SHA-256 为 `de7129a343e055ff35229d4679eae6a4dc35c6411495afab8a88164d42c0b85c`。未选择文件没有完整落盘；librqbit 可能留下零字节占位路径，因此验收按完整大小判断，不把占位路径误报为下载内容。
- Rust HTTP 单连接路径补齐 416 处理：只有 `Content-Range` 或额外 `HEAD` 明确证明本地文件已完整时才直接复用；无法证明时删除残留并重新发起无 `Range` 请求，避免截断文件被误判完成或持续卡在 416。
- Rust 分片 HTTP 路径对 416 做确定性回退：当所有 Range 分片均被服务端拒绝时清理临时文件并回退到单连接下载，保持任务可恢复。
- Torrent/Magnet 任务卡现在显示资源目录入口：单文件 metadata 名与文件名相同时去掉扩展名作为入口名称，多文件保留 metadata 目录名；完整文件名、格式、大小和逐文件进度仍在“资源详情”中展示。
- Kotlin 任务列表读取并显示 Rust 持久化的 `started_at_ms`/`finished_at_ms`；运行中显示实时速度，完成态显示完成时间，避免已完成任务继续显示下载速度。
- Torrent/Magnet 新建任务在点击“开始下载”后保留新建弹框，底层异步获取 metadata；清单成功后叠加文件选择弹框，只有确认文件并成功入队后才同时关闭两个弹框，取消选择不会创建空任务。
- Torrent/Magnet metadata 启动失败、解析失败或清单为空时，错误会显示在新建弹框内部，不再只写到被弹框遮挡的页面通知区域；异常返回也会统一收敛为可见错误。
- HTTP/HTTPS、FTP/FTPS、SFTP、SMB、WebDAV、HLS 和 ed2k 的创建失败现在统一回显在新建弹框内；未知协议在入队前被拦截，ed2k 在确认系统接管应用后才创建队列任务，移交失败会清理任务并保留弹框。
- HLS 清晰度读取失败会显示具体 Rust 错误；Torrent/Magnet metadata 增加 90 秒超时，文件确认入队失败会在文件选择弹框内显示；P2P 失败任务重试时重新获取 metadata，不复用旧会话。
- 失败任务长按操作面板显示完整失败原因，避免任务卡单行省略后无法排查协议错误。
- 新建下载流程不再把内部状态追加到任务页顶部；识别失败、入队失败、metadata 错误和外部移交错误只在当前弹框内显示，避免弹框与页面同时出现重复提示。
- Kotlin 任务卡对已知总量的任务使用整卡背景显示下载进度；运行中右上角只显示百分比，完成态只显示“已完成”，右下角完成时间统一为 `yyyyMMdd HH:mm:ss`，任务页标题栏不再提供手动刷新按钮。
- 宿主侧生命周期真机回归：使用全新 `64.0 MiB` Range HTTP 资源 `lifecycle-force-stop-1021.bin`，任务运行到断点后执行 `adb shell am force-stop dev.fluxdown.mobile.kotlin`，再启动 `MainActivity`；目标进程 PID 从 `24185` 变为 `25844`，前台服务在新进程中重新恢复同一队列，最终快照为 `finished`、`67,108,864/67,108,864 B`，无重复任务。该证据覆盖显式强停后的启动恢复，不宣称系统低内存回收或永久后台存活。
- Kotlin 任务页新增 1 秒快照轮询，并用互斥门避免刷新请求重叠；运行中任务可以持续显示 Rust 持久化的真实进度、下载速度和完成时间，轮询不会重复启动前台服务。
- 新增 Android 真机队列回归：暂停/继续保留断点、并发数为 1 时第二任务真实排队、失败重试、416 回退、重置/删除、前台服务中断恢复；当前 instrumentation 共 `15/15` 通过（Redmi Note 8 Pro，serial：`wsvwypiz7xwslvl7`）。本轮仍只生成 `arm64-v8a` 预览包，未切换正式包名或商店签名。
- 新增 Android 压力与异常回归：`16 MiB` HTTP 文件完整落盘并校验 SHA-256；`48` 段、约 `6 MiB` 的 HLS playlist 使用 4 路分片并发完成；服务端提前断开响应体时任务进入 `failed` 且不伪造完成；输出路径被普通文件占用时任务进入 `failed`。完整 instrumentation 已更新为 `19/19` 通过。
- 新增前台服务后台回归 `foregroundServiceCompletesWhenActivityMovesToBackground`：Redmi 真机启动 Kotlin 页面和 `DownloadForegroundService` 后按 Home 将 Activity 退到后台，慢速 `4 MiB` HTTP 任务仍由 Rust 队列完成，输出字节与源内容一致。该证据覆盖“用户离开页面”的持续下载，不宣称系统低内存回收或永久后台存活。
- 新增网络传输中断恢复回归 `queueRecoversAfterMidTransferNetworkInterruptionThroughRust`：Redmi 真机回环 HTTP 首次只返回四分之一响应体后主动断开，Rust 将 `reqwest` 的响应体解码/EOF 异常归类为可重试错误，第二次请求恢复完整文件；任务最终 `finished`、`512 KiB/512 KiB`，服务端收到至少两次请求。该用例覆盖真实传输中断的恢复，不把普通 HTTP 503 冒充网络切换。
- 修复 Rust HTTP 重试分类：响应体读取阶段的 `is_decode()`、EOF、连接关闭和断管错误现在会进入自动重试；认证、权限、磁盘空间不足和资源不存在等不可恢复错误仍不重试。
- 新增可选系统级 Wi-Fi 切换回归 `queueRecoversAfterWifiToggleThroughRust`：在 Redmi 真机连接 `192.168.1.8` 局域网的 `64 MiB` Range HTTP 资源，下载产生真实进度后通过 `svc wifi disable/enable` 切断并恢复 Wi-Fi；主机先收到 `200`，恢复后收到 `206` Range 请求，任务最终完整落盘。该用例必须显式传入 `networkFixtureUrl`/`networkFixtureBytes`，普通 connected instrumentation 默认跳过。

## 当前策略

Android Kotlin 重写采用并行迁移，不立即替换现有 Flutter 包：

1. `apps/mobile` 继续作为现有 Android/iOS 产品入口，保证线上版本和协议回归不受影响。
2. `apps/android` 是 Kotlin + Jetpack Compose 的原生 Android 预览宿主，先做任务列表与设置页。
3. 下载协议、队列 schema、Torrent/Magnet metadata 和暂停/继续等业务仍由 Rust core 提供，Kotlin 不复制 Dart 下载器。
4. Kotlin 通过 `crates/fluxdown-android` 的 JNI 壳调用 ABI 1，读取同一份 Rust `rust-queue.json`。
5. 迁移预览只生成 `arm64-v8a`，完成一轮真实设备验证后再决定包名切换和 Flutter 目录退役。

## 第一阶段已落地

- Kotlin Compose 两个主页面：任务、设置。
- Rust JNI bridge：版本、ABI、协议识别、队列列出/新增/暂停/继续/重置/删除。
- Rust JNI bridge 已暴露非阻塞队列运行、运行状态查询和句柄回收；Kotlin 新建任务后会按设置自动启动 Rust 队列并轮询真实状态。
- 任务新增弹框：链接、可选文件名、保存路径。
- 任务行：状态、进度、已下载量/总量、速度、错误信息、重试和删除；点击任务可暂停/继续。
- 设置持久化：并发 `1-30`、线程 `1-32`、重试 `0-10`、限速 MB/s、保存位置；设置页同时提供存储总量/已用/剩余统计。
- 设置能力已对齐 Flutter：Android Keystore 加密保存用户名密码或 SFTP PEM 私钥，任务只保存凭据引用；`known_hosts` 导入到应用私有副本并通过 Rust 队列运行参数透传；当前版本可请求 GitHub 最新 Release，并打开 APK 下载地址或发布页。
- Rust 凭据运行时支持密码与 SFTP 私钥认证：私钥和口令只存在一次队列运行的内存结构，不序列化到 `queue.json` 或 Rust `DownloadOptions`。
- 新建任务支持小型剪贴板图标填入链接；保存位置支持 Android `OpenDocumentTree`，持久化目录授权后，Rust 先写入每任务应用私有暂存目录，完成态再通过 `DocumentFile` 复制到用户目录。
- Torrent/Magnet 新建任务会先异步读取 metadata，再显示完整目录名、文件名、格式和大小；只有用户确认至少一个文件后才写入队列。队列列表只显示资源目录名，点击目录进入资源详情后查看已确认文件及逐文件已下载量，暂停/继续仍通过长按操作面板完成。
- 已完成任务长按可打开操作面板；本地文件通过 `FileProvider` 授权给系统应用，SAF 文件直接使用持久化 `content://` URI，支持打开、分享、复制链接、重试、暂停/继续、删除和 Torrent 资源详情。
- HLS 链接在新建任务弹框中支持手动填写 variant 编号（从 0 开始）及保留原始 TS 文件，参数会写入 Rust 队列并随任务持久化。
- HLS master playlist 现在可在新建任务弹框中主动读取清晰度列表，展示分辨率、带宽和编码信息；选择某项会自动填入 Rust 使用的 variant 编号，普通 media playlist 保持空列表并继续使用默认清晰度。
- 2026-09-30 缺口补齐：二维码入口增加 `rawValue`/`displayValue` 候选遍历和 Rust 协议校验，普通文本二维码不会抢占后续真实下载链接；新增 JVM 单测和真机 ML Kit 实体二维码 instrumentation。
- 2026-09-30 新增 Android 媒体栈 instrumentation：使用真实双轨、B 帧/多音频、仅音频和仅视频 H.264/AAC MPEG-TS 夹具验证 `MediaExtractor/MediaMuxer`。空 TS、损坏 TS 会失败且不残留伪 MP4，源文件保留便于重试；当前 Redmi 媒体栈对多音频夹具只暴露一条 AAC，输出按系统实际解析到的音视频轨保留，不宣称完整多音轨选择。
- 2026-09-30 Rust HLS 分片缓存增强：缓存绑定最终 media playlist URL 摘要、playlist 正文摘要和逐片 URL/序号/范围；缓存分片记录长度与 SHA-256，临时文件改名后才提交，来源变化或内容损坏会自动清理并重新下载。
- 2026-09-30 Rust HLS 合并改为“并发分片落盘、按序流式读取”：并发任务不再把全部分片字节收集到内存，长视频内存峰值与并发分片规模相关；初始化段在写入临时输出后立即释放。
- Android 前台服务已接入：服务只负责提升进程优先级、维护低重要性通知和轮询 Rust 队列摘要，下载执行仍由 Activity 侧唯一 Rust 运行句柄负责，避免重复启动同一队列。
- Rust 队列进度持久化已修复：Torrent/Magnet 等待首个 Peer 时会先保存已知总大小，即使已下载仍为 `0 B` 也不会在 UI 中错误显示为“未知”。
- `scripts/build-kotlin-android.sh`：用现有 Gradle wrapper 和 cargo-ndk 构建 arm64 JNI/APK。

## 真机验证

2026-09-28 使用 Redmi Note 8 Pro（serial：`wsvwypiz7xwslvl7`）安装调试 APK 验证：

- 通过 `adb reverse tcp:8765 tcp:8765` 访问本机 Range HTTP 服务。
- `http://127.0.0.1:8765/source/torrent-small.txt` 自动命名为 `torrent-small.txt`，真实下载完成，列表显示 `27 B/27 B` 和 `已完成`。
- 16 MB HTTP 文件真实下载完成，说明 JNI 队列不是仅写入任务；另一个网络任务在下载中显示 `下载中` 和暂停按钮，点击任务后真实转为 `已暂停`。
- 2026-09-29 通过局域网真实 P2P 验证 Torrent 多文件选择：电脑 `192.168.1.8` 提供 Tracker/Transmission 做种，手机通过 `adb reverse` 获取 `.torrent`，Info hash 为 `b3f6920b5ee2f3948ed26b7fcf62bd13eaf1b0a5`。双文件种子总大小 `131.1 KB`，仅确认 `kotlin-p2p-bundle/a-selected.bin` 后，任务从 `下载中` 变为 `已完成`，列表显示资源目录 `kotlin-p2p-bundle`；点击目录进入详情后显示 `a-selected.bin` 和 `64.0 KB/64.0 KB`，未确认的 `b-skipped.bin` 未进入任务。该证据证明 Android Kotlin 使用 Rust 队列完成了真实 Peer 下载，而不是只创建任务。
- 2026-09-29 通过同一局域网 Tracker/Transmission 验证 Magnet 真下载：Magnet 使用 `b3f6920b5ee2f3948ed26b7fcf62bd13eaf1b0a5` 和 `http://192.168.1.8:18691/announce`，metadata 弹框中确认 `a-selected.bin` 后，Android Kotlin 任务列表显示资源目录 `kotlin-p2p-bundle`，点击目录进入详情后显示 `a-selected.bin` 和 `64.0 KB/64.0 KB`；未选择的 `b-skipped.bin` 未进入任务。验证过程中发现本地 Seeder 重启后需要先用 Transmission 的真实绝对路径执行“查找数据”并校验，否则会出现“有 Peer 但无可用数据”的假象；校验后同一 Rust/librqbit 链路下载成功。
- 2026-09-29 在同一 Redmi 真机选择系统目录 `FluxDownTest`，通过 `adb reverse` 下载 `http://127.0.0.1:62408/saf-check.txt`（20 B）；任务显示 `已完成` 后，文件复制到 `/sdcard/FluxDownTest/saf-check.txt`，设备端与源文件 SHA-256 均为 `ba8eff80909d6adad8cb9a7ce8ac671d666943158a66a46ea9c50338fb1391c9`。强制停止并重新启动后，目录授权和设置回显仍保留。该证据覆盖了 SAF 授权、私有暂存、完成后复制和持久化回显。
- 设备限制：该机启用了 SELinux，`adb shell run-as dev.fluxdown.mobile.kotlin` 被 `fromRunAs` 拒绝，因此本次文件完整性以 Rust 任务状态、队列字节数和逐文件详情为主，未从 shell 直接读取应用私有目录做二次 hash。
- 2026-09-29 前台服务回归：点击暂停任务继续下载后，系统按预期请求 `POST_NOTIFICATIONS`；授权后 `DownloadForegroundService` 以 `dataSync` 类型进入前台，通知渠道为“下载任务”。将应用切到桌面后服务仍保持 `isForeground=true`，返回应用可继续看到 Rust 队列状态。该服务暂不承诺进程被系统强杀后的自动恢复，启动恢复仍待单独验证。
- 2026-09-29 启动恢复回归：真机新建 `20260614.mp4`（约 `370.6 MB`）HTTP 任务，开始后记录到 `18.5 MB/370.6 MB`，执行 `adb shell am force-stop dev.fluxdown.mobile.kotlin`，再用 `monkey` 重新启动应用；任务仍从 Rust 队列恢复为“下载中”，随后点击暂停可稳定落为“已暂停”，已下载量保持 `18.5 MB`。该证据覆盖 force-stop 后队列不丢失、未伪造完成和可继续操作；不等同于系统低内存回收或长期后台恢复。
- 2026-09-29 任务操作面板回归：在同一 Redmi 真机长按已完成的 `saf-check.txt`，面板显示打开、分享、复制链接和删除；点击打开/分享均成功唤起 Android 系统选择器，未出现 `FileProvider`、URI 授权或崩溃日志。SAF 文件走持久化 `content://` URI，本地私有文件走 `FileProvider`。
- 2026-09-29 HLS 真机回归：同一 Redmi 真机通过 `adb reverse tcp:8765 tcp:8765` 下载本机 VOD playlist `http://127.0.0.1:8765/hls/index.m3u8`，新建弹框填写 variant `0` 并勾选“保留原始 TS 文件”。任务先进入“排队中”，暂停占用中的旧任务后自动转为“下载中”，最终列表显示“已完成”和 `383.2 MB/383.2 MB`；SAF 目录实际生成 `/sdcard/FluxDownTest/index.ts`，大小约 `383 MB`。该证据覆盖 Kotlin → JNI → Rust HLS 分片下载 → SAF 复制的真实链路；master variant 列表已在后续独立夹具中验证。该条记录形成时尚未验证原生 TS→MP4，后续已由 `AndroidHlsRemuxer` 真机复验补齐。
- 2026-09-29 HLS 小资源回归：同一 Redmi 真机通过 `adb reverse tcp:8765 tcp:8765` 下载 `http://127.0.0.1:8765/hls/kotlin-small.m3u8`，输出文件自动命名为 `kotlin-small.ts`，任务从“排队中”进入“下载中”后完成，列表显示 `1,495,352 B/1,495,352 B`；`/sdcard/FluxDownTest/kotlin-small.ts` 已实际落盘，设备端 SHA-256 为 `3b7db768fabf91c1eb4d704bd96af8fa5cf189b655cff0df9628f8d87ec6fc62`。该用例补齐了本轮 Kotlin → JNI → Rust 的小体积 HLS 真机闭环。
- 2026-09-30 FTPS 真机复验：使用局域网地址 `ftps://flux:fluxpass@192.168.1.8:21216/ftps-sample.txt?allowBadCertificate=true`，Redmi 真机通过 Kotlin UI 完成控制连接、EPSV 动态数据连接、TLS 数据通道、`RETR` 和文件落盘，任务显示 `22 B/22 B`、`已完成`。此前 `127.0.0.1 + adb reverse` 的失败原因是只反向了控制端口，未反向 EPSV 返回的动态数据端口，不代表 Rust/Android FTPS 引擎缺陷。
- 2026-09-29 全协议迁移矩阵：HTTP、HTTPS、WebDAV、WebDAVS、FTP、SFTP、SMB、HLS、Torrent、Magnet 均由 Kotlin 新建任务直接进入 Rust 队列，并在 Redmi 真机完成真实下载；Torrent/Magnet 还完成 metadata 文件选择和真实 Peer 下载。ed2k 通过 Kotlin `ACTION_VIEW` 系统移交路径验证：设备未安装 handler 时任务总数保持不变并提示“没有可处理 ed2k 链接的应用”，不会创建假的下载任务。由此，当前 Android Kotlin 端的 12 类协议入口均已迁移到 Kotlin；其中 11 类内建协议本轮真实下载通过，ed2k 为外部客户端移交边界。
- 2026-09-29 Torrent/Magnet 目录入口 UI 回归：使用本机 Tracker `127.0.0.1:18696`、Transmission 做种和双文件资源 `kotlin-ui-bundle`（Info hash `cc05fe3a20b7a36eb8874c1eec1a60e240fc9ae0`），通过当前 Kotlin UI 分别新建 `.torrent` 和 Magnet 任务。队列卡片均显示目录 `kotlin-ui-bundle`，不直接显示 `selected.txt` 或 `skipped.txt`；点击目录进入“资源详情”，详情页按已确认文件显示逐文件进度。该旧快照曾记录任务卡把未选择文件纳入总量，后续已由 Rust 队列进度回调和 Kotlin 兼容解析修正。
- 2026-09-30 Torrent/Magnet 真机复验：使用局域网 Tracker `http://192.168.1.8:18691/announce`、Transmission 做种和双文件资源 `kotlin-p2p-bundle`（Info hash `b3f6920b5ee2f3948ed26b7fcf62bd13eaf1b0a5`），Redmi 真机分别新建 `.torrent` 与 Magnet。metadata 选择页默认全选，取消 `b-skipped.bin` 后确认加入；两条任务均进入“已完成”，任务卡显示目录名 `kotlin-p2p-bundle` 与 `64.0 KB/64.0 KB`，点击目录后“资源详情”只显示 `a-selected.bin`、`BIN · 64.0 KB / 64.0 KB`，未选文件没有进入任务。该证据覆盖 Kotlin → JNI → Rust metadata、文件选择、Peer 下载、选中文件进度统计和目录详情链路。
- 2026-09-30 HLS 容器回归：传统 TS playlist `http://127.0.0.1:8765/kotlin-small.m3u8` 在 Kotlin 真机真实完成，任务显示 `1.4 MB/1.4 MB`；本轮新增 `http://127.0.0.1:8765/index.m3u8` 的原生转封装复验，使用文件名 `ts-remux-test-2`，任务最终显示 `ts-remux-test-2.mp4`、`79.1 KB/79.1 KB`，确认 `AndroidHlsRemuxer` 通过 `MediaExtractor/MediaMuxer` 生成非空 MP4 后才删除 TS。另用带 `#EXT-X-MAP` 的 fMP4 playlist `http://127.0.0.1:8766/index.m3u8` 完成直出 `index.mp4`，任务显示 `62.6 KB/62.6 KB`。随后更长/B 帧、仅音频/仅视频和异常 TS 由 instrumentation 补齐；完整多音轨选择仍受 Android 媒体栈轨道暴露能力限制。
- 2026-09-30 HLS/扫码边界加固：`AndroidHlsRemuxer` 在切换音视频轨道前重新定位 `MediaExtractor`，避免多轨 TS 只写入第一条轨道；重新安装 arm64 Debug APK 后再次下载 `http://127.0.0.1:8765/index.m3u8`，任务显示 `ts-remux-test-3.mp4`、`79.1 KB/79.1 KB`，logcat 无 `FATAL EXCEPTION`。扫码回调增加 `displayValue` 兜底，并在异步 CameraX provider 回调绑定前检查弹框是否已释放。随后补充 `AndroidHlsRemuxerTest` 和真实二维码位图 instrumentation，双轨、B 帧/多音频夹具的可解析轨道、仅音频、仅视频、空/损坏 TS 与 ML Kit 实体识别共 7 项均已通过；多音频仍受设备 `MediaExtractor` 轨道暴露能力限制。
- 2026-10-01 后台生命周期宿主复验：Redmi 真机使用本机 `adb reverse tcp:8766 tcp:8766` 的慢速 Range HTTP 资源 `lifecycle-force-stop-1021.bin`（`64.0 MiB`）。任务启动后执行 `adb shell am force-stop dev.fluxdown.mobile.kotlin`，重新启动 `MainActivity` 后目标 PID 从 `24185` 变为 `25844`；服务重新调用 Rust 队列，最终通过 instrumentation 直接读取默认 `rust-queue.json`，确认状态 `finished`、`67,108,864/67,108,864 B`，文件字节数完整且没有新增重复任务。该证据覆盖显式强停后的恢复和断点续传，不等同于系统低内存回收或长期后台存活保证。
- 2026-09-30 暂停/继续真机回归：使用本机 `http://127.0.0.1:8765/hls/index.m3u8`（经 `adb reverse`）创建 `index.mp4` 任务。限速期间点击任务后状态稳定为 `已暂停`，再次点击继续恢复为 `下载中`，最终显示 `383.2 MB/383.2 MB` 和 `已完成`。期间修复 Rust 队列收尾竞态：旧暂停协程不再把用户已经重新排队的任务覆盖回 `paused`。
- 2026-09-30 HTTP 瞬态错误重试真机回归：本地夹具前两次返回 `503`，第三次返回 `200`；Kotlin 设置保留自动重试 `3` 次，任务最终显示 `flaky.bin`、`24 B/24 B`、`已完成`，服务端计数为 `3`。这证明 Android Kotlin 的重试参数已透传到 Rust 队列，且成功结果来自真实响应而非预置假数据。
- 2026-09-30 扫码入口真机回归：新建下载弹框中的扫码入口可唤起系统相机权限请求，授权后 CameraX 预览稳定显示，ML Kit 分析器已绑定生命周期；退出扫码能回到下载链接输入框且无崩溃。协议识别结果为空时不会误回填普通文本；ZXing 实体二维码 instrumentation 和用户手持相机实拍回填均已确认识别结果与下载链接一致。
- 2026-09-30 SFTP 凭据与主机指纹真机回归：在设置中保存 `sftp-key4` 凭据引用并导入匹配的 `known_hosts`，通过 `sftp://192.168.1.8:2222/Downloads/fluxdown-kotlin-sftp.txt` 下载 `41 B` 文件，任务进入“已完成”。替换为伪造指纹后，`sftp-bad-host.txt` 在传输前失败并提示主机身份校验错误；同时确认 URL 已含用户名时不能再叠加凭据引用，SFTP 绝对路径按远程用户主目录解析，避免把 `/Users/long/...` 重复拼接。
- 2026-09-30 返回退出提示真机回归：安装本轮 arm64 debug APK 后，在任务首页按系统返回键显示“退出 FluxDown”确认框；点击取消后仍停留在任务页，未触发 Activity 退出或崩溃。确认文案明确说明已入队任务继续由后台服务运行。
- 2026-10-01 构建与启动复验：`cargo fmt --all -- --check`、`cargo test --locked -p fluxdown-core -p fluxdown-ffi`（core 116、FFI 14）和 `apps/mobile/android/gradlew -p apps/android :app:compileDebugKotlin --no-daemon` 均通过；随后 `:app:connectedDebugAndroidTest` 在同一 Redmi 真机 10/10 通过。
- 2026-10-01 Kotlin 异常网络 instrumentation：新增 `queueRetriesTransientHttpFailureThroughRust`，设备回环 HTTP 前两次返回 `503`、第三次返回 `200`，Kotlin 设置的 `retryAttempts=2` 透传到 Rust runner，任务真实进入 `finished` 且输出字节完全匹配；同一 Redmi 真机 connected instrumentation 更新为 `11/11`。
- 2026-10-01 HLS 分片实时指标：Rust 队列快照新增可选 `hls_segments_written`/`hls_segments_total`，HLS 并发下载在每个分片完成或命中缓存后持久化真实 `n/m`；Kotlin 任务卡在下载中、完成和失败状态显示“分片 n/m”，同时继续显示字节进度和实时速度。旧队列缺少字段时按未知处理，不把字节数伪装成分片数。
- 2026-10-01 HLS 分片真机验收：按 `scripts/build-kotlin-android.sh` 重建 arm64 Debug APK（`57 MB`，SHA-256 `1e2b41d47cc1c79e3e8a594582ea3c488230ee0beeafcc7a040407d46868d039`）并安装到 Redmi Note 8 Pro `wsvwypiz7xwslvl7`；`queueStreamsLongHlsPlaylistThroughRust` 真实跑完 48 段、每段 128 KiB 的本机回环资源，队列快照断言 `hls_segments_written=48`、`hls_segments_total=48`，输出字节完整。connected instrumentation 共 25 项结束、2 项按环境跳过、0 失败，应用启动无 `FATAL EXCEPTION`。
- 2026-10-01 公网 HLS 真机验收：通过显式参数运行 `queueDownloadsConfiguredPublicHlsThroughRust`，资源为 `https://hd.kuktxu.com/play/dwpklmMe/index.m3u8`；Redmi 真机上的 Kotlin → JNI → Rust 队列最终为 `finished`，断言输出文件非空、分片总数大于 0 且 `hls_segments_written == hls_segments_total`。该用例默认跳过，避免基础套件依赖公网站点。
- 2026-10-01 Torrent/Magnet 错误弹框真机回归：在 Redmi 真机新建 `https://example.com/invalid.torrent`，metadata 返回 HTTP 404；新建弹框内部显示“Torrent/Magnet 清单获取失败”和具体错误内容，弹框保持打开且未创建任务。
- 2026-10-01 Kotlin Release 构建检查：`npm run mobile:kotlin:release` 通过，R8 与资源收缩生效，产物 `app-release.apk` 为 `24 MB`、仅包含 `lib/arm64-v8a/libfluxdown_android.so`，此前 Alpha 4 构建版本为 `1.0.28-kotlin-alpha.4`。因 `apps/android/key.properties` 尚不存在，签名仍为 `Android Debug`（仅能用于预览安装），正式证书和升级兼容仍未宣称完成。
- 2026-10-01 Alpha 5 本地产物：版本 `1.0.28-kotlin-alpha.5`、versionCode `2032`，APK `25,465,282` bytes，SHA-256 `0073dddc222565d42a37c62c7de654536adf11db805ac1484e6b9ee61669abd9`；`apkanalyzer` 确认包名 `dev.fluxdown.mobile.kotlin` 且只包含 `arm64-v8a`，`apksigner` v2 校验通过。安装到 Redmi 真机后启动到 `MainActivity`，无 `FATAL EXCEPTION`。
- 2026-09-30 HLS 输入护栏回归：Rust 对空媒体 playlist（包括只有初始化段、没有实际媒体分片的情况）直接返回 `InvalidM3u8`，新增核心单测通过，避免生成 0 字节“成功”任务。
- 2026-09-29 HLS master variant 真机回归：本机 HTTP fixture 提供 320x180/64 kbps 与 1280x720/256 kbps 两个 variant，Redmi 真机通过 `adb reverse tcp:8765 tcp:8765` 在新建任务弹框点击“读取 HLS 清晰度”，界面正确显示 `#0`、`#1` 两项；JNI 加载成功，logcat 无 `FATAL EXCEPTION`。同时修正 ML Kit 回调从分析线程写 Compose 状态的问题，识别结果与错误提示统一切回主线程。

## 本轮设置迁移验证

- Kotlin 编译：`apps/mobile/android/gradlew -p apps/android :app:compileDebugKotlin --no-daemon` 通过。
- Rust 回归：`cargo test --locked -p fluxdown-core -p fluxdown-ffi` 通过（core 118、FFI 14）；新增 HTTP `.torrent` 远程种子必须走 `from_bytes`、Magnet metadata 预览选项必须保留零文件下载和 Tracker 刷新的回归测试，并保留 HLS 缓存来源/损坏校验、较大 HLS 流式合并、HLS 分片指标、Torrent 选中文件进度统计、空 HLS playlist 护栏和 FFI 私钥凭据解析测试。
- 2026-09-29 Redmi 真机凭据保存回归：首次测试发现旧 Keystore 别名可能无法解析，且 AES/GCM 不允许调用方指定 IV；修复为失效别名幂等删除、由 Keystore 自动生成 IV 并随密文保存后，使用引用 `credtest`、用户名 `testuser`、密码 `testpass` 保存成功，设置页显示引用。强制停止并重新启动应用后引用仍然显示，证明加密偏好和引用列表可持久化；日志无 `FATAL EXCEPTION`。
- 2026-09-29 Redmi 真机新建任务凭据选择回归：新建任务弹框中的“凭据引用（可选）”可展开菜单，显示“不使用凭据”和已保存的 `credtest`，选择菜单项不会创建任务或崩溃。
- 2026-09-30 Redmi 真机密码凭据下载与失效重试回归：在 Android Keystore 保存引用 `auth-basic`（用户名 `flux`），新建 HTTP 任务选择该引用，通过 `adb reverse tcp:8770 tcp:8770` 访问 Basic Auth 夹具，任务真实完成并显示 `auth.txt`、`28 B/28 B`、`已完成`。随后在设置页删除该引用，再从已完成任务的长按菜单点击“重新下载”；任务先进入“排队中”，随后真实失败并显示“下载凭据不可用，请检查系统凭据库中的引用和权限。”，没有假完成，证明完成任务重新下载入口和凭据失效错误路径均生效。
- 2026-09-29 Redmi 真机版本检查回归：设置页点击“检查更新”成功显示“已是最新版本”、当前版本、更新说明和“打开下载页”按钮；当前网络环境下未执行外部浏览器页面的二次下载验证。
- 带密码 HTTP、SFTP `known_hosts` 命中/拒绝、FTPS 局域网数据通道和删除凭据后二次运行失败路径均已完成真机验证；后续只需把这些用例纳入稳定的发布前自动化入口。

## 剩余能力缺口

- 凭据设置的真实设备闭环已覆盖添加、加密保存、重启回显、新建任务引用选择、带密码 HTTP 下载、SFTP 私钥/`known_hosts` 命中与拒绝，以及删除凭据后重新下载的失败提示；二维码扫描代码已接入 CameraX + ML Kit，实体二维码 instrumentation 和手持相机实拍回填均已通过。
- HLS 逐文件指标不适用于单一 HLS 资源，当前已补齐逐分片实时指标；系统级 ENOSPC、长期后台异常网络仍待补。真实局域网 Torrent/Magnet 多文件重复下载压力已完成。当前物理 Redmi 分区仍有约 `102.7 GiB` 可用，非 root 环境不能安全制造真实 ENOSPC；Rust 已有 `ErrorKind::StorageFull` 不重试和中文错误单测，Android 真机只保留无效路径/权限等邻近回归，不把它们冒充磁盘已满。
- 后台恢复已覆盖 Activity 退后台、force-stop 后断点续传和前台服务保活，系统返回退出提示已在真机通过；仍需覆盖系统低内存回收、网络切换和更长时长后台场景。
- 正式商店签名升级和正式包名切换仍未完成；本次 Alpha 使用本机专用预览签名，仅用于迁移预览和真机安装。

## 构建

```zsh
npm run mobile:kotlin:debug
npm run mobile:kotlin:release
```

脚本会先构建 `libfluxdown_android.so`，再调用 `apps/mobile/android/gradlew -p apps/android`。构建输出位于
`apps/android/app/build/outputs/apk/`，不与现有 Flutter APK 混用。

本轮补充证据：上一轮 `npm run mobile:kotlin:debug` 构建并安装到 Redmi `wsvwypiz7xwslvl7` 成功，`lib/arm64-v8a/libfluxdown_android.so` 已包含 HLS variant JNI 导出；上一轮 arm64 Debug APK 为 `60,210,314` bytes，SHA-256 为 `7eb744e42702ee22fe4c514e180c8515f62bdbf08fb76af1bb2655a969c339db`，包名 `dev.fluxdown.mobile.kotlin`、版本 `1.0.28-kotlin-alpha.3`，启动进程和 `MainActivity` 均已回验。本次 Alpha 6 会重新构建 release APK 并以远端 Release 资产为准；当前没有 `apps/android/key.properties`，因此仍使用 Android Debug 证书，不等同于正式商店签名。

Kotlin Release 签名准备：`apps/android/app/build.gradle.kts` 现在支持 `apps/android/key.properties`，字段与 Flutter Android 工程一致（`storeFile`、`storePassword`、`keyAlias`、`keyPassword`），模板见 `apps/android/key.properties.example`。未配置真实密钥时 Release 明确回退到 debug 签名，仅用于安装测试；配置密钥后才会使用 release signing config。当前仍未配置正式证书，也未切换正式 `applicationId`。

## 切换门槛

只有在 Kotlin 端完成 Rust 队列真实下载、目录权限、扫码、凭据、Torrent/Magnet 多文件选择和前台服务回归后，才切换正式 `applicationId`；在此之前，Kotlin 预览使用独立包名 `dev.fluxdown.mobile.kotlin`，可与 Flutter 版并装。
