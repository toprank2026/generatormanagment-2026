import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';

/// Talks to the backend per-account sync mirror. Push (device → server) keeps
/// the server copy current; pull (server → device) restores this account's data
/// onto a device (new device, or after clearing local data). The mirror is
/// strictly per-account — the backend scopes every record to the JWT's user.
class SyncRepository {
  final ApiClient _api = ApiClient();

  /// Pushes a batch of change records. Each record:
  /// { entity, localId, deleted, updatedAt, data? }.
  Future<void> push(List<Map<String, dynamic>> records) async {
    await _api.post(ApiConfig.syncPush, body: {'records': records});
  }

  /// Pulls this account's mirrored records (optionally only those updated after
  /// [since]). Returns the raw record maps: { entity, localId, deleted,
  /// updatedAt, data }.
  Future<List<Map<String, dynamic>>> pull(
      {String? since, String? receiptsMonth}) async {
    final q = <String, String>{};
    if (since != null && since.isNotEmpty) q['since'] = since;
    // v11 (item 3): restrict ONLY receipts to this billing month (other
    // entities pull fully). Older-month receipts come down when that month is
    // selected + pulled.
    if (receiptsMonth != null && receiptsMonth.isNotEmpty) {
      q['receiptsMonth'] = receiptsMonth;
    }
    final res = await _api.get(
      ApiConfig.syncPull,
      query: q.isEmpty ? null : q,
    );
    final list = (res is Map && res['records'] is List)
        ? res['records'] as List
        : const [];
    return list
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
  }
}
