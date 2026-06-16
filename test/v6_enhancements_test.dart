import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';

/// v6 enhancements at the repository layer:
///   * R4 — per-category pricing drives each subscriber's due/paid status;
///   * R7 — circuit exclusivity helpers (branch-scoped, active-only);
///   * R8 — duplicate-name detection (per branch, case/space-insensitive).
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

  const month = '2026-06';
  const main = DbHelper.kMainBranchId;
  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();
  final boards = BoardRepository();
  final circuits = CircuitRepository();

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

  Receipt rec(String uuid, String subId, double paid) => Receipt(
        uuid: uuid,
        receiptNo: 1,
        subscriberId: subId,
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 0,
        paidAmount: paid,
        remainingAfter: 0,
        branchId: main,
        issuedAt: '$month-10T00:00:00.000Z',
      );

  group('R4 per-category pricing', () {
    test('each category prices independently and drives due/paid', () async {
      await prices.insert(MonthlyPrice(
          month: month,
          pricePerAmp: 2000,
          branchId: main,
          category: SubscriberCategory.commercial));
      await prices.insert(MonthlyPrice(
          month: month,
          pricePerAmp: 1000,
          branchId: main,
          category: SubscriberCategory.standard));

      // commercial: amps10 -> due 20000; standard: amps10 -> due 10000.
      await subs.insert(sub('a', 'A', 'c-a', SubscriberCategory.commercial));
      await subs.insert(sub('b', 'B', 'c-b', SubscriberCategory.standard));
      await receipts.insert(rec('ra', 'a', 20000)); // fully paid (commercial)
      await receipts.insert(rec('rb', 'b', 5000)); // underpaid (standard)

      expect(
          (await prices.getByMonth(month,
                  branchId: main, category: SubscriberCategory.commercial))!
              .pricePerAmp,
          2000);
      expect(
          (await prices.getByMonth(month,
                  branchId: main, category: SubscriberCategory.standard))!
              .pricePerAmp,
          1000);

      final all = await prices.pricesForMonth(month, branchId: main);
      expect(all[SubscriberCategory.commercial], 2000);
      expect(all[SubscriberCategory.standard], 1000);

      // Category-aware paid/unpaid: A paid (20000>=20000), B unpaid (5000<10000).
      final paid =
          await subs.getByPaymentStatus(month: month, isPaid: true, branchId: main);
      final unpaid = await subs.getByPaymentStatus(
          month: month, isPaid: false, branchId: main);
      expect(paid.map((s) => s.id), contains('a'));
      expect(unpaid.map((s) => s.id), contains('b'));
      expect(paid.map((s) => s.id), isNot(contains('b')));
    });
  });

  group('R7 circuit exclusivity helpers', () {
    test('isCircuitTaken is branch-scoped, active-only, and self-excluding',
        () async {
      await subs.insert(sub('x', 'X', 'c1', SubscriberCategory.standard));

      expect(await subs.isCircuitTaken('c1', branchId: main), true);
      expect(await subs.isCircuitTaken('c2', branchId: main), false);
      // The holder itself does not count (lets you edit the same subscriber).
      expect(await subs.isCircuitTaken('c1', branchId: main, exceptId: 'x'),
          false);
      // Different branch: the circuit is free there.
      expect(await subs.isCircuitTaken('c1', branchId: 'other'), false);

      // An inactive holder frees the circuit.
      await subs.insert(Subscriber(
          id: 'y',
          name: 'Y',
          amps: 5,
          boardId: 'b1',
          circuitId: 'c3',
          status: 'inactive',
          branchId: main));
      expect(await subs.isCircuitTaken('c3', branchId: main), false);

      expect(await subs.takenCircuitIds(branchId: main), {'c1'});
    });
  });

  group('R8 duplicate names', () {
    test('nameExists is per-branch, case- and space-insensitive', () async {
      await subs.insert(sub('a', 'Ahmed', 'c1', SubscriberCategory.standard));

      expect(await subs.nameExists('ahmed', branchId: main), true); // case
      expect(await subs.nameExists('  Ahmed  ', branchId: main), true); // trim
      expect(await subs.nameExists('Sara', branchId: main), false);
      // The same row does not collide with itself (edit).
      expect(await subs.nameExists('Ahmed', branchId: main, exceptId: 'a'),
          false);
      // Another branch may reuse the name.
      expect(await subs.nameExists('Ahmed', branchId: 'other'), false);
    });
  });

  // Touch boards/circuits repos so the imports are exercised + schema builds.
  test('schema builds at v6 (smoke)', () async {
    await boards.insert(Board(id: 'b1', name: 'B', branchId: main));
    await circuits.insert(
        Circuit(id: 'c1', boardId: 'b1', name: 'C', branchId: main));
    expect((await boards.getAll()).length, 1);
  });
}
