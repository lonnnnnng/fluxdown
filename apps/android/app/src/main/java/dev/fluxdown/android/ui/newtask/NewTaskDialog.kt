package dev.fluxdown.android.ui.newtask
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.*
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
internal fun NewTaskDialog(
    defaultOutputPath: String,
    credentialReferences: List<String>,
    hlsVariants: List<HlsVariantOption>,
    hlsVariantsSource: String?,
    hlsVariantsLoading: Boolean,
    hlsVariantsError: String?,
    onLoadHlsVariants: (String) -> Unit,
    torrentMetadataLoading: Boolean,
    torrentMetadataError: String?,
    newTaskSubmitting: Boolean,
    newTaskError: String?,
    onSourceChanged: () -> Unit,
    onDismiss: () -> Unit,
    onConfirm: (String, String, String, String?, String, Int?, Boolean) -> Unit,
    /** S5 从剪贴板建议进入时预填的下载源。 */
    initialSource: String? = null,
) {
    var source by remember(initialSource) { mutableStateOf(initialSource.orEmpty()) }
    var fileName by remember { mutableStateOf("") }
    var outputPath by remember { mutableStateOf(defaultOutputPath) }
    var credentialRef by remember { mutableStateOf<String?>(null) }
    var credentialMenuExpanded by remember { mutableStateOf(false) }
    var hlsVariant by remember { mutableStateOf("") }
    var hlsKeepTransportStream by remember { mutableStateOf(false) }
    var showScanner by rememberSaveable { mutableStateOf(false) }
    val clipboard = LocalClipboardManager.current
    val detectedProtocol = remember(source) {
        source.trim().takeIf { it.isNotEmpty() }?.let { ProtocolDetector.detect(it) } ?: "unknown"
    }
    val isHlsSource = detectedProtocol == "m3u8"
    val hlsVariantIndex = hlsVariant.trim().takeIf { it.isNotEmpty() }?.toIntOrNull()
    val hlsVariantError = hlsVariant.trim().isNotEmpty() && (hlsVariantIndex == null || hlsVariantIndex < 0)
    val sourceError = downloadSourceIssue(source.trim(), detectedProtocol)
    val busy = newTaskSubmitting || torrentMetadataLoading
    val detectedLabel = when (detectedProtocol) {
        "http" -> tr(Str.ProtocolHttp)
        "https" -> tr(Str.ProtocolHttps)
        "m3u8" -> tr(Str.ProtocolHls)
        "torrent" -> tr(Str.ProtocolTorrent)
        "magnet" -> tr(Str.ProtocolMagnet)
        "ftp" -> tr(Str.ProtocolFtp)
        "ftps" -> tr(Str.ProtocolFtps)
        "sftp" -> tr(Str.ProtocolSftp)
        "ed2k" -> tr(Str.ProtocolEd2k)
        "smb" -> tr(Str.ProtocolSmb)
        "webdav", "webdavs" -> tr(Str.ProtocolWebdav)
        else -> if (source.isBlank()) tr(Str.WaitingForLink) else tr(Str.UnsupportedProtocol)
    }
    Dialog(
        onDismissRequest = { if (!busy) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .widthIn(max = 348.dp)
                .heightIn(max = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp * 0.86f)
                .padding(horizontal = 16.dp, vertical = 24.dp),
            shape = RoundedCornerShape(16.dp),
            color = FluxPalette.surfaceTintAlt4,
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
                        Text(tr(Str.NewDownload), fontSize = 17.sp, lineHeight = 19.sp, fontWeight = FontWeight.Normal, color = FluxPalette.textPrimary)
                        Spacer(Modifier.height(3.dp))
                        Text(tr(Str.NewDownloadHint), fontSize = 11.sp, lineHeight = 14.sp, color = FluxPalette.textStrongAlt3)
                    }
                    IconButton(onClick = {
                        clipboard.getText()?.text?.trim()?.takeIf { it.isNotEmpty() }?.let { source = it }
                    }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.ContentPaste, contentDescription = tr(Str.ReadClipboard), tint = FluxPalette.textStrong, modifier = Modifier.size(17.dp))
                    }
                    IconButton(onClick = { showScanner = true }, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.QrCodeScanner, contentDescription = tr(Str.ScanQr), tint = FluxPalette.textStrong, modifier = Modifier.size(17.dp))
                    }
                    IconButton(onClick = onDismiss, enabled = !busy, modifier = Modifier.size(32.dp)) {
                        Icon(Icons.Default.Close, contentDescription = tr(Str.Close), tint = FluxPalette.textStrong, modifier = Modifier.size(19.dp))
                    }
                }
                OutlinedTextField(
                    value = source,
                    onValueChange = { source = it; onSourceChanged() },
                    enabled = !busy,
                    label = { Text(tr(Str.FieldLink), fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 5,
                    maxLines = 5,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, lineHeight = 14.sp, color = FluxPalette.textPrimary),
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                        unfocusedContainerColor = FluxPalette.surfaceCard,
                        focusedContainerColor = FluxPalette.surfaceCard,
                        unfocusedBorderColor = FluxPalette.border,
                        focusedBorderColor = FluxPalette.accent,
                    ),
                )
                Card(
                    modifier = Modifier.fillMaxWidth(),
                    colors = CardDefaults.cardColors(containerColor = FluxPalette.surfaceTintAlt),
                    shape = RoundedCornerShape(8.dp),
                    border = BorderStroke(1.dp, FluxPalette.borderAccent),
                ) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(tr(Str.AutoDetect), fontSize = 10.5.sp, color = FluxPalette.textStrongAlt3)
                        Spacer(Modifier.width(8.dp))
                        Text(detectedLabel, modifier = Modifier.weight(1f), fontSize = 11.5.sp, color = if (source.isNotBlank() && sourceError != null) FluxPalette.dangerStrong else FluxPalette.accent, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (sourceError == null) Icon(Icons.Default.Check, contentDescription = null, tint = FluxPalette.accent, modifier = Modifier.size(15.dp))
                    }
                }
                (torrentMetadataError ?: newTaskError ?: sourceError?.takeIf { source.isNotBlank() })?.let { message ->
                    Card(
                        modifier = Modifier.fillMaxWidth(),
                        colors = CardDefaults.cardColors(containerColor = FluxPalette.dangerSurface),
                        shape = RoundedCornerShape(8.dp),
                        border = BorderStroke(1.dp, FluxPalette.borderDanger),
                    ) {
                        Column(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp)) {
                            Text(if (torrentMetadataError != null) tr(Str.TorrentManifestFailed) else tr(Str.CannotCreateTask), fontSize = 11.5.sp, color = FluxPalette.dangerStrong)
                            Spacer(Modifier.height(2.dp))
                            Text(message, fontSize = 11.sp, color = FluxPalette.dangerText)
                        }
                    }
                }
                OutlinedTextField(
                    value = fileName,
                    onValueChange = { fileName = it },
                    enabled = !busy,
                    label = { Text(tr(Str.FieldFileName), fontSize = 12.sp) },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 4,
                    maxLines = 4,
                    textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, lineHeight = 14.sp, color = FluxPalette.textPrimary),
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(unfocusedContainerColor = FluxPalette.surfaceCard, focusedContainerColor = FluxPalette.surfaceCard, unfocusedBorderColor = FluxPalette.border, focusedBorderColor = FluxPalette.accent),
                )
                // 作者: long
                // 没有输入需要认证的协议时不展示凭据字段，保持新建弹框首屏只聚焦链接、文件名和协议相关选项；
                // 用户输入 HTTP/FTP/SFTP 等支持凭据的链接后再展开该可选项。
                if (credentialReferences.isNotEmpty() && supportsCredentialProtocol(detectedProtocol)) {
                    Box(Modifier.fillMaxWidth()) {
                        OutlinedTextField(
                            value = credentialRef ?: tr(Str.UseNoCredential),
                            onValueChange = {},
                            readOnly = true,
                            label = { Text(tr(Str.FieldCredentialRefOptional), fontSize = 12.sp) },
                            modifier = Modifier.fillMaxWidth().height(48.dp),
                            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(unfocusedContainerColor = FluxPalette.surfaceCard, focusedContainerColor = FluxPalette.surfaceCard, unfocusedBorderColor = FluxPalette.border, focusedBorderColor = FluxPalette.accent),
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
                                text = { Text(tr(Str.UseNoCredential)) },
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
                            Text(if (hlsVariantsLoading) tr(Str.ReadingHlsVariants) else tr(Str.ReadHlsVariants), fontSize = 12.sp)
                        }
                        if (hlsVariantsSource == source.trim() && hlsVariants.isNotEmpty()) {
                            Spacer(Modifier.width(8.dp))
                            Text(tr(Str.HlsVariantsCount, hlsVariants.size), fontSize = 11.sp, color = FluxPalette.textMuted)
                        }
                    }
                    if (hlsVariantsSource == source.trim() && hlsVariantsError != null) {
                        Text(tr(Str.HlsVariantsFailed, hlsVariantsError), fontSize = 11.sp, color = FluxPalette.dangerStrong)
                    }
                    if (hlsVariantsSource == source.trim() && hlsVariants.isNotEmpty()) {
                        Column(
                            modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(FluxPalette.background).padding(8.dp),
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
                                    Text("#${variant.index} ${details.ifBlank { tr(Str.HlsVariantNoInfo) }}", modifier = Modifier.weight(1f), fontSize = 11.sp)
                                }
                            }
                        }
                    }
                    OutlinedTextField(
                        value = hlsVariant,
                        onValueChange = { value -> hlsVariant = value.filter(Char::isDigit) },
                        label = { Text(tr(Str.HlsVariantLabel), fontSize = 12.sp) },
                        supportingText = { Text(if (hlsVariantError) tr(Str.InvalidHlsIndex) else tr(Str.HlsVariantHint)) },
                        isError = hlsVariantError,
                        modifier = Modifier.fillMaxWidth(),
                        singleLine = true,
                    )
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Checkbox(
                            checked = hlsKeepTransportStream,
                            onCheckedChange = { hlsKeepTransportStream = it },
                        )
                        Text(tr(Str.KeepTransportStream), fontSize = 12.sp, color = FluxPalette.textStrongAlt2)
                    }
                }
                if (torrentMetadataLoading) {
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().height(3.dp),
                        color = FluxPalette.accent,
                        trackColor = FluxPalette.surfaceTintAlt3,
                    )
                    Text(
                        tr(Str.LoadingManifestHint),
                        fontSize = 11.sp,
                        color = FluxPalette.textStrongAlt3,
                    )
                }
                Button(
                    onClick = {
                        if (sourceError == null && !hlsVariantError && !busy) {
                            onConfirm(source, fileName, outputPath, credentialRef, "", hlsVariantIndex.takeIf { isHlsSource }, hlsKeepTransportStream && isHlsSource)
                        }
                    },
                    enabled = sourceError == null && !hlsVariantError && !busy,
                    modifier = Modifier.fillMaxWidth().height(44.dp),
                    shape = RoundedCornerShape(8.dp),
                ) {
                    if (torrentMetadataLoading) {
                        Text(tr(Str.LoadingManifest), fontSize = 13.sp, fontWeight = FontWeight.Normal)
                    } else if (newTaskSubmitting) {
                        Text(tr(Str.CreatingTask), fontSize = 13.sp, fontWeight = FontWeight.Normal)
                    } else {
                        Icon(Icons.Default.Download, contentDescription = null, modifier = Modifier.size(17.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(tr(Str.StartDownload), fontSize = 13.sp, fontWeight = FontWeight.Normal)
                    }
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
