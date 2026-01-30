import 'package:get/get.dart';
import 'package:generatormanagment/data/models/expense_model.dart';
import 'package:generatormanagment/data/repositories/expense_repository.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

class ExpenseController extends GetxController {
  final ExpenseRepository _repo = ExpenseRepository();

  var expenses = <Expense>[].obs;
  var totalExpenses = 0.0.obs;
  var selectedMonth = "".obs;
  var isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    selectedMonth.value = DateFormat('yyyy-MM').format(DateTime.now());
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

  Future<void> loadExpenses() async {
    isLoading.value = true;
    expenses.value = await _repo.getExpensesByMonth(selectedMonth.value);
    totalExpenses.value = await _repo.getTotalExpenses(selectedMonth.value);
    isLoading.value = false;
    update();
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
    );
    await _repo.addExpense(newExpense);
    loadExpenses();
    update();
  }

  Future<void> deleteExpense(String id) async {
    await _repo.deleteExpense(id);
    loadExpenses();
    update();
  }
}
