class Expense {
  final String id;
  final String category;
  final double amount;
  final String? note;
  final String date;
  final String? createdByUserId;
  final String? createdAt;

  Expense({
    required this.id,
    required this.category,
    required this.amount,
    this.note,
    required this.date,
    this.createdByUserId,
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
      'created_at': createdAt,
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
      createdAt: map['created_at'],
    );
  }
}
