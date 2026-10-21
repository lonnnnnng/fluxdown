package dev.fluxdown.android.data

import dev.fluxdown.android.core.RustCoreBridge

/**
 * 作者: long
 * 协议识别的唯一入口。UI 层不应直接调用 RustCoreBridge，否则后续换实现
 * （例如先本地正则预判再交给 Rust）会波及所有弹窗。
 */
internal object ProtocolDetector {
    /** 返回 http/https/ftp/sftp/smb/m3u8/ed2k/... 等协议标识，无法识别时返回 "unknown"。 */
    fun detect(source: String): String =
        parseDataString(RustCoreBridge.detect(source), "protocol") ?: "unknown"
}
