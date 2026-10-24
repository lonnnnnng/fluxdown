package dev.fluxdown.android.platform

import androidx.core.content.ContextCompat
import dev.fluxdown.android.AndroidHlsRemuxer
import com.google.mlkit.vision.barcode.BarcodeScannerOptions

/**
 * 作者: long
 * instrumentation 覆盖的类名锚点。
 *
 * releaseTest 会对目标 APK 执行完整 R8（`isMinifyEnabled` + `isShrinkResources`），
 * 而测试 APK 独立编译、仍按原始全限定名引用被测类。只把这些类写在测试侧时，R8 看不到
 * 任何保留代码引用它们，会直接记成 `R8$$REMOVED$$CLASS$$N`：
 *
 * - `AndroidHlsRemuxer`：唯一调用方 `HlsRemuxCoordinator` 自身也被裁剪，整条链消失；
 * - `BarcodeScannerOptions$Builder`：只在仪器测试里构造；
 * - `ContextCompat`：主源码只在 `QueueServiceController`/扫码弹窗里调用，releaseTest 中被内联。
 *
 * 这里用 `::class.java.name` 做真实引用，Kotlin 会把类名写进本类常量池，R8 因此保留原名。
 * 已验证 `AndroidHlsRemuxer::class.java.name` / `ContextCompat::class.java.name` 会落进
 * `InstrumentationHooks.class` 常量池，而不是随无状态 object 静态化消失。
 */
internal object InstrumentationHooks {
    /** 返回 releaseTest 必须按原名保留的类名清单，供 instrumentation 断言实际可见性。 */
    fun requiredClassName(): List<String> = listOf(
        AndroidHlsRemuxer::class.java.name,
        BarcodeScannerOptions.Builder::class.java.name,
        ContextCompat::class.java.name,
    )
}
