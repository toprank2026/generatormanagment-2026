import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/expense_model.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';

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
  });

  // ---- helpers ---------------------------------------------------------

  const uuid = Uuid();

  Board makeBoard({required String id, String? name}) =>
      Board(id: id, name: name ?? 'Board $id');

  Circuit makeCircuit({
    required String id,
    required String boardId,
    String? name,
  }) => Circuit(id: id, boardId: boardId, name: name ?? 'Circuit $id');

  Subscriber makeSubscriber({
    required String id,
    required String boardId,
    required String circuitId,
    double amps = 10,
    String? name,
  }) => Subscriber(
    id: id,
    name: name ?? 'Sub $id',
    amps: amps,
    boardId: boardId,
    circuitId: circuitId,
  );

  Receipt makeReceipt({
    String? uuidStr,
    required int receiptNo,
    required String subscriberId,
    String month = '2026-06',
    double ampsSnapshot = 10,
    double priceSnapshot = 5,
    double paidAmount = 50,
    double remainingAfter = 0,
    String status = 'valid',
  }) => Receipt(
    uuid: uuidStr ?? uuid.v4(),
    receiptNo: receiptNo,
    subscriberId: subscriberId,
    month: month,
    ampsSnapshot: ampsSnapshot,
    priceSnapshot: priceSnapshot,
    paidAmount: paidAmount,
    remainingAfter: remainingAfter,
    issuedAt: '2026-06-01T00:00:00.000',
    status: status,
  );

  Future<int> countRows(String table, String where, List<Object?> args) async {
    final db = await DbHelper().database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM $table WHERE $where', args),
        ) ??
        -1;
  }

  // ---- CASCADE DELETE --------------------------------------------------

  group('Cascade delete', () {
    test('BoardRepository.delete removes circuits, subscribers, receipts',
        () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      final subRepo = SubscriberRepository();
      final receiptRepo = ReceiptRepository();

      await boardRepo.insert(makeBoard(id: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c1', boardId: 'b1'));
      await subRepo.insert(
        makeSubscriber(id: 's1', boardId: 'b1', circuitId: 'c1'),
      );
      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r1', receiptNo: 1, subscriberId: 's1'),
      );

      // A sibling board must remain untouched.
      await boardRepo.insert(makeBoard(id: 'b2'));
      await circuitRepo.insert(makeCircuit(id: 'c2', boardId: 'b2'));
      await subRepo.insert(
        makeSubscriber(id: 's2', boardId: 'b2', circuitId: 'c2'),
      );
      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r2', receiptNo: 2, subscriberId: 's2'),
      );

      await boardRepo.delete('b1');

      expect(await countRows('boards', 'id = ?', ['b1']), 0);
      expect(await countRows('circuits', 'board_id = ?', ['b1']), 0);
      expect(await countRows('subscribers', 'board_id = ?', ['b1']), 0);
      expect(await countRows('receipts', 'subscriber_id = ?', ['s1']), 0);

      // Sibling board intact.
      expect(await countRows('boards', 'id = ?', ['b2']), 1);
      expect(await countRows('circuits', 'board_id = ?', ['b2']), 1);
      expect(await countRows('subscribers', 'board_id = ?', ['b2']), 1);
      expect(await countRows('receipts', 'subscriber_id = ?', ['s2']), 1);
    });

    test('CircuitRepository.delete removes subscribers and their receipts',
        () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      final subRepo = SubscriberRepository();
      final receiptRepo = ReceiptRepository();

      await boardRepo.insert(makeBoard(id: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c1', boardId: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c2', boardId: 'b1'));
      await subRepo.insert(
        makeSubscriber(id: 's1', boardId: 'b1', circuitId: 'c1'),
      );
      await subRepo.insert(
        makeSubscriber(id: 's2', boardId: 'b1', circuitId: 'c2'),
      );
      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r1', receiptNo: 1, subscriberId: 's1'),
      );
      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r2', receiptNo: 2, subscriberId: 's2'),
      );

      await circuitRepo.delete('c1');

      expect(await countRows('circuits', 'id = ?', ['c1']), 0);
      expect(await countRows('subscribers', 'circuit_id = ?', ['c1']), 0);
      expect(await countRows('receipts', 'subscriber_id = ?', ['s1']), 0);

      // Other circuit + its subscriber/receipt are untouched, board remains.
      expect(await countRows('circuits', 'id = ?', ['c2']), 1);
      expect(await countRows('subscribers', 'circuit_id = ?', ['c2']), 1);
      expect(await countRows('receipts', 'subscriber_id = ?', ['s2']), 1);
      expect(await countRows('boards', 'id = ?', ['b1']), 1);
    });

    test('SubscriberRepository.delete removes its receipts and refunds',
        () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      final subRepo = SubscriberRepository();
      final receiptRepo = ReceiptRepository();

      await boardRepo.insert(makeBoard(id: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c1', boardId: 'b1'));
      await subRepo.insert(
        makeSubscriber(id: 's1', boardId: 'b1', circuitId: 'c1'),
      );
      await subRepo.insert(
        makeSubscriber(id: 's2', boardId: 'b1', circuitId: 'c1'),
      );
      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r1', receiptNo: 1, subscriberId: 's1'),
      );
      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r2', receiptNo: 2, subscriberId: 's2'),
      );

      // Insert a refund tied to r1 directly (no repo for refunds).
      final db = await DbHelper().database;
      await db.insert('refunds', {
        'uuid': 'rf1',
        'receipt_uuid': 'r1',
        'amount': 10.0,
        'reason': 'test',
      });
      await db.insert('refunds', {
        'uuid': 'rf2',
        'receipt_uuid': 'r2',
        'amount': 10.0,
        'reason': 'test',
      });

      await subRepo.delete('s1');

      expect(await countRows('subscribers', 'id = ?', ['s1']), 0);
      expect(await countRows('receipts', 'subscriber_id = ?', ['s1']), 0);
      expect(await countRows('refunds', 'receipt_uuid = ?', ['r1']), 0);

      // Other subscriber's receipt + refund intact.
      expect(await countRows('subscribers', 'id = ?', ['s2']), 1);
      expect(await countRows('receipts', 'subscriber_id = ?', ['s2']), 1);
      expect(await countRows('refunds', 'receipt_uuid = ?', ['r2']), 1);
    });
  });

  // ---- PAGINATION ------------------------------------------------------

  group('Pagination', () {
    test('BoardRepository.getAll paginates 25 boards (10/10/5)', () async {
      final boardRepo = BoardRepository();
      for (int i = 0; i < 25; i++) {
        // Zero-pad names so ASC ordering is deterministic.
        final n = i.toString().padLeft(2, '0');
        await boardRepo.insert(makeBoard(id: 'b$n', name: 'Board $n'));
      }

      final page1 = await boardRepo.getAll(limit: 10, offset: 0);
      final page2 = await boardRepo.getAll(limit: 10, offset: 10);
      final page3 = await boardRepo.getAll(limit: 10, offset: 20);

      expect(page1.length, 10);
      expect(page2.length, 10);
      expect(page3.length, 5);

      // No overlap between consecutive pages.
      final p1Ids = page1.map((b) => b.id).toSet();
      final p2Ids = page2.map((b) => b.id).toSet();
      expect(p1Ids.intersection(p2Ids), isEmpty);
      expect(page1.first.name, 'Board 00');
    });

    test('CircuitRepository.getByBoardId paginates 25 circuits (10/10/5)',
        () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      await boardRepo.insert(makeBoard(id: 'b1'));
      // Circuit under a different board must not bleed into results.
      await boardRepo.insert(makeBoard(id: 'bOther'));
      await circuitRepo.insert(
        makeCircuit(id: 'cOther', boardId: 'bOther', name: 'Other'),
      );

      for (int i = 0; i < 25; i++) {
        final n = i.toString().padLeft(2, '0');
        await circuitRepo.insert(
          makeCircuit(id: 'c$n', boardId: 'b1', name: 'Circuit $n'),
        );
      }

      final page1 = await circuitRepo.getByBoardId('b1', limit: 10, offset: 0);
      final page2 = await circuitRepo.getByBoardId('b1', limit: 10, offset: 10);
      final page3 = await circuitRepo.getByBoardId('b1', limit: 10, offset: 20);

      expect(page1.length, 10);
      expect(page2.length, 10);
      expect(page3.length, 5);
      expect(page1.every((c) => c.boardId == 'b1'), isTrue);
    });

    test('SubscriberRepository.getAll paginates 25 subscribers (10/10/5)',
        () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      final subRepo = SubscriberRepository();
      await boardRepo.insert(makeBoard(id: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c1', boardId: 'b1'));

      for (int i = 0; i < 25; i++) {
        final n = i.toString().padLeft(2, '0');
        await subRepo.insert(
          makeSubscriber(
            id: 's$n',
            boardId: 'b1',
            circuitId: 'c1',
            name: 'Sub $n',
          ),
        );
      }

      final page1 = await subRepo.getAll(limit: 10, offset: 0);
      final page2 = await subRepo.getAll(limit: 10, offset: 10);
      final page3 = await subRepo.getAll(limit: 10, offset: 20);

      expect(page1.length, 10);
      expect(page2.length, 10);
      expect(page3.length, 5);

      final ids = <String>{
        ...page1.map((s) => s.id),
        ...page2.map((s) => s.id),
        ...page3.map((s) => s.id),
      };
      expect(ids.length, 25);
    });

    test('ExpenseRepository.getExpensesByMonth paginates 25 expenses (10/10/5)',
        () async {
      final expenseRepo = ExpenseRepository();
      for (int i = 0; i < 25; i++) {
        final day = (i + 1).toString().padLeft(2, '0');
        await expenseRepo.addExpense(
          Expense(
            id: 'e$i',
            category: 'fuel',
            amount: 10,
            date: '2026-06-$day',
          ),
        );
      }
      // An expense in a different month must be excluded.
      await expenseRepo.addExpense(
        Expense(id: 'eOther', category: 'fuel', amount: 99, date: '2026-05-01'),
      );

      final page1 =
          await expenseRepo.getExpensesByMonth('2026-06', limit: 10, offset: 0);
      final page2 = await expenseRepo.getExpensesByMonth(
        '2026-06',
        limit: 10,
        offset: 10,
      );
      final page3 = await expenseRepo.getExpensesByMonth(
        '2026-06',
        limit: 10,
        offset: 20,
      );

      expect(page1.length, 10);
      expect(page2.length, 10);
      expect(page3.length, 5);
      expect(page1.every((e) => e.date.startsWith('2026-06')), isTrue);
    });
  });

  // ---- PAYMENT STATUS (valid vs refunded) ------------------------------

  group('getByPaymentStatus', () {
    test('only valid receipts count toward paid; refunded are ignored',
        () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      final subRepo = SubscriberRepository();
      final receiptRepo = ReceiptRepository();

      const month = '2026-06';
      const pricePerAmp = 5.0;

      await boardRepo.insert(makeBoard(id: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c1', boardId: 'b1'));

      // Subscriber needs amps * price = 10 * 5 = 50 to be fully paid.
      await subRepo.insert(
        makeSubscriber(id: 's1', boardId: 'b1', circuitId: 'c1', amps: 10),
      );

      // One valid receipt of 50 (covers the full bill) ...
      await receiptRepo.insert(
        makeReceipt(
          uuidStr: 'rValid',
          receiptNo: 1,
          subscriberId: 's1',
          month: month,
          paidAmount: 50,
        ),
      );
      // ... and a refunded receipt of 50 that must NOT count.
      await receiptRepo.insert(
        makeReceipt(
          uuidStr: 'rRefunded',
          receiptNo: 2,
          subscriberId: 's1',
          month: month,
          paidAmount: 50,
          status: 'refunded',
        ),
      );

      final paid = await subRepo.getByPaymentStatus(
        month: month,
        pricePerAmp: pricePerAmp,
        isPaid: true,
      );
      final unpaid = await subRepo.getByPaymentStatus(
        month: month,
        pricePerAmp: pricePerAmp,
        isPaid: false,
      );

      // total valid paid (50) >= bill (50) -> classified as paid.
      expect(paid.map((s) => s.id), contains('s1'));
      expect(unpaid.map((s) => s.id), isNot(contains('s1')));
    });

    test('subscriber with only a refunded receipt is unpaid', () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      final subRepo = SubscriberRepository();
      final receiptRepo = ReceiptRepository();

      const month = '2026-06';
      const pricePerAmp = 5.0;

      await boardRepo.insert(makeBoard(id: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c1', boardId: 'b1'));
      await subRepo.insert(
        makeSubscriber(id: 's1', boardId: 'b1', circuitId: 'c1', amps: 10),
      );

      // Only a refunded receipt for the full amount -> should NOT count.
      await receiptRepo.insert(
        makeReceipt(
          uuidStr: 'rRefunded',
          receiptNo: 1,
          subscriberId: 's1',
          month: month,
          paidAmount: 50,
          status: 'refunded',
        ),
      );

      final paid = await subRepo.getByPaymentStatus(
        month: month,
        pricePerAmp: pricePerAmp,
        isPaid: true,
      );
      final unpaid = await subRepo.getByPaymentStatus(
        month: month,
        pricePerAmp: pricePerAmp,
        isPaid: false,
      );

      expect(unpaid.map((s) => s.id), contains('s1'));
      expect(paid.map((s) => s.id), isNot(contains('s1')));
    });
  });

  // ---- MONTHLY PRICE + RECEIPT NUMBER ----------------------------------

  group('MonthlyPriceRepository', () {
    test('insert then getByMonth round-trips the price', () async {
      final repo = MonthlyPriceRepository();
      await repo.insert(MonthlyPrice(month: '2026-06', pricePerAmp: 7.5));

      final fetched = await repo.getByMonth('2026-06');
      expect(fetched, isNotNull);
      expect(fetched!.month, '2026-06');
      expect(fetched.pricePerAmp, 7.5);

      // Missing month returns null.
      expect(await repo.getByMonth('1999-01'), isNull);
    });
  });

  group('ReceiptRepository.getNextReceiptNumber', () {
    test('returns 1 when empty then max + 1', () async {
      final boardRepo = BoardRepository();
      final circuitRepo = CircuitRepository();
      final subRepo = SubscriberRepository();
      final receiptRepo = ReceiptRepository();

      expect(await receiptRepo.getNextReceiptNumber(), 1);

      await boardRepo.insert(makeBoard(id: 'b1'));
      await circuitRepo.insert(makeCircuit(id: 'c1', boardId: 'b1'));
      await subRepo.insert(
        makeSubscriber(id: 's1', boardId: 'b1', circuitId: 'c1'),
      );

      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r1', receiptNo: 5, subscriberId: 's1'),
      );
      await receiptRepo.insert(
        makeReceipt(uuidStr: 'r2', receiptNo: 9, subscriberId: 's1'),
      );

      expect(await receiptRepo.getNextReceiptNumber(), 10);
    });
  });
}
