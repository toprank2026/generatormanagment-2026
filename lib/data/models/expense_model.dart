class Expense {
  final String id;
  final String category;
  final double amount;
  final String? note;
  final String date;
  final String? createdByUserId;
  // Owning accountant (NULL = owner-owned). Expenses are owner-only today, but
  // the column keeps per-accountant report filtering uniform with the rest.
  final String? accountantId;
  // Owning branch (full-isolation partition). NULL = Main Branch (legacy).
  final String? branchId;
  final String? createdAt;

  Expense({
    required this.id,
    required this.category,
    required this.amount,
    this.note,
    required this.date,
    this.createdByUserId,
    this.accountantId,
    this.branchId,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'category': category,
      'amount': amount,
      'note': note,
      'date': date,
      'created_by_user_id': createdByUserId,
      'accountant_id': accountantId,
      'branch_id': branchId,
      'created_at': createdAt,
      'updated_at': DateTime.now().toUtc().toIso8601String(), // conflict resolution
    };
  }

  factory Expense.fromMap(Map<String, dynamic> map) {
    return Expense(
      id: map['id'],
      category: map['category'],
      amount: (map['amount'] as num).toDouble(),
      note: map['note'],
      date: map['date'],
      createdByUserId: map['created_by_user_id'],
      accountantId: map['accountant_id'],
      branchId: map['branch_id'],
      createdAt: map['created_at'],
    );
  }
}
