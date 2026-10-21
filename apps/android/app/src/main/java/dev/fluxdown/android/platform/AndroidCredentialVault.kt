package dev.fluxdown.android.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import dev.fluxdown.android.ui.i18n.Str
import dev.fluxdown.android.ui.i18n.trApp

/**
 * 作者: long
 * 凭据仓库：明文永远不落盘，只用 Android Keystore 里的 AES/GCM 密钥加密后存进 SharedPreferences。
 * 队列文件里只保存"凭据引用"，Rust 侧拿到引用后再由这里解出真实密码或私钥。
 */
internal class AndroidCredentialVault(
    private val context: Context,
) {
    private val prefs = context.getSharedPreferences("fluxdown.kotlin.credentials", Context.MODE_PRIVATE)
    private val keyAlias = "fluxdown.android.credentials.v1"

    fun put(reference: String, credential: StoredAndroidCredential) {
        val normalized = normalizeReference(reference)
        require(credential.username.trim().isNotEmpty()) { trApp(Str.CredentialUserEmpty) }
        if (credential.usesPrivateKey) {
            val pem = credential.privateKeyPem!!.trim()
            require(pem.length <= 256 * 1024 && pem.contains("PRIVATE KEY")) { trApp(Str.SftpKeyInvalid) }
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
        require(normalized.isNotEmpty() && normalized.length <= 128) { trApp(Str.CredentialRefInvalidNotice) }
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
        require(packed.size > 12) { trApp(Str.CredentialInvalid) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, packed.copyOfRange(0, 12)))
        return cipher.doFinal(packed.copyOfRange(12, packed.size)).toString(Charsets.UTF_8)
    }
}
