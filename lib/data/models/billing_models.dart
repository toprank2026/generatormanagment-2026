class MonthlyPrice {
  String month; // YYYY-MM
  double pricePerAmp;
  int locked; // 0 or 1
  String? createdAt;

  MonthlyPrice({
    required this.month,
    required this.pricePerAmp,
    this.locked = 0,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'month': month,
      'price_per_amp': pricePerAmp,
      'locked': locked,
      'created_at': createdAt,
    };
  }

  factory MonthlyPrice.fromMap(Map<String, dynamic> map) {
    return MonthlyPrice(
      month: map['month'],
      pricePerAmp: map['price_per_amp'],
      locked: map['locked'] ?? 0,
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
      performedByUserId: map['performed_by_user_id'],
      issuedAt: map['issued_at'],
      status: map['status'],
      qrToken: map['qr_token'],
    );
  }
}
