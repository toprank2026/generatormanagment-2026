import 'package:get/get.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';

class DashboardController extends GetxController {
  final SubscriberRepository _subRepo = SubscriberRepository();
  final ReceiptRepository _receiptRepo = ReceiptRepository();
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();
  final BoardRepository _boardRepo = BoardRepository();
  final CircuitRepository _circuitRepo = CircuitRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();
  final MonthController _month = Get.find();

  /// Per-accountant scope: null = owner/admin (all), else the accountant's id.
  String? get _scope => _auth.scopeAccountantId;

  /// Active-branch read scope (null = consolidated / All branches).
  String? get _branchScope => _branch.scopeBranchId;

  /// The globally-selected month (R9) — sourced from [MonthController], NOT
  /// owned here. Exposed as the same [RxString] so the dashboard banner stays
  /// reactive while only displaying it (the picker now lives on Monthly
  /// Pricing). The dashboard shows this month read-only.
  RxString get currentMonth => _month.selectedMonth;

  var totalSubscribers = 0.obs;
  var totalAmps = 0.0.obs;
  var totalCollected = 0.0.obs;
  var totalDue = 0.0.obs;
  var paidCount = 0.obs;
  var unpaidCount = 0.obs;
  var boardsCount = 0.obs;
  var circuitsCount = 0.obs;
  // v32 item 1: Σ amps per category for the derived PAID / UNPAID sets — the
  // same coverage rule as the counts, so paidAmps + unpaidAmps == totalAmps.
  final paidAmpsByCategory = <String, double>{}.obs;
  final unpaidAmpsByCategory = <String, double>{}.obs;
  // v32 item 2: total APPROVED (applied) discounts this month — the waived
  // amounts on valid receipts. Read-only aggregate of existing data
  // (receipts.discount_value); branch-wide like paid/unpaid.
  var totalDiscounts = 0.0.obs;
  var isLoading = false.obs;
  // True when the selected month/branch has at least one price row set. When
  // false the dashboard shows a "no pricing set for this month" notice (R: month
  // pricing check) — the figures still recompute (revenue/remaining = 0).
  var hasPriceForMonth = true.obs;

  @override
  void onInit() {
    super.onInit();
    // Re-scope the stats whenever the acting user changes (owner <-> accountant).
    ever(_auth.currentUser, (_) => loadStats());
    // Re-scope when the active branch switches (full system-context swap).
    ever(_branch.currentBranch, (_) => loadStats());
    // R9: re-bind ALL figures when the global month changes (the change is
    // initiated from the Monthly Pricing screen). This keeps paid/unpaid,
    // revenue, remaining and the no-pricing notice synchronized to one month.
    ever(_month.selectedMonth, (_) => loadStats());
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
      // 1. Subscribers & Amps (branch-scoped) — SQL aggregates, NOT a full
      //    materialization of every subscriber row (audit: scale).
      totalSubscribers.value = await _subRepo.countByBranch(branchId: branch);
      final ampsByCat = await _subRepo.ampsByCategory(branchId: branch);
      totalAmps.value = ampsByCat.values.fold(0.0, (sum, a) => sum + a);

      // 2. Financials for the SELECTED month. Expected is CATEGORY-AWARE (R4):
      //    each subscriber's due = amps × the price for ITS category this
      //    month/branch (a category with no price set contributes 0). Computed
      //    from the per-category amp sums above.
      final month = currentMonth.value;
      final prices = await _priceRepo.pricesForMonth(month, branchId: branch);
      // Month pricing check: has the owner set any price for this month/branch?
      hasPriceForMonth.value = prices.isNotEmpty;
      // v23 item 1 (§2.3): CONSOLIDATED (All-branches) view prices each branch's
      // amps with THAT branch's own tariff — the flat pricesForMonth(null)
      // collapses branches last-row-wins (wrong for differently-priced branches).
      // A single active branch keeps the old math.
      double expected = 0.0;
      if (branch == null) {
        final ampsByBranchCat = await _subRepo.ampsByBranchCategory();
        final pricesByBranch =
            await _priceRepo.pricesForMonthByBranch(month);
        ampsByBranchCat.forEach((br, catMap) {
          final brPrices = pricesByBranch[br] ?? const <String, double>{};
          catMap.forEach((cat, amps) {
            expected += amps * (brPrices[cat] ?? 0.0);
          });
        });
      } else {
        ampsByCat.forEach((cat, amps) {
          expected += amps * (prices[cat] ?? 0.0);
        });
      }

      // 3. Monthly Revenue = collected valid receipts this month (active branch +
      //    this accountant; owner = all) (R6/R9).
      totalCollected.value = await _receiptRepo.getCollectedSum(month,
          accountantId: scope, branchId: branch);

      // Monthly Remaining Fees = expected − collected − waived discount. The
      // discount reduces what is owed (coverage = paid + discount), so it must
      // be subtracted here too, matching the backend dashboard and the
      // paid/unpaid counts (audit: discount lockstep). Collected stays cash-only.
      //
      // v32 item 3 (audit fix): remaining is a BRANCH fact — what subscribers
      // still owe — so it must subtract ALL collections/discounts of the
      // branch, not only the acting accountant's. For an accountant the old
      // scope-mixed math (branch expected − personal collected) overstated
      // remaining whenever a colleague had also collected. Owner/admin figures
      // are unchanged (scope is already null → identical queries).
      final double collectedAll = scope == null
          ? totalCollected.value
          : await _receiptRepo.getCollectedSum(month, branchId: branch);
      final double discountAll =
          await _receiptRepo.getDiscountSum(month, branchId: branch);
      totalDue.value = expected - collectedAll - discountAll;
      // v32 item 2: the approved-discounts card (branch-wide, like paid/unpaid).
      totalDiscounts.value = discountAll;

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

      // v32 item 1: Σ amps per category for the PAID and UNPAID sets (same
      // derived rule as the counts → the two groups partition totalAmps).
      paidAmpsByCategory.value = await _subRepo.ampsByPaymentStatusCategory(
          month: month, isPaid: true, branchId: branch);
      unpaidAmpsByCategory.value = await _subRepo.ampsByPaymentStatusCategory(
          month: month, isPaid: false, branchId: branch);

      // 5. Boards Count (branch-scoped) — COUNT, not a full getAll.
      boardsCount.value = await _boardRepo.countByBranch(branchId: branch);

      // 6. Circuits Count (branch-scoped) — single COUNT, not an N+1 loop that
      //    fetched and concatenated every circuit row per board (audit: scale).
      circuitsCount.value = await _circuitRepo.countByBranch(branchId: branch);
    } catch (e) {
      print("Error loading dashboard stats: $e");
    } finally {
      isLoading.value = false;
    }
    update();
  }
}
