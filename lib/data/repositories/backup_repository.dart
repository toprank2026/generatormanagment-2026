import 'dart:io';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/account.dart';

/// Cloud backup of the local SQLite database (`moldati.db`) via the backend.
/// The business data itself never lives on the server — only opaque DB snapshots
/// the owner can restore onto a device.
class BackupRepository {
  final ApiClient _api = ApiClient();
  final DbHelper _db = DbHelper();

  /// Uploads the current device DB file as a new cloud backup.
  Future<BackupEntry> upload({String? note, String? appVersion}) async {
    final path = await _db.getDbPath();
    final file = File(path);
    if (!file.existsSync()) {
      throw ApiException(0, 'Local database file not found');
    }
    final res = await _api.uploadFile(
      ApiConfig.backup,
      filePath: path,
      field: 'file',
      fields: {
        if (note != null) 'note': note,
        if (appVersion != null) 'appVersion': appVersion,
      },
    );
    final j = (res is Map ? (res['backup'] ?? res) : res) as Map<String, dynamic>;
    return BackupEntry.fromJson(j);
  }

  Future<List<BackupEntry>> list() async {
    final res = await _api.get(ApiConfig.backup);
    final list = (res is Map ? res['backups'] : res) as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(BackupEntry.fromJson)
        .toList();
  }

  Future<void> delete(String id) async {
    await _api.delete(ApiConfig.backupById(id));
  }

  /// Downloads a cloud backup and OVERWRITES the local DB. The DB connection is
  /// closed first so the file lock is released; the app must restart/logout
  /// afterwards for the new data to be picked up cleanly.
  Future<void> restore(String id) async {
    final bytes = await _api.downloadBytes(ApiConfig.backupDownload(id));
    final path = await _db.getDbPath();
    await _db.close();
    await File(path).writeAsBytes(bytes, flush: true);
    // Clear the restored snapshot's PENDING outbox so its stale rows aren't
    // re-pushed (and resurrect old data) on the next login's push-before-pull
    // (audit fix). Reopening also migrates the restored file to the current
    // schema; close again so the post-logout reopen is clean.
    final db = await _db.database;
    await db.delete('sync_outbox');
    await _db.close();
  }
}
