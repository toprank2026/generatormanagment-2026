package com.example.generatormanagment

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicBoolean

/// Exposes two native channels:
///  - `moldati/device`: best-effort hardware ids for device binding.
///  - `moldati/usb` (v21): direct USB thermal printing (printer-CLASS, raw bulk
///    transfer) so the app can print without any third-party USB plugin. This
///    requests USB permission with the FLAG_IMMUTABLE that Android 12+ requires
///    (the bug that crashed the abandoned flutter_usb_printer plugin).
///
/// IMPORTANT: on Android 10+ (API 29) IMEI is NOT available to normal apps
/// (getImei throws SecurityException) and the Wi-Fi MAC is randomized. These
/// methods are wrapped defensively and simply return null when blocked — the
/// app falls back to the persistent installId + SSAID for binding.
class MainActivity : FlutterActivity() {
    private val channelName = "moldati/device"
    private val usbChannelName = "moldati/usb"
    private val actionUsbPermission = "com.example.generatormanagment.USB_PERMISSION"

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, usbChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "listUsbDevices" -> result.success(listUsbDevices())
                    "printBytes" -> {
                        val vid = call.argument<Int>("vendorId")
                        val pid = call.argument<Int>("productId")
                        val bytes = call.argument<ByteArray>("bytes")
                        if (vid == null || pid == null || bytes == null) {
                            result.error("bad_args", "vendorId/productId/bytes required", null)
                        } else {
                            printBytes(vid, pid, bytes, result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ---------------------------------------------------------------- USB ----

    /// Enumerates the attached USB devices as maps the Dart side can read.
    private fun listUsbDevices(): List<HashMap<String, Any?>> {
        val out = ArrayList<HashMap<String, Any?>>()
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager ?: return out
        for (device in usbManager.deviceList.values) {
            val m = HashMap<String, Any?>()
            m["vendorId"] = device.vendorId
            m["productId"] = device.productId
            m["productName"] = device.productName
            m["manufacturer"] = device.manufacturerName
            m["deviceName"] = device.deviceName
            out.add(m)
        }
        return out
    }

    /// Sends [bytes] to the USB device matching [vendorId]/[productId]. Requests
    /// runtime permission first when needed (the result is delivered after the
    /// user responds to the system dialog).
    private fun printBytes(
        vendorId: Int,
        productId: Int,
        bytes: ByteArray,
        result: MethodChannel.Result,
    ) {
        val usbManager = getSystemService(Context.USB_SERVICE) as? UsbManager
        if (usbManager == null) {
            result.error("no_usb", "USB service unavailable", null)
            return
        }
        val device = usbManager.deviceList.values.firstOrNull {
            it.vendorId == vendorId && it.productId == productId
        }
        if (device == null) {
            result.error("no_device", "USB device not found", null)
            return
        }
        if (usbManager.hasPermission(device)) {
            writeAsync(usbManager, device, bytes, result)
            return
        }

        // Request permission. FLAG_IMMUTABLE is mandatory on Android 12+ (S).
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_IMMUTABLE
            else 0
        val intent = Intent(actionUsbPermission).setPackage(packageName)
        val permissionIntent = PendingIntent.getBroadcast(this, 0, intent, flags)

        // `done` makes sure `result` is delivered EXACTLY once across the two
        // racing paths: the permission broadcast and the watchdog timeout. The
        // watchdog converts a never-delivered broadcast (some OEM ROMs send none
        // when the dialog is dismissed) into a normal, retryable failure instead
        // of a forever-hung Dart await.
        val handler = Handler(Looper.getMainLooper())
        val done = AtomicBoolean(false)
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, received: Intent?) {
                if (received?.action != actionUsbPermission) return
                if (!done.compareAndSet(false, true)) return
                handler.removeCallbacksAndMessages(null)
                try {
                    unregisterReceiver(this)
                } catch (_: Exception) { /* already gone */ }
                val granted =
                    received.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                if (granted) {
                    writeAsync(usbManager, device, bytes, result)
                } else {
                    result.error("permission_denied", "USB permission denied", null)
                }
            }
        }
        val filter = IntentFilter(actionUsbPermission)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(receiver, filter)
        }
        usbManager.requestPermission(device, permissionIntent)
        handler.postDelayed({
            if (!done.compareAndSet(false, true)) return@postDelayed
            try {
                unregisterReceiver(receiver)
            } catch (_: Exception) { /* already gone */ }
            result.error("permission_timeout", "USB permission not granted in time", null)
        }, 60_000)
    }

    /// Runs the (blocking) bulk transfer off the main thread, then delivers the
    /// MethodChannel result back on the UI thread.
    private fun writeAsync(
        usbManager: UsbManager,
        device: UsbDevice,
        bytes: ByteArray,
        result: MethodChannel.Result,
    ) {
        Thread {
            val error = writeToDevice(usbManager, device, bytes)
            runOnUiThread {
                if (error == null) result.success(true)
                else result.error("usb_error", error, null)
            }
        }.start()
    }

    /// Claims the first bulk-OUT endpoint and writes [bytes] in chunks. Returns
    /// null on success or a short error code on failure.
    private fun writeToDevice(
        usbManager: UsbManager,
        device: UsbDevice,
        bytes: ByteArray,
    ): String? {
        var targetInterface: UsbInterface? = null
        var outEndpoint: UsbEndpoint? = null
        outer@ for (i in 0 until device.interfaceCount) {
            val intf = device.getInterface(i)
            for (e in 0 until intf.endpointCount) {
                val ep = intf.getEndpoint(e)
                if (ep.direction == UsbConstants.USB_DIR_OUT &&
                    ep.type == UsbConstants.USB_ENDPOINT_XFER_BULK
                ) {
                    targetInterface = intf
                    outEndpoint = ep
                    break@outer
                }
            }
        }
        if (targetInterface == null || outEndpoint == null) return "no_bulk_out_endpoint"

        val connection: UsbDeviceConnection =
            usbManager.openDevice(device) ?: return "open_failed"
        try {
            if (!connection.claimInterface(targetInterface, true)) return "claim_failed"
            var offset = 0
            val chunkSize = 16384
            while (offset < bytes.size) {
                val len = minOf(chunkSize, bytes.size - offset)
                // bulkTransfer returns the COUNT of bytes actually transferred,
                // which can be a SHORT write (< len) or 0 (a timeout that moved
                // nothing under backpressure). Advancing by `len` would silently
                // drop the un-sent tail and corrupt the position-sensitive ESC/POS
                // raster. Advance by `sent`, and tolerate a few 0-byte stalls.
                var sent = connection.bulkTransfer(outEndpoint, bytes, offset, len, 5000)
                var stalls = 0
                while (sent == 0 && stalls < 3) {
                    stalls++
                    sent = connection.bulkTransfer(outEndpoint, bytes, offset, len, 5000)
                }
                if (sent < 0) return "bulk_transfer_failed_at_$offset"
                if (sent == 0) return "bulk_transfer_stalled_at_$offset"
                offset += sent
            }
            return null
        } catch (e: Exception) {
            return e.message ?: "usb_exception"
        } finally {
            try {
                connection.releaseInterface(targetInterface)
            } catch (_: Exception) { /* best-effort */ }
            connection.close()
        }
    }

    // ------------------------------------------------------------- device ----

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
