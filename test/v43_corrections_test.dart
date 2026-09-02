import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/correction_models.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/correction_repository.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// Flash v43 — CORRECTIONS AFTER INVOICING, end to end, against the real
/// repositories (`CorrectionRepository` + `SettlementRepository`), asserting
/// every figure after every step in the style of `v38_e2e_flow_test.dart`.
///
/// The owner's Golden Rule, which is what this file exists to pin down:
///
/// > Invoice month = accounting month = settlement month = correction month.
/// > A correction for one billing month must never alter or financially affect
/// > another month, and the accountant's wallet must never be driven negative
/// > by a historical correction.
///
/// Covered here: a correction BEFORE any settlement · a correction AFTER one ·
/// INCREASE (wallet rises by exactly the difference, an additional settlement
/// for the month becomes possible) · DECREASE (`refund_due`, the wallet is NOT
/// reduced) · the wallet never going negative even when the decrease is larger
/// than the month's collected cash · `refund_due → cash returned → completed` ·
/// the ORIGINAL receipt / settlement / subscriber rows staying byte-identical
/// through all of it · same-month isolation · idempotency.
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

  const aug = '2026-08';
  const sep = '2026-09';
  const main = DbHelper.kMainBranchId;
  const acct = 'acct-1';
  const owner = 'owner-1';

  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();
  final settles = SettlementRepository();
  final corr = CorrectionRepository();

  // ---------------------------------------------------------------------------
  // fixtures
  // ---------------------------------------------------------------------------

  Future<void> price(String month, double perAmp) => prices.insert(MonthlyPrice(
      month: month,
      pricePerAmp: perAmp,
      branchId: main,
      category: SubscriberCategory.standard));

  Future<void> addSub(String id, double amps, {String from = aug}) =>
      subs.insert(Subscriber(
        id: id,
        name: id,
        amps: amps,
        boardId: 'b',
        circuitId: 'c-$id',
        category: SubscriberCategory.standard,
        branchId: main,
        billingStartMonth: from, // v42 item 5 — explicit, never inferred here
      ));

  Future<void> pay(
    String uuid,
    String subId, {
    required double cash,
    required double amps,
    required double remaining,
    String month = aug,
    String method = 'cash',
    required String issuedAt,
  }) =>
      receipts.insertWithAllocatedNumber(
          Receipt(
            uuid: uuid,
            receiptNo: 0,
            subscriberId: subId,
            month: month,
            ampsSnapshot: amps,
            priceSnapshot: 1000,
            paidAmount: cash,
            remainingAfter: remaining,
            accountantId: acct,
            branchId: main,
            categorySnapshot: SubscriberCategory.standard,
            issuedAt: issuedAt,
            paymentMethod: method,
          ),
          branchId: main);

  Future<Settlement> settle(String id, double amount,
      {String month = aug, String method = 'cash', required String at}) async {
    final s = Settlement(
        id: id,
        accountantId: acct,
        branchId: main,
        amount: amount,
        method: method,
        status: 'pending',
        month: month, // v40: the TARIFF month is the accounting bucket
        requestedAt: at);
    await settles.insert(s);
    return s;
  }

  /// Files a correction exactly as `CorrectionController.requestCorrection`
  /// composes it: the subscriber/receipt/settlement rows are only READ, and
  /// `difference = newDue − oldDue` is the entire money story — booked only if
  /// and when the owner approves.
  Future<Correction> request(
    String id,
    String subId, {
    required double oldAmps,
    required double newAmps,
    double perAmp = 1000,
    String month = aug,
    String? receiptUuid,
    String? settlementId,
    String reason = 'meter re-read',
  }) async {
    final double oldDue = oldAmps * perAmp;
    final double newDue = newAmps * perAmp;
    final c = Correction(
      id: id,
      subscriberId: subId,
      month: month,
      branchId: main,
      accountantId: acct, // the wallet the delta belongs to
      receiptUuid: receiptUuid,
      settlementId: settlementId,
      reason: reason,
      oldAmps: oldAmps,
      newAmps: newAmps,
      oldDue: oldDue,
      newDue: newDue,
      difference: newDue - oldDue,
      requestedBy: acct,
    );
    await corr.create(c);
    return c;
  }

  // ---------------------------------------------------------------------------
  // the two owner/admin operations, mirroring CorrectionController EXACTLY
  //
  // The controller needs GetX (Auth/Branch/Month + snackbars), so its two money
  // paths are reproduced here against the same repositories with the same
  // sequence, the same DETERMINISTIC adjustment id, the same amounts and the
  // same signs — including the deliberate `accountantId: null` on a refund
  // return, which is what keeps an accountant's derived wallet out of it.
  // ---------------------------------------------------------------------------

  String adjustmentId(String correctionId, String kind) => const Uuid()
      .v5(Namespace.url.value, 'moldati/v43/adjustment/$correctionId/$kind');

  /// INCREASE → `correction_increase` (+Δ) and status `approved`.
  /// DECREASE → `correction_decrease` (|Δ|, which counts as ZERO in every
  /// wallet figure) and status `refund_due`: the wallet is never reduced.
  Future<bool> approve(Correction c) async {
    final fresh = await corr.getById(c.id);
    if (fresh == null || !fresh.isPending) return false;
    final double delta = fresh.difference;
    // v43 review fix: the GUARDED status transition runs FIRST, so a device
    // that loses the race writes nothing into the append-only ledger.
    final bool ok = await corr.decide(
      fresh,
      delta < 0 ? CorrectionStatus.refundDue : CorrectionStatus.approved,
      decidedBy: owner,
    );
    if (!ok) return false;
    if (delta != 0) {
      final String kind =
          delta > 0 ? AdjustmentKind.increase : AdjustmentKind.decrease;
      await corr.insertAdjustment(FinancialAdjustment(
        id: adjustmentId(fresh.id, kind),
        correctionId: fresh.id,
        subscriberId: fresh.subscriberId,
        month: fresh.month,
        branchId: fresh.branchId,
        accountantId: fresh.accountantId,
        kind: kind,
        amount: delta.abs(),
        method: 'cash',
        createdBy: owner,
      ));
    }
    // v43.1 - mirrors CorrectionController.approve: the corrected amps are
    // written onto the SUBSCRIBER so future months bill the new value.
    final double? applied = fresh.newAmps;
    final String? tid = fresh.subscriberId;
    if (applied != null && applied > 0 && tid != null && tid.isNotEmpty) {
      final target = await subs.getById(tid);
      if (target != null && target.amps != applied) {
        target.amps = applied;
        await subs.update(target);
      }
    }
    return true;
  }

  /// The PHYSICAL cash return that closes a decrease: `refund_due → completed`
  /// plus one NEGATIVE `refund_return` row carrying NO accountant (the owner
  /// hands the money back, so no accountant's wallet may fall because of it).
  Future<bool> recordRefundPaid(Correction c) async {
    final fresh = await corr.getById(c.id);
    if (fresh == null || !fresh.isRefundDue) return false;
    // Same ordering rule as approve(): guarded transition first.
    final bool ok = await corr.markRefundPaid(fresh, paidBy: owner);
    if (!ok) return false;
    await corr.insertAdjustment(FinancialAdjustment(
      id: adjustmentId(fresh.id, AdjustmentKind.refundReturn),
      correctionId: fresh.id,
      subscriberId: fresh.subscriberId,
      month: fresh.month,
      branchId: fresh.branchId,
      accountantId: null,
      kind: AdjustmentKind.refundReturn,
      amount: -fresh.difference.abs(),
      method: 'cash',
      createdBy: owner,
    ));
    return true;
  }

  /// v44 — closes a decrease by applying its credit to the NEXT month:
  /// `refund_due -> carried_forward` + ONE `credit_applied` row whose month is
  /// the TARGET month. No cash moves.
  String nextMonthOf(String m) {
    final p = m.split('-');
    final d = DateTime(int.parse(p[0]), int.parse(p[1]) + 1);
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';
  }

  Future<bool> carryForward(Correction c) async {
    final fresh = await corr.getById(c.id);
    if (fresh == null || !fresh.isRefundDue) return false;
    final ok = await corr.carryForward(fresh, by: owner);
    if (!ok) return false;
    await corr.insertAdjustment(FinancialAdjustment(
      id: adjustmentId(fresh.id, AdjustmentKind.creditApplied),
      correctionId: fresh.id,
      subscriberId: fresh.subscriberId,
      month: nextMonthOf(fresh.month!),
      branchId: fresh.branchId,
      accountantId: null,
      kind: AdjustmentKind.creditApplied,
      amount: fresh.difference.abs(),
      method: 'cash',
      createdBy: owner,
    ));
    return true;
  }

  // ---------------------------------------------------------------------------
  // readers
  // ---------------------------------------------------------------------------

  Future<double> collected(String month) =>
      receipts.getCollectedSum(month, branchId: main);
  Future<int> paidCount(String month) =>
      subs.countByPaymentStatus(month: month, isPaid: true, branchId: main);
  Future<int> unpaidCount(String month) =>
      subs.countByPaymentStatus(month: month, isPaid: false, branchId: main);
  Future<double> remaining(String month) =>
      subs.remainingFeesTotal(month: month, branchId: main);

  /// The raw stored row, so "unchanged" can be asserted as WHOLE-ROW equality
  /// (paid_amount, status, month, amps_snapshot, price_snapshot, updated_at —
  /// everything), not as a hand-picked list of fields that could hide an edit.
  Future<Map<String, Object?>> rawRow(String table, String pk, String id) async {
    final db = await DbHelper().database;
    final rows = await db.query(table, where: '$pk = ?', whereArgs: [id]);
    expect(rows.length, 1, reason: '$table/$id must still exist, exactly once');
    return Map<String, Object?>.from(rows.first);
  }

  /// The cash a settlement request could actually be filed for, mirroring
  /// `SettlementController.requestSettlement`: the amount is
  /// min(month balance, LIFETIME balance) — the v42 cap — and a still-pending
  /// request for the month blocks a new one. 0 means "not possible".
  Future<double> requestableCash(String month) async {
    final m = await settles.walletForMonth(acct, month);
    final l = await settles.wallet(acct);
    final double bal =
        m.cashBalance < l.cashBalance ? m.cashBalance : l.cashBalance;
    if (bal <= 0) return 0;
    if (await settles.hasPending(acct, 'cash', month: month)) return 0;
    return bal;
  }

  // ===========================================================================
  // 1. A correction filed BEFORE any settlement exists — the INCREASE branch.
  // ===========================================================================
  test('increase BEFORE any settlement: wallet rises by exactly the difference, '
      'originals untouched, the month then settles at the corrected figure',
      () async {
    await price(aug, 1000);
    await addSub('A', 10);
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05T09:00:00.000Z');

    expect(await collected(aug), 10000);
    expect(await paidCount(aug), 1);
    var w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 10000);
    expect(w.cashBalance, 10000);

    // The month is NOT settlement-locked yet — this is the "before" scenario.
    expect(await settles.monthHasActiveSettlement(aug), false);

    final receiptBefore = await rawRow('receipts', 'uuid', 'rA');
    final subBefore = await rawRow('subscribers', 'id', 'A');

    // ---- file: A was metered at 12A, invoiced at 10A → +2,000 -------------
    final c = await request('cor-1', 'A',
        oldAmps: 10, newAmps: 12, receiptUuid: 'rA');
    expect(c.difference, 2000);
    expect(c.isIncrease, true);
    expect(c.settlementId, isNull, reason: 'nothing had settled the month yet');
    expect(c.requestedAt, isNotNull, reason: 'create() stamps the request time');

    var stored = (await corr.getById('cor-1'))!;
    expect(stored.status, CorrectionStatus.pending);
    expect(
        (await corr.list(
                status: CorrectionStatus.pending, month: aug, limit: 10, offset: 0))
            .map((x) => x.id),
        ['cor-1']);

    // A PENDING correction moves NO money — it is only a request.
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0);
    expect(await collected(aug), 10000);
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 10000);

    // ---- approve ----------------------------------------------------------
    expect(await approve(stored), true);
    stored = (await corr.getById('cor-1'))!;
    expect(stored.status, CorrectionStatus.approved);
    expect(stored.decidedBy, owner);
    expect(stored.decidedAt, isNotNull);
    expect(stored.refundPaidAt, isNull, reason: 'an increase returns no cash');

    // ONE immutable ledger row, for exactly the difference.
    final ledger = await corr.adjustmentsFor(month: aug);
    expect(ledger.length, 1);
    expect(ledger.first.kind, AdjustmentKind.increase);
    expect(ledger.first.amount, 2000);
    expect(ledger.first.correctionId, 'cor-1');
    expect(ledger.first.month, aug);
    expect(ledger.first.accountantId, acct);
    expect(ledger.first.createdAt, isNotNull);

    // ---- v44 MONEY RULE: an increase is a RECEIVABLE, not cash --------------
    // Nobody handed over any money, so NOTHING on the collected side moves.
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0,
        reason: 'an increase never credits a wallet (v43 booked phantom cash)');
    w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 10000, reason: 'exactly the cash that was received');
    expect(w.cashBalance, 10000);
    expect(w.cardCollected, 0);
    final life = await settles.wallet(acct);
    expect(life.cashCollected, 10000, reason: 'the lifetime wallet must agree');
    expect(life.cashBalance, 10000);
    expect(await settles.monthUnsettled(acct, aug), 10000);
    expect(await collected(aug), 10000, reason: 'revenue is real cash only');

    // ---- v44 DUE RULE: the customer OWES the difference and is UNPAID -------
    expect(await remaining(aug), 2000,
        reason: 'the difference is added to the outstanding balance');
    expect(await paidCount(aug), 0, reason: 'unpaid again for the difference');
    expect(await unpaidCount(aug), 1);
    expect((await subs.coverageBySubscriber(month: aug, branchId: main))['A'],
        10000, reason: 'coverage is what the subscriber paid — unchanged');
    expect(await receipts.getNextReceiptNumber(branchId: main), 2,
        reason: 'an adjustment NEVER consumes a receipt number');
    expect((await receipts.getByMonth(aug, branchId: main)).length, 1,
        reason: 'no phantom invoice in the printed history');

    // ---- the ORIGINAL INVOICE is byte-identical ----------------------------
    // The receipt is the historical document and is never rewritten.
    expect(await rawRow('receipts', 'uuid', 'rA'), receiptBefore);

    // ---- but the SUBSCRIBER is updated (v43.1) -----------------------------
    // Previously the approval moved money while leaving the subscriber on the
    // old amps, so every FUTURE month kept billing the wrong value. The record
    // must reflect reality; history is protected by DbHelper.effectiveAmps,
    // which prices August on this correction's `old_amps`.
    expect((await subs.getById('A'))!.amps, 12,
        reason: 'the corrected amps are applied to the subscriber');
    expect(subBefore['amps'], 10, reason: 'and it really was 10 before');
    // v44: the 2,000 difference is OWED (unpaid) until an ordinary receipt
    // collects it — that receipt is what reaches the wallet.
    expect(await remaining(aug), 2000);
    expect(await paidCount(aug), 0);
    await pay('rA-diff', 'A',
        cash: 2000, amps: 12, remaining: 0, issuedAt: '2026-08-06T08:00:00.000Z');
    expect(await remaining(aug), 0,
        reason: 'August is priced on the frozen 10A + the collected difference');
    expect(await paidCount(aug), 1, reason: 'the receipt covers the difference');
    w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 12000, reason: '10,000 + the 2,000 receipt');

    // ---- the corrected month now settles at the CORRECTED figure -----------
    expect(await requestableCash(aug), 12000);
    final s = await settle('st-1', 12000, at: '2026-08-06T09:00:00.000Z');
    expect(await settles.decide(s, 'approved', decidedBy: owner), true);
    w = await settles.walletForMonth(acct, aug);
    expect(w.cashSettled, 12000);
    expect(w.cashBalance, 0);
    expect(await settles.approvedSumForMonth(aug, 'cash', accountantId: acct),
        12000);
    expect(await collected(aug) - 12000, w.cashBalance,
        reason: 'received − settled is EXACTLY the unsettled balance');
  });

  // ===========================================================================
  // 2. A correction filed AFTER the month was already settled.
  // ===========================================================================
  test('increase AFTER a settlement: the settled row is untouched and an '
      'ADDITIONAL settlement for the same month becomes possible', () async {
    await price(aug, 1000);
    await addSub('A', 10);
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05T09:00:00.000Z');

    final s1 = await settle('st-1', 10000, at: '2026-08-05T11:00:00.000Z');
    expect(await settles.decide(s1, 'approved', decidedBy: owner), true);

    // The month is settlement-locked now — the "after" scenario.
    expect(await settles.monthHasActiveSettlement(aug), true);
    expect(
        await settles.monthHasActiveSettlement(aug,
            accountantId: acct, branchId: main),
        true);
    expect(await settles.monthHasActiveSettlement(sep), false,
        reason: 'the lock is per accounting month, nothing wider');

    var w = await settles.walletForMonth(acct, aug);
    expect(w.cashBalance, 0, reason: 'everything the month collected is settled');
    expect(await requestableCash(aug), 0,
        reason: 'with nothing unsettled there is nothing to hand over');

    final receiptBefore = await rawRow('receipts', 'uuid', 'rA');
    final settlementBefore = await rawRow('settlements', 'id', 'st-1');

    // ---- file + approve: 10A → 13A → +3,000 --------------------------------
    final c = await request('cor-1', 'A',
        oldAmps: 10, newAmps: 13, receiptUuid: 'rA', settlementId: 'st-1');
    expect(c.difference, 3000);
    expect(await approve(c), true);
    expect((await corr.getById('cor-1'))!.status, CorrectionStatus.approved);

    // ---- the settled month's wallet rises by exactly the difference --------
    w = await settles.walletForMonth(acct, aug);
    // v44: the increase moved NO cash — the customer owes 3,000, unpaid.
    expect(w.cashCollected, 10000);
    expect(w.cashSettled, 10000, reason: 'the settlement itself did not move');
    expect(w.cashBalance, 0);
    expect((await settles.wallet(acct)).cashBalance, 0);
    expect(await settles.monthUnsettled(acct, aug), 0);
    expect(await collected(aug), 10000);
    expect(await remaining(aug), 3000, reason: 'the customer owes the difference');
    expect(await unpaidCount(aug), 1);
    // The difference is collected with an ORDINARY receipt — that is what
    // reaches the wallet and makes the ADDITIONAL settlement possible.
    await pay('rA-diff', 'A',
        cash: 3000, amps: 13, remaining: 0, issuedAt: '2026-08-06T08:00:00.000Z');
    expect(await remaining(aug), 0);
    expect(await paidCount(aug), 1);
    w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 13000, reason: '10,000 + the 3,000 receipt');
    expect(w.cashBalance, 3000);
    expect(await settles.monthUnsettled(acct, aug), 3000);
    expect(await collected(aug), 13000);

    // ---- ORIGINALS: the invoice AND the approved settlement are intact -----
    expect(await rawRow('receipts', 'uuid', 'rA'), receiptBefore,
        reason: 'approval appends a ledger row; it never edits the invoice');
    expect(await rawRow('settlements', 'id', 'st-1'), settlementBefore,
        reason: 'amount 10,000 / status approved / month 2026-08 all unchanged');

    // ---- an ADDITIONAL settlement for the SAME month is now possible -------
    expect(await settles.hasPending(acct, 'cash', month: aug), false);
    expect(await requestableCash(aug), 3000,
        reason: 'exactly the corrected delta, capped by the lifetime balance');
    final s2 = await settle('st-2', 3000, at: '2026-08-07T09:00:00.000Z');
    expect(await settles.decide(s2, 'approved', decidedBy: owner), true);
    w = await settles.walletForMonth(acct, aug);
    expect(w.cashSettled, 13000);
    expect(w.cashBalance, 0);
    expect(await settles.approvedSumForMonth(aug, 'cash', accountantId: acct),
        13000);
    expect(
        await settles.approvedSumForMonth(aug, 'cash', accountantId: acct) <=
            await collected(aug),
        true,
        reason: 'settlements can never exceed the money actually received');
    // Still nothing rewritten by the second settlement either.
    expect(await rawRow('settlements', 'id', 'st-1'), settlementBefore);
    expect(await rawRow('receipts', 'uuid', 'rA'), receiptBefore);
  });

  // ===========================================================================
  // 3. DECREASE — refund_due, and THE WALLET IS NEVER DRIVEN NEGATIVE, even
  //    when the decrease is bigger than everything the month collected.
  // ===========================================================================
  test('decrease larger than the month cash: refund_due, the wallet is NOT '
      'reduced and never goes negative', () async {
    await price(aug, 1000);
    await addSub('B', 10);
    // PARTIAL payment: the month holds only 4,000 cash against a 10,000 due.
    await pay('rB', 'B',
        cash: 4000, amps: 10, remaining: 6000, issuedAt: '2026-08-05T09:00:00.000Z');
    expect(await collected(aug), 4000);
    expect(await unpaidCount(aug), 1);
    expect(await remaining(aug), 6000);

    final receiptBefore = await rawRow('receipts', 'uuid', 'rB');
    final double revenueBefore = await collected(aug);

    // ---- file: B was really 2A → newDue 2,000 → Δ = −8,000 ----------------
    // |Δ| is DOUBLE the cash the month ever received, which is precisely the
    // shape that could drive a derived wallet negative.
    final c = await request('cor-1', 'B',
        oldAmps: 10, newAmps: 2, receiptUuid: 'rB');
    expect(c.difference, -8000);
    expect(c.isIncrease, false);

    expect(await approve(c), true);
    final stored = (await corr.getById('cor-1'))!;
    expect(stored.status, CorrectionStatus.refundDue,
        reason: 'an approved DECREASE owes cash back — it is not just approved');
    expect(stored.isRefundDue, true);
    expect(stored.refundPaidAt, isNull,
        reason: 'approval never asserts that money moved');

    // The ledger records the decrease for the audit trail...
    final ledger = await corr.adjustmentsFor(month: aug);
    expect(ledger.length, 1);
    expect(ledger.first.kind, AdjustmentKind.decrease);
    expect(ledger.first.amount, 8000, reason: 'stored as the absolute delta');
    // ...but it contributes EXACTLY ZERO to the wallet.
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0,
        reason: 'correction_decrease is zeroed — the wallet is never reduced');

    var w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 4000, reason: 'unchanged by the approved decrease');
    expect(w.cashBalance, 4000);
    expect(w.cashBalance, greaterThanOrEqualTo(0));
    var life = await settles.wallet(acct);
    expect(life.cashBalance, 4000);
    expect(life.cashBalance, greaterThanOrEqualTo(0));
    expect(await settles.monthUnsettled(acct, aug), 4000);
    expect(await settles.monthUnsettled(acct, aug), greaterThanOrEqualTo(0));
    expect(await collected(aug), revenueBefore,
        reason: 'no cash has left the business yet');

    // Nothing else moved: the subscriber is still unpaid for the same amount,
    // because the correction changed the DUE, not what was paid.
    expect(await unpaidCount(aug), 1);
    expect(await remaining(aug), 6000);
    expect(await rawRow('receipts', 'uuid', 'rB'), receiptBefore);

    // ---- and the cash return keeps the WALLET non-negative too -------------
    expect(await recordRefundPaid(stored), true);
    w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 4000,
        reason: 'the refund carries NO accountant, so no wallet falls with it');
    expect(w.cashBalance, 4000);
    expect(w.cashBalance, greaterThanOrEqualTo(0));
    life = await settles.wallet(acct);
    expect(life.cashBalance, 4000);
    expect(life.cashBalance, greaterThanOrEqualTo(0));
    expect(await settles.monthUnsettled(acct, aug), 4000);
    expect(await settles.monthUnsettled(acct, aug), greaterThanOrEqualTo(0));
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0,
        reason: 'accountant-scoped ledger: neither the decrease nor the return');

    // The BRANCH-scoped revenue does fall by the returned cash — that money
    // physically left the business. NOTE the mechanism, asserted as a relation
    // rather than a blessed constant: the return is booked at the FULL |Δ|
    // (8,000) even though the month only ever received 4,000, so a month's
    // revenue figure can go below zero this way. The wallet — the figure the
    // Golden Rule protects — cannot, as asserted above.
    expect(await collected(aug), revenueBefore - 8000,
        reason: 'revenue falls by the cash actually handed back');
    expect(await receipts.getCollectedSum(aug, accountantId: acct), 4000,
        reason: 'an accountant-scoped figure excludes the owner-paid return');
  });

  // ===========================================================================
  // 4. refund_due → record the cash returned → completed.
  // ===========================================================================
  test('refund_due → cash returned → completed: a refund_return row is appended '
      'and the correction closes', () async {
    await price(aug, 1000);
    await addSub('C', 10);
    await pay('rC', 'C',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05T09:00:00.000Z');
    final receiptBefore = await rawRow('receipts', 'uuid', 'rC');

    // 10A invoiced, really 6A → Δ = −4,000.
    final c = await request('cor-1', 'C',
        oldAmps: 10, newAmps: 6, receiptUuid: 'rC');
    expect(c.difference, -4000);
    expect(await approve(c), true);
    var stored = (await corr.getById('cor-1'))!;
    expect(stored.status, CorrectionStatus.refundDue);
    expect(await collected(aug), 10000,
        reason: 'approving a decrease alone books nothing');

    // ---- the owner physically returns the cash ----------------------------
    expect(await recordRefundPaid(stored), true);
    stored = (await corr.getById('cor-1'))!;
    expect(stored.status, CorrectionStatus.completed);
    expect(stored.isCompleted, true);
    expect(stored.refundPaidAt, isNotNull);
    expect(stored.refundPaidBy, owner);
    expect(stored.decidedAt, isNotNull,
        reason: 'the approval stamp survives the second operation');

    // TWO ledger rows, in append order — the approval, then the cash return.
    final ledger = await corr.adjustmentsFor(month: aug, subscriberId: 'C');
    expect(ledger.length, 2);
    expect(ledger.map((a) => a.kind),
        [AdjustmentKind.decrease, AdjustmentKind.refundReturn]);
    expect(ledger.last.amount, -4000,
        reason: 'the return is NEGATIVE — cash left the business');
    expect(ledger.last.accountantId, isNull,
        reason: 'the owner returned it; no accountant wallet may fall for it');
    expect(ledger.last.correctionId, 'cor-1');
    expect(ledger.last.month, aug, reason: 'same accounting month, always');

    // Revenue falls by the returned cash; the wallet does not move at all.
    expect(await collected(aug), 6000);
    final w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 10000);
    expect(w.cashBalance, 10000);
    expect(w.cashBalance, greaterThanOrEqualTo(0));
    expect((await settles.wallet(acct)).cashBalance, 10000);
    expect(await settles.monthUnsettled(acct, aug), 10000);

    // Paid/unpaid and the invoice are exactly what they were.
    expect(await paidCount(aug), 1);
    expect(await remaining(aug), 0);
    expect(await rawRow('receipts', 'uuid', 'rC'), receiptBefore);

    // ---- recording it TWICE is a no-op ------------------------------------
    expect(await corr.markRefundPaid(stored, paidBy: 'someone-else'), false,
        reason: 'already completed — the transition is refund_due ONLY');
    expect(await recordRefundPaid(stored), false);
    expect((await corr.adjustmentsFor(month: aug, subscriberId: 'C')).length, 2,
        reason: 'no second refund_return may ever be appended');
    expect((await corr.getById('cor-1'))!.refundPaidBy, owner,
        reason: 'the original payer stamp is not overwritten');
    expect(await collected(aug), 6000);
  });

  // ===========================================================================
  // 5. IDEMPOTENCY — a decided correction can never be re-decided.
  // ===========================================================================
  test('idempotency: deciding an already-decided correction returns false and '
      'changes nothing; refund-paid on a non-refund_due row returns false',
      () async {
    await price(aug, 1000);
    await addSub('A', 10);
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05T09:00:00.000Z');

    final c = await request('cor-1', 'A',
        oldAmps: 10, newAmps: 12, receiptUuid: 'rA');

    // A pending row cannot be refund-paid — that transition starts at refund_due.
    expect(await corr.markRefundPaid(c, paidBy: owner), false);
    expect((await corr.getById('cor-1'))!.status, CorrectionStatus.pending);

    // Nor can it be moved to a status that is not a decision.
    expect(await corr.decide(c, CorrectionStatus.completed, decidedBy: owner),
        false, reason: 'completed is reached only by recording the cash return');
    expect((await corr.getById('cor-1'))!.status, CorrectionStatus.pending);

    // ---- first decision applies -------------------------------------------
    expect(await approve(c), true);
    final afterApproval = await rawRow('corrections', 'id', 'cor-1');
    // v44: an increase credits nothing — the customer owes it instead.
    expect(await collected(aug), 10000);
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 10000);
    expect(await remaining(aug), 2000);

    // ---- every later decision is refused, and nothing moves ---------------
    expect(await corr.decide(c, CorrectionStatus.rejected, decidedBy: 'other'),
        false, reason: 'a raced/stale second decision must be a NO-OP');
    expect(await corr.decide(c, CorrectionStatus.approved, decidedBy: 'other'),
        false);
    expect(await approve(c), false, reason: 're-approval writes no second row');
    expect(await corr.markRefundPaid(c, paidBy: 'other'), false,
        reason: 'an approved INCREASE never owes a refund');

    expect(await rawRow('corrections', 'id', 'cor-1'), afterApproval,
        reason: 'status/decided_by/decided_at all survive the refused writes');
    expect((await corr.adjustmentsFor(month: aug)).length, 1,
        reason: 'the wallet can never be credited twice for one correction');
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0,
        reason: 'v44: the ledger row exists but credits no wallet');
    expect(await collected(aug), 10000);
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 10000);
    expect((await settles.wallet(acct)).cashBalance, 10000);
  });

  // ===========================================================================
  // 6. SAME-MONTH ONLY — an August correction never reaches September.
  // ===========================================================================
  test('same-month only: an August correction (increase, decrease and refund) '
      'moves no September figure', () async {
    await price(aug, 1000);
    await price(sep, 1000);
    await addSub('A', 10);
    await addSub('B', 10);
    await addSub('S', 7, from: sep);
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05T09:00:00.000Z');
    await pay('rB', 'B',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05T09:30:00.000Z');
    await pay('rS', 'S',
        cash: 7000,
        amps: 7,
        remaining: 0,
        month: sep,
        issuedAt: '2026-09-04T09:00:00.000Z');

    // September, before anything is corrected in August.
    final sepWalletBefore = await settles.walletForMonth(acct, sep);
    final double sepCollectedBefore = await collected(sep);
    final double sepUnsettledBefore = await settles.monthUnsettled(acct, sep);
    final int sepPaidBefore = await paidCount(sep);
    final double sepRemainingBefore = await remaining(sep);
    final sepReceiptBefore = await rawRow('receipts', 'uuid', 'rS');
    expect(sepCollectedBefore, 7000);
    expect(sepWalletBefore.cashBalance, 7000);

    // ---- August: one INCREASE (+5,000) and one DECREASE (−3,000, refunded) --
    final up =
        await request('cor-up', 'A', oldAmps: 10, newAmps: 15, receiptUuid: 'rA');
    expect(await approve(up), true);
    final down =
        await request('cor-dn', 'B', oldAmps: 10, newAmps: 7, receiptUuid: 'rB');
    expect(await approve(down), true);
    expect(await recordRefundPaid(down), true);

    // August moved exactly as designed.
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0,
        reason: 'v44: neither an increase nor a decrease credits a wallet');
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 20000,
        reason: '20,000 cash + 5,000 increase; the decrease is zeroed');
    expect(await collected(aug), 17000,
        reason: '20,000 cash + 5,000 increase − 3,000 physically returned');

    // ---- SEPTEMBER: byte-for-byte the month it was ------------------------
    expect(await corr.adjustmentTotal(month: sep, accountantId: acct), 0);
    expect(await corr.adjustmentTotal(month: sep), 0);
    expect(await corr.adjustmentsFor(month: sep), isEmpty);
    final sepWalletAfter = await settles.walletForMonth(acct, sep);
    expect(sepWalletAfter.cashCollected, sepWalletBefore.cashCollected);
    expect(sepWalletAfter.cashSettled, sepWalletBefore.cashSettled);
    expect(sepWalletAfter.cashBalance, sepWalletBefore.cashBalance);
    expect(sepWalletAfter.cardCollected, sepWalletBefore.cardCollected);
    expect(sepWalletAfter.cardBalance, sepWalletBefore.cardBalance);
    // The MONEY of the correction never leaves August — that is the isolation
    // this test exists to protect.
    expect(await collected(sep), sepCollectedBefore);
    expect(await settles.monthUnsettled(acct, sep), sepUnsettledBefore);
    expect(await paidCount(sep), sepPaidBefore);
    // v43.1 — September's DUE is the one thing that legitimately moves: the
    // approval applied the corrected amps to the subscriber, and September is
    // AFTER the corrected month, so it now bills the true value. That is the
    // whole point of applying the amps; it is a re-pricing of an open month,
    // not a money leak (no adjustment, receipt, wallet or settlement moved).
    expect(await corr.adjustmentsFor(month: sep), isEmpty,
        reason: 'no adjustment ever lands in another month');
    expect(await remaining(sep), greaterThanOrEqualTo(0));
    expect(await rawRow('receipts', 'uuid', 'rS'), sepReceiptBefore);

    // The corrections themselves are month-scoped in the queue, too.
    expect((await corr.list(month: sep, limit: 10, offset: 0)), isEmpty);
    expect((await corr.list(month: aug, limit: 10, offset: 0)).length, 2);

    // The LIFETIME wallet is the sum of the two months — never more, never
    // less: August's corrected 25,000 plus September's untouched 7,000.
    final life = await settles.wallet(acct);
    expect(life.cashCollected, 27000,
        reason: 'v44: August 20,000 real cash + September 7,000 — no credit');
    expect(life.cashBalance, 27000);
    expect(life.cashBalance, greaterThanOrEqualTo(0));
  });

  // ===========================================================================
  // v43 ADVERSARIAL-REVIEW REGRESSIONS
  // ===========================================================================

  test(
      'a REJECTED correction leaves NO adjustment behind — the guarded status '
      'transition runs before the append-only write', () async {
    await price(aug, 1000);
    await addSub('A', 10);
    await pay('rc1', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05 10:00:00');

    final c = await request('cor-race', 'A',
        oldAmps: 10, newAmps: 15, receiptUuid: 'rc1');

    // The owner REJECTS it on one device…
    expect(await corr.decide(c, CorrectionStatus.rejected, decidedBy: owner),
        true);

    // …while a second device, holding a stale "pending" copy, tries to approve.
    // The guarded transition must lose, and — because the ledger write happens
    // only AFTER that transition succeeds — nothing may be booked. Before the
    // fix the adjustment was appended FIRST and could never be taken back
    // (financial_adjustments has no update/delete path by design), leaving a
    // permanent wallet credit for a correction that was never approved.
    expect(await approve(c), false, reason: 'the stale approval must lose');

    expect(await corr.adjustmentsFor(month: aug), isEmpty,
        reason: 'a rejected correction books nothing at all');
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0);
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 10000,
        reason: 'the wallet is exactly the collected cash — no phantom credit');
    expect((await corr.getById(c.id))!.status, CorrectionStatus.rejected,
        reason: 'the rejection stands');
  });

  test(
      'a SECOND correction for the same subscriber-month is INCREMENTAL — the '
      'first delta is never re-booked', () async {
    await price(aug, 1000);
    await addSub('A', 10);
    await pay('rc1', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05 10:00:00');

    // 10A → 15A: +5,000.
    final first = await request('cor-1', 'A',
        oldAmps: 10, newAmps: 15, receiptUuid: 'rc1');
    expect(await approve(first), true);
    expect(await corr.adjustmentTotal(month: aug, accountantId: acct), 0,
        reason: 'v44: an increase credits no wallet');
    expect(await remaining(aug), 5000, reason: 'the customer owes the +5,000');

    // v43.1: approval APPLIES the corrected amps, so the subscriber itself is
    // now the effective basis and the next correction is naturally incremental.
    final sub = (await subs.getById('A'))!;
    expect(sub.amps, 15, reason: 'the approval moved the subscriber to 15A');
    final double oldDue = sub.amps * 1000;
    final double newDue = 20 * 1000;
    expect(oldDue, 15000, reason: 'the effective basis, not the original');
    expect(newDue - oldDue, 5000, reason: 'strictly the incremental delta');

    final second = await request('cor-2', 'A',
        oldAmps: 15, newAmps: 20, perAmp: 1000, receiptUuid: 'rc1');
    expect(await approve(second), true);

    // Two corrections, 10A → 20A: the month may have moved by exactly 10,000.
    expect(await remaining(aug), 10000,
        reason: 'two corrections, 10A -> 20A: exactly 10,000 owed, never more');
    expect((await corr.adjustmentsFor(month: aug, subscriberId: 'A')).length, 2,
        reason: 'one ledger row per correction — nothing re-booked');
    expect((await subs.getById('A'))!.amps, 20,
        reason: 'and the subscriber ended on the final corrected value');
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 10000,
        reason: 'v44: only the 10,000 actually collected — corrections credit nothing');
  });

  test('the wallet can never be driven negative by a decrease', () async {
    await price(aug, 1000);
    await addSub('A', 10);
    await pay('rc1', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05 10:00:00');

    // A decrease far larger than everything ever collected.
    final c = await request('cor-big', 'A',
        oldAmps: 10, newAmps: 1, receiptUuid: 'rc1');
    expect(await approve(c), true);
    expect((await corr.getById(c.id))!.status, CorrectionStatus.refundDue);

    final w = await settles.walletForMonth(acct, aug);
    expect(w.cashBalance, 10000,
        reason: 'a decrease contributes ZERO to the wallet');
    expect(w.cashBalance, greaterThanOrEqualTo(0));
  });

  test(
      'v43.1: approval CHANGES the subscriber amps, future months bill the new '
      'value, and the corrected month stays frozen on what it was invoiced at',
      () async {
    await price(aug, 1000);
    await price(sep, 1000);
    await addSub('A', 10);

    // August invoiced and fully paid at 10A = 10,000.
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05 10:00:00');
    expect(await remaining(aug), 0, reason: 'August is settled at 10A');
    expect(await paidCount(aug), 1);
    expect(await remaining(sep), 10000, reason: '10A x 1000 before the fix');

    // Meter re-read: really 15A. Correct August and approve.
    final c = await request('cor-amps', 'A',
        oldAmps: 10, newAmps: 15, receiptUuid: 'rA');
    expect(await approve(c), true);

    // 1. THE BUG THIS FIXES: the subscriber's amps actually change.
    expect((await subs.getById('A'))!.amps, 15,
        reason: 'the correction must update the subscriber, not just the money');

    // 2. FUTURE months bill the corrected value.
    expect(await remaining(sep), 15000,
        reason: 'September must now price 15A x 1000');

    // 3. THE CORRECTED MONTH IS FROZEN. August was invoiced at 10A and the
    // +5,000 rides in the adjustment ledger; if the live amps leaked backwards
    // August would re-open as unpaid - silent corruption of closed books.
    // v44: the basis stays 10A (frozen) — the +5,000 is the approved
    // increase, which the customer now OWES for August.
    expect(await remaining(aug), 5000,
        reason: 'the difference is owed for August; the amps basis is frozen');
    expect(await paidCount(aug), 0, reason: 'unpaid again for the difference');
    expect(await unpaidCount(aug), 1);
    // Pay it with an ordinary receipt -> paid, and the cash reaches the wallet.
    await pay('rA-diff', 'A',
        cash: 5000, amps: 15, remaining: 0, issuedAt: '2026-08-06 10:00:00');
    expect(await remaining(aug), 0);
    expect(await paidCount(aug), 1, reason: 'the receipt covers the difference');

    // 4. the original receipt is still untouched.
    final r = await rawRow('receipts', 'uuid', 'rA');
    expect(r['paid_amount'], 10000);
    expect(r['status'], 'valid');
  });

  test('v43.1: a CHAIN of corrections gives every month its own basis',
      () async {
    await price('2026-07', 1000);
    await price(aug, 1000);
    await price(sep, 1000);
    await price('2026-10', 1000);
    await addSub('A', 10, from: '2026-07');

    await pay('r7', 'A',
        cash: 10000, amps: 10, remaining: 0, month: '2026-07',
        issuedAt: '2026-07-05 10:00:00');
    await pay('r8', 'A',
        cash: 10000, amps: 10, remaining: 0, month: aug,
        issuedAt: '2026-08-05 10:00:00');

    // 10 -> 15 corrected in August.
    final c1 = await request('chain-1', 'A',
        oldAmps: 10, newAmps: 15, month: aug, receiptUuid: 'r8');
    expect(await approve(c1), true);

    // 15 -> 20 corrected in September.
    await pay('r9', 'A',
        cash: 15000, amps: 15, remaining: 0, month: sep,
        issuedAt: '2026-09-05 10:00:00');
    final c2 = await request('chain-2', 'A',
        oldAmps: 15, newAmps: 20, month: sep, receiptUuid: 'r9');
    expect(await approve(c2), true);

    expect((await subs.getById('A'))!.amps, 20, reason: 'latest value wins');
    expect(await remaining('2026-07'), 0, reason: 'July frozen at 10A');
    expect(await remaining(aug), 5000,
        reason: 'August: frozen at 10A, plus the owed +5,000 increase');
    expect(await remaining(sep), 5000,
        reason: 'September: frozen at 15A, plus the owed +5,000 increase');
    expect(await remaining('2026-10'), 20000,
        reason: 'October is the first month past every correction -> 20A');
  });

  test('v44: a DECREASE keeps the customer PAID; carrying the credit forward '
      'reduces NEXT month and moves no cash', () async {
    await price(aug, 1000);
    await price(sep, 1000);
    await addSub('A', 10);
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05 10:00:00');
    final walletBefore = (await settles.walletForMonth(acct, aug)).cashBalance;

    // 10A -> 7A: a 3,000 credit.
    final c = await request('cor-cf', 'A',
        oldAmps: 10, newAmps: 7, receiptUuid: 'rA');
    expect(await approve(c), true);
    expect((await corr.getById(c.id))!.status, CorrectionStatus.refundDue);
    expect(await remaining(aug), 0, reason: 'the customer REMAINS paid');
    expect(await paidCount(aug), 1);
    expect((await settles.walletForMonth(acct, aug)).cashBalance, walletBefore,
        reason: 'a credit never moves a wallet');
    expect(await remaining(sep), 7000, reason: '7A x 1000 before carry-forward');

    expect(await carryForward(c), true);
    expect((await corr.getById(c.id))!.status, CorrectionStatus.carriedForward);
    expect(await remaining(sep), 4000,
        reason: 'September due reduced by the 3,000 credit');
    expect(await remaining(aug), 0, reason: 'August untouched');
    expect((await settles.walletForMonth(acct, aug)).cashBalance, walletBefore);
    expect((await settles.walletForMonth(acct, sep)).cashBalance, 0,
        reason: 'no cash moved in September either');
    expect(await carryForward(c), false, reason: 'terminal — cannot re-apply');
    expect(await recordRefundPaid(c), false, reason: 'nor refund a carried credit');
    final rows = await corr.adjustmentsFor(month: sep);
    expect(rows.length, 1);
    expect(rows.first.kind, AdjustmentKind.creditApplied);
    expect(rows.first.amount, 3000);
  });

  test('v44 review: carrying a credit forward keeps EARLIER months frozen — '
      'an unpaid July is not re-priced on the lower amps', () async {
    await price('2026-07', 1000);
    await price(aug, 1000);
    await price(sep, 1000);
    await addSub('A', 10, from: '2026-07');
    // July UNPAID (owes 10,000); August invoiced and paid at 10A.
    await pay('r8', 'A',
        cash: 10000, amps: 10, remaining: 0, month: aug,
        issuedAt: '2026-08-05 10:00:00');
    expect(await remaining('2026-07'), 10000, reason: 'July owed at 10A');

    // 10A -> 7A for August: a 3,000 credit; approval writes amps = 7.
    final c = await request('cor-jul', 'A',
        oldAmps: 10, newAmps: 7, month: aug, receiptUuid: 'r8');
    expect(await approve(c), true);
    expect((await subs.getById('A'))!.amps, 7);
    expect(await remaining('2026-07'), 10000,
        reason: 'refund_due: July still frozen on old_amps 10');

    expect(await carryForward(c), true);
    // THE BUG: carried_forward was missing from the freeze list, so July fell
    // through to the live 7A and 3,000 of receivable silently vanished — on
    // top of the 3,000 credit applied to September (credit granted twice).
    expect(await remaining('2026-07'), 10000,
        reason: 'carried_forward must freeze exactly like completed');
    expect(await remaining(aug), 0, reason: 'August stays paid at 10A');
    expect(await remaining(sep), 4000,
        reason: 'September: 7A x 1000 minus the single 3,000 credit');
  });

  test('v44 review: a same-month chain freezes on the FIRST correction, '
      'regardless of UUID order', () async {
    await price(aug, 1000);
    await addSub('A', 10);
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05 10:00:00');
    // Two corrections in ONE month; ids chosen so the SECOND sorts FIRST.
    final c1 = await request('zzz-first', 'A',
        oldAmps: 10, newAmps: 15, receiptUuid: 'rA');
    expect(await approve(c1), true);
    final c2 = await request('aaa-second', 'A',
        oldAmps: 15, newAmps: 20, receiptUuid: 'rA');
    expect(await approve(c2), true);
    // Correct due: frozen 10A x 1000 + 5,000 + 5,000 = 20,000 -> owes 10,000.
    expect(await remaining(aug), 10000,
        reason: 'basis is the FIRST correction (10A), not the lexically first id');
    await pay('rA-diff', 'A',
        cash: 10000, amps: 20, remaining: 0, issuedAt: '2026-08-06 10:00:00');
    expect(await remaining(aug), 0);
    expect(await paidCount(aug), 1);
  });

  test('v44 review: a double-close race (refund + carry-forward) settles the '
      'credit ONCE — the correction status is the arbiter', () async {
    await price(aug, 1000);
    await price(sep, 1000);
    await addSub('A', 10);
    await pay('rA', 'A',
        cash: 10000, amps: 10, remaining: 0, issuedAt: '2026-08-05 10:00:00');
    final c = await request('cor-race', 'A',
        oldAmps: 10, newAmps: 7, receiptUuid: 'rA');
    expect(await approve(c), true);
    // Device 1 carried it forward (status carried_forward + credit_applied).
    expect(await carryForward(c), true);
    // Device 2, offline, had recorded the cash refund; after sync BOTH ledger
    // rows exist but the status resolved (last-edit-wins) to `completed`.
    await corr.insertAdjustment(FinancialAdjustment(
      id: adjustmentId(c.id, AdjustmentKind.refundReturn),
      correctionId: c.id,
      subscriberId: 'A',
      month: aug,
      branchId: main,
      accountantId: null,
      kind: AdjustmentKind.refundReturn,
      amount: -3000,
      method: 'cash',
      createdBy: owner,
    ));
    final db = await DbHelper().database;
    await db.update('corrections', {'status': CorrectionStatus.completed},
        where: 'id = ?', whereArgs: [c.id]);
    // Only the row matching the FINAL status is in force.
    expect(await remaining(sep), 7000,
        reason: 'credit_applied is NOT in force: the correction is completed');
    expect(await collected(aug), 7000,
        reason: 'the refund_return IS in force: 10,000 - 3,000');
    // ...and the other way round.
    await db.update('corrections', {'status': CorrectionStatus.carriedForward},
        where: 'id = ?', whereArgs: [c.id]);
    expect(await remaining(sep), 4000, reason: 'now the credit is in force');
    expect(await collected(aug), 10000, reason: 'and the refund is not');
  });
}
