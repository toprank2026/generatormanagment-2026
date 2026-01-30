class Board {
  String id;
  String name;
  String? code;
  String? createdAt;

  Board({required this.id, required this.name, this.code, this.createdAt});

  Map<String, dynamic> toMap() {
    return {'id': id, 'name': name, 'code': code, 'created_at': createdAt};
  }

  factory Board.fromMap(Map<String, dynamic> map) {
    return Board(
      id: map['id'],
      name: map['name'],
      code: map['code'],
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

  Circuit({
    required this.id,
    required this.boardId,
    required this.name,
    this.phase,
    this.createdAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'board_id': boardId,
      'name': name,
      'phase': phase,
      'created_at': createdAt,
    };
  }

  factory Circuit.fromMap(Map<String, dynamic> map) {
    return Circuit(
      id: map['id'],
      boardId: map['board_id'],
      name: map['name'],
      phase: map['phase'],
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
  String? createdAt;

  Subscriber({
    required this.id,
    required this.name,
    this.phone,
    required this.amps,
    required this.boardId,
    required this.circuitId,
    this.status = 'active',
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
      createdAt: map['created_at'],
    );
  }
}
