package dev.fluxdown.android

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.StatFs
import android.os.storage.StorageManager
import android.util.Log
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.FolderOpen
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Security
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SystemUpdateAlt
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.outlined.Download as DownloadOutlined
import androidx.compose.material.icons.outlined.Settings as SettingsOutlined
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.documentfile.provider.DocumentFile
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.viewModelScope
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import dev.fluxdown.android.core.RustCoreBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import java.net.URLConnection
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage

private const val KOTLIN_APP_VERSION = "1.0.28-kotlin-alpha.4"

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val model = ViewModelProvider(this, NativeViewModel.factory(this))[NativeViewModel::class.java]
        setContent {
            FluxDownKotlinTheme {
                FluxDownApp(model)
            }
        }
    }
}

private enum class HomeTab { Tasks, Settings }

private data class QueueTask(
    val id: String,
    val name: String,
    val source: String,
    val state: String,
    val downloadedBytes: Long,
    val totalBytes: Long?,
    val speedBytesPerSecond: Long,
    val startedAtMs: Long?,
    val finishedAtMs: Long?,
    val error: String?,
    val outputDir: String,
    val torrentName: String?,
    val torrentFiles: List<TorrentFileSelection>,
    val torrentFileIndices: Set<Int>,
    val hlsVariantIndex: Int?,
    val hlsKeepTransportStream: Boolean,
    val hlsRemuxedToMp4: Boolean,
    val credentialRef: String?,
) {
    // 作者: long
    // Torrent/Magnet 是目录型资源，列表入口应展示 metadata 根目录；具体文件留在资源详情中查看。
    val isTorrentResource: Boolean
        get() = torrentFiles.isNotEmpty() || torrentName != null

    val displayName: String
        get() = when {
            isTorrentResource -> torrentResourceDirectoryLabel(torrentName, torrentFiles.map { it.name })
            hlsRemuxedToMp4 && name.endsWith(".ts", ignoreCase = true) -> name.dropLast(3) + ".mp4"
            else -> name
        }

    val progress: Float
        get() = if (state == "finished") 1f
        else if (totalBytes == null || totalBytes <= 0) 0f
        else (downloadedBytes.toDouble() / totalBytes).coerceIn(0.0, 1.0).toFloat()
}

internal fun torrentResourceDirectoryLabel(name: String?, fileNames: List<String>): String {
    val metadataName = name?.trim().orEmpty()
    if (metadataName.isEmpty()) return "Torrent 资源"
    // 作者: long
    // 单文件种子的 metadata 名通常就是文件名；列表展示资源入口时去掉文件扩展名，
    // 文件全名、格式和大小仍在详情中，避免目录入口看起来像单个 MP4/MKV 文件。
    if (fileNames.size == 1 && metadataName.equals(fileNames[0], ignoreCase = true)) {
        return metadataName.substringBeforeLast('.', metadataName).ifBlank { metadataName }
    }
    return metadataName
}

private data class TorrentFileSelection(
    val index: Int,
    val path: String,
    val name: String,
    val size: Long,
    val isStreamable: Boolean,
    val progressBytes: Long? = null,
)

private data class TorrentSelection(
    val source: String,
    val requestedFileName: String,
    val outputPath: String,
    val directoryName: String,
    val files: List<TorrentFileSelection>,
    val infoHash: String?,
)

private data class KotlinSettings(
    val concurrency: String = "5",
    val threads: String = "16",
    val retries: String = "3",
    val speedLimit: String = "",
    val outputPath: String = "",
    val sftpKnownHostsPath: String = "",
)

internal data class StoredAndroidCredential(
    val username: String,
    val password: String = "",
    val privateKeyPem: String? = null,
    val passphrase: String? = null,
) {
    val usesPrivateKey: Boolean
        get() = !privateKeyPem.isNullOrBlank()
}

private data class AndroidStorageStats(
    val totalBytes: Long,
    val freeBytes: Long,
) {
    val usedBytes: Long
        get() = (totalBytes - freeBytes).coerceIn(0L, totalBytes)
}

private data class AndroidUpdateReport(
    val currentVersion: String,
    val latestVersion: String,
    val hasUpdate: Boolean,
    val releaseUrl: String,
    val downloadUrl: String?,
    val releaseNotes: String?,
)

private data class HlsVariantOption(
    val index: Int,
    val bandwidth: Long,
    val averageBandwidth: Long?,
    val codecs: String?,
    val resolution: String?,
    val frameRate: Double?,
)

private data class NativeUiState(
    val tasks: List<QueueTask> = emptyList(),
    val settings: KotlinSettings = KotlinSettings(),
    val selectedTab: HomeTab = HomeTab.Tasks,
    val isLoading: Boolean = false,
    val notice: String? = null,
    val rustVersion: String = "未加载",
    val rustAbi: String = "-",
    val torrentSelection: TorrentSelection? = null,
    val isConfirmingTorrent: Boolean = false,
    val torrentDetail: TorrentSelection? = null,
    val torrentDetailTask: QueueTask? = null,
    val actionTask: QueueTask? = null,
    val notificationPermissionRequest: Boolean = false,
    val credentialReferences: List<String> = emptyList(),
    val storageStats: AndroidStorageStats? = null,
    val storageLoading: Boolean = false,
    val storageUnavailable: Boolean = false,
    val updateChecking: Boolean = false,
    val updateReport: AndroidUpdateReport? = null,
    val hlsVariants: List<HlsVariantOption> = emptyList(),
    val hlsVariantsSource: String? = null,
    val hlsVariantsLoading: Boolean = false,
)

/**
 * 作者: long
 * Android 端凭据只保存引用名到普通偏好，用户名、密码和私钥使用 Keystore 中的 AES 密钥加密。
 * 这样任务 JSON、日志和 Rust 队列快照都不会携带认证材料；运行队列时才短暂解密到内存。
 */
internal class AndroidCredentialVault(
    private val context: Context,
) {
    private val prefs = context.getSharedPreferences("fluxdown.kotlin.credentials", Context.MODE_PRIVATE)
    private val keyAlias = "fluxdown.android.credentials.v1"

    fun put(reference: String, credential: StoredAndroidCredential) {
        val normalized = normalizeReference(reference)
        require(credential.username.trim().isNotEmpty()) { "凭据用户名不能为空" }
        if (credential.usesPrivateKey) {
            val pem = credential.privateKeyPem!!.trim()
            require(pem.length <= 256 * 1024 && pem.contains("PRIVATE KEY")) { "SFTP 私钥格式无效" }
        }
        val payload = JSONObject()
            .put("username", credential.username)
            .put("authType", if (credential.usesPrivateKey) "privateKey" else "password")
        if (credential.usesPrivateKey) {
            payload.put("privateKeyPem", credential.privateKeyPem)
            credential.passphrase?.let { payload.put("passphrase", it) }
        } else {
            payload.put("password", credential.password)
        }
        prefs.edit().putString(storageKey(normalized), encrypt(payload.toString())).apply()
    }

    fun get(reference: String): StoredAndroidCredential? {
        val normalized = runCatching { normalizeReference(reference) }.getOrNull() ?: return null
        val encoded = prefs.getString(storageKey(normalized), null) ?: return null
        return runCatching {
            val value = JSONObject(decrypt(encoded))
            val username = value.optString("username").trim()
            if (username.isEmpty()) return@runCatching null
            if (value.optString("authType") == "privateKey") {
                val pem = value.optString("privateKeyPem").trim()
                if (pem.isEmpty()) return@runCatching null
                StoredAndroidCredential(username, privateKeyPem = pem, passphrase = value.optString("passphrase").ifBlank { null })
            } else {
                StoredAndroidCredential(username, password = value.optString("password"))
            }
        }.getOrNull()
    }

    fun remove(reference: String) {
        val normalized = normalizeReference(reference)
        prefs.edit().remove(storageKey(normalized)).apply()
    }

    private fun storageKey(reference: String): String =
        "fluxdown.credential.v1.${Base64.encodeToString(reference.toByteArray(Charsets.UTF_8), Base64.NO_WRAP or Base64.URL_SAFE)}"

    private fun normalizeReference(reference: String): String {
        val normalized = reference.trim()
        require(normalized.isNotEmpty() && normalized.length <= 128) { "凭据引用无效" }
        return normalized
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        // 作者: long
        // 部分真机在应用升级或恢复备份后会保留一个无法再解析参数的旧别名；
        // 先清掉失效别名再生成新密钥，避免凭据保存被 Keystore 的内部异常阻断。
        val existing = runCatching { keyStore.getKey(keyAlias, null) as? SecretKey }.getOrNull()
        if (existing != null) return existing
        // `containsAlias` 也可能在失效元数据上抛异常，因此删除动作本身必须是幂等的。
        // 作者: long
        runCatching { keyStore.deleteEntry(keyAlias) }
        val generator = KeyGenerator.getInstance("AES", "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        // 作者: long
        // Android Keystore 的 AES/GCM 密钥策略禁止调用方指定加密 IV；让 Keystore 生成随机 IV，
        // 再把实际 IV 与密文打包，确保同一凭据每次保存都使用新的随机初始向量。
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv + encrypted, Base64.NO_WRAP)
    }

    private fun decrypt(value: String): String {
        val packed = Base64.decode(value, Base64.NO_WRAP)
        require(packed.size > 12) { "凭据内容无效" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, packed.copyOfRange(0, 12)))
        return cipher.doFinal(packed.copyOfRange(12, packed.size)).toString(Charsets.UTF_8)
    }
}

private class NativeViewModel(private val context: Context) : ViewModel() {
    private val prefs = context.getSharedPreferences("fluxdown.kotlin.settings", Context.MODE_PRIVATE)
    private val safTargetPrefs = context.getSharedPreferences("fluxdown.kotlin.saf.targets", Context.MODE_PRIVATE)
    private val credentialVault = AndroidCredentialVault(context)
    private val storePath = File(context.filesDir, "fluxdown/rust-queue.json").absolutePath
    // 作者: long
    // Android 预览阶段先落到应用私有目录，避免 Rust 核心在未接入 SAF 授权时误写受保护的共享目录。
    // 接入系统目录选择器后，用户选择的持久化目录才会覆盖这个安全默认值。
    private val defaultOutputPath = File(context.filesDir, "Downloads").apply { mkdirs() }.absolutePath
    private val safStagingRoot = File(context.filesDir, "fluxdown/saf-staging").apply { mkdirs() }
    private val knownHostsRoot = File(context.filesDir, "fluxdown/security").apply { mkdirs() }
    private val safCopyInFlight = ConcurrentHashMap.newKeySet<String>()
    private val hlsRemuxInFlight = ConcurrentHashMap.newKeySet<String>()
    private val _state = MutableStateFlow(
        NativeUiState(
            settings = KotlinSettings(
                concurrency = prefs.getString("concurrency", "5") ?: "5",
                threads = prefs.getString("threads", "16") ?: "16",
                retries = prefs.getString("retries", "3") ?: "3",
                speedLimit = prefs.getString("speedLimit", "") ?: "",
                outputPath = prefs.getString("outputPath", defaultOutputPath) ?: defaultOutputPath,
                sftpKnownHostsPath = prefs.getString("sftpKnownHostsPath", "") ?: "",
            ),
            credentialReferences = prefs.getStringSet("credentialReferences", emptySet())?.toList()?.sorted().orEmpty(),
        ),
    )
    val state: StateFlow<NativeUiState> = _state.asStateFlow()

    init {
        refresh()
        refreshStorageStats()
    }

    fun selectTab(tab: HomeTab) {
        _state.value = _state.value.copy(selectedTab = tab, notice = null)
    }

    fun clearNotificationPermissionRequest() {
        _state.value = _state.value.copy(notificationPermissionRequest = false)
    }

    fun refresh() {
        viewModelScope.launch(Dispatchers.IO) {
            refreshOnce()
            ensureQueueRunning()
        }
    }

    fun addTask(
        source: String,
        fileName: String,
        outputPath: String,
        credentialRef: String?,
        expectedSha256: String,
        hlsVariantIndex: Int?,
        hlsKeepTransportStream: Boolean,
    ) {
        viewModelScope.launch(Dispatchers.IO) {
            val normalizedSource = source.trim()
            val protocol = parseDataString(RustCoreBridge.detect(normalizedSource), "protocol")
            val normalizedCredential = credentialRef?.trim()?.takeIf { it.isNotEmpty() }
            if (normalizedCredential != null && !supportsCredentialProtocol(protocol)) {
                withContext(Dispatchers.Main) {
                    _state.value = _state.value.copy(notice = "该协议不支持凭据引用")
                }
                return@launch
            }
            if (normalizedCredential != null) {
                val credential = credentialVault.get(normalizedCredential)
                if (credential == null) {
                    withContext(Dispatchers.Main) {
                        _state.value = _state.value.copy(notice = "凭据不可用，请在设置中重新保存")
                    }
                    return@launch
                }
                if (credential.usesPrivateKey && protocol != "sftp") {
                    withContext(Dispatchers.Main) {
                        _state.value = _state.value.copy(notice = "SFTP 私钥凭据只能用于 SFTP 任务")
                    }
                    return@launch
                }
            }
            if (protocol == "torrent" || protocol == "magnet") {
                inspectTorrent(normalizedSource, fileName.trim(), outputPath.ifBlank { defaultOutputPath })
                return@launch
            }
            val selectedOutput = outputPath.ifBlank { defaultOutputPath }
            val taskId = taskIdForOutput(selectedOutput)
            val request = JSONObject()
                .put("source", normalizedSource)
                .put("outputDir", rustOutputPath(selectedOutput, taskId))
            taskId?.let { request.put("taskId", it) }
            if (fileName.isNotBlank()) request.put("fileName", fileName.trim())
            if (expectedSha256.isNotBlank()) request.put("expectedSha256", expectedSha256.trim())
            normalizedCredential?.let { request.put("credentialRef", it) }
            hlsVariantIndex?.let { request.put("hlsVariantIndex", it) }
            if (hlsKeepTransportStream) request.put("hlsKeepTransportStream", true)
            val taskIdFromQueue = enqueue(
                request,
                selectedOutput.takeIf { isTreeUri(it) },
                startQueue = protocol != "ed2k",
            )
            if (protocol == "ed2k" && taskIdFromQueue != null) {
                handoffEd2k(normalizedSource, taskIdFromQueue)
            }
        }
    }

