# Rust JNI 导出入口通过名称解析，不能被 R8 移除。
-keep class dev.fluxdown.android.core.RustCoreBridge { *; }
