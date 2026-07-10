import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';

/// v32 item 1/3 — amps by payment status × subscriber type. The paid and
/// unpaid amp sums use the SAME category-aware coverage rule as the
/// paid/unpaid counts, so together they must partition ampsByCategory exactly
/// (the Home overview's total stays accurate with no record excluded).
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

  Subscriber sub(String id, double amps, String category) => Subscriber(
        id: id,
        name: id,
        amps: amps,
        boardId: 'b',
        circuitId: 'c-$id',
        category: category,
        branchId: main,
      );

  Receipt pay(String uuid, String subId, double amount, double amps,
          double price) =>
      Receipt(
        uuid: uuid,
        receiptNo: 1,
        subscriberId: subId,
        month: month,
        ampsSnapshot: amps,
        priceSnapshot: price,
        paidAmount: amount,
        remainingAfter: 0,
        branchId: main,
        issuedAt: '2026-09-05T10:00:00.000Z',
      );

  test('paid/unpaid amp sums per category partition ampsByCategory exactly',
      () async {
    // Prices: standard 1000, gold 2000 — commercial UNPRICED (⇒ unpaid).
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 1000,
        branchId: main,
        category: SubscriberCategory.standard));
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 2000,
        branchId: main,
        category: SubscriberCategory.gold));

    await subs.insert(sub('A', 10, SubscriberCategory.standard)); // paid
    await subs.insert(sub('B', 5, SubscriberCategory.standard)); // unpaid
    await subs.insert(sub('C', 8, SubscriberCategory.gold)); // paid
    await subs.insert(sub('D', 6, SubscriberCategory.commercial)); // no price

    await receipts.insert(pay('r1', 'A', 10000, 10, 1000)); // full
    await receipts.insert(pay('r2', 'C', 16000, 8, 2000)); // full

    final paid = await subs.ampsByPaymentStatusCategory(
        month: month, isPaid: true, branchId: main);
    final unpaid = await subs.ampsByPaymentStatusCategory(
        month: month, isPaid: false, branchId: main);

    expect(paid[SubscriberCategory.standard], 10);
    expect(paid[SubscriberCategory.gold], 8);
    expect(paid[SubscriberCategory.commercial], isNull);
    expect(unpaid[SubscriberCategory.standard], 5);
    expect(unpaid[SubscriberCategory.commercial], 6); // unpriced ⇒ unpaid
    expect(unpaid[SubscriberCategory.gold], isNull);

    // Partition invariant: Σ paid amps + Σ unpaid amps == Σ all amps, and the
    // groups agree with the paid/unpaid COUNTS derived by the same rule.
    final all = await subs.ampsByCategory(branchId: main);
    final double allTotal = all.values.fold(0.0, (s, a) => s + a);
    final double paidTotal = paid.values.fold(0.0, (s, a) => s + a);
    final double unpaidTotal = unpaid.values.fold(0.0, (s, a) => s + a);
    expect(paidTotal + unpaidTotal, allTotal); // 18 + 11 == 29
    expect(
        await subs.countByPaymentStatus(
            month: month, isPaid: true, branchId: main),
        2);
    expect(
        await subs.countByPaymentStatus(
            month: month, isPaid: false, branchId: main),
        2);
  });

  // v33 (audit fix): the remaining card must equal the SUM of the unpaid
  // list's per-subscriber dues — an OVERPAYMENT (coverage > current due, e.g.
  // amps/price reduced after paying) must NOT be netted against other
  // subscribers' dues. Also verifies total paid = Σ cash actually received.
  test('remainingFeesTotal = Σ unpaid dues (overpayment not netted); '
      'collected = Σ cash received', () async {
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 1000,
        branchId: main,
        category: SubscriberCategory.standard));

    await subs.insert(sub('A', 10, SubscriberCategory.standard)); // paid exact
    await subs.insert(sub('B', 5, SubscriberCategory.standard)); // unpaid
    await subs.insert(sub('C', 10, SubscriberCategory.standard)); // OVERPAID
    await subs.insert(sub('D', 10, SubscriberCategory.standard)); // partial

    await receipts.insert(pay('p1', 'A', 10000, 10, 1000)); // due 10,000 exact
    await receipts.insert(pay('p2', 'C', 15000, 10, 1000)); // due 10,000 → +5k
    await receipts.insert(pay('p3', 'D', 4000, 10, 1000)); // due 10,000 → −6k

    // Total paid (الوارد الكلي) = every dinar actually received, incl. the
    // overpayment cash: 10,000 + 15,000 + 4,000.
    expect(await receipts.getCollectedSum(month, branchId: main), 29000);

    // Remaining = B's full due (5,000) + D's remainder (6,000) = 11,000 —
    // exactly what the unpaid list sums to. The OLD aggregate
    // (expected 35,000 − collected 29,000 − discounts 0 = 6,000) wrongly
    // netted C's 5,000 overpayment against B/D's dues.
    expect(
        await subs.remainingFeesTotal(month: month, branchId: main), 11000);

    // Consistency: B and D are the unpaid set the card claims to sum.
    expect(
        await subs.countByPaymentStatus(
            month: month, isPaid: false, branchId: main),
        2);
  });
}
