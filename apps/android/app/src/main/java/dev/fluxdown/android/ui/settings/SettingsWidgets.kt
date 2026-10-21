package dev.fluxdown.android.ui.settings
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.sp
import dev.fluxdown.android.data.*
import dev.fluxdown.android.platform.AndroidStorageStats
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
internal fun StorageStatsPanel(
    stats: AndroidStorageStats?,
    loading: Boolean,
    unavailable: Boolean,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = FluxPalette.background),
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, FluxPalette.borderAlt),
    ) {
        if (loading && stats == null) {
            Text(tr(Str.ReadingSizeHint), modifier = Modifier.padding(10.dp), fontSize = 11.sp, color = FluxPalette.textMuted)
        } else if (stats == null || unavailable) {
            Text(tr(Str.CannotReadSize), modifier = Modifier.padding(10.dp), fontSize = 11.sp, color = FluxPalette.textMuted)
        } else {
            Row(Modifier.fillMaxWidth().padding(4.dp), horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                StorageStatItem(tr(Str.StorageTotal), formatBytes(stats.totalBytes))
                StorageStatItem(tr(Str.StorageUsed), formatBytes(stats.usedBytes))
                StorageStatItem(tr(Str.StorageFree), formatBytes(stats.freeBytes))
            }
        }
    }
}

@Composable
internal fun RowScope.StorageStatItem(label: String, value: String) {
    Box(
        Modifier
            .weight(1f)
            .clip(RoundedCornerShape(8.dp))
            .background(FluxPalette.surfaceTintAlt)
            .padding(horizontal = 6.dp, vertical = 4.dp),
    ) {
        Column {
            Text(label, fontSize = 9.5.sp, color = FluxPalette.textMuted, maxLines = 1)
            Text(value, fontSize = 11.5.sp, color = FluxPalette.textStrongAlt, maxLines = 1)
        }
    }
}

@Composable
internal fun SettingsCompactRow(
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
                .background(FluxPalette.chipBackground),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = FluxPalette.textStrong, modifier = Modifier.size(13.dp))
        }
        Spacer(Modifier.width(7.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, fontSize = 11.8.sp, color = FluxPalette.textPrimary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, fontSize = 10.sp, lineHeight = 10.5.sp, color = FluxPalette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(7.dp))
        trailing()
    }
}

@Composable
internal fun SettingsValueRow(
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
                placeholder = { Text(placeholder, fontSize = 11.sp, color = FluxPalette.textSecondary, maxLines = 1) },
                textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, textAlign = TextAlign.End, color = FluxPalette.textPrimary),
                trailingIcon = if (suffix.isBlank()) null else {
                    { Text(suffix, fontSize = 10.sp, color = FluxPalette.textSecondary, modifier = Modifier.padding(end = 6.dp)) }
                },
                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                    unfocusedContainerColor = FluxPalette.surfaceCard,
                    focusedContainerColor = FluxPalette.surfaceCard,
                    unfocusedBorderColor = FluxPalette.border,
                    focusedBorderColor = FluxPalette.accent,
                ),
                shape = RoundedCornerShape(12.dp),
            )
        },
    )
}

@Composable
internal fun SettingsSection(title: String, content: @Composable () -> Unit) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(containerColor = FluxPalette.surfaceCard),
        shape = RoundedCornerShape(12.dp),
    ) {
        Column(Modifier.fillMaxWidth().padding(14.dp)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = FluxPalette.textStrongAlt4)
            Spacer(Modifier.height(10.dp))
            content()
        }
    }
}

@Composable
internal fun SettingsGroupTitle(title: String, icon: androidx.compose.ui.graphics.vector.ImageVector) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(24.dp).clip(RoundedCornerShape(7.dp)).background(FluxPalette.surfaceTint), contentAlignment = Alignment.Center) {
            Icon(icon, contentDescription = null, tint = FluxPalette.accent, modifier = Modifier.size(14.dp))
        }
        Spacer(Modifier.width(7.dp))
        Text(title, fontSize = 11.sp, color = FluxPalette.accentStrong, fontWeight = FontWeight.Normal)
    }
}

@Composable
internal fun SettingsDivider() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(FluxPalette.surfaceMutedAlt))
}

@Composable
internal fun SettingField(label: String, value: String, hint: String, onValueChange: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, fontSize = 13.sp, color = FluxPalette.textPrimary)
            Text(hint, fontSize = 9.5.sp, color = FluxPalette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Spacer(Modifier.width(10.dp))
        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            modifier = Modifier.widthIn(min = 78.dp, max = 108.dp).height(44.dp),
            singleLine = true,
            textStyle = androidx.compose.ui.text.TextStyle(fontSize = 12.sp, color = FluxPalette.textPrimary),
            placeholder = { Text(tr(Str.UnitNone), fontSize = 11.sp, color = FluxPalette.textDisabled) },
        )
    }
}

/**
 * 作者: long
 * 设置页的开关行：复用 SettingsCompactRow 的排版，右侧放 Material3 Switch，
 * 点击整行也能切换，符合设置项的常规交互。
 */
@Composable
internal fun SettingsSwitchRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    SettingsCompactRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        trailing = {
            Switch(
                checked = checked,
                onCheckedChange = onCheckedChange,
                modifier = Modifier
                    .size(width = 42.dp, height = 26.dp)
                    .clickable { onCheckedChange(!checked) },
            )
        },
    )
}

/**
 * 作者: long
 * 设置页的枚举选择行（主题 / 语言 / 筛选）：点开弹框列出候选项，选中后立即生效。
 */
@Composable
internal fun SettingsChoiceRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    subtitle: String,
    currentLabel: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
) {
    var showDialog by remember { mutableStateOf(false) }
    SettingsCompactRow(
        icon = icon,
        title = title,
        subtitle = subtitle,
        trailing = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(currentLabel, fontSize = 11.5.sp, color = FluxPalette.accentStrong, maxLines = 1)
                IconButton(onClick = { showDialog = true }, modifier = Modifier.size(34.dp)) {
                    Icon(Icons.Default.ChevronRight, contentDescription = tr(Str.ChooseTitle, title), tint = FluxPalette.textStrong, modifier = Modifier.size(18.dp))
                }
            }
        },
    )
    if (showDialog) {
        AlertDialog(
            onDismissRequest = { showDialog = false },
            title = { Text(title, fontSize = 16.sp) },
            text = {
                Column(Modifier.fillMaxWidth()) {
                    options.forEach { (value, label) ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(6.dp))
                                .clickable { showDialog = false; onSelect(value) }
                                .padding(horizontal = 8.dp, vertical = 11.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(label, fontSize = 13.sp, color = FluxPalette.textPrimary, modifier = Modifier.weight(1f))
                            if (value == currentLabel || label == currentLabel) {
                                Icon(Icons.Default.Check, contentDescription = null, tint = FluxPalette.accentStrong, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { showDialog = false }) { Text(tr(Str.Close)) } },
        )
    }
}
