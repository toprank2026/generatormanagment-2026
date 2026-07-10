import 'package:get/get.dart';
import 'package:generatormanagment/data/models/expense_model.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/controllers/reports_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:uuid/uuid.dart';

class ExpenseController extends GetxController {
  final ExpenseRepository _repo = ExpenseRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();
  final MonthController _month = Get.find();

  /// Per-accountant scope: null = owner/admin (all). Expenses are owner-only.
  String? get _scope => _auth.scopeAccountantId;

  /// v22 item 6: owner-only accountant filter for BROWSING (null = all).
  /// Ignored for an accountant, who is always scoped to themselves. Writes
  /// (add/delete) keep using [_scope] — the filter never changes attribution.
  final RxnString accountantFilter = RxnString();

  /// Effective READ scope: an accountant is forced to their own id; the
  /// owner/admin browses all or the chosen accountant.
  String? get _readScope =>
      _auth.isAdmin ? accountantFilter.value : _auth.scopeAccountantId;

  void setAccountantFilter(String? accountantId) {
    accountantFilter.value = accountantId;
    loadExpenses();
  }

  /// Active-branch read scope (null = consolidated / All branches).
  String? get _branchScope => _branch.scopeBranchId;

  var expenses = <Expense>[].obs;
  var totalExpenses = 0.0.obs;

  /// The globally-selected month (R9) — sourced from [MonthController]. Expenses
  /// browse the same month as the rest of the app; the month is changed only on
  /// the Monthly Pricing screen.
  RxString get selectedMonth => _month.selectedMonth;
  var isLoading = false.obs;

  // Pagination
  // Large page (R1): show all expenses for normal sizes; loadMore handles scale.
  static const int expensesPerPage = 100;
  var expensesCurrentPage = 1.obs;
  var expensesHasNextPage = false.obs;
  var expensesMoreLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    // Re-scope expenses when the acting user changes.
    ever(_auth.currentUser, (_) {
      accountantFilter.value = null; // v22 item 6: reset any owner filter
      loadExpenses();
    });
    // Re-scope when the active branch switches (full system-context swap).
    ever(_branch.currentBranch, (_) => loadExpenses());
    // R9: re-load when the global month changes (changed from Monthly Pricing).
    ever(_month.selectedMonth, (_) => loadExpenses());
  }

  @override
  void onReady() {
    super.onReady();
    loadExpenses();
  }

  Future<void> loadExpenses({int page = 1}) async {
    if (page == 1) {
      isLoading.value = true;
    } else {
      expensesMoreLoading.value = true;
    }

    expensesCurrentPage.value = page;
    // Capture the month so a mid-load month change can't mismatch list/total.
    final String month = selectedMonth.value;

    try {
      // Fetch one extra item to check if there is a next page
      final result = await _repo.getExpensesByMonth(
        month,
        limit: expensesPerPage + 1,
        offset: (page - 1) * expensesPerPage,
        accountantId: _readScope, // v22 item 6: honors the owner's filter
        branchId: _branchScope,
      );

      List<Expense> newItems;
      if (result.length > expensesPerPage) {
        expensesHasNextPage.value = true;
        newItems = result.sublist(0, expensesPerPage);
      } else {
        expensesHasNextPage.value = false;
        newItems = result;
      }

      if (page == 1) {
        expenses.assignAll(newItems);
        // Month total must reflect ALL expenses, not just the page
        totalExpenses.value = await _repo.getTotalExpenses(month,
            accountantId: _readScope, branchId: _branchScope);
      } else {
        expenses.addAll(newItems);
      }
    } finally {
      isLoading.value = false;
      expensesMoreLoading.value = false;
    }
    update();
  }

  void loadMore() {
    if (expensesHasNextPage.value &&
        !expensesMoreLoading.value &&
        !isLoading.value) {
      loadExpenses(page: expensesCurrentPage.value + 1);
    }
  }

  Future<void> addExpense({
    required String category,
    required double amount,
    String? note,
    DateTime? date,
  }) async {
    final newExpense = Expense(
      id: const Uuid().v4(),
      category: category,
      amount: amount,
      note: note,
      date: (date ?? DateTime.now()).toIso8601String(),
      createdByUserId: _auth.currentUser.value?.id,
      accountantId: _scope,
      // Full isolation: the expense belongs to the active branch.
      branchId: _branch.writeBranchId,
    );
    await _repo.addExpense(newExpense);
    SyncController.poke(); // item 9
    loadExpenses();
    _refreshReports(); // v35 audit: expenses feed the Reports net/expenses cards
    update();
  }

  /// v35 audit (item 9, staleness): the alive Reports tab derives expensesTotal
  /// + netProfit from this table — recompute it after every expense write.
  void _refreshReports() {
    if (Get.isRegistered<ReportsController>()) {
      Get.find<ReportsController>().loadReport();
    }
  }

  /// v30 T3: only the CREATOR may delete an expense — an accountant deletes
  /// only their own rows; the admin/owner deletes only OWNER-CREATED rows
  /// (accountant_id null), never an accountant's (the admin still VIEWS all).
  bool canDelete(Expense e) {
    if (_auth.isAccountant) {
      final me = _auth.currentUser.value?.id;
      return me != null && e.accountantId == me;
    }
    return e.accountantId == null || e.accountantId!.isEmpty;
  }

  /// Returns false when the deletion is refused by the creator-only rule
  /// (choke point — mirrors the UI gate; the repo re-enforces it in SQL).
  Future<bool> deleteExpense(String id) async {
    Expense? e;
    for (final x in expenses) {
      if (x.id == id) {
        e = x;
        break;
      }
    }
    if (e == null || !canDelete(e)) return false;
    if (_auth.isAccountant) {
      await _repo.deleteExpense(id, accountantId: _scope);
    } else {
      await _repo.deleteExpense(id, ownerOnly: true);
    }
    SyncController.poke(); // item 9
    loadExpenses();
    _refreshReports(); // v35 audit: keep the Reports expenses/net cards fresh
    update();
    return true;
  }
}
