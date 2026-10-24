package dev.fluxdown.android.ui.i18n

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import dev.fluxdown.android.data.KotlinSettings

/**
 * 作者: long
 * S4 语言切换的文案资源层。每个 key 自带中英文两条文案，
 * 界面只引用 [Str] 常量，不再出现中文字面量（便于 grep 校验遗漏）。
 * 带参数的文案统一用 %1$s / %1$d 占位，由 [tr] 做格式化。
 */
internal enum class Str(val zh: String, val en: String) {
    // ---- 通用 ----
    Confirm("确定", "OK"),
    Cancel("取消", "Cancel"),
    Close("关闭", "Close"),
    Save("保存", "Save"),
    Delete("删除", "Delete"),
    Retry("重试", "Retry"),
    Continue("继续", "Resume"),
    Pause("暂停", "Pause"),
    Ignore("忽略", "Dismiss"),
    None("无", "None"),
    NotLoaded("未加载", "Not loaded"),

    // ---- 底部导航 / 任务页 ----
    TabTasks("任务", "Tasks"),
    TabSettings("设置", "Settings"),
    NewTask("新建任务", "New task"),
    ClearFinished("清理已完成", "Clear finished"),
    ClearFinishedTitle("清理已完成任务", "Clear finished tasks"),
    ClearFinishedMessage(
        "将删除 %1\$d 个已完成任务记录（不删除已下载的文件）。运行中、暂停和失败的任务会保留。",
        "This removes %1\$d finished task records (downloaded files are kept). Running, paused and failed tasks stay.",
    ),
    ClearAction("清理", "Clear"),
    EmptyQueueTitle("还没有下载任务", "No downloads yet"),
    EmptyQueueHint("点击右下角按钮添加链接", "Tap the button at the bottom right to add a link"),
    FilterAll("全部", "All"),
    FilterUnfinished("未完成", "Active"),
    FilterEnded("已结束", "Finished"),
    FilterFailed("失败", "Failed"),
    NetworkPaused("已按设置暂停：当前不在 Wi-Fi 网络，连接 Wi-Fi 后自动继续", "Paused by setting: not on Wi-Fi, downloads resume automatically once Wi-Fi is back"),
    ShareFile("分享文件", "Share file"),
    OpenFile("打开文件", "Open file"),
    CopyLink("复制下载链接", "Copy link"),
    Properties("属性", "Properties"),
    DeleteTask("删除任务", "Delete task"),
    Redownload("重新下载", "Download again"),
    TaskActions("任务操作", "Task actions"),
    TaskProperties("任务属性", "Task properties"),
    TaskCreated("已移交", "Handed off"),

    // ---- 任务属性面板 ----
    FieldFileName("文件名", "File name"),
    FieldSha256("SHA-256 校验值（可选）", "SHA-256 checksum (optional)"),
    Sha256Hint("64 位十六进制，可带 sha256: 前缀", "64 hexadecimal characters; optional sha256: prefix"),
    Sha256Invalid("SHA-256 必须是 64 位十六进制字符", "SHA-256 must contain 64 hexadecimal characters"),
    FieldSource("源链接", "Source URL"),
    FieldOutputPath("输出路径", "Output path"),
    FieldProtocol("协议", "Protocol"),
    FieldStatus("状态", "Status"),
    FieldFileSize("文件大小", "File size"),
    FieldStartedAt("开始时间", "Started at"),
    FieldFinishedAt("结束时间", "Finished at"),
    FieldElapsed("总耗时", "Elapsed"),
    FieldSpeed("速度", "Speed"),
    FieldError("错误信息", "Error"),
    FieldFailureReason("失败原因", "Failure reason"),
    SpeedAverage("平均 ", "Avg "),
    SpeedAverageWithCurrent(" · 当前 ", " · now "),
    SizeUnknown("未知（已下载 %1\$s）", "Unknown (%1\$s downloaded)"),
    SpeedValue("速度 %1\$s/s", "Speed %1\$s/s"),
    HlsSegmentProgress("分片 %1\$d/%2\$d", "Segment %1\$d/%2\$d"),

    // ---- 任务状态 ----
    StateQueued("排队中", "Queued"),
    StateRunning("下载中", "Downloading"),
    StatePaused("已暂停", "Paused"),
    StateFinished("已完成", "Finished"),
    StateFailed("下载失败", "Download failed"),
    StateInProgress("进行中", "In progress"),

