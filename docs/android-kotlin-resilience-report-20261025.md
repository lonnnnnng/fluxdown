# Kotlin Android 韧性验证报告（2026-10-25）

## 1. 环境

| 项目 | 值 |
| --- | --- |
| 设备 | Redmi Note 8 Pro（API 36） |
| 序列号 | wsvwypiz7xwslvl7 |
| 应用包名 | dev.fluxdown.mobile.kotlin |
| 应用版本 | 1.0.28-kotlin-alpha.8 |
| 测试载荷 | 50331648 字节，SHA-256 `96290698a8335ed71b14d0f0fcd6597ba432243072f177566df84ce0fc2f725f` |
| 回环总带宽 | 2048 KiB/s |
| 采集时间 | 2026-10-25 11:34:55 +0800 |

## 2. 结论

| 场景 | 结果 | 关键证据 |
| --- | --- | --- |
| 进程被杀后恢复 | 通过 | 任务恢复为 paused + error_code=interrupted；被杀前已下载 4521931 字节；服务端观测到 1 次非 0 偏移 Range 续传；续传完成后文件大小与 SHA-256 均与源一致 |
| 设备 idle 长时下载 | 通过 | force-idle 生效=yes；前台服务在 idle 窗口内把整个载荷下完（收尾日志命中 1 次），摘要与源一致 |
| 真实 ENOSPC | 通过 | 1 MiB HFS+ 卷 + 8 MiB 载荷，CLI 退出码 1，错误文案命中「磁盘空间不足」 |

## 3. 复跑方式

```bash
scripts/verify-android-kotlin-resilience.sh
```

## 4. 已知边界

- 设备侧没有 root，无法让 /data 真正写满；ENOSPC 用 macOS 1 MiB 磁盘镜像验证同一条 Rust 下载路径，错误码映射另有 Rust 单测（`ErrorKind::StorageFull` → `disk_full`）。
- 多连接下载（threadCount > 1）中断后不续传，会整份重下；只有单连接写最终文件才有 Range 续传语义，脚本统一用 threadCount=1。
- 进程被杀由 `am force-stop` 制造，等价于用户或系统停止应用；LMK 回收后 START_STICKY 重建服务走同一条 recover 路径。
- 队列文件在应用内部存储（Rust 进程写不到外置存储私有目录），宿主只能读应用镜像出来的 `progress.json`。
