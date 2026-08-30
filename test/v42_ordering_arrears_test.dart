import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';

/// v42 — two owner-reported defects, asserted end to end against real SQLite:
///
///  * **item 6** — boards / circuits / subscribers must list oldest → newest and
///    the order must NEVER move. Two production defects made it move: legacy
///    rows with `created_at = NULL` were tie-broken by `rowid`, which is
///    DEVICE-LOCAL and re-assigned in pull-arrival order by every sync pull /
///    delete-local-data / branch switch / reinstall; and the two coexisting
///    timestamp formats (`'YYYY-MM-DD HH:MM:SS'` vs ISO-8601 with a `T`) sorted
///    by FORMAT before they sorted by TIME, because `' ' < 'T'`.
///    [DbHelper.creationOrder] fixes both — display only, nothing rewritten.
///
///  * **item 3** — `SubscriberRepository.previousUnpaidMonths` is the ONLY
///    source of the arrears notice on the subscriber page. It must report the
///    months strictly BEFORE the selected one that the subscriber was already
///    active in and still owes — and it must never leak into the selected
///    month's own accounting.
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

  const branch = DbHelper.kMainBranchId;
  final boards = BoardRepository();
  final circuits = CircuitRepository();
  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();

  // ===========================================================================
  // PART A — item 6: deterministic oldest → newest ordering
  // ===========================================================================

  // The three `created_at` shapes that really coexist in production, listed in
  // REAL creation order — this is the order every device must show:
  //   NULL              pre-v20 rows (no stamp at all)
  //   'YYYY-MM-DD HH:MM:SS'   SQLite CURRENT_TIMESTAMP (space separator)
  //   'YYYY-MM-DDTHH:MM:SS.mmmZ'  Dart ISO-8601 (T separator)
  // The three middle keys are all on the SAME DAY, deliberately interleaving the
  // two formats — that is where the format defect used to reorder rows.
  const creationOrderKeys = <String>[
    'null-a', // NULL — sorts into the epoch bucket, tie-broken by id ASC
    'null-z', // NULL — 'a' < 'z', identical on every device
    'iso-0630', // 2026-01-05 06:30 (ISO)   ← sorted AFTER 08:00 before v42
    'space-0800', // 2026-01-05 08:00 (space)
    'iso-0900', // 2026-01-05 09:00 (ISO)
    'space-feb', // 2026-02-10 07:15 (space)
    'iso-mar', // 2026-03-01 23:59 (ISO)
  ];
  const stamps = <String, String?>{
    'null-a': null,
    'null-z': null,
    'iso-0630': '2026-01-05T06:30:00.000Z',
    'space-0800': '2026-01-05 08:00:00',
    'iso-0900': '2026-01-05T09:00:00.000Z',
    'space-feb': '2026-02-10 07:15:00',
    'iso-mar': '2026-03-01T23:59:59.999Z',
  };

  // Two PHYSICAL insert orders (= two rowid orders), both unrelated to the
  // creation order above. This is exactly what a sync pull does: rows arrive in
  // server order and every one of them gets a brand-new local rowid.
  const arrival1 = <String>[
    'iso-mar',
    'null-z',
    'space-feb',
    'iso-0900',
    'null-a',
    'space-0800',
    'iso-0630',
  ];
  const arrival2 = <String>[
    'space-0800',
    'iso-0630',
    'null-a',
    'iso-mar',
    'null-z',
    'iso-0900',
    'space-feb',
  ];

  // Every circuit hangs off the first board and every subscriber off that same
  // board with its own circuit (one لوحة with many جوزات) — so the board-scoped
  // list queries return the whole fixture and their ordering is asserted too.
  const sharedBoard = 'b-null-a';

  List<String> expected(String prefix) =>
      creationOrderKeys.map((k) => '$prefix$k').toList();

  /// Writes one board + one circuit + one subscriber per timeline entry, in
  /// [arrival] order, all three sharing the entry's `created_at` stamp.
  Future<void> seedTimeline(List<String> arrival) async {
    for (final k in arrival) {
      final at = stamps[k];
      await boards.insert(Board(
          id: 'b-$k', name: 'board $k', branchId: branch, createdAt: at));
      await circuits.insert(Circuit(
          id: 'c-$k',
          boardId: sharedBoard,
          name: 'circuit $k',
          branchId: branch,
          createdAt: at));
      await subs.insert(Subscriber(
          id: 's-$k',
          name: 'sub $k',
          amps: 10,
          boardId: sharedBoard,
          circuitId: 'c-$k',
          branchId: branch,
          createdAt: at));
    }
  }

  Future<List<String>> boardIds() async =>
      (await boards.getAll(limit: 100, branchId: branch))
          .map((e) => e.id)
          .toList();
  Future<List<String>> circuitIds() async =>
      (await circuits.getByBoardId(sharedBoard, branchId: branch))
          .map((e) => e.id)
          .toList();
  Future<List<String>> subscriberIds() async =>
      (await subs.getAll(limit: 100, branchId: branch))
          .map((e) => e.id)
          .toList();

  test('v42 item 6: NULL / space-format / ISO created_at all list oldest → '
      'newest, and same-day rows sort by TIME not by FORMAT', () async {
    await seedTimeline(arrival1);

    // Every list call site of the three entities uses DbHelper.creationOrder.
    expect(await boardIds(), expected('b-'));
    expect(await circuitIds(), expected('c-'));
    expect(await subscriberIds(), expected('s-'));
    expect(
        (await circuits.getAllInBranch(branchId: branch))
            .map((e) => e.id)
            .toList(),
        expected('c-'),
        reason: 'the all-circuits map feeding subscriber rows uses it too');
    expect(
        (await subs.getByBoard(sharedBoard, branchId: branch))
            .map((e) => e.id)
            .toList(),
        expected('s-'),
        reason: 'the board-scoped subscriber list uses it too');

    final b = await boardIds();
    // Defect 1 — legacy NULL rows: they still sort first (nothing is hidden or
    // rewritten), but the tie-break is now the UUID, identical on every device.
    expect(b.take(2).toList(), ['b-null-a', 'b-null-z'],
        reason: 'NULL created_at rows are tie-broken by id, not by rowid');
    // Defect 2 — the two formats on the SAME DAY now compare by real time.
    expect(b.indexOf('b-space-0800') < b.indexOf('b-iso-0900'), isTrue,
        reason: 'the 09:00 ISO row comes AFTER the 08:00 space-format row');
    expect(b.indexOf('b-iso-0630') < b.indexOf('b-space-0800'), isTrue,
        reason: 'the 06:30 ISO row comes BEFORE the 08:00 space-format row — '
            'this is the pair the REPLACE actually fixes');

    // The PRE-v42 ordering, run directly against the same rows, still shows
    // both defects — proof the assertions above are not vacuous.
    final db = await DbHelper().database;
    final naive = (await db.query('boards',
            columns: ['id'], orderBy: 'created_at ASC, rowid ASC'))
        .map((r) => r['id'] as String)
        .toList();
    expect(naive.take(2).toList(), ['b-null-z', 'b-null-a'],
        reason: 'defect 1: NULLs fell back to the device-local rowid, i.e. the '
            'arrival order — b-null-z arrived first here');
    expect(naive.indexOf('b-space-0800') < naive.indexOf('b-iso-0630'), isTrue,
        reason: "defect 2: ' ' < 'T' put the 08:00 legacy row before the 06:30 "
            'ISO row of the same day');

    // Pagination only makes sense on a total order: the pages must concatenate
    // back into the full list with no duplicate and no gap.
    final p1 = await boards.getAll(limit: 3, offset: 0, branchId: branch);
    final p2 = await boards.getAll(limit: 3, offset: 3, branchId: branch);
    final p3 = await boards.getAll(limit: 3, offset: 6, branchId: branch);
    expect([...p1, ...p2, ...p3].map((e) => e.id).toList(), expected('b-'));
  });

  test('v42 item 6: the order is IDENTICAL after a pull re-writes every rowid',
      () async {
    final db = await DbHelper().database;
    Future<List<String>> naiveBoardIds() async => (await db.query('boards',
            columns: ['id'], orderBy: 'created_at ASC, rowid ASC'))
        .map((r) => r['id'] as String)
        .toList();

    await seedTimeline(arrival1);
    final before = (
      boards: await boardIds(),
      circuits: await circuitIds(),
      subscribers: await subscriberIds(),
      naive: await naiveBoardIds(),
    );

    // Simulate the real cycle that used to shuffle the lists: delete-local-data
    // (or a branch switch / reinstall) followed by a pull that re-inserts the
    // very same rows in a DIFFERENT server order — every rowid is reassigned.
    for (final t in ['subscribers', 'circuits', 'boards']) {
      await db.delete(t);
    }
    expect(await boardIds(), isEmpty);
    await seedTimeline(arrival2);

    // The pre-v42 ordering DOES move across that cycle — the owner's "the order
    // is random and changes between views" report, reproduced on demand.
    expect(await naiveBoardIds(), isNot(before.naive),
        reason: 'created_at ASC, rowid ASC follows the arrival order');

    expect(await boardIds(), before.boards,
        reason: 'boards must not move when rowids change');
    expect(await circuitIds(), before.circuits,
        reason: 'circuits (الجوزات) must not move when rowids change');
    expect(await subscriberIds(), before.subscribers,
        reason: 'subscribers must not move when rowids change');
    // …and it is still the creation order, not merely a stable arbitrary one.
    expect(await boardIds(), expected('b-'));
    expect(await circuitIds(), expected('c-'));
    expect(await subscriberIds(), expected('s-'));
  });

  // ===========================================================================
  // PART B — item 3: the previous-outstanding-months notice
  // ===========================================================================

  test('v42 item 3: previousUnpaidMonths reports only PRIOR months the '
      'subscriber was active in and still owes — newest first', () async {
    // Tariff 1,000 IQD/amp for six consecutive months, plus a decoy price in
    // ANOTHER branch to prove the notice never crosses a branch.
    for (final m in [
      '2026-04',
      '2026-05',
      '2026-06',
      '2026-07',
      '2026-08',
      '2026-09'
    ]) {
      await prices.insert(MonthlyPrice(
          month: m,
          pricePerAmp: 1000,
          branchId: branch,
          category: SubscriberCategory.standard));
    }
    await prices.insert(MonthlyPrice(
        month: '2026-06',
        pricePerAmp: 5000,
        branchId: 'br-other',
        category: SubscriberCategory.standard));

    // S1 — v42 row: billing starts 2026-06 (stamped from the tariff month).
    await subs.insert(Subscriber(
        id: 'S1',
        name: 'S1',
        amps: 10, // due = 10,000 / month
        boardId: 'b1',
        circuitId: 'c1',
        category: SubscriberCategory.standard,
        branchId: branch,
        createdAt: '2026-06-01T08:00:00.000Z',
        billingStartMonth: '2026-06'));
    // S2 — LEGACY row: no billing_start_month at all; the COALESCE must fall
    // back to its created_at prefix ('2026-07'), never to "all of history".
    await subs.insert(Subscriber(
        id: 'S2',
        name: 'S2',
        amps: 5, // due = 5,000 / month
        boardId: 'b1',
        circuitId: 'c2',
        category: SubscriberCategory.standard,
        branchId: branch,
        createdAt: '2026-07-03T10:00:00.000Z'));

    // S1 pays JULY in full; June is left untouched.
    await receipts.insertWithAllocatedNumber(
        Receipt(
            uuid: 'r-jul',
            receiptNo: 0,
            subscriberId: 'S1',
            month: '2026-07',
            ampsSnapshot: 10,
            priceSnapshot: 1000,
            paidAmount: 10000,
            remainingAfter: 0,
            accountantId: 'acct-1',
            branchId: branch,
            categorySnapshot: SubscriberCategory.standard,
            issuedAt: '2026-07-04T09:00:00.000Z'),
        branchId: branch);

    // v42 REVIEW FIX — the notice only claims a month this device actually
    // holds receipt data for. `SyncController` pulls receipts MONTH-SCOPED, so
    // on a freshly-pulled device a past month has no local receipts and a naive
    // query would report EVERY earlier month as outstanding for a subscriber
    // who is fully paid up. Before that evidence exists, June is SILENT:
    var early = await subs.previousUnpaidMonths('S1',
        beforeMonth: '2026-08', branchId: branch);
    expect(early, isEmpty,
        reason: 'no local June receipts at all ⇒ no evidence ⇒ no accusation');

    // A THIRD subscriber (S3) pays June and August IN FULL, so this device
    // demonstrably holds those months' receipt data. S3 owes nothing, so it
    // changes no other figure in this test — it only supplies the evidence.
    await subs.insert(Subscriber(
        id: 'S3',
        name: 'S3',
        amps: 1, // due = 1,000 / month
        boardId: 'b1',
        circuitId: 'c3',
        category: SubscriberCategory.standard,
        branchId: branch,
        createdAt: '2026-06-01T08:00:00.000Z',
        billingStartMonth: '2026-06'));
    for (final m in ['2026-06', '2026-08']) {
      await receipts.insertWithAllocatedNumber(
          Receipt(
              uuid: 'r-ev-$m',
              receiptNo: 0,
              subscriberId: 'S3',
              month: m,
              ampsSnapshot: 1,
              priceSnapshot: 1000,
              paidAmount: 1000,
              remainingAfter: 0,
              accountantId: 'acct-1',
              branchId: branch,
              categorySnapshot: SubscriberCategory.standard,
              issuedAt: '$m-20T09:00:00.000Z'),
          branchId: branch);
    }

    // ---- viewing AUGUST: exactly one outstanding earlier month (June) -------
    var arrears = await subs.previousUnpaidMonths('S1',
        beforeMonth: '2026-08', branchId: branch);
    expect(arrears.length, 1);
    expect(arrears.single.month, '2026-06');
    expect(arrears.single.due, 10000,
        reason: 'due uses the subscriber CURRENT amps × that month\'s price — '
            'the other branch\'s 5,000 price row is not its price');
    expect(arrears.single.coverage, 0);
    expect(arrears.single.remaining, 10000);
    final months = arrears.map((a) => a.month).toList();
    expect(months.contains('2026-08'), isFalse,
        reason: 'the SELECTED month is never part of its own arrears notice');
    expect(months.contains('2026-09'), isFalse,
        reason: 'a FUTURE month is never reported as outstanding');
    expect(months.contains('2026-07'), isFalse, reason: 'July is fully paid');
    expect(months.any((m) => m.compareTo('2026-06') < 0), isFalse,
        reason: 'April/May are priced but predate billing_start_month — a '
            'subscriber is never told it owes a month it did not exist in');

    // ---- viewing SEPTEMBER: two outstanding months, NEWEST FIRST -----------
    arrears = await subs.previousUnpaidMonths('S1',
        beforeMonth: '2026-09', branchId: branch);
    expect(arrears.map((a) => a.month).toList(), ['2026-08', '2026-06']);
    expect(arrears.map((a) => a.remaining).toList(), [10000, 10000]);
    // The notice is capped, and the cap keeps the most RECENT months.
    final capped = await subs.previousUnpaidMonths('S1',
        beforeMonth: '2026-09', branchId: branch, limit: 1);
    expect(capped.map((a) => a.month).toList(), ['2026-08']);

    // ---- a PARTIAL payment leaves remaining = due − coverage ---------------
    await receipts.insertWithAllocatedNumber(
        Receipt(
            uuid: 'r-jun-partial',
            receiptNo: 0,
            subscriberId: 'S1',
            month: '2026-06',
            ampsSnapshot: 10,
            priceSnapshot: 1000,
            paidAmount: 4000,
            remainingAfter: 6000,
            accountantId: 'acct-1',
            branchId: branch,
            categorySnapshot: SubscriberCategory.standard,
            issuedAt: '2026-06-10T09:00:00.000Z'),
        branchId: branch);
    arrears = await subs.previousUnpaidMonths('S1',
        beforeMonth: '2026-08', branchId: branch);
    expect(arrears.single.month, '2026-06');
    expect(arrears.single.due, 10000);
    expect(arrears.single.coverage, 4000);
    expect(arrears.single.remaining, 6000);

    // ---- coverage = cash + WAIVED discount, exactly like the paid/unpaid ---
    // derivation, so the notice can never disagree with that month's screen.
    await receipts.insertWithAllocatedNumber(
        Receipt(
            uuid: 'r-jun-rest',
            receiptNo: 0,
            subscriberId: 'S1',
            month: '2026-06',
            ampsSnapshot: 10,
            priceSnapshot: 1000,
            paidAmount: 5000,
            remainingAfter: 0,
            accountantId: 'acct-1',
            branchId: branch,
            categorySnapshot: SubscriberCategory.standard,
            discountType: 'value',
            discountValue: 1000,
            issuedAt: '2026-06-11T09:00:00.000Z'),
        branchId: branch);
    expect(
        await subs.previousUnpaidMonths('S1',
            beforeMonth: '2026-08', branchId: branch),
        isEmpty,
        reason: '4,000 + 5,000 cash + 1,000 waived = the full 10,000 due');
    // Refunding it puts the month straight back — only VALID receipts count.
    await receipts.markRefunded((await receipts.getByUuid('r-jun-rest'))!);
    arrears = await subs.previousUnpaidMonths('S1',
        beforeMonth: '2026-08', branchId: branch);
    expect(arrears.single.month, '2026-06');
    expect(arrears.single.remaining, 6000);

    // ---- the LEGACY subscriber falls back to its created_at prefix ---------
    final legacy = await subs.previousUnpaidMonths('S2',
        beforeMonth: '2026-09', branchId: branch);
    expect(legacy.map((a) => a.month).toList(), ['2026-08', '2026-07'],
        reason: 'S2 has no billing_start_month; created_at 2026-07-03 makes '
            'July its first billed month — June is priced but never charged');
    expect(legacy.map((a) => a.remaining).toList(), [5000, 5000],
        reason: '5 amps × 1,000');

    // ---- and the notice is DISPLAY ONLY: August accounting is untouched ----
    // (previousUnpaidMonths is read by one widget; no aggregate consumes it.)
    expect(await subs.remainingFeesTotal(month: '2026-08', branchId: branch),
        15000,
        reason: 'August owes S1 10,000 + S2 5,000 — the June arrears are NOT '
            'folded into the selected month');
    expect(
        await subs.countByPaymentStatus(
            month: '2026-08', isPaid: false, branchId: branch),
        2);
    expect(
        await subs.countByPaymentStatus(
            month: '2026-08', isPaid: true, branchId: branch),
        1,
        reason: 'only the evidence subscriber S3 paid August in full');
  });
}
