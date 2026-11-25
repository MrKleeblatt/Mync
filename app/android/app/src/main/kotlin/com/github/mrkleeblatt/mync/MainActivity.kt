package com.github.mrkleeblatt.mync

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Kanal „mync/fs“ (MusicFs.kt): Zugriff nur auf die vom Nutzer
 * freigegebenen Musikordner. Kanal „mync/app“ (AppUpdate.kt): Updates.
 * Kanal „mync/net“: eigene IPv4-Adressen mit Netzgröße für die Gerätesuche.
 *
 * Erbt von AudioServiceActivity (audio_service), damit Activity und
 * Wiedergabedienst dieselbe Flutter-Engine nutzen.
 */
class MainActivity : AudioServiceActivity() {
    private var fs: MusicFs? = null

    companion object {
        /** Einmal je Prozess (die Engine wird mit dem Wiedergabedienst geteilt). */
        private var volume: SystemVolume? = null
        private var media: MediaHelper? = null
        private var mdns: Mdns? = null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+: ohne diese Erlaubnis zeigt Android (je nach Gerät, z. B.
        // Samsung) keine Wiedergabe-Benachrichtigung – dann fehlt mync in der
        // Medienausgabe und auf dem Sperrbildschirm. Musicolet fragt ebenso.
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 7301)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val handler = MusicFs(this)
        fs = handler
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/fs")
            .setMethodCallHandler(handler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/app")
            .setMethodCallHandler(AppUpdate(this))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/net")
            .setMethodCallHandler { call, result ->
                if (call.method == "deviceName") {
                    return@setMethodCallHandler result.success(deviceName())
                }
                if (call.method != "ipv4") return@setMethodCallHandler result.notImplemented()
                try {
                    // mit Netzgröße und auch für die Hotspot-Schnittstelle,
                    // die dart:io nicht immer liefert
                    val list = mutableListOf<String>()
                    for (nif in NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()) {
                        if (!nif.isUp || nif.isLoopback) continue
                        for (ia in nif.interfaceAddresses) {
                            val a = ia.address
                            if (a is Inet4Address) {
                                list.add("${a.hostAddress}/${ia.networkPrefixLength}%${nif.name}")
                            }
                        }
                    }
                    result.success(list)
                } catch (e: Exception) {
                    result.error("net", e.toString(), null)
                }
            }
        if (volume == null) {
            volume = SystemVolume(
                this,
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/volume"),
            ).apply { start() }
        }
        if (mdns == null) {
            val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/mdns")
            mdns = Mdns(applicationContext, ch).also { ch.setMethodCallHandler(it) }
        }
        if (media == null) {
            val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/media")
            media = MediaHelper(this, ch).also { ch.setMethodCallHandler(it) }
        }
    }

    @Deprecated("Ordnerauswahl über startActivityForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (fs?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    /** Gerätename wie in den Einstellungen („Über das Telefon“), sonst Modell. */
    private fun deviceName(): String {
        val cr = contentResolver
        val names = listOf(
            {
                if (Build.VERSION.SDK_INT >= 25) {
                    Settings.Global.getString(cr, Settings.Global.DEVICE_NAME)
                } else null
            },
            { Settings.Secure.getString(cr, "bluetooth_name") },
            { Settings.System.getString(cr, "device_name") },
        )
        for (n in names) {
            val v = try { n() } catch (e: Exception) { null }
            if (!v.isNullOrBlank()) return v.trim()
        }
        val model = Build.MODEL ?: "Android"
        val maker = Build.MANUFACTURER ?: ""
        return if (model.startsWith(maker, ignoreCase = true)) model
        else "${maker.replaceFirstChar { it.uppercase() }} $model".trim()
    }
}
