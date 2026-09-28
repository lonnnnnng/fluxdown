# P2 阶段完成记录

核对时间：2026-09-27（北京时间）

本记录只描述当前源码工作树与已执行的自动化/设备证据，不把未具备环境条件的平台写成全平台真机通过。

| 项目 | 结论 | 关键证据与边界 |
| --- | --- | --- |
| P2-01 Rust 移动下载引擎 | 已完成（混合边界） | Rust FFI 已支持异步单任务/队列、Torrent/Magnet metadata 异步读取、暂停/继续/重置/删除、并发/线程/重试/限速、HTTP/HLS 与已完成 metadata 选择的 Torrent/Magnet；Android 三 ABI 真机 HTTP/HLS 队列与 HLS variant/fMP4 通过。metadata 失败直接阻止新建任务，旧任务执行回退、SFTP 私钥和 ed2k 外部移交仍由端侧适配器负责。 |
| P2-02 系统后台下载 | 已完成（平台边界） | Android 前台服务负责存活优先级、通知 channel 和进度；iOS 使用系统允许的短时 `beginBackgroundTask`。进程被回收后由启动恢复逻辑接管，不能承诺 iOS 永久后台或 force-stop 后继续下载。 |
| P2-03 队列格式演进 | 已完成 | Rust canonical schema v2、tombstone、旁路锁、原子写、迁移快照、事务 marker、启动恢复和按更新时间冲突合并均已实现，并由 core/FFI/Flutter 回归覆盖。未知 schema/状态不会静默降级。 |
| P2-04 ed2k 外部客户端 | 已完成（移交通路边界） | 桌面/CLI 优先 aMule CLI、缺失时系统 URL handler；移动端使用 `url_launcher`。任务保存 `handed-off`/`handedOff`、后端和移交时间，不冒充 `finished`。第三方客户端的进度、完成回传、最终路径和客户端选择没有稳定通用 API，FluxDown 不宣称已掌控。 |
| P2-05 凭据与连接安全 | 已完成（支持边界） | 桌面/CLI 使用系统凭据库、known_hosts、SSH agent 和单跳跳板；移动端使用 Keystore/Keychain，密码凭据通过 Rust FFI 临时参数或 Dart 请求使用，SFTP 私钥固定走 Dart 握手，任务 JSON 只保存引用。Android 真机和 iOS simulator 的私钥/known_hosts/错误指纹回归通过；移动端 ssh-agent、跳板机和 iOS 物理真机仍明确不支持或受环境限制。 |

## 回归结果

- `cargo test --workspace`：core 105、CLI 集成 37、桌面 38（8 项需要外部实时 P2P/FTP/SFTP/SMB 夹具的用例按预期忽略）、FFI 10，全部通过。
- `flutter analyze`：通过。
- `flutter test`：全部通过；未注入动态库时 17 个 host FFI 用例按预期跳过。重新构建 `target/debug/libfluxdown_ffi.dylib` 后，`test/core_ffi_test.dart` 的 24 项（含 Torrent/Magnet、凭据引用和队列控制）全部通过。
- `node --test scripts/github-release-assets.test.mjs`：15/15 通过。
- `./gradlew :app:compileDebugKotlin`：通过，仅保留 Android `Notification.Builder(Context)` 的弃用警告。
- `flutter build ios --simulator --no-codesign`：通过，生成 `apps/mobile/build/ios/iphonesimulator/Runner.app`。
- `flutter build apk --release`：通过，生成 `app-release.apk`（`144,815,221` bytes，SHA-256 `0fda95829c2f5acfce3462d97b649e9d8b9511ac34cd878a023925aa6c3853fe`）；安装到 Redmi `wsvwypiz7xwslvl7` 后启动正常，版本 `1.0.26 (27)`，前台服务权限和服务注册均存在，未见 `FATAL EXCEPTION`。
- 物理 iPhone、Windows/Linux 桌面本轮不纳入运行结论；Windows/Linux 按此前约定跳过。

## 后续

P2 已按当前产品边界收口。下一阶段进入 P2-06：正式签名、许可证合规、商店分发和发布门禁；移动端可用密码凭据已进入 Rust，私钥/ssh-agent/跳板机属于后续能力评估，不再作为 P2 主线的隐性缺口。
