package dev.blemesh.ble_mesh

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Stores the mesh identity's private keys under an AES key held by the Android
 * Keystore.
 *
 * The seeds themselves are Ed25519 and X25519 material, which the Keystore
 * cannot hold directly on every API level. Wrapping them with a non-exportable
 * Keystore AES key gets the property that matters: the bytes on disk are
 * useless without a key that cannot leave the secure hardware, so copying the
 * app's data directory off a rooted device does not yield a usable identity.
 */
class KeyVault(context: Context) {
    private val preferences =
        context.getSharedPreferences("ble_mesh_keys", Context.MODE_PRIVATE)

    fun read(name: String): ByteArray? {
        val stored = preferences.getString(name, null) ?: return null
        val combined = android.util.Base64.decode(stored, android.util.Base64.NO_WRAP)
        require(combined.size > IV_LENGTH) { "Invalid stored identity" }
        return run {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(TAG_BITS, combined, 0, IV_LENGTH)
            )
            cipher.doFinal(combined, IV_LENGTH, combined.size - IV_LENGTH)
        }
    }

    fun write(name: String, value: ByteArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val sealed = cipher.doFinal(value)
        val combined = cipher.iv + sealed
        check(preferences.edit()
            .putString(name, android.util.Base64.encodeToString(combined, android.util.Base64.NO_WRAP))
            .commit()) { "Could not persist identity" }
    }

    fun delete(name: String) {
        check(preferences.edit().remove(name).commit()) { "Could not delete identity" }
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(PROVIDER).apply { load(null) }
        (keyStore.getEntry(WRAPPING_KEY, null) as? KeyStore.SecretKeyEntry)
            ?.let { return it.secretKey }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, PROVIDER)
        generator.init(
            KeyGenParameterSpec.Builder(
                WRAPPING_KEY,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                // Deliberately not requiring user authentication: the mesh has
                // to relay and receive while the phone is locked in a pocket.
                .setUserAuthenticationRequired(false)
                .build()
        )
        return generator.generateKey()
    }

    companion object {
        private const val PROVIDER = "AndroidKeyStore"
        private const val WRAPPING_KEY = "ble_mesh_identity_wrapping_key"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val IV_LENGTH = 12
        private const val TAG_BITS = 128
        const val CHANNEL = "dev.blemesh.ble_mesh/keys"

        fun register(messenger: BinaryMessenger, context: Context): MethodChannel {
            val vault = KeyVault(context)
            val channel = MethodChannel(messenger, CHANNEL)
            channel.setMethodCallHandler { call, result -> vault.handle(call, result) }
            return channel
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "isAvailable" -> result.success(true)
                "read" -> result.success(read(call.argument<String>("key")!!))
                "write" -> {
                    write(call.argument<String>("key")!!, call.argument<ByteArray>("value")!!)
                    result.success(null)
                }
                "delete" -> {
                    delete(call.argument<String>("key")!!)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("keystore_failed", error.message, null)
        }
    }
}
