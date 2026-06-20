class MonthlyPrice {
  String month; // YYYY-MM
  double pricePerAmp;
  int locked; // 0 or 1
  // Per-branch (v5) AND per-category (v6) pricing: the PK is a synthetic id
  // "<month>|<branchId>|<category>". Each category prices independently (R4).
  String? branchId;
  String category;
  String? createdAt;
  // Flash item 5: owner-chosen start DAY within the month (ISO yyyy-MM-dd).
  // Metadata only — billing stays month-based (no proration).
  String? startDate;

  MonthlyPrice({
    required this.month,
    required this.pricePerAmp,
    this.locked = 0,
    this.branchId,
    this.category = 'standard',
    this.createdAt,
    this.startDate,
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
      'start_date': startDate,
      'updated_at': DateTime.now().toUtc().toIso8601String(), // conflict resolution
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
      startDate: map['start_date'],
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
  // Discount (P5) — applied only on a FULL payment. type: 'none'|'ampere'|
  // 'value'. discountValue = IQD waived; discountAmps = amps waived (ampere
  // type). paidAmount is the CASH collected (due - discountValue on full pay).
  String discountType;
  double discountValue;
  double? discountAmps;
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
    this.discountType = 'none',
    this.discountValue = 0,
    this.discountAmps,
    this.performedByUserId,
    required this.issuedAt,
    this.status = 'valid',
    this.qrToken,
  });

  /// True when a discount was applied to this receipt (P5).
  bool get hasDiscount => discountType != 'none' && discountValue > 0;

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
      'discount_type': discountType,
      'discount_value': discountValue,
      'discount_amps': discountAmps,
      'performed_by_user_id': performedByUserId,
      'issued_at': issuedAt,
      'status': status,
      'qr_token': qrToken,
      'updated_at': DateTime.now().toUtc().toIso8601String(), // conflict resolution
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
      discountType: (map['discount_type'] ?? 'none').toString(),
      discountValue: (map['discount_value'] as num?)?.toDouble() ?? 0.0,
      discountAmps: (map['discount_amps'] as num?)?.toDouble(),
      performedByUserId: map['performed_by_user_id'],
      issuedAt: map['issued_at'],
      status: map['status'],
      qrToken: map['qr_token'],
    );
  }
}

String _fmtNum(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(0);

/// Arabic discount line for a PRINTED receipt (P5): shows the discount type +
/// value when one was applied, or "no discount". Shared by the Bluetooth and
/// PDF receipt renderers (the print path uses hardcoded Arabic, like the rest
/// of the receipt body).
String receiptDiscountText(Receipt r) {
  if (!r.hasDiscount) return 'لا يوجد خصم';
  if (r.discountType == 'ampere') {
    final a = r.discountAmps;
    final amps = a == null ? '' : ' (${_fmtNum(a)} أمبير)';
    return '${_fmtNum(r.discountValue)} د.ع$amps';
  }
  return '${_fmtNum(r.discountValue)} د.ع';
}
