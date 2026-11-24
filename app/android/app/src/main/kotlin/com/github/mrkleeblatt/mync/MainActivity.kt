package com.github.mrkleeblatt.mync

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Kanal „mync/fs“ (MusicFs.kt): Zugriff nur auf die vom Nutzer
 * freigegebenen Musikordner. Kanal „mync/app“ (AppUpdate.kt): Updates.
 *
 * Erbt von AudioServiceActivity (audio_service), damit Activity und
 * Wiedergabedienst dieselbe Flutter-Engine nutzen.
 */
class MainActivity : AudioServiceActivity() {
    private var fs: MusicFs? = null

    companion object {
        /** Einmal je Prozess (die Engine wird mit dem Wiedergabedienst geteilt). */
        private var volume: SystemVolume? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val handler = MusicFs(this)
        fs = handler
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/fs")
            .setMethodCallHandler(handler)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/app")
            .setMethodCallHandler(AppUpdate(this))
        if (volume == null) {
            volume = SystemVolume(
                this,
                MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/volume"),
            ).apply { start() }
        }
    }

    @Deprecated("Ordnerauswahl über startActivityForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (fs?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
