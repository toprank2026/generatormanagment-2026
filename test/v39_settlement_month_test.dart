import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v39 — settlement MONTH ISOLATION (owner decision, strict):
///   history()/listAllForOwner()/pendingCount() confine to the requested
///   month (`requested_at` UTC prefix, pending rows included — the v27
///   "pending always surfaces" bypass was removed), and monthUnsettled()
///   derives the month-isolated unsettled balance (clamped ≥ 0).
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

  const main = DbHelper.kMainBranchId;
  const acct = 'acct-1';
  final settles = SettlementRepository();
  final receipts = ReceiptRepository();

  Settlement st(String id, String status, String requestedAt,
          {double amount = 1000, String method = 'cash', String? month}) =>
      Settlement(
        id: id,
        accountantId: acct,
        branchId: main,
        amount: amount,
        method: method,
        status: status,
        month: month,
        requestedAt: requestedAt,
      );

  Receipt rc(String uuid,
          {required double cash,
          required String month,
          String status = 'valid',
          String method = 'cash',
          String? issuedAt}) =>
      Receipt(
        uuid: uuid,
        receiptNo: 0,
        subscriberId: 'S',
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 1000,
        paidAmount: cash,
        remainingAfter: 0,
        accountantId: acct,
        branchId: main,
        categorySnapshot: SubscriberCategory.standard,
        status: status,
        paymentMethod: method,
        issuedAt: issuedAt ?? '$month-05T10:00:00.000Z',
      );

  test('history / listAllForOwner / pendingCount are STRICTLY month-isolated',
      () async {
    // September: one approved + one pending. August: one approved + one pending.
    await settles.insert(
        st('sep-appr', 'approved', '2026-09-10T09:00:00.000Z', amount: 6000));
    await settles.insert(st('sep-pend', 'pending', '2026-09-20T09:00:00.000Z'));
    await settles.insert(
        st('aug-appr', 'approved', '2026-08-10T09:00:00.000Z', amount: 4000));
    await settles.insert(st('aug-pend', 'pending', '2026-08-20T09:00:00.000Z'));

    // Accountant history: month param confines the list — pending included.
    final sep = await settles.history(acct, limit: 10, offset: 0, month: '2026-09');
    expect(sep.map((s) => s.id).toSet(), {'sep-appr', 'sep-pend'});
    final aug = await settles.history(acct, limit: 10, offset: 0, month: '2026-08');
    expect(aug.map((s) => s.id).toSet(), {'aug-appr', 'aug-pend'});
    // No month → the old all-time behavior is untouched.
    expect((await settles.history(acct, limit: 10, offset: 0)).length, 4);

    // Admin list: the v27 "pending from ANY month always shows" bypass is GONE
    // — August's pending must NOT leak into September's view.
    final sepAll = await settles.listAllForOwner(month: '2026-09');
    expect(sepAll.map((r) => r.settlement.id).toSet(), {'sep-appr', 'sep-pend'},
        reason: 'strict isolation: no cross-month pending rows');
    final augAll = await settles.listAllForOwner(month: '2026-08');
    expect(augAll.map((r) => r.settlement.id).toSet(), {'aug-appr', 'aug-pend'});

    // Pending banner: month-scoped count; all-time still available.
    expect(await settles.pendingCount(month: '2026-09'), 1);
    expect(await settles.pendingCount(month: '2026-08'), 1);
    expect(await settles.pendingCount(month: '2026-07'), 0);
    expect(await settles.pendingCount(), 2);

    // Total Settlement (the card's query) stays per-month: 6,000 vs 4,000 —
    // never accumulated across months.
    expect(await settles.approvedSumForMonth('2026-09', 'cash'), 6000);
    expect(await settles.approvedSumForMonth('2026-08', 'cash'), 4000);
  });

  test('monthUnsettled = month receipts − month approved settlements, clamped',
      () async {
    // September receipts by acct-1: 10,000 cash + 5,000 card (valid) +
    // 3,000 refunded (ignored). October: 7,000 (other month, ignored).
    await receipts.insertWithAllocatedNumber(
        rc('r1', cash: 10000, month: '2026-09'),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r2', cash: 5000, month: '2026-09', method: 'card'),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r3', cash: 3000, month: '2026-09', status: 'refunded'),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r4', cash: 7000, month: '2026-10'),
        branchId: main);

    // No settlements yet: the whole month is unsettled.
    expect(await settles.monthUnsettled(acct, '2026-09'), 15000);

    // Approved September settlement of 6,000 reduces it; a PENDING request and
    // a legacy approved SALARY row never do.
    await settles.insert(
        st('s1', 'approved', '2026-09-12T09:00:00.000Z', amount: 6000));
    await settles.insert(
        st('s2', 'pending', '2026-09-25T09:00:00.000Z', amount: 2000));
    await settles.insert(st('s3', 'approved', '2026-09-26T09:00:00.000Z',
        amount: 100000, method: 'salary'));
    expect(await settles.monthUnsettled(acct, '2026-09'), 9000,
        reason: '15,000 valid cash+card − 6,000 approved');

    // August: nothing collected but 4,000 approved → CLAMPED at 0, never
    // negative (money of one month settled in another stays a display 0).
    await settles.insert(
        st('s4', 'approved', '2026-08-10T09:00:00.000Z', amount: 4000));
    expect(await settles.monthUnsettled(acct, '2026-08'), 0);

    // October only sees its own receipt.
    expect(await settles.monthUnsettled(acct, '2026-10'), 7000);
  });

  // v40 — FUTURE-MONTH BILLING: the stamped TARIFF month is the accounting
  // bucket; the transaction timestamps stay historical-only. Acceptance
  // scenario from the owner spec: tariff month = August, today = July 28.
  test('v40: tariff-month stamp buckets settlements; timestamps stay history',
      () async {
    // Collect 15,000 of AUGUST subscriptions on JULY 28: the receipt carries
    // month='2026-08' (tariff) with the TRUE July issue timestamp — already
    // the app behavior (billing stamps the global month, issuedAt = now).
    await receipts.insertWithAllocatedNumber(
        rc('rAug',
            cash: 15000,
            month: '2026-08',
            issuedAt: '2026-07-28T10:00:00.000Z'),
        branchId: main);
    final aug = (await receipts.getByUuid('rAug'))!;
    expect(aug.month, '2026-08');
    expect(await receipts.getCollectedSum('2026-08', branchId: main), 15000);
    expect(await receipts.getCollectedSum('2026-07', branchId: main), 0);

    // The accountant settles on JULY 29 — the request carries the TARIFF
    // month (August); requested_at remains the true July timestamp.
    await settles.insert(st('stAug', 'pending', '2026-07-29T09:00:00.000Z',
        amount: 15000, month: '2026-08'));

    // Pending banner + histories + admin list: the request lives in AUGUST.
    expect(await settles.pendingCount(month: '2026-08'), 1);
    expect(await settles.pendingCount(month: '2026-07'), 0);
    expect(
        (await settles.history(acct, limit: 10, offset: 0, month: '2026-08'))
            .map((s) => s.id),
        ['stAug']);
    expect(
        (await settles.history(acct, limit: 10, offset: 0, month: '2026-07'))
            .isEmpty,
        true);
    expect((await settles.listAllForOwner(month: '2026-08'))
        .map((r) => r.settlement.id), ['stAug']);
    expect((await settles.listAllForOwner(month: '2026-07')).isEmpty, true);

    // Approve → Total Settlement books into AUGUST, July stays 0, and the
    // August unsettled balance closes (was the v39 phantom: August kept
    // showing 15,000 unsettled forever while July got the credit).
    final req = (await settles.listAllForOwner(month: '2026-08'))
        .first.settlement;
    expect(await settles.decide(req, 'approved', decidedBy: 'owner'), true);
    expect(await settles.approvedSumForMonth('2026-08', 'cash'), 15000);
    expect(await settles.approvedSumForMonth('2026-07', 'cash'), 0);
    expect(await settles.monthUnsettled(acct, '2026-08'), 0,
        reason: '15,000 August cash − 15,000 August-stamped settlement');
    expect(await settles.monthUnsettled(acct, '2026-07'), 0,
        reason: 'July collected nothing and is charged nothing');
    // The stamp survives the decision round-trip.
    final decided = (await settles.listAllForOwner(month: '2026-08'))
        .first.settlement;
    expect(decided.month, '2026-08');
    expect(decided.status, 'approved');
    expect(decided.requestedAt, '2026-07-29T09:00:00.000Z',
        reason: 'the historical transaction timestamp is NEVER rewritten');

    // MIXED DB: a legacy (unstamped) settlement keeps its old bucketing.
    await settles.insert(
        st('stLegacy', 'approved', '2026-07-10T09:00:00.000Z', amount: 500));
    expect(await settles.approvedSumForMonth('2026-07', 'cash'), 500,
        reason: 'legacy row buckets by requested_at prefix, unchanged');
    expect(await settles.approvedSumForMonth('2026-08', 'cash'), 15000,
        reason: 'stamped row unaffected by the legacy neighbor');

    // CROSS-MONTH LOCK PIN: the July-28 receipt is inside the July-29 request
    // (the wallet is all-time) → locked, regardless of either month stamp.
    final lastReq = await settles.lastActiveRequestAt(acct, 'cash');
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: lastReq, issuedAt: aug.issuedAt),
        true,
        reason: 'locks compare timestamps — month stamping must not change them');
  });
}