    /**
     * SAF 目录不能作为 POSIX 路径交给 Rust；先为任务建立私有暂存目录，完成后再复制到用户目录。
     * 作者: long
     */
    private suspend fun enqueue(request: JSONObject, safTarget: String?, startQueue: Boolean = true): String? {
        val result = RustCoreBridge.queueAdd(storePath, request.toString())
        val message = parseError(result)
        val taskId = parseDataString(result, "id")
        if (message == null && safTarget != null) {
            parseDataString(result, "id")?.let { rememberSafTarget(it, safTarget) }
        }
        withContext(Dispatchers.Main) {
            _state.value = _state.value.copy(notice = message ?: "任务已加入 Rust 队列")
        }
        if (message == null) {
            refreshOnce()
            if (startQueue && taskId != null) ensureQueueRunning()
        }
        return taskId
    }

    private suspend fun handoffEd2k(source: String, taskId: String) {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(source)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        val packageManager = context.packageManager
        val canHandle = intent.resolveActivity(packageManager) != null
        if (!canHandle) {
            RustCoreBridge.queueRemove(storePath, taskId)
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(notice = "没有可处理 ed2k 链接的应用")
            }
            refreshOnce()
            return
        }
        runCatching { context.startActivity(intent) }
            .onSuccess {
                RustCoreBridge.queueMarkHandedOff(storePath, taskId)
                withContext(Dispatchers.Main) {
                    _state.value = _state.value.copy(notice = "ed2k 链接已移交外部客户端")
                }
            }
            .onFailure {
                RustCoreBridge.queueRemove(storePath, taskId)
                withContext(Dispatchers.Main) {
                    _state.value = _state.value.copy(notice = "ed2k 链接移交失败：${it.message ?: "未知错误"}")
                }
            }
        refreshOnce()
    }

    /**
     * Torrent/Magnet 先解析 metadata，不写入队列；只有用户确认文件选择后才创建任务。
     * 作者: long
     */
    private suspend fun inspectTorrent(source: String, fileName: String, outputPath: String) {
        withContext(Dispatchers.Main) {
            _state.value = _state.value.copy(notice = "正在解析 Torrent/Magnet metadata…")
        }
        val start = RustCoreBridge.torrentDetailsAsync(source)
        val runId = parseDataString(start, "runId")
        if (runId == null) {
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(notice = parseError(start) ?: "metadata 解析启动失败")
            }
            return
        }
        var detailsStatus = "running"
        var terminalStatus = start
        while (detailsStatus == "running") {
            delay(500)
            terminalStatus = RustCoreBridge.queueRunStatus(runId)
            detailsStatus = parseDataString(terminalStatus, "state") ?: "failed"
        }
        RustCoreBridge.queueRunForget(runId)
        if (detailsStatus != "finished") {
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(notice = parseDataString(terminalStatus, "error") ?: "metadata 解析失败")
            }
            return
        }
        val selection = parseTorrentSelection(terminalStatus, source, fileName, outputPath)
        if (selection == null || selection.files.isEmpty()) {
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(notice = "metadata 未返回可下载文件")
            }
            return
        }
        withContext(Dispatchers.Main) {
            _state.value = _state.value.copy(torrentSelection = selection, notice = null)
        }
    }

    fun showTorrentDetails(task: QueueTask) {
        val outputPath = _state.value.settings.outputPath.ifBlank { defaultOutputPath }
        fun savedDetails(): TorrentSelection = TorrentSelection(
            source = task.source,
            requestedFileName = task.name,
            outputPath = outputPath,
            directoryName = task.torrentName ?: task.name,
            files = task.torrentFiles
                .filter { task.torrentFileIndices.isEmpty() || it.index in task.torrentFileIndices }
                .map { file ->
                    if (task.state == "finished") file.copy(progressBytes = file.size) else file
                },
            infoHash = null,
        )
        if (task.state != "running") {
            // 作者: long
            // 非运行任务没有活动 session；直接读取持久化的确认结果，避免 Magnet 详情触发第二次网络等待。
            _state.value = _state.value.copy(torrentDetail = savedDetails(), torrentDetailTask = task, notice = null)
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            // 作者: long
            // 运行中的 Torrent 由 Rust 返回逐文件进度；暂停或完成后没有活动会话时，仍展示入队时保存的 metadata。
            val start = RustCoreBridge.torrentDetailsAsync(task.source, task.id)
            val runId = parseDataString(start, "runId")
            if (runId == null) {
                withContext(Dispatchers.Main) {
                    _state.value = _state.value.copy(torrentDetail = savedDetails(), torrentDetailTask = task, notice = null)
                }
                return@launch
            }
            var detailsStatus = "running"
            var terminalStatus = start
            while (detailsStatus == "running") {
                delay(400)
                terminalStatus = RustCoreBridge.queueRunStatus(runId)
                detailsStatus = parseDataString(terminalStatus, "state") ?: "failed"
            }
            RustCoreBridge.queueRunForget(runId)
            val selection = if (detailsStatus == "finished") {
                parseTorrentSelection(terminalStatus, task.source, task.name, outputPath)
            } else {
                null
            }
            val selected = selection?.let { value ->
                if (task.torrentFileIndices.isEmpty()) value
                else value.copy(files = value.files.filter { it.index in task.torrentFileIndices })
            }
            val fallback = selected ?: savedDetails()
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(torrentDetail = fallback, torrentDetailTask = task, notice = null)
            }
        }
    }

    fun closeTorrentDetails() {
        _state.value = _state.value.copy(torrentDetail = null, torrentDetailTask = null)
    }

    fun confirmTorrentSelection(selection: TorrentSelection, selectedIndexes: Set<Int>) {
        if (_state.value.isConfirmingTorrent) return
        _state.value = _state.value.copy(isConfirmingTorrent = true)
        viewModelScope.launch(Dispatchers.IO) {
            if (selectedIndexes.isEmpty()) {
                withContext(Dispatchers.Main) {
                    _state.value = _state.value.copy(isConfirmingTorrent = false, notice = "至少选择一个文件")
                }
                return@launch
            }
            val files = JSONArray()
            selection.files.forEach { file ->
                files.put(
                    JSONObject()
                        .put("index", file.index)
                        .put("path", file.path)
                        .put("name", file.name)
                        .put("size", file.size)
                        .put("isStreamable", file.isStreamable),
                )
            }
            val taskId = taskIdForOutput(selection.outputPath)
            val request = JSONObject()
                .put("source", selection.source)
                .put("outputDir", rustOutputPath(selection.outputPath, taskId))
                .put("fileName", selection.requestedFileName.ifBlank { selection.directoryName })
                .put("torrentName", selection.directoryName)
                .put("torrentFileIndices", JSONArray(selectedIndexes.toList().sorted()))
                .put("torrentFiles", files)
            taskId?.let { request.put("taskId", it) }
            val result = RustCoreBridge.queueAdd(storePath, request.toString())
            val message = parseError(result)
            if (message == null && taskId != null) {
                rememberSafTarget(taskId, selection.outputPath)
            }
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(
                    torrentSelection = if (message == null) null else selection,
                    isConfirmingTorrent = false,
                    notice = message ?: "任务已加入 Rust 队列",
                )
            }
            if (message == null) {
                refreshOnce()
                ensureQueueRunning()
            }
        }
    }

    fun cancelTorrentSelection() {
        if (_state.value.isConfirmingTorrent) return
        _state.value = _state.value.copy(torrentSelection = null, notice = "已取消 Torrent/Magnet 任务")
    }

    fun remove(task: QueueTask) {
        mutateTask(task, { RustCoreBridge.queueRemove(storePath, task.id) }) {
            forgetSafTarget(task.id)
        }
    }

    fun pause(task: QueueTask) {
        mutateTask(task, { RustCoreBridge.queuePause(storePath, task.id) })
    }

    fun resume(task: QueueTask) {
        mutateTask(task, { RustCoreBridge.queueResume(storePath, task.id) })
    }

    fun reset(task: QueueTask) {
        mutateTask(task, { RustCoreBridge.queueReset(storePath, task.id) }) {
            markSafPending(task.id)
        }
    }

    fun showTaskActions(task: QueueTask) {
        _state.value = _state.value.copy(actionTask = task)
    }

    fun closeTaskActions() {
        _state.value = _state.value.copy(actionTask = null)
    }

    fun copySource(task: QueueTask) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        clipboard?.setPrimaryClip(ClipData.newPlainText("FluxDown", task.source))
        _state.value = _state.value.copy(actionTask = null, notice = "下载链接已复制")
    }

    fun openTask(task: QueueTask) {
        dispatchTaskFile(task, Intent.ACTION_VIEW)
    }

    fun shareTask(task: QueueTask) {
        dispatchTaskFile(task, Intent.ACTION_SEND)
    }

    fun openTorrentFile(task: QueueTask, file: TorrentFileSelection) {
        if (task.state == "finished" && task.torrentFiles.any { it.index == file.index && it.path == file.path } &&
            (task.torrentFileIndices.isEmpty() || file.index in task.torrentFileIndices)
        ) {
            dispatchTaskFile(task, Intent.ACTION_VIEW, file.path)
        }
    }

    fun shareTorrentFile(task: QueueTask, file: TorrentFileSelection) {
        if (task.state == "finished" && task.torrentFiles.any { it.index == file.index && it.path == file.path } &&
            (task.torrentFileIndices.isEmpty() || file.index in task.torrentFileIndices)
        ) {
            dispatchTaskFile(task, Intent.ACTION_SEND, file.path)
        }
    }

    /**
     * 完成任务的真实产物可能在应用私有目录，也可能已被复制到 SAF 目录；统一解析成可授权的 content URI，
     * 避免把私有路径直接交给其他应用，也避免 SAF 目录被误当作 POSIX 文件路径。
     * 作者: long
     */
    private fun dispatchTaskFile(task: QueueTask, action: String, relativePath: String? = null) {
        viewModelScope.launch(Dispatchers.IO) {
            val resolved = runCatching { resolveTaskFile(task, relativePath) }.getOrNull()
            withContext(Dispatchers.Main) {
                if (resolved == null) {
                    _state.value = _state.value.copy(actionTask = null, notice = "找不到已下载文件")
                    return@withContext
                }
                val intent = Intent(action).apply {
                    setDataAndType(resolved.uri, resolved.mimeType)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    if (action == Intent.ACTION_SEND) {
                        putExtra(Intent.EXTRA_STREAM, resolved.uri)
                    }
                }
                try {
                    context.startActivity(
                        Intent.createChooser(intent, if (action == Intent.ACTION_SEND) "分享文件" else "打开文件")
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    _state.value = _state.value.copy(actionTask = null)
                } catch (_: ActivityNotFoundException) {
                    _state.value = _state.value.copy(actionTask = null, notice = "设备上没有支持此文件类型的应用")
                } catch (error: RuntimeException) {
                    _state.value = _state.value.copy(actionTask = null, notice = "无法${if (action == Intent.ACTION_SEND) "分享" else "打开"}文件：${error.message ?: "未知错误"}")
                }
            }
        }
    }

    private data class ResolvedTaskFile(
        val uri: Uri,
        val mimeType: String,
    )

    private fun resolveTaskFile(task: QueueTask, relativePath: String?): ResolvedTaskFile? {
        val safTarget = safTargetPrefs.getString("target:${task.id}", null)
        return if (safTarget != null) {
            resolveSafTaskFile(task, safTarget, relativePath)
        } else {
            resolveLocalTaskFile(task, relativePath)
        }
    }

    private fun resolveLocalTaskFile(task: QueueTask, relativePath: String?): ResolvedTaskFile? {
        val root = File(task.outputDir)
        if (!root.isDirectory) return null
        val candidates = taskOutputPaths(task, relativePath).mapNotNull { safeChild(root, it) }
        val file = candidates.firstOrNull { it.isFile } ?: return null
        val uri = runCatching {
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        }.getOrNull() ?: return null
        return ResolvedTaskFile(uri, URLConnection.guessContentTypeFromName(file.name) ?: "application/octet-stream")
    }

    private fun resolveSafTaskFile(task: QueueTask, target: String, relativePath: String?): ResolvedTaskFile? {
        if (safTargetPrefs.getString("state:${task.id}", "pending") != "copied") return null
        val root = DocumentFile.fromTreeUri(context, Uri.parse(target)) ?: return null
        val recorded = safTargetPrefs.getString("files:${task.id}", null)?.let { raw ->
            runCatching {
                val array = JSONArray(raw)
                (0 until array.length()).mapNotNull { array.optString(it).takeIf(String::isNotBlank) }
            }.getOrNull()
        }.orEmpty()
        val paths = ((if (relativePath == null) recorded else emptyList()) + taskOutputPaths(task, relativePath)).distinct()
        val document = paths.asSequence()
            .mapNotNull { findSafFile(root, it) }
            .firstOrNull { it.isFile }
            ?: return null
        return ResolvedTaskFile(
            document.uri,
            document.type ?: URLConnection.guessContentTypeFromName(document.name ?: "") ?: "application/octet-stream",
        )
    }

    private fun safeChild(root: File, relativePath: String): File? {
        val candidate = runCatching { File(root, relativePath).canonicalFile }.getOrNull() ?: return null
        val canonicalRoot = runCatching { root.canonicalFile }.getOrNull() ?: return null
        val rootPrefix = canonicalRoot.path + File.separator
        return candidate.takeIf { it.path == canonicalRoot.path || it.path.startsWith(rootPrefix) }
    }

    private fun findSafFile(root: DocumentFile, relativePath: String): DocumentFile? {
        val components = relativePath.replace('\\', '/').split('/')
        if (components.isEmpty() || components.any { it.isBlank() || it == "." || it == ".." }) return null
        var current = root
        for (component in components) {
            current = current.findFile(component) ?: return null
        }
        return current
    }

    private fun taskOutputPaths(task: QueueTask, relativePath: String?): List<String> = buildList {
        task.torrentFiles
            .filter { (task.torrentFileIndices.isEmpty() || it.index in task.torrentFileIndices) &&
                (relativePath == null || it.path == relativePath) }
            .forEach { file ->
                add(file.path)
                task.torrentName?.takeIf { it.isNotBlank() }?.let { add("$it/${file.path}") }
            }
        if (relativePath != null) return@buildList
        add(task.name)
        if (task.source.substringBefore('?').endsWith(".m3u8", ignoreCase = true)) {
            val stem = task.name.substringBeforeLast('.', task.name)
            add("$stem.mp4")
            add("$stem.ts")
        }
    }.distinct()

    fun selectOutputDirectory(uri: Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            val persisted = runCatching {
                val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                context.contentResolver.takePersistableUriPermission(uri, flags)
                DocumentFile.fromTreeUri(context, uri)?.takeIf { it.isDirectory && it.canWrite() }
            }.getOrNull()
            withContext(Dispatchers.Main) {
                if (persisted == null) {
                    _state.value = _state.value.copy(notice = "无法写入所选目录，请选择可写的系统目录")
                } else {
                    val path = uri.toString()
                    val settings = _state.value.settings.copy(outputPath = path)
                    prefs.edit().putString("outputPath", path).apply()
                    _state.value = _state.value.copy(settings = settings, notice = "已选择下载保存位置：${persisted.name ?: "系统目录"}")
                    refreshStorageStats(path)
                }
            }
        }
    }

    /**
     * 作者: long
     * SAF 返回的是 content URI，Rust 只能读取 POSIX 文件；因此把 known_hosts 复制到应用私有目录，
     * 并只把私有副本路径传给 Rust，避免授权失效或外部文件被替换造成主机密钥策略漂移。
     */
    fun importSftpKnownHosts(uri: Uri) {
        viewModelScope.launch(Dispatchers.IO) {
            val result = runCatching {
                val content = context.contentResolver.openInputStream(uri)?.use(InputStream::readBytes)
                    ?.toString(Charsets.UTF_8)?.trim()
                    ?: error("无法读取 known_hosts 文件")
                require(hasUsableKnownHostEntry(content)) { "文件中没有可用的 OpenSSH known_hosts 主机密钥" }
                val target = File(knownHostsRoot, "known_hosts")
                target.writeText(content, Charsets.UTF_8)
                target.absolutePath
            }
            withContext(Dispatchers.Main) {
                result.onSuccess { path ->
                    val settings = _state.value.settings.copy(sftpKnownHostsPath = path)
                    prefs.edit().putString("sftpKnownHostsPath", path).apply()
                    _state.value = _state.value.copy(settings = settings, notice = "SFTP 主机密钥已更新")
                }.onFailure {
                    _state.value = _state.value.copy(notice = it.message ?: "无法读取 known_hosts 文件")
                }
            }
        }
    }

    fun clearSftpKnownHosts() {
        val path = _state.value.settings.sftpKnownHostsPath
        if (path.isNotBlank()) runCatching { File(path).delete() }
        val settings = _state.value.settings.copy(sftpKnownHostsPath = "")
        prefs.edit().remove("sftpKnownHostsPath").apply()
        _state.value = _state.value.copy(settings = settings, notice = "SFTP 主机密钥已清除")
    }

    fun saveCredential(reference: String, credential: StoredAndroidCredential) {
        viewModelScope.launch(Dispatchers.IO) {
            val result = runCatching {
                credentialVault.put(reference, credential)
                val normalized = reference.trim()
                val references = (_state.value.credentialReferences + normalized).toSet().toList().sorted()
                prefs.edit().putStringSet("credentialReferences", references.toSet()).apply()
                references
            }
            withContext(Dispatchers.Main) {
                result.onSuccess { references ->
                    _state.value = _state.value.copy(credentialReferences = references, notice = "凭据已保存")
                }.onFailure {
                    _state.value = _state.value.copy(notice = it.message ?: "凭据保存失败")
                }
            }
        }
    }

    fun deleteCredential(reference: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val result = runCatching {
                credentialVault.remove(reference)
                val references = _state.value.credentialReferences.filterNot { it == reference }
                prefs.edit().putStringSet("credentialReferences", references.toSet()).apply()
                references
            }
            withContext(Dispatchers.Main) {
                result.onSuccess { references ->
                    _state.value = _state.value.copy(credentialReferences = references, notice = "凭据已删除")
                }.onFailure {
                    _state.value = _state.value.copy(notice = it.message ?: "凭据删除失败")
                }
            }
        }
    }

    fun checkForUpdates() {
        if (_state.value.updateChecking) return
        _state.value = _state.value.copy(updateChecking = true)
        viewModelScope.launch(Dispatchers.IO) {
            val result = runCatching { fetchLatestRelease() }
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(updateChecking = false)
                result.onSuccess { report ->
                    _state.value = _state.value.copy(notice = "已完成版本检查")
                    _state.value = _state.value.copy(updateReport = report)
                }.onFailure {
                    _state.value = _state.value.copy(notice = it.message ?: "检查更新失败，请稍后重试")
                    _state.value = _state.value.copy(updateReport = null)
                }
            }
        }
    }

    fun loadHlsVariants(source: String) {
        val requested = source.trim()
        if (!requested.substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true)) {
            _state.value = _state.value.copy(hlsVariants = emptyList(), hlsVariantsSource = null, hlsVariantsLoading = false)
            return
        }
        if (_state.value.hlsVariantsLoading && _state.value.hlsVariantsSource == requested) return
        _state.value = _state.value.copy(hlsVariants = emptyList(), hlsVariantsSource = requested, hlsVariantsLoading = true)
        viewModelScope.launch(Dispatchers.IO) {
            val result = parseHlsVariants(RustCoreBridge.hlsVariants(requested))
            withContext(Dispatchers.Main) {
                // 作者: long
                // 网络请求返回可能晚于用户继续编辑链接，只接受仍对应当前地址的结果，避免旧清晰度列表套到新任务。
                if (_state.value.hlsVariantsSource == requested) {
                    _state.value = _state.value.copy(hlsVariants = result, hlsVariantsLoading = false)
                }
            }
        }
    }

    fun clearUpdateReport() {
        _state.value = _state.value.copy(updateReport = null)
    }

    fun openExternalUrl(url: String) {
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.onFailure {
            _state.value = _state.value.copy(notice = "无法打开下载页")
        }
    }

    private fun fetchLatestRelease(): AndroidUpdateReport {
        val connection = (URL("https://api.github.com/repos/lonnnnnng/fluxdown/releases/latest").openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 15_000
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "FluxDown-Kotlin")
        }
        return try {
            if (connection.responseCode !in 200..299) error("更新服务器返回错误（${connection.responseCode}）")
            val root = JSONObject(connection.inputStream.bufferedReader().use { reader -> reader.readText() })
            val latest = normalizeVersion(root.optString("tag_name"))
            require(latest.isNotBlank()) { "更新信息缺少版本号" }
            val current = normalizeVersion(KOTLIN_APP_VERSION)
            val assets = root.optJSONArray("assets") ?: JSONArray()
            val apk = buildList {
                for (index in 0 until assets.length()) {
                    val asset = assets.optJSONObject(index) ?: continue
                    val name = asset.optString("name")
                    val url = asset.optString("browser_download_url")
                    if (name.endsWith(".apk", ignoreCase = true) && url.startsWith("https://")) add(url)
                }
            }.firstOrNull()
            AndroidUpdateReport(
                currentVersion = current,
                latestVersion = latest,
                hasUpdate = compareVersions(latest, current) > 0,
                releaseUrl = root.optString("html_url").ifBlank { "https://github.com/lonnnnnng/fluxdown/releases/latest" },
                downloadUrl = apk,
                releaseNotes = root.optString("body").ifBlank { null },
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun normalizeVersion(value: String): String = value.trim().removePrefix("v").substringBefore("-").substringBefore("+")

    private fun compareVersions(left: String, right: String): Int {
        val a = Regex("\\d+").findAll(left).map { it.value.toInt() }.toList()
        val b = Regex("\\d+").findAll(right).map { it.value.toInt() }.toList()
        val size = maxOf(a.size, b.size)
        for (index in 0 until size) {
            val diff = (a.getOrNull(index) ?: 0).compareTo(b.getOrNull(index) ?: 0)
            if (diff != 0) return diff
        }
        return 0
    }

    fun refreshStorageStats(path: String = _state.value.settings.outputPath) {
        _state.value = _state.value.copy(storageLoading = true)
        viewModelScope.launch(Dispatchers.IO) {
            val stats = readStorageStats(path)
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(
                    storageStats = stats,
                    storageLoading = false,
                    storageUnavailable = stats == null,
                )
            }
        }
    }

    private fun readStorageStats(path: String): AndroidStorageStats? = runCatching {
        val resolvedPath = if (path.startsWith("content://")) {
            // 作者: long
            // DocumentTree URI 不暴露可直接传给 StatFs 的路径；容量统计展示用户设备主存储卷，
            // 下载文件仍按 SAF 授权目录保存，不能因为 URI 统计失败而隐藏容量信息。
            val volumePath = runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    context.getSystemService(StorageManager::class.java)
                        ?.getStorageVolume(Uri.parse(path))
                        ?.directory
                        ?.absolutePath
                } else null
            }.getOrNull()
            volumePath
                ?: Environment.getExternalStorageDirectory().absolutePath
        } else {
            path.takeIf { it.isNotBlank() }
        } ?: context.filesDir.absolutePath
        val stat = StatFs(resolvedPath)
        val total = stat.blockCountLong * stat.blockSizeLong
        val free = stat.availableBlocksLong * stat.blockSizeLong
        AndroidStorageStats(total, free.coerceIn(0L, total))
    }.getOrNull()?.takeIf { it.totalBytes > 0L }

    fun saveSettings(settings: KotlinSettings, showNotice: Boolean = true) {
        val normalized = settings.copy(
            concurrency = settings.concurrency.toIntOrNull()?.coerceIn(1, 30)?.toString() ?: "5",
            threads = settings.threads.toIntOrNull()?.coerceIn(1, 32)?.toString() ?: "16",
            retries = settings.retries.toIntOrNull()?.coerceIn(0, 10)?.toString() ?: "3",
            speedLimit = settings.speedLimit.trim().let { value ->
                if (value.isBlank()) "" else value.toDoubleOrNull()?.coerceAtLeast(0.0)?.toString() ?: ""
            },
            outputPath = settings.outputPath.ifBlank { defaultOutputPath },
            sftpKnownHostsPath = settings.sftpKnownHostsPath.trim(),
        )
        prefs.edit()
            .putString("concurrency", normalized.concurrency)
            .putString("threads", normalized.threads)
            .putString("retries", normalized.retries)
            .putString("speedLimit", normalized.speedLimit)
            .putString("outputPath", normalized.outputPath)
            .putString("sftpKnownHostsPath", normalized.sftpKnownHostsPath)
            .apply()
        _state.value = _state.value.copy(settings = normalized, notice = if (showNotice) "设置已保存" else _state.value.notice)
        refreshStorageStats(normalized.outputPath)
    }

    /**
     * 设置输入框采用原版的即时保存方式；编辑中的空值暂不回填默认值，避免用户清空输入时光标被打断。
     * 作者: long
     */
    fun saveSettingsDraft(settings: KotlinSettings) {
        val draft = settings.copy(
            concurrency = settings.concurrency.filter(Char::isDigit),
            threads = settings.threads.filter(Char::isDigit),
            retries = settings.retries.filter(Char::isDigit),
            speedLimit = settings.speedLimit.filter { it.isDigit() || it == '.' },
            outputPath = settings.outputPath.ifBlank { defaultOutputPath },
            sftpKnownHostsPath = settings.sftpKnownHostsPath.trim(),
        )
        prefs.edit()
            .putString("concurrency", draft.concurrency)
            .putString("threads", draft.threads)
            .putString("retries", draft.retries)
            .putString("speedLimit", draft.speedLimit)
            .putString("outputPath", draft.outputPath)
            .putString("sftpKnownHostsPath", draft.sftpKnownHostsPath)
            .apply()
        _state.value = _state.value.copy(settings = draft)
    }

    private fun mutateTask(task: QueueTask, mutation: () -> String, onSuccess: () -> Unit = {}) {
        viewModelScope.launch(Dispatchers.IO) {
            val result = mutation()
            val message = parseError(result)
            withContext(Dispatchers.Main) {
                _state.value = _state.value.copy(notice = message)
            }
            if (message == null) onSuccess()
            refreshOnce()
            // 作者: long
            // reset 会把已完成任务重新置为 queued，不能用变更前的 finished 状态阻止调度器启动；
            // 其他操作没有待运行任务时 ensureQueueRunning 会立即返回，不会重复创建运行句柄。
            if (message == null) ensureQueueRunning()
        }
    }

    /**
     * 从 Rust 队列读取一次真实状态。下载进度、速度和终态都以这个快照为准，UI 不维护假进度。
     * 作者: long
     */
    private suspend fun refreshOnce() {
        val result = RustCoreBridge.queueList(storePath)
        val tasks = parseTasks(result)
        postProcessFinishedHls(tasks)
        scheduleSafCopies(tasks)
        val version = if (RustCoreBridge.isLoaded) RustCoreBridge.version() else "未加载"
        val abi = if (RustCoreBridge.isLoaded) RustCoreBridge.abi() else "-"
        val notice = parseError(result) ?: RustCoreBridge.loadError
        withContext(Dispatchers.Main) {
            _state.value = _state.value.copy(
                tasks = tasks,
                isLoading = false,
                notice = notice,
                rustVersion = version,
                rustAbi = abi,
            )
        }
    }

    /**
     * 作者: long
     * Android arm64 包不携带 ffmpeg，传统 HLS 由 Rust 保留为 TS 后在这里尝试系统级转封装；
     * 只有实际生成非空 MP4 后才把 TS 删除，失败路径继续保留可播放的原始 TS。
     */
    private suspend fun postProcessFinishedHls(tasks: List<QueueTask>) {
        tasks.filter { task ->
            task.state == "finished" &&
                task.source.substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true) &&
                !task.hlsKeepTransportStream &&
                !task.hlsRemuxedToMp4
        }.forEach { task ->
            if (!hlsRemuxInFlight.add(task.id)) return@forEach
            try {
                val source = File(task.outputDir, task.name)
                if (!source.isFile || !source.name.endsWith(".ts", ignoreCase = true)) return@forEach
                val target = File(source.parentFile, source.name.dropLast(3) + ".mp4")
                val result = withContext(Dispatchers.IO) {
                    AndroidHlsRemuxer.remuxTransportStream(source, target)
                }
                if (result.isSuccess && target.isFile && target.length() > 0L) {
                    runCatching { source.delete() }
                } else {
                    Log.w("FluxDownHlsRemux", "传统 HLS TS 转 MP4 失败: ${result.exceptionOrNull()?.message ?: "未知错误"}")
                }
            } finally {
                hlsRemuxInFlight.remove(task.id)
            }
        }
    }

    /**
     * 只唤起前台服务，不在 Activity 生命周期中持有 Rust runner。
     * 作者: long
     * 这样 UI 进程重建、切到后台或被系统回收时，下载执行仍由可恢复的服务负责。
     */
    private suspend fun ensureQueueRunning() {
        val snapshot = parseTasks(RustCoreBridge.queueList(storePath))
        if (snapshot.none { it.state == "queued" || it.state == "running" }) return
        startForegroundMonitor(DownloadForegroundService.ACTION_START)
        withContext(Dispatchers.Main) {
            _state.value = _state.value.copy(notice = "Rust 下载队列已交给后台服务")
        }
    }

    private fun startForegroundMonitor(action: String) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            _state.value = _state.value.copy(notificationPermissionRequest = true)
        }
        val intent = Intent(context, DownloadForegroundService::class.java).apply {
            this.action = action
            putExtra(DownloadForegroundService.EXTRA_STORE_PATH, storePath)
        }
        runCatching { ContextCompat.startForegroundService(context, intent) }
    }

    private fun isTreeUri(path: String): Boolean = path.trim().startsWith("content://")

    private fun taskIdForOutput(outputPath: String): String? =
        outputPath.takeIf(::isTreeUri)?.let { "android-${UUID.randomUUID()}" }

    private fun rustOutputPath(outputPath: String, taskId: String?): String {
        if (taskId == null) return outputPath
        return File(safStagingRoot, taskId).apply { mkdirs() }.absolutePath
    }

    private fun rememberSafTarget(taskId: String, target: String) {
        safTargetPrefs.edit()
            .putString("target:$taskId", target)
            .putString("state:$taskId", "pending")
            .apply()
    }

    private fun markSafPending(taskId: String) {
        if (safTargetPrefs.contains("target:$taskId")) {
            safTargetPrefs.edit().putString("state:$taskId", "pending").remove("files:$taskId").apply()
        }
    }

    private fun forgetSafTarget(taskId: String) {
        safTargetPrefs.edit().remove("target:$taskId").remove("state:$taskId").remove("files:$taskId").apply()
        runCatching { File(safStagingRoot, taskId).deleteRecursively() }
    }

    /**
     * 队列状态仍由 Rust 决定；这里仅在完成态触发一次 SAF 文件复制，不把“已下载到私有目录”冒充“已保存到用户目录”。
     * 作者: long
     */
    private fun scheduleSafCopies(tasks: List<QueueTask>) {
        tasks.filter { it.state == "finished" }.forEach { task ->
            val target = safTargetPrefs.getString("target:${task.id}", null) ?: return@forEach
            if (safTargetPrefs.getString("state:${task.id}", "pending") == "copied") return@forEach
            if (!safCopyInFlight.add(task.id)) return@forEach
            viewModelScope.launch(Dispatchers.IO) {
                val result = copyTaskToSaf(task, target)
                safCopyInFlight.remove(task.id)
                if (result.isSuccess) {
                    val relativePaths = result.getOrThrow()
                    safTargetPrefs.edit()
                        .putString("files:${task.id}", JSONArray(relativePaths).toString())
                        .putString("state:${task.id}", "copied")
                        .apply()
                    withContext(Dispatchers.Main) {
                        _state.value = _state.value.copy(notice = "下载完成，已保存到系统目录")
                    }
                } else {
                    withContext(Dispatchers.Main) {
                        _state.value = _state.value.copy(notice = "下载已完成，但保存到系统目录失败：${result.exceptionOrNull()?.message ?: "未知复制错误"}")
                    }
                }
            }
        }
    }

    private fun copyTaskToSaf(task: QueueTask, target: String): Result<List<String>> = runCatching {
        val sourceRoot = File(task.outputDir)
        require(sourceRoot.isDirectory) { "暂存目录不存在" }
        val destinationRoot = DocumentFile.fromTreeUri(context, Uri.parse(target))
        require(destinationRoot?.isDirectory == true && destinationRoot.canWrite()) { "目录权限已失效" }
        val files = sourceRoot.walkTopDown()
            .filter { file ->
                file.isFile &&
                    !file.name.endsWith(".part") &&
                    !file.path.split(File.separatorChar).any { it.startsWith(".") }
            }
            .toList()
        require(files.isNotEmpty()) { "暂存目录没有可复制的文件" }
        files.map { source ->
            val relative = source.relativeTo(sourceRoot).invariantSeparatorsPath
            val components = relative.split('/').filter { it.isNotBlank() }
            require(components.isNotEmpty()) { "文件名无效" }
            val parent = components.dropLast(1).fold(destinationRoot) { current, name ->
                current.findFile(name)?.takeIf { it.isDirectory }
                    ?: current.createDirectory(name)
                    ?: error("无法创建目录 $name")
            }
            val name = components.last()
            parent.findFile(name)?.delete()
            val mime = URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"
            val destination = parent.createFile(mime, name) ?: error("无法创建文件 $name")
            context.contentResolver.openOutputStream(destination.uri, "wt")?.use { output ->
                FileInputStream(source).use { input -> input.copyTo(output) }
            } ?: error("无法打开目标文件 $name")
            relative
        }
    }

    companion object {
        fun factory(context: Context): ViewModelProvider.Factory =
            object : ViewModelProvider.Factory {
                @Suppress("UNCHECKED_CAST")
                override fun <T : ViewModel> create(modelClass: Class<T>): T =
                    NativeViewModel(context.applicationContext) as T
            }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun FluxDownApp(model: NativeViewModel) {
    val state by model.state.collectAsStateCompat()
    val context = LocalContext.current
    var showNewTask by rememberSaveable { mutableStateOf(false) }
    var showExitConfirm by rememberSaveable { mutableStateOf(false) }
    // 作者: long
    // 一级页面返回只退出当前 Activity；Rust 队列和前台服务继续负责已入队任务，避免用户误触返回键时中断下载。
    BackHandler {
        showExitConfirm = true
    }
    val notificationPermissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        model.clearNotificationPermissionRequest()
        // 作者: long
        // Android 首次授权通知后，之前被系统暂缓的前台服务不会自动重试；刷新会重新检查队列并唤起 runner。
        model.refresh()
    }
    val outputDirectoryLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri?.let(model::selectOutputDirectory)
    }
    val knownHostsLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(model::importSftpKnownHosts)
    }

    androidx.compose.runtime.LaunchedEffect(state.notificationPermissionRequest) {
        if (state.notificationPermissionRequest && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    Scaffold(
        bottomBar = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color.White)
                    .navigationBarsPadding(),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().height(54.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BottomNavItem(
                        selected = state.selectedTab == HomeTab.Tasks,
                        icon = if (state.selectedTab == HomeTab.Tasks) Icons.Default.Download else Icons.Outlined.DownloadOutlined,
                        label = "任务",
                        onClick = { model.selectTab(HomeTab.Tasks) },
                        modifier = Modifier.weight(1f),
                    )
                    BottomNavItem(
                        selected = state.selectedTab == HomeTab.Settings,
                        icon = if (state.selectedTab == HomeTab.Settings) Icons.Default.Settings else Icons.Outlined.SettingsOutlined,
                        label = "设置",
                        onClick = { model.selectTab(HomeTab.Settings) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        },
        floatingActionButton = {
            if (state.selectedTab == HomeTab.Tasks) {
                FloatingActionButton(
                    onClick = { showNewTask = true },
                    containerColor = MaterialTheme.colorScheme.primary,
                ) {
                    Icon(Icons.Default.Add, contentDescription = "新建任务")
                }
            }
        },
        containerColor = Color(0xFFF4F8FC),
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            state.notice?.let { notice ->
                Text(
                    text = notice,
                    modifier = Modifier.fillMaxWidth().background(Color(0xFFE8F3FB)).padding(horizontal = 16.dp, vertical = 8.dp),
                    color = Color(0xFF17658F),
                    fontSize = 12.sp,
                )
            }
            when (state.selectedTab) {
                HomeTab.Tasks -> QueueScreen(state, model)
                HomeTab.Settings -> SettingsScreen(
                    state,
                    model,
                    onChooseOutputDirectory = { outputDirectoryLauncher.launch(null) },
                    onChooseKnownHosts = { knownHostsLauncher.launch(arrayOf("text/*", "application/octet-stream")) },
                )
            }
        }
    }

    if (showNewTask) {
        NewTaskDialog(
            defaultOutputPath = state.settings.outputPath,
            storageStats = state.storageStats,
            storageLoading = state.storageLoading,
            storageUnavailable = state.storageUnavailable,
            onDismiss = { showNewTask = false },
            onChooseOutputDirectory = { outputDirectoryLauncher.launch(null) },
            credentialReferences = state.credentialReferences,
            hlsVariants = state.hlsVariants,
            hlsVariantsSource = state.hlsVariantsSource,
            hlsVariantsLoading = state.hlsVariantsLoading,
            onLoadHlsVariants = model::loadHlsVariants,
            onConfirm = { source, fileName, outputPath, credentialRef, expectedSha256, hlsVariantIndex, hlsKeepTransportStream ->
                showNewTask = false
                model.addTask(source, fileName, outputPath, credentialRef, expectedSha256, hlsVariantIndex, hlsKeepTransportStream)
            },
        )
    }

    state.updateReport?.let { report ->
        UpdateResultDialog(
            report = report,
            onDismiss = model::clearUpdateReport,
            onDownload = report.downloadUrl?.let { url -> { model.clearUpdateReport(); model.openExternalUrl(url) } },
            onOpenRelease = { model.clearUpdateReport(); model.openExternalUrl(report.releaseUrl) },
        )
    }

    state.torrentSelection?.let { selection ->
        TorrentSelectionDialog(
            selection = selection,
            isConfirming = state.isConfirmingTorrent,
            onDismiss = model::cancelTorrentSelection,
            onConfirm = { selected -> model.confirmTorrentSelection(selection, selected) },
        )
    }

    state.torrentDetail?.let { selection ->
        val task = state.torrentDetailTask
        TorrentDetailsDialog(
            selection = selection,
            onDismiss = model::closeTorrentDetails,
            onOpenFile = task?.takeIf { it.state == "finished" }?.let { current ->
                { file -> model.openTorrentFile(current, file) }
            },
            onShareFile = task?.takeIf { it.state == "finished" }?.let { current ->
                { file -> model.shareTorrentFile(current, file) }
            },
        )
    }

    state.actionTask?.let { task ->
        TaskActionsDialog(
            task = task,
            onDismiss = model::closeTaskActions,
            onPause = { model.closeTaskActions(); model.pause(task) },
            onResume = { model.closeTaskActions(); model.resume(task) },
            onRetry = { model.closeTaskActions(); model.reset(task) },
            onOpen = { model.openTask(task) },
            onShare = { model.shareTask(task) },
            onCopySource = { model.copySource(task) },
            onDetails = {
                model.closeTaskActions()
                if (task.isTorrentResource) model.showTorrentDetails(task)
            },
            onRemove = { model.closeTaskActions(); model.remove(task) },
        )
    }

    if (showExitConfirm) {
        AlertDialog(
            onDismissRequest = { showExitConfirm = false },
            title = { Text("退出 FluxDown", fontSize = 16.sp) },
            text = { Text("退出当前界面？已加入队列的下载会继续在后台运行。", fontSize = 13.sp) },
            confirmButton = {
                TextButton(
                    onClick = {
                        showExitConfirm = false
                        (context as? ComponentActivity)?.finish()
                    },
                ) { Text("退出") }
            },
            dismissButton = {
                TextButton(onClick = { showExitConfirm = false }) { Text("取消") }
            },
        )
    }
}

@Composable
private fun BottomNavItem(
    selected: Boolean,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val contentColor = if (selected) Color(0xFF168BD1) else Color.Black
    Box(
        modifier = modifier
            .height(54.dp)
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
                onClick = onClick,
            ),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .width(64.dp)
                .height(54.dp),
            contentAlignment = Alignment.Center,
        ) {
            // 作者: long
            // TabBar 的文字和图标必须完整落在系统导航栏上方；扩大安全容器后再整体下移，避免文字底部被父布局裁掉。
            Column(
                modifier = Modifier.offset(y = 10.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Icon(icon, contentDescription = label, tint = contentColor, modifier = Modifier.size(18.dp))
                Text(
                    label,
                    color = contentColor,
                    fontSize = 10.5.sp,
                    lineHeight = 10.5.sp,
                    fontWeight = FontWeight.Normal,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

private enum class AndroidQueueFilter { All, Unfinished, Ended, Failed }

@Composable
private fun QueueScreen(state: NativeUiState, model: NativeViewModel) {
    var selectedFilter by rememberSaveable { mutableStateOf(AndroidQueueFilter.All) }
    val visibleTasks = state.tasks.filter { task ->
        when (selectedFilter) {
            AndroidQueueFilter.All -> true
            AndroidQueueFilter.Unfinished -> task.state in setOf("running", "queued", "paused")
            AndroidQueueFilter.Ended -> task.state in setOf("finished", "handed-off")
            AndroidQueueFilter.Failed -> task.state == "failed"
        }
    }
    Column(Modifier.fillMaxSize()) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("任务", fontSize = 18.sp, fontWeight = FontWeight.Normal, color = Color(0xFF20252B), modifier = Modifier.weight(1f))
            IconButton(onClick = model::refresh, modifier = Modifier.size(34.dp)) {
                Icon(Icons.Default.Refresh, contentDescription = "刷新", tint = Color(0xFF0F6FA8), modifier = Modifier.size(18.dp))
            }
        }
        QueueFilterStrip(
            selected = selectedFilter,
            counts = mapOf(
                AndroidQueueFilter.All to state.tasks.size,
                AndroidQueueFilter.Unfinished to state.tasks.count { it.state in setOf("running", "queued", "paused") },
                AndroidQueueFilter.Ended to state.tasks.count { it.state in setOf("finished", "handed-off") },
                AndroidQueueFilter.Failed to state.tasks.count { it.state == "failed" },
            ),
            onSelected = { selectedFilter = it },
        )
        if (visibleTasks.isEmpty()) {
            EmptyQueue()
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 88.dp),
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                items(visibleTasks, key = { it.id }) { task -> TaskRow(task, model) }
            }
        }
    }
}

@Composable
private fun QueueFilterStrip(
    selected: AndroidQueueFilter,
    counts: Map<AndroidQueueFilter, Int>,
    onSelected: (AndroidQueueFilter) -> Unit,
) {
    val labels = mapOf(
        AndroidQueueFilter.All to "全部",
        AndroidQueueFilter.Unfinished to "未完成",
        AndroidQueueFilter.Ended to "已结束",
        AndroidQueueFilter.Failed to "失败",
    )
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp)
            .height(34.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(Color(0xFFE8F5FC))
            .padding(2.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        AndroidQueueFilter.values().forEach { filter ->
            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxSize()
                    .clip(RoundedCornerShape(6.dp))
                    .background(if (filter == selected) Color(0xFF168BD1) else Color.Transparent)
                    .clickable { onSelected(filter) },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    "${labels.getValue(filter)}(${counts[filter] ?: 0})",
                    color = if (filter == selected) Color.White else Color(0xFF20252B),
                    fontSize = 10.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun EmptyQueue() {
    Column(
        modifier = Modifier.fillMaxSize().padding(start = 16.dp, end = 16.dp, bottom = 88.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            colors = CardDefaults.cardColors(containerColor = Color.White),
            shape = RoundedCornerShape(8.dp),
            border = BorderStroke(1.dp, Color(0x2A168BD1)),
        ) {
            Column(
                Modifier.fillMaxWidth().padding(vertical = 30.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.size(42.dp).clip(RoundedCornerShape(8.dp)).background(Color(0xFFE8F5FC)), contentAlignment = Alignment.Center) {
                    Icon(Icons.Default.Download, contentDescription = null, tint = Color(0xFF168BD1), modifier = Modifier.size(22.dp))
                }
                Spacer(Modifier.height(10.dp))
                Text("还没有下载任务", color = Color(0xFF20252B), fontSize = 14.sp)
                Text("点击右下角按钮添加链接", color = Color(0xFF687782), fontSize = 11.sp)
            }
        }
    }
}

@Composable
@OptIn(ExperimentalFoundationApi::class)
private fun TaskRow(task: QueueTask, model: NativeViewModel) {
    val (tint, background, border, progressFill) = when (task.state) {
        "finished", "handed-off" -> listOf(Color(0xFF2E8B57), Color(0xFFF1FBF5), Color(0x4A2E8B57), Color.Transparent)
        "failed" -> listOf(Color(0xFFC64B4B), Color(0xFFFFF5F5), Color(0x4AC64B4B), Color.Transparent)
        "paused" -> listOf(Color(0xFFB7791F), Color(0xFFFFFAF0), Color(0x4AB7791F), Color.Transparent)
        else -> listOf(Color(0xFF168BD1), Color(0xFFF7FCFF), Color(0x4A168BD1), Color(0xB89DD8F5))
    }
    Card(
        modifier = Modifier.fillMaxWidth().combinedClickable(
            onClick = {
                if (task.isTorrentResource) {
                    model.showTorrentDetails(task)
                } else if (task.state == "paused") {
                    model.resume(task)
                } else if (task.state == "running") {
                    model.pause(task)
                }
            },
            onLongClick = {
                model.showTaskActions(task)
            },
        ),
        colors = CardDefaults.cardColors(containerColor = background),
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, border),
    ) {
        BoxWithConstraints {
            if (task.state == "running" && task.progress > 0f) {
                Box(
                    Modifier
                        .width(maxWidth * task.progress)
                        .matchParentSize()
                        .background(progressFill),
                )
            }
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    Modifier.size(25.dp).clip(RoundedCornerShape(7.dp)).background(Color.White.copy(alpha = 0.76f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (task.isTorrentResource) Icons.Default.FolderOpen else Icons.Default.Download,
                        contentDescription = null,
                        tint = tint,
                        modifier = Modifier.size(14.dp),
                    )
                }
                Spacer(Modifier.width(8.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            task.displayName,
                            modifier = Modifier.weight(1f),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                            fontSize = 12.sp,
                            lineHeight = 14.sp,
                            color = Color(0xFF20252B),
                        )
                        Spacer(Modifier.width(5.dp))
                        Surface(color = tint.copy(alpha = 0.14f), shape = RoundedCornerShape(5.dp)) {
                            Text(
                                "${task.stateLabel()} ${(task.progress * 100).toInt()}%",
                                color = tint,
                                fontSize = 9.5.sp,
                                modifier = Modifier.padding(horizontal = 5.dp, vertical = 2.dp),
                                maxLines = 1,
                            )
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "${formatBytes(task.downloadedBytes)}/${task.totalBytes?.let(::formatBytes) ?: "未知"}",
                            fontSize = 10.sp,
                            color = Color(0xFF687782),
                        )
                        Spacer(Modifier.weight(1f))
                        if (task.state == "running") {
                            Text(
                                "速度 ${formatBytes(task.speedBytesPerSecond)}/s",
                                fontSize = 10.sp,
                                color = Color(0xFF687782),
                            )
                        } else if (task.state == "finished") {
                            Text(
                                task.finishedAtMs?.let { "完成 ${formatTaskTime(it)}" } ?: "已完成",
                                fontSize = 10.sp,
                                color = tint,
                                maxLines = 1,
                            )
                        } else if (task.state == "failed") {
                            Text("下载失败", fontSize = 10.sp, color = tint)
                        }
                    }
                    if (task.state == "failed" && !task.error.isNullOrBlank()) {
                        Text(task.error, color = Color(0xFFB64646), fontSize = 9.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

@Composable
private fun TaskActionsDialog(
    task: QueueTask,
    onDismiss: () -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRetry: () -> Unit,
    onOpen: () -> Unit,
    onShare: () -> Unit,
    onCopySource: () -> Unit,
    onDetails: () -> Unit,
    onRemove: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("任务操作", fontSize = 17.sp, fontWeight = FontWeight.Medium) },
        text = {
            Column(Modifier.fillMaxWidth()) {
                Text(task.displayName, maxLines = 2, overflow = TextOverflow.Ellipsis, fontSize = 12.sp, color = Color(0xFF687782))
                Spacer(Modifier.height(8.dp))
                if (task.state == "running") {
                    TaskActionButton(Icons.Default.Pause, "暂停", onPause)
                } else if (task.state == "paused") {
                    TaskActionButton(Icons.Default.PlayArrow, "继续", onResume)
                }
                if (task.state == "failed") {
                    TaskActionButton(Icons.Default.Refresh, "重试", onRetry)
                } else if (task.state == "finished") {
                    // 作者: long
                    // 完成任务重新运行需要清理旧断点并重新请求源文件；单独使用“重新下载”文案，避免和失败任务的“重试”混淆。
                    TaskActionButton(Icons.Default.Refresh, "重新下载", onRetry)
                }
                val selectedTorrentFiles = task.torrentFiles.count {
                    task.torrentFileIndices.isEmpty() || it.index in task.torrentFileIndices
                }
                if (task.state == "finished" && selectedTorrentFiles <= 1) {
                    TaskActionButton(Icons.Default.OpenInNew, "打开文件", onOpen)
                    TaskActionButton(Icons.Default.Share, "分享文件", onShare)
                }
                if (task.isTorrentResource) {
                    TaskActionButton(Icons.Default.FolderOpen, "资源详情", onDetails)
                }
                TaskActionButton(Icons.Default.ContentCopy, "复制下载链接", onCopySource)
                TaskActionButton(Icons.Default.DeleteOutline, "删除任务", onRemove, destructive = true)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("关闭") } },
    )
}

@Composable
private fun TaskActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    onClick: () -> Unit,
    destructive: Boolean = false,
) {
    TextButton(onClick = onClick, modifier = Modifier.fillMaxWidth()) {
        Icon(icon, contentDescription = null, tint = if (destructive) Color(0xFFC64B4B) else MaterialTheme.colorScheme.primary)
        Spacer(Modifier.width(10.dp))
        Text(label, modifier = Modifier.weight(1f), color = if (destructive) Color(0xFFC64B4B) else Color(0xFF2C3E50))
    }
}

@Composable
private fun SettingsScreen(
    state: NativeUiState,
    model: NativeViewModel,
    onChooseOutputDirectory: () -> Unit,
    onChooseKnownHosts: () -> Unit,
) {
    val context = LocalContext.current
    var settings by remember(state.settings) { mutableStateOf(state.settings) }
    var showCredentialEditor by rememberSaveable { mutableStateOf(false) }
    var credentialToDelete by rememberSaveable { mutableStateOf<String?>(null) }
    fun updateSettings(next: KotlinSettings) {
        settings = next
        model.saveSettingsDraft(next)
    }
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 88.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Text("设置", fontSize = 18.sp, fontWeight = FontWeight.Normal, color = Color(0xFF20252B), modifier = Modifier.padding(bottom = 6.dp))
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = Color.White),
                shape = RoundedCornerShape(8.dp),
                border = BorderStroke(1.dp, Color(0x2A168BD1)),
            ) {
                Column(Modifier.fillMaxWidth()) {
                    SettingsCompactRow(
                        icon = Icons.Default.FolderOpen,
                        title = "保存位置",
                        subtitle = formatOutputLocation(context, settings.outputPath),
                        trailing = {
                            IconButton(onClick = onChooseOutputDirectory, modifier = Modifier.size(38.dp)) {
                                Icon(Icons.Default.FolderOpen, contentDescription = "选择系统目录", tint = Color(0xFF3F4B55), modifier = Modifier.size(18.dp))
                            }
                        },
                    )
                    Box(Modifier.padding(horizontal = 8.dp, vertical = 5.dp)) {
                        StorageStatsPanel(
                            stats = state.storageStats,
                            loading = state.storageLoading,
                            unavailable = state.storageUnavailable,
                        )
                    }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Download, "最大并发", "同时运行任务数", settings.concurrency, "个") { updateSettings(settings.copy(concurrency = it)) }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Settings, "最大下载线程", "单任务线程数", settings.threads, "线程") { updateSettings(settings.copy(threads = it)) }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Replay, "自动重试次数", "失败重试 0-10，0 不重试", settings.retries, "次") { updateSettings(settings.copy(retries = it)) }
                    SettingsDivider()
                    SettingsValueRow(Icons.Default.Speed, "最大下载网速", "MB/s，留空不限速", settings.speedLimit, "", placeholder = "不限速") { updateSettings(settings.copy(speedLimit = it)) }

                    // 作者: long
                    // 凭据、SFTP 和版本信息仍保留在同一张设置卡中，但放在下载参数后面，首屏先突出高频下载配置。
                    SettingsDivider()
                    SettingsCompactRow(
                        icon = Icons.Default.Key,
                        title = "安全凭据",
                        subtitle = if (state.credentialReferences.isEmpty()) "密码和私钥仅保存在 Android Keystore" else "已保存 ${state.credentialReferences.size} 个凭据引用",
                        trailing = {
                            IconButton(onClick = { showCredentialEditor = true }, modifier = Modifier.size(38.dp)) {
                                Icon(Icons.Default.Add, contentDescription = "添加凭据", tint = Color(0xFF0F6FA8), modifier = Modifier.size(18.dp))
                            }
                        },
                    )
                    state.credentialReferences.forEach { reference ->
                        Row(Modifier.fillMaxWidth().padding(start = 42.dp, end = 10.dp, top = 1.dp, bottom = 1.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Security, contentDescription = null, tint = Color(0xFF168BD1), modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(reference, modifier = Modifier.weight(1f), fontSize = 10.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            IconButton(onClick = { credentialToDelete = reference }, modifier = Modifier.size(30.dp)) {
                                Icon(Icons.Default.DeleteOutline, contentDescription = "删除凭据", tint = Color(0xFFC64B4B), modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                    SettingsDivider()
                    SettingsCompactRow(
                        icon = Icons.Default.Security,
                        title = "SFTP 主机密钥",
                        subtitle = if (settings.sftpKnownHostsPath.isBlank()) "未配置，使用 SSH 库默认策略" else "已配置 known_hosts",
                        trailing = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                IconButton(onClick = onChooseKnownHosts, modifier = Modifier.size(34.dp)) {
                                    Icon(Icons.Default.FolderOpen, contentDescription = "导入 known_hosts", tint = Color(0xFF0F6FA8), modifier = Modifier.size(17.dp))
                                }
                                if (settings.sftpKnownHostsPath.isNotBlank()) {
                                    IconButton(onClick = { model.clearSftpKnownHosts() }, modifier = Modifier.size(34.dp)) {
                                        Icon(Icons.Default.DeleteOutline, contentDescription = "清除主机密钥", tint = Color(0xFFC64B4B), modifier = Modifier.size(17.dp))
                                    }
                                }
                            }
                        },
                    )
                    SettingsDivider()
                    SettingsCompactRow(
                        icon = Icons.Default.Info,
                        title = "当前版本",
                        subtitle = "v$KOTLIN_APP_VERSION · Rust ${state.rustVersion}",
                        trailing = {
                            if (state.updateChecking) {
                                androidx.compose.material3.CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                            } else {
                                IconButton(onClick = model::checkForUpdates, modifier = Modifier.size(38.dp)) {
                                    Icon(Icons.Default.SystemUpdateAlt, contentDescription = "检查更新", tint = Color(0xFF0F6FA8), modifier = Modifier.size(17.dp))
                                }
                            }
                        },
                    )
                }
            }
        }
    }

    if (showCredentialEditor) {
        CredentialEditorDialog(
            onDismiss = { showCredentialEditor = false },
            onSave = { reference, credential ->
                showCredentialEditor = false
                model.saveCredential(reference, credential)
            },
        )
    }
    credentialToDelete?.let { reference ->
        AlertDialog(
            onDismissRequest = { credentialToDelete = null },
            title = { Text("删除凭据", fontSize = 16.sp) },
            text = { Text("确定删除“$reference”吗？使用该引用的任务将在下次运行时提示凭据不可用。", fontSize = 13.sp) },
            confirmButton = {
                TextButton(onClick = { credentialToDelete = null; model.deleteCredential(reference) }) { Text("删除") }
            },
            dismissButton = { TextButton(onClick = { credentialToDelete = null }) { Text("取消") } },
        )
    }
}

@Composable
private fun StorageStatsPanel(
    stats: AndroidStorageStats?,
    loading: Boolean,
    unavailable: Boolean,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = Color(0xFFF4F8FC)),
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, Color(0xFFCFDCE6)),
    ) {
        if (loading && stats == null) {
            Text("正在读取存储容量…", modifier = Modifier.padding(10.dp), fontSize = 11.sp, color = Color(0xFF74838D))
        } else if (stats == null || unavailable) {
            Text("无法读取这个路径的存储容量", modifier = Modifier.padding(10.dp), fontSize = 11.sp, color = Color(0xFF74838D))
        } else {
            Row(Modifier.fillMaxWidth().padding(4.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                StorageStatItem("总容量", formatBytes(stats.totalBytes))
                StorageStatItem("已用", formatBytes(stats.usedBytes))
                StorageStatItem("剩余", formatBytes(stats.freeBytes))
            }
        }
    }
}