    // ---- 新建任务弹窗 ----
    NewDownload("新建下载", "New download"),
    NewDownloadHint("粘贴链接后自动识别类型，确认下载即可开始。", "Paste a link; the type is detected automatically. Confirm to start."),
    FieldLink("下载链接", "Download URL"),
    ReadClipboard("读取剪切板", "Read clipboard"),
    ScanQr("扫描二维码", "Scan QR code"),
    AutoDetect("自动识别", "Detected"),
    WaitingForLink("等待识别链接类型", "Waiting for link detection"),
    FieldCredentialRef("凭据引用", "Credential reference"),
    FieldCredentialRefOptional("凭据引用（可选）", "Credential reference (optional)"),
    UseNoCredential("不使用凭据", "No credential"),
    HlsVariantLabel("HLS 清晰度编号（可选）", "HLS variant index (optional)"),
    HlsVariantHint("留空使用默认清晰度；从 0 开始", "Leave empty for default quality; starts at 0"),
    ReadHlsVariants("读取 HLS 清晰度", "Load HLS variants"),
    ReadingHlsVariants("正在读取清晰度…", "Loading variants…"),
    HlsVariantsFailed("清晰度读取失败：%1\$s", "Failed to load variants: %1\$s"),
    HlsVariantsCount("%1\$d 个", "%1\$d available"),
    KeepTransportStream("保留原始 TS 文件", "Keep original TS file"),
    StartDownload("开始下载", "Start download"),
    CreatingTask("正在创建任务…", "Creating task…"),
    PleaseEnterLink("请输入下载链接", "Please enter a download URL"),
    UnsupportedProtocol("无法识别或暂不支持", "Unrecognized or unsupported"),
    CannotCreateTask("无法创建下载任务", "Unable to create the download task"),

    // ---- Torrent 选择 ----
    LoadingManifest("正在获取清单…", "Loading manifest…"),
    LoadingManifestHint("正在获取可下载清单，完成后选择文件…", "Fetching the file list; pick files when it finishes…"),
    TorrentManifestFailed("Torrent/Magnet 清单获取失败", "Failed to load the Torrent/Magnet manifest"),
    SelectFilesTitle("选择要下载的文件（%1\$d/%2\$d）", "Choose files to download (%1\$d/%2\$d)"),
    ConfirmedFiles("已确认文件（%1\$d）", "Confirmed files (%1\$d)"),
    ConfirmAndAdd("确认并加入", "Confirm and add"),
    SelectAtLeastOneFile("至少选择一个文件", "Select at least one file"),
    ResourceDetails("资源详情", "Resource details"),
    ShareNamed("分享 %1\$s", "Share %1\$s"),
    OpenNamed("打开 %1\$s", "Open %1\$s"),
    ReadingSizeHint("正在读取存储容量…", "Reading storage capacity…"),
    CannotReadSize("无法读取这个路径的存储容量", "Cannot read storage capacity for this path"),

    // ---- 协议标签 ----
    ProtocolHttp("HTTP · Rust 下载引擎", "HTTP · Rust engine"),
    ProtocolHttps("HTTPS · Rust 下载引擎", "HTTPS · Rust engine"),
    ProtocolWebdav("WebDAV · Rust 下载引擎", "WebDAV · Rust engine"),
    ProtocolFtp("FTP · Rust 下载引擎", "FTP · Rust engine"),
    ProtocolFtps("FTPS · Rust 下载引擎", "FTPS · Rust engine"),
    ProtocolSftp("SFTP · Rust 下载引擎", "SFTP · Rust engine"),
    ProtocolSmb("SMB · Rust 下载引擎", "SMB · Rust engine"),
    ProtocolHls("HLS · Rust 下载引擎", "HLS · Rust engine"),
    ProtocolTorrent("Torrent · Rust 元数据", "Torrent · Rust metadata"),
    ProtocolMagnet("Magnet · Rust 元数据", "Magnet · Rust metadata"),
    ProtocolEd2k("ED2K · 外部接管", "ED2K · external client"),

