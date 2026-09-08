# 1.0.16 包体优化与回归记录

核验日期：2026-09-08。目标是保留功能、协议和平台兼容性，尽量减少下载体积，不设固定压缩比例。尚未完成的远端构建和资产回验不会提前标为通过。

## R8 现状

- Android 使用 AGP `8.11.1`。应用 Gradle 没有显式关闭 R8；Flutter Gradle 插件默认设置 Release 的 `isMinifyEnabled=true`、`isShrinkResources=true` 并使用 `proguard-android-optimize.txt`。
- 本地已有 Release `mapping.txt` 明确标注 `compiler: R8`、`compiler_version: 8.11.18`，包含重命名和移除记录；不能因为应用 Gradle 没写开关就判断未启用。
- R8 处理 Android JVM 代码和资源，不直接裁剪 Rust/C++ 原生库或 Dart AOT。原生库按多架构重复打入，是 APK 大小的重要来源。
- 没有为减包扩大 keep 规则，也没有升级 AGP 或切换扫码实现。

## 本次措施

| 范围 | 已实现配置 | 保留边界 |
| --- | --- | --- |
| Rust 全平台 | Thin LTO、单代码生成单元、去除 debug info；CLI/桌面另去符号表 | 保持吞吐优先优化与 panic 展开，保留移动 FFI 导出 |
| Android APK/AAB | 分离 Dart 调试符号、移除没有使用的 Cupertino 图标字体 | 保留 arm64-v8a、armeabi-v7a、x86_64，以及扫码、Torrent 和所有协议 |
| iOS Release | 分离 Dart 调试符号，链接优化后的 Rust 静态库 | 不裁剪 FFI 导出，不改变签名/真机验证边界 |
| macOS DMG | 原有 UDZO 容器使用 zlib level 9 | 不更换镜像格式，不修改 App 内容与安装操作 |
| Windows Setup / Linux DEB | 从优化后的 Rust 二进制生成 | Windows 保持 NSIS 默认 LZMA，DEB 不引入新系统依赖 |
| Linux RPM | XZ level 6 | 标准 RPM 压缩格式 |
| 三平台 CLI | Windows ZIP、macOS/Linux TAR.GZ | 解压后保留原二进制内容、许可证及 Unix 可执行权限 |

Dart `.symbols` 与 Android R8 mapping 保存在 CI 的 `fluxdown-android-symbols` / `fluxdown-ios-symbols`。恢复 Dart 堆栈需要相同版本和架构的符号配合 `flutter symbolize`；没有启用 Dart 标识符混淆。Actions Artifacts 有保留期，生产问题排查所需符号应另做长期归档。

## 队列回归阻断

`v1.0.15` / `a90e63c` 的 [流水线 34191232572](https://github.com/lonnnnnng/fluxdown/actions/runs/34191232572) 在 Linux CLI 的跨进程删除测试失败，因此没有发布 Release。

- 原实现只有进程内互斥。原子替换避免半截 JSON，但无法避免另一个进程的新增、删除或暂停被旧快照覆盖。
- 新增回归在旧实现上复现：16 个 CLI 并发添加，最后仅保留 1 个；持有跨进程锁时，旧 CLI 仍提前写入队列。
- `store.rs` 增加稳定旁路文件锁，覆盖完整读改写，等待锁放到阻塞线程池。`runner.rs` 发现删除立即取消，最终删除结果不计作下载成功。
- 修复后的本地 debug 和 Release Core/CLI 各 113 项通过，包含新增 2 项回归及原有跨进程暂停、恢复、删除用例；桌面 Rust 另有 33 项通过、7 项外部环境用例忽略。

## 测量与验证

最终对比应使用相同架构的 CI 程序/安装包，区分原生二进制大小和压缩后下载大小。基线取失败发版中已成功构建的 `1.0.15` 产物，不把“未发布”写成“旧 Release”；Linux CLI 基线因该作业失败不可用。

本地预检：macOS CLI 从基线 CI 的 `15,732,112` 字节降至本地候选的 `9,321,136` 字节；这还不是最终远端资产对比。优化后的 host Release FFI 已通过 50 项 Flutter 测试，含真实协议识别、队列和本地 HTTP 文件大小/内容核验。

本地 macOS App/DMG 与 iOS unsigned Release 构建通过；DMG 签名校验和最终 iOS Runner 的 8 个 FFI 导出检查通过。`npm run verify:release-cli-smoke` 用已构建的 macOS Release CLI 跑通版本、detect/add/pause/resume/run/list/download，队列和直接下载各 256 KiB，SHA-256 均为 `31a1f9dea0169551092d05e8bf4a446228c8c3eb4c9b713c66adcb7fd53c89be`。这是隔离本地 HTTP/Range 回归，不是公网或全协议验收。

11 项公开资产策略回归通过，覆盖白名单、大小/哈希、缺包、多余文件、重复项、三平台 CLI 解压内容与 Unix 可执行权限。其输入是隔离打包夹具，不冒充真实安装包验证。

本轮没有启动 GUI 或设备、没有改动用户队列；原生 App 全协议真运行仍需单独验收。后续 CI、最终包体大小和远端回验结果见 [下载验证状态](download-verification.md)。

## 参考

- [Cargo profile](https://doc.rust-lang.org/cargo/reference/profiles.html)：核验 strip、LTO、代码生成单元及 panic 行为。
- [Rust File locking](https://doc.rust-lang.org/std/fs/struct.File.html#method.lock)：系统锁在 Unix/Windows 的行为及句柄关闭时释放规则。
- `flutter build apk --help`：核验 `--split-debug-info`、`--obfuscate` 和多 ABI 的行为区别。
