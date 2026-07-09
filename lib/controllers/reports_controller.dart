import 'package:get/get.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
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

  /// v30 F1: gauge (paid/unpaid) scope. The owner keeps their accountant
  /// filter; an ACCOUNTANT sees the BRANCH-WIDE paid/unpaid picture (like the
  /// admin gauge) with their own collections highlighted separately ([paidByMe]).
  String? get _gaugeScope => _auth.isAdmin ? accountantFilter.value : null;

  /// v30 F1: the "current accountant" whose paid slice is shown orange — an
  /// accountant is themselves; the owner has none here (paidByMe stays 0, so the
  /// owner gauge is unchanged: a plain 2-segment paid/unpaid donut).
  String? get _meId => _auth.isAdmin ? null : _auth.currentUser.value?.id;

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

  /// v30 F1: count of subscribers PAID BY THE CURRENT ACCOUNTANT this month
  /// (the orange gauge segment). 0 for the owner/admin view.
  var paidByMe = 0.obs;

  var totalAmps = 0.0.obs;
  var pricePerAmp =
      0.0.obs; // standard-category representative — banner + header ONLY
  // (expected is category-aware since R4; v23 consolidated is branch-aware).
  // (item 1) per-tariff PAID subscriber counts for the selected month/branch
  // (replaces the old per-tariff price cards).
  var paidGold = 0.obs;
  var paidStandard = 0.obs;
  var paidCommercial = 0.obs;
  // v32 item 6: total AMPS per tariff (from the same ampsByCategory aggregate
  // that feeds totalAmps, so the three cards sum to the overall total).
  var ampsGold = 0.0.obs;
  var ampsStandard = 0.0.obs;
  var ampsCommercial = 0.0.obs;
  var expectedTotal = 0.0.obs;
  var collectedTotal = 0.0.obs;
  var remainingTotal = 0.0.obs;
  var expensesTotal = 0.0.obs;
  var netProfit = 0.0.obs;

  /// The selected month's receipts, newest first (paginated).
  final RxList<Receipt> receipts = <Receipt>[].obs;

  /// v22 item 6: accountant id → display name, so the owner's payments list can
  /// attribute each receipt to its collector (one query per report load).
  final Map<String, String> accountantNames = <String, String>{};
  final AccountantRepository _accountantRepo = AccountantRepository();

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
    // v23 item 1 (§2.5): compute EVERY figure into locals first, then commit
    // them in one atomic block at the end. A mid-way failure used to leave the
    // screen showing a mix of the new month's and the previous month's numbers.
    try {
      final m = month.value;
      // Money (collected/expenses/payments list) is per-accountant; the shared
      // subscriber base (total/amps/paid/unpaid/expected) is partitioned by
      // the active branch (full isolation).
      final scope = _scope;
      final branch = _branchScope;
      // v30 F1: the gauge (paid/unpaid + per-tariff) uses the branch-wide scope
      // for an accountant (so they see the same paid/unpaid picture as admin),
      // while money figures stay personal via [scope]. [meId] is the accountant
      // whose paid slice is highlighted orange.
      final gaugeScope = _gaugeScope;
      final meId = _meId;

      // 1. Subscribers & Amps (branch-scoped) — SQL aggregates, NOT a full
      //    materialization of every subscriber row (audit: scale).
      final int totalSubs = await _subRepo.countByBranch(branchId: branch);
      final ampsByCat = await _subRepo.ampsByCategory(branchId: branch);
      final double totalAmpsLocal =
          ampsByCat.values.fold(0.0, (sum, a) => sum + a);

      // 2. Per-category prices for the month (R4). The single "price per amp"
      //    figure shown on the report uses the standard category as representative.
      final prices = await _priceRepo.pricesForMonth(m, branchId: branch);
      final double pricePerAmpLocal =
          prices[SubscriberCategory.standard] ?? 0.0;

      // 3. Financials. Expected is CATEGORY-AWARE: Σ amps × price[category] (R4).
      //    v23 item 1 (§2.3): in the CONSOLIDATED (All-branches) view, price each
      //    branch's amps with THAT branch's own tariff — the flat
      //    pricesForMonth(null) collapses branches last-row-wins (wrong for
      //    differently-priced branches). A single active branch keeps the old math.
      double expectedLocal = 0.0;
      if (branch == null) {
        final ampsByBranchCat = await _subRepo.ampsByBranchCategory();
        final pricesByBranch = await _priceRepo.pricesForMonthByBranch(m);
        ampsByBranchCat.forEach((br, catMap) {
          final brPrices = pricesByBranch[br] ?? const <String, double>{};
          catMap.forEach((cat, amps) {
            expectedLocal += amps * (brPrices[cat] ?? 0.0);
          });
        });
      } else {
        ampsByCat.forEach((cat, amps) {
          expectedLocal += amps * (prices[cat] ?? 0.0);
        });
      }
      final double collectedLocal = await _receiptRepo.getCollectedSum(m,
          accountantId: scope, branchId: branch);
      // Remaining = expected − collected − waived discount (audit: discount
      // lockstep with the dashboard, backend, and paid/unpaid counts).
      final double discountTotal = await _receiptRepo.getDiscountSum(m,
          accountantId: scope, branchId: branch);
      // v32 item 3 (audit fix, mirrors DashboardController): remaining is a
      // BRANCH fact — for an ACCOUNTANT login it must subtract ALL branch
      // collections/discounts, not only theirs (the personal scope overstated
      // remaining and contradicted the Home dashboard). The OWNER's explicit
      // accountantFilter keeps its deliberate per-accountant remaining (v22).
      final double collectedForRemaining;
      final double discountForRemaining;
      if (!_auth.isAdmin) {
        collectedForRemaining =
            await _receiptRepo.getCollectedSum(m, branchId: branch);
        discountForRemaining =
            await _receiptRepo.getDiscountSum(m, branchId: branch);
      } else {
        collectedForRemaining = collectedLocal;
        discountForRemaining = discountTotal;
      }
      final double remainingLocal =
          expectedLocal - collectedForRemaining - discountForRemaining;
      final double expensesLocal = await _expenseRepo.getTotalExpenses(m,
          accountantId: scope, branchId: branch);
      final double netLocal = collectedLocal - expensesLocal;

      // 4. Paid / Unpaid counts — category-aware, branch-scoped (R4).
      // v22 item 6: also scoped to the COLLECTOR when a per-accountant view is
      // active (receiptAccountantId — receipts.accountant_id, matching the
      // backend panel's v14 per-accountant coverage), so the donut + per-tariff
      // counts no longer stay branch-wide while the money figures are filtered.
      final int paidLocal = await _subRepo.countByPaymentStatus(
        month: m,
        isPaid: true,
        branchId: branch,
        receiptAccountantId: gaugeScope,
      );
      final int unpaidLocal = await _subRepo.countByPaymentStatus(
        month: m,
        isPaid: false,
        branchId: branch,
        receiptAccountantId: gaugeScope,
      );

      // v30 F1: subscribers PAID BY THE CURRENT ACCOUNTANT this month (orange
      // segment) — collector-scoped to [meId]; 0 for the owner/admin view.
      final int paidByMeLocal = meId == null
          ? 0
          : await _subRepo.countByPaymentStatus(
              month: m,
              isPaid: true,
              branchId: branch,
              receiptAccountantId: meId,
            );

      // (item 1) per-tariff PAID counts (gold / standard / commercial).
      final int paidGoldLocal = await _subRepo.countByPaymentStatus(
          month: m,
          isPaid: true,
          branchId: branch,
          category: SubscriberCategory.gold,
          receiptAccountantId: gaugeScope);
      final int paidStandardLocal = await _subRepo.countByPaymentStatus(
          month: m,
          isPaid: true,
          branchId: branch,
          category: SubscriberCategory.standard,
          receiptAccountantId: gaugeScope);
      final int paidCommercialLocal = await _subRepo.countByPaymentStatus(
          month: m,
          isPaid: true,
          branchId: branch,
          category: SubscriberCategory.commercial,
          receiptAccountantId: gaugeScope);

      // v22 item 6: collector-name map (best-effort; report renders without it).
      // v23 review: SNAPSHOT the prior names (not an alias) so a getAll() failure
      // leaves the atomic commit re-installing the previous map, not an empty one.
      Map<String, String> namesLocal = Map<String, String>.from(accountantNames);
      try {
        final all = await _accountantRepo.getAll();
        namesLocal = {for (final a in all) a.id: a.displayName};
      } catch (_) {}

      // 5. The month's payments list (newest first), page 1.
      final page = await _receiptRepo.getByMonth(
        m,
        limit: _receiptsPerPage + 1,
        offset: 0,
        accountantId: scope,
        branchId: branch,
      );
      final bool moreReceipts = page.length > _receiptsPerPage;
      final receiptsPage =
          moreReceipts ? page.sublist(0, _receiptsPerPage) : page;

      // --- ATOMIC COMMIT: everything computed OK → publish together. ---
      totalSubscribers.value = totalSubs;
      totalAmps.value = totalAmpsLocal;
      pricePerAmp.value = pricePerAmpLocal;
      expectedTotal.value = expectedLocal;
      collectedTotal.value = collectedLocal;
      remainingTotal.value = remainingLocal;
      expensesTotal.value = expensesLocal;
      netProfit.value = netLocal;
      paidCount.value = paidLocal;
      unpaidCount.value = unpaidLocal;
      paidByMe.value = paidByMeLocal;
      paidGold.value = paidGoldLocal;
      paidStandard.value = paidStandardLocal;
      paidCommercial.value = paidCommercialLocal;
      // v32 item 6: per-tariff amps from the already-computed aggregate.
      ampsGold.value = ampsByCat[SubscriberCategory.gold] ?? 0.0;
      ampsStandard.value = ampsByCat[SubscriberCategory.standard] ?? 0.0;
      ampsCommercial.value = ampsByCat[SubscriberCategory.commercial] ?? 0.0;
      accountantNames
        ..clear()
        ..addAll(namesLocal);
      _receiptsPage = 1;
      hasMoreReceipts.value = moreReceipts;
      receipts.assignAll(receiptsPage);
    } catch (e) {
      // Keep the previously-displayed figures intact; surface the failure.
      print("Error loading monthly report: $e");
      Get.snackbar('error'.tr, 'report_failed'.tr,
          snackPosition: SnackPosition.BOTTOM);
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
