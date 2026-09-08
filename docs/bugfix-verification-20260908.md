# 2026-09-08 修复验证与文档差异

发行归属：修复先进入 `v1.0.15`，该次 CI 因 Linux CLI 跨进程删除回归失败而未发布；后续修复与包体优化纳入 [1.0.16](releases/1.0.16.md)。下文保留初始修复阶段的版本、未提交状态和验证边界，后续证据另见 [下载验证状态](download-verification.md)。

## 范围与结论

- 基线：`main` / `e0f2a698f210094629cdbf76c54e65d690656f7f`。2026-09-08 执行 `git pull --ff-only`，远端无更新。
- 最新已发布版本为 [v1.0.14](https://github.com/lonnnnnng/fluxdown/releases/tag/v1.0.14)，GitHub Release API 已核对到 19 个 assets；本次未下载回验这些远端资产。
- 本次修复 iOS FFI 构建/链接、移动 FFI 解码/桥接、桌面 Torrent 分文件进度。源码版本仍为 `1.0.14`，这些修复尚未发布，不包含在已有 Release 中。
- 本地定向验证通过。没有提交、推送、打 tag、触发远端 CI 或安装到用户真机；没有修改用户下载队列。

## 修复清单

| 问题 | 根因 | 修复与定位 |
| --- | --- | --- |
| iOS FFI 构建失败，Runner 未链接 Rust 库 | Rust/C 的最低部署目标与 Runner/SDK 不一致；仅生成 `.a` 不能保证 App 内可用 | [build-ios-ffi.sh](../scripts/build-ios-ffi.sh) 统一 iOS 15.0 并区分真机/模拟器架构；[FluxDownFfi.xcconfig](../apps/mobile/ios/Flutter/FluxDownFfi.xcconfig) 与 Runner 构建阶段静态链接、保留 8 个导出；[产物验证](../scripts/verify-artifacts.mjs) 检查最终二进制符号。 |
| 移动端 FFI 每次调用都失败并回退 Dart | Rust 返回 JSON 文本，Dart 未解码就按 Map 使用；桥接层又重复读取 `data` | [fluxdown_ffi.dart](../apps/mobile/lib/src/ffi/fluxdown_ffi.dart) 先解析信封、检查 ABI、严格校验队列形状，并分别释放 Dart 入参与 Rust 返回字符串；[core_bridge.dart](../apps/mobile/lib/src/core_bridge.dart) 只读取一次解包后的结果。 |
| 桌面 Torrent 详情没有分文件进度 | 后端已有 `progress_bytes`，前端只展示名称/总大小；轮询仍持有打开时的任务状态 | [App.tsx](../apps/desktop/src/App.tsx) 的 `TorrentFileProgressRow` 增加字节数、百分比、进度条；详情跟随队列当前状态，暂停/关闭停止轮询，丢弃关闭或切换后的迟到响应。静态 metadata 显示未知进度。 |

## 本地验证

环境：Apple Silicon macOS、Xcode 16.2（16C5032a）、Rust 1.97.1、Flutter 3.41.9、Dart 3.11.5。

| 检查 | 实际结果 | 证据边界 |
| --- | --- | --- |
| `cargo build --locked -p fluxdown-ffi` | 通过，生成 host `target/debug/libfluxdown_ffi.dylib` | macOS host 库，不是移动端原生库运行验证。 |
| `flutter analyze --no-pub` | 无问题 | 静态分析。 |
| 完整 `flutter test`，显式传入 host 库 | 50 项通过 | 包含原有移动测试和新增 8 项 FFI 测试；不是 50 项真机下载。 |
| 单独运行 `test/core_ffi_test.dart`，显式传入 host 库 | 8 项通过 | 4 项 JSON 信封、4 项原生库测试；覆盖 ABI/版本、12 类协议识别、Unicode 队列、原生错误和真实本地 HTTP 下载。 |
| `bash scripts/build-ios-ffi.sh` | 真机 arm64 静态库构建通过 | Rust/C 部署目标统一为 iOS 15.0。 |
| `flutter build ios --no-codesign --no-pub`（UTF-8 locale） | Release `Runner.app` 构建通过，约 57 MB | 未签名、未在 iPhone 启动。 |
| `flutter build ios --simulator --no-pub` | arm64 + x86_64 模拟器 App 构建通过 | 本次未启动模拟器 App 做下载。 |
| `npm run mobile:ios:verify` / `mobile:ios:simulator:verify` | 均检出 8 个 FFI 导出 | 真机 `Runner`、模拟器 `Runner.debug.dylib`；另按 arm64/x86_64 分别用 `nm` 核验模拟器导出。 |
| `xcrun vtool -show-build` 检查真机 Runner | `minos 15.0`、SDK 18.2 | 确认最终二进制部署目标。 |
| `npm --workspace apps/desktop run build` | TypeScript/Vite 通过 | 前端编译，不是原生桌面协议 E2E。 |
| `cargo test --locked -p fluxdown-core torrent_details` | 2 项通过 | Torrent 静态详情解析测试。 |
| [桌面进度回归脚本](../scripts/verify-desktop-torrent-progress.js) | 10 项通过 | 隔离浏览器 mock Tauri IPC，无真实队列或真实 P2P 传输。 |
| `npm run verify:ci-config` | 通过 | 手动打包/发版触发策略未改变；没有远端运行。 |
| `plutil -lint`、`bash -n`、`node --check`、`git diff --check` | 通过 | Xcode 配置、脚本语法和差异检查。 |
| 文档链接检查 | 12 份 Markdown，110 个本地引用无缺失 | 检查相对链接、图片路径及所用标题锚点，不代表外部 URL 的可达性。 |

### FFI 复跑

从仓库根目录执行：

```sh
cargo build --locked -p fluxdown-ffi
cd apps/mobile
flutter test --no-pub --dart-define=FLUXDOWN_FFI_TEST_LIBRARY="$(cd ../.. && pwd)/target/debug/libfluxdown_ffi.dylib"
```

真实 HTTP 测试在独立 isolate 启动回环 HTTP 服务，创建临时 Rust 队列，调用原生 `queueAdd`/`queueRun`/`queueList`，检查 `finished`、已下载字节数以及文件内容。它证明绑定层能调用真实下载，不证明 Flutter 产品下载控制器已切换到 Rust。未传库路径时 4 项原生库测试会跳过。

### 桌面 UI 复跑

启动独立本地前端服务，在 Playwright CLI 的隔离会话打开该地址后执行：

```sh
playwright-cli --session fluxdown-fixes run-code --filename scripts/verify-desktop-torrent-progress.js
```

10 个检查点：字节数、零字节文件、宽/紧凑窗口长文件名、25% 到 75% 刷新、静态进度未知、暂停停止轮询、错误后恢复、旧响应不能覆盖重开详情、关闭停止轮询。

本地截图为 `output/playwright/torrent-progress-wide.png`（1280×820 视口）和 `output/playwright/torrent-progress-compact.png`（980×680 视口），已人工查看文件名换行、进度条及无溢出。这些是隔离 UI 样例证据，位于忽略目录，不替换 README 的真实 App 截图。

## README 与代码差异

| 原文问题 | 当前代码事实 | 文档处理 |
| --- | --- | --- |
| 首页版本是 1.0.14，发布产物段仍写 1.0.10 | v1.0.14 Release 已存在；main 另有未发布改动 | 统一发布入口为 1.0.14，未发布修复独立标注。 |
| 未记录桌面更新、托盘、通知等能力 | `1.0.12`/`1.0.14` 已实现更新/窗口持久化和驻留功能 | 补齐，并限定为桌面能力。 |
| SHA-256 写成桌面独有 | Flutter 新建 UI、任务模型、完成校验已有实现 | 改为桌面、CLI、移动均有可选文件校验。 |
| 文档称扫码/剪切板尚未接回新建弹框 | 移动弹框标题栏已有入口 | 修正文档及路线图，不再重复列为待实现。 |
| 未区分 HLS/ETA/每任务限速的平台 | 增强项主要在桌面/core | 明确移动端仍有独立下载实现和配置面。 |
| 声称统一任务 schema/移动 FFI 完成 | 仅有 Rust 模型投影，Flutter 仍用独立本地队列；原有 FFI 还有本次修复的问题 | 修正架构/任务模型文档，保留完整引擎迁移为待办。 |
| Torrent 分文件进度被写成已展示 | 已发布源码仅后端提供数据 | 标明本次未发布前端修复及验证范围。 |
| 截图和旧真机结果像是当前版本 | macOS 图来自 08-04 至 08-06；Android 较新图来自 08-20 的 1.0.10 | 标注日期/版本，替换 Android 引用，避免用旧图证明新功能。 |
| 中文 README 重复副本易过期 | `README.zh-CN.md` 与默认中文 README 内容重复 | 保留入口文件，跳转到根 README 统一维护。 |

## 未完成边界

- [远端运行 34037218884](https://github.com/lonnnnnng/fluxdown/actions/runs/34037218884) 仍为历史失败：iOS job 失败，其余平台构建通过，Release job 跳过。本次只修复并本地验证，必须等下一次明确打包/发版再验证 CI 的 Xcode/SDK 环境。
- 本次没有重跑 Android/iOS 真机或原生 macOS/Windows/Linux 的完整协议下载，不把历史报告当成当前版本全量验收。
- iPhone 签名、扫码/目录/分享/打开能力和 Linux 原生 GUI 下载仍待验证。
- 移动端真实下载仍由 Dart/移动原生适配器执行；完整 Rust 引擎迁移及跨端队列转换仍待完成。
- 桌面非活动 Torrent 静态详情无法推断分文件真实完成量；GUI 中的 metadata 多文件选择完整前台流程仍需要单独补证据。

历史协议记录见 [下载验证状态](download-verification.md)，当前建设项见 [路线图](roadmap.md)。
