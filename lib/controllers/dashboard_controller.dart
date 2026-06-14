import 'package:get/get.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:intl/intl.dart';

class DashboardController extends GetxController {
  final SubscriberRepository _subRepo = SubscriberRepository();
  final ReceiptRepository _receiptRepo = ReceiptRepository();
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();
  final BoardRepository _boardRepo = BoardRepository();
  final CircuitRepository _circuitRepo = CircuitRepository();
  final AuthController _auth = Get.find();

  /// Per-accountant scope: null = owner/admin (all), else the accountant's id.
  String? get _scope => _auth.scopeAccountantId;

  var totalSubscribers = 0.obs;
  var totalAmps = 0.0.obs;
  var totalCollected = 0.0.obs;
  var totalDue = 0.0.obs;
  var paidCount = 0.obs;
  var unpaidCount = 0.obs;
  var boardsCount = 0.obs;
  var circuitsCount = 0.obs;
  var currentMonth = "".obs;
  var isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    currentMonth.value = DateFormat('yyyy-MM').format(DateTime.now());
    // Re-scope the stats whenever the acting user changes (owner <-> accountant).
    ever(_auth.currentUser, (_) => loadStats());
  }

  @override
  void onReady() {
    super.onReady();
    loadStats();
  }

  Future<void> loadStats() async {
    isLoading.value = true;
    try {
      final scope = _scope;
      // 1. Subscribers & Amps (scoped to the acting accountant, if any)
      final subs = await _subRepo.getAll(limit: 10000, accountantId: scope);
      totalSubscribers.value = subs.length;
      totalAmps.value = subs.fold(0.0, (sum, s) => sum + s.amps);

      // 2. Financials for current month
      final month = currentMonth.value;
      final priceObj = await _priceRepo.getByMonth(month);
      final price = priceObj?.pricePerAmp ?? 0.0;

      double calculatedTotalDue = totalAmps.value * price;

      // 3. Collected
      // Fetch real collected amount from DB
      totalCollected.value =
          await _receiptRepo.getCollectedSum(month, accountantId: scope);

      // Remaining = Total Expected - Collected
      totalDue.value = calculatedTotalDue - totalCollected.value;

      // 4. Paid / Unpaid Counts
      paidCount.value = await _subRepo.countByPaymentStatus(
        month: month,
        pricePerAmp: price,
        isPaid: true,
        accountantId: scope,
      );
      unpaidCount.value = await _subRepo.countByPaymentStatus(
        month: month,
        pricePerAmp: price,
        isPaid: false,
        accountantId: scope,
      );

      // 5. Boards Count
      final boardsList = await _boardRepo.getAll(accountantId: scope);
      boardsCount.value = boardsList.length;

      // 6. Circuits Count
      final List<Circuit> allCircuits = [];
      for (var b in boardsList) {
        final circs = await _circuitRepo.getByBoardId(b.id, accountantId: scope);
        allCircuits.addAll(circs);
      }
      circuitsCount.value = allCircuits.length;
    } catch (e) {
      print("Error loading dashboard stats: $e");
    } finally {
      isLoading.value = false;
    }
    update();
  }
}
