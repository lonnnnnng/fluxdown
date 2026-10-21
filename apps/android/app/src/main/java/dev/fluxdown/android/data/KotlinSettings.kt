package dev.fluxdown.android.data

/**
 * 作者: long
 * 用户可在设置页调整的下载参数。全部以字符串保存，避免输入过程中的空值和非法数字
 * 在持久化阶段被静默改写；真正下发到 Rust 队列前再统一收敛为数字。
 */
internal data class KotlinSettings(
    val concurrency: String = "5",
    val threads: String = "16",
    val retries: String = "3",
    val speedLimit: String = "",
    val outputPath: String = "",
    val sftpKnownHostsPath: String = "",
    /** S1 仅 Wi-Fi 下载：移动网络下不启动新任务，并在切回 Wi-Fi 后自动继续。 */
    val wifiOnly: Boolean = false,
    /** S2 下载完成通知开关；关闭后前台服务不再发完成通知。 */
    val notifyOnComplete: Boolean = true,
    /** S3 主题：system / light / dark。 */
    val theme: String = THEME_SYSTEM,
    /** S4 界面语言：zh / en。 */
    val language: String = LANGUAGE_ZH,
    /** S5 启动时识别剪贴板链接并提示新建任务。 */
    val clipboardPrompt: Boolean = true,
    /** S6 任务页上次使用的筛选条件，重启后保持。 */
    val queueFilter: String = FILTER_ALL,
) {
    companion object {
        const val THEME_SYSTEM = "system"
        const val THEME_LIGHT = "light"
        const val THEME_DARK = "dark"

        const val LANGUAGE_ZH = "zh"
        const val LANGUAGE_EN = "en"

        const val FILTER_ALL = "all"
        const val FILTER_UNFINISHED = "unfinished"
        const val FILTER_ENDED = "ended"
        const val FILTER_FAILED = "failed"

        val THEMES = listOf(THEME_SYSTEM, THEME_LIGHT, THEME_DARK)
        val LANGUAGES = listOf(LANGUAGE_ZH, LANGUAGE_EN)
        val FILTERS = listOf(FILTER_ALL, FILTER_UNFINISHED, FILTER_ENDED, FILTER_FAILED)
    }
}
