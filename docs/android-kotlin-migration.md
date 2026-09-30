# Android Kotlin 重写进度

核对日期：2026-09-30。当前源码版本：`1.0.28-kotlin-alpha.2`。

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
- 2026-09-30 HLS 容器回归：传统 TS playlist `http://127.0.0.1:8765/kotlin-small.m3u8` 在 Kotlin 真机真实完成，任务显示 `1.4 MB/1.4 MB`；本轮新增 `http://127.0.0.1:8765/index.m3u8` 的原生转封装复验，使用文件名 `ts-remux-test-2`，任务最终显示 `ts-remux-test-2.mp4`、`79.1 KB/79.1 KB`，确认 `AndroidHlsRemuxer` 通过 `MediaExtractor/MediaMuxer` 生成非空 MP4 后才删除 TS。另用带 `#EXT-X-MAP` 的 fMP4 playlist `http://127.0.0.1:8766/index.m3u8` 完成直出 `index.mp4`，任务显示 `62.6 KB/62.6 KB`。因此 Kotlin HLS 的 TS→MP4、fMP4→MP4 和可选保留 TS 路径均已通过；更长视频、多音轨和异常媒体仍需扩展回归。
- 2026-09-30 HLS/扫码边界加固：`AndroidHlsRemuxer` 在切换音视频轨道前重新定位 `MediaExtractor`，避免多轨 TS 只写入第一条轨道；重新安装 arm64 Debug APK 后再次下载 `http://127.0.0.1:8765/index.m3u8`，任务显示 `ts-remux-test-3.mp4`、`79.1 KB/79.1 KB`，logcat 无 `FATAL EXCEPTION`。扫码回调增加 `displayValue` 兜底，并在异步 CameraX provider 回调绑定前检查弹框是否已释放。当前仍没有 Android 媒体栈自动化测试目录，多轨媒体还需补独立夹具。
- 2026-09-30 后台生命周期真机回归：Redmi 真机通过 `adb reverse tcp:8771 tcp:8771` 下载慢速 Range HTTP 资源 `lifecycle.bin`（`64.0 MiB`）。强停前任务显示 `24.1 MB/64.0 MB`、`下载中 37%`；重新启动 `dev.fluxdown.mobile.kotlin` 后同一任务从持久 Rust 队列继续，先显示 `43.7 MB/64.0 MB`，最终进入 `已完成 100%`。未出现重复任务，证明当前 Kotlin Activity 重建/新进程启动恢复路径可继续断点任务；这仍不等同于系统低内存回收或长期后台存活保证。
- 2026-09-30 扫码入口真机回归：新建下载弹框中的扫码入口可唤起系统相机权限请求，授权后 CameraX 预览稳定显示，ML Kit 分析器已绑定生命周期；退出扫码后能回到下载链接输入框且无崩溃。本轮同时修正协议识别结果为空时误回填普通文本的边界。由于没有可控的实体二维码画面注入条件，仍未把“二维码实拍识别并回填链接”标记为通过。
- 2026-09-30 SFTP 凭据与主机指纹真机回归：在设置中保存 `sftp-key4` 凭据引用并导入匹配的 `known_hosts`，通过 `sftp://192.168.1.8:2222/Downloads/fluxdown-kotlin-sftp.txt` 下载 `41 B` 文件，任务进入“已完成”。替换为伪造指纹后，`sftp-bad-host.txt` 在传输前失败并提示主机身份校验错误；同时确认 URL 已含用户名时不能再叠加凭据引用，SFTP 绝对路径按远程用户主目录解析，避免把 `/Users/long/...` 重复拼接。
- 2026-09-30 返回退出提示真机回归：安装本轮 arm64 debug APK 后，在任务首页按系统返回键显示“退出 FluxDown”确认框；点击取消后仍停留在任务页，未触发 Activity 退出或崩溃。确认文案明确说明已入队任务继续由后台服务运行。
- 2026-09-30 构建与启动复验：`cargo fmt --all -- --check`、`cargo test --locked -p fluxdown-core -p fluxdown-ffi`（core 108、FFI 14）和 `apps/mobile/android/gradlew -p apps/android :app:compileDebugKotlin --no-daemon` 均通过；`npm run mobile:kotlin:debug` 重新生成 arm64 Debug APK，安装到 Redmi `wsvwypiz7xwslvl7` 后 `dev.fluxdown.mobile.kotlin/dev.fluxdown.android.MainActivity` 正常启动，最近 400 行 logcat 未发现 `FATAL EXCEPTION`。
- 2026-09-30 HLS 输入护栏回归：Rust 对空媒体 playlist（包括只有初始化段、没有实际媒体分片的情况）直接返回 `InvalidM3u8`，新增核心单测通过，避免生成 0 字节“成功”任务。
- 2026-09-29 HLS master variant 真机回归：本机 HTTP fixture 提供 320x180/64 kbps 与 1280x720/256 kbps 两个 variant，Redmi 真机通过 `adb reverse tcp:8765 tcp:8765` 在新建任务弹框点击“读取 HLS 清晰度”，界面正确显示 `#0`、`#1` 两项；JNI 加载成功，logcat 无 `FATAL EXCEPTION`。同时修正 ML Kit 回调从分析线程写 Compose 状态的问题，识别结果与错误提示统一切回主线程。