@Composable
private fun RowScope.StorageStatItem(label: String, value: String) {
    Box(
        Modifier
            .weight(1f)
            .clip(RoundedCornerShape(8.dp))
            .background(Color(0xFFEAF6FD))
            .padding(horizontal = 6.dp, vertical = 4.dp),
    ) {
        Column {
            Text(label, fontSize = 9.5.sp, color = Color(0xFF74838D), maxLines = 1)
            Text(value, fontSize = 11.5.sp, color = Color(0xFF2C3E50), maxLines = 1)
        }
    }
}

@Composable
private fun SettingsCompactRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    trailing: @Composable () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(min = 46.dp)
            .padding(horizontal = 8.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
                Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(7.dp))
                .background(Color(0xFFDDECFB)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = Color(0xFF3F4B55), modifier = Modifier.size(13.dp))
        }
        Spacer(Modifier.width(7.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 11.8.sp, color = Color(0xFF20252B), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, fontSize = 10.sp, lineHeight = 10.5.sp, color = Color(0xFF687782), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(7.dp))
        trailing()
    }
}

@Composable
private fun SettingsValueRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    value: String,
    suffix: String,
    placeholder: String = "",
    onValueChange: (String) -> Unit,
) {
    SettingsCompactRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        trailing = {
            OutlinedTextField(
                value = value,
                onValueChange = onValueChange,
                modifier = Modifier.width(if (suffix.isBlank()) 76.dp else 98.dp).heightIn(min = 56.dp),
                singleLine = true,
                placeholder = { Text(placeholder, fontSize = 11.sp, color = Color(0xFF687782), maxLines = 1) },
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, textAlign = TextAlign.End, color = Color(0xFF20252B)),
                trailingIcon = if (suffix.isBlank()) null else {
                    { Text(suffix, fontSize = 10.sp, color = Color(0xFF687782), modifier = Modifier.padding(end = 6.dp)) }
                },
                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                    unfocusedContainerColor = Color.White,
                    focusedContainerColor = Color.White,
                    unfocusedBorderColor = Color(0xFFCFE5F3),
                    focusedBorderColor = Color(0xFF168BD1),
                ),
                shape = RoundedCornerShape(12.dp),
            )
        },
    )
}

