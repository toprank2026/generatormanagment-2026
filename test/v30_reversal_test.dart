import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v30 F2 — receipt reversal (soft void). Flipping a receipt's status
/// 'valid' → 'refunded' must restore the subscriber to UNPAID and drop every
/// derived aggregate (paid/unpaid counts + collected sum), since they all filter
/// status = 'valid'. This pins that behaviour at the repository layer.
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

  Subscriber sub(String id) => Subscriber(
        id: id,
        name: id,
        amps: 10,
        boardId: 'b',
        circuitId: 'c-$id',
        category: SubscriberCategory.standard,
        branchId: main,
      );

  test('reversing (markRefunded) a full-payment receipt restores UNPAID + '
      'drops collected, and persists status', () async {
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 1000,
        branchId: main,
        category: SubscriberCategory.standard));
    await subs.insert(sub('A'));
    // Full payment: 10 amps × 1000 = 10,000 → fully paid.
    await receipts.insert(Receipt(
      uuid: 'r1',
      receiptNo: 1,
      subscriberId: 'A',
      month: month,
      ampsSnapshot: 10,
      priceSnapshot: 1000,
      paidAmount: 10000,
      remainingAfter: 0,
      accountantId: 'acct-1',
      branchId: main,
      categorySnapshot: SubscriberCategory.standard,
      issuedAt: '2026-09-05T10:00:00.000Z',
    ));

    // Before: paid, collected = 10,000.
    expect(
        await subs.countByPaymentStatus(
            month: month, isPaid: true, branchId: main),
        1);
    expect(await receipts.getCollectedSum(month, branchId: main), 10000);

    // Reverse it.
    final fresh = await receipts.getByUuid('r1');
    expect(fresh, isNotNull);
    await receipts.markRefunded(fresh!);

    // After: back to UNPAID, collected 0.
    expect(
        await subs.countByPaymentStatus(
            month: month, isPaid: true, branchId: main),
        0);
    expect(
        await subs.countByPaymentStatus(
            month: month, isPaid: false, branchId: main),
        1);
    expect(await receipts.getCollectedSum(month, branchId: main), 0);

    // Status persisted as 'refunded'.
    final after = await receipts.getByUuid('r1');
    expect(after!.status, 'refunded');
  });

  test('a refunded receipt no longer covers due (getByUuid round-trips)',
      () async {
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 1000,
        branchId: main,
        category: SubscriberCategory.standard));
    await subs.insert(sub('B'));
    await receipts.insert(Receipt(
      uuid: 'r2',
      receiptNo: 2,
      subscriberId: 'B',
      month: month,
      ampsSnapshot: 10,
      priceSnapshot: 1000,
      paidAmount: 10000,
      remainingAfter: 0,
      accountantId: 'acct-1',
      branchId: main,
      categorySnapshot: SubscriberCategory.standard,
      issuedAt: '2026-09-06T10:00:00.000Z',
    ));
    // Valid receipts for the month cover the due → 1 valid row.
    final validBefore =
        await receipts.getBySubscriberAndMonth('B', month, branchId: main);
    expect(validBefore.length, 1);

    await receipts.markRefunded((await receipts.getByUuid('r2'))!);

    // The refunded row is excluded from the coverage query.
    final validAfter =
        await receipts.getBySubscriberAndMonth('B', month, branchId: main);
    expect(validAfter.isEmpty, true);
  });

  // v30 (refined lock): a receipt locks ONLY once included in a SUBMITTED
  // settlement request — never immediately after payment.
  test('lock rule: no request → reversible; issued before request → locked; '
      'issued after request → reversible; garbage → conservative lock', () {
    // No settlement request submitted → the receipt stays reversible.
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: null, issuedAt: '2026-09-05T10:00:00.000Z'),
        false);
    // Issued BEFORE the request → its cash was in the requested balance → locked.
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: '2026-09-05T12:00:00.000Z',
            issuedAt: '2026-09-05T11:00:00.000Z'),
        true);
    // Issued AFTER the request → not part of any settlement → reversible.
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: '2026-09-05T12:00:00.000Z',
            issuedAt: '2026-09-05T13:00:00.000Z'),
        false);
    // Unparseable timestamps → conservatively locked (financial safety).
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: 'garbage',
            issuedAt: '2026-09-05T13:00:00.000Z'),
        true);
  });

  test('lastActiveRequestAt: rejected never locks; newest active wins; '
      'method-scoped', () async {
    final sRepo = SettlementRepository();
    Settlement st(String id, String status, String at, {String m = 'cash'}) =>
        Settlement(
            id: id,
            accountantId: 'acct-9',
            amount: 100,
            method: m,
            status: status,
            requestedAt: at);
    // Only a REJECTED request → nothing locks.
    await sRepo.insert(st('s-rej', 'rejected', '2026-09-01T10:00:00.000Z'));
    expect(await sRepo.lastActiveRequestAt('acct-9', 'cash'), isNull);
    // A pending request → it is the active lock point.
    await sRepo.insert(st('s-pen', 'pending', '2026-09-02T10:00:00.000Z'));
    expect(await sRepo.lastActiveRequestAt('acct-9', 'cash'),
        '2026-09-02T10:00:00.000Z');
    // An older approved one doesn't override the newer pending.
    await sRepo.insert(st('s-app', 'approved', '2026-09-01T09:00:00.000Z'));
    expect(await sRepo.lastActiveRequestAt('acct-9', 'cash'),
        '2026-09-02T10:00:00.000Z');
    // The CARD wallet is independent of the cash one.
    expect(await sRepo.lastActiveRequestAt('acct-9', 'card'), isNull);
  });
}
