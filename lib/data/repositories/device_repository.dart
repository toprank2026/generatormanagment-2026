import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/core/device_info_service.dart';
import 'package:generatormanagment/data/models/account.dart';

/// Device-binding operations against the backend (manage which devices may use
/// the account). Used by the settings "devices" view.
class DeviceRepository {
  final ApiClient _api = ApiClient();
  final DeviceInfoService _device = DeviceInfoService();

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
}