@Composable
private fun CredentialEditorDialog(
    onDismiss: () -> Unit,
    onSave: (String, StoredAndroidCredential) -> Unit,
) {
    var reference by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var privateKeyPem by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var usePrivateKey by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("添加安全凭据", fontSize = 16.sp) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                OutlinedTextField(reference, { reference = it }, label = { Text("凭据引用") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(username, { username = it }, label = { Text("用户名") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = usePrivateKey, onCheckedChange = { usePrivateKey = it })
                    Text("SFTP 私钥认证", fontSize = 12.sp)
                }
                if (usePrivateKey) {
                    OutlinedTextField(privateKeyPem, { privateKeyPem = it }, label = { Text("私钥内容（PEM）") }, minLines = 4, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(passphrase, { passphrase = it }, label = { Text("私钥口令（可选）") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                } else {
                    OutlinedTextField(password, { password = it }, label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                }
                error?.let { Text(it, color = Color(0xFFC64B4B), fontSize = 11.sp) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val normalizedReference = reference.trim()
                val normalizedUsername = username.trim()
                error = when {
                    normalizedReference.isEmpty() -> "请输入凭据引用"
                    normalizedReference.length > 128 -> "凭据引用不能超过 128 个字符"
                    normalizedUsername.isEmpty() -> "请输入用户名"
                    usePrivateKey && (!privateKeyPem.contains("PRIVATE KEY") || privateKeyPem.length > 256 * 1024) -> "请输入有效的 SFTP 私钥"
                    else -> null
                }
                if (error == null) {
                    onSave(
                        normalizedReference,
                        if (usePrivateKey) StoredAndroidCredential(normalizedUsername, privateKeyPem = privateKeyPem.trim(), passphrase = passphrase.trim().ifEmpty { null })
                        else StoredAndroidCredential(normalizedUsername, password = password),
                    )
                }
            }) { Text("保存") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("取消") } },
    )
}

@Composable
private fun UpdateResultDialog(
    report: AndroidUpdateReport,
    onDismiss: () -> Unit,
    onDownload: (() -> Unit)?,
    onOpenRelease: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(if (report.hasUpdate) "找到最新版本 ${report.latestVersion}" else "已是最新版本", fontSize = 16.sp) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("当前版本：${report.currentVersion}", fontSize = 12.sp, color = Color(0xFF687782))
                report.releaseNotes?.takeIf { it.isNotBlank() }?.let {
                    Text("更新说明", fontSize = 12.sp, color = Color(0xFF31566E))
                    Text(it, fontSize = 11.sp, color = Color(0xFF687782), maxLines = 8, overflow = TextOverflow.Ellipsis)
                }
            }
        },
        confirmButton = {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                if (report.hasUpdate && onDownload != null) TextButton(onClick = onDownload) { Text("下载更新") }
                TextButton(onClick = onOpenRelease) { Text("打开下载页") }
                TextButton(onClick = onDismiss) { Text("确定") }
            }
        },
    )
}

