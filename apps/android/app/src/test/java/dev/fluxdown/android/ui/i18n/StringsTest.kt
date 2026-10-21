package dev.fluxdown.android.ui.i18n

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 作者: long
 * S4 语言切换的文案资源守卫：
 * 1) 每条文案都必须有中文，英文允许为空（仅限纯单位后缀，如“个”）；
 * 2) 中英文的占位符必须完全一致，否则 String.format 会在英文下抛异常；
 * 3) key 不允许重复，避免切换语言时互相覆盖。
 */
class StringsTest {

    private val placeholders = Regex("""%(\d+)\$[sd]""")

    @Test
    fun everyEntryHasChineseText() {
        Str.entries.forEach { key ->
            assertTrue("${key.name} 缺少中文文案", key.zh.isNotBlank())
        }
    }

    @Test
    fun englishTextIsPresentUnlessPureSuffix() {
        // “个”这类中文量词在英文里没有对应后缀，允许为空。
        val suffixOnly = setOf(Str.UnitCount)
        Str.entries.forEach { key ->
            if (key in suffixOnly) return@forEach
            assertTrue("${key.name} 缺少英文文案", key.en.isNotBlank())
        }
    }

    @Test
    fun placeholdersMatchBetweenLanguages() {
        Str.entries.forEach { key ->
            assertEquals(
                "${key.name} 中英文占位符不一致",
                placeholders.findAll(key.zh).map { it.groupValues[1] }.toSortedSet(),
                placeholders.findAll(key.en).map { it.groupValues[1] }.toSortedSet(),
            )
        }
    }

    @Test
    fun keysAreUnique() {
        val names = Str.entries.map { it.name }
        assertEquals(names.size, names.toSet().size)
    }

    @Test
    fun languageSelectionFallsBackToChinese() {
        assertEquals(Str.TabTasks.zh, Str.TabTasks.text("zh"))
        assertEquals(Str.TabTasks.en, Str.TabTasks.text("en"))
        // 未知语言（例如历史遗留值）一律回落中文，避免界面出现空文案。
        assertEquals(Str.TabTasks.zh, Str.TabTasks.text("fr"))
    }

    @Test
    fun trInFormatsArguments() {
        assertEquals(
            String.format(Str.CompletedTasksCount.zh, 3),
            trIn("zh", Str.CompletedTasksCount, 3),
        )
        assertEquals(
            String.format(Str.CompletedTasksCount.en, 3),
            trIn("en", Str.CompletedTasksCount, 3),
        )
    }
}