    // ---- 二维码 ----
    CameraPermissionNeeded("需要相机权限才能扫描二维码", "Camera permission is required to scan QR codes"),
    CameraPermissionRetry("请允许相机权限后重试", "Allow camera access and try again"),
    CameraStartFailed("相机启动失败：%1\$s", "Failed to start the camera: %1\$s"),
    CameraUnavailable("无法打开相机", "Camera unavailable"),
    QrScanHint("将下载链接二维码放入取景框", "Place the link QR code inside the frame"),
    QrNotALink("二维码内容不是可识别的下载链接", "The QR code does not contain a recognizable download URL"),
    QrScanFailed("二维码识别失败，请保持图案完整", "QR scan failed; keep the code fully visible"),

    // ---- 设置页 ----
    SettingsTitle("设置", "Settings"),
    OutputLocation("保存位置", "Save location"),
    ChooseSystemDir("选择系统目录", "Choose folder"),
    StorageTotal("总容量", "Total"),
    StorageUsed("已用", "Used"),
    StorageFree("剩余", "Free"),
    MaxConcurrency("最大并发", "Max concurrent"),
    MaxConcurrencyHint("同时运行任务数", "Tasks running at once"),
    MaxThreads("最大下载线程", "Threads per task"),
    MaxThreadsHint("单任务线程数", "Threads used by one task"),
    RetryAttempts("自动重试次数", "Auto retry"),
    RetryAttemptsHint("失败重试 0-10，0 不重试", "Retries on failure, 0-10; 0 disables"),
    SpeedLimit("最大下载网速", "Speed limit"),
    SpeedLimitHint("MB/s，留空不限速", "MB/s; leave empty for unlimited"),
    Unlimited("不限速", "Unlimited"),
    UnitCount("个", ""),
    UnitThreads("线程", "threads"),
    UnitTimes("次", "times"),
    WifiOnly("仅在 Wi-Fi 下下载", "Download on Wi-Fi only"),
    WifiOnlyHint("移动网络时暂停队列，连上 Wi-Fi 后自动继续", "Pause on mobile data and resume once Wi-Fi is back"),
    NotifyOnComplete("下载完成通知", "Completion notification"),
    NotifyOnCompleteHint("队列结束或失败时发送通知", "Notify when the queue ends or fails"),
    NotifyPermissionMissing("通知权限未授予，完成后无法提醒", "Notifications are blocked, so you will not be alerted"),
    NotificationsDisabled("系统已关闭本应用通知", "Notifications are turned off for this app"),
    GoEnable("去开启", "Enable"),
    ClipboardPrompt("启动时识别剪贴板链接", "Detect clipboard links on launch"),
    ClipboardPromptHint("复制下载链接后打开应用，顶部提示新建任务", "After copying a link, open the app to get a new-task prompt"),
    Theme("主题", "Theme"),
    ThemeHint("浅色 / 深色 / 跟随系统", "Light / dark / follow system"),
    ThemeSystem("跟随系统", "Follow system"),
    ThemeLight("浅色", "Light"),
    ThemeDark("深色", "Dark"),
    Language("语言", "Language"),
    LanguageHint("界面语言，重启后保持", "Interface language, kept across restarts"),
    LanguageZh("简体中文", "简体中文"),
    LanguageEn("English", "English"),
    Credentials("安全凭据", "Credentials"),
    CredentialsHintEmpty("密码和私钥仅保存在 Android Keystore", "Passwords and keys stay in the Android Keystore"),
    CredentialsHintCount("已保存 %1\$d 个凭据引用", "%1\$d credential reference(s) saved"),
    AddCredential("添加凭据", "Add credential"),
    DeleteCredential("删除凭据", "Delete credential"),
    DeleteCredentialMessage("确定删除“%1\$s”吗？使用该引用的任务将在下次运行时提示凭据不可用。", "Delete \"%1\$s\"? Tasks using it will report a missing credential."),
    SftpKnownHosts("SFTP 主机密钥", "SFTP host keys"),
    SftpKnownHostsUnset("未配置，使用 SSH 库默认策略", "Not configured; using the SSH library default"),
    SftpKnownHostsSet("已配置 known_hosts", "known_hosts configured"),
    ImportKnownHosts("导入 known_hosts", "Import known_hosts"),
    ClearKnownHosts("清除主机密钥", "Clear host keys"),
    CurrentVersion("当前版本", "Version"),
    CheckUpdate("检查更新", "Check for updates"),
    DownloadUpdate("下载更新", "Download update"),
    OpenDownloadPage("打开下载页", "Open download page"),
    UpdateNotes("更新说明", "Release notes"),
    UpToDate("已是最新版本", "You are up to date"),
    UpdateCheckDone("已完成版本检查", "Update check finished"),
    UpdateCheckFailed("检查更新失败，请稍后重试", "Update check failed, try again later"),
    UpdateFound("找到最新版本 %1\$s", "Latest version: %1\$s"),
    CurrentVersionLabel("当前版本：%1\$s", "Current version: %1\$s"),
    UpdateMissingVersion("更新信息缺少版本号", "Update info has no version number"),
    CannotOpenDownloadPage("无法打开下载页", "Cannot open the download page"),
    CannotOpenCamera("无法打开相机", "Camera unavailable"),
    FileNameInvalid("文件名无效", "Invalid file name"),
    CredentialRefTooLong("凭据引用不能超过 128 个字符", "Credential reference must be at most 128 characters"),
    CredentialRefInvalid("凭据引用无效", "Invalid credential reference"),
    CredentialRefRequired("请输入凭据引用", "Please enter a credential reference"),
    UsernameRequired("请输入用户名", "Please enter a user name"),
    InvalidPrivateKey("请输入有效的 SFTP 私钥", "Please enter a valid SFTP private key"),
    InvalidHlsIndex("请输入不小于 0 的编号", "Enter a number no smaller than 0"),
    CredentialEditorTitle("添加安全凭据", "Add credential"),
    CredentialUsername("用户名", "User name"),
    CredentialPassword("密码", "Password"),
    CredentialPrivateKey("私钥内容（PEM）", "Private key (PEM)"),
    CredentialPassphrase("私钥口令（可选）", "Key passphrase (optional)"),
    SftpPrivateKeyAuth("SFTP 私钥认证", "SFTP key authentication"),
    ChooseTitle("选择%1\$s", "Choose %1\$s"),

