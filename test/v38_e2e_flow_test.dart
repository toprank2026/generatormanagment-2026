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

/// v38 — END-TO-END financial lifecycle simulation (fake data), asserting
/// EVERY figure after EVERY step, exactly as the owner requested:
///   pay (partial) → pay with AMPERE discount → pay with VALUE discount →
///   wallet → settlement request → approval → reversal lock on settled money →
///   new post-settlement receipt → refund it → amps INCREASE → amps DECREASE →
///   the revenue-vs-settlement identity → the negative-wallet root cause.
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
  const acct = 'acct-1';
  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();
  final settles = SettlementRepository();

  Subscriber sub(String id, double amps) => Subscriber(
        id: id,
        name: id,
        amps: amps,
        boardId: 'b',
        circuitId: 'c-$id',
        category: SubscriberCategory.standard,
        branchId: main,
      );

  Receipt pay(
    String uuid,
    String subId, {
    required double cash,
    required double amps,
    required double remaining,
    double discountValue = 0,
    double? discountAmps,
    String discountType = 'none',
    required String issuedAt,
    String payMonth = month,
    String method = 'cash',
  }) =>
      Receipt(
        uuid: uuid,
        receiptNo: 0,
        subscriberId: subId,
        month: payMonth,
        ampsSnapshot: amps,
        priceSnapshot: 1000,
        paidAmount: cash,
        remainingAfter: remaining,
        accountantId: acct,
        branchId: main,
        categorySnapshot: SubscriberCategory.standard,
        discountType: discountType,
        discountValue: discountValue,
        discountAmps: discountAmps,
        issuedAt: issuedAt,
        paymentMethod: method,
      );

  Future<int> paidCount() =>
      subs.countByPaymentStatus(month: month, isPaid: true, branchId: main);
  Future<int> unpaidCount() =>
      subs.countByPaymentStatus(month: month, isPaid: false, branchId: main);
  Future<double> collected() =>
      receipts.getCollectedSum(month, branchId: main);
  Future<double> discounts() => receipts.getDiscountSum(month, branchId: main);
  Future<double> remaining() =>
      subs.remainingFeesTotal(month: month, branchId: main);

  test('E2E: pay → ampere/value discounts → settle → locks → refund → amps ±',
      () async {
    // Tariff: standard 1,000 IQD per amp.
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 1000,
        branchId: main,
        category: SubscriberCategory.standard));

    // Roster: A 10A, B 10A, C 5A, D 10A → expected = 35,000.
    await subs.insert(sub('A', 10));
    await subs.insert(sub('B', 10));
    await subs.insert(sub('C', 5));
    await subs.insert(sub('D', 10));
    expect(await unpaidCount(), 4);
    expect(await remaining(), 35000);

    // ---- STEP 1: PARTIAL payment — A pays 4,000 of 10,000 -----------------
    await receipts.insertWithAllocatedNumber(
        pay('rA', 'A',
            cash: 4000,
            amps: 10,
            remaining: 6000,
            issuedAt: '2026-09-05T09:00:00.000Z'),
        branchId: main);
    expect(await collected(), 4000, reason: 'partial cash counts');
    expect(await paidCount(), 0, reason: 'partial ≠ paid');
    expect(await remaining(), 31000, reason: '35,000 − 4,000');

    // ---- STEP 2: FULL payment + AMPERE discount — B: 2 amps waived --------
    // discountValue = 2 × 1,000 = 2,000 → cash = 10,000 − 2,000 = 8,000.
    await receipts.insertWithAllocatedNumber(
        pay('rB', 'B',
            cash: 8000,
            amps: 10,
            remaining: 0,
            discountType: 'ampere',
            discountAmps: 2,
            discountValue: 2000,
            issuedAt: '2026-09-05T10:00:00.000Z'),
        branchId: main);
    expect(await collected(), 12000, reason: 'cash only — discount excluded');
    expect(await discounts(), 2000);
    expect(await paidCount(), 1, reason: 'coverage 8,000+2,000 = due 10,000');
    expect(await remaining(), 21000, reason: 'A 6,000 + C 5,000 + D 10,000');

    // ---- STEP 3: FULL payment + VALUE discount — C: 500 IQD waived --------
    await receipts.insertWithAllocatedNumber(
        pay('rC', 'C',
            cash: 4500,
            amps: 5,
            remaining: 0,
            discountType: 'value',
            discountValue: 500,
            issuedAt: '2026-09-05T10:30:00.000Z'),
        branchId: main);
    expect(await collected(), 16500);
    expect(await discounts(), 2500);
    expect(await paidCount(), 2);
    expect(await remaining(), 16000, reason: 'A 6,000 + D 10,000');

    // ---- STEP 4: WALLET → SETTLEMENT REQUEST → APPROVAL -------------------
    var w = await settles.wallet(acct);
    expect(w.cashCollected, 16500, reason: 'wallet = cash actually received');
    expect(w.cashBalance, 16500);
    final req = Settlement(
        id: 'st-1',
        accountantId: acct,
        branchId: main,
        amount: w.cashBalance, // request = exact balance (app behavior)
        method: 'cash',
        status: 'pending',
        requestedAt: '2026-09-05T11:00:00.000Z');
    await settles.insert(req);
    expect(await settles.hasPending(acct, 'cash'), true);
    // Approve.
    expect(await settles.decide(req, 'approved', decidedBy: 'owner'), true);
    w = await settles.wallet(acct);
    expect(w.cashSettled, 16500);
    expect(w.cashBalance, 0, reason: 'settled everything → balance 0');
    // Settlement totals NEVER exceed received money.
    final settledSum =
        await settles.approvedSumForMonth(month, 'cash', accountantId: acct);
    expect(settledSum, 16500);
    expect(settledSum <= await collected(), true);
    // v35 idempotency: a second decision is a NO-OP.
    expect(await settles.decide(req, 'rejected'), false);
    expect((await settles.wallet(acct)).cashSettled, 16500);

    // ---- STEP 5: settled receipts are LOCKED against refund ---------------
    final lastReq = await settles.lastActiveRequestAt(acct, 'cash');
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: lastReq,
            issuedAt: '2026-09-05T10:00:00.000Z'), // rB — before the request
        true,
        reason: 'settled cash cannot be un-collected');

    // ---- STEP 6: NEW receipt AFTER the settlement — D pays full -----------
    await receipts.insertWithAllocatedNumber(
        pay('rD', 'D',
            cash: 10000,
            amps: 10,
            remaining: 0,
            issuedAt: '2026-09-05T12:00:00.000Z'),
        branchId: main);
    expect(await collected(), 26500);
    expect(await paidCount(), 3);
    w = await settles.wallet(acct);
    expect(w.cashBalance, 10000, reason: '26,500 received − 16,500 settled');
    // THE revenue-vs-settlement identity (owner question): the difference
    // between total received and total settled is EXACTLY the unsettled
    // wallet balance — never an error.
    expect(await collected() - settledSum, w.cashBalance);
    // rD is NOT locked (issued after the request) → refundable.
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: lastReq,
            issuedAt: '2026-09-05T12:00:00.000Z'),
        false);

    // ---- STEP 7: REFUND rD (unsettled) — every figure restores ------------
    await receipts.markRefunded((await receipts.getByUuid('rD'))!);
    expect(await collected(), 16500, reason: 'refund removes the cash');
    expect(await paidCount(), 2, reason: 'D back to unpaid');
    expect(await remaining(), 16000, reason: 'A 6,000 + D 10,000 again');
    w = await settles.wallet(acct);
    expect(w.cashBalance, 0, reason: 'refunded cash leaves the wallet');

    // ---- STEP 8: AMPS INCREASE on paid B (10 → 15) -------------------------
    final b = (await subs.getById('B'))!;
    b.amps = 15;
    await subs.update(b);
    expect(await paidCount(), 1, reason: 'B owes 15,000, covered 10,000');
    expect(await remaining(), 21000,
        reason: 'A 6,000 + D 10,000 + B residual 5,000');
    expect(await collected(), 16500, reason: 'cash history NEVER changes');

    // ---- STEP 9: AMPS DECREASE on paid C (5 → 3): over-coverage -----------
    final c = (await subs.getById('C'))!;
    c.amps = 3;
    await subs.update(c);
    expect(await paidCount(), 1, reason: 'C still paid (coverage 5,000 ≥ 3,000)');
    expect(await remaining(), 21000,
        reason: 'over-coverage is CLAMPED per subscriber — never netted');
    expect(await collected(), 16500);

    // ---- STEP 10: the NEGATIVE-WALLET root cause, demonstrated ------------
    // The app's guards block this (delete guard v35 / reversal lock v31); we
    // bypass them with raw SQL to reproduce the historical incident: erasing a
    // SETTLED receipt drops Collected while Settled stays.
    // First: the delete guard's own check would have refused it.
    final scoped = await receipts.validReceiptsForDeleteScope(subscriberId: 'B');
    expect(scoped.length, 1);
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: lastReq, issuedAt: scoped.first.issuedAt),
        true,
        reason: 'the v35 delete guard blocks exactly this');
    // Bypass (simulating pre-guard data damage):
    final db = await DbHelper().database;
    await db.delete('receipts', where: 'uuid = ?', whereArgs: ['rB']);
    w = await settles.wallet(acct);
    expect(w.cashCollected, 8500, reason: '16,500 − erased 8,000');
    expect(w.cashBalance, -8000,
        reason: 'THIS is the only way a wallet goes negative — erased settled '
            'cash; the app refuses it, and the UI clamps the display at 0');
  });

  // Gap scenarios flagged by the v38 verification fleet: multi-receipt
  // coverage, refund of a DISCOUNTED receipt, cash/card wallet separation,
  // settlement REJECTION, cross-month isolation, and the price-0 free month.
  test('E2E gaps: multi-partial → paid, discounted refund, card wallet, '
      'rejection, month isolation, price-0', () async {
    await prices.insert(MonthlyPrice(
        month: month,
        pricePerAmp: 1000,
        branchId: main,
        category: SubscriberCategory.standard));
    await subs.insert(sub('E', 10));
    await subs.insert(sub('F', 10));
    await subs.insert(sub('G', 5));
    expect(await remaining(), 25000);

    // ---- GAP 1: TWO partial payments ACCUMULATE to paid -------------------
    await receipts.insertWithAllocatedNumber(
        pay('rE1', 'E',
            cash: 3000,
            amps: 10,
            remaining: 7000,
            issuedAt: '2026-09-06T09:00:00.000Z'),
        branchId: main);
    expect(await paidCount(), 0);
    expect(await remaining(), 22000, reason: 'E 7,000 + F 10,000 + G 5,000');
    await receipts.insertWithAllocatedNumber(
        pay('rE2', 'E',
            cash: 7000,
            amps: 10,
            remaining: 0,
            issuedAt: '2026-09-06T09:30:00.000Z'),
        branchId: main);
    expect(await paidCount(), 1, reason: 'coverage SUMS receipts: 3,000+7,000');
    expect(await collected(), 10000);
    expect(await remaining(), 15000, reason: 'F 10,000 + G 5,000');

    // ---- GAP 2: refund of a DISCOUNTED receipt ----------------------------
    // Coverage must drop by cash AND discount together; the discounts card
    // must also give the waived amount back.
    await receipts.insertWithAllocatedNumber(
        pay('rF', 'F',
            cash: 9000,
            amps: 10,
            remaining: 0,
            discountType: 'value',
            discountValue: 1000,
            issuedAt: '2026-09-06T10:00:00.000Z'),
        branchId: main);
    expect(await paidCount(), 2);
    expect(await discounts(), 1000);
    await receipts.markRefunded((await receipts.getByUuid('rF'))!);
    expect(await collected(), 10000, reason: 'cash 9,000 restored');
    expect(await discounts(), 0, reason: 'waived 1,000 restored too');
    expect(await paidCount(), 1, reason: 'F unpaid again — full coverage gone');
    expect(await remaining(), 15000, reason: 'F owes the FULL 10,000 again');

    // ---- GAP 3: cash/card wallets are fully SEPARATE ----------------------
    await receipts.insertWithAllocatedNumber(
        pay('rG', 'G',
            cash: 5000,
            amps: 5,
            remaining: 0,
            method: 'card',
            issuedAt: '2026-09-06T11:00:00.000Z'),
        branchId: main);
    var w = await settles.wallet(acct);
    expect(w.cashCollected, 10000, reason: 'E only — card money excluded');
    expect(w.cardCollected, 5000);
    expect(w.cardBalance, 5000);
    // Settle the CARD wallet — the cash wallet must not move or lock.
    final cardReq = Settlement(
        id: 'st-card',
        accountantId: acct,
        branchId: main,
        amount: 5000,
        method: 'card',
        status: 'pending',
        requestedAt: '2026-09-06T12:00:00.000Z');
    await settles.insert(cardReq);
    expect(await settles.decide(cardReq, 'approved', decidedBy: 'owner'), true);
    w = await settles.wallet(acct);
    expect(w.cardBalance, 0);
    expect(w.cashBalance, 10000, reason: 'card settlement never touches cash');
    expect(await settles.lastActiveRequestAt(acct, 'cash'), isNull,
        reason: 'a card settlement does NOT lock cash receipts');
    expect(
        BillingController.isLockedBySettlement(
            lastActiveRequestAt: await settles.lastActiveRequestAt(acct, 'card'),
            issuedAt: '2026-09-06T11:00:00.000Z'), // rG
        true,
        reason: 'the card receipt IS locked by its own method\'s settlement');

    // ---- GAP 4: settlement REJECTION — balance intact, nothing locks ------
    final cashReq = Settlement(
        id: 'st-rej',
        accountantId: acct,
        branchId: main,
        amount: 10000,
        method: 'cash',
        status: 'pending',
        requestedAt: '2026-09-06T13:00:00.000Z');
    await settles.insert(cashReq);
    expect(await settles.decide(cashReq, 'rejected', decidedBy: 'owner'), true);
    w = await settles.wallet(acct);
    expect(w.cashSettled, 0, reason: 'rejected money never left the wallet');
    expect(w.cashBalance, 10000, reason: 'balance unchanged after rejection');
    expect(await settles.hasPending(acct, 'cash'), false);
    expect(await settles.lastActiveRequestAt(acct, 'cash'), isNull,
        reason: 'rejected requests never lock receipts');

    // ---- GAP 5: MONTH ISOLATION — another month\'s receipt is invisible ----
    await receipts.insertWithAllocatedNumber(
        pay('rE3', 'E',
            cash: 4000,
            amps: 10,
            remaining: 6000,
            payMonth: '2026-10',
            issuedAt: '2026-10-03T09:00:00.000Z'),
        branchId: main);
    expect(await collected(), 15000,
        reason: '2026-09 untouched: 10,000 cash (E) + 5,000 card (G) — '
            'month revenue counts BOTH methods');
    expect(await paidCount(), 2, reason: 'E and G paid; F refunded');
    expect(await receipts.getCollectedSum('2026-10', branchId: main), 4000);
    expect(
        await subs.countByPaymentStatus(
            month: '2026-10', isPaid: true, branchId: main),
        0,
        reason: '2026-10 is unpriced → nobody is paid there, receipt or not');
    // The WALLET, by design, is ALL-TIME (cross-month) — this is exactly the
    // "month timing" part of the revenue-vs-settlement difference.
    w = await settles.wallet(acct);
    expect(w.cashBalance, 14000, reason: '10,000 (Sep) + 4,000 (Oct)');

    // ---- GAP 6: price 0 = FREE month — everyone counts as paid ------------
    await prices.insert(MonthlyPrice(
        month: '2026-11',
        pricePerAmp: 0,
        branchId: main,
        category: SubscriberCategory.standard));
    expect(
        await subs.countByPaymentStatus(
            month: '2026-11', isPaid: true, branchId: main),
        3,
        reason: 'due = amps × 0 = 0 → coverage 0 ≥ 0 → paid');
    expect(await subs.remainingFeesTotal(month: '2026-11', branchId: main), 0);
  });
}
