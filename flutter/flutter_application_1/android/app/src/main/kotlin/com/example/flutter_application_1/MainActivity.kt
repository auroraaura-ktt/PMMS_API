package com.example.flutter_application_1

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "pmms/session_storage"
        private const val PREFERENCES = "pmms_secure_session"
        private const val KEY_ALIAS = "pmms_session_key"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
        ).setMethodCallHandler { call, result ->
            try {
                val key = call.argument<String>("key")
                    ?: throw IllegalArgumentException("Storage key is required.")
                when (call.method) {
                    "read" -> result.success(readValue(key))
                    "write" -> {
                        val value = call.argument<String>("value")
                            ?: throw IllegalArgumentException("Storage value is required.")
                        writeValue(key, value)
                        result.success(null)
                    }
                    "delete" -> {
                        deleteValue(key)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: IllegalArgumentException) {
                sendStorageError(result)
            } catch (_: IllegalStateException) {
                sendStorageError(result)
            } catch (_: GeneralSecurityException) {
                sendStorageError(result)
            } catch (_: IOException) {
                sendStorageError(result)
            } catch (_: SecurityException) {
                sendStorageError(result)
            }
        }
    }

    private fun sendStorageError(result: MethodChannel.Result) {
        result.error(
            "SESSION_STORAGE_ERROR",
            "Could not access encrypted PMMS session storage.",
            null,
        )
    }

    private fun readValue(key: String): String? {
        val saved = getSharedPreferences(PREFERENCES, MODE_PRIVATE).getString(key, null)
            ?: return null
        val parts = saved.split(':', limit = 2)
        if (parts.size != 2) throw IllegalStateException("Invalid encrypted value.")

        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            sessionKey(),
            GCMParameterSpec(128, Base64.decode(parts[0], Base64.NO_WRAP)),
        )
        val plaintext = cipher.doFinal(Base64.decode(parts[1], Base64.NO_WRAP))
        return plaintext.toString(Charsets.UTF_8)
    }

    private fun writeValue(key: String, value: String) {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, sessionKey())
        val encrypted = listOf(
            Base64.encodeToString(cipher.iv, Base64.NO_WRAP),
            Base64.encodeToString(cipher.doFinal(value.toByteArray(Charsets.UTF_8)), Base64.NO_WRAP),
        ).joinToString(":")
        val saved = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            .edit()
            .putString(key, encrypted)
            .commit()
        if (!saved) throw IllegalStateException("Could not save encrypted value.")
    }

    private fun deleteValue(key: String) {
        val deleted = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            .edit()
            .remove(key)
            .commit()
        if (!deleted) throw IllegalStateException("Could not delete encrypted value.")
    }

    private fun sessionKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (keyStore.containsAlias(KEY_ALIAS)) {
            return keyStore.getKey(KEY_ALIAS, null) as SecretKey
        }

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}
