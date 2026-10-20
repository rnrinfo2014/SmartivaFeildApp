package com.smartiva.smartiva_fieldops

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.smartiva.fieldops/network")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticast" -> {
                        try {
                            val manager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            val lock = multicastLock ?: manager.createMulticastLock("SmartivaFieldOpsScan").also {
                                it.setReferenceCounted(false)
                                multicastLock = it
                            }
                            if (!lock.isHeld) lock.acquire()
                            result.success(null)
                        } catch (_: Exception) {
                            result.error("multicast_unavailable", "Wi-Fi multicast is unavailable", null)
                        }
                    }
                    "releaseMulticast" -> {
                        releaseMulticast()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun releaseMulticast() {
        multicastLock?.let { if (it.isHeld) it.release() }
    }

    override fun onDestroy() {
        releaseMulticast()
        super.onDestroy()
    }
}
