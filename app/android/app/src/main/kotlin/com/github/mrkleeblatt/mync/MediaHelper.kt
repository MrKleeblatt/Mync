package com.github.mrkleeblatt.mync

import android.annotation.SuppressLint
import android.app.ActivityManager
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.widget.Toast
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Kanal „mync/media“ – was ein Musikplayer wie Musicolet außer der
 * Mediensitzung noch braucht:
 *  - Audiofokus: beim Abspielen anfordern, damit Android mync als die
 *    spielende Medien-App erkennt (Medienausgabe, Medientasten) und andere
 *    Apps verstummen; Verlust (Anruf, andere App) wird an Dart gemeldet.
 *  - kurze Hinweise als Toast (auch, wenn mync im Hintergrund läuft).
 */
class MediaHelper(context: Context, private val channel: MethodChannel) :
    MethodChannel.MethodCallHandler {
    private val app = context.applicationContext
    private val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private var request: AudioFocusRequest? = null
    private var hasFocus = false

    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        val what = when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> "gain"
            AudioManager.AUDIOFOCUS_LOSS -> "loss"
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> "lossTransient"
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> "duck"
            else -> return@OnAudioFocusChangeListener
        }
        hasFocus = change == AudioManager.AUDIOFOCUS_GAIN
        main.post { channel.invokeMethod("focus", what) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestFocus" -> result.success(requestFocus())
            "abandonFocus" -> {
                abandonFocus()
                result.success(null)
            }
            "diagnose" -> result.success(diagnose())
            "ignoreBatteryOptimizations" -> result.success(requestIgnoreBattery())
            "toast" -> {
                Toast.makeText(app, call.arguments as String, Toast.LENGTH_SHORT).show()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun requestFocus(): Boolean {
        if (hasFocus) return true
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val r = request ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                // Navigation o. Ä.: Android senkt die Lautstärke selbst ab
                .setWillPauseWhenDucked(false)
                .setOnAudioFocusChangeListener(listener, main)
                .build()
                .also { request = it }
            audio.requestAudioFocus(r)
        } else {
            @Suppress("DEPRECATION")
            audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        hasFocus = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return hasFocus
    }

    private fun abandonFocus() {
        if (!hasFocus) return
        hasFocus = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            request?.let { audio.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audio.abandonAudioFocus(listener)
        }
    }

    /**
     * Zustand für das Logbuch: Erscheint mync nicht in der Medienausgabe
     * oder wird es im Hintergrund beendet, steht hier, woran es liegt
     * (Benachrichtigungen aus, Dienst nicht im Vordergrund, Akku-Optimierung).
     */
    @Suppress("DEPRECATION")
    private fun diagnose(): Map<String, Any?> {
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val am = app.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        val service = try {
            am.getRunningServices(50).firstOrNull {
                it.service.className == "com.ryanheise.audioservice.AudioService"
            }
        } catch (e: Exception) { null }
        val media = try {
            nm.activeNotifications.count {
                it.notification.extras.containsKey("android.mediaSession")
            }
        } catch (e: Exception) { -1 }
        return mapOf(
            "sdk" to Build.VERSION.SDK_INT,
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
            "notifications" to nm.areNotificationsEnabled(),
            "channel" to if (Build.VERSION.SDK_INT >= 26) {
                nm.getNotificationChannel("com.github.mrkleeblatt.mync.wiedergabe")?.importance
            } else null,
            "service" to (service != null),
            "foreground" to (service?.foreground == true),
            "mediaNotifications" to media,
            "batteryOptimized" to !pm.isIgnoringBatteryOptimizations(app.packageName),
            "backgroundRestricted" to if (Build.VERSION.SDK_INT >= 28) {
                am.isBackgroundRestricted
            } else false,
        )
    }

    /** Fragt, ob mync von der Akku-Optimierung ausgenommen werden darf. */
    @SuppressLint("BatteryLife")
    private fun requestIgnoreBattery(): Boolean {
        val pm = app.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (pm.isIgnoringBatteryOptimizations(app.packageName)) return true
        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${app.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            app.startActivity(intent)
            false
        } catch (e: Exception) {
            // ältere/abweichende Geräte: Liste der Akku-Optimierung öffnen
            try {
                app.startActivity(
                    Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            } catch (e2: Exception) {}
            false
        }
    }
}
