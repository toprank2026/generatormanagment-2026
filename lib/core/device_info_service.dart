import 'dart:io';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:generatormanagment/core/logger.dart';
import 'package:generatormanagment/core/secure_store.dart';

/// Collects a device fingerprint sent to the backend on register/login/bind so
/// an account can be tied to its physical device(s) (anti-sharing / anti-abuse).
///
/// NOTE on IMEI / MAC: modern Android (10+) and iOS **do not expose** the real
/// IMEI or hardware MAC to normal apps — `READ_PHONE_STATE` no longer returns
/// IMEI for non-system apps, and the Wi-Fi MAC is randomized. We therefore send:
///   - a persistent app-generated `installId` (primary, always available),
///   - the OS-provided stable device id (Android SSAID / iOS identifierForVendor),
///   - model / brand / OS version,
/// and best-effort `imei` / `mac` (usually null / the Wi-Fi BSSID). The backend
/// keys binding off `installId` + `deviceId`.
class DeviceInfoService {
  static final DeviceInfoService _instance = DeviceInfoService._internal();
  factory DeviceInfoService() => _instance;
  DeviceInfoService._internal();

  static const MethodChannel _channel = MethodChannel('moldati/device');

  final DeviceInfoPlugin _plugin = DeviceInfoPlugin();
  final NetworkInfo _network = NetworkInfo();
  final SecureStore _store = SecureStore();

  Future<Map<String, dynamic>> collect() async {
    final installId = await _store.installId();

    String platform = 'unknown';
    String model = 'unknown';
    String brand = 'unknown';
    String osVersion = 'unknown';
    String deviceId = installId;
    String? imei;
    String? mac;

    try {
      if (Platform.isAndroid) {
        final a = await _plugin.androidInfo;
        platform = 'android';
        model = a.model;
        brand = a.manufacturer;
        osVersion = 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
        deviceId = a.id; // SSAID — best stable id apps can read
      } else if (Platform.isIOS) {
        final i = await _plugin.iosInfo;
        platform = 'ios';
        model = i.utsname.machine;
        brand = 'Apple';
        osVersion = 'iOS ${i.systemVersion}';
        deviceId = i.identifierForVendor ?? installId;
      }
    } catch (e) {
      Log.w('device info collect failed: $e');
    }

    // Best-effort native hardware ids (Android). Returns null on Android 10+
    // where IMEI is blocked and the MAC is randomized — handled gracefully.
    if (Platform.isAndroid) {
      try {
        final ids = await _channel.invokeMapMethod<String, dynamic>('getHardwareIds');
        final rawImei = ids?['imei'] as String?;
        final rawMac = ids?['mac'] as String?;
        if (rawImei != null && rawImei.isNotEmpty) imei = rawImei;
        if (rawMac != null && rawMac.isNotEmpty && rawMac != '02:00:00:00:00:00') {
          mac = rawMac;
        }
      } catch (e) {
        Log.w('native hardware ids unavailable: $e');
      }
    }

    // Fallback: connected access point BSSID (may be null without location perms).
    if (mac == null) {
      try {
        mac = await _network.getWifiBSSID();
      } catch (_) {}
    }

    return {
      'installId': installId,
      'deviceId': deviceId,
      'platform': platform,
      'model': model,
      'brand': brand,
      'osVersion': osVersion,
      if (imei != null) 'imei': imei,
      if (mac != null && mac.isNotEmpty) 'mac': mac,
    };
  }
}
