# FluxDown 任务模型与 FFI（v2）

本文记录当前 Rust serde 任务格式、FFI 接口以及 Flutter 模型的对应关系，依据
`crates/fluxdown-core/src/task.rs`、`crates/fluxdown-ffi/src/lib.rs` 和移动端源码。
Rust core、CLI、桌面 GUI 共用同一模型；移动端 native 可用时以 Rust `rust-queue.json` 作为活动任务的
canonical 文件，Flutter `queue.json` 只保存 `handedOff` 等移动端专属投影。旧版双队列会在首次启动时
按任务时间戳合并，迁移事务失败会恢复原始快照；普通 HTTP、HLS 和已经完成 metadata 选择的 Torrent/Magnet 会进入 Rust 下载引擎，metadata 获取、文件选择和 ed2k 外部移交仍保留在移动端适配层。

## 队列文件版本

Rust canonical 队列使用版本 `2`，Flutter 专属投影仍使用版本 `1`：

- Rust/CLI/桌面：`{"schema_version":2,"tasks":[...],"deleted_task_ids":{}}`；v1 缺失 tombstone 字段时兼容读取。
- Flutter：`{"schemaVersion":1,"tasks":[...],"deletedTaskIds":{}}`；native 可用时任务数组只包含移动端专属投影，旧版 JSON 数组仍兼容读取。
- 读取到高于当前版本的文件会明确失败并保留原文件，未知任务状态会跳过而不是降级成 `queued`。

## 任务对象（DownloadTask）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | Rust 任务 ID，格式 `task-<uuid>` |
| `source` | string | 原始下载源可能含凭据；CLI/桌面展示边界负责脱敏，存储并非脱敏副本 |
| `protocol` | string | `http`/`https`/`webdav`/`webdavs`/`ftp`/`ftps`/`m3u8`/`sftp`/`smb`/`torrent`/`magnet`/`ed2k`/`unknown` |
| `support` | object | `SupportStatus`：`protocol`/`backend`/`executable`；不含运行态的 `configured`/`missing_command`/`note` |
| `state` | string | Rust：`queued`/`running`/`finished`/`failed`/`paused`/`handed-off`；Flutter 使用 `handedOff`。移交态只表示外部客户端已接收链接，不能映射成内建下载完成 |
| `output_dir` | string | 保存目录 |
| `file_name` | string \| null | 另存文件名（规范化为单文件名） |
| `credential_ref` | string \| null | 系统凭据库引用名；只保存引用，不保存用户名、密码或私钥。桌面端/CLI 使用系统凭据库，移动端从 Keystore/Keychain 读取密码或 SFTP 私钥 |
| `expected_sha256` | string \| null | 64 位小写十六进制；下载完成后按此校验产物 |
| `torrent_file_indices` | number[] | 多文件种子的选择下标（排序去重）；空数组=全部 |
| `torrent_name` | string \| null | metadata 中的资源目录名；旧任务缺失时为空 |
| `torrent_files` | object[] | 用户确认时保存的完整文件元数据；字段为 `index`/`path`/`name`/`size`/`is_streamable`，旧任务缺失时为空数组 |
| `speed_limit_mbps` | number \| null | 每任务限速，界面单位为 MB/s（字节）；缺省/null=跟随全局；有限正数才生效。字段名中的 `mbps` 是历史兼容命名，当前按值 × 1024² 字节/秒执行，不是兆比特/秒 |
| `hls_variant_index` | number \| null | HLS master 的清晰度下标；null=第一个 variant |
| `hls_keep_transport_stream` | bool | true=保留 TS 原始流，跳过转封装 |
| `total_bytes` | number \| null | 已知总字节数 |
| `downloaded_bytes` | number | 已完成字节数 |
| `current_speed_bytes_per_second` | number | 实时速率采样（B/s） |
| `error` | string \| null | 最近一次失败原因；展示时脱敏，不保证原始存储已脱敏 |
| `created_at_ms` / `updated_at_ms` | number | Unix 毫秒时间戳 |
| `started_at_ms` / `finished_at_ms` | number \| null | 未开始/未结束时为 null |
| `handoff_backend` | string \| null | `amule` 或 `system-handoff` 等外部后端；仅在 `handed-off` 时保存 |
| `handed_off_at_ms` | number \| null | 外部客户端接收链接的 Unix 毫秒时间戳；不等同于文件完成时间 |