@Composable
private fun SettingsSection(title: String, content: @Composable () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        shape = RoundedCornerShape(12.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(14.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color(0xFF31566E))
            Spacer(Modifier.height(10.dp))
            content()
        }
    }
}

@Composable
private fun SettingsGroupTitle(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(24.dp).clip(RoundedCornerShape(7.dp)).background(Color(0xFFE8F5FC)), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = Color(0xFF168BD1), modifier = Modifier.size(14.dp))
        }
        Spacer(Modifier.width(7.dp))
        Text(title, fontSize = 11.sp, color = Color(0xFF0F6FA8), fontWeight = FontWeight.Normal)
    }
}

@Composable
private fun SettingsDivider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0xFFE5EEF4)))
}

@Composable
private fun SettingField(label: String, value: String, hint: String, onValueChange: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 13.sp, color = Color(0xFF20252B))
            Text(hint, fontSize = 9.5.sp, color = Color(0xFF687782), maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(10.dp))
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.widthIn(min = 78.dp, max = 108.dp).height(44.dp),
            singleLine = true,
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, color = Color(0xFF20252B)),
            placeholder = { Text("不限", fontSize = 11.sp, color = Color(0xFF9AA8B2)) },
        )
    }
}

@Composable
private fun NewTaskDialog(
    defaultOutputPath: String,
    storageStats: AndroidStorageStats?,
    storageLoading: Boolean,
    storageUnavailable: Boolean,
    credentialReferences: List<String>,
    hlsVariants: List<HlsVariantOption>,
    hlsVariantsSource: String?,
    hlsVariantsLoading: Boolean,
    onLoadHlsVariants: (String) -> Unit,
    onChooseOutputDirectory: () -> Unit,
    onDismiss: () -> Unit,
    onConfirm: (String, String, String, String?, String, Int?, Boolean) -> Unit,
) {
    var source by remember { mutableStateOf("") }
    var fileName by remember { mutableStateOf("") }
    var outputPath by remember { mutableStateOf(defaultOutputPath) }
    var credentialRef by remember { mutableStateOf<String?>(null) }
    var credentialMenuExpanded by remember { mutableStateOf(false) }
    var expectedSha256 by remember { mutableStateOf("") }
    var hlsVariant by remember { mutableStateOf("") }
    var hlsKeepTransportStream by remember { mutableStateOf(false) }
    var showScanner by rememberSaveable { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val isHlsSource = source.trim().substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true)
    val hlsVariantIndex = hlsVariant.trim().takeIf { it.isNotEmpty() }?.toIntOrNull()
    val hlsVariantError = hlsVariant.trim().isNotEmpty() && (hlsVariantIndex == null || hlsVariantIndex < 0)
    val detectedProtocol = remember(source) {
        source.trim().takeIf { it.isNotEmpty() }?.let { parseDataString(RustCoreBridge.detect(it), "protocol") } ?: "unknown"
    }
    val detectedLabel = when (detectedProtocol) {
        "http" -> "HTTP · Rust 下载引擎"
        "https" -> "HTTPS · Rust 下载引擎"
        "m3u8" -> "HLS · Rust 下载引擎"
        "torrent" -> "Torrent · Rust 元数据"
        "magnet" -> "Magnet · Rust 元数据"
        "ftp" -> "FTP · Rust 下载引擎"
        "ftps" -> "FTPS · Rust 下载引擎"
        "sftp" -> "SFTP · Rust 下载引擎"
        "ed2k" -> "ED2K · 外部接管"
        "smb" -> "SMB · Rust 下载引擎"
        "webdav", "webdavs" -> "WebDAV · Rust 下载引擎"
        else -> "等待识别链接类型"
    }
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 348.dp)
                .heightIn(max = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp * 0.86f)
                .padding(horizontal = 16.dp, vertical = 24.dp),
            shape = RoundedCornerShape(16.dp),
            color = Color(0xFFF3F6FE),
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(start = 14.dp, top = 12.dp, end = 14.dp, bottom = 14.dp),
                verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.Top,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("新建下载", fontSize = 17.sp, lineHeight = 19.sp, fontWeight = FontWeight.Normal, color = Color(0xFF20252B))
                        Spacer(Modifier.height(3.dp))
                        Text("粘贴链接后自动识别类型，确认下载即可开始。", fontSize = 11.sp, lineHeight = 14.sp, color = Color(0xFF5D646D))
                    }
                    IconButton(onClick = {
                        clipboard.getText()?.text?.trim()?.takeIf { it.isNotEmpty() }?.let { source = it }
                    }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.ContentPaste, contentDescription = "读取剪切板", tint = Color(0xFF3F4B55), modifier = Modifier.size(17.dp))
                    }
                    IconButton(onClick = { showScanner = true }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.QrCodeScanner, contentDescription = "扫描二维码", tint = Color(0xFF3F4B55), modifier = Modifier.size(17.dp))
                    }
                    IconButton(onClick = onDismiss, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.Close, contentDescription = "关闭", tint = Color(0xFF3F4B55), modifier = Modifier.size(19.dp))
                    }
                }
                OutlinedTextField(
                    value = source,
                    onValueChange = { source = it },
                    label = { Text("下载链接", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 5,
                    maxLines = 5,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, lineHeight = 14.sp, color = Color(0xFF20252B)),
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                        unfocusedContainerColor = Color.White,
                        focusedContainerColor = Color.White,
                        unfocusedBorderColor = Color(0xFFCFE5F3),
                        focusedBorderColor = Color(0xFF168BD1),
                    ),
                )
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = Color(0xFFEAF6FD)),
                    shape = RoundedCornerShape(8.dp),
                    border = BorderStroke(1.dp, Color(0x2A168BD1)),
                ) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("自动识别", fontSize = 10.5.sp, color = Color(0xFF5D646D))
                        Spacer(Modifier.width(8.dp))
                        Text(detectedLabel, modifier = Modifier.weight(1f), fontSize = 11.5.sp, color = Color(0xFF168BD1), maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Icon(Icons.Default.Check, contentDescription = null, tint = Color(0xFF168BD1), modifier = Modifier.size(15.dp))
                    }
                }
                OutlinedTextField(
                    value = fileName,
                    onValueChange = { fileName = it },
                    label = { Text("文件名", fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 4,
                    maxLines = 4,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, lineHeight = 14.sp, color = Color(0xFF20252B)),
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(unfocusedContainerColor = Color.White, focusedContainerColor = Color.White, unfocusedBorderColor = Color(0xFFCFE5F3), focusedBorderColor = Color(0xFF168BD1)),
                )
                // 作者: long
                // 没有输入需要认证的协议时不展示凭据字段，保持新建弹框首屏只聚焦链接、文件名和协议相关选项；
                // 用户输入 HTTP/FTP/SFTP 等支持凭据的链接后再展开该可选项。
                if (credentialReferences.isNotEmpty() && supportsCredentialProtocol(detectedProtocol)) {
                    Box(Modifier.fillMaxWidth()) {
                        OutlinedTextField(
                            value = credentialRef ?: "不使用凭据",
                            onValueChange = {},
                            readOnly = true,
                            label = { Text("凭据引用（可选）", fontSize = 12.sp) },
                            modifier = Modifier.fillMaxWidth().height(48.dp),
                            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(unfocusedContainerColor = Color.White, focusedContainerColor = Color.White, unfocusedBorderColor = Color(0xFFCFE5F3), focusedBorderColor = Color(0xFF168BD1)),
                        )
                        // 作者: long
                        // OutlinedTextField 会优先消费点击事件，直接给它挂 clickable 在部分真机上无法展开菜单；
                        // 用透明覆盖层承接点击，保持字段只读并让凭据引用选择稳定可用。
                        Box(
                            modifier = Modifier
                                .matchParentSize()
                                .clickable { credentialMenuExpanded = true },
                        )
                        DropdownMenu(
                            expanded = credentialMenuExpanded,
                            onDismissRequest = { credentialMenuExpanded = false },
                        ) {
                            DropdownMenuItem(
                                text = { Text("不使用凭据") },
                                onClick = { credentialRef = null; credentialMenuExpanded = false },
                            )
                            credentialReferences.forEach { reference ->
                                DropdownMenuItem(
                                    text = { Text(reference) },
                                    onClick = { credentialRef = reference; credentialMenuExpanded = false },
                                )
                            }
                        }
                    }
                }
                if (isHlsSource) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        OutlinedButton(
                            onClick = { onLoadHlsVariants(source) },
                            enabled = !hlsVariantsLoading && source.isNotBlank(),
                            modifier = Modifier.weight(1f),
                        ) {
                            Text(if (hlsVariantsLoading) "正在读取清晰度…" else "读取 HLS 清晰度", fontSize = 12.sp)
                        }
                        if (hlsVariantsSource == source.trim() && hlsVariants.isNotEmpty()) {
                            Spacer(Modifier.width(8.dp))
                            Text("${hlsVariants.size} 个", fontSize = 11.sp, color = Color(0xFF74838D))
                        }
                    }
                    if (hlsVariantsSource == source.trim() && hlsVariants.isNotEmpty()) {
                        Column(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Color(0xFFF4F8FC)).padding(8.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            hlsVariants.forEach { variant ->
                                val details = listOfNotNull(
                                    variant.resolution,
                                    variant.bandwidth.takeIf { it > 0 }?.let { "${it / 1000} kbps" },
                                    variant.codecs?.takeIf { it.isNotBlank() },
                                ).joinToString(" · ")
                                TextButton(
                                    onClick = { hlsVariant = variant.index.toString() },
                                    modifier = Modifier.fillMaxWidth(),
                                    contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                                ) {
                                    Text("#${variant.index} ${details.ifBlank { "未提供清晰度信息" }}", modifier = Modifier.weight(1f), fontSize = 11.sp)
                                }
                            }
                        }
                    }
                    OutlinedTextField(
                        value = hlsVariant,
                        onValueChange = { value -> hlsVariant = value.filter(Char::isDigit) },
                        label = { Text("HLS 清晰度编号（可选）", fontSize = 12.sp) },
                        supportingText = { Text(if (hlsVariantError) "请输入不小于 0 的编号" else "留空使用默认清晰度；从 0 开始") },
                        isError = hlsVariantError,
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(
                            checked = hlsKeepTransportStream,
                            onCheckedChange = { hlsKeepTransportStream = it },
                        )
                        Text("保留原始 TS 文件", fontSize = 12.sp, color = Color(0xFF50606C))
                    }
                }
                StorageStatsPanel(
                    stats = storageStats,
                    loading = storageLoading,
                    unavailable = storageUnavailable,
                )
                Button(
                    onClick = {
                        if (source.isNotBlank() && !hlsVariantError) {
                            onConfirm(source, fileName, outputPath, credentialRef, expectedSha256, hlsVariantIndex.takeIf { isHlsSource }, hlsKeepTransportStream && isHlsSource)
                        }
                    },
                    enabled = source.isNotBlank() && !hlsVariantError,
                    modifier = Modifier.fillMaxWidth().height(44.dp),
                    shape = RoundedCornerShape(8.dp),
                ) {
                    Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("开始下载", fontSize = 13.sp, fontWeight = FontWeight.Normal)
                }
            }
        }
    }
    if (showScanner) {
        QrScannerDialog(
            onDismiss = { showScanner = false },
            onResult = { value ->
                source = value
                showScanner = false
            },
        )
    }
}

