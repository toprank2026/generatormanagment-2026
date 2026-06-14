import 'package:generatormanagment/core/permissions.dart';

/// Server-visible accountant identity (synced via the `accountants` table).
///
/// This carries NO credentials — the password lives only in the local (un-synced)
/// `users` table. `id` is shared with the matching `users` row and is what every
/// business record's `accountant_id` points at, so attribution + the printed
/// invoice name resolve on any device and on the admin panel.
class Accountant {
  final String id;
  final String username;
  final String? name;
  final bool active;
  final Set<String> permissions;
  final String? createdAt;

  Accountant({
    required this.id,
    required this.username,
    this.name,
    this.active = true,
    Set<String>? permissions,
    this.createdAt,
  }) : permissions = permissions ?? <String>{};

  String get displayName =>
      (name != null && name!.trim().isNotEmpty) ? name!.trim() : username;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'username': username,
      'name': name,
      'active': active ? 1 : 0,
      'permissions': Perm.encode(permissions),
      'created_at': createdAt,
    };
  }

  factory Accountant.fromMap(Map<String, dynamic> map) {
    return Accountant(
      id: map['id'],
      username: map['username'],
      name: map['name'],
      active: (map['active'] ?? 1) == 1,
      permissions: Perm.parse(map['permissions'] as String?),
      createdAt: map['created_at'],
    );
  }
}
