import 'package:intl/intl.dart';
import 'package:generatormanagment/core/logger.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';

/// DEBUG-ONLY test data, enabled with `--dart-define=SEED_TEST_DATA=true`.
///
/// Seeds one accountant (Kareem, password `kareem123`, granted "manage
/// subscribers" + "manage expenses") with a board/circuit/subscriber assigned
/// to him, a current-month price, and a collected receipt — plus one
/// owner-owned subscriber Kareem must NOT see. Lets the per-accountant
/// print + isolation + permission flow be tested without manual data entry.
/// Idempotent (ConflictAlgorithm.replace), so it is safe to run on every boot.
class TestSeeder {
  static const bool enabled = bool.fromEnvironment('SEED_TEST_DATA');

  static Future<void> run() async {
    if (!enabled) return;
    try {
      final accts = AccountantRepository();
      final boards = BoardRepository();
      final circuits = CircuitRepository();
      final subs = SubscriberRepository();
      final prices = MonthlyPriceRepository();
      final receipts = ReceiptRepository();

      const kareem = 'seed-acc-kareem';
      final now = DateTime.now().toIso8601String();
      final month = DateFormat('yyyy-MM').format(DateTime.now());

      // Accountant Kareem with two granted permissions.
      await accts.create(
        id: kareem,
        username: 'kareem',
        name: 'Kareem',
        password: 'kareem123',
        permissions: const [Perm.subscribers, Perm.expenses],
      );

      // Kareem's own board / circuit / subscriber.
      await boards.insert(Board(
          id: 'seed-board-k',
          name: 'بورد كريم',
          accountantId: kareem,
          createdAt: now));
      await circuits.insert(Circuit(
          id: 'seed-circ-k',
          boardId: 'seed-board-k',
          name: 'جوزة كريم',
          accountantId: kareem,
          createdAt: now));
      await subs.insert(Subscriber(
          id: 'seed-sub-k',
          name: 'مشترك كريم',
          amps: 10,
          boardId: 'seed-board-k',
          circuitId: 'seed-circ-k',
          accountantId: kareem,
          createdAt: now));

      // An owner-owned board/subscriber Kareem must NOT see (isolation check).
      await boards.insert(
          Board(id: 'seed-board-o', name: 'بورد المالك', createdAt: now));
      await circuits.insert(Circuit(
          id: 'seed-circ-o',
          boardId: 'seed-board-o',
          name: 'جوزة المالك',
          createdAt: now));
      await subs.insert(Subscriber(
          id: 'seed-sub-o',
          name: 'مشترك المالك',
          amps: 20,
          boardId: 'seed-board-o',
          circuitId: 'seed-circ-o',
          createdAt: now));

      // Current-month price.
      await prices.insert(MonthlyPrice(month: month, pricePerAmp: 1000));

      // A collected receipt for Kareem's subscriber → an invoice to print,
      // attributed to Kareem so the printout shows "المحاسب: Kareem".
      final no = await receipts.getNextReceiptNumber();
      await receipts.insert(Receipt(
        uuid: 'seed-receipt-k',
        receiptNo: no,
        subscriberId: 'seed-sub-k',
        month: month,
        ampsSnapshot: 10,
        priceSnapshot: 1000,
        paidAmount: 10000,
        remainingAfter: 0,
        accountantId: kareem,
        performedByUserId: kareem,
        issuedAt: now,
        status: 'valid',
      ));

      Log.w('TestSeeder: seeded accountant Kareem + data (debug only)');
    } catch (e) {
      Log.e('TestSeeder failed', e);
    }
  }
}
