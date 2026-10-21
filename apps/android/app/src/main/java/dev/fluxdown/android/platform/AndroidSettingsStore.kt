package dev.fluxdown.android.platform

import android.content.Context
import dev.fluxdown.android.data.KotlinSettings

/**
 * 作者: long
 * 设置与 SAF 授权的唯一落盘入口。所有键名集中在这里，避免 ViewModel 和 UI 各自拼字符串
 * 导致升级后读不到旧值。
 */
internal class AndroidSettingsStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_SETTINGS, Context.MODE_PRIVATE)
    private val safPrefs = context.getSharedPreferences(PREFS_SAF_TARGETS, Context.MODE_PRIVATE)

    fun load(defaultOutputPath: String): KotlinSettings = KotlinSettings(
        concurrency = prefs.getString(KEY_CONCURRENCY, "5") ?: "5",
        threads = prefs.getString(KEY_THREADS, "16") ?: "16",
        retries = prefs.getString(KEY_RETRIES, "3") ?: "3",
        speedLimit = prefs.getString(KEY_SPEED_LIMIT, "") ?: "",
        outputPath = prefs.getString(KEY_OUTPUT_PATH, defaultOutputPath) ?: defaultOutputPath,
        sftpKnownHostsPath = prefs.getString(KEY_KNOWN_HOSTS, "") ?: "",
        wifiOnly = prefs.getBoolean(KEY_WIFI_ONLY, false),
        notifyOnComplete = prefs.getBoolean(KEY_NOTIFY_ON_COMPLETE, true),
        theme = prefs.getString(KEY_THEME, KotlinSettings.THEME_SYSTEM)
            ?.takeIf { it in KotlinSettings.THEMES } ?: KotlinSettings.THEME_SYSTEM,
        language = prefs.getString(KEY_LANGUAGE, KotlinSettings.LANGUAGE_ZH)
            ?.takeIf { it in KotlinSettings.LANGUAGES } ?: KotlinSettings.LANGUAGE_ZH,
        clipboardPrompt = prefs.getBoolean(KEY_CLIPBOARD_PROMPT, true),
        queueFilter = prefs.getString(KEY_QUEUE_FILTER, KotlinSettings.FILTER_ALL)
            ?.takeIf { it in KotlinSettings.FILTERS } ?: KotlinSettings.FILTER_ALL,
    )

    fun save(settings: KotlinSettings) {
        prefs.edit()
            .putString(KEY_CONCURRENCY, settings.concurrency)
            .putString(KEY_THREADS, settings.threads)
            .putString(KEY_RETRIES, settings.retries)
            .putString(KEY_SPEED_LIMIT, settings.speedLimit)
            .putString(KEY_OUTPUT_PATH, settings.outputPath)
            .putString(KEY_KNOWN_HOSTS, settings.sftpKnownHostsPath)
            .putBoolean(KEY_WIFI_ONLY, settings.wifiOnly)
            .putBoolean(KEY_NOTIFY_ON_COMPLETE, settings.notifyOnComplete)
            .putString(KEY_THEME, settings.theme)
            .putString(KEY_LANGUAGE, settings.language)
            .putBoolean(KEY_CLIPBOARD_PROMPT, settings.clipboardPrompt)
            .putString(KEY_QUEUE_FILTER, settings.queueFilter)
            .apply()
    }

    /** S6 筛选条件单独落盘：切换筛选不该触发整份设置的重写与校验。 */
    fun updateQueueFilter(filter: String) {
        prefs.edit().putString(KEY_QUEUE_FILTER, filter).apply()
    }

    /** S5 上次提示过的剪贴板链接，避免同一个链接每次启动都打扰用户。 */
    fun clipboardLastSeen(): String? = prefs.getString(KEY_CLIPBOARD_LAST_SEEN, null)

    fun updateClipboardLastSeen(source: String) {
        prefs.edit().putString(KEY_CLIPBOARD_LAST_SEEN, source).apply()
    }

    fun updateOutputPath(path: String) {
        prefs.edit().putString(KEY_OUTPUT_PATH, path).apply()
    }

    fun updateKnownHostsPath(path: String) {
        prefs.edit().putString(KEY_KNOWN_HOSTS, path).apply()
    }

    fun clearKnownHostsPath() {
        prefs.edit().remove(KEY_KNOWN_HOSTS).apply()
    }

    fun credentialReferences(): List<String> =
        prefs.getStringSet(KEY_CREDENTIAL_REFERENCES, emptySet())?.toList()?.sorted().orEmpty()

    fun saveCredentialReferences(references: List<String>) {
        prefs.edit().putStringSet(KEY_CREDENTIAL_REFERENCES, references.toSet()).apply()
    }

    /** SAF 目标目录：key 为 `target:<taskId>`，值为用户授权的 tree URI。 */
    fun safTarget(taskId: String): String? = safPrefs.getString(safTargetKey(taskId), null)

    /** SAF 复制状态：`pending` 表示尚未复制到用户目录，`copied` 表示已完成。 */
    fun safState(taskId: String): String = safPrefs.getString(safStateKey(taskId), SAF_STATE_PENDING) ?: SAF_STATE_PENDING

    /** SAF 复制是否已经完成；完成前打开/分享必须回退到私有暂存目录。 */
    fun isSafCopied(taskId: String): Boolean = safState(taskId) == SAF_STATE_COPIED

    /** 已复制文件的相对路径集合（JSON 数组字符串），用于打开/分享。 */
    fun safFiles(taskId: String): String? = safPrefs.getString(safFilesKey(taskId), null)

    fun rememberSafTarget(taskId: String, target: String) {
        safPrefs.edit()
            .putString(safTargetKey(taskId), target)
            .putString(safStateKey(taskId), SAF_STATE_PENDING)
            .apply()
    }

    fun markSafPending(taskId: String) {
        if (!safPrefs.contains(safTargetKey(taskId))) return
        safPrefs.edit()
            .putString(safStateKey(taskId), SAF_STATE_PENDING)
            .remove(safFilesKey(taskId))
            .apply()
    }

    fun markSafCopied(taskId: String, relativePaths: List<String>) {
        safPrefs.edit()
            .putString(safFilesKey(taskId), org.json.JSONArray(relativePaths).toString())
            .putString(safStateKey(taskId), SAF_STATE_COPIED)
            .apply()
    }

    fun forgetSafTarget(taskId: String) {
        safPrefs.edit()
            .remove(safTargetKey(taskId))
            .remove(safStateKey(taskId))
            .remove(safFilesKey(taskId))
            .apply()
    }

    private fun safTargetKey(taskId: String): String = "target:$taskId"

    private fun safStateKey(taskId: String): String = "state:$taskId"

    private fun safFilesKey(taskId: String): String = "files:$taskId"

    private companion object {
        const val PREFS_SETTINGS = "fluxdown.kotlin.settings"
        const val PREFS_SAF_TARGETS = "fluxdown.kotlin.saf.targets"

        const val KEY_CONCURRENCY = "concurrency"
        const val KEY_THREADS = "threads"
        const val KEY_RETRIES = "retries"
        const val KEY_SPEED_LIMIT = "speedLimit"
        const val KEY_OUTPUT_PATH = "outputPath"
        const val KEY_KNOWN_HOSTS = "sftpKnownHostsPath"
        const val KEY_CREDENTIAL_REFERENCES = "credentialReferences"
        const val KEY_WIFI_ONLY = "wifiOnly"
        const val KEY_NOTIFY_ON_COMPLETE = "notifyOnComplete"
        const val KEY_THEME = "theme"
        const val KEY_LANGUAGE = "language"
        const val KEY_CLIPBOARD_PROMPT = "clipboardPrompt"
        const val KEY_QUEUE_FILTER = "queueFilter"
        const val KEY_CLIPBOARD_LAST_SEEN = "clipboardLastSeen"

        const val SAF_STATE_PENDING = "pending"
        const val SAF_STATE_COPIED = "copied"
    }
}