## 任务请求对象（DownloadRequest）

Rust 请求包含 `source`、`output_dir`、可选 `file_name`、`credential_ref`、`expected_sha256`、
`torrent_file_indices`、`torrent_name`、`torrent_files`、`speed_limit_mbps`、
`hls_variant_index`、`hls_keep_transport_stream`。
`task_id` 用于运行器关联活动会话，不是新建任务必填项。请求中的
`hls_keep_transport_stream` 为可选布尔值，落入任务时缺省为 false。

### FFI 入队请求

`fluxdown_queue_add(store_path, request_json)` 并非直接反序列化 Rust `DownloadRequest`。
当前只读取以下字段，字段名必须准确匹配，不能把 snake_case 当成兼容别名：

| FFI 字段 | 必填 | 行为 |
| --- | --- | --- |
| `source` | 是 | 下载源字符串 |
| `outputDir` | 否 | 缺省使用核心默认队列目录；产品接入时应显式传入可写下载目录 |
| `fileName` | 否 | 未指定时按链接推断文件名 |
| `credentialRef` | 否 | 系统凭据库引用名；只保存引用，不接受密码、私钥或口令内容 |
| `expectedSha256` | 否 | 校验格式后保存期望 hash |
| `torrentFileIndices` | 否 | 无符号文件编号列表，核心排序去重；空列表代表全部 |
| `torrentName` | 否 | metadata 资源目录名；为空时不覆盖链接推断名称 |
| `torrentFiles` | 否 | 完整文件元数据数组，核心按索引排序去重；每项包含 `index`、`path`、`name`、`size`、`is_streamable` |
| `speedLimitMbps` | 否 | 对应 `speed_limit_mbps`，输入单位为 MB/s（字节）；同样按值 × 1024² 换算为字节/秒 |
| `hlsVariantIndex` | 否 | HLS master playlist 的 zero-based variant 编号；缺省使用第一个 |
| `hlsKeepTransportStream` | 否 | 为 true 时保留 HLS TS 原始流，不尝试转封装为 MP4 |

当前 FFI 队列接口会读取并映射 Torrent metadata、`hlsVariantIndex` 与 `hlsKeepTransportStream`；移动端下载器同时通过自己的 camelCase 队列字段执行这些选项。移动正式入口在 native 库可用时优先将 HTTP/HTTPS/WebDAV(S)/HLS，以及已经完成 metadata 选择的 Torrent/Magnet 交给 Rust 队列；metadata 获取、文件选择和 ed2k 外部移交仍由 Dart/原生适配器执行。库缺失、私钥凭据或初始化失败时自动回退 Dart。

`fluxdown_queue_upsert(store_path, task_json)` 用于移动端迁移已有任务。它同时接受 camelCase 与 Rust snake_case 字段，按 `taskId`/`id` 幂等插入或更新任务，并保留状态、进度、错误、时间戳、Torrent 文件树、限速、HLS 选项和移交字段。`handedOff` 可以被结构化导入为 Rust 的 `handed-off` 终态，但运行器不会把它当作内建下载完成；移动端仍把外部移交投影保存在 Flutter 侧，避免 native 回写覆盖移交语义。

### 返回值与执行边界