@Composable
private fun QrScannerDialog(
    onDismiss: () -> Unit,
    onResult: (String) -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    var hasPermission by remember {
        mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
    }
    var error by remember { mutableStateOf<String?>(null) }
    val handled = remember { AtomicBoolean(false) }
    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        hasPermission = granted
        if (!granted) error = "需要相机权限才能扫描二维码"
    }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (!hasPermission) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxSize(0.86f).padding(16.dp),
            shape = RoundedCornerShape(18.dp),
            color = Color.Black,
        ) {
            if (!hasPermission) {
                Column(
                    Modifier.fillMaxSize().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                ) {
                    Text("无法打开相机", color = Color.White, fontSize = 18.sp)
                    Spacer(Modifier.height(8.dp))
                    Text(error ?: "请允许相机权限后重试", color = Color(0xFFCBD5E1), fontSize = 13.sp)
                    Spacer(Modifier.height(18.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(onClick = onDismiss) { Text("取消") }
                        Button(onClick = { permissionLauncher.launch(Manifest.permission.CAMERA) }) { Text("重新授权") }
                    }
                }
            } else {
                Box(Modifier.fillMaxSize()) {
                    val previewView = remember { PreviewView(context).apply { scaleType = PreviewView.ScaleType.FILL_CENTER } }
                    AndroidView(
                        modifier = Modifier.fillMaxSize(),
                        factory = { previewView },
                    )
                    androidx.compose.runtime.DisposableEffect(previewView, lifecycleOwner) {
                        val executor = Executors.newSingleThreadExecutor()
                        val mainExecutor = ContextCompat.getMainExecutor(context)
                        val disposed = AtomicBoolean(false)
                        val scanner = BarcodeScanning.getClient(
                            BarcodeScannerOptions.Builder()
                                .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
                                .build(),
                        )
                        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
                        val listener = Runnable {
                            runCatching {
                                val provider = cameraProviderFuture.get()
                                // 作者: long
                                // 用户快速关闭扫码弹框时，异步 provider 回调仍可能晚到；在绑定生命周期前再次检查，
                                // 防止已经释放的分析器被重新绑定到相机。
                                if (disposed.get()) return@runCatching
                                val preview = Preview.Builder().build().also { it.setSurfaceProvider(previewView.surfaceProvider) }
                                val analysis = ImageAnalysis.Builder()
                                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                    .build()
                                    analysis.setAnalyzer(executor) { imageProxy ->
                                        val mediaImage = imageProxy.image
                                    if (mediaImage == null || handled.get() || disposed.get()) {
                                            imageProxy.close()
                                            return@setAnalyzer
                                        }
                                        // 作者: long
                                        // 每次只接收第一个有效链接并立即停止回调，避免同一二维码连续创建多个下载任务。
                                        val image = InputImage.fromMediaImage(mediaImage, imageProxy.imageInfo.rotationDegrees)
                                    scanner.process(image)
                                        .addOnSuccessListener { barcodes ->
                                            if (handled.get() || disposed.get()) return@addOnSuccessListener
                                            val value = firstValidatedQrDownloadSource(
                                                barcodes.map { it.rawValue to it.displayValue },
                                            ) { candidate ->
                                                parseDataString(RustCoreBridge.detect(candidate), "protocol")
                                            }
                                            // 作者: long
                                            // ML Kit 可能识别出普通文本；只有 Rust 返回明确协议时才回填，避免 null 被误判为可下载链接。
                                            if (value != null) {
                                                if (!handled.compareAndSet(false, true)) return@addOnSuccessListener
                                                mainExecutor.execute { onResult(value) }
                                            } else if (barcodes.any { (it.rawValue ?: it.displayValue)?.trim()?.let { value -> value.isNotEmpty() && value.length <= 8192 } == true }) {
                                                mainExecutor.execute { error = "二维码内容不是可识别的下载链接" }
                                            }
                                        }
                                        .addOnFailureListener { mainExecutor.execute { error = "二维码识别失败，请保持图案完整" } }
                                        .addOnCompleteListener { imageProxy.close() }
                                }
                                provider.unbindAll()
                                provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                            }.onFailure { mainExecutor.execute { error = "相机启动失败：${it.message ?: "未知错误"}" } }
                        }
                        cameraProviderFuture.addListener(listener, ContextCompat.getMainExecutor(context))
                        onDispose {
                            disposed.set(true)
                            if (cameraProviderFuture.isDone) runCatching { cameraProviderFuture.get().unbindAll() }
                            scanner.close()
                            executor.shutdown()
                        }
                    }
                    Column(
                        Modifier.fillMaxWidth().align(Alignment.BottomCenter).padding(18.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Text("将下载链接二维码放入取景框", color = Color.White, fontSize = 13.sp)
                        Spacer(Modifier.height(10.dp))
                        OutlinedButton(onClick = onDismiss) { Text("取消") }
                    }
                }
            }
        }
    }
}

