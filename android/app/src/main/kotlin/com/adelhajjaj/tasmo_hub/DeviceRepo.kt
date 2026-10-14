package com.adelhajjaj.tasmo_hub

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** One switchable output: a device plus one relay key (POWER, POWER1, ...). */
data class Target(
    val deviceId: String,
    val name: String,
    val host: String,
    val user: String,
    val relay: String,
    val locked: Boolean,
) {
    /** Stable key used to bind a widget or tile to this output. */
    val key: String get() = "$deviceId|$relay"
}

/**
 * Native copy of the device list for widgets and Quick Settings tiles.
 *
 * Device data lives in private SharedPreferences. Web passwords are
 * encrypted with an AES-GCM key that never leaves the Android Keystore,
 * so they are not readable from a backup or a rooted file dump.
 */
object DeviceRepo {
    private const val PREFS = "tasmohub_native"
    private const val KEY_ALIAS = "tasmohub_widget_key"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun sync(ctx: Context, devicesJson: String, passwords: Map<String, String>) {
        val e = prefs(ctx).edit()
        e.putString("devices", devicesJson)
        // Drop stale passwords, then store the current ones encrypted.
        prefs(ctx).all.keys.filter { it.startsWith("pw_") }.forEach { e.remove(it) }
        for ((id, pw) in passwords) {
            if (pw.isNotEmpty()) e.putString("pw_$id", encrypt(pw))
        }
        e.apply()
    }

    /** Every switchable output, one per relay. */
    fun targets(ctx: Context): List<Target> {
        val raw = prefs(ctx).getString("devices", "[]") ?: "[]"
        val out = mutableListOf<Target>()
        val arr = try { JSONArray(raw) } catch (_: Exception) { JSONArray() }
        for (i in 0 until arr.length()) {
            val d = arr.optJSONObject(i) ?: continue
            val relays = d.optJSONArray("relays")
            val keys = mutableListOf<String>()
            if (relays != null) for (r in 0 until relays.length()) keys.add(relays.optString(r))
            if (keys.isEmpty()) keys.add("POWER")
            for (k in keys) {
                val label = if (keys.size == 1) d.optString("name")
                else "${d.optString("name")} · ${k.replace("POWER", "#")}"
                out.add(
                    Target(
                        deviceId = d.optString("id"),
                        name = label,
                        host = d.optString("host"),
                        user = d.optString("user", "admin"),
                        relay = k,
                        locked = d.optBoolean("locked", false),
                    )
                )
            }
        }
        return out
    }

    fun target(ctx: Context, key: String?): Target? =
        if (key == null) null else targets(ctx).firstOrNull { it.key == key }

    // ---- bindings (widget id / tile name -> target key) -----------------

    fun bind(ctx: Context, slot: String, key: String) =
        prefs(ctx).edit().putString("bind_$slot", key).apply()

    fun unbind(ctx: Context, slot: String) =
        prefs(ctx).edit().remove("bind_$slot").apply()

    fun boundKey(ctx: Context, slot: String): String? =
        prefs(ctx).getString("bind_$slot", null)

    /** Last known state: 1 on, 0 off, -1 unknown/unreachable. */
    fun cachedState(ctx: Context, key: String): Int =
        prefs(ctx).getInt("state_$key", -1)

    private fun cache(ctx: Context, key: String, on: Boolean?) =
        prefs(ctx).edit().putInt("state_$key", if (on == null) -1 else if (on) 1 else 0).apply()

    // ---- HTTP -----------------------------------------------------------

    /** Sends `<relay> <arg>` and returns the new on/off state, or null. Blocking. */
    fun power(ctx: Context, t: Target, arg: String): Boolean? {
        val pw = password(ctx, t.deviceId)
        val q = StringBuilder()
        if (!pw.isNullOrEmpty()) {
            q.append("user=").append(enc(t.user.ifEmpty { "admin" }))
            q.append("&password=").append(enc(pw)).append('&')
        }
        q.append("cmnd=").append(enc(if (arg.isEmpty()) t.relay else "${t.relay} $arg"))
        val result = try {
            val conn = URL("http://${t.host}/cm?$q").openConnection() as HttpURLConnection
            conn.connectTimeout = 3000
            conn.readTimeout = 4000
            try {
                if (conn.responseCode != 200) null
                else {
                    val body = conn.inputStream.bufferedReader().use { it.readText() }
                    parsePower(JSONObject(body), t.relay)
                }
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            null
        }
        cache(ctx, t.key, result)
        return result
    }

    fun query(ctx: Context, t: Target) = power(ctx, t, "")
    fun toggle(ctx: Context, t: Target) = power(ctx, t, "TOGGLE")

    /** A single-relay device may answer POWER1 for POWER, or vice versa. */
    private fun parsePower(j: JSONObject, relay: String): Boolean? {
        val candidates = when (relay) {
            "POWER" -> listOf("POWER", "POWER1")
            "POWER1" -> listOf("POWER1", "POWER")
            else -> listOf(relay)
        }
        for (k in candidates) {
            if (j.has(k)) {
                val v = j.opt(k)
                return when (v) {
                    is String -> v.equals("ON", ignoreCase = true)
                    is Number -> v.toInt() != 0
                    else -> null
                }
            }
        }
        return null
    }

    private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

    // ---- crypto ---------------------------------------------------------

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun encrypt(plain: String): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        val iv = c.iv
        val ct = c.doFinal(plain.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(iv + ct, Base64.NO_WRAP)
    }

    private fun password(ctx: Context, deviceId: String): String? {
        val stored = prefs(ctx).getString("pw_$deviceId", null) ?: return null
        return try {
            val all = Base64.decode(stored, Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, all, 0, 12))
            String(c.doFinal(all, 12, all.size - 12), Charsets.UTF_8)
        } catch (_: Exception) {
            null
        }
    }
}
