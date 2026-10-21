package dev.fluxdown.android.ui

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.fluxdown.android.data.QueueTask
import dev.fluxdown.android.ui.queue.TaskPropertiesDialog
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * 作者: long
 * 属性面板的三态验收：运行中（耗时显示"进行中"）、已完成（真实耗时）、失败（错误信息）。
 * 字段全部来自 QueueTask 的时间戳，UI 不做任何推算；用 Robolectric 跑在 JVM 上，
 * 避开 Espresso 在 API 31+ 上反射 InputManager.getInstance() 的崩溃。
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class TaskPropertiesDialogTest {
    @get:Rule
    val composeRule = createComposeRule()

    private fun task(
        state: String,
        downloaded: Long,
        total: Long?,
        startedAtMs: Long?,
        finishedAtMs: Long?,
        error: String? = null,
        source: String = "https://example.com/demo.m3u8",
    ) = QueueTask(
        id = "props-1",
        name = "demo.m3u8",
        source = source,
        state = state,
        downloadedBytes = downloaded,
        totalBytes = total,
        speedBytesPerSecond = 0L,
        hlsSegmentsWritten = null,
        hlsSegmentsTotal = null,
        startedAtMs = startedAtMs,
        finishedAtMs = finishedAtMs,
        error = error,
        outputDir = "/data/user/0/dev.fluxdown.android/files/Downloads",
        torrentName = null,
        torrentFiles = emptyList(),
        torrentFileIndices = emptySet(),
        hlsVariantIndex = null,
        hlsKeepTransportStream = false,
        hlsRemuxedToMp4 = false,
        credentialRef = null,
    )

    private fun render(task: QueueTask) {
        composeRule.setContent {
            FluxDownKotlinTheme { TaskPropertiesDialog(task = task, onDismiss = {}) }
        }
    }

    @Test
    fun runningTaskShowsInProgressDuration() {
        render(
            task(
                state = "running",
                downloaded = 2L * 1024 * 1024,
                total = 4L * 1024 * 1024,
                startedAtMs = System.currentTimeMillis() - 30_000L,
                finishedAtMs = null,
            ),
        )
        composeRule.onNodeWithText("任务属性").assertExists()
        composeRule.onNodeWithText("下载中").assertExists()
        composeRule.onNodeWithText("进行中").assertExists()
        composeRule.onNodeWithText("HLS").assertExists()
    }

    @Test
    fun finishedTaskShowsRealElapsedTime() {
        render(
            task(
                state = "finished",
                downloaded = 4L * 1024 * 1024,
                total = 4L * 1024 * 1024,
                startedAtMs = 1_700_000_000_000L,
                finishedAtMs = 1_700_000_000_000L + 125_000L,
            ),
        )
        composeRule.onNodeWithText("已完成").assertExists()
        composeRule.onNodeWithText("2分5秒").assertExists()
    }

    @Test
    fun failedTaskShowsElapsedTimeAndError() {
        render(
            task(
                state = "failed",
                downloaded = 512L * 1024,
                total = 4L * 1024 * 1024,
                startedAtMs = 1_700_000_000_000L,
                finishedAtMs = 1_700_000_000_000L + 65_000L,
                error = "连接被重置",
            ),
        )
        composeRule.onNodeWithText("失败").assertExists()
        composeRule.onNodeWithText("1分5秒").assertExists()
        composeRule.onNodeWithText("连接被重置").assertExists()
    }
}
