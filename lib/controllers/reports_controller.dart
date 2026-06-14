import 'package:get/get.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
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

  /// Owner-only accountant filter (null = all accountants). Ignored for an
  /// accountant, who is always scoped to themselves.
  final RxnString accountantFilter = RxnString();

  /// Effective scope: an accountant is forced to their own id; the owner uses
  /// the chosen filter (null = everything).
  String? get _scope =>
      _auth.isAdmin ? accountantFilter.value : _auth.currentUser.value?.id;

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
  var pricePerAmp = 0.0.obs;
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
      final scope = _scope;

      // 1. Subscribers & Amps
      final subs = await _subRepo.getAll(limit: 10000, accountantId: scope);
      totalSubscribers.value = subs.length;
      totalAmps.value = subs.fold(0.0, (sum, s) => sum + s.amps);

      // 2. Price for the selected month
      final priceObj = await _priceRepo.getByMonth(m);
      pricePerAmp.value = priceObj?.pricePerAmp ?? 0.0;

      // 3. Financials
      expectedTotal.value = totalAmps.value * pricePerAmp.value;
      collectedTotal.value =
          await _receiptRepo.getCollectedSum(m, accountantId: scope);
      remainingTotal.value = expectedTotal.value - collectedTotal.value;
      expensesTotal.value =
          await _expenseRepo.getTotalExpenses(m, accountantId: scope);
      netProfit.value = collectedTotal.value - expensesTotal.value;

      // 4. Paid / Unpaid counts (same formula as the dashboard)
      paidCount.value = await _subRepo.countByPaymentStatus(
        month: m,
        pricePerAmp: pricePerAmp.value,
        isPaid: true,
        accountantId: scope,
      );
      unpaidCount.value = await _subRepo.countByPaymentStatus(
        month: m,
        pricePerAmp: pricePerAmp.value,
        isPaid: false,
        accountantId: scope,
      );

      // 5. The month's payments list (newest first), page 1.
      _receiptsPage = 1;
      final page = await _receiptRepo.getByMonth(
        m,
        limit: _receiptsPerPage + 1,
        offset: 0,
        accountantId: scope,
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