- `fluxdown_ffi_abi()` 返回整数 `1`，`fluxdown_version()` 返回版本字符串。
- 协议与队列接口返回 UTF-8 JSON 信封：成功为 `{"ok":true,"data":...}`，失败包含 `ok:false` 与 `error`。Dart 先 JSON 解码、再解包一次，不重复读取 `data`。
- `detect` 的 `data` 包含 `protocol` 与运行态 `support`；`support` 返回运行态支持对象；`queue_list` 的 `data` 是 Rust 任务数组，`queue_add` 是单个任务。
- Rust 返回的字符串用 `fluxdown_string_free` 释放；Dart 分配的入参由 Dart 释放，避免高频识别/轮询泄漏。
- `fluxdown_queue_run(store_path, task_id)` 保留为同步兼容接口；`fluxdown_queue_run_async` 使用默认设置返回单任务运行句柄，`fluxdown_queue_run_with_options_async(store_path, task_id, options_json)` 按移动端设置启动单任务，`fluxdown_queue_run_queued_async(store_path, options_json)` 按队列设置异步调度全部 queued 任务。`fluxdown_queue_run_status` 查询完成/失败结果，任务实时进度继续从 `fluxdown_queue_list` 读取。
- `fluxdown_queue_upsert(store_path, task_json)` 按任务 ID 幂等导入移动端任务；只用于迁移，不改变普通 `queue_add` 的新建语义。
- `options_json` 支持 `concurrency`（1-30）、`threadCount`（1-32）、`retryAttempts`（0-10）和 `speedLimitKbps`（KiB/s 字节限速，0/缺省不限速），边界由 Rust 核心统一收敛。
- `fluxdown_queue_pause` / `fluxdown_queue_resume` 通过任务状态控制运行器，`fluxdown_queue_reset` 清理断点并重新进入 `queued`，`fluxdown_queue_remove` 删除 native 任务，`fluxdown_queue_run_forget` 回收完成句柄。异步运行不持有 FFI 全局锁，暂停请求可以在下载期间落盘。
- 同一个 Rust 队列文件同时只允许一个 `fluxdown_queue_run_queued_async` 调度句柄，避免两个调用方重复启动同一批 queued 任务；单任务句柄仍由核心状态机防止 running 任务重复执行。
- `RustQueueBackend` 已接入移动正式入口的 HTTP/HTTPS/WebDAV(S)/HLS，以及已完成 metadata 选择的 Torrent/Magnet，按任务 ID、完整任务字段、进度、速度、错误和 Rust 毫秒时间戳回写 Flutter；已覆盖幂等 upsert、单任务 start/pause/resume/reset/remove、队列运行和初始化/入队失败回退 Dart。Torrent/Magnet 的 metadata 选择仍由 Dart/libtorrent 负责；ed2k 的 `handedOff` 由移动原生适配器维护。

## 移动端（Flutter）映射

| Rust 字段 | 移动端 `DownloadTask` | 当前关系，不代表自动转换 |
| --- | --- | --- |
| `id` | `id` | 一致 |
| `source` | `source` | 一致 |
| `protocol` | `protocol`（string） | 移动端直接存字符串 |
| `state` | `state.name` | Rust `handed-off` 映射为 Flutter `handedOff`；仅表示外部 App 已接受移交，不是 `finished` |
| `output_dir` | `outputFolder` | 命名差异，映射时转换 |
| `file_name` | `fileName` | 命名差异 |
| `credential_ref` | `credentialRef` | 桌面/CLI 运行时从系统凭据库解析；移动端从 Keystore/Keychain 读取。密码凭据通过本次 Rust FFI 运行参数临时注入，私钥凭据仍在 Dart SFTP 握手期间使用，任务 JSON 只保存引用 |
| `expected_sha256` | `expectedSha256` | 命名差异 |
| `total_bytes` / `downloaded_bytes` | `totalBytes` / `downloadedBytes` | 命名差异 |
| `current_speed_bytes_per_second` | `currentSpeedBytesPerSecond` | 命名差异 |
| `hls_variant_index` | `hlsVariantIndex` | 移动端新建任务可选，null 使用第一个 master variant |
| `hls_keep_transport_stream` | `hlsKeepTransportStream` | 移动端新建任务可选，默认 false；true 时保留 TS |
| `created_at_ms` 等 | `createdAt` 等 `DateTime` | Rust FFI 投影会将毫秒字段转为 UTC `DateTime`；移动端持久化仍使用 ISO-8601，迁移通过任务级 upsert 完成 |
| 无 | `pausedAt` | 移动端专属暂停时间 |
| `torrent_name` / `torrent_files` | `torrentName` / `torrentFiles` | 桌面与移动端均保存 metadata 目录名和完整文件描述；选择结果仍由 `torrent_file_indices` / `selectedTorrentFileIndexes` 保存 |
| `torrent_file_indices` | `selectedTorrentFileIndexes` | 命名差异，均为用户确认的文件索引；空值/空数组沿用“全部”兼容语义 |
| `handoff_backend` | `handoffBackend` | 命名差异；外部移交后端显示信息 |
| `handed_off_at_ms` | `handedOffAt` | Rust 毫秒时间戳转换为 UTC `DateTime`；不作为完成时间使用 |