    // ---- 补充：界面零散文案 ----
    Unknown("未知", "Unknown"),
    UnitNone("不限", "Unlimited"),
    Create("新建", "New"),
    QuitFluxDown("退出 FluxDown", "Quit FluxDown"),
    QuitMessage("退出当前界面？已加入队列的下载会继续在后台运行。", "Exit? Queued downloads keep running in the background."),
    Quit("退出", "Exit"),
    ClipboardDetected("剪贴板检测到链接", "Link detected in clipboard"),
    DoneShort("已完成", "Done"),
    Reauthorize("重新授权", "Allow"),
    SavedCredentialsCount("已保存 %1\$d 个凭据引用", "%1\$d credential reference(s) saved"),
    TorrentResource("Torrent 资源", "Torrent resource"),
    DownloadedUnknown("已下载未知", "downloaded size unknown"),

    // ---- 非界面文案（服务 / 通知 / 平台层） ----
    SvcQueueStartFailed("Rust 下载队列启动失败", "Failed to start the Rust download queue"),
    RustUnknownError("Rust 核心返回未知错误", "Rust core returned an unknown error"),
    RustNotLoaded("Rust 核心未加载: %1\$s", "Rust core not loaded: %1\$s"),
    RustCallFailed("调用 Rust 核心失败: %1\$s", "Rust core call failed: %1\$s"),
    DownloadFailedWith("下载失败：%1\$s", "Download failed: %1\$s"),
    CompletedTasksCount("已完成 %1\$d 个任务", "%1\$d task(s) finished"),
    QueueEnded("下载队列已结束", "Download queue finished"),
    ChannelProgress("下载任务", "Downloads"),
    ChannelProgressDesc("FluxDown Kotlin 下载进度", "FluxDown Kotlin download progress"),
    ChannelDone("下载完成", "Downloads finished"),
    ChannelDoneDesc("FluxDown Kotlin 下载完成与失败提醒", "FluxDown Kotlin completion and failure alerts"),
    QueueRunning("下载队列正在运行", "Download queue is running"),
    QueueProgressSummary("进行中 %1\$d · 已完成 %2\$d/%3\$d", "%1\$d active · %2\$d/%3\$d finished"),
    CredentialSavedNotice("凭据已保存", "Credential saved"),
    CredentialSaveFailed("凭据保存失败", "Failed to save the credential"),
    CredentialDeletedNotice("凭据已删除", "Credential deleted"),
    CredentialDeleteFailed("凭据删除失败", "Failed to delete the credential"),
    SettingsSavedNotice("设置已保存", "Settings saved"),
    NothingToClearNotice("没有可清理的已完成任务", "No finished tasks to clear"),
    ClearedTasksNotice("已清理 %1\$d 个已完成任务", "Cleared %1\$d finished task(s)"),
    LinkCopiedNotice("下载链接已复制", "Download link copied"),
    DirNotWritable("无法写入所选目录，请选择可写的系统目录", "Cannot write to that folder; pick a writable system folder"),
    OutputSelectedNotice("已选择下载保存位置：%1\$s", "Save location set to %1\$s"),
    KnownHostsUpdatedNotice("SFTP 主机密钥已更新", "SFTP host keys updated"),
    KnownHostsClearedNotice("SFTP 主机密钥已清除", "SFTP host keys cleared"),
    KnownHostsReadFailed("无法读取 known_hosts 文件", "Cannot read the known_hosts file"),
    KnownHostsNoEntries("文件中没有可用的 OpenSSH known_hosts 主机密钥", "No usable OpenSSH known_hosts host key found in the file"),
    Ed2kHandoffFailed("ed2k 链接移交失败：%1\$s", "ed2k hand-off failed: %1\$s"),
    ProtocolNoCredential("该协议不支持凭据引用", "This protocol does not support credential references"),
    CredentialUnavailable("凭据不可用，请在设置中重新保存", "Credential unavailable; save it again in Settings"),
    SftpKeyOnlyForSftp("SFTP 私钥凭据只能用于 SFTP 任务", "SFTP key credentials can only be used for SFTP tasks"),
    NoEd2kApp("没有可处理 ed2k 链接的应用，请先安装支持 ed2k 的客户端", "No app can handle ed2k links; install an ed2k client first"),
    Ed2kNoTaskId("ed2k 任务创建成功，但无法取得任务编号，未移交外部客户端", "ed2k task created but no task id was returned, so no hand-off happened"),
    TaskCreateFailed("任务创建失败", "Failed to create the task"),
    SelectOneFile("至少选择一个文件", "Select at least one file"),
    ReplaceTaskFailed("替换旧失败任务失败：%1\$s", "Failed to replace the old failed task: %1\$s"),
    PrivateDirNotice("已下载到私有目录", "Saved to the private folder"),
    UserDirNotice("已保存到用户目录", "Saved to the user folder"),
    SavedToSystemDir("下载完成，已保存到系统目录", "Download finished and saved to the system folder"),
    SaveToSystemDirFailed("下载已完成，但保存到系统目录失败：%1\$s", "Download finished but saving to the system folder failed: %1\$s"),
    OutputPrivateDirLabel("应用私有下载目录", "App private download folder"),
    OutputChosenDirLabel("已选择的系统目录", "Chosen system folder"),
    MetadataStartFailed("metadata 解析启动失败", "Failed to start metadata parsing"),
    MetadataTimeout("获取 Torrent/Magnet 清单超时，请检查网络或节点", "Timed out fetching the Torrent/Magnet manifest; check the network or peers"),
    MetadataFailed("metadata 解析失败", "Metadata parsing failed"),
    MetadataNoFiles("metadata 未返回可下载文件", "Metadata returned no downloadable files"),
    StagingMissing("暂存目录不存在", "Staging folder is missing"),
    PermissionRevoked("目录权限已失效", "Folder permission is no longer valid"),
    StagingEmpty("暂存目录没有可复制的文件", "No files to copy from the staging folder"),
    CannotCreateDir("无法创建目录 %1\$s", "Cannot create folder %1\$s"),
    CannotCreateFile("无法创建文件 %1\$s", "Cannot create file %1\$s"),
    CannotOpenTarget("无法打开目标文件 %1\$s", "Cannot open target file %1\$s"),
    UpdateServerError("更新服务器返回错误（%1\$d）", "Update server returned %1\$d"),
    RemuxFailed("传统 HLS TS 转 MP4 失败: %1\$s", "Failed to remux the legacy HLS TS into MP4: %1\$s"),
    FileNotFound("找不到已下载文件", "Downloaded file not found"),
    NoAppForFileType("设备上没有支持此文件类型的应用", "No app on this device supports that file type"),
    CannotActOnFile("无法%1\$s文件：%2\$s", "Cannot %1\$s the file: %2\$s"),
    ActionShare("分享", "share"),
    ActionOpen("打开", "open"),
    CredentialUserEmpty("凭据用户名不能为空", "Credential user name cannot be empty"),
    SftpKeyInvalid("SFTP 私钥格式无效", "Invalid SFTP private key format"),
    CredentialInvalid("凭据内容无效", "Invalid credential contents"),
    CredentialRefInvalidNotice("凭据引用无效", "Invalid credential reference"),
    RemuxNoTs("TS 文件不存在或为空", "TS file is missing or empty"),
    RemuxCannotOverwrite("无法覆盖 MP4 输出文件", "Cannot overwrite the MP4 output file"),
    RemuxNoTrack("TS 中没有可写入 MP4 的音视频轨道", "The TS has no audio/video tracks to write into MP4"),
    RemuxEmpty("MP4 转封装结果为空", "The MP4 remux produced no output"),
    DurationHms("%1\$d小时%2\$d分%3\$d秒", "%1\$dh %2\$dm %3\$ds"),
    DurationMs("%1\$d分%2\$d秒", "%1\$dm %2\$ds"),
    DurationS("%1\$d秒", "%1\$ds"),
    StateFailedShort("失败", "Failed"),
    StateHandedOff("已移交", "Handed off"),
    HlsVariantNoInfo("未提供清晰度信息", "no variant details"),
    UnsupportedProtocolLink("无法识别或暂不支持该链接协议", "Unrecognized or unsupported link protocol"),
    CopyErrorUnknown("未知复制错误", "unknown copy error"),
    UnknownError("未知错误", "Unknown error"),
    FileWord("文件", "file"),
    AddToQueueFailed("加入队列失败：%1\$s", "Failed to add to the queue: %1\$s"),
    ProtocolWrapped("基于 HTTP 的封装协议", "HTTP-based wrapper protocol"),
    ;

