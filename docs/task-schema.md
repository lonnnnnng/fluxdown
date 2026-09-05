# FluxDown 统一任务 Schema（v1）

桌面端（Rust `crates/fluxdown-core` serde 输出）与移动端共享同一套任务模型语义。
本文档是**唯一权威定义**：桌面端 serde 字段即规范本体，移动端通过映射层对齐；
跨进程/跨语言边界（FFI、命令行 JSON、导入导出）一律使用本 schema。

## 任务对象（DownloadTask）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | string | 任务 ID，格式 `task-<uuid>`；跨端同步时保留 |
| `source` | string | 原始下载源（含凭据）；展示层用 `redactedForDisplay` 输出脱敏版本 |
| `protocol` | string | `http`/`https`/`webdav`/`webdavs`/`ftp`/`ftps`/`m3u8`/`sftp`/`smb`/`torrent`/`magnet`/`ed2k`/`unknown` |
| `support` | object | 协议运行时支持状态（`backend`/`executable`/`missing_command`/`note`） |
| `state` | string | kebab-case：`queued`/`running`/`finished`/`failed`/`paused`；移动端额外有 `handed-off`（移交外部客户端），导出为 `finished` 时须附 `handedOff` 标记 |
| `output_dir` | string | 保存目录 |
| `file_name` | string \| null | 另存文件名（规范化为单文件名） |
| `expected_sha256` | string \| null | 64 位小写十六进制；下载完成后按此校验产物 |
| `torrent_file_indices` | number[] | 多文件种子的选择下标（排序去重）；空数组=全部 |
| `speed_limit_mbps` | number \| null | 每任务限速；null=跟随全局；>0 才生效 |
| `hls_variant_index` | number \| null | HLS master 的清晰度下标；null=第一个 variant |
| `hls_keep_transport_stream` | bool | true=保留 TS 原始流，跳过转封装 |
| `total_bytes` | number \| null | 已知总字节数 |
| `downloaded_bytes` | number | 已完成字节数 |
| `current_speed_bytes_per_second` | number | 实时速率采样（B/s） |
| `error` | string \| null | 最近一次失败原因（已脱敏） |
| `created_at_ms` / `updated_at_ms` / `started_at_ms` / `finished_at_ms` | number \| null | Unix 毫秒时间戳 |

## 任务请求对象（DownloadRequest）

新建任务时只需要请求对象：`source`、`output_dir`、`file_name`、`expected_sha256`、
`torrent_file_indices`、`speed_limit_mbps`、`hls_variant_index`、`hls_keep_transport_stream`。
其余字段由核心生成。FFI 的 `fluxdown_queue_add` 接受 camelCase 别名
（`outputDir`/`fileName`/`expectedSha256`/`torrentFileIndices`/`speedLimitMbps`），
因为移动端 UI 层默认 camelCase。

## 移动端（Flutter）映射

| 统一 schema | 移动端 `DownloadTask` | 备注 |
| --- | --- | --- |
| `id` | `id` | 一致 |
| `source` | `source` | 一致 |
| `protocol` | `protocol`（string） | 移动端直接存字符串 |
| `state` | `state.name` | 移动端枚举名是 camelCase（`handedOff`），见上方说明 |
| `output_dir` | `outputFolder` | 命名差异，映射时转换 |
| `file_name` | `fileName` | 命名差异 |
| `expected_sha256` | `expectedSha256` | 命名差异 |
| `total_bytes` / `downloaded_bytes` | `totalBytes` / `downloadedBytes` | 命名差异 |
| `current_speed_bytes_per_second` | `currentSpeedBytesPerSecond` | 命名差异 |
| `created_at_ms` 等 | `createdAt` 等 `DateTime`（ISO-8601 UTC） | 移动端本地存储用 ISO 字符串，导出/导入时换算为毫秒 |
| — | `pausedAt` | 移动端专属（精确暂停时间），桌面端无对应字段，导入时忽略 |
| — | `torrentName` / `torrentFiles` / `selectedTorrentFileIndexes` | 移动端运行时元数据缓存，导出时按需携带 |

`lib/src/ffi/fluxdown_ffi.dart` 的 `FluxDownCoreTask` 是统一 schema 的最小投影，
字段直接使用 Rust serde 原名（snake_case），后续移动端 FFI 化以此为准。

## 演进规则

1. 只增不删：新增字段必须带默认值，旧持久化数据无需迁移。
2. 枚举值新增时，旧客户端应把未知值降级为 `failed`（带原始值进 error）。
3. 大版本 schema 变更（v2）需要提供导入导出转换工具后再发布。
