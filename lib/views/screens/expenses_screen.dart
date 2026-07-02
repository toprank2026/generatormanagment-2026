import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:generatormanagment/controllers/expense_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/permissions.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/repositories/accountant_repository.dart';
import 'package:generatormanagment/utils/money.dart';
import 'package:generatormanagment/views/widgets/date_field.dart';

class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key});

  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  final ExpenseController controller = Get.find<ExpenseController>();
  final AuthController auth = Get.find<AuthController>();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      controller.loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text(
          'expenses'.tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(child: Column(
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
                // R9: month is READ-ONLY here — selected only on Monthly Pricing
                // and shown across the app as information.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.calendar_month,
                        color: Colors.white70, size: 18),
                    const SizedBox(width: 6),
                    Obx(
                      () => Text(
                        controller.selectedMonth.value,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  'total_expenses'.tr,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Obx(
                  () => Text(
                    "IQD ${fmtAmount(controller.totalExpenses.value)}",
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

          // v22 item 6: owner/admin-only accountant filter — browse ONE
          // accountant's expenses (null = all). Accountants are always scoped
          // to themselves, so the dropdown is hidden for them. The Obx reads
          // auth.isAdmin (currentUser) FIRST — never short-circuits before an
          // observable read (GetX "improper use of Obx" gotcha).
          Obx(
            () => auth.isAdmin
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: FutureBuilder<List<Accountant>>(
                        future: AccountantRepository().getAll(),
                        builder: (context, snapshot) {
                          final List<Accountant> accountants =
                              snapshot.data ?? [];
                          return Obx(
                            () => DropdownButtonHideUnderline(
                              child: DropdownButton<String?>(
                                isExpanded: true,
                                value: controller.accountantFilter.value,
                                hint: Text('all_accountants'.tr),
                                icon: const Icon(Icons.person_search,
                                    color: Color(0xFF1565C0)),
                                items: [
                                  DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text('all_accountants'.tr),
                                  ),
                                  ...accountants.map(
                                    (a) => DropdownMenuItem<String?>(
                                      value: a.id,
                                      child: Text(
                                        a.displayName,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                                onChanged: controller.setAccountantFilter,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // Quick Add Buttons Grid (owner or accountant granted expenses)
          Obx(
            () => auth.can(Perm.expenses)
                ? Column(
                    children: [
                      const SizedBox(height: 20),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'quick_add'.tr,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blueGrey,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: [
                                _QuickAddButton(
                                  label: 'expense_cat_fuel'.tr,
                                  icon: Icons.local_gas_station,
                                  color: Colors.orange,
                                  onTap: () => _showAddExpenseDialog(
                                    context,
                                    controller,
                                    category: "Fuel",
                                  ),
                                ),
                                _QuickAddButton(
                                  label: 'expense_cat_oil'.tr,
                                  icon: Icons.water_drop,
                                  color: Colors.black87,
                                  onTap: () => _showAddExpenseDialog(
                                    context,
                                    controller,
                                    category: "Oil",
                                  ),
                                ),
                                _QuickAddButton(
                                  label: 'expense_cat_maint_short'.tr,
                                  icon: Icons.build,
                                  color: Colors.blue,
                                  onTap: () => _showAddExpenseDialog(
                                    context,
                                    controller,
                                    category: "Maintenance",
                                  ),
                                ),
                                _QuickAddButton(
                                  label: 'expense_cat_other'.tr,
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
                    ],
                  )
                : const SizedBox.shrink(),
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
                  Text(
                    'recent_transactions'.tr,
                    style: const TextStyle(
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
                            'no_expenses_month'.tr,
                            style: TextStyle(color: Colors.grey[400]),
                          ),
                        );
                      }
                      return ListView.separated(
                        controller: _scrollController,
                        itemCount:
                            controller.expenses.length +
                            (controller.expensesMoreLoading.value ? 1 : 0),
                        separatorBuilder: (c, i) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          if (index == controller.expenses.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(8.0),
                                child: CircularProgressIndicator(),
                              ),
                            );
                          }
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
                                _categoryLabel(ex.category),
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
                                    "- ${fmtAmount(ex.amount)}",
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                  Obx(
                                    () => auth.can(Perm.expenses)
                                        ? Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const SizedBox(width: 4),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.delete_outline,
                                                  size: 20,
                                                  color: Colors.grey,
                                                ),
                                                onPressed: () => _confirmDelete(
                                                  controller,
                                                  ex.id,
                                                ),
                                              ),
                                            ],
                                          )
                                        : const SizedBox.shrink(),
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
      )),
      floatingActionButton: Obx(
        () => auth.can(Perm.expenses)
            ? FloatingActionButton(
                backgroundColor: const Color(0xFF1565C0),
                child: const Icon(Icons.add, color: Colors.white),
                onPressed: () => _showAddExpenseDialog(context, controller),
              )
            : const SizedBox.shrink(),
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
    // R12: expense date is editable (manual entry + picker); defaults to today.
    DateTime selectedDate = DateTime.now();
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
              Text(
                'add_expense'.tr,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 20),

              DropdownButtonFormField<String>(
                value: selectedCategory,
                items: categories
                    .map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(_categoryLabel(c)),
                      ),
                    )
                    .toList(),
                onChanged: (val) => selectedCategory = val!,
                decoration: InputDecoration(
                  labelText: 'expense_category'.tr,
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
                  labelText: 'amount'.tr,
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
                  labelText: 'note_optional'.tr,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // R12: manual date entry + picker for the expense date.
              DateField(
                label: 'date'.tr,
                initial: selectedDate,
                onChanged: (d) => selectedDate = d,
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
                          date: selectedDate,
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
                  child: Text('save_expense'.tr),
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
      title: 'delete_expense_title'.tr,
      middleText: 'delete_expense_confirm'.tr,
      textConfirm: 'delete'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      onConfirm: () {
        controller.deleteExpense(id);
        Get.back();
      },
    );
  }

  String _categoryLabel(String cat) {
    switch (cat) {
      case "Fuel":
        return 'expense_cat_fuel'.tr;
      case "Oil":
        return 'expense_cat_oil'.tr;
      case "Maintenance":
        return 'expense_cat_maintenance'.tr;
      case "Salaries":
        return 'expense_cat_salaries'.tr;
      case "Rent":
        return 'expense_cat_rent'.tr;
      case "Other":
        return 'expense_cat_other'.tr;
      default:
        return cat;
    }
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
