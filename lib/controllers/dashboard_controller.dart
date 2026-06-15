import 'package:get/get.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:intl/intl.dart';

class DashboardController extends GetxController {
  final SubscriberRepository _subRepo = SubscriberRepository();
  final ReceiptRepository _receiptRepo = ReceiptRepository();
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();
  final BoardRepository _boardRepo = BoardRepository();
  final CircuitRepository _circuitRepo = CircuitRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();

  /// Per-accountant scope: null = owner/admin (all), else the accountant's id.
  String? get _scope => _auth.scopeAccountantId;

  /// Active-branch read scope (null = consolidated / All branches).
  String? get _branchScope => _branch.scopeBranchId;

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
    // Re-scope when the active branch switches (full system-context swap).
    ever(_branch.currentBranch, (_) => loadStats());
  }

  @override
  void onReady() {
    super.onReady();
    loadStats();
  }

  Future<void> loadStats() async {
    isLoading.value = true;
    try {
      // Subscriber base (subscribers/boards/circuits) is SHARED across
      // accountants but PARTITIONED by branch → counts are scoped to the active
      // branch. Only the money (collected) is additionally per-accountant.
      final scope = _scope; // accountant id (null = owner/all) — money only
      final branch = _branchScope; // active branch (null = consolidated/all)
      // 1. Subscribers & Amps (branch-scoped)
      final subs = await _subRepo.getAll(limit: 10000, branchId: branch);
      totalSubscribers.value = subs.length;
      totalAmps.value = subs.fold(0.0, (sum, s) => sum + s.amps);

      // 2. Financials for current month (price is per-branch)
      final month = currentMonth.value;
      final priceObj = await _priceRepo.getByMonth(month, branchId: branch);
      final price = priceObj?.pricePerAmp ?? 0.0;

      double calculatedTotalDue = totalAmps.value * price;

      // 3. Collected — active branch + this accountant's own receipts (owner=all)
      totalCollected.value = await _receiptRepo.getCollectedSum(month,
          accountantId: scope, branchId: branch);

      // Remaining = Total Expected - Collected
      totalDue.value = calculatedTotalDue - totalCollected.value;

      // 4. Paid / Unpaid Counts (branch-scoped subscriber base)
      paidCount.value = await _subRepo.countByPaymentStatus(
        month: month,
        pricePerAmp: price,
        isPaid: true,
        branchId: branch,
      );
      unpaidCount.value = await _subRepo.countByPaymentStatus(
        month: month,
        pricePerAmp: price,
        isPaid: false,
        branchId: branch,
      );

      // 5. Boards Count (branch-scoped)
      final boardsList = await _boardRepo.getAll(branchId: branch);
      boardsCount.value = boardsList.length;

      // 6. Circuits Count (branch-scoped)
      final List<Circuit> allCircuits = [];
      for (var b in boardsList) {
        final circs = await _circuitRepo.getByBoardId(b.id, branchId: branch);
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
