class User {
  final String id;
  final String username;
  final String passwordHash;
  final String role; // 'admin' (owner) | 'accountant'
  // Human display name (printed on invoices / shown in UI). Falls back to the
  // username when null.
  final String? name;
  // Whether this local sub-user may sign in (owner can disable an accountant).
  final bool active;
  final String? createdAt;

  User({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.role,
    this.name,
    this.active = true,
    this.createdAt,
  });

  /// Best display label for printing / UI (name if set, else username).
  String get displayName => (name != null && name!.trim().isNotEmpty)
      ? name!.trim()
      : username;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'password_hash': passwordHash,
      'role': role,
      'name': name,
      'active': active ? 1 : 0,
      'created_at': createdAt,
    };
  }

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      id: map['id'],
      username: map['username'],
      passwordHash: map['password_hash'],
      role: map['role'],
      name: map['name'],
      active: (map['active'] ?? 1) == 1,
      createdAt: map['created_at'],
    );
  }
}
