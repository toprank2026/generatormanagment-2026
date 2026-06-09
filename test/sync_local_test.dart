import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';

import 'package:generatormanagment/core/sync_service.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';

/// Verifies the local-only side of the sync engine: SyncService.deleteLocalData
/// wipes the 7 mirrored business tables AND clears the change-capture outbox
/// (so the wipe is never pushed). No network is touched — pull()/push() are not
/// called here.
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

  Future<int> countRows(String table) async {
    final db = await DbHelper().database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $table'),
        ) ??
        -1;
  }

  test('deleteLocalData wipes all business tables and the outbox', () async {
    final boardRepo = BoardRepository();
    final circuitRepo = CircuitRepository();
    final subRepo = SubscriberRepository();

    // Inserting through the repos fires the AFTER INSERT triggers, which fill
    // sync_outbox.
    await boardRepo.insert(Board(id: 'b1', name: 'Board 1'));
    await circuitRepo.insert(
      Circuit(id: 'c1', boardId: 'b1', name: 'Circuit 1'),
    );
    await subRepo.insert(
      Subscriber(
        id: 's1',
        name: 'Sub 1',
        amps: 10,
        boardId: 'b1',
        circuitId: 'c1',
      ),
    );

    // Sanity: the rows landed and the triggers captured them.
    expect(await countRows('boards'), 1);
    expect(await countRows('circuits'), 1);
    expect(await countRows('subscribers'), 1);
    expect(
      await countRows('sync_outbox'),
      greaterThan(0),
      reason: 'triggers must have queued the inserts in sync_outbox',
    );

    // Wipe local data (no network).
    await SyncService().deleteLocalData();

    // All 7 mirrored business tables are empty.
    for (final table in DbHelper.syncedTables.keys) {
      expect(
        await countRows(table),
        0,
        reason: '$table must be empty after deleteLocalData',
      );
    }

    // And the outbox is empty too, so the wipe is not pushed to the server.
    expect(
      await countRows('sync_outbox'),
      0,
      reason: 'sync_outbox must be cleared so the wipe is never synced',
    );
  });
}