`lib/src/ffi/fluxdown_ffi.dart` 的 `FluxDownCoreTask` 从 snake_case JSON 投影完整的
任务字段，包括 `support`、文件名/目录、SHA-256、Torrent metadata/选择下标、限速、HLS 选项、
进度、错误和 Rust 毫秒时间戳。它仍是 FFI 返回的只读投影，不是移动端 `DownloadTask` 的替代物。

Rust canonical 队列文件为 `{"schema_version":2,"tasks":[...],"deleted_task_ids":{"task-id":<deletedAtMs>}}`，移动端专属投影文件为
`{"schemaVersion":1,"tasks":[...],"deletedTaskIds":{}}`；不要直接覆盖或互换文件。移动端仍兼容读取旧数组和 Rust v1。

旧版双队列首次收敛时，`TaskStore` 会在 Flutter 队列同级创建 `.queue-migration/`：

- `manifest.json` 的 `prepared` 表示快照已完整写入、迁移尚未提交；App 启动发现该状态会先恢复两份原文件。
- `committed` 表示本轮同步已完成；`recovered` 表示已回滚，不会再次覆盖后续新写入。
- 快照覆盖 Flutter `queue.json` 和 Rust `rust-queue.json` 的存在性与原始字节；迁移失败时会恢复缺失文件状态，避免新建的半套队列复活已删除任务。
- Flutter `queue.json` 的原子写入使用同级长期存在的 `queue.json.lock` 旁路锁；Rust 队列沿用 `rust-queue.json.lock`，两侧均在替换 JSON 前取得独占系统锁，避免跨进程写入产生半套或互相覆盖的快照。
- 合并按任务 ID 和 `updatedAt` 选择较新记录；时间相同则保留更大已下载量或完成态，`handedOff` 永远保留在 Flutter 投影。迁移提交后 Rust 文件成为活动任务唯一来源。
- Flutter 删除支持 Rust 的任务会调用 native remove 并在 `deleted_task_ids` 写入 tombstone；迟到的 upsert 只有时间戳晚于 tombstone 才能复用 ID。移动专属 `handedOff` 仍由 Flutter 投影直接覆盖保存。

## 后续演进约束

1. 新增持久化字段应提供默认值，并用旧队列样例做向后兼容测试。当前 Torrent metadata 字段均为可选，旧队列读取后为空，不影响 HTTP 等普通任务。
2. 状态扩展要同时明确各端读取行为，尤其不能把外部移交等同下载完成；未知状态必须保留 canonical 文件并等待支持它的版本。
3. 当前已补任务级转换、设置透传、幂等 upsert、native 孤儿任务导入、canonical schema v2、未来版本保护、迁移备份/恢复、启动冲突合并和 Rust tombstone；后续只需为新增字段补兼容样例。
