import 'package:sqflite/sqflite.dart';
import 'package:generatormanagment/core/logger.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/repositories/sync_repository.dart';

/// Drains the local change-capture outbox (written by SQLite triggers) and
/// pushes the affected rows to the server mirror, then clears the drained
/// entries. The device DB is never modified by sync, so triggers don't recurse.
class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final DbHelper _db = DbHelper();
  final SyncRepository _repo = SyncRepository();

  static const int batchSize = 200;

  /// Number of distinct pending items (entity + row) awaiting upload.
  Future<int> pendingCount() async {
    final db = await _db.database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) c FROM (SELECT DISTINCT entity, local_id FROM sync_outbox)',
    );
    return Sqflite.firstIntValue(r) ?? 0;
  }

  /// Pushes all currently-pending changes. Returns the number of records sent.
  /// Captures the current max seq first so concurrent writes during the push
  /// are not lost (only drained rows up to that seq are deleted afterwards).
  Future<int> push() async {
    final db = await _db.database;

    final maxSeqRow = await db.rawQuery('SELECT MAX(seq) m FROM sync_outbox');
    final int maxSeq = Sqflite.firstIntValue(maxSeqRow) ?? 0;
    if (maxSeq == 0) return 0;

    // Latest op per (entity, local_id) within the captured window.
    final pending = await db.rawQuery(
      '''
      SELECT entity, local_id,
             (SELECT op FROM sync_outbox o2
               WHERE o2.entity = o1.entity AND o2.local_id = o1.local_id
                 AND o2.seq <= ?
               ORDER BY o2.seq DESC LIMIT 1) AS op
      FROM sync_outbox o1
      WHERE o1.seq <= ?
      GROUP BY entity, local_id
      ''',
      [maxSeq, maxSeq],
    );

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final List<Map<String, dynamic>> records = [];
    for (final row in pending) {
      final entity = row['entity'] as String;
      final localId = '${row['local_id']}';
      final op = row['op'] as String?;
      final pk = DbHelper.syncedTables[entity];
      if (pk == null) continue;

      Map<String, dynamic>? data;
      if (op != 'delete') {
        final found = await db.query(entity, where: '$pk = ?', whereArgs: [localId], limit: 1);
        if (found.isNotEmpty) data = found.first;
      }
      records.add({
        'entity': entity,
        'localId': localId,
        'deleted': data == null,
        'updatedAt': nowIso,
        if (data != null) 'data': data,
      });
    }

    if (records.isEmpty) {
      await db.delete('sync_outbox', where: 'seq <= ?', whereArgs: [maxSeq]);
      return 0;
    }

    // Push in batches; only clear the outbox after all batches succeed.
    for (var i = 0; i < records.length; i += batchSize) {
      final end = (i + batchSize < records.length) ? i + batchSize : records.length;
      await _repo.push(records.sublist(i, end));
    }
    await db.delete('sync_outbox', where: 'seq <= ?', whereArgs: [maxSeq]);
    Log.d('SyncService: pushed ${records.length} records');
    return records.length;
  }
}
