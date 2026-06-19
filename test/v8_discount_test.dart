import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';

/// v8 P5 — receipt discount on FULL payment:
///  - coverage = paid_amount + discount_value, so a discounted full payment
///    counts as fully PAID (getByPaymentStatus), while an equal cash-only
///    partial payment stays UNPAID;
///  - the waived discount is NOT counted as collected cash;
///  - the v7 schema carries the discount columns (round-trip).
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

  const month = '2026-09';
  const main = DbHelper.kMainBranchId;
  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();

  Subscriber sub(String id, {double amps = 10}) => Subscriber(
        id: id,
        name: id,
        amps: amps,
        boardId: 'b',
        circuitId: 'c-$id',
        category: SubscriberCategory.standard,
        branchId: main,
      );

  Receipt rec(String uuid, String subId,
          {required double paid, double discount = 0, String type = 'none'}) =>
      Receipt(
        uuid: uuid,
        receiptNo: 1,
        subscriberId: subId,
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 1000,
        paidAmount: paid,
        remainingAfter: 0,
        branchId: main,
        discountType: type,
        discountValue: discount,
        issuedAt: '$month-05T00:00:00.000Z',
      );

  test('discounted FULL payment counts PAID; cash-only partial stays UNPAID',
      () async {
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 1000,
        branchId: main,
        category: SubscriberCategory.standard));
    // A: amps 10 → due 10000. Pays 6000 cash + 4000 discount = covered 10000.
    await subs.insert(sub('A'));
    await receipts.insert(rec('rA', 'A', paid: 6000, discount: 4000, type: 'value'));
    // B: amps 10 → due 10000. Pays 6000 cash, no discount → still owes 4000.
    await subs.insert(sub('B'));
    await receipts.insert(rec('rB', 'B', paid: 6000));

    final paid =
        await subs.getByPaymentStatus(month: month, isPaid: true, branchId: main);
    final unpaid = await subs.getByPaymentStatus(
        month: month, isPaid: false, branchId: main);
    expect(paid.map((s) => s.id), contains('A'));
    expect(unpaid.map((s) => s.id), contains('B'));
    expect(paid.map((s) => s.id), isNot(contains('B')));
  });

  test('discount is NOT collected cash (getCollectedSum = paid_amount only)',
      () async {
    await subs.insert(sub('A'));
    await receipts.insert(rec('rA', 'A', paid: 6000, discount: 4000, type: 'value'));
    final collected = await receipts.getCollectedSum(month, branchId: main);
    expect(collected, 6000); // the 4000 was waived, never received
  });

  test('getDiscountSum returns waived discount only (lockstep: remaining)',
      () async {
    await subs.insert(sub('A'));
    await receipts
        .insert(rec('rA', 'A', paid: 6000, discount: 4000, type: 'value'));
    await subs.insert(sub('B'));
    await receipts.insert(rec('rB', 'B', paid: 6000)); // no discount
    final discount = await receipts.getDiscountSum(month, branchId: main);
    expect(discount, 4000);
    // The aggregate "remaining" must be expected − collected − discount so it
    // stays in lockstep with paid/unpaid coverage and the backend dashboard.
    // expected = (10+10)*1000 = 20000; collected = 12000; discount = 4000.
    final collected = await receipts.getCollectedSum(month, branchId: main);
    expect(20000 - collected - discount, 4000); // == B's true remaining
  });

  test('v7 schema carries discount columns (round-trip)', () async {
    await subs.insert(sub('A'));
    await receipts
        .insert(rec('rA', 'A', paid: 7000, discount: 3000, type: 'ampere'));
    final list =
        await receipts.getBySubscriberAndMonth('A', month, branchId: main);
    expect(list.length, 1);
    expect(list.first.discountType, 'ampere');
    expect(list.first.discountValue, 3000);
    expect(list.first.hasDiscount, true);
  });
}
