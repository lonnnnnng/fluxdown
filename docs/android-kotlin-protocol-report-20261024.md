# FluxDown Kotlin Android 协议真机验证报告（2026-10-24）

> 作者: long

本报告由 `scripts/verify-android-kotlin-protocols.sh` 一条命令生成：
起回环夹具 → `adb reverse` 映射到设备 → 用 Kotlin 端真实使用的 Rust 队列入口
（`RustCoreBridge.queueAdd` + `queueRunQueued`）跑完 12 类协议 → 采集队列终态与落盘 SHA-256。
报告里的每个数字都来自 `protocol-matrix-results.json`，不是手抄。

## 1. 环境

| 项 | 值 |
| --- | --- |
| 设备 | Redmi Note 8 Pro / API 36 |
| 设备型号 / 序列号 | `Redmi Note 8 Pro` / `` |
| 应用包名 | `dev.fluxdown.mobile.kotlin.releaseTest` |
| 构建变体 | `releaseTest` |
| 应用版本 | `1.0.28-kotlin-alpha.7` (versionCode `2034`) |
| APK SHA-256 | `1e7d7fa82151e7979060e72a865e2c593fe18369856c09011f1761bab1a50d79` |
| 采集时间 | 2026-10-24 11:40:13 |
| 夹具目录 | `/tmp/fluxdown-android-fixtures` |
| instrumentation 退出码 | `0` |
| 夹具端口 | ftp=2121, ftps=2990, http=9101, https=9443, peer=51413, sftp=2222, smb=1445, tracker=6969 |

### 1.1 被测产物与已发布 APK 的关系

`releaseTest` 是 `release` 的克隆（`initWith(release)`）：同一套 R8 混淆配置、额外只多测试专用 keep（`apps/android/app/release-test-proguard-rules.pro`），差异仅签名（debug）与包名后缀（`.releaseTest`）。因此本报告验证的是**混淆后的正式构建配置**，比未混淆的 debug 包更接近发布产物。

已发布的正式签名包不能直接跑 instrumentation：AGP 生成 androidTest APK 时会排除"被测 APK 已提供"的类，debug 版 test APK 里只有 `kotlin/jvm/internal/Intrinsics` 的引用而无定义；正式 release 包把 `kotlin.**` 重命名了（`-keep class kotlin.**` 只存在于 release-test 规则里），实测 `am instrument` 直接失败：

```
java.lang.NoClassDefFoundError: Failed resolution of: Lkotlin/jvm/internal/Intrinsics;
  at androidx.test.platform.app.AppComponentFactoryRegistry.instantiateApplication
  at androidx.test.runner.MonitoringInstrumentation.newApplication
```

重新打出 `1.0.28-kotlin-alpha.7` 的正式签名 APK（SHA-256 `fd99236c5093ba286223a207e291b4088bfee4d02c120bfb6e6f5a0614b174d1`）后已装机验证可启动；协议栈行为与变体无关（Rust 队列与 JNI 入口在两者中都是同一份代码、且都被 keep），差别只在 R8 的裁剪与签名。

## 2. 结论

- 内建协议 **11/11** 通过：队列终态 `finished`，落盘 SHA-256 与源文件一致。
- 无失败项。
- ed2k 无内建下载实现，按设计走"移交外部客户端"边界，单独记录。

## 3. 矩阵明细

| # | 协议 | 队列终态 | 落盘字节 | 落盘 SHA-256 | 期望 SHA-256 | 结果 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | HTTP | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 2 | HTTPS | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 3 | WebDAV | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 4 | WebDAVS | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 5 | FTP | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 6 | FTPS | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 7 | SFTP | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 8 | SMB | `finished` | 1.0 MB | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | `3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d` | ✅ 通过 |
| 9 | HLS | `finished` | 940.0 KB | `19de51c742cd52ca420df43423496917803baa5c65d04f4a006d66af193793a0` | `19de51c742cd52ca420df43423496917803baa5c65d04f4a006d66af193793a0` | ✅ 通过 |
| 10 | Torrent | `finished` | 2.0 MB | `d8a2d33d25bdd8a191584e86b7ed4eeefafd90aa7bd4f9ab8c529450a712eff0` | `d8a2d33d25bdd8a191584e86b7ed4eeefafd90aa7bd4f9ab8c529450a712eff0` | ✅ 通过 |
| 11 | Magnet | `finished` | 2.0 MB | `d8a2d33d25bdd8a191584e86b7ed4eeefafd90aa7bd4f9ab8c529450a712eff0` | `d8a2d33d25bdd8a191584e86b7ed4eeefafd90aa7bd4f9ab8c529450a712eff0` | ✅ 通过 |
| 12 | ed2k | `failed` | 0 B | - | - | 移交边界 |

