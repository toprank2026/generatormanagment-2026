import 'package:get/get.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:intl/intl.dart';

/// Monthly reports & statistics — all figures derived from the LOCAL SQLite
/// tables (receipts, expenses, subscribers, monthly_prices) via repositories.
/// Offline-first: no network involved. Per-accountant: an accountant sees only
/// their own figures; the owner/admin sees all and may filter by one accountant
/// via [accountantFilter].
class ReportsController extends GetxController {
  final SubscriberRepository _subRepo = SubscriberRepository();
  final ReceiptRepository _receiptRepo = ReceiptRepository();
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();
  final ExpenseRepository _expenseRepo = ExpenseRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();

  /// Owner-only accountant filter (null = all accountants). Ignored for an
  /// accountant, who is always scoped to themselves.
  final RxnString accountantFilter = RxnString();

  /// Effective scope: an accountant is forced to their own id; the owner uses
  /// the chosen filter (null = everything).
  String? get _scope =>
      _auth.isAdmin ? accountantFilter.value : _auth.currentUser.value?.id;

  /// Active-branch read scope (null = consolidated / All branches).
  String? get _branchScope => _branch.scopeBranchId;

  void setAccountantFilter(String? accountantId) {
    accountantFilter.value = accountantId;
    loadReport();
  }

  /// Selected report month as 'yyyy-MM'.
  var month = DateFormat('yyyy-MM').format(DateTime.now()).obs;
  var isLoading = false.obs;

  var totalSubscribers = 0.obs;
  var paidCount = 0.obs;
  var unpaidCount = 0.obs;

  var totalAmps = 0.0.obs;
  var pricePerAmp = 0.0.obs; // standard (back-compat; banner + expected math)
  // P2: per-tariff ampere prices for the selected month/branch.
  var goldPrice = 0.0.obs;
  var commercialPrice = 0.0.obs;
  var expectedTotal = 0.0.obs;
  var collectedTotal = 0.0.obs;
  var remainingTotal = 0.0.obs;
  var expensesTotal = 0.0.obs;
  var netProfit = 0.0.obs;

  /// The selected month's receipts, newest first (paginated).
  final RxList<Receipt> receipts = <Receipt>[].obs;

  /// Payments-list pagination (canonical pattern: fetch one extra row to
  /// detect a next page, trim, page-1 assignAll + later pages addAll).
  static const int _receiptsPerPage = 15;
  int _receiptsPage = 1;
  var hasMoreReceipts = false.obs;
  var isReceiptsLoadingMore = false.obs;

  @override
  void onInit() {
    super.onInit();
    // Re-scope the report when the acting user changes (owner <-> accountant).
    ever(_auth.currentUser, (_) {
      accountantFilter.value = null; // reset any owner filter on switch
      loadReport();
    });
    // Re-scope when the active branch switches (full system-context swap).
    ever(_branch.currentBranch, (_) => loadReport());
  }

  @override
  void onReady() {
    super.onReady();
    loadReport();
  }

  Future<void> loadReport() async {
    isLoading.value = true;
    try {
      final m = month.value;
      // Money (collected/expenses/payments list) is per-accountant; the shared
      // subscriber base (total/amps/paid/unpaid/expected) is partitioned by
      // the active branch (full isolation).
      final scope = _scope;
      final branch = _branchScope;

      // 1. Subscribers & Amps (branch-scoped) — SQL aggregates, NOT a full
      //    materialization of every subscriber row (audit: scale).
      totalSubscribers.value = await _subRepo.countByBranch(branchId: branch);
      final ampsByCat = await _subRepo.ampsByCategory(branchId: branch);
      totalAmps.value = ampsByCat.values.fold(0.0, (sum, a) => sum + a);

      // 2. Per-category prices for the month (R4). The single "price per amp"
      //    figure shown on the report uses the standard category as representative.
      final prices = await _priceRepo.pricesForMonth(m, branchId: branch);
      pricePerAmp.value = prices[SubscriberCategory.standard] ?? 0.0;
      // P2: surface all three tariff prices on the report.
      goldPrice.value = prices[SubscriberCategory.gold] ?? 0.0;
      commercialPrice.value = prices[SubscriberCategory.commercial] ?? 0.0;

      // 3. Financials. Expected is CATEGORY-AWARE: Σ amps × price[category] (R4),
      //    from the per-category amp sums above.
      double expected = 0.0;
      ampsByCat.forEach((cat, amps) {
        expected += amps * (prices[cat] ?? 0.0);
      });
      expectedTotal.value = expected;
      collectedTotal.value = await _receiptRepo.getCollectedSum(m,
          accountantId: scope, branchId: branch);
      // Remaining = expected − collected − waived discount (audit: discount
      // lockstep with the dashboard, backend, and paid/unpaid counts).
      final discountTotal = await _receiptRepo.getDiscountSum(m,
          accountantId: scope, branchId: branch);
      remainingTotal.value =
          expectedTotal.value - collectedTotal.value - discountTotal;
      expensesTotal.value = await _expenseRepo.getTotalExpenses(m,
          accountantId: scope, branchId: branch);
      netProfit.value = collectedTotal.value - expensesTotal.value;

      // 4. Paid / Unpaid counts — category-aware, branch-scoped (R4).
      paidCount.value = await _subRepo.countByPaymentStatus(
        month: m,
        isPaid: true,
        branchId: branch,
      );
      unpaidCount.value = await _subRepo.countByPaymentStatus(
        month: m,
        isPaid: false,
        branchId: branch,
      );

      // 5. The month's payments list (newest first), page 1.
      _receiptsPage = 1;
      final page = await _receiptRepo.getByMonth(
        m,
        limit: _receiptsPerPage + 1,
        offset: 0,
        accountantId: scope,
        branchId: branch,
      );
      hasMoreReceipts.value = page.length > _receiptsPerPage;
      receipts.assignAll(
        hasMoreReceipts.value ? page.sublist(0, _receiptsPerPage) : page,
      );
    } catch (e) {
      print("Error loading monthly report: $e");
    } finally {
      isLoading.value = false;
    }
    update();
  }

  /// Loads the next page of the month's payments (ScrollController calls this
  /// near the bottom of the list).
  Future<void> loadMoreReceipts() async {
    if (isReceiptsLoadingMore.value || !hasMoreReceipts.value) return;
    isReceiptsLoadingMore.value = true;
    try {
      final next = await _receiptRepo.getByMonth(
        month.value,
        limit: _receiptsPerPage + 1,
        offset: _receiptsPage * _receiptsPerPage,
        accountantId: _scope,
        branchId: _branchScope,
      );
      hasMoreReceipts.value = next.length > _receiptsPerPage;
      receipts.addAll(
        hasMoreReceipts.value ? next.sublist(0, _receiptsPerPage) : next,
      );
      _receiptsPage++;
    } catch (e) {
      print("Error loading more receipts: $e");
    } finally {
      isReceiptsLoadingMore.value = false;
    }
    update();
  }

  void setMonth(String m) {
    month.value = m;
    loadReport();
  }

  void prevMonth() => setMonth(_shiftMonth(month.value, -1));

  void nextMonth() => setMonth(_shiftMonth(month.value, 1));

  /// Shifts a 'yyyy-MM' string by [delta] months (handles year wrap).
  String _shiftMonth(String m, int delta) {
    final parts = m.split('-');
    final date = DateTime(int.parse(parts[0]), int.parse(parts[1]) + delta);
    return DateFormat('yyyy-MM').format(date);
  }
}
