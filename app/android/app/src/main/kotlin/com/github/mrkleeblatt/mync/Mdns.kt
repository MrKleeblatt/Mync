package com.github.mrkleeblatt.mync

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/**
 * Kanal „mync/mdns“: mync per mDNS/DNS-SD bekannt machen und andere Geräte
 * finden (NsdManager). Funde gehen als „found“ {host, port, txt} an Dart.
 */
class Mdns(context: Context, private val channel: MethodChannel) :
    MethodChannel.MethodCallHandler {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val main = Handler(Looper.getMainLooper())

    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null

    /** Auflösen geht vor Android 14 nur eins nach dem anderen. */
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "register" -> {
                    unregister()
                    val info = NsdServiceInfo().apply {
                        serviceName = call.argument<String>("name")!!
                        serviceType = call.argument<String>("type")!!
                        port = call.argument<Int>("port")!!
                        for ((k, v) in call.argument<Map<String, String>>("txt").orEmpty()) {
                            setAttribute(k, v)
                        }
                    }
                    val l = object : NsdManager.RegistrationListener {
                        override fun onServiceRegistered(i: NsdServiceInfo) {}
                        override fun onRegistrationFailed(i: NsdServiceInfo, code: Int) {
                            if (registration == this) registration = null
                        }
                        override fun onServiceUnregistered(i: NsdServiceInfo) {}
                        override fun onUnregistrationFailed(i: NsdServiceInfo, code: Int) {}
                    }
                    registration = l
                    nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, l)
                    result.success(null)
                }
                "unregister" -> {
                    unregister()
                    result.success(null)
                }
                "browse" -> {
                    stopBrowse()
                    val l = object : NsdManager.DiscoveryListener {
                        override fun onDiscoveryStarted(type: String) {}
                        override fun onDiscoveryStopped(type: String) {}
                        override fun onStartDiscoveryFailed(type: String, code: Int) {
                            if (discovery == this) discovery = null
                        }
                        override fun onStopDiscoveryFailed(type: String, code: Int) {}
                        override fun onServiceFound(info: NsdServiceInfo) {
                            main.post { queue(info) }
                        }
                        override fun onServiceLost(info: NsdServiceInfo) {}
                    }
                    discovery = l
                    nsd.discoverServices(
                        call.argument<String>("type")!!,
                        NsdManager.PROTOCOL_DNS_SD,
                        l,
                    )
                    result.success(null)
                }
                "stopBrowse" -> {
                    stopBrowse()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("mdns", e.toString(), null)
        }
    }

    private fun unregister() {
        registration?.let { l ->
            try { nsd.unregisterService(l) } catch (e: Exception) {}
        }
        registration = null
    }

    private fun stopBrowse() {
        discovery?.let { l ->
            try { nsd.stopServiceDiscovery(l) } catch (e: Exception) {}
        }
        discovery = null
        pending.clear()
    }

    private fun queue(info: NsdServiceInfo) {
        pending.addLast(info)
        next()
    }

    @Suppress("DEPRECATION")
    private fun next() {
        if (resolving) return
        val info = pending.removeFirstOrNull() ?: return
        resolving = true
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(i: NsdServiceInfo, code: Int) {
                    main.post { resolving = false; next() }
                }
                override fun onServiceResolved(i: NsdServiceInfo) {
                    main.post {
                        report(i)
                        resolving = false
                        next()
                    }
                }
            })
        } catch (e: Exception) {
            resolving = false
            main.post { next() }
        }
    }

    @Suppress("DEPRECATION")
    private fun report(i: NsdServiceInfo) {
        val addrs = if (Build.VERSION.SDK_INT >= 34) i.hostAddresses else listOfNotNull(i.host)
        val host = (addrs.firstOrNull { it is Inet4Address } ?: addrs.firstOrNull())
            ?.hostAddress ?: return
        val txt = HashMap<String, String>()
        for ((k, v) in i.attributes) {
            if (v != null) txt[k] = String(v, Charsets.UTF_8)
        }
        channel.invokeMethod(
            "found",
            mapOf("host" to host, "port" to i.port, "txt" to txt),
        )
    }
}
