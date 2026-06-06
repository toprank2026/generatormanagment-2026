import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';

import 'package:generatormanagment/core/sync_service.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';

/// Verifies the SQLite change-capture layer that backs offline-first sync:
/// the AFTER INSERT/UPDATE/DELETE triggers (db_helper.dart `_createSyncInfra`)
/// must record every local mutation into `sync_outbox`, and
/// `SyncService.pendingCount()` must report the number of DISTINCT pending
/// items (entity + row). No network is exercised here — push() is not called.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await DbHelper.resetForTest();
    DbHelper.testPath = inMemoryDatabasePath;
  });

  tearDown(() async {
    await DbHelper.resetForTest();
  });

  // ---- helpers ---------------------------------------------------------

  Board makeBoard({required String id, String? name}) =>
      Board(id: id, name: name ?? 'Board $id');

  /// All outbox rows for a given (entity, localId), oldest first.
  Future<List<Map<String, Object?>>> outboxFor(
    String entity,
    String localId,
  ) async {
    final db = await DbHelper().database;
    return db.query(
      'sync_outbox',
      where: 'entity = ? AND local_id = ?',
      whereArgs: [entity, localId],
      orderBy: 'seq ASC',
    );
  }

  Future<int> outboxTotal() async {
    final db = await DbHelper().database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM sync_outbox'),
        ) ??
        -1;
  }

  // ---- TRIGGERS POPULATE THE OUTBOX -----------------------------------

  group('sync_outbox triggers', () {
    test('inserting a board records an upsert row for entity boards', () async {
      final boardRepo = BoardRepository();
      await boardRepo.insert(makeBoard(id: 'b1'));

      final rows = await outboxFor('boards', 'b1');
      expect(rows.length, 1);
      expect(rows.first['entity'], 'boards');
      expect(rows.first['op'], 'upsert');
      expect(rows.first['local_id'], 'b1');
    });

    test('updating the board records another upsert row', () async {
      final boardRepo = BoardRepository();
      await boardRepo.insert(makeBoard(id: 'b1', name: 'Original'));
      await boardRepo.update(makeBoard(id: 'b1', name: 'Renamed'));

      final rows = await outboxFor('boards', 'b1');
      // One from INSERT + one from UPDATE.
      expect(rows.length, 2);
      expect(rows.every((r) => r['op'] == 'upsert'), isTrue);
      expect(rows.every((r) => r['entity'] == 'boards'), isTrue);
    });

    test('deleting the board records a delete row', () async {
      final boardRepo = BoardRepository();
      await boardRepo.insert(makeBoard(id: 'b1'));
      await boardRepo.delete('b1');

      final rows = await outboxFor('boards', 'b1');
      // insert -> upsert, delete -> delete.
      expect(rows.length, 2);
      expect(rows.first['op'], 'upsert');
      expect(rows.last['op'], 'delete');
      expect(rows.last['local_id'], 'b1');
    });

    test('full insert/update/delete lifecycle yields 3 outbox rows', () async {
      final boardRepo = BoardRepository();
      await boardRepo.insert(makeBoard(id: 'b1', name: 'A'));
      await boardRepo.update(makeBoard(id: 'b1', name: 'B'));
      await boardRepo.delete('b1');

      final rows = await outboxFor('boards', 'b1');
      expect(rows.map((r) => r['op']).toList(), ['upsert', 'upsert', 'delete']);
      expect(await outboxTotal(), 3);
    });
  });

  // ---- pendingCount() COUNTS DISTINCT ITEMS ---------------------------

  group('SyncService.pendingCount', () {
    test('is 0 on a fresh database', () async {
      expect(await SyncService().pendingCount(), 0);
    });

    test('counts distinct (entity, row) regardless of op count', () async {
      final boardRepo = BoardRepository();

      // Three mutations on the SAME board => three outbox rows ...
      await boardRepo.insert(makeBoard(id: 'b1', name: 'A'));
      await boardRepo.update(makeBoard(id: 'b1', name: 'B'));
      await boardRepo.update(makeBoard(id: 'b1', name: 'C'));

      expect(await outboxTotal(), 3);
      // ... but only ONE distinct pending item.
      expect(await SyncService().pendingCount(), 1);

      // A second distinct board bumps the pending count to 2.
      await boardRepo.insert(makeBoard(id: 'b2'));
      expect(await SyncService().pendingCount(), 2);
    });
  });
}
