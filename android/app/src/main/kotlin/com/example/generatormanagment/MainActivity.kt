package com.example.generatormanagment

import android.content.Context
import android.os.Build
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface

/// Exposes a best-effort hardware-id channel for device binding.
///
/// IMPORTANT: on Android 10+ (API 29) IMEI is NOT available to normal apps
/// (getImei throws SecurityException) and the Wi-Fi MAC is randomized. These
/// methods are wrapped defensively and simply return null when blocked — the
/// app falls back to the persistent installId + SSAID for binding.
class MainActivity : FlutterActivity() {
    private val channelName = "moldati/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getHardwareIds" -> {
                        val map = HashMap<String, Any?>()
                        map["imei"] = tryGetImei()
                        map["mac"] = tryGetMac()
                        result.success(map)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun tryGetImei(): String? {
        return try {
            val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager? ?: return null
            @Suppress("DEPRECATION", "HardwareIds")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) tm.imei else tm.deviceId
        } catch (e: Exception) {
            null
        }
    }

    private fun tryGetMac(): String? {
        return try {
            for (nif in NetworkInterface.getNetworkInterfaces()) {
                if (!nif.name.equals("wlan0", ignoreCase = true)) continue
                val bytes = nif.hardwareAddress ?: return null
                val sb = StringBuilder()
                for (b in bytes) sb.append(String.format("%02X:", b))
                if (sb.isNotEmpty()) sb.deleteCharAt(sb.length - 1)
                return sb.toString()
            }
            null
        } catch (e: Exception) {
            null
        }
    }
}
