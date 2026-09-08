# FluxDown 任务模型与 FFI（v1）

本文记录当前 Rust serde 任务格式、FFI 接口以及 Flutter 模型的对应关系，依据
`crates/fluxdown-core/src/task.rs`、`crates/fluxdown-ffi/src/lib.rs` 和移动端源码。
Rust core、CLI、桌面 GUI 共用同一模型；Flutter 本地队列仍使用独立的 camelCase JSON。
FFI 的字段投影不等于跨端队列已经统一，当前没有自动导入/导出转换器或跨设备同步。

## 任务对象（DownloadTask）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | Rust 任务 ID，格式 `task-<uuid>` |
| `source` | string | 原始下载源可能含凭据；CLI/桌面展示边界负责脱敏，存储并非脱敏副本 |
| `protocol` | string | `http`/`https`/`webdav`/`webdavs`/`ftp`/`ftps`/`m3u8`/`sftp`/`smb`/`torrent`/`magnet`/`ed2k`/`unknown` |
| `support` | object | `SupportStatus`：`protocol`/`backend`/`executable`；不含运行态的 `configured`/`missing_command`/`note` |
| `state` | string | Rust：`queued`/`running`/`finished`/`failed`/`paused`；Flutter 独有的 `handedOff` 不能映射成内建下载完成 |
| `output_dir` | string | 保存目录 |
| `file_name` | string \| null | 另存文件名（规范化为单文件名） |
| `expected_sha256` | string \| null | 64 位小写十六进制；下载完成后按此校验产物 |
| `torrent_file_indices` | number[] | 多文件种子的选择下标（排序去重）；空数组=全部 |
| `speed_limit_mbps` | number \| null | 每任务限速；缺省/null=跟随全局；有限正数才生效。历史字段名含 `mbps`，当前实际按值 × 1024² 字节/秒执行，不是兆比特/秒 |
| `hls_variant_index` | number \| null | HLS master 的清晰度下标；null=第一个 variant |
| `hls_keep_transport_stream` | bool | true=保留 TS 原始流，跳过转封装 |
| `total_bytes` | number \| null | 已知总字节数 |
| `downloaded_bytes` | number | 已完成字节数 |
| `current_speed_bytes_per_second` | number | 实时速率采样（B/s） |
| `error` | string \| null | 最近一次失败原因；展示时脱敏，不保证原始存储已脱敏 |
| `created_at_ms` / `updated_at_ms` | number | Unix 毫秒时间戳 |
| `started_at_ms` / `finished_at_ms` | number \| null | 未开始/未结束时为 null |

## 任务请求对象（DownloadRequest）

Rust 请求包含 `source`、`output_dir`、可选 `file_name`、`expected_sha256`、
`torrent_file_indices`、`speed_limit_mbps`、`hls_variant_index`、`hls_keep_transport_stream`。
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
| `expectedSha256` | 否 | 校验格式后保存期望 hash |
| `torrentFileIndices` | 否 | 无符号文件编号列表，核心排序去重；空列表代表全部 |
| `speedLimitMbps` | 否 | 对应 `speed_limit_mbps`，同样按字节速率换算 |

FFI 当前不读取 HLS variant/TS 选项。未知字段被忽略，不能把 Rust 请求的所有选项都视为已透传。

### 返回值与执行边界

- `fluxdown_ffi_abi()` 返回整数 `1`，`fluxdown_version()` 返回版本字符串。
- 协议与队列接口返回 UTF-8 JSON 信封：成功为 `{"ok":true,"data":...}`，失败包含 `ok:false` 与 `error`。Dart 先 JSON 解码、再解包一次，不重复读取 `data`。
- `detect` 的 `data` 包含 `protocol` 与运行态 `support`；`support` 返回运行态支持对象；`queue_list` 的 `data` 是 Rust 任务数组，`queue_add` 是单个任务。
- Rust 返回的字符串用 `fluxdown_string_free` 释放；Dart 分配的入参由 Dart 释放，避免高频识别/轮询泄漏。
- `fluxdown_queue_run(store_path, task_id)` 同步等待单任务结束，返回 `TaskRunReport`，并非进度订阅；运行时持有 FFI 队列锁。当前没有通过该接口公开暂停/取消、全局并发/线程数/重试配置。
- Flutter 产品目前只使用 FFI 协议识别，原生队列测试独立于移动队列。未来接入必须设计非阻塞执行、进度、取消和模型转换，不能直接在 UI isolate 调用 `queueRun`。

## 移动端（Flutter）映射

| Rust 字段 | 移动端 `DownloadTask` | 当前关系，不代表自动转换 |
| --- | --- | --- |
| `id` | `id` | 一致 |
| `source` | `source` | 一致 |
| `protocol` | `protocol`（string） | 移动端直接存字符串 |
| `state` | `state.name` | `handedOff` 是移动端独立状态，仅表示外部 App 已接受移交，不是 `finished` |
| `output_dir` | `outputFolder` | 命名差异，映射时转换 |
| `file_name` | `fileName` | 命名差异 |
| `expected_sha256` | `expectedSha256` | 命名差异 |
| `total_bytes` / `downloaded_bytes` | `totalBytes` / `downloadedBytes` | 命名差异 |
| `current_speed_bytes_per_second` | `currentSpeedBytesPerSecond` | 命名差异 |
| `created_at_ms` 等 | `createdAt` 等 `DateTime` | 移动端以 ISO-8601 字符串存储；当前没有与 Rust 毫秒时间戳互转的队列导入/导出流程 |
| 无 | `pausedAt` | 移动端专属暂停时间 |
| 无直接同构对象 | `torrentName` / `torrentFiles` / `selectedTorrentFileIndexes` | 移动端保存 metadata/选择信息；Rust 用选择编号及独立会话快照 |

`lib/src/ffi/fluxdown_ffi.dart` 的 `FluxDownCoreTask` 从 snake_case JSON 投影
`id`、`source`、`protocol`、`state`、`file_name`、`output_dir`、`expected_sha256`、
`total_bytes`、`downloaded_bytes`。它不是完整 Rust 任务，也不是移动端 `DownloadTask` 的替代物。

Rust 队列文件为 `{"tasks":[...]}`，移动端队列文件为任务数组；不要直接覆盖或互换文件。

## 后续演进约束

1. 新增持久化字段应提供默认值，并用旧队列样例做向后兼容测试。
2. 状态扩展要同时明确各端读取行为，尤其不能把外部移交等同下载完成；当前没有统一未知状态降级策略。
3. 统一队列格式之前必须补转换工具、设置透传与迁移测试。这里只记录建设方向，不宣称已实现导入导出。
