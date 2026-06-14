class Board {
  String id;
  String name;
  String? code;
  // Assigned accountant (NULL = owner-owned). Set by the owner; drives
  // per-accountant visibility.
  String? accountantId;
  String? createdAt;

  Board({
    required this.id,
    required this.name,
    this.code,
    this.accountantId,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'code': code,
      'accountant_id': accountantId,
      'created_at': createdAt,
    };
  }

  factory Board.fromMap(Map<String, dynamic> map) {
    return Board(
      id: map['id'],
      name: map['name'],
      code: map['code'],
      accountantId: map['accountant_id'],
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

  Circuit({
    required this.id,
    required this.boardId,
    required this.name,
    this.phase,
    this.accountantId,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'board_id': boardId,
      'name': name,
      'phase': phase,
      'accountant_id': accountantId,
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
      createdAt: map['created_at'],
    );
  }
}

class Subscriber {
  String id;
  String name;
  String? phone;
  double amps;
  String boardId;
  String circuitId;
  String status;
  String? accountantId;
  String? createdAt;

  Subscriber({
    required this.id,
    required this.name,
    this.phone,
    required this.amps,
    required this.boardId,
    required this.circuitId,
    this.status = 'active',
    this.accountantId,
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
      'accountant_id': accountantId,
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
      accountantId: map['accountant_id'],
      createdAt: map['created_at'],
    );
  }
}
