import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/expense_controller.dart';
import 'package:generatormanagment/data/models/expense_model.dart';

class ExpensesScreen extends StatelessWidget {
  const ExpensesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    // Put controller if not exists
    final ExpenseController controller = Get.put(ExpenseController());

    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: const Text(
          "Expenses",
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: Column(
        children: [
          // Header: Total & Date
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: Color(0xFF1565C0),
              borderRadius: BorderRadius.vertical(bottom: Radius.circular(30)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Obx(
                      () => Text(
                        controller.selectedMonth.value,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(
                        Icons.calendar_month,
                        color: Colors.white70,
                      ),
                      onPressed: () async {
                        DateTime? picked = await showDatePicker(
                          context: context,
                          initialDate: DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          String m = DateFormat('yyyy-MM').format(picked);
                          controller.changeMonth(m);
                        }
                      },
                    ),
                  ],
                ),
                const Text(
                  "Total Expenses",
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Obx(
                  () => Text(
                    NumberFormat.currency(
                      symbol: "IQD ",
                      decimalDigits: 0,
                    ).format(controller.totalExpenses.value),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Quick Add Buttons Grid
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Quick Add",
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _QuickAddButton(
                      label: "Fuel",
                      icon: Icons.local_gas_station,
                      color: Colors.orange,
                      onTap: () => _showAddExpenseDialog(
                        context,
                        controller,
                        category: "Fuel",
                      ),
                    ),
                    _QuickAddButton(
                      label: "Oil",
                      icon: Icons.water_drop,
                      color: Colors.black87,
                      onTap: () => _showAddExpenseDialog(
                        context,
                        controller,
                        category: "Oil",
                      ),
                    ),
                    _QuickAddButton(
                      label: "Maint.",
                      icon: Icons.build,
                      color: Colors.blue,
                      onTap: () => _showAddExpenseDialog(
                        context,
                        controller,
                        category: "Maintenance",
                      ),
                    ),
                    _QuickAddButton(
                      label: "Other",
                      icon: Icons.more_horiz,
                      color: Colors.purple,
                      onTap: () => _showAddExpenseDialog(
                        context,
                        controller,
                        category: "Other",
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Expense List
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Recent Transactions",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.blueGrey,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Obx(() {
                      if (controller.isLoading.value)
                        return const Center(child: CircularProgressIndicator());
                      if (controller.expenses.isEmpty) {
                        return Center(
                          child: Text(
                            "No expenses for this month",
                            style: TextStyle(color: Colors.grey[400]),
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: controller.expenses.length,
                        separatorBuilder: (c, i) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final ex = controller.expenses[index];
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withOpacity(0.05),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: ListTile(
                              leading: Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: _getCategoryColor(
                                    ex.category,
                                  ).withOpacity(0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  _getCategoryIcon(ex.category),
                                  color: _getCategoryColor(ex.category),
                                ),
                              ),
                              title: Text(
                                ex.category,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              subtitle: Text(
                                "${DateFormat('MMM d').format(DateTime.parse(ex.date))} • ${ex.note ?? ''}",
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    "- ${NumberFormat.decimalPattern().format(ex.amount)}",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 20,
                                      color: Colors.grey,
                                    ),
                                    onPressed: () =>
                                        _confirmDelete(controller, ex.id),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    }),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF1565C0),
        child: const Icon(Icons.add, color: Colors.white),
        onPressed: () => _showAddExpenseDialog(context, controller),
      ),
    );
  }

  void _showAddExpenseDialog(
    BuildContext context,
    ExpenseController controller, {
    String? category,
  }) {
    final amountCtrl = TextEditingController();
    final noteCtrl = TextEditingController();
    String selectedCategory = category ?? "Fuel";
    final List<String> categories = [
      "Fuel",
      "Oil",
      "Maintenance",
      "Salaries",
      "Rent",
      "Other",
    ];

    Get.bottomSheet(
      Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Add Expense",
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),

              DropdownButtonFormField<String>(
                value: selectedCategory,
                items: categories
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (val) => selectedCategory = val!,
                decoration: InputDecoration(
                  labelText: "Category",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: "Amount",
                  prefixText: "IQD ",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              TextField(
                controller: noteCtrl,
                decoration: InputDecoration(
                  labelText: "Note (Optional)",
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (amountCtrl.text.isNotEmpty) {
                      double? val = double.tryParse(amountCtrl.text);
                      if (val != null) {
                        controller.addExpense(
                          category: selectedCategory,
                          amount: val,
                          note: noteCtrl.text,
                        );
                        Get.back();
                      }
                    }
                  },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: const Color(0xFF1565C0),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text("SAVE EXPENSE"),
                ),
              ),
              // Keyboard padding
              SizedBox(height: MediaQuery.of(context).viewInsets.bottom),
            ],
          ),
        ),
      ),
      isScrollControlled: true,
    );
  }

  void _confirmDelete(ExpenseController controller, String id) {
    Get.defaultDialog(
      title: "Delete Expense?",
      middleText: "This cannot be undone.",
      textConfirm: "Delete",
      textCancel: "Cancel",
      confirmTextColor: Colors.white,
      onConfirm: () {
        controller.deleteExpense(id);
        Get.back();
      },
    );
  }

  Color _getCategoryColor(String cat) {
    switch (cat) {
      case "Fuel":
        return Colors.orange;
      case "Oil":
        return Colors.black87;
      case "Maintenance":
        return Colors.blue;
      case "Salaries":
        return Colors.green;
      case "Rent":
        return Colors.purple;
      default:
        return Colors.grey;
    }
  }

  IconData _getCategoryIcon(String cat) {
    switch (cat) {
      case "Fuel":
        return Icons.local_gas_station;
      case "Oil":
        return Icons.water_drop;
      case "Maintenance":
        return Icons.build;
      case "Salaries":
        return Icons.people_alt;
      case "Rent":
        return Icons.home_work;
      default:
        return Icons.attach_money;
    }
  }
}

class _QuickAddButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickAddButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.blue.withOpacity(0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }
}
