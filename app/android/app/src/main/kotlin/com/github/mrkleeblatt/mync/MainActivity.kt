package com.github.mrkleeblatt.mync

import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Kanal „mync/storage“: Berechtigung „Zugriff auf alle Dateien“
 * (MANAGE_EXTERNAL_STORAGE) prüfen und die Systemeinstellung dafür öffnen.
 * Nötig, damit der Zig-Kern Musikdateien umbenennen, löschen und taggen kann.
 *
 * Erbt von AudioServiceActivity (audio_service), damit Activity und
 * Wiedergabedienst dieselbe Flutter-Engine nutzen.
 */
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/storage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasAllFilesAccess" -> result.success(Environment.isExternalStorageManager())
                    "requestAllFilesAccess" -> {
                        val intent = Intent(
                            Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                            Uri.parse("package:$packageName"),
                        )
                        startActivity(intent)
                        result.success(null)
                    }
                    "scanFiles" -> {
                        // Nach dem Sync: Änderungen für Musicolet & Co. bekannt machen
                        val paths = call.arguments as? List<*> ?: emptyList<Any>()
                        MediaScannerConnection.scanFile(
                            this,
                            paths.filterIsInstance<String>().toTypedArray(),
                            null,
                            null,
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
