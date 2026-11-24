package com.github.mrkleeblatt.mync

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Kanal „mync/app“ für Updates, wie in Kassenbon: eigene APK (für
 * Teil-Updates), Ablageordner, Version, Architektur und Installation.
 */
class AppUpdate(private val activity: Activity) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "apkPath" -> result.success(activity.applicationInfo.sourceDir)
                "updateDir" -> result.success(File(activity.filesDir, "updates").apply { mkdirs() }.path)
                "version" -> result.success(
                    activity.packageManager.getPackageInfo(activity.packageName, 0).versionName,
                )
                "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull())
                "openUrl" -> {
                    activity.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url")!!))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "canInstall" -> result.success(
                    Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls(),
                )
                "openInstallSettings" -> {
                    activity.startActivity(
                        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")),
                    )
                    result.success(null)
                }
                "install" -> {
                    val file = File(call.argument<String>("path")!!)
                    val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", file)
                    activity.startActivity(
                        Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        },
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("app", e.toString(), null)
        }
    }
}