## 本轮设置迁移验证

- Kotlin 编译：`apps/mobile/android/gradlew -p apps/android :app:compileDebugKotlin --no-daemon` 通过。
- Rust 回归：`cargo test -p fluxdown-core -p fluxdown-ffi` 通过（core 109、FFI 14）；新增 Torrent 选中文件进度统计、空 HLS playlist 护栏和 FFI 私钥凭据解析测试，并确认序列化结果不包含私钥正文。
- 2026-09-29 Redmi 真机凭据保存回归：首次测试发现旧 Keystore 别名可能无法解析，且 AES/GCM 不允许调用方指定 IV；修复为失效别名幂等删除、由 Keystore 自动生成 IV 并随密文保存后，使用引用 `credtest`、用户名 `testuser`、密码 `testpass` 保存成功，设置页显示引用。强制停止并重新启动应用后引用仍然显示，证明加密偏好和引用列表可持久化；日志无 `FATAL EXCEPTION`。
- 2026-09-29 Redmi 真机新建任务凭据选择回归：新建任务弹框中的“凭据引用（可选）”可展开菜单，显示“不使用凭据”和已保存的 `credtest`，选择菜单项不会创建任务或崩溃。
- 2026-09-30 Redmi 真机密码凭据下载与失效重试回归：在 Android Keystore 保存引用 `auth-basic`（用户名 `flux`），新建 HTTP 任务选择该引用，通过 `adb reverse tcp:8770 tcp:8770` 访问 Basic Auth 夹具，任务真实完成并显示 `auth.txt`、`28 B/28 B`、`已完成`。随后在设置页删除该引用，再从已完成任务的长按菜单点击“重新下载”；任务先进入“排队中”，随后真实失败并显示“下载凭据不可用，请检查系统凭据库中的引用和权限。”，没有假完成，证明完成任务重新下载入口和凭据失效错误路径均生效。
- 2026-09-29 Redmi 真机版本检查回归：设置页点击“检查更新”成功显示“已是最新版本”、当前版本、更新说明和“打开下载页”按钮；当前网络环境下未执行外部浏览器页面的二次下载验证。
- 仍需补：二维码实拍识别并回填链接；带密码 HTTP、SFTP `known_hosts` 命中/拒绝、FTPS 局域网数据通道和删除凭据后二次运行失败路径均已完成真机验证。

## 剩余能力缺口

- 凭据设置的真实设备闭环已覆盖添加、加密保存、重启回显、新建任务引用选择、带密码 HTTP 下载、SFTP 私钥/`known_hosts` 命中与拒绝，以及删除凭据后重新下载的失败提示；二维码扫描代码已接入 CameraX + ML Kit，真机已验证权限申请和实时预览，仍需补二维码实拍识别。
- HLS 逐文件实时指标、更大文件及异常网络回归仍待补；在线 variant 列表、手动 variant 编号、传统 TS→MP4、fMP4 直出 MP4 和 TS 保留均已完成验证，多轨切换保护已补齐，但更长视频、多音轨、B 帧和异常 playlist 仍需扩展回归；Android 媒体栈自动化测试尚未建立。
- 后台恢复已覆盖 force-stop 后断点续传和前台服务保活，系统返回退出提示已在真机通过；仍需覆盖系统低内存回收和长时间后台场景。
- 正式商店签名升级和正式包名切换仍未完成；本次 Alpha 使用本机专用预览签名，仅用于迁移预览和真机安装。

## 构建

```zsh
npm run mobile:kotlin:debug
npm run mobile:kotlin:release
```

脚本会先构建 `libfluxdown_android.so`，再调用 `apps/mobile/android/gradlew -p apps/android`。构建输出位于
`apps/android/app/build/outputs/apk/`，不与现有 Flutter APK 混用。

本轮补充证据：`npm run mobile:kotlin:debug` 构建并安装到 Redmi `wsvwypiz7xwslvl7` 成功，`lib/arm64-v8a/libfluxdown_android.so` 已包含 HLS variant JNI 导出；`npm run mobile:kotlin:release` 通过 R8 和资源压缩，生成约 24 MB 的 arm64 unsigned APK。本次 Alpha 另外使用本机专用预览密钥签名并通过 `apksigner verify`，不等同于正式商店签名；由于后续真机当前未连接，发布前只完成构建、签名和静态包回验。

## 切换门槛

只有在 Kotlin 端完成 Rust 队列真实下载、目录权限、扫码、凭据、Torrent/Magnet 多文件选择和前台服务回归后，才切换正式 `applicationId`；在此之前，Kotlin 预览使用独立包名 `dev.fluxdown.mobile.kotlin`，可与 Flutter 版并装。
