/// v11: an accountant wallet settlement request. The wallet balance is DERIVED
/// (Σ collected cash − Σ approved settlements), never stored as a counter; a
/// settlement just records the amount requested and the owner's decision.
class Settlement {
  String id;
  String? accountantId;
  String? branchId;
  double amount;
  String method; // v12: 'cash' | 'card' (which wallet this settles)
  String status; // 'pending' | 'approved' | 'rejected'
  String? requestedAt;
  String? decidedAt;
  String? decidedBy;
  String? note;
  String? createdAt;

  Settlement({
    required this.id,
    this.accountantId,
    this.branchId,
    required this.amount,
    this.method = 'cash',
    this.status = 'pending',
    this.requestedAt,
    this.decidedAt,
    this.decidedBy,
    this.note,
    this.createdAt,
  });

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved';
  bool get isRejected => status == 'rejected';

  Map<String, dynamic> toMap() => {
        'id': id,
        'accountant_id': accountantId,
        'branch_id': branchId,
        'amount': amount,
        'method': method,
        'status': status,
        'requested_at': requestedAt,
        'decided_at': decidedAt,
        'decided_by': decidedBy,
        'note': note,
        'created_at': createdAt,
        // Per-row edit time for conflict resolution (owner approve wins by time).
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  factory Settlement.fromMap(Map<String, dynamic> map) => Settlement(
        id: map['id'],
        accountantId: map['accountant_id'],
        branchId: map['branch_id'],
        amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
        method: (map['method'] ?? 'cash').toString(),
        status: (map['status'] ?? 'pending').toString(),
        requestedAt: map['requested_at'],
        decidedAt: map['decided_at'],
        decidedBy: map['decided_by'],
        note: map['note'],
        createdAt: map['created_at'],
      );
}
