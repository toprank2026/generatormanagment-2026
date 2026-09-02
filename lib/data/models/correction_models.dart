// v43: corrections after invoicing — the two NEW synced tables that let a
// closed (invoiced / settled) month be corrected without ever editing an
// existing row.
//
// Deliberately a pair of new tables, never new columns on `subscribers`,
// `receipts`, `monthly_prices` or `settlements`: `SyncService.pull` writes
// with `ConflictAlgorithm.replace` (INSERT OR REPLACE = delete + insert), so
// a column an older device does not know about would be reset ACCOUNT-WIDE on
// every device's next pull. Lock state stays DERIVED, never stored.

/// Lifecycle of a correction request (stored lowercase, like every other status
/// in this codebase, for sync simplicity).
///
/// `pending -> approved | rejected`, and for a DECREASE the approved request
/// continues `approved -> refundDue -> completed`: approving a correction and
/// physically returning the cash are two separate, separately-recorded steps.
class CorrectionStatus {
  CorrectionStatus._();
  static const String pending = 'pending';
  static const String approved = 'approved';
  static const String rejected = 'rejected';
  static const String refundDue = 'refund_due'; // decrease approved, cash not returned yet
  static const String completed = 'completed'; // cash physically returned
  // v44: a decrease's credit was applied to the NEXT month's due instead of
  // being refunded in cash. Terminal, like `completed`.
  static const String carriedForward = 'carried_forward';
  static const List<String> all = [
    pending,
    approved,
    rejected,
    refundDue,
    completed,
    carriedForward, // v44
  ];

  /// Normalize an arbitrary/legacy value to a valid status (default pending).
  static String normalize(String? v) => all.contains(v) ? v! : pending;
}

/// The kind of an immutable financial adjustment row.
class AdjustmentKind {
  AdjustmentKind._();

  /// The corrected month owes MORE than was invoiced. v44: the difference is a
  /// RECEIVABLE — it is added to that month's DUE (the customer is unpaid for
  /// it) and credits NO wallet; the cash arrives through an ordinary receipt.
  static const String increase = 'correction_increase';

  /// The corrected month owes LESS than was invoiced. Recorded for the audit
  /// trail; the wallet is NOT reduced (it must never be driven negative) — the
  /// correction moves to `refund_due` instead.
  static const String decrease = 'correction_decrease';

  /// The physical cash return that settles a `refund_due` correction.
  static const String refundReturn = 'refund_return';
  // v44: a decrease's credit applied to a LATER month. `month` on the row is
  // the month the credit REDUCES (the target), not the corrected month; it
  // contributes 0 to every wallet figure and -amount to that month's due.
  static const String creditApplied = 'credit_applied';

  static const List<String> all = [
    increase,
    decrease,
    refundReturn,
    creditApplied, // v44
  ];

  /// Normalize an arbitrary/legacy value to a valid kind (default increase).
  static String normalize(String? v) => all.contains(v) ? v! : increase;
}

/// A request to correct a subscriber's billing basis for ONE already-invoiced
/// (or already-settled) month, plus the owner/admin decision on it.
///
/// It is an audit document: it records what the month WAS (`oldAmps`/`oldDue`)
/// and what it should be (`newAmps`/`newDue`) — the original receipt, the
/// settlement and the subscriber row are never rewritten. `month` is the
/// TARIFF/accounting month ('YYYY-MM'): invoice month = accounting month =
/// settlement month = correction month, and a correction never affects another.
class Correction {
  String id;
  String? subscriberId;
  String? month; // 'YYYY-MM' — the tariff/accounting month being corrected
  String? branchId;
  String? accountantId;
  String? receiptUuid; // the invoice that locked the month, if any
  String? settlementId; // the settlement that locked the month, if any
  String? reason;
  double? oldAmps;
  double? newAmps;
  double? oldDue;
  double? newDue;

  /// newDue − oldDue. Positive = the month was under-invoiced (increase);
  /// negative = over-invoiced (decrease -> refund).
  double difference;
  String status;
  String? requestedBy;
  String? requestedAt;
  String? decidedBy;
  String? decidedAt;
  String? decisionNote;

  /// When the physical cash return was recorded (decrease flow only).
  String? refundPaidAt;
  String? refundPaidBy;
  String? createdAt;

  Correction({
    required this.id,
    this.subscriberId,
    this.month,
    this.branchId,
    this.accountantId,
    this.receiptUuid,
    this.settlementId,
    this.reason,
    this.oldAmps,
    this.newAmps,
    this.oldDue,
    this.newDue,
    this.difference = 0,
    this.status = CorrectionStatus.pending,
    this.requestedBy,
    this.requestedAt,
    this.decidedBy,
    this.decidedAt,
    this.decisionNote,
    this.refundPaidAt,
    this.refundPaidBy,
    this.createdAt,
  });

  /// True when the corrected month owes MORE than it was invoiced for — the
  /// branch of the flow that credits the wallet. Everything else (difference
  /// <= 0) is the decrease/refund branch, which never reduces the wallet.
  bool get isIncrease => difference > 0;

