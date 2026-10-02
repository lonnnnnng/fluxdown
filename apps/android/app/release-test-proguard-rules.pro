# 作者: long
# instrumentation 从独立 APK 启动，但 AGP 会把与目标应用共享的 tracing 类留在目标 APK；
# releaseTest 必须保留该运行时入口，正式 Release 不承担测试工具链的保留成本。
-keep class androidx.tracing.Trace { *; }

# AndroidX Test 的 Kotlin 实现由测试 APK 以原始全限定名反射加载；目标包中的
# Kotlin 标准库必须保留类名，否则 R8 的重命名会让 runner 在 onCreate 阶段找不到 LazyKt。
-keep class kotlin.** { *; }