@Composable
private fun TorrentSelectionDialog(
    selection: TorrentSelection,
    isConfirming: Boolean,
    onDismiss: () -> Unit,
    onConfirm: (Set<Int>) -> Unit,
) {
    var selectedIndexes by remember(selection.files) {
        mutableStateOf(selection.files.map { it.index }.toSet())
    }
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxSize(0.88f).padding(12.dp),
            shape = RoundedCornerShape(18.dp),
            color = Color.White,
        ) {
            Column(Modifier.fillMaxSize().padding(18.dp)) {
                Text("资源详情", fontSize = 19.sp, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(4.dp))
                Text(selection.directoryName, fontSize = 14.sp, color = Color(0xFF31566E))
                selection.infoHash?.let { hash ->
                    Text("Info hash：$hash", fontSize = 10.sp, color = Color(0xFF74838D), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.height(12.dp))
                Text("选择要下载的文件（${selectedIndexes.size}/${selection.files.size}）", fontSize = 12.sp, color = Color(0xFF687782))
                Spacer(Modifier.height(6.dp))
                LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(selection.files, key = { it.index }) { file ->
                        val checked = file.index in selectedIndexes
                        Row(
                            modifier = Modifier.fillMaxWidth().clickable {
                                selectedIndexes = if (checked) selectedIndexes - file.index else selectedIndexes + file.index
                            }.padding(vertical = 7.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Checkbox(
                                checked = checked,
                                onCheckedChange = { value ->
                                    selectedIndexes = if (value) selectedIndexes + file.index else selectedIndexes - file.index
                                },
                            )
                            Spacer(Modifier.width(6.dp))
                            Column(Modifier.weight(1f)) {
                                Text(file.path, fontSize = 13.sp)
                                Text(
                                    "${file.name.substringAfterLast('.', "文件").uppercase()} · ${formatBytes(file.size)}",
                                    fontSize = 11.sp,
                                    color = Color(0xFF74838D),
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    OutlinedButton(onClick = onDismiss, enabled = !isConfirming) { Text("取消") }
                    Spacer(Modifier.width(8.dp))
                    Button(onClick = { onConfirm(selectedIndexes) }, enabled = selectedIndexes.isNotEmpty() && !isConfirming) {
                        Text("确认并加入")
                    }
                }
            }
        }
    }
}

@Composable
private fun TorrentDetailsDialog(
    selection: TorrentSelection,
    onDismiss: () -> Unit,
    onOpenFile: ((TorrentFileSelection) -> Unit)?,
    onShareFile: ((TorrentFileSelection) -> Unit)?,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier.fillMaxWidth().fillMaxSize(0.88f).padding(12.dp),
            shape = RoundedCornerShape(18.dp),
            color = Color.White,
        ) {
            Column(Modifier.fillMaxSize().padding(18.dp)) {
                Text("资源详情", fontSize = 19.sp, fontWeight = FontWeight.Medium)
                Spacer(Modifier.height(4.dp))
                Text(
                    selection.directoryName,
                    fontSize = 14.sp,
                    color = Color(0xFF31566E),
                )
                selection.infoHash?.let { hash ->
                    Text("Info hash：$hash", fontSize = 10.sp, color = Color(0xFF74838D), maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                Spacer(Modifier.height(12.dp))
                Text("已确认文件（${selection.files.size}）", fontSize = 12.sp, color = Color(0xFF687782))
                Spacer(Modifier.height(6.dp))
                LazyColumn(
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(selection.files, key = { it.index }) { file ->
                        Column(Modifier.fillMaxWidth().padding(vertical = 7.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    file.path,
                                    modifier = Modifier.weight(1f).then(
                                        if (onOpenFile != null) Modifier.clickable { onOpenFile(file) } else Modifier,
                                    ),
                                    fontSize = 13.sp,
                                )
                                if (onOpenFile != null) {
                                    IconButton(onClick = { onOpenFile(file) }, modifier = Modifier.size(32.dp)) {
                                        Icon(Icons.Default.OpenInNew, contentDescription = "打开 ${file.name}", modifier = Modifier.size(17.dp))
                                    }
                                }
                                if (onShareFile != null) {
                                    IconButton(onClick = { onShareFile(file) }, modifier = Modifier.size(32.dp)) {
                                        Icon(Icons.Default.Share, contentDescription = "分享 ${file.name}", modifier = Modifier.size(17.dp))
                                    }
                                }
                            }
                            val progress = file.progressBytes
                            Text(
                                if (progress == null) {
                                    "${file.name.substringAfterLast('.', "文件").uppercase()} · ${formatBytes(file.size)} · 已下载未知"
                                } else {
                                    "${file.name.substringAfterLast('.', "文件").uppercase()} · ${formatBytes(progress)} / ${formatBytes(file.size)}"
                                },
                                fontSize = 11.sp,
                                color = Color(0xFF74838D),
                            )
                            if (progress != null && file.size > 0) {
                                Spacer(Modifier.height(4.dp))
                                LinearProgressIndicator(
                                    progress = { (progress.toDouble() / file.size).coerceIn(0.0, 1.0).toFloat() },
                                    modifier = Modifier.fillMaxWidth().height(3.dp).clip(RoundedCornerShape(3.dp)),
                                    color = MaterialTheme.colorScheme.primary,
                                    trackColor = Color(0xFFE6EDF2),
                                )
                            }
                        }
                    }
                }
                Spacer(Modifier.height(8.dp))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                    Button(onClick = onDismiss) { Text("关闭") }
                }
            }
        }
    }
}

private fun QueueTask.stateLabel(): String = when (state) {
    "running" -> "下载中"
    "queued" -> "排队中"
    "paused" -> "已暂停"
    "finished" -> "已完成"
    "failed" -> "失败"
    "handed-off" -> "已移交"
    else -> state
}

private fun parseTasks(envelope: String): List<QueueTask> = runCatching {
    val root = JSONObject(envelope)
    val data = root.optJSONArray("data") ?: JSONArray()
    buildList {
        for (index in 0 until data.length()) {
            val task = data.optJSONObject(index) ?: continue
            val total = if (task.isNull("total_bytes")) null else task.optLong("total_bytes", 0L)
            val rawFileName = task.optString("file_name").ifBlank { task.optString("source") }
            val rawOutputDir = task.optString("output_dir").ifBlank { task.optString("outputDir") }
            val rawSource = task.optString("source")
            val rawKeepTs = task.optBoolean("hls_keep_transport_stream", false)
            val hlsRemuxedToMp4 = if (
                rawSource.substringBefore('?').substringBefore('#').endsWith(".m3u8", ignoreCase = true) &&
                !rawKeepTs &&
                rawFileName.endsWith(".ts", ignoreCase = true)
            ) {
                val transport = File(rawOutputDir, rawFileName)
                val mp4 = File(rawOutputDir, rawFileName.dropLast(3) + ".mp4")
                // 作者: long
                // 多个 HLS 任务可能共用保存目录和文件名；只有 MP4 比当前 TS 更新，
                // 或 TS 已被删除且 MP4 仍存在时，才把它认作本任务的转封装结果。
                mp4.isFile && (!transport.isFile || mp4.lastModified() >= transport.lastModified())
            } else {
                false
            }
            val torrentFiles = parseTorrentFiles(task.optJSONArray("torrent_files"))
            val torrentFileIndices = parseTorrentIndices(task.optJSONArray("torrent_file_indices"))
            val selectedTorrentFiles = torrentFiles.filter { file ->
                torrentFileIndices.isNotEmpty() && file.index in torrentFileIndices
            }
            // 作者: long
            // 队列卡片只统计用户确认过的 Torrent/Magnet 文件；Rust 新版本会直接写入选中进度，
            // 这里再按 metadata 做一次兼容收口，避免旧队列把未选择文件混进总量。
            val displayTotal = selectedTorrentFiles
                .takeIf { it.isNotEmpty() }
                ?.sumOf { it.size }
                ?: total
            val rawDownloaded = task.optLong("downloaded_bytes", 0L)
            val displayDownloaded = selectedTorrentFiles
                .takeIf { it.isNotEmpty() }
                ?.let { files ->
                    val fileProgress = files.mapNotNull { it.progressBytes }
                    when {
                        task.optString("state") == "finished" -> files.sumOf { it.size }
                        fileProgress.isNotEmpty() -> fileProgress.sum().coerceAtMost(files.sumOf { it.size })
                        else -> rawDownloaded.coerceAtMost(files.sumOf { it.size })
                    }
                }
                ?: rawDownloaded
            add(
                QueueTask(
                    id = task.optString("id"),
                    name = rawFileName,
                    source = rawSource,
                    state = task.optString("state", "queued"),
                    downloadedBytes = displayDownloaded,
                    totalBytes = displayTotal,
                    speedBytesPerSecond = task.optLong("current_speed_bytes_per_second", 0L),
                    startedAtMs = task.optNullableLong("started_at_ms", "startedAtMs"),
                    finishedAtMs = task.optNullableLong("finished_at_ms", "finishedAtMs"),
                    error = task.optString("error").ifBlank { null },
                    outputDir = rawOutputDir,
                    torrentName = task.optString("torrent_name").ifBlank { null },
                    torrentFiles = torrentFiles,
                    torrentFileIndices = torrentFileIndices,
                    hlsVariantIndex = if (task.isNull("hls_variant_index")) null else task.optInt("hls_variant_index", -1).takeIf { it >= 0 },
                    hlsKeepTransportStream = rawKeepTs,
                    hlsRemuxedToMp4 = hlsRemuxedToMp4,
                    credentialRef = task.optString("credential_ref").ifBlank { null },
                ),
            )
        }
    }
}.getOrDefault(emptyList())

private fun parseTorrentFiles(filesJson: JSONArray?): List<TorrentFileSelection> {
    if (filesJson == null) return emptyList()
    return buildList {
        for (index in 0 until filesJson.length()) {
            val file = filesJson.optJSONObject(index) ?: continue
            val progress = if (file.isNull("progress_bytes")) null else file.optLong("progress_bytes", 0L)
            add(
                TorrentFileSelection(
                    index = file.optInt("index", index),
                    path = file.optString("path").ifBlank { file.optString("name") },
                    name = file.optString("name").ifBlank { file.optString("path") },
                    size = file.optLong("size", 0L),
                    isStreamable = file.optBoolean("is_streamable", file.optBoolean("isStreamable", false)),
                    progressBytes = progress,
                ),
            )
        }
    }
}

private fun JSONObject.optNullableLong(vararg keys: String): Long? {
    for (key in keys) {
        if (!isNull(key) && has(key)) {
            optLong(key, 0L).takeIf { it > 0L }?.let { return it }
        }
    }
    return null
}

private fun parseTorrentIndices(indices: JSONArray?): Set<Int> {
    if (indices == null) return emptySet()
    return buildSet {
        for (index in 0 until indices.length()) {
            indices.optInt(index, -1).takeIf { it >= 0 }?.let(::add)
        }
    }
}

private fun parseError(envelope: String): String? = runCatching {
    val root = JSONObject(envelope)
    if (root.optBoolean("ok", false)) null else root.optString("error").ifBlank { "Rust 核心返回未知错误" }
}.getOrNull()

internal fun firstValidatedQrDownloadSource(
    candidates: Iterable<Pair<String?, String?>>,
    detectProtocol: (String) -> String?,
): String? {
    // 作者: long
    // 一帧可能同时包含多个二维码；逐个尝试 raw/display 值，避免普通文本二维码排在前面时
    // 把后面的真实下载链接误判为无效。长度和协议校验都在纯函数内完成，便于 JVM 单测覆盖。
    candidates.forEach { (rawValue, displayValue) ->
        sequenceOf(rawValue, displayValue)
            .mapNotNull { it?.trim() }
            .filter { it.isNotEmpty() && it.length <= 8192 }
            .distinct()
            .forEach { candidate ->
                if (detectProtocol(candidate)?.let { it != "unknown" } == true) return candidate
            }
    }
    return null
}

private fun parseDataString(envelope: String, key: String): String? = runCatching {
    val root = JSONObject(envelope)
    if (!root.optBoolean("ok", false)) return@runCatching null
    root.optJSONObject("data")?.optString(key)?.takeIf { it.isNotBlank() }
}.getOrNull()

private fun parseHlsVariants(envelope: String): List<HlsVariantOption> = runCatching {
    val root = JSONObject(envelope)
    if (!root.optBoolean("ok", false)) return@runCatching emptyList()
    val data = root.optJSONArray("data") ?: return@runCatching emptyList()
    buildList {
        for (index in 0 until data.length()) {
            val item = data.optJSONObject(index) ?: continue
            add(
                HlsVariantOption(
                    index = item.optInt("index", index),
                    bandwidth = item.optLong("bandwidth", 0L),
                    averageBandwidth = if (item.isNull("average_bandwidth")) null else item.optLong("average_bandwidth", 0L),
                    codecs = item.optString("codecs").takeUnless { it.isBlank() || it.equals("null", ignoreCase = true) },
                    resolution = item.optString("resolution").takeUnless { it.isBlank() || it.equals("null", ignoreCase = true) },
                    frameRate = if (item.isNull("frame_rate")) null else item.optDouble("frame_rate", 0.0),
                ),
            )
        }
    }
}.getOrDefault(emptyList())

private fun parseTorrentSelection(
    envelope: String,
    source: String,
    requestedFileName: String,
    outputPath: String,
): TorrentSelection? = runCatching {
    val root = JSONObject(envelope)
    val report = root.optJSONObject("data")?.optJSONObject("report") ?: return@runCatching null
    val filesJson = report.optJSONArray("files") ?: return@runCatching null
    val files = parseTorrentFiles(filesJson)
    val rawInfoHash = report.opt("info_hash")
    val infoHash = rawInfoHash
        ?.takeIf { it != JSONObject.NULL }
        ?.toString()
        ?.trim()
        ?.takeIf { it.isNotEmpty() && !it.equals("null", ignoreCase = true) }
    TorrentSelection(
        source = source,
        requestedFileName = requestedFileName,
        outputPath = outputPath,
        directoryName = report.optString("name").ifBlank { "Torrent 资源" },
        files = files,
        infoHash = infoHash,
    )
}.getOrNull()

private fun supportsCredentialProtocol(protocol: String?): Boolean = protocol in setOf(
    "http",
    "https",
    "webdav",
    "webdavs",
    "ftp",
    "ftps",
    "sftp",
    "smb",
)

private fun hasUsableKnownHostEntry(content: String): Boolean = content.lineSequence().any { rawLine ->
    val line = rawLine.trim()
    if (line.isEmpty() || line.startsWith("#")) return@any false
    val fields = line.split(Regex("\\s+"))
    if (fields.size < 3 || fields[0].isBlank() || fields[1].isBlank()) return@any false
    runCatching {
        Base64.decode(fields[2], Base64.DEFAULT).isNotEmpty()
    }.getOrDefault(false)
}

private fun formatBytes(value: Long): String = when {
    value >= 1024L * 1024L * 1024L -> "%.1f GB".format(value / 1024.0 / 1024.0 / 1024.0)
    value >= 1024L * 1024L -> "%.1f MB".format(value / 1024.0 / 1024.0)
    value >= 1024L -> "%.1f KB".format(value / 1024.0)
    else -> "$value B"
}

private fun formatTaskTime(value: Long): String = runCatching {
    SimpleDateFormat("MM-dd HH:mm", Locale.getDefault()).format(Date(value))
}.getOrDefault("--")

private fun formatOutputLocation(context: Context, value: String): String {
    if (!value.startsWith("content://")) return value.ifBlank { "应用私有下载目录" }
    return runCatching {
        DocumentFile.fromTreeUri(context, Uri.parse(value))?.name ?: "已选择的系统目录"
    }.getOrDefault("已选择的系统目录")
}

@Composable
private fun <T> StateFlow<T>.collectAsStateCompat(): androidx.compose.runtime.State<T> {
    return collectAsState()
}

@Composable
private fun FluxDownKotlinTheme(content: @Composable () -> Unit) {
    val colors = lightColorScheme(
        primary = Color(0xFF2B8FD8),
        onPrimary = Color.White,
        secondary = Color(0xFF1F7A9E),
        background = Color(0xFFF4F8FC),
        surface = Color.White,
        surfaceVariant = Color(0xFFE8F1F7),
    )
    MaterialTheme(colorScheme = colors, content = content)
}