  bool get isPending => status == CorrectionStatus.pending;
  bool get isApproved => status == CorrectionStatus.approved;
  bool get isRejected => status == CorrectionStatus.rejected;
  bool get isRefundDue => status == CorrectionStatus.refundDue;
  bool get isCompleted => status == CorrectionStatus.completed;
  bool get isCarriedForward => status == CorrectionStatus.carriedForward;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'subscriber_id': subscriberId,
      'month': month,
      'branch_id': branchId,
      'accountant_id': accountantId,
      'receipt_uuid': receiptUuid,
      'settlement_id': settlementId,
      'reason': reason,
      'old_amps': oldAmps,
      'new_amps': newAmps,
      'old_due': oldDue,
      'new_due': newDue,
      'difference': difference,
      'status': status,
      'requested_by': requestedBy,
      'requested_at': requestedAt,
      'decided_by': decidedBy,
      'decided_at': decidedAt,
      'decision_note': decisionNote,
      'refund_paid_at': refundPaidAt,
      'refund_paid_by': refundPaidBy,
      'created_at': createdAt,
      // Per-row edit time for conflict resolution — the server applies
      // last-EDIT-wins, so the owner's decision beats a stale device copy.
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  factory Correction.fromMap(Map<String, dynamic> map) {
    return Correction(
      id: map['id'],
      subscriberId: map['subscriber_id'],
      month: map['month'],
      branchId: map['branch_id'],
      accountantId: map['accountant_id'],
      receiptUuid: map['receipt_uuid'],
      settlementId: map['settlement_id'],
      reason: map['reason'],
      oldAmps: (map['old_amps'] as num?)?.toDouble(),
      newAmps: (map['new_amps'] as num?)?.toDouble(),
      oldDue: (map['old_due'] as num?)?.toDouble(),
      newDue: (map['new_due'] as num?)?.toDouble(),
      difference: (map['difference'] as num?)?.toDouble() ?? 0.0,
      status: CorrectionStatus.normalize(map['status'] as String?),
      requestedBy: map['requested_by'],
      requestedAt: map['requested_at'],
      decidedBy: map['decided_by'],
      decidedAt: map['decided_at'],
      decisionNote: map['decision_note'],
      refundPaidAt: map['refund_paid_at'],
      refundPaidBy: map['refund_paid_by'],
      createdAt: map['created_at'],
    );
  }
}

/// An immutable signed money delta for one subscriber-month — the audit trail.
///
/// APPEND-ONLY: a row is written ONCE (at approval, or when the physical cash
/// return is recorded) and is NEVER updated and NEVER deleted, by anyone — no
/// code path, no repository method, no admin action. It is the only
/// append-only financial record this system has; correcting a mistake means
/// appending another adjustment, never editing this one.
///
/// It is deliberately NOT a row in `receipts`: `receipt_no` is NOT NULL and
/// allocated MAX+1 per branch, so an adjustment would consume a real invoice
/// number, and the `status='valid'` filter would either hide the delta from
/// ~20 money queries or inject a phantom invoice into printed history.
///
/// `month` is the TARIFF/accounting month ('YYYY-MM') the delta belongs to —
/// the same bucket the receipt and the settlement use, so a correction can
/// never move money between months. `amount` is folded into exactly the
/// wallet/revenue aggregates enumerated in `specs/flash-v43/plan.md` (Phase 5)
/// and into nothing else — never the paid/unpaid derivation, coverage, a
/// printed receipt, or `receipt_no` allocation.
class FinancialAdjustment {
  String id;

  /// The `corrections.id` this delta was written for.
  String? correctionId;
  String? subscriberId;
  String? month; // 'YYYY-MM' — tariff/accounting month
  String? branchId;

  /// Whose wallet this delta lands in — the accountant of the corrected month.
  String? accountantId;
  String kind; // AdjustmentKind.*
  double amount;
  String method; // 'cash' | 'card' — which wallet, mirroring settlements
  String? createdAt;
  String? createdBy;

  FinancialAdjustment({
    required this.id,
    this.correctionId,
    this.subscriberId,
    this.month,
    this.branchId,
    this.accountantId,
    this.kind = AdjustmentKind.increase,
    required this.amount,
    this.method = 'cash',
    this.createdAt,
    this.createdBy,
  });

  bool get isIncrease => kind == AdjustmentKind.increase;
  bool get isDecrease => kind == AdjustmentKind.decrease;
  bool get isRefundReturn => kind == AdjustmentKind.refundReturn;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'correction_id': correctionId,
      'subscriber_id': subscriberId,
      'month': month,
      'branch_id': branchId,
      'accountant_id': accountantId,
      'kind': kind,
      'amount': amount,
      'method': method,
      'created_at': createdAt,
      'created_by': createdBy,
      // Stamped for the sync conflict resolver only. The row is APPEND-ONLY:
      // it is inserted once and never edited, so this never changes in practice.
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    };
  }

  factory FinancialAdjustment.fromMap(Map<String, dynamic> map) {
    return FinancialAdjustment(
      id: map['id'],
      correctionId: map['correction_id'],
      subscriberId: map['subscriber_id'],
      month: map['month'],
      branchId: map['branch_id'],
      accountantId: map['accountant_id'],
      kind: AdjustmentKind.normalize(map['kind'] as String?),
      amount: (map['amount'] as num?)?.toDouble() ?? 0.0,
      method: (map['method'] ?? 'cash').toString(),
      createdAt: map['created_at'],
      createdBy: map['created_by'],
    );
  }
}
