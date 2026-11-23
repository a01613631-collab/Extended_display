package dev.jose.tabdisplay

import android.content.Context

/** Ajustes persistentes de la tablet: emparejamiento Wi-Fi y preferencias simples. */
class AppPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("tabdisplay", Context.MODE_PRIVATE)

    /** Token recibido por USB en HELLO_ACK; obligatorio para conectar por Wi-Fi. */
    val pairingToken: String?
        get() = prefs.getString(KEY_TOKEN, null)

    val pairedMacName: String?
        get() = prefs.getString(KEY_MAC_NAME, null)

    var wifiEnabled: Boolean
        get() = prefs.getBoolean(KEY_WIFI, true)
        set(value) = prefs.edit().putBoolean(KEY_WIFI, value).apply()

    var overlayVisible: Boolean
        get() = prefs.getBoolean(KEY_OVERLAY, false)
        set(value) = prefs.edit().putBoolean(KEY_OVERLAY, value).apply()

    fun savePairing(token: String, macName: String?) {
        prefs.edit().putString(KEY_TOKEN, token).putString(KEY_MAC_NAME, macName).apply()
    }

    fun clearPairing() {
        prefs.edit().remove(KEY_TOKEN).remove(KEY_MAC_NAME).apply()
    }

    private companion object {
        const val KEY_TOKEN = "pairing_token"
        const val KEY_MAC_NAME = "paired_mac_name"
        const val KEY_WIFI = "wifi_enabled"
        const val KEY_OVERLAY = "overlay_visible"
    }
}
