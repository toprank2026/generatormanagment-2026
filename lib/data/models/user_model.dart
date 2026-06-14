import 'package:generatormanagment/core/permissions.dart';

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
  // Granted permission keys (see Perm). Empty = collect+print only.
  final Set<String> permissions;
  final String? createdAt;

  User({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.role,
    this.name,
    this.active = true,
    Set<String>? permissions,
    this.createdAt,
  }) : permissions = permissions ?? <String>{};

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
      'permissions': Perm.encode(permissions),
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
      permissions: Perm.parse(map['permissions'] as String?),
      createdAt: map['created_at'],
    );
  }
}
