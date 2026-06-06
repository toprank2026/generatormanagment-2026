import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';

/// Talks to the backend sync mirror. Push-only (device → server) — the device
/// stays the source of truth; the server mirror is what the admin panel reads.
class SyncRepository {
  final ApiClient _api = ApiClient();

  /// Pushes a batch of change records. Each record:
  /// { entity, localId, deleted, updatedAt, data? }.
  Future<void> push(List<Map<String, dynamic>> records) async {
    await _api.post(ApiConfig.syncPush, body: {'records': records});
  }
}
