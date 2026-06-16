class Board {
  String id;
  String name;
  String? code;
  // Assigned accountant (NULL = owner-owned). Set by the owner; drives
  // per-accountant visibility.
  String? accountantId;
  // Owning branch (full-isolation partition). NULL = Main Branch (legacy).
  String? branchId;
  String? createdAt;

  Board({
    required this.id,
    required this.name,
    this.code,
    this.accountantId,
    this.branchId,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'code': code,
      'accountant_id': accountantId,
      'branch_id': branchId,
      'created_at': createdAt,
    };
  }

  factory Board.fromMap(Map<String, dynamic> map) {
    return Board(
      id: map['id'],
      name: map['name'],
      code: map['code'],
      accountantId: map['accountant_id'],
      branchId: map['branch_id'],
      createdAt: map['created_at'],
    );
  }
}

class Circuit {
  String id;
  String boardId;
  String name;
  String? phase;
  String? createdAt;

  String? accountantId;
  String? branchId;

  Circuit({
    required this.id,
    required this.boardId,
    required this.name,
    this.phase,
    this.accountantId,
    this.branchId,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'board_id': boardId,
      'name': name,
      'phase': phase,
      'accountant_id': accountantId,
      'branch_id': branchId,
      'created_at': createdAt,
    };
  }

  factory Circuit.fromMap(Map<String, dynamic> map) {
    return Circuit(
      id: map['id'],
      boardId: map['board_id'],
      name: map['name'],
      phase: map['phase'],
      accountantId: map['accountant_id'],
      branchId: map['branch_id'],
      createdAt: map['created_at'],
    );
  }
}

/// Subscriber pricing category (R4) — each is priced independently per month.
/// Stored as a lowercase string for sync simplicity.
class SubscriberCategory {
  SubscriberCategory._();
  static const String commercial = 'commercial'; // shops
  static const String standard = 'standard';
  static const String gold = 'gold'; // 24 hours
  static const List<String> all = [commercial, standard, gold];

  /// Normalize an arbitrary/legacy value to a valid category (default standard).
  static String normalize(String? v) =>
      all.contains(v) ? v! : standard;
}

class Subscriber {
  String id;
  String name;
  String? phone;
  double amps;
  String boardId;
  String circuitId;
  String status;
  // Pricing category (R4): commercial | standard | gold. Default standard so
  // legacy rows bill exactly as before until other categories are priced.
  String category;
  String? accountantId;
  String? branchId;
  String? createdAt;

  Subscriber({
    required this.id,
    required this.name,
    this.phone,
    required this.amps,
    required this.boardId,
    required this.circuitId,
    this.status = 'active',
    this.category = SubscriberCategory.standard,
    this.accountantId,
    this.branchId,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'amps': amps,
      'board_id': boardId,
      'circuit_id': circuitId,
      'status': status,
      'category': category,
      'accountant_id': accountantId,
      'branch_id': branchId,
      'created_at': createdAt,
    };
  }

  factory Subscriber.fromMap(Map<String, dynamic> map) {
    return Subscriber(
      id: map['id'],
      name: map['name'],
      phone: map['phone'],
      amps: map['amps'],
      boardId: map['board_id'],
      circuitId: map['circuit_id'],
      status: map['status'] ?? 'active',
      category: SubscriberCategory.normalize(map['category'] as String?),
      accountantId: map['accountant_id'],
      branchId: map['branch_id'],
      createdAt: map['created_at'],
    );
  }
}