## 4. 逐协议证据

### HTTP

- 资源 URL：`http://127.0.0.1:9101/http-1mb.bin`
- 夹具来源：scripts/range-http-server.py (Range 支持)
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/http/downloads`
- 产物文件：`http-1mb.bin`
- 错误信息：`null`

### HTTPS

- 资源 URL：`https://127.0.0.1:9443/http-1mb.bin?allowBadCertificate=true`
- 夹具来源：scripts/range-http-server.py --tls-cert（自签 127.0.0.1）
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/https/downloads`
- 产物文件：`http-1mb.bin`
- 错误信息：`null`

### WebDAV

- 资源 URL：`http://127.0.0.1:9101/dav/webdav-1mb.bin`
- 夹具来源：HTTP transport 映射（WebDAV 只做 GET）
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/webdav/downloads`
- 产物文件：`webdav-1mb.bin`
- 错误信息：`null`
- 边界说明：移动端把 WebDAV/WebDAVS 映射为 HTTP/HTTPS GET，本项验证的是 transport 层可下载性，不代表完整 WebDAV 方法（PROPFIND/LOCK/MOVE 等）已被验证。

### WebDAVS

- 资源 URL：`https://127.0.0.1:9443/dav/webdav-1mb.bin?allowBadCertificate=true`
- 夹具来源：HTTPS transport 映射（WebDAV 只做 GET）
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/webdavs/downloads`
- 产物文件：`webdav-1mb.bin`
- 错误信息：`null`
- 边界说明：移动端把 WebDAV/WebDAVS 映射为 HTTP/HTTPS GET，本项验证的是 transport 层可下载性，不代表完整 WebDAV 方法（PROPFIND/LOCK/MOVE 等）已被验证。

### FTP

- 资源 URL：`ftp://fluxdown:fluxdown@127.0.0.1:2121/ftp-1mb.bin`
- 夹具来源：scripts/fixtures/ftp_server.py (pyftpdlib)
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/ftp/downloads`
- 产物文件：`ftp-1mb.bin`
- 错误信息：`null`

### FTPS

- 资源 URL：`ftps://fluxdown:fluxdown@127.0.0.1:2990/ftp-1mb.bin?allowBadCertificate=true`
- 夹具来源：scripts/fixtures/ftp_server.py --tls-cert（显式 FTPS）
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/ftps/downloads`
- 产物文件：`ftp-1mb.bin`
- 错误信息：`null`

### SFTP

- 资源 URL：`sftp://fluxdown:fluxdown@127.0.0.1:2222/sftp-1mb.bin`
- 夹具来源：scripts/fixtures/sftp_server.py (paramiko)
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/sftp/downloads`
- 产物文件：`sftp-1mb.bin`
- 错误信息：`null`

### SMB

- 资源 URL：`smb://fluxdown:fluxdown@127.0.0.1:1445/SCRATCH/smb-1mb.bin`
- 夹具来源：impacket smbserver -smb2support
- 队列终态：`finished`
- 下载字节：1048576（落盘 1048576 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/smb/downloads`
- 产物文件：`smb-1mb.bin`
- 错误信息：`null`

### HLS

- 资源 URL：`http://127.0.0.1:9101/hls/index.m3u8`
- 夹具来源：scripts/range-http-server.py 静态 m3u8 + 5 个分片
- 队列终态：`finished`
- 下载字节：962560（落盘 962560 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/hls/downloads`
- 产物文件：`index.ts`
- 错误信息：`null`
- 边界说明：队列层产物为 TS 拼接文件；MP4 重封装由 Kotlin 端 `HlsRemuxCoordinator` 在任务完成后执行，SHA-256 因此对应分片拼接后的字节流。

### Torrent

- 资源 URL：`http://127.0.0.1:9101/torrent/fluxdown-fixture.torrent`
- 夹具来源：transmission-cli seeder + scripts/fixtures/tracker.py
- 队列终态：`finished`
- 下载字节：2097152（落盘 2097152 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/torrent/downloads`
- 产物文件：`torrent-2mb.bin`
- 错误信息：`null`
- 边界说明：seeder 为 `transmission-cli`，tracker 为 `scripts/fixtures/tracker.py`，两者都通过 `adb reverse` 暴露到设备回环地址。

### Magnet

- 资源 URL：`magnet:?xt=urn:btih:ee658cba89450e2b2ee016f0f9c5ca016fd644e1&dn=torrent-2mb.bin&tr=http%3A%2F%2F127.0.0.1%3A6969%2Fannounce`
- 夹具来源：transmission-cli seeder + scripts/fixtures/tracker.py
- 队列终态：`finished`
- 下载字节：2097152（落盘 2097152 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/magnet/downloads`
- 产物文件：`torrent-2mb.bin`
- 错误信息：`null`

