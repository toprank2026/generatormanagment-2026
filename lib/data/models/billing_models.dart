class MonthlyPrice {
  String month; // YYYY-MM
  double pricePerAmp;
  int locked; // 0 or 1
  // Per-branch (v5) AND per-category (v6) pricing: the PK is a synthetic id
  // "<month>|<branchId>|<category>". Each category prices independently (R4).
  String? branchId;
  String category;
  String? createdAt;

  MonthlyPrice({
    required this.month,
    required this.pricePerAmp,
    this.locked = 0,
    this.branchId,
    this.category = 'standard',
    this.createdAt,
  });

  /// Synthetic per-branch, per-category primary key (table PK + sync localId).
  static String buildId(String month, String? branchId, String? category) =>
      '$month|${branchId ?? ''}|${category ?? 'standard'}';

  String get id => buildId(month, branchId, category);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'month': month,
      'price_per_amp': pricePerAmp,
      'locked': locked,
      'branch_id': branchId,
      'category': category,
      'created_at': createdAt,
    };
  }

  factory MonthlyPrice.fromMap(Map<String, dynamic> map) {
    return MonthlyPrice(
      month: map['month'],
      pricePerAmp: map['price_per_amp'],
      locked: map['locked'] ?? 0,
      branchId: map['branch_id'],
      category: (map['category'] as String?) ?? 'standard',
      createdAt: map['created_at'],
    );
  }
}

class Receipt {
  String uuid;
  int receiptNo;
  String subscriberId;
  String month;
  double ampsSnapshot;
  double priceSnapshot;
  double paidAmount;
  double remainingAfter;
  String? accountantId;
  String? branchId;
  // Subscriber category at collection time (R4 audit) — keeps historical
  // reports correct if the subscriber's category later changes.
  String? categorySnapshot;
  String? performedByUserId;
  String issuedAt;
  String status; // valid, refunded
  String? qrToken;

  Receipt({
    required this.uuid,
    required this.receiptNo,
    required this.subscriberId,
    required this.month,
    required this.ampsSnapshot,
    required this.priceSnapshot,
    required this.paidAmount,
    required this.remainingAfter,
    this.accountantId,
    this.branchId,
    this.categorySnapshot,
    this.performedByUserId,
    required this.issuedAt,
    this.status = 'valid',
    this.qrToken,
  });

  Map<String, dynamic> toMap() {
    return {
      'uuid': uuid,
      'receipt_no': receiptNo,
      'subscriber_id': subscriberId,
      'month': month,
      'amps_snapshot': ampsSnapshot,
      'price_snapshot': priceSnapshot,
      'paid_amount': paidAmount,
      'remaining_after': remainingAfter,
      'accountant_id': accountantId,
      'branch_id': branchId,
      'category_snapshot': categorySnapshot,
      'performed_by_user_id': performedByUserId,
      'issued_at': issuedAt,
      'status': status,
      'qr_token': qrToken,
    };
  }

  factory Receipt.fromMap(Map<String, dynamic> map) {
    return Receipt(
      uuid: map['uuid'],
      receiptNo: map['receipt_no'],
      subscriberId: map['subscriber_id'],
      month: map['month'],
      ampsSnapshot: map['amps_snapshot'],
      priceSnapshot: map['price_snapshot'],
      paidAmount: map['paid_amount'],
      remainingAfter: map['remaining_after'],
      accountantId: map['accountant_id'],
      branchId: map['branch_id'],
      categorySnapshot: map['category_snapshot'],
      performedByUserId: map['performed_by_user_id'],
      issuedAt: map['issued_at'],
      status: map['status'],
      qrToken: map['qr_token'],
    );
  }
}
