import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v42 item 1 — the accountant wallet is ISOLATED PER ACCOUNTING MONTH.
///
/// `walletForMonth(accountant, month)` buckets BOTH sides to one tariff month:
/// collected by `receipts.month`, settled by
/// `COALESCE(settlements.month, substr(requested_at,1,7))` (the v40 rule, so a
/// LEGACY unstamped row keeps its exact previous behaviour). `hasPending` gains
/// the same optional month scope, so a still-pending August request can no
/// longer block September's settlement — while omitting the month keeps the old
/// all-time guard, and `wallet()` keeps its lifetime semantics untouched.
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
  final settles = SettlementRepository();
  final receipts = ReceiptRepository();

  Settlement st(String id, String status, String requestedAt,
          {double amount = 1000,
          String method = 'cash',
          String? month,
          String accountantId = acct}) =>
      Settlement(
        id: id,
        accountantId: accountantId,
        branchId: main,
        amount: amount,
        method: method,
        status: status,
        month: month, // null = a legacy, pre-v40 row (no tariff stamp)
        requestedAt: requestedAt,
      );

  Receipt rc(String uuid,
          {required double cash,
          required String month,
          String status = 'valid',
          String method = 'cash',
          String accountantId = acct}) =>
      Receipt(
        uuid: uuid,
        receiptNo: 0,
        subscriberId: 'S',
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 1000,
        paidAmount: cash,
        remainingAfter: 0,
        accountantId: accountantId,
        branchId: main,
        categorySnapshot: SubscriberCategory.standard,
        status: status,
        paymentMethod: method,
        issuedAt: '$month-05T10:00:00.000Z',
      );

  /// The shared money picture for every test below:
  ///   AUGUST    — 10,000 cash + 4,000 card received by acct-1
  ///   SEPTEMBER —  7,000 cash + 2,000 card received by acct-1
  /// plus two rows that must NEVER reach acct-1's wallet: a refunded August
  /// receipt and an August receipt collected by a second accountant.
  Future<void> seedMoney() async {
    await receipts.insertWithAllocatedNumber(
        rc('r-aug-cash', cash: 10000, month: aug),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r-aug-card', cash: 4000, month: aug, method: 'card'),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r-aug-void', cash: 3000, month: aug, status: 'refunded'),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r-aug-other', cash: 5000, month: aug, accountantId: 'acct-2'),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r-sep-cash', cash: 7000, month: sep),
        branchId: main);
    await receipts.insertWithAllocatedNumber(
        rc('r-sep-card', cash: 2000, month: sep, method: 'card'),
        branchId: main);
  }

  test('walletForMonth sees ONLY its own month (cash + card), wallet() stays '
      'all-time', () async {
    await seedMoney();

    // AUGUST — the refunded row and the other accountant's row are excluded,
    // exactly as in the all-time wallet.
    var w = await settles.walletForMonth(acct, aug);
    expect(w.cashCollected, 10000, reason: 'September money must not carry in');
    expect(w.cardCollected, 4000);
    expect(w.cashSettled, 0);
    expect(w.cardSettled, 0);
    expect(w.cashBalance, 10000);
    expect(w.cardBalance, 4000);

    // SEPTEMBER — its own money only; August is not accumulated.
    w = await settles.walletForMonth(acct, sep);
    expect(w.cashCollected, 7000);
    expect(w.cardCollected, 2000);
    expect(w.cashBalance, 7000);
    expect(w.cardBalance, 2000);

    // A month with no records is a clean zero wallet — never a carried-over
    // balance (the defect this item removes: the cards never reset).
    w = await settles.walletForMonth(acct, '2026-07');
    expect(w.cashCollected, 0);
    expect(w.cardCollected, 0);
    expect(w.cashBalance, 0);
    expect(w.cardBalance, 0);

    // wallet() (all-time) is deliberately KEPT alongside — same shape, the
    // lifetime figure = the sum of both months.
    final all = await settles.wallet(acct);
    expect(all.cashCollected, 17000, reason: '10,000 Aug + 7,000 Sep');
    expect(all.cardCollected, 6000, reason: '4,000 Aug + 2,000 Sep');
    expect(all.cashBalance, 17000);
    expect(all.cardBalance, 6000);
  });

  test('an APPROVED month-stamped settlement reduces ONLY that month',
      () async {
    await seedMoney();

    // August cash settlement request, stamped with the AUGUST tariff month.
    final req = st('st-aug', 'pending', '2026-08-20T09:00:00.000Z',
        amount: 6000, month: aug);
    await settles.insert(req);
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 10000,
        reason: 'a PENDING request has not moved any money yet');

    expect(await settles.decide(req, 'approved', decidedBy: 'owner'), true);
    var w = await settles.walletForMonth(acct, aug);
    expect(w.cashSettled, 6000);
    expect(w.cashBalance, 4000, reason: '10,000 received − 6,000 settled');
    expect(w.cardSettled, 0,
        reason: 'a cash settlement never touches the card wallet');
    expect(w.cardBalance, 4000);

    // SEPTEMBER is untouched — the whole point of the isolation.
    w = await settles.walletForMonth(acct, sep);
    expect(w.cashSettled, 0);
    expect(w.cashBalance, 7000);
    expect(w.cardBalance, 2000);

    // The all-time wallet still nets the settlement across the lifetime.
    final all = await settles.wallet(acct);
    expect(all.cashSettled, 6000);
    expect(all.cashBalance, 11000, reason: '17,000 received − 6,000 settled');

    // A REJECTED September request settles nothing (the money never left).
    final rej = st('st-sep', 'pending', '2026-09-20T09:00:00.000Z',
        amount: 7000, month: sep);
    await settles.insert(rej);
    expect(await settles.decide(rej, 'rejected', decidedBy: 'owner'), true);
    w = await settles.walletForMonth(acct, sep);
    expect(w.cashSettled, 0);
    expect(w.cashBalance, 7000, reason: 'rejection leaves the balance intact');
    // …and August did not move either.
    expect((await settles.walletForMonth(acct, aug)).cashBalance, 4000);

    // A CARD settlement stamped August drains only the August card wallet.
    final card = st('st-aug-card', 'pending', '2026-08-22T09:00:00.000Z',
        amount: 4000, method: 'card', month: aug);
    await settles.insert(card);
    expect(await settles.decide(card, 'approved', decidedBy: 'owner'), true);
    w = await settles.walletForMonth(acct, aug);
    expect(w.cardSettled, 4000);
    expect(w.cardBalance, 0);
    expect(w.cashBalance, 4000, reason: 'the cash side is unaffected');
    expect((await settles.walletForMonth(acct, sep)).cardBalance, 2000);
  });

  test('a LEGACY settlement (month NULL) still buckets by its requested_at '
      'prefix', () async {
    await seedMoney();

    // Written before v40 stamped the tariff month: month IS NULL, so the v40
    // back-compat rule must bucket it by substr(requested_at,1,7) = August.
    await settles.insert(st('st-legacy-aug', 'approved',
        '2026-08-25T09:00:00.000Z',
        amount: 2500));
    var w = await settles.walletForMonth(acct, aug);
    expect(w.cashSettled, 2500,
        reason: 'legacy row falls back to requested_at — never reinterpreted');
    expect(w.cashBalance, 7500);
    expect((await settles.walletForMonth(acct, sep)).cashSettled, 0,
        reason: 'an August legacy row must not leak into September');

    // A second legacy row, requested in September, lands in September only.
    await settles.insert(st('st-legacy-sep', 'approved',
        '2026-09-03T09:00:00.000Z',
        amount: 1000));
    expect((await settles.walletForMonth(acct, sep)).cashSettled, 1000);
    expect((await settles.walletForMonth(acct, aug)).cashSettled, 2500,
        reason: 'unchanged by its September neighbour');

    // MIXED DB (v40 future-month billing): a STAMPED row requested on July 29
    // for the August tariff books into AUGUST — the stamp wins over the
    // timestamp, and the legacy neighbour above keeps its own bucketing.
    await settles.insert(st('st-stamped', 'approved',
        '2026-07-29T09:00:00.000Z',
        amount: 500, month: aug));
    w = await settles.walletForMonth(acct, aug);
    expect(w.cashSettled, 3000, reason: '2,500 legacy + 500 stamped');
    expect(w.cashBalance, 7000);
    expect((await settles.walletForMonth(acct, '2026-07')).cashSettled, 0,
        reason: 'July gets no credit for money stamped to August');
  });

  test('hasPending is per MONTH; omitting the month keeps the all-time guard',
      () async {
    await seedMoney();

    // One outstanding AUGUST cash request.
    final augReq = st('st-aug-pending', 'pending', '2026-08-20T09:00:00.000Z',
        amount: 10000, month: aug);
    await settles.insert(augReq);
    expect(await settles.hasPending(acct, 'cash', month: aug), true,
        reason: 'August is guarded against a duplicate request');
    expect(await settles.hasPending(acct, 'cash', month: sep), false,
        reason: 'v42: a pending August request no longer blocks SEPTEMBER — '
            'each accounting month settles independently');
    expect(await settles.hasPending(acct, 'card', month: aug), false,
        reason: 'the guard stays per-method');
    expect(await settles.hasPending(acct, 'cash'), true,
        reason: 'no month → the previous ALL-TIME guard, unchanged');

    // Another accountant's pending August request never guards acct-1.
    expect(
        await settles.hasPending('acct-2', 'cash', month: aug), false);

    // Deciding the request clears both the month guard and the all-time one.
    expect(await settles.decide(augReq, 'approved', decidedBy: 'owner'), true);
    expect(await settles.hasPending(acct, 'cash', month: aug), false);
    expect(await settles.hasPending(acct, 'cash'), false);

    // v42 REVIEW FIX — a LEGACY pending row (month NULL, pre-v40) blocks in
    // EVERY month, not just the one its requested_at happens to fall in.
    // An unstamped request has no reliable accounting month, so a month-only
    // guard would stop seeing it the moment the accountant browsed to another
    // month, letting them file a SECOND request while the owner still had the
    // first — a duplicate the pre-v42 all-time guard used to prevent.
    await settles.insert(st('st-legacy-pending', 'pending',
        '2026-09-18T09:00:00.000Z',
        amount: 7000));
    expect(await settles.hasPending(acct, 'cash', month: sep), true);
    expect(await settles.hasPending(acct, 'cash', month: aug), true,
        reason: 'an unstamped pending request blocks every month until decided');
    expect(await settles.hasPending(acct, 'cash'), true);

    // Once it is decided, every month is free again — the block is not sticky.
    final legacy = (await settles.history(acct, limit: 50, offset: 0))
        .firstWhere((x) => x.id == 'st-legacy-pending');
    expect(await settles.decide(legacy, 'rejected', decidedBy: 'owner'), true);
    expect(await settles.hasPending(acct, 'cash', month: aug), false);
    expect(await settles.hasPending(acct, 'cash', month: sep), false);
  });

  // ---------------------------------------------------------------------------
  // v42 REVIEW FIX — the double-payout hole the per-month wallet would otherwise
  // open, and the lifetime cap that closes it.
  //
  // A settlement is an AMOUNT, not a link to specific receipts. So a settlement
  // bucketed to July (a LEGACY row keyed on requested_at, or a v40 row stamped
  // to a different tariff month) can have paid out cash that was COLLECTED in
  // August. August's month wallet then reads `collected − 0` and would offer
  // that already-handed-over cash as a fresh balance — the same money settled
  // twice.
  //
  // The month figure is still what the owner sees (the requirement), but the
  // REQUEST is capped at the LIFETIME unsettled balance
  // (Σ all collected − Σ all approved settlements), which is conserved. This
  // asserts the arithmetic the controller's cap relies on.
  // ---------------------------------------------------------------------------
  test('v42: a settlement bucketed to another month cannot be paid twice — '
      'the month figure over-states, the lifetime balance does not', () async {
    // 10,000 collected in AUGUST only.
    await receipts.insert(rc('r-aug', cash: 10000, month: aug));

    // It was settled by an APPROVED request that buckets to JULY: a legacy row
    // (month NULL) requested on 2026-07-30 — exactly the shape a pre-v40
    // production account carries.
    await settles.insert(st('st-july-legacy', 'approved',
        '2026-07-30T10:00:00.000Z',
        amount: 10000));

    // The MONTH view honestly reports August's own two sides…
    final wAug = await settles.walletForMonth(acct, aug);
    expect(wAug.cashCollected, 10000);
    expect(wAug.cashSettled, 0,
        reason: 'the settlement buckets to July, not August');
    expect(wAug.cashBalance, 10000,
        reason: 'the month figure ALONE would re-offer already-settled cash');

    // …while the LIFETIME balance knows the money is gone. This is the ceiling
    // SettlementController.requestSettlement caps every request at, so the
    // effective requestable amount is min(month, lifetime) = 0.
    final life = await settles.wallet(acct);
    expect(life.cashCollected, 10000);
    expect(life.cashSettled, 10000);
    expect(life.cashBalance, 0,
        reason: 'nothing is still in hand — the cap must block the request');

    final double requestable =
        wAug.cashBalance < life.cashBalance ? wAug.cashBalance : life.cashBalance;
    expect(requestable, 0, reason: 'min(month, lifetime) blocks the double payout');

    // And the cap is a no-op in the normal case: fresh September money is fully
    // requestable because the lifetime balance rises with it.
    await receipts.insert(rc('r-sep', cash: 4000, month: sep));
    final wSep = await settles.walletForMonth(acct, sep);
    final life2 = await settles.wallet(acct);
    expect(wSep.cashBalance, 4000);
    expect(life2.cashBalance, 4000);
    final double requestable2 =
        wSep.cashBalance < life2.cashBalance ? wSep.cashBalance : life2.cashBalance;
    expect(requestable2, 4000,
        reason: 'the cap never blocks genuinely unsettled money');
  });
}
