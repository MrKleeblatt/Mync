package com.github.mrkleeblatt.mync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Kanal „mync/volume“: meldet Änderungen der Medienlautstärke des Systems
 * (Lautstärketasten) an Dart – bei 0 pausiert mync. Android schickt dafür
 * VOLUME_CHANGED_ACTION; registriert mit dem App-Kontext, damit es auch bei
 * Wiedergabe im Hintergrund ankommt.
 */
class SystemVolume(context: Context, private val channel: MethodChannel) {
    private val app = context.applicationContext
    private val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var last = audio.getStreamVolume(AudioManager.STREAM_MUSIC)

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val stream = intent.getIntExtra("android.media.EXTRA_VOLUME_STREAM_TYPE", -1)
            if (stream != -1 && stream != AudioManager.STREAM_MUSIC) return
            val v = audio.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (v == last) return
            last = v
            channel.invokeMethod("musicVolume", v)
        }
    }

    fun start() {
        ContextCompat.registerReceiver(
            app,
            receiver,
            IntentFilter("android.media.VOLUME_CHANGED_ACTION"),
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }
}
