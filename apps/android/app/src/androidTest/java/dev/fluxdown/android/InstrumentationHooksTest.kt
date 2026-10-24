package dev.fluxdown.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.fluxdown.android.platform.InstrumentationHooks
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * 作者: long
 *
 * releaseTest 会对目标 APK 执行完整 R8，instrumentation APK 却按原始全限定名引用被测类；
 * 一旦缺少 `apps/android/app/release-test-proguard-rules.pro` 里的 keep 规则，相关测试会以
 * `NoClassDefFoundError` 的形式失败，而堆栈只指向测试代码，看不出是保留规则的问题。
 *
 * 这里先按 [InstrumentationHooks.requiredClassName] 单点断言三个类名都能解析，让回归时
 * 第一眼就能定位到「保留规则被删了」，而不是逐个猜测十几个用例的失败原因。
 */
@RunWith(AndroidJUnit4::class)
class InstrumentationHooksTest {
    @Test
    fun releaseTestKeepsClassNamesUsedByInstrumentation() {
        val required = InstrumentationHooks.requiredClassName()
        val missing = required.filterNot { name ->
            runCatching { Class.forName(name, false, javaClass.classLoader) }.isSuccess
        }
        assertTrue(
            "instrumentation 依赖的类在目标 APK 中不可见（通常是 release-test-proguard-rules.pro 的 keep 规则被删）：$missing",
            missing.isEmpty(),
        )
    }
}
