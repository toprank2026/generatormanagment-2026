import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/expense_model.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';
import 'package:generatormanagment/data/repositories/branch_repository.dart';

/// Proves the Multi-Branch full-isolation contract at the repository layer:
///   * reads scoped to a branch see ONLY that branch's rows; consolidated
///     (branchId == null) sees all branches;
///   * receipt numbering is independent per branch (D-3);
///   * monthly pricing is independent per branch (D-4);
///   * deleting a branch cascades only its own data;
///   * branch + accountant scopes compose (receipts).
/// Plus a v4 -> v5 migration test: legacy rows are mapped into the Main Branch
/// and monthly_prices is reshaped to the synthetic per-branch primary key.
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

  const bMain = DbHelper.kMainBranchId; // 'main'
  const bTwo = 'branch-2';
  const month = '2026-06';

  final boards = BoardRepository();
  final circuits = CircuitRepository();
  final subs = SubscriberRepository();
  final prices = MonthlyPriceRepository();
  final receipts = ReceiptRepository();
  final expenses = ExpenseRepository();

  Subscriber sub(String id, String branch, {double amps = 10}) => Subscriber(
        id: id,
        name: 'Sub $id',
        amps: amps,
        boardId: 'bd-$branch',
        circuitId: 'ci-$branch',
        branchId: branch,
      );

  Receipt rec(String uuid, int no, String subId, String branch, double paid) =>
      Receipt(
        uuid: uuid,
        receiptNo: no,
        subscriberId: subId,
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 1000,
        paidAmount: paid,
        remainingAfter: 0,
        branchId: branch,
        issuedAt: '$month-10T00:00:00.000Z',
      );

  group('branch read scoping', () {
    setUp(() async {
      await boards.insert(Board(id: 'bd-$bMain', name: 'Main BD', branchId: bMain));
      await boards.insert(Board(id: 'bd-$bTwo', name: 'Two BD', branchId: bTwo));
      await circuits.insert(
          Circuit(id: 'ci-$bMain', boardId: 'bd-$bMain', name: 'Main CI', branchId: bMain));
      await circuits.insert(
          Circuit(id: 'ci-$bTwo', boardId: 'bd-$bTwo', name: 'Two CI', branchId: bTwo));
      await subs.insert(sub('s1', bMain));
      await subs.insert(sub('s2', bTwo, amps: 15));
      await receipts.insert(rec('r1', 1, 's1', bMain, 10000)); // main, fully paid
      await receipts.insert(rec('r2', 1, 's2', bTwo, 5000)); // branch-2, underpaid
      await expenses.addExpense(Expense(
          id: 'e1', category: 'fuel', amount: 3000, date: '$month-05', branchId: bMain));
      await expenses.addExpense(Expense(
          id: 'e2', category: 'oil', amount: 1000, date: '$month-06', branchId: bTwo));
    });

    test('boards: each branch sees only its own; consolidated sees all', () async {
      expect((await boards.getAll(branchId: bMain)).map((b) => b.id), ['bd-$bMain']);
      expect((await boards.getAll(branchId: bTwo)).map((b) => b.id), ['bd-$bTwo']);
      expect((await boards.getAll()).length, 2); // consolidated
    });

    test('circuits: scoped by branch', () async {
      expect(
          (await circuits.getByBoardId('bd-$bMain', branchId: bMain)).map((c) => c.id),
          ['ci-$bMain']);
      // Asking for branch-2's circuits under the main board yields nothing.
      expect(
          (await circuits.getByBoardId('bd-$bMain', branchId: bTwo)).isEmpty, true);
    });

    test('subscribers: scoped vs consolidated', () async {
      expect((await subs.getAll(branchId: bMain)).map((s) => s.id), ['s1']);
      expect((await subs.getAll(branchId: bTwo)).map((s) => s.id), ['s2']);
      expect((await subs.getAll()).length, 2);
    });

    test('collected sum is per-branch; consolidated is the total', () async {
      expect(await receipts.getCollectedSum(month, branchId: bMain), 10000);
      expect(await receipts.getCollectedSum(month, branchId: bTwo), 5000);
      expect(await receipts.getCollectedSum(month), 15000);
    });

    test('expenses total is per-branch; consolidated is the total', () async {
      expect(await expenses.getTotalExpenses(month, branchId: bMain), 3000);
      expect(await expenses.getTotalExpenses(month, branchId: bTwo), 1000);
      expect(await expenses.getTotalExpenses(month), 4000);
    });

    test('paid/unpaid counts respect the branch scope', () async {
      // price 1000: s1 (amps10, due 10000, paid 10000) PAID in main;
      //             s2 (amps15, due 15000, paid 5000)  UNPAID in branch-2.
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: true, branchId: bMain),
          1);
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: false, branchId: bMain),
          0);
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: true, branchId: bTwo),
          0);
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: false, branchId: bTwo),
          1);
    });
  });

  group('cross-branch receipt leak (regression)', () {
    // A shared subscriber id can carry receipts stamped under more than one
    // branch (e.g. a payment collected from the consolidated view). The due /
    // paid reads MUST count only the queried branch's receipts.
    test('getBySubscriberAndMonth is scoped to the branch', () async {
      await receipts.insert(rec('rm', 1, 'm1', bMain, 4000));
      await receipts.insert(rec('rt', 1, 'm1', bTwo, 8000)); // same subscriber id

      final mainOnly = await receipts.getBySubscriberAndMonth('m1', month, branchId: bMain);
      expect(mainOnly.map((r) => r.uuid), ['rm']);
      final twoOnly = await receipts.getBySubscriberAndMonth('m1', month, branchId: bTwo);
      expect(twoOnly.map((r) => r.uuid), ['rt']);
      // Consolidated (no branch) sees both.
      final both = await receipts.getBySubscriberAndMonth('m1', month);
      expect(both.length, 2);
    });

    test('paid/unpaid count does not leak another branch\'s payment', () async {
      // m1 in main: amps 10, price 1000 -> due 10000. Main receipt 4000 (unpaid
      // in main). A stray branch-2 receipt of 8000 must NOT push m1 to "paid".
      await subs.insert(sub('m1', bMain, amps: 10));
      await receipts.insert(rec('rm', 1, 'm1', bMain, 4000));
      await receipts.insert(rec('rt', 1, 'm1', bTwo, 8000));

      // Unscoped sum would be 12000 >= 10000 (wrongly PAID); branch-scoped is
      // 4000 < 10000 (correctly UNPAID).
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: true, branchId: bMain),
          0);
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: false, branchId: bMain),
          1);
    });
  });

  group('per-branch receipt numbering (D-3)', () {
    test('each branch keeps its own 1..N sequence', () async {
      expect(await receipts.getNextReceiptNumber(branchId: bMain), 1);
      await receipts.insert(rec('r1', 1, 's1', bMain, 100));
      await receipts.insert(rec('r2', 2, 's1', bMain, 100));
      // branch-2 is still empty -> starts at 1, independent of main's 2 rows.
      expect(await receipts.getNextReceiptNumber(branchId: bTwo), 1);
      await receipts.insert(rec('r3', 1, 's2', bTwo, 100));
      expect(await receipts.getNextReceiptNumber(branchId: bMain), 3);
      expect(await receipts.getNextReceiptNumber(branchId: bTwo), 2);
    });
  });

  group('per-branch monthly price (D-4)', () {
    test('same month, different price per branch (synthetic id)', () async {
      await prices.insert(MonthlyPrice(month: month, pricePerAmp: 1500, branchId: bMain));
      await prices.insert(MonthlyPrice(month: month, pricePerAmp: 2000, branchId: bTwo));

      expect((await prices.getByMonth(month, branchId: bMain))!.pricePerAmp, 1500);
      expect((await prices.getByMonth(month, branchId: bTwo))!.pricePerAmp, 2000);
      // Synthetic PK keeps both rows distinct (no clash on the month).
      expect(MonthlyPrice(month: month, pricePerAmp: 0, branchId: bMain).id,
          '$month|$bMain');
    });
  });

  group('branch delete cascade', () {
    test('deleting a branch removes only its own data', () async {
      final branchRepo = BranchRepository();
      await branchRepo.ensureMain();
      await branchRepo.create(id: bTwo, name: 'Branch Two');
      await boards.insert(Board(id: 'bd-$bMain', name: 'Main BD', branchId: bMain));
      await boards.insert(Board(id: 'bd-$bTwo', name: 'Two BD', branchId: bTwo));
      await subs.insert(sub('s1', bMain));
      await subs.insert(sub('s2', bTwo));
      await receipts.insert(rec('r2', 1, 's2', bTwo, 5000));

      await branchRepo.delete(bTwo);

      // branch-2 data gone; main data intact.
      expect((await boards.getAll()).map((b) => b.id), ['bd-$bMain']);
      expect((await subs.getAll()).map((s) => s.id), ['s1']);
      expect(await receipts.getCollectedSum(month), 0);
      expect((await branchRepo.getAll()).map((b) => b.id), [bMain]);
    });

    test('the Main Branch cannot be deleted', () async {
      final branchRepo = BranchRepository();
      await branchRepo.ensureMain();
      await branchRepo.delete(bMain);
      expect((await branchRepo.getById(bMain)) != null, true);
    });
  });

  group('branch + accountant scopes compose (receipts)', () {
    test('collected sum can be filtered by branch AND accountant', () async {
      // Two accountants both collect inside the Main Branch.
      await receipts.insert(Receipt(
          uuid: 'a', receiptNo: 1, subscriberId: 's1', month: month,
          ampsSnapshot: 10, priceSnapshot: 1000, paidAmount: 7000,
          remainingAfter: 0, branchId: bMain, accountantId: 'acc-1',
          issuedAt: '$month-10T00:00:00.000Z'));
      await receipts.insert(Receipt(
          uuid: 'b', receiptNo: 2, subscriberId: 's1', month: month,
          ampsSnapshot: 10, priceSnapshot: 1000, paidAmount: 3000,
          remainingAfter: 0, branchId: bMain, accountantId: 'acc-2',
          issuedAt: '$month-10T00:00:00.000Z'));
      // A receipt in another branch by acc-1 must NOT count for the Main scope.
      await receipts.insert(Receipt(
          uuid: 'c', receiptNo: 1, subscriberId: 's2', month: month,
          ampsSnapshot: 10, priceSnapshot: 1000, paidAmount: 9000,
          remainingAfter: 0, branchId: bTwo, accountantId: 'acc-1',
          issuedAt: '$month-10T00:00:00.000Z'));

      expect(await receipts.getCollectedSum(month, branchId: bMain), 10000);
      expect(
          await receipts.getCollectedSum(month,
              branchId: bMain, accountantId: 'acc-1'),
          7000);
      expect(
          await receipts.getCollectedSum(month,
              branchId: bMain, accountantId: 'acc-2'),
          3000);
      // acc-1 across all branches = 7000 (main) + 9000 (branch-2).
      expect(await receipts.getCollectedSum(month, accountantId: 'acc-1'), 16000);
    });
  });

  group('v4 -> v5 migration (legacy backfill + price reshape)', () {
    test('legacy rows map into Main Branch; prices get synthetic ids', () async {
      // 1) Build a pre-v5 (version 4) database on disk with the OLD schema:
      //    no branch_id columns, monthly_prices keyed by month.
      final dir = await Directory.systemTemp.createTemp('br_mig_');
      final path = '${dir.path}/v4.db';

      final v4 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
          onCreate: (db, v) async {
            await db.execute('''CREATE TABLE boards (
              id TEXT PRIMARY KEY, name TEXT, code TEXT,
              accountant_id TEXT, created_at TEXT)''');
            await db.execute('''CREATE TABLE circuits (
              id TEXT PRIMARY KEY, board_id TEXT, name TEXT, phase TEXT,
              accountant_id TEXT, created_at TEXT)''');
            await db.execute('''CREATE TABLE subscribers (
              id TEXT PRIMARY KEY, name TEXT, phone TEXT, amps REAL,
              board_id TEXT, circuit_id TEXT, status TEXT,
              accountant_id TEXT, created_at TEXT)''');
            await db.execute('''CREATE TABLE monthly_prices (
              month TEXT PRIMARY KEY, price_per_amp REAL, locked INTEGER,
              created_at TEXT)''');
            await db.execute('''CREATE TABLE receipts (
              uuid TEXT PRIMARY KEY, receipt_no INTEGER, subscriber_id TEXT,
              month TEXT, amps_snapshot REAL, price_snapshot REAL,
              paid_amount REAL, remaining_after REAL, accountant_id TEXT,
              performed_by_user_id TEXT, issued_at TEXT, status TEXT,
              qr_token TEXT, created_at TEXT)''');
            await db.execute('''CREATE TABLE refunds (
              uuid TEXT PRIMARY KEY, receipt_uuid TEXT, amount REAL,
              created_at TEXT)''');
            await db.execute('''CREATE TABLE expenses (
              id TEXT PRIMARY KEY, category TEXT, amount REAL, note TEXT,
              date TEXT, created_by_user_id TEXT, accountant_id TEXT,
              created_at TEXT)''');
            await db.execute('''CREATE TABLE accountants (
              id TEXT PRIMARY KEY, username TEXT, name TEXT, active INTEGER,
              permissions TEXT, created_at TEXT)''');
          },
        ),
      );
      // Legacy data (no branch_id; price keyed by month).
      await v4.insert('boards', {'id': 'b1', 'name': 'Legacy Board'});
      await v4.insert('subscribers', {
        'id': 's1', 'name': 'Legacy Sub', 'amps': 12,
        'board_id': 'b1', 'circuit_id': 'c1', 'status': 'active',
      });
      await v4.insert('monthly_prices',
          {'month': month, 'price_per_amp': 1500, 'locked': 0});
      await v4.close();

      // 2) Reopen through DbHelper at version 5 -> runs the REAL _onUpgrade.
      DbHelper.testPath = path;
      final db = await DbHelper().database;

      // 3a) Legacy rows are mapped into the Main Branch.
      final b = await db.query('boards', where: 'id = ?', whereArgs: ['b1']);
      expect(b.first['branch_id'], bMain);
      final s = await db.query('subscribers', where: 'id = ?', whereArgs: ['s1']);
      expect(s.first['branch_id'], bMain);

      // 3b) monthly_prices reshaped to the synthetic per-branch primary key.
      final mp = await db.query('monthly_prices');
      expect(mp.length, 1);
      expect(mp.first['id'], '$month|$bMain');
      expect(mp.first['branch_id'], bMain);
      expect(mp.first['price_per_amp'], 1500);

      // 3c) The branches table now exists; ensureMain seeds the Main Branch row.
      await BranchRepository().ensureMain();
      final branchRows = await db.query('branches');
      expect(branchRows.any((r) => r['id'] == bMain), true);

      // Close the connection before removing the temp file (Windows lock).
      await DbHelper.resetForTest();
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // Best-effort cleanup; the OS temp dir is reclaimed regardless.
      }
    });
  });
}
