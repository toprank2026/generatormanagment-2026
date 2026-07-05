import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v28 item 11 — salary "once per calendar month":
///  - salaryStatusForMonth returns 'pending'/'approved' for a salary settlement
///    in the given LOCAL month (blocks a new request + drives the button state);
///  - a 'rejected' salary does NOT block (owner declined → month stays open);
///  - only 'salary'-method rows count (cash/card ignored);
///  - the month is matched on the accountant's LOCAL time even though
///    requested_at is persisted UTC (month-boundary correctness).
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
    DbHelper.testPath = null;
  });

  final repo = SettlementRepository();

  Settlement settle(
    String id, {
    required String requestedAtUtcIso,
    String method = 'salary',
    String status = 'pending',
    String accountantId = 'acct-1',
  }) =>
      Settlement(
        id: id,
        accountantId: accountantId,
        amount: status == 'approved' ? 500000 : 0,
        method: method,
        status: status,
        requestedAt: requestedAtUtcIso,
      );

  // Local month for a given local DateTime, matching the controller's
  // DateFormat('yyyy-MM').format(DateTime.now()).
  String localMonth(DateTime local) =>
      '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}';

  test('pending salary this month → blocks (returns "pending")', () async {
    final now = DateTime.now();
    await repo.insert(settle('s1',
        requestedAtUtcIso: now.toUtc().toIso8601String(), status: 'pending'));
    final st = await repo.salaryStatusForMonth('acct-1', localMonth(now));
    expect(st, 'pending');
  });

  test('approved salary this month → button state "approved"', () async {
    final now = DateTime.now();
    await repo.insert(settle('s1',
        requestedAtUtcIso: now.toUtc().toIso8601String(), status: 'approved'));
    final st = await repo.salaryStatusForMonth('acct-1', localMonth(now));
    expect(st, 'approved');
  });

  test('rejected salary does NOT block (month stays open → null)', () async {
    final now = DateTime.now();
    await repo.insert(settle('s1',
        requestedAtUtcIso: now.toUtc().toIso8601String(), status: 'rejected'));
    final st = await repo.salaryStatusForMonth('acct-1', localMonth(now));
    expect(st, isNull);
  });

  test('cash/card settlements are ignored (only salary counts)', () async {
    final now = DateTime.now();
    await repo.insert(settle('s1',
        requestedAtUtcIso: now.toUtc().toIso8601String(),
        method: 'cash',
        status: 'approved'));
    final st = await repo.salaryStatusForMonth('acct-1', localMonth(now));
    expect(st, isNull);
  });

  test('a different accountant does not leak into the status', () async {
    final now = DateTime.now();
    await repo.insert(settle('s1',
        requestedAtUtcIso: now.toUtc().toIso8601String(),
        status: 'pending',
        accountantId: 'acct-OTHER'));
    final st = await repo.salaryStatusForMonth('acct-1', localMonth(now));
    expect(st, isNull);
  });

  test('month-boundary: a request stored under the previous UTC month is still '
      'matched by its LOCAL month', () async {
    // Pick a local instant early in a local month whose UTC instant is in the
    // PREVIOUS month for positive UTC offsets (e.g. UTC+3 Baghdad). We build a
    // local DateTime and store its UTC ISO — exactly what the app persists.
    final localEarly = DateTime(2026, 8, 1, 1, 30); // 01:30 local on the 1st
    final storedUtcIso = localEarly.toUtc().toIso8601String();
    await repo.insert(
        settle('s1', requestedAtUtcIso: storedUtcIso, status: 'pending'));

    // The accountant's local month for that instant is 2026-08.
    final st = await repo.salaryStatusForMonth('acct-1', localMonth(localEarly));
    expect(st, 'pending',
        reason: 'local-month match must not miss a row whose UTC prefix is the '
            'previous month');
  });

  test('newest matching row wins when several exist in the month', () async {
    final now = DateTime.now();
    final earlier = now.subtract(const Duration(hours: 2));
    // Older rejected + newer pending in the same month → newest (pending) wins.
    await repo.insert(settle('s-old',
        requestedAtUtcIso: earlier.toUtc().toIso8601String(),
        status: 'rejected'));
    await repo.insert(settle('s-new',
        requestedAtUtcIso: now.toUtc().toIso8601String(), status: 'pending'));
    final st = await repo.salaryStatusForMonth('acct-1', localMonth(now));
    expect(st, 'pending');
  });
}