    companion object {
        /** 所有文案 key，供测试遍历校验双语是否齐全。 */
        val all: List<Str> get() = entries
    }
}

/** 当前语言 key（KotlinSettings.LANGUAGE_ZH / LANGUAGE_EN）。 */
internal val LocalLanguage = staticCompositionLocalOf { KotlinSettings.LANGUAGE_ZH }

internal fun languageOf(context: Context): String {
    val prefs = context.getSharedPreferences("fluxdown.kotlin.settings", Context.MODE_PRIVATE)
    return prefs.getString("language", KotlinSettings.LANGUAGE_ZH)?.takeIf { it in KotlinSettings.LANGUAGES }
        ?: KotlinSettings.LANGUAGE_ZH
}

internal fun Str.text(language: String): String =
    if (language == KotlinSettings.LANGUAGE_EN) en else zh

/** 无 Context 场景（data 层解析函数）的兜底语言来源，由界面在设置加载/切换时写入。 */
internal object AppLanguage {
    var current: String = KotlinSettings.LANGUAGE_ZH
}

/** 无 Context 场景取文案。 */
internal fun trApp(key: Str, vararg args: Any): String =
    format(key.text(AppLanguage.current), args)

private fun format(template: String, args: Array<out Any>): String =
    if (args.isEmpty()) template else runCatching { String.format(template, *args) }.getOrDefault(template)

/** 界面取文案：跟随当前语言，切换语言后自动重组。 */
@Composable
internal fun tr(key: Str, vararg args: Any): String =
    format(key.text(LocalLanguage.current), args)

/** 给定语言取文案：供非 Composable 的 lambda（相机回调等）使用。 */
internal fun trIn(language: String, key: Str, vararg args: Any): String =
    format(key.text(language), args)

/** 非 Composable 场景（前台服务、通知）取文案：直接读持久化的语言设置。 */
internal fun trOff(context: Context, key: Str, vararg args: Any): String =
    format(key.text(languageOf(context)), args)
