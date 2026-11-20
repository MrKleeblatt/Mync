package com.github.mrkleeblatt.mync

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Kanal „mync/fs“ (MusicFs.kt): Zugriff nur auf die vom Nutzer
 * freigegebenen Musikordner.
 *
 * Erbt von AudioServiceActivity (audio_service), damit Activity und
 * Wiedergabedienst dieselbe Flutter-Engine nutzen.
 */
class MainActivity : AudioServiceActivity() {
    private var fs: MusicFs? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val handler = MusicFs(this)
        fs = handler
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mync/fs")
            .setMethodCallHandler(handler)
    }

    @Deprecated("Ordnerauswahl über startActivityForResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (fs?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }
}
