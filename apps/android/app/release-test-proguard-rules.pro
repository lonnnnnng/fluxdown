# 作者: long
# instrumentation 从独立 APK 启动，但 AGP 会把与目标应用共享的 tracing 类留在目标 APK；
# releaseTest 必须保留该运行时入口，正式 Release 不承担测试工具链的保留成本。
-keep class androidx.tracing.Trace { *; }

# AndroidX Test 的 Kotlin 实现由测试 APK 以原始全限定名反射加载；目标包中的
# Kotlin 标准库必须保留类名，否则 R8 的重命名会让 runner 在 onCreate 阶段找不到 LazyKt。
-keep class kotlin.** { *; }

# 作者: long
# instrumentation APK 与目标 APK 分开编译：测试侧按原始全限定名引用被测类，而目标 APK 的
# R8 只保留「从应用入口可达」的类。以下三个类在 releaseTest 目标里没有可达调用链，会被记成
# R8$$REMOVED$$CLASS$$N 并从 dex 中彻底消失（不是改名），安装后 instrumentation 立刻抛
# NoClassDefFoundError。逐个说明：
#   - AndroidHlsRemuxer：唯一调用方 HlsRemuxCoordinator 自身也被裁掉，整条链消失；
#   - BarcodeScannerOptions/Builder：只有仪器测试会构造，应用路径不引用；
#   - ContextCompat：主源码只在 QueueServiceController/扫码弹窗内部调用，releaseTest 中被内联。
# 这些 keep 只作用于 releaseTest 变体，正式 Release 仍由 R8 按可达性正常裁剪。
-keep class dev.fluxdown.android.AndroidHlsRemuxer { *; }
-keep class androidx.core.content.ContextCompat { *; }

# 作者: long
# ML Kit 扫码链路的 API 表面必须整体保留原名：测试侧按原名引用 BarcodeScanning、
# BarcodeScannerOptions、Barcode 和 InputImage，而方法签名还会带上 BarcodeScanner、
# Task 等返回类型；只要其中任意一个被重命名，instrumentation APK 在解析签名时就抛
# NoClassDefFoundError。实现类（com.google.android.gms.internal.*）由保留的
# ComponentRegistrar 静态引用，跟着可达性保留并允许统一改名，不需要单独列出。
# 这些 keep 只作用于 releaseTest 变体，正式 Release 仍由 R8 正常裁剪和混淆。
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.tasks.** { *; }

# 本类用 ::class.java.name 把上述三个类名写进常量池，作为「instrumentation 依赖这些类名」
# 的单点声明；InstrumentationHooksTest 会断言三个名字都能解析，避免 keep 规则被误删后
# 又退回成一堆看不懂的 NoClassDefFoundError。
-keep class dev.fluxdown.android.platform.InstrumentationHooks { *; }
