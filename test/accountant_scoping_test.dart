import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';

/// Proves the per-accountant data isolation contract at the repository layer:
/// an accountant scope sees ONLY its own rows; the owner (null scope) sees all;
/// deletes are accountant-aware; and accountant credentials authenticate
/// offline. (These are the guarantees the controllers rely on.)
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

  const a1 = 'acc-1';
  const a2 = 'acc-2';
  const month = '2026-06';

  final boards = BoardRepository();
  final subs = SubscriberRepository();
  final receipts = ReceiptRepository();
  final accountants = AccountantRepository();

  Subscriber sub(String id, String acc, {double amps = 10}) => Subscriber(
        id: id,
        name: 'Sub $id',
        amps: amps,
        boardId: 'b-$acc',
        circuitId: 'c-$acc',
        accountantId: acc,
      );

  Receipt rec(String uuid, String subId, String acc, double paid) => Receipt(
        uuid: uuid,
        receiptNo: uuid.hashCode & 0x7fffffff,
        subscriberId: subId,
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 1000,
        paidAmount: paid,
        remainingAfter: 0,
        accountantId: acc,
        issuedAt: '$month-10T00:00:00.000Z',
      );

  group('AccountantRepository', () {
    test('create writes a synced identity + a working offline credential',
        () async {
      await accountants.create(
          id: a1, username: 'ahmed', name: 'Ahmed', password: 'secret1');
      await accountants.create(
          id: a2, username: 'sara', name: 'Sara', password: 'secret2');

      expect(await accountants.count(), 2);
      final all = await accountants.getAll();
      expect(all.map((a) => a.id).toSet(), {a1, a2});
      expect((await accountants.getById(a1))!.displayName, 'Ahmed');

      // Offline auth: right password works, wrong fails, unknown fails.
      expect((await accountants.authenticate('ahmed', 'secret1'))!.id, a1);
      expect(await accountants.authenticate('ahmed', 'nope'), isNull);
      expect(await accountants.authenticate('ghost', 'x'), isNull);
    });

    test('disabled accountant cannot authenticate', () async {
      await accountants.create(
          id: a1, username: 'ahmed', name: 'Ahmed', password: 'secret1');
      await accountants.update(id: a1, active: false);
      expect(await accountants.authenticate('ahmed', 'secret1'), isNull);
    });
  });

  group('per-accountant read scoping', () {
    setUp(() async {
      await boards.insert(Board(id: 'b-$a1', name: 'B1', accountantId: a1));
      await boards.insert(Board(id: 'b-$a2', name: 'B2', accountantId: a2));
      await subs.insert(sub('s1', a1));
      await subs.insert(sub('s2', a2, amps: 15));
      await receipts.insert(rec('r1', 's1', a1, 10000)); // s1 fully paid
      await receipts.insert(rec('r2', 's2', a2, 5000)); // s2 underpaid
    });

    test('boards: accountant sees only own; owner sees all', () async {
      expect((await boards.getAll(accountantId: a1)).map((b) => b.id), ['b-$a1']);
      expect((await boards.getAll(accountantId: a2)).map((b) => b.id), ['b-$a2']);
      expect((await boards.getAll()).length, 2); // owner
    });

    test('subscribers: scoped vs all', () async {
      expect((await subs.getAll(accountantId: a1)).map((s) => s.id), ['s1']);
      expect((await subs.getAll(accountantId: a2)).map((s) => s.id), ['s2']);
      expect((await subs.getAll()).length, 2);
    });

    test('collected sum is per-accountant; owner is the total', () async {
      expect(await receipts.getCollectedSum(month, accountantId: a1), 10000);
      expect(await receipts.getCollectedSum(month, accountantId: a2), 5000);
      expect(await receipts.getCollectedSum(month), 15000);
    });

    test('paid/unpaid counts respect the accountant scope', () async {
      // price 1000: s1 (amps10 -> due 10000, paid 10000) PAID; s2 (amps15 ->
      // due 15000, paid 5000) UNPAID.
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: true, accountantId: a1),
          1);
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: false, accountantId: a1),
          0);
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: true, accountantId: a2),
          0);
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: false, accountantId: a2),
          1);
      // Owner-wide: 1 paid, 1 unpaid.
      expect(
          await subs.countByPaymentStatus(
              month: month, pricePerAmp: 1000, isPaid: true),
          1);
    });
  });

  group('accountant-aware delete', () {
    setUp(() async {
      await subs.insert(sub('s1', a1));
      await subs.insert(sub('s2', a2));
    });

    test('an accountant cannot delete another accountant\'s subscriber',
        () async {
      // a2 tries to delete s1 (owned by a1) -> no-op.
      await subs.delete('s1', accountantId: a2);
      expect((await subs.getAll()).length, 2);
      // a1 deletes its own s1 -> gone.
      await subs.delete('s1', accountantId: a1);
      expect((await subs.getAll()).map((s) => s.id), ['s2']);
    });

    test('owner (null scope) can delete any subscriber', () async {
      await subs.delete('s2'); // owner
      expect((await subs.getAll()).map((s) => s.id), ['s1']);
    });
  });
}
