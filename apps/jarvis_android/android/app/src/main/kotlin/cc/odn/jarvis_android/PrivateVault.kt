package cc.odn.jarvis_android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class PrivateVault(private val context: Context) {
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("jarvis-private-state-v1", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("jarvis-private-state-v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    fun state(): File = File(context.noBackupFilesDir, "jarvis-state-v1.aes")
    fun blob(id: String): File {
        require(id.matches(Regex("[A-Za-z0-9_-]{1,160}")))
        return File(File(context.noBackupFilesDir, "attachments").apply { mkdirs() }, "$id.aes")
    }
    fun read(path: File): ByteArray? {
        val file = AtomicFile(path)
        if (!path.exists() && !File(path.path + ".bak").exists()) return null
        val bytes = file.readFully()
        try {
            require(bytes.size >= 29 && bytes[0].toInt() == 1)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(1, 13)))
            return cipher.doFinal(bytes.copyOfRange(13, bytes.size))
        } catch (e: Exception) {
            // Preserve the original encrypted bytes even if a later user action saves new state.
            File(context.noBackupFilesDir, "unreadable-${System.currentTimeMillis()}-${path.name}").writeBytes(bytes)
            throw e
        }
    }
    fun write(path: File, plain: ByteArray) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key()); require(cipher.iv.size == 12)
        val bytes = byteArrayOf(1) + cipher.iv + cipher.doFinal(plain)
        val file = AtomicFile(path); val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) } catch (e: Exception) { file.failWrite(stream); throw e }
    }
}
