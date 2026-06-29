import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/core/device_info_service.dart';
import 'package:generatormanagment/core/secure_store.dart';
import 'package:generatormanagment/data/models/account.dart';

/// Device-binding operations against the backend (manage which devices may use
/// the account). Used by the settings "devices" view.
class DeviceRepository {
  final ApiClient _api = ApiClient();
  final DeviceInfoService _device = DeviceInfoService();
  final SecureStore _store = SecureStore();

  Future<List<DeviceBinding>> list() async {
    final res = await _api.get(ApiConfig.devices);
    final list = (res is Map ? res['devices'] : res) as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(DeviceBinding.fromJson)
        .toList();
  }

  Future<DeviceBinding> bindCurrent() async {
    final device = await _device.collect();
    final res = await _api.post(ApiConfig.deviceBind, body: {'device': device});
    final j = (res is Map ? (res['device'] ?? res) : res) as Map<String, dynamic>;
    return DeviceBinding.fromJson(j);
  }

  Future<void> unbind(String deviceId) async {
    await _api.delete(ApiConfig.deviceById(deviceId));
  }

  /// v18 item 1: remove THIS device's binding, clear the local install-id, then
  /// (when [rebind]) re-run the fresh-registration binding flow (collect + bind).
  /// Each step is best-effort so a transient failure never blocks the caller
  /// (logout passes rebind:false — the next login rebinds). Requires the caller
  /// to be authenticated + online; the OS-stable deviceId is what binding keys
  /// off, so clearing the install-id only refreshes the fallback id.
  Future<void> rebindCurrent({bool rebind = true}) async {
    final fp = await _device.collect();
    final id = (fp['deviceId'] ?? '').toString();
    if (id.isNotEmpty) {
      try {
        await unbind(id);
      } catch (_) {/* already gone / offline → best effort */}
    }
    await _store.clearInstallId();
    if (rebind) {
      try {
        await bindCurrent();
      } catch (_) {/* next login will rebind */}
    }
  }
}
