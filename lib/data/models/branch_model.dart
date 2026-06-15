import 'package:generatormanagment/data/db_helper.dart';

/// A branch (org partition) under the Owner organization. Synced like an
/// accountant identity. Full-isolation: every business row carries this `id` as
/// its `branch_id`, and a branch is the active *context*, not a filter on shared
/// data. The Main Branch (id == DbHelper.kMainBranchId) holds all legacy data.
class Branch {
  final String id;
  final String name;
  final String? code;
  final bool isMain;
  final bool active;
  final String? createdAt;

  Branch({
    required this.id,
    required this.name,
    this.code,
    this.isMain = false,
    this.active = true,
    this.createdAt,
  });

  bool get isMainBranch => isMain || id == DbHelper.kMainBranchId;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'code': code,
      'is_main': isMain ? 1 : 0,
      'active': active ? 1 : 0,
      'created_at': createdAt,
    };
  }

  factory Branch.fromMap(Map<String, dynamic> map) {
    return Branch(
      id: map['id'],
      name: map['name'] ?? '',
      code: map['code'],
      isMain: (map['is_main'] ?? 0) == 1,
      active: (map['active'] ?? 1) == 1,
      createdAt: map['created_at'],
    );
  }
}