### ed2k

- 资源 URL：`ed2k://|file|fluxdown-fixture.bin|1048576|31D6CFE0D16AE931B73C59D7E0C089C0|/`
- 夹具来源：无内建实现：记录移交外部客户端的边界
- 队列终态：`failed`
- 下载字节：0（落盘 0 字节）
- 输出目录：`/data/user/0/dev.fluxdown.mobile.kotlin.releaseTest/cache/protocol-matrix/ed2k/downloads`
- 错误信息：`无法移交给系统或外部应用，请确认已安装可处理该链接的应用。`
- 边界说明：Kotlin/Rust 侧无 ed2k 下载实现，按产品设计交由外部客户端处理，本轮只验证识别与移交路径。

## 5. 复跑方式

```bash
# 一条命令跑完整矩阵并重新生成本报告
ANDROID_SERIAL=<serial> scripts/verify-android-kotlin-protocols.sh

# 跑 R8 混淆后的 releaseTest 变体（正式构建配置，报告里的变体/APK 指纹随之变化）
scripts/verify-android-kotlin-protocols.sh --variant releaseTest

# 只起夹具（调试用）
scripts/android-kotlin-protocol-fixtures.sh up     # 起服务 + adb reverse + 生成 manifest
scripts/android-kotlin-protocol-fixtures.sh urls   # 查看当前夹具清单
scripts/android-kotlin-protocol-fixtures.sh down   # 停止并清理 adb reverse
```

夹具全部绑定在回环地址，再通过 `adb reverse` 逐端口映射到设备：
因此设备侧 URL 统一是 `127.0.0.1:<port>`，不依赖局域网、也不受本机防火墙与代理影响。

## 6. 已知边界

1. WebDAV/WebDAVS 为 transport 映射，不宣称完整 WebDAV 方法验证。
2. ed2k 无内建下载实现，只验证识别与移交。
3. HLS 队列产物为 TS；MP4 重封装是 Kotlin 端后处理步骤，另行验证。
4. Rust 核心返回的失败原因（例如"下载资源不存在或已失效"）不参与 i18n，属于语言切换的明确边界。
5. 夹具服务均为本地最小实现（pyftpdlib / paramiko / impacket / transmission / 自研 tracker），
   与真实 NAS、云盘行为存在差异，本报告只证明协议栈连通性与字节一致性。

## 7. 本轮新增依赖与体积影响

运行期新增仅一项，测试期依赖不进入产物：

| 依赖 | 范围 | 理由 | 体积影响 |
| --- | --- | --- | --- |
| `tracing-subscriber` 0.3（仅 `fmt` + `std`） | 运行期，`crates/fluxdown-android` | Android 侧 Rust 日志此前完全不可见，torrent 对端被丢弃这类问题只能靠猜；本轮的 `missing field 'm'` 根因就是靠它定位的 | debug arm64 `.so` 中 tracing 符号合计约 340 KB（未 strip）；release 经 strip/R8 后更小 |
| `robolectric` 4.14.1、`androidx.test.ext:junit` 1.3.0、`compose ui-test-junit4`/`ui-test-manifest` 1.7.5 | 仅 `testImplementation` / `debugImplementation` | Espresso 在 API 36 上 `Espresso.onIdle` 会抛 `NoSuchMethodException: InputManager.getInstance`（Android 12+ 已移除该 API），改用 Robolectric 在 JVM 跑 Compose 用例 | 不进入 APK |
