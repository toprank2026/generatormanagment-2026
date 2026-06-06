import 'package:intl/intl.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/core/logger.dart';

/// DEBUG-ONLY local data seeder for scale/perf testing. Gated by the
/// compile-time flag `--dart-define=DEV_SEED=true` (default off, so it has zero
/// effect on production builds). Seeds one board + circuit, [count] subscribers,
/// a monthly price, and receipts (about half the subscribers paid this month,
/// plus a deep 25-receipt history on the first subscriber for history paging).
class DevSeed {
  static Future<void> run({int count = 1000}) async {
    final db = await DbHelper().database;
    final existing =
        Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM subscribers')) ?? 0;
    if (existing >= count) {
      Log.d('DevSeed: already $existing subscribers (>= $count), skipping');
      return;
    }

    final boardId = const Uuid().v4();
    final circuitId = const Uuid().v4();
    final now = DateTime.now();
    final month = DateFormat('yyyy-MM').format(now);
    const pricePerAmp = 1000.0;
    final uuid = const Uuid();

    await db.transaction((txn) async {
      await txn.insert('boards', {'id': boardId, 'name': 'SEED 1000', 'code': 'SEED'});
      await txn.insert(
        'circuits',
        {'id': circuitId, 'board_id': boardId, 'name': 'SEED-C1', 'phase': 'A'},
      );
      await txn.insert(
        'monthly_prices',
        {'month': month, 'price_per_amp': pricePerAmp, 'locked': 0},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      int receiptNo =
          Sqflite.firstIntValue(await txn.rawQuery('SELECT MAX(receipt_no) FROM receipts')) ?? 0;
      final batch = txn.batch();

      for (int i = 0; i < count; i++) {
        final subId = uuid.v4();
        final amps = (5 + (i % 30)).toDouble();
        batch.insert('subscribers', {
          'id': subId,
          'name': 'Seed Sub ${i + 1}',
          'phone': '0770${1000000 + i}',
          'amps': amps,
          'board_id': boardId,
          'circuit_id': circuitId,
          'status': 'active',
        });

        // ~half the subscribers fully paid this month -> tests paid/unpaid filter.
        if (i % 2 == 0) {
          receiptNo++;
          batch.insert('receipts', {
            'uuid': uuid.v4(),
            'receipt_no': receiptNo,
            'subscriber_id': subId,
            'month': month,
            'amps_snapshot': amps,
            'price_snapshot': pricePerAmp,
            'paid_amount': amps * pricePerAmp,
            'remaining_after': 0.0,
            'issued_at': now.toIso8601String(),
            'status': 'valid',
          });
        }

        // First subscriber gets a deep multi-month history for paging tests.
        if (i == 0) {
          for (int m = 1; m <= 25; m++) {
            receiptNo++;
            final d = DateTime(now.year, now.month - m, 5);
            batch.insert('receipts', {
              'uuid': uuid.v4(),
              'receipt_no': receiptNo,
              'subscriber_id': subId,
              'month': DateFormat('yyyy-MM').format(d),
              'amps_snapshot': amps,
              'price_snapshot': pricePerAmp,
              'paid_amount': amps * pricePerAmp,
              'remaining_after': 0.0,
              'issued_at': d.toIso8601String(),
              'status': 'valid',
            });
          }
        }
      }

      await batch.commit(noResult: true);
    });
    Log.d('DevSeed: seeded $count subscribers + receipts under board $boardId');
  }
}
