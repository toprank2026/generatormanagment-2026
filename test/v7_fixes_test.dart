import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';

/// v7 fix-batch repository behavior:
///   * R1 — duplicate board/circuit (feed) name detection (per branch / board);
///   * R5 — category filter threaded through getAll + getByPaymentStatus;
///   * R2 — adding a non-zero price for a month makes every subscriber unpaid.
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

  const month = '2026-07';
  const main = DbHelper.kMainBranchId;
  final boards = BoardRepository();
  final circuits = CircuitRepository();
  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();

  Subscriber sub(String id, String name, String circuit, String category,
          {double amps = 10}) =>
      Subscriber(
        id: id,
        name: name,
        amps: amps,
        boardId: 'b1',
        circuitId: circuit,
        category: category,
        branchId: main,
      );

  group('R1 duplicate board name', () {
    test('nameExists is per-branch, case/space-insensitive, self-excluding',
        () async {
      await boards.insert(Board(id: 'b1', name: 'North', branchId: main));

      expect(await boards.nameExists('north', branchId: main), true);
      expect(await boards.nameExists('  North ', branchId: main), true);
      expect(await boards.nameExists('South', branchId: main), false);
      // Editing the same board doesn't collide with itself.
      expect(await boards.nameExists('North', branchId: main, exceptId: 'b1'),
          false);
      // Another branch may reuse the name (full isolation).
      expect(await boards.nameExists('North', branchId: 'other'), false);
    });
  });

  group('R1 duplicate circuit (feed) name', () {
    test('nameExists is per-board within the branch', () async {
      await boards.insert(Board(id: 'b1', name: 'B1', branchId: main));
      await boards.insert(Board(id: 'b2', name: 'B2', branchId: main));
      await circuits
          .insert(Circuit(id: 'c1', boardId: 'b1', name: 'Feed-1', branchId: main));

      expect(await circuits.nameExists('feed-1', 'b1', branchId: main), true);
      // Same feed name under a DIFFERENT board is allowed.
      expect(await circuits.nameExists('Feed-1', 'b2', branchId: main), false);
      // Self-exclusion on edit.
      expect(
          await circuits.nameExists('Feed-1', 'b1',
              branchId: main, exceptId: 'c1'),
          false);
    });
  });

  group('R5 category filter', () {
    test('getAll and getByPaymentStatus filter by category', () async {
      await prices.insert(MonthlyPrice(
          month: month,
          pricePerAmp: 1000,
          branchId: main,
          category: SubscriberCategory.gold));
      await prices.insert(MonthlyPrice(
          month: month,
          pricePerAmp: 1000,
          branchId: main,
          category: SubscriberCategory.standard));
      await subs.insert(sub('g', 'Gold guy', 'c1', SubscriberCategory.gold));
      await subs.insert(sub('s', 'Std guy', 'c2', SubscriberCategory.standard));

      final goldOnly =
          await subs.getAll(branchId: main, category: SubscriberCategory.gold);
      expect(goldOnly.map((s) => s.id), ['g']);

      // No receipts yet → both unpaid; filtering unpaid by category isolates it.
      final unpaidGold = await subs.getByPaymentStatus(
          month: month,
          isPaid: false,
          branchId: main,
          category: SubscriberCategory.gold);
      expect(unpaidGold.map((s) => s.id), ['g']);
      expect(unpaidGold.map((s) => s.id), isNot(contains('s')));
    });
  });

  group('R2 unpaid-by-default for a newly priced month', () {
    test('a non-zero price with no receipts makes everyone unpaid', () async {
      await subs.insert(sub('a', 'A', 'c1', SubscriberCategory.standard));
      await subs.insert(sub('b', 'B', 'c2', SubscriberCategory.standard));

      // Before any price: due 0 → everyone counts as paid.
      expect(
          (await subs.getByPaymentStatus(
                  month: month, isPaid: false, branchId: main))
              .length,
          0);

      // Add a non-zero standard price → due > 0, no receipts → all unpaid.
      await prices.insert(MonthlyPrice(
          month: month,
          pricePerAmp: 1500,
          branchId: main,
          category: SubscriberCategory.standard));

      final unpaid = await subs.getByPaymentStatus(
          month: month, isPaid: false, branchId: main);
      expect(unpaid.map((s) => s.id).toSet(), {'a', 'b'});
      // And the price is scoped to THIS month only (a different month stays $0).
      expect(
          (await subs.getByPaymentStatus(
                  month: '2026-08', isPaid: false, branchId: main))
              .length,
          0);
    });
  });
}
