import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';

/// v42 item 5 — SUBSCRIBER MONTH ONBOARDING.
///
/// A subscriber is part of a month's billing ONLY from the accounting month it
/// was added onwards. Before v42 every subscriber row belonged to every month,
/// so five subscribers entered in month 9 showed up as UNPAID in month 8 (and
/// in every earlier month), corrupting the whole historical picture.
///
/// This suite proves the new predicate on the LIVE-data guarantees that make it
/// safe to ship — the point is as much "nothing existing vanished" as "the new
/// row is excluded":
///   • a month-9 subscriber is absent from month 8 (paid AND unpaid) and
///     present in month 9;
///   • it inflates neither remainingFeesTotal nor ampsByPaymentStatusCategory;
///   • a LEGACY row (billing_start_month NULL) falls back to its `created_at`
///     prefix — in BOTH stored timestamp formats;
///   • a row with NO timestamp at all is ALWAYS included (the '0000-00' floor);
///   • THE SAFETY VALVE: a subscriber holding a valid receipt in a month stays
///     visible in that month whatever its start stamp says;
///   • the activation arg is appended LAST, so `category`/`query`/
///     `receiptAccountantId` filters keep their positional-arg order.
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
  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();

  /// [createdAt] and [billingStartMonth] are BOTH nullable on purpose — the
  /// legacy shapes this feature has to keep working are exactly the rows where
  /// one or both are absent.
  Subscriber sub(
    String id, {
    required String board,
    double amps = 10,
    String? createdAt,
    String? billingStartMonth,
  }) =>
      Subscriber(
        id: id,
        name: id,
        amps: amps,
        boardId: board,
        circuitId: 'c-$id',
        category: SubscriberCategory.standard,
        branchId: main,
        createdAt: createdAt,
        billingStartMonth: billingStartMonth,
      );

  Receipt pay(
    String uuid,
    String subId, {
    required double cash,
    required String payMonth,
    required String issuedAt,
    double amps = 10,
  }) =>
      Receipt(
        uuid: uuid,
        receiptNo: 0,
        subscriberId: subId,
        month: payMonth,
        ampsSnapshot: amps,
        priceSnapshot: 1000,
        paidAmount: cash,
        remainingAfter: (amps * 1000) - cash,
        accountantId: acct,
        branchId: main,
        categorySnapshot: SubscriberCategory.standard,
        issuedAt: issuedAt,
        paymentMethod: 'cash',
      );

  Future<Set<String>> idsOf(String month, {required bool isPaid}) async =>
      (await subs.getByPaymentStatus(
              month: month, isPaid: isPaid, branchId: main))
          .map((s) => s.id)
          .toSet();

  test(
      'v42 item 5: a month-9 subscriber is invisible in month 8, and every '
      'legacy shape survives untouched', () async {
    // Same tariff in both months so any difference is the activation rule
    // alone, never a pricing difference.
    for (final m in [aug, sep]) {
      await prices.insert(MonthlyPrice(
          month: m,
          pricePerAmp: 1000,
          branchId: main,
          category: SubscriberCategory.standard));
    }

    // ---- THE ROSTER — one row per shape the predicate has to handle --------
    // 1. THE REGRESSION ITSELF: entered while browsing September's bills (v40
    //    future-month billing), so the tariff stamp is 2026-09 even though the
    //    wall clock said August. It must NOT exist for August.
    await subs.insert(sub('s-future',
        board: 'b-1',
        createdAt: '2026-08-20 09:00:00',
        billingStartMonth: sep));
    // 2. LEGACY row, OLD SQLite format ('YYYY-MM-DD HH:MM:SS' from
    //    CURRENT_TIMESTAMP) and no stamp — must fall back to created_at.
    await subs.insert(
        sub('s-legacy-space', board: 'b-1', createdAt: '2026-07-15 10:00:00'));
    // 3. LEGACY row, Dart ISO-8601 format — REPLACE(...,'T',' ') must make it
    //    behave identically to #2.
    await subs.insert(sub('s-legacy-iso',
        board: 'b-2', createdAt: '2026-07-15T10:00:00.000Z'));
    // 4. NO timestamp at all — the '0000-00' floor: always included, so no
    //    undated production row can silently disappear.
    await subs.insert(sub('s-nostamp', board: 'b-2'));
    // 5. THE SAFETY VALVE: stamped for September, but it already holds a valid
    //    August receipt. An existing record can never be orphaned.
    await subs.insert(sub('s-valve',
        board: 'b-2',
        createdAt: '2026-08-20 09:00:00',
        billingStartMonth: sep));
    await receipts.insertWithAllocatedNumber(
        pay('r-valve', 's-valve',
            cash: 10000, payMonth: aug, issuedAt: '2026-08-21T09:00:00.000Z'),
        branchId: main);

    // ---- AUGUST: the future subscriber is simply not there -----------------
    expect(await idsOf(aug, isPaid: false),
        {'s-legacy-space', 's-legacy-iso', 's-nostamp'},
        reason: 's-future belongs to September; the three legacy shapes stay');
    expect(await idsOf(aug, isPaid: true), {'s-valve'},
        reason: 'the safety valve keeps a receipted subscriber visible');
    expect(
        await subs.countByPaymentStatus(
            month: aug, isPaid: false, branchId: main),
        3,
        reason: 'was 4 before v42 — s-future was a phantom August debtor');
    expect(
        await subs.countByPaymentStatus(
            month: aug, isPaid: true, branchId: main),
        1);
    expect(await subs.paidSubscriberIds(month: aug, branchId: main),
        {'s-valve'},
        reason: 'the list dot uses the same choke point');

    // ---- AUGUST money figures are NOT inflated -----------------------------
    expect(await subs.remainingFeesTotal(month: aug, branchId: main), 30000,
        reason: '3 unpaid × 10A × 1,000 — NOT 40,000 with s-future added');
    expect(
        (await subs.ampsByPaymentStatusCategory(
            month: aug, isPaid: false, branchId: main))['standard'],
        30,
        reason: 'unpaid amps exclude the not-yet-active subscriber');
    expect(
        (await subs.ampsByPaymentStatusCategory(
            month: aug, isPaid: true, branchId: main))['standard'],
        10,
        reason: 'the valve subscriber still contributes its paid amps');

    // ---- SEPTEMBER: everybody is billable, nothing is lost -----------------
    expect(await idsOf(sep, isPaid: false), {
      's-future',
      's-legacy-space',
      's-legacy-iso',
      's-nostamp',
      's-valve',
    }, reason: 's-future is billed from its OWN month onwards');
    expect(await idsOf(sep, isPaid: true), isEmpty,
        reason: "the valve receipt is August's — it never leaks into September");
    expect(await subs.remainingFeesTotal(month: sep, branchId: main), 50000);

    // ---- BOARD GRID (parallel SQL, its own arg order) ----------------------
    final boardsAug = await subs.paymentCountsByBoard(month: aug, branchId: main);
    expect(boardsAug['b-1']?.unpaid, 1,
        reason: 'b-1 holds s-future + s-legacy-space; only the legacy one counts');
    expect(boardsAug['b-1']?.paid, 0);
    expect(boardsAug['b-2']?.paid, 1, reason: 's-valve');
    expect(boardsAug['b-2']?.unpaid, 2,
        reason: 's-legacy-iso + s-nostamp');
    final boardsSep = await subs.paymentCountsByBoard(month: sep, branchId: main);
    expect(boardsSep['b-1']?.unpaid, 2, reason: 'September has both b-1 rows');
    expect(boardsSep['b-2']?.unpaid, 3);

    // ---- notYetActiveIds — the neutral-dot source --------------------------
    expect(await subs.notYetActiveIds(month: aug, branchId: main), {'s-future'},
        reason: 's-valve is NOT reported inactive: it has an August receipt');
    expect(await subs.notYetActiveIds(month: sep, branchId: main), isEmpty,
        reason: 'in its own month nothing is pending activation');

    // ---- Dashboard aggregates: optional month scope, all-time unchanged ----
    expect(await subs.countByBranch(branchId: main), 5,
        reason: 'NO month ⇒ byte-identical all-time behaviour (back-compat)');
    expect((await subs.ampsByCategory(branchId: main))['standard'], 50);
    // v42 review fix: the simple aggregates carry the SAME receipts safety valve
    // as the derived paid/unpaid queries (an EXISTS sub-query). 's-valve' is
    // September-stamped but HAS an August receipt, so August counts it — its
    // cash is in `collected`, so its due must be in `expected`, and
    // `paid + unpaid` can never exceed `totalSubscribers` on one dashboard.
    // Only 's-future' (September-stamped, no receipt) is excluded.
    expect(await subs.countByBranch(branchId: main, month: aug), 4,
        reason: 'the receipted September row stays counted in August (safety '
            'valve) — consistent with getByPaymentStatus/countByPaymentStatus');
    expect((await subs.ampsByCategory(branchId: main, month: aug))['standard'],
        40);
    expect(await subs.countByBranch(branchId: main, month: sep), 5);
    expect((await subs.ampsByCategory(branchId: main, month: sep))['standard'],
        50);

    // ---- POSITIONAL-ARG ORDER (risk register): the activation arg is
    // appended LAST, so every optional filter before it must still bind to its
    // own `?`. A drift here would silently return the wrong rows, not throw.
    expect(
        (await subs.getByPaymentStatus(
                month: aug,
                isPaid: false,
                branchId: main,
                category: SubscriberCategory.standard,
                query: 'space'))
            .map((s) => s.id)
            .toSet(),
        {'s-legacy-space'},
        reason: 'category + query + activation args stay in `?` order');
    expect(
        await subs.getByPaymentStatus(
            month: aug,
            isPaid: false,
            branchId: main,
            category: SubscriberCategory.gold),
        isEmpty,
        reason: 'the category filter still filters (nobody is gold)');
    // receiptAccountantId scopes the INNER receipts sub-query (args BEFORE the
    // outer ones): with the collecting accountant the valve is paid…
    expect(
        await subs.countByPaymentStatus(
            month: aug,
            isPaid: true,
            branchId: main,
            receiptAccountantId: acct),
        1);
    // …and with a different collector its receipt is out of scope, so the
    // valve closes and the September stamp excludes it again.
    expect(
        await subs.countByPaymentStatus(
            month: aug,
            isPaid: true,
            branchId: main,
            receiptAccountantId: 'other-acct'),
        0);
    expect(
        await subs.countByPaymentStatus(
            month: aug,
            isPaid: false,
            branchId: main,
            receiptAccountantId: 'other-acct'),
        3,
        reason: 's-valve is not silently re-added as an unpaid August debtor');

    // ---- THE REGRESSION WITNESS -------------------------------------------
    // The PRE-v42 unpaid derivation, frozen here verbatim minus the activation
    // clause, replayed against the very same fixture. It returns 4 — s-future
    // as a phantom August debtor. This is what production was reporting, and it
    // is what makes every assertion above non-vacuous: the 3 vs 4 gap is the
    // predicate, not the fixture.
    final db = await DbHelper().database;
    final legacy = await db.rawQuery("""
      SELECT COUNT(*) AS c
      FROM subscribers s
      LEFT JOIN (
        SELECT subscriber_id,
               SUM(paid_amount) as total_paid,
               SUM(IFNULL(discount_value, 0)) as total_discount
        FROM receipts
        WHERE month = ? AND status = 'valid' AND branch_id = ?
        GROUP BY subscriber_id
      ) r ON s.id = r.subscriber_id
      LEFT JOIN monthly_prices mp
        ON mp.month = ?
        AND mp.category = IFNULL(s.category, 'standard')
        AND IFNULL(mp.branch_id, '$main') = IFNULL(s.branch_id, '$main')
      WHERE (mp.price_per_amp IS NULL
             OR (COALESCE(r.total_paid, 0) + COALESCE(r.total_discount, 0))
                < (s.amps * mp.price_per_amp))
        AND s.branch_id = ?
    """, [aug, main, aug, main]);
    expect(legacy.first['c'], 4,
        reason: 'the defect reproduces without the activation predicate');
  });

  test(
      'v42 item 5: the two stored created_at formats normalise identically, '
      'including across the month boundary', () async {
    for (final m in [aug, sep]) {
      await prices.insert(MonthlyPrice(
          month: m,
          pricePerAmp: 1000,
          branchId: main,
          category: SubscriberCategory.standard));
    }

    // The SAME instant written in the two formats that coexist in production
    // ('YYYY-MM-DD HH:MM:SS' from SQLite CURRENT_TIMESTAMP vs Dart ISO-8601).
    // substr(REPLACE(created_at,'T',' '),1,7) must yield '2026-08' for both.
    await subs.insert(
        sub('s-space-aug', board: 'b', createdAt: '2026-08-31 21:00:00'));
    await subs.insert(
        sub('s-iso-aug', board: 'b', createdAt: '2026-08-31T21:00:00.000Z'));
    // One day later — the other side of the boundary, again in both formats.
    await subs.insert(
        sub('s-space-sep', board: 'b', createdAt: '2026-09-01 08:00:00'));
    await subs.insert(
        sub('s-iso-sep', board: 'b', createdAt: '2026-09-01T08:00:00.000Z'));

    expect(await idsOf(aug, isPaid: false), {'s-space-aug', 's-iso-aug'},
        reason: 'the format must not decide membership — only the month does');
    expect(await idsOf(sep, isPaid: false),
        {'s-space-aug', 's-iso-aug', 's-space-sep', 's-iso-sep'},
        reason: 'August rows keep being billed in September (start month, not '
            'a single month)');
    expect(await subs.remainingFeesTotal(month: aug, branchId: main), 20000);
    expect(await subs.remainingFeesTotal(month: sep, branchId: main), 40000);
    expect(await subs.notYetActiveIds(month: aug, branchId: main),
        {'s-space-sep', 's-iso-sep'});
    expect(await subs.countByBranch(branchId: main, month: aug), 2);
  });
}
