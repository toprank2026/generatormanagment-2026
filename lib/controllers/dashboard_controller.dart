import 'package:flutter/material.dart';
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
  // True when the selected month/branch has at least one price row set. When
  // false the dashboard shows a "no pricing set for this month" notice (R: month
  // pricing check) — the figures still recompute (revenue/remaining = 0).
  var hasPriceForMonth = true.obs;

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

  /// Switch the dashboard month (R11) — every figure (revenue, remaining,
  /// paid/unpaid, expected) rebinds to the selected month. If that month has no
  /// pricing set, surface a message (the figures still recompute to 0).
  Future<void> changeMonth(String month) async {
    currentMonth.value = month;
    await loadStats();
    if (!hasPriceForMonth.value) {
      Get.snackbar(
        'no_pricing'.tr,
        'no_pricing_set_for_month'.tr,
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: const Color(0xFFFFF3E0),
        colorText: const Color(0xFFE65100),
        margin: const EdgeInsets.all(12),
      );
    }
    update();
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

      // 2. Financials for the SELECTED month. Expected is CATEGORY-AWARE (R4):
      //    each subscriber's due = amps × the price for ITS category this
      //    month/branch (a category with no price set contributes 0).
      final month = currentMonth.value;
      final prices = await _priceRepo.pricesForMonth(month, branchId: branch);
      // Month pricing check: has the owner set any price for this month/branch?
      hasPriceForMonth.value = prices.isNotEmpty;
      double expected = 0.0;
      for (final s in subs) {
        expected += s.amps * (prices[s.category] ?? 0.0);
      }

      // 3. Monthly Revenue = collected valid receipts this month (active branch +
      //    this accountant; owner = all) (R6/R9).
      totalCollected.value = await _receiptRepo.getCollectedSum(month,
          accountantId: scope, branchId: branch);

      // Monthly Remaining Fees = expected − collected (R6/R9).
      totalDue.value = expected - totalCollected.value;

      // 4. Paid / Unpaid Counts — category-aware, branch-scoped (R4).
      paidCount.value = await _subRepo.countByPaymentStatus(
        month: month,
        isPaid: true,
        branchId: branch,
      );
      unpaidCount.value = await _subRepo.countByPaymentStatus(
        month: month,
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
