package dev.fluxdown.android.ui.settings
import dev.fluxdown.android.*
import dev.fluxdown.android.ui.*
import dev.fluxdown.android.ui.queue.*
import dev.fluxdown.android.ui.settings.*
import dev.fluxdown.android.ui.newtask.*

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.input.PasswordVisualTransformation
import dev.fluxdown.android.data.*
import dev.fluxdown.android.platform.StoredAndroidCredential
import dev.fluxdown.android.viewmodel.*
import dev.fluxdown.android.ui.i18n.*

@Composable
internal fun CredentialEditorDialog(
    onDismiss: () -> Unit,
    onSave: (String, StoredAndroidCredential) -> Unit,
) {
    val language = LocalLanguage.current
    var reference by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var privateKeyPem by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var usePrivateKey by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(tr(Str.CredentialEditorTitle), fontSize = 16.sp) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                OutlinedTextField(reference, { reference = it }, label = { Text(tr(Str.FieldCredentialRef)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(username, { username = it }, label = { Text(tr(Str.CredentialUsername)) }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = usePrivateKey, onCheckedChange = { usePrivateKey = it })
                    Text(tr(Str.SftpPrivateKeyAuth), fontSize = 12.sp)
                }
                if (usePrivateKey) {
                    OutlinedTextField(privateKeyPem, { privateKeyPem = it }, label = { Text(tr(Str.CredentialPrivateKey)) }, minLines = 4, modifier = Modifier.fillMaxWidth())
                    OutlinedTextField(passphrase, { passphrase = it }, label = { Text(tr(Str.CredentialPassphrase)) }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                } else {
                    OutlinedTextField(password, { password = it }, label = { Text(tr(Str.CredentialPassword)) }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
                }
                error?.let { Text(it, color = FluxPalette.danger, fontSize = 11.sp) }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val normalizedReference = reference.trim()
                val normalizedUsername = username.trim()
                error = when {
                    normalizedReference.isEmpty() -> trIn(language, Str.CredentialRefRequired)
                    normalizedReference.length > 128 -> trIn(language, Str.CredentialRefTooLong)
                    normalizedUsername.isEmpty() -> trIn(language, Str.UsernameRequired)
                    usePrivateKey && (!privateKeyPem.contains("PRIVATE KEY") || privateKeyPem.length > 256 * 1024) -> trIn(language, Str.InvalidPrivateKey)
                    else -> null
                }
                if (error == null) {
                    onSave(
                        normalizedReference,
                        if (usePrivateKey) StoredAndroidCredential(normalizedUsername, privateKeyPem = privateKeyPem.trim(), passphrase = passphrase.trim().ifEmpty { null })
                        else StoredAndroidCredential(normalizedUsername, password = password),
                    )
                }
            }) { Text(tr(Str.Save)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(tr(Str.Cancel)) } },
    )
}
