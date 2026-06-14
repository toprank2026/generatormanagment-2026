import 'package:get/get.dart';
import 'package:generatormanagment/data/models/expense_model.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

class ExpenseController extends GetxController {
  final ExpenseRepository _repo = ExpenseRepository();
  final AuthController _auth = Get.find();

  /// Per-accountant scope: null = owner/admin (all). Expenses are owner-only.
  String? get _scope => _auth.scopeAccountantId;

  var expenses = <Expense>[].obs;
  var totalExpenses = 0.0.obs;
  var selectedMonth = "".obs;
  var isLoading = false.obs;

  // Pagination
  static const int expensesPerPage = 10;
  var expensesCurrentPage = 1.obs;
  var expensesHasNextPage = false.obs;
  var expensesMoreLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    selectedMonth.value = DateFormat('yyyy-MM').format(DateTime.now());
    // Re-scope expenses when the acting user changes.
    ever(_auth.currentUser, (_) => loadExpenses());
  }

  @override
  void onReady() {
    super.onReady();
    loadExpenses();
  }

  void changeMonth(String month) {
    selectedMonth.value = month;
    loadExpenses();
    update();
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
        accountantId: _scope,
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
        totalExpenses.value =
            await _repo.getTotalExpenses(month, accountantId: _scope);
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
    );
    await _repo.addExpense(newExpense);
    loadExpenses();
    update();
  }

  Future<void> deleteExpense(String id) async {
    await _repo.deleteExpense(id, accountantId: _scope);
    loadExpenses();
    update();
  }
}
