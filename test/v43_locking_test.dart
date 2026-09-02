import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v43 — THE MONTH LOCK (spec §3.3), asserted at the REPOSITORY choke point.
///
/// Lock state is **DERIVED, never stored**. No column is added to `subscribers`,
/// `receipts`, `monthly_prices` or `settlements`: `SyncService.pull` writes with
/// `ConflictAlgorithm.replace` (INSERT OR REPLACE = delete + insert), so a lock
/// column an older device did not know about would be reset ACCOUNT-WIDE on
/// every device's next pull. These tests therefore assert the two predicates
/// themselves, recomputed from the receipts and settlements:
///
///   * invoice-locked(subscriber, month) ⇔ a VALID receipt exists for
///     (subscriber_id, month)                    → `ReceiptRepository.hasValidReceipt`
///   * settlement-locked(month)          ⇔ a `pending|approved` settlement whose
///     bucket `COALESCE(month, substr(requested_at,1,7))` equals the month
///                                               → `SettlementRepository.monthHasActiveSettlement`
///   * price-locked(month)               ⇔ the month already carries a valid
///     receipt, and only a price CHANGE is refused
///                                               → `MonthlyPriceInvoiceLock`
///
/// and the Golden Rule that governs all three:
///
/// > **A correction for one billing month must never alter or financially
/// > affect another month.** Locking August leaves September fully editable.
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

  const jul = '2026-07';
  const aug = '2026-08';
  const sep = '2026-09';
  const mainBr = DbHelper.kMainBranchId;
  const otherBr = 'branch-2';
  const acct = 'acct-1';

  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();
  final settles = SettlementRepository();

  Subscriber sub(String id, {String branchId = mainBr, double amps = 10}) =>
      Subscriber(
        id: id,
        name: 'sub-$id',
        phone: '0770000000',
        amps: amps,
        boardId: 'b1',
        circuitId: 'c-$id',
        category: SubscriberCategory.standard,
        branchId: branchId,
        billingStartMonth: aug,
      );

  Receipt rc(
    String uuid,
    String subId,
    String month, {
    String status = 'valid',
    String branchId = mainBr,
    double cash = 10000,
  }) =>
      Receipt(
        uuid: uuid,
        receiptNo: 0,
        subscriberId: subId,
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 1000,
        paidAmount: cash,
        remainingAfter: 0,
        accountantId: acct,
        branchId: branchId,
        categorySnapshot: SubscriberCategory.standard,
        status: status,
        paymentMethod: 'cash',
        issuedAt: '$month-05T10:00:00.000Z',
      );

  Settlement st(
    String id,
    String status,
    String requestedAt, {
    String? month,
    double amount = 5000,
    String accountantId = acct,
    String branchId = mainBr,
  }) =>
      Settlement(
        id: id,
        accountantId: accountantId,
        branchId: branchId,
        amount: amount,
        method: 'cash',
        status: status,
        month: month, // null = a legacy, pre-v40 row (no tariff stamp)
        requestedAt: requestedAt,
      );

  MonthlyPrice price(
    String month,
    double perAmp, {
    String branchId = mainBr,
    String category = SubscriberCategory.standard,
  }) =>
      MonthlyPrice(
        month: month,
        pricePerAmp: perAmp,
        branchId: branchId,
        category: category,
      );

  /// Runs [write] and returns the [ValidationException] it refused with, or
  /// null when the write was ALLOWED. Keeps every "refused / allowed" assertion
  /// below symmetrical and lets us check the key AND its arg.
  Future<ValidationException?> refusal(Future<void> Function() write) async {
    try {
      await write();
      return null;
    } on ValidationException catch (e) {
      return e;
    }
  }

  Future<double?> storedPrice(String month,
          {String branchId = mainBr,
          String category = SubscriberCategory.standard}) async =>
      (await prices.getByMonth(month, branchId: branchId, category: category))
          ?.pricePerAmp;

  // ---------------------------------------------------------------------------
  // 1. THE INVOICE LOCK — per (subscriber, month), derived from valid receipts.
  // ---------------------------------------------------------------------------
  test('hasValidReceipt locks ONLY the invoiced (subscriber, month) — another '
      'month, another subscriber and a REVERSED receipt are all unlocked',
      () async {
    await subs.insert(sub('S1'));
    await subs.insert(sub('S2'));

    // Nothing invoiced yet: no subscriber-month is locked.
    expect(await receipts.hasValidReceipt('S1', aug), false);
    expect(await receipts.hasValidReceipt('S2', aug), false);

    // S1 is invoiced for AUGUST only.
    await receipts.insertWithAllocatedNumber(rc('r-s1-aug', 'S1', aug),
        branchId: mainBr);

    expect(await receipts.hasValidReceipt('S1', aug), true,
        reason: 'the invoiced subscriber-month is locked');
    expect(await receipts.hasValidReceipt('S1', sep), false,
        reason: 'AUGUST invoicing must never lock SEPTEMBER for the same '
            'subscriber — the Golden Rule');
    expect(await receipts.hasValidReceipt('S1', jul), false,
        reason: '…nor a month BEFORE the invoiced one');
    expect(await receipts.hasValidReceipt('S2', aug), false,
        reason: 'the lock is per SUBSCRIBER-month, not per month: an unbilled '
            'neighbour in the same month stays freely editable');

    // A REFUNDED receipt does not lock: the reversal already unwound that
    // month's cash and restored the subscriber to unpaid, so the billing basis
    // is editable in place again (status = 'valid' is the same filter every
    // other money query in the file uses).
    await receipts.insertWithAllocatedNumber(
        rc('r-s2-aug-void', 'S2', aug, status: 'refunded'),
        branchId: mainBr);
    expect(await receipts.hasValidReceipt('S2', aug), false,
        reason: 'a refunded receipt is not an invoice');

    // …and reversing the live August receipt UNLOCKS S1's August again.
    final live = rc('r-s1-aug', 'S1', aug);
    live.receiptNo = 1;
    await receipts.markRefunded(live, reason: 'test_reversal');
    expect(await receipts.hasValidReceipt('S1', aug), false,
        reason: 'reversal releases the lock, exactly as it releases paid state');
  });

  test('hasValidReceipt is branch-scopable — a receipt in one branch does not '
      'lock the same subscriber-month in another', () async {
    await subs.insert(sub('S1'));
    await receipts.insertWithAllocatedNumber(rc('r-main', 'S1', aug),
        branchId: mainBr);

    expect(await receipts.hasValidReceipt('S1', aug), true,
        reason: 'no branch filter = the STRICTEST reading (any branch locks), '
            'so a legacy NULL-branch receipt still protects the month');
    expect(await receipts.hasValidReceipt('S1', aug, branchId: mainBr), true);
    expect(await receipts.hasValidReceipt('S1', aug, branchId: otherBr), false,
        reason: 'branches are fully isolated: the other branch never invoiced '
            'this subscriber-month');
  });

  // ---------------------------------------------------------------------------
  // 2. THE SETTLEMENT LOCK — per month, bucketed by the v40 tariff-month
  //    expression COALESCE(month, substr(requested_at,1,7)).
  // ---------------------------------------------------------------------------
  test('monthHasActiveSettlement: pending and approved lock, rejected does not',
      () async {
    expect(await settles.monthHasActiveSettlement(aug), false,
        reason: 'a month with no settlement at all is open');

    // PENDING — the money is already claimed by an open request.
    await settles.insert(
        st('st-aug', 'pending', '2026-08-20T09:00:00.000Z', month: aug));
    expect(await settles.monthHasActiveSettlement(aug), true);
    expect(await settles.monthHasActiveSettlement(sep), false,
        reason: 'AUGUST settling must never lock SEPTEMBER');

    // APPROVED — the cash has been handed over; the month is closed.
    await settles.insert(
        st('st-sep', 'approved', '2026-09-20T09:00:00.000Z', month: sep));
    expect(await settles.monthHasActiveSettlement(sep), true);

    // REJECTED — the owner declined, the money never left the wallet, so the
    // month is NOT locked (same reversal rule as lastActiveRequestAt).
    await settles.insert(
        st('st-jul', 'rejected', '2026-07-20T09:00:00.000Z', month: jul));
    expect(await settles.monthHasActiveSettlement(jul), false,
        reason: 'a rejected request holds no money and locks nothing');

    // Defensive: an empty month is never a lock (the guard short-circuits).
    expect(await settles.monthHasActiveSettlement(''), false);
  });

  test('monthHasActiveSettlement buckets by the TARIFF month — a legacy '
      'month-NULL row falls back to its requested_at prefix', () async {
    // Written before v40 stamped the tariff month: month IS NULL, so the v40
    // back-compat rule must bucket it by substr(requested_at,1,7) = JULY.
    // Nothing stored is reinterpreted.
    await settles.insert(st('st-legacy', 'pending', '2026-07-18T09:00:00.000Z'));
    expect(await settles.monthHasActiveSettlement(jul), true,
        reason: 'legacy row buckets by requested_at — its previous meaning');
    expect(await settles.monthHasActiveSettlement(aug), false,
        reason: 'a July legacy row must not leak into August');

    // v40 future-month billing: a row REQUESTED on July 29 but STAMPED for the
    // AUGUST tariff belongs to August. The stamp wins over the timestamp, and
    // the legacy neighbour above keeps its own bucketing.
    await settles.insert(st('st-stamped', 'approved',
        '2026-07-29T09:00:00.000Z',
        month: aug));
    expect(await settles.monthHasActiveSettlement(aug), true,
        reason: 'the stamped tariff month is the accounting bucket');
    expect(await settles.monthHasActiveSettlement(jul), true,
        reason: 'July is still locked by its OWN legacy row, not by this one');
    expect(await settles.monthHasActiveSettlement(sep), false);
  });

  test('monthHasActiveSettlement narrows by accountant and branch, and the '
      'default is the strictest reading', () async {
    await settles.insert(st('st-other', 'pending', '2026-09-10T09:00:00.000Z',
        month: sep, accountantId: 'acct-2', branchId: otherBr));

    expect(await settles.monthHasActiveSettlement(sep), true,
        reason: 'unfiltered = ANY accountant, ANY branch locks the month');
    expect(
        await settles.monthHasActiveSettlement(sep, accountantId: 'acct-2'),
        true);
    expect(await settles.monthHasActiveSettlement(sep, accountantId: acct),
        false,
        reason: 'another accountant\'s request is not this one\'s lock');
    expect(await settles.monthHasActiveSettlement(sep, branchId: otherBr), true);
    expect(await settles.monthHasActiveSettlement(sep, branchId: mainBr), false,
        reason: 'branch isolation holds for the settlement lock too');
  });

  // ---------------------------------------------------------------------------
  // 3. THE PRICE LOCK — a tariff edit silently re-prices EVERY subscriber in
  //    the month, so only a CHANGE in an invoiced month is refused.
  // ---------------------------------------------------------------------------
  test('a price CHANGE in an INVOICED month is refused with '
      'price_locked_invoiced; creating and re-writing stay allowed', () async {
    await subs.insert(sub('S1'));

    // Before any invoice, pricing behaves byte-identically to today.
    expect(await prices.monthHasAnyReceipt(aug, branchId: mainBr), false);
    expect(await refusal(() => prices.insertGuarded(price(aug, 1000))), isNull);
    expect(await refusal(() => prices.insertGuarded(price(aug, 1200))), isNull,
        reason: 'an un-invoiced month is fully re-priceable');
    expect(await storedPrice(aug), 1200);

    // The first valid receipt closes August's tariff.
    await receipts.insertWithAllocatedNumber(rc('r-s1-aug', 'S1', aug),
        branchId: mainBr);
    expect(await prices.monthHasAnyReceipt(aug, branchId: mainBr), true);

    final refused = await refusal(() => prices.insertGuarded(price(aug, 1500)));
    expect(refused, isNotNull, reason: 'the invoiced tariff must not change');
    expect(refused!.messageKey, 'price_locked_invoiced');
    expect(refused.arg, aug, reason: 'the message names the locked month');
    expect(await storedPrice(aug), 1200,
        reason: 'the refusal left the stored tariff untouched — no partial write');

    // Re-writing the SAME value is NOT a change and stays allowed. This is
    // load-bearing: BillingController.setPrices re-writes all three categories
    // on every save, and a start_date-only edit is metadata, not money.
    expect(await refusal(() => prices.insertGuarded(price(aug, 1200))), isNull,
        reason: 'an identical re-write is not a price change');
    expect(await storedPrice(aug), 1200);

    // Creating a NEW row in the invoiced month is allowed: pricing a category
    // that had no tariff only ADDS a due — it never re-prices an issued invoice.
    expect(
        await refusal(() => prices.insertGuarded(
            price(aug, 3000, category: SubscriberCategory.gold))),
        isNull,
        reason: 'a first-time category price is a creation, not a change');
    expect(await storedPrice(aug, category: SubscriberCategory.gold), 3000);
    // …but CHANGING that new row afterwards is locked like every other.
    final goldRefused = await refusal(() => prices
        .insertGuarded(price(aug, 3500, category: SubscriberCategory.gold)));
    expect(goldRefused?.messageKey, 'price_locked_invoiced');
    expect(await storedPrice(aug, category: SubscriberCategory.gold), 3000);

    // Another BRANCH's August tariff is independent — a main-branch receipt
    // does not close branch-2's books.
    expect(await prices.monthHasAnyReceipt(aug, branchId: otherBr), false);
    expect(
        await refusal(
            () => prices.insertGuarded(price(aug, 900, branchId: otherBr))),
        isNull);
    expect(
        await refusal(
            () => prices.insertGuarded(price(aug, 1100, branchId: otherBr))),
        isNull,
        reason: 'branch-2 has no invoice for August, so its tariff is open');
    expect(await storedPrice(aug, branchId: otherBr), 1100);

    // Reversing the only August receipt re-opens the month (status = 'valid').
    final live = rc('r-s1-aug', 'S1', aug);
    live.receiptNo = 1;
    await receipts.markRefunded(live, reason: 'test_reversal');
    expect(await prices.monthHasAnyReceipt(aug, branchId: mainBr), false);
    expect(await refusal(() => prices.insertGuarded(price(aug, 1500))), isNull,
        reason: 'the reversal unwound the month, so the tariff is editable');
    expect(await storedPrice(aug), 1500);
  });

  test('the unguarded insert stays unguarded — the sync-pull and restore paths '
      'must never be blocked by an app-layer lock', () async {
    await subs.insert(sub('S1'));
    await prices.insert(price(aug, 1000));
    await receipts.insertWithAllocatedNumber(rc('r-s1-aug', 'S1', aug),
        branchId: mainBr);

    // insertGuarded refuses…
    expect((await refusal(() => prices.insertGuarded(price(aug, 1500))))
        ?.messageKey,
        'price_locked_invoiced');
    // …while the raw insert (used by SyncService.pull / backup restore) writes
    // the server's row unconditionally. Blocking it would wedge the pull for
    // the whole account — the documented v40 freeze class.
    expect(await refusal(() => prices.insert(price(aug, 1500))), isNull);
    expect(await storedPrice(aug), 1500);
  });

  // ---------------------------------------------------------------------------
  // 4. THE GOLDEN RULE — ONE MONTH NEVER AFFECTS ANOTHER.
  // ---------------------------------------------------------------------------
  test('locking AUGUST (invoiced + settled) leaves SEPTEMBER fully editable, '
      'and September closing later never re-opens or re-prices August',
      () async {
    await subs.insert(sub('S1'));
    await subs.insert(sub('S2'));
    await prices.insertGuarded(price(aug, 1000));
    await prices.insertGuarded(price(sep, 1000));

    // AUGUST closes: S1 is invoiced and the month's cash is under an approved
    // settlement stamped to the August tariff.
    await receipts.insertWithAllocatedNumber(rc('r-s1-aug', 'S1', aug),
        branchId: mainBr);
    await settles.insert(
        st('st-aug', 'approved', '2026-08-25T09:00:00.000Z', month: aug));

    // Every August predicate is locked…
    expect(await receipts.hasValidReceipt('S1', aug), true);
    expect(await settles.monthHasActiveSettlement(aug), true);
    expect(
        (await refusal(() => prices.insertGuarded(price(aug, 1600))))
            ?.messageKey,
        'price_locked_invoiced');

    // …and every SEPTEMBER predicate is still open. This is the whole rule.
    expect(await receipts.hasValidReceipt('S1', sep), false);
    expect(await settles.monthHasActiveSettlement(sep), false);
    expect(await prices.monthHasAnyReceipt(sep, branchId: mainBr), false);
    expect(await refusal(() => prices.insertGuarded(price(sep, 1750))), isNull,
        reason: 'September is un-invoiced, so its tariff is freely editable');
    expect(await storedPrice(sep), 1750);
    expect(await storedPrice(aug), 1000,
        reason: 're-pricing September must not touch the August tariff');

    // An August settlement does NOT invoice-lock an unbilled subscriber: the
    // settlement lock is per MONTH, the invoice lock is per SUBSCRIBER-month.
    expect(await receipts.hasValidReceipt('S2', aug), false,
        reason: 'S2 was never invoiced in August');

    // SEPTEMBER now closes too. August must not move a millimetre.
    await receipts.insertWithAllocatedNumber(rc('r-s1-sep', 'S1', sep),
        branchId: mainBr);
    await settles.insert(
        st('st-sep', 'pending', '2026-09-25T09:00:00.000Z', month: sep));

    expect(await receipts.hasValidReceipt('S1', sep), true);
    expect(await settles.monthHasActiveSettlement(sep), true);
    expect(
        (await refusal(() => prices.insertGuarded(price(sep, 1900))))
            ?.messageKey,
        'price_locked_invoiced');
    expect(await storedPrice(sep), 1750, reason: 'September tariff frozen as-is');

    // August: unchanged in every respect — still locked, still 1000.
    expect(await receipts.hasValidReceipt('S1', aug), true);
    expect(await settles.monthHasActiveSettlement(aug), true);
    expect(await storedPrice(aug), 1000);

    // Reversing SEPTEMBER's receipt re-opens September ONLY.
    final sepReceipt = rc('r-s1-sep', 'S1', sep);
    sepReceipt.receiptNo = 2;
    await receipts.markRefunded(sepReceipt, reason: 'test_reversal');
    expect(await receipts.hasValidReceipt('S1', sep), false);
    expect(await receipts.hasValidReceipt('S1', aug), true,
        reason: 'a September reversal never unlocks August');
    expect(await prices.monthHasAnyReceipt(aug, branchId: mainBr), true);
  });

  test('name and phone are NEVER billing-relevant — editing them in a locked '
      'month leaves the invoice, the lock and the tariff untouched', () async {
    await subs.insert(sub('S1', amps: 10));
    await prices.insertGuarded(price(aug, 1000));
    await receipts.insertWithAllocatedNumber(rc('r-s1-aug', 'S1', aug),
        branchId: mainBr);
    expect(await receipts.hasValidReceipt('S1', aug), true);

    // The guard in CoreController.updateSubscriber fires only when a
    // BILLING-RELEVANT field changed (amps / category / branch). A name+phone
    // edit is none of those, so the repository write goes through exactly as
    // before — and the money picture is byte-identical afterwards.
    final edited = (await subs.getById('S1'))!;
    edited.name = 'renamed';
    edited.phone = '07711112222';
    await subs.update(edited);

    final after = (await subs.getById('S1'))!;
    expect(after.name, 'renamed');
    expect(after.phone, '07711112222');
    expect(after.amps, 10, reason: 'the billing basis was not touched');
    expect(after.category, SubscriberCategory.standard);
    expect(after.branchId, mainBr);

    // The invoice, the lock and the tariff are all exactly where they were.
    expect(await receipts.hasValidReceipt('S1', aug), true);
    final invoices =
        await receipts.getBySubscriberAndMonth('S1', aug, branchId: mainBr);
    expect(invoices.length, 1);
    expect(invoices.first.ampsSnapshot, 10);
    expect(invoices.first.priceSnapshot, 1000);
    expect(invoices.first.paidAmount, 10000);
    expect(invoices.first.status, 'valid');
    expect(await storedPrice(aug), 1000);
  });
}
