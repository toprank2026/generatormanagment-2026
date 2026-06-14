import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/accountant_model.dart';
import 'package:generatormanagment/data/models/user_model.dart';

/// Owner-managed accountant sub-users.
///
/// Each accountant is stored in TWO places, kept consistent here:
///  - `users`        — local credentials (password hash) for OFFLINE login; NOT synced.
///  - `accountants`  — server-visible identity (id/username/name/active); synced
///                     so the admin panel can list/count/filter and invoices
///                     resolve the name on any device.
/// Both rows share the same `id`, which is the value stamped onto every business
/// record's `accountant_id`.
class AccountantRepository {
  final DbHelper _dbHelper = DbHelper();

  static String hashPassword(String password) =>
      sha256.convert(utf8.encode(password)).toString();

  /// Create a new accountant (writes the credential + identity rows atomically).
  Future<void> create({
    required String id,
    required String username,
    required String name,
    required String password,
    bool active = true,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      await txn.insert(
        'users',
        {
          'id': id,
          'username': username,
          'password_hash': hashPassword(password),
          'role': 'accountant',
          'name': name,
          'active': active ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      await txn.insert(
        'accountants',
        {
          'id': id,
          'username': username,
          'name': name,
          'active': active ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  /// Update name / active, and optionally reset the password.
  Future<void> update({
    required String id,
    String? name,
    bool? active,
    String? newPassword,
  }) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      final userValues = <String, dynamic>{};
      if (name != null) userValues['name'] = name;
      if (active != null) userValues['active'] = active ? 1 : 0;
      if (newPassword != null && newPassword.isNotEmpty) {
        userValues['password_hash'] = hashPassword(newPassword);
      }
      if (userValues.isNotEmpty) {
        await txn.update('users', userValues, where: 'id = ?', whereArgs: [id]);
      }
      final idValues = <String, dynamic>{};
      if (name != null) idValues['name'] = name;
      if (active != null) idValues['active'] = active ? 1 : 0;
      if (idValues.isNotEmpty) {
        await txn
            .update('accountants', idValues, where: 'id = ?', whereArgs: [id]);
      }
    });
  }

  /// Delete both rows. (Business records keep their accountant_id; the owner
  /// still sees them and they read as belonging to a removed accountant.)
  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.transaction((txn) async {
      await txn.delete('users', where: 'id = ?', whereArgs: [id]);
      await txn.delete('accountants', where: 'id = ?', whereArgs: [id]);
    });
  }

  /// Verify a local accountant login (offline). Returns the user on success.
  Future<User?> authenticate(String username, String password) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'users',
      where: 'username = ? AND role = ?',
      whereArgs: [username, 'accountant'],
    );
    if (rows.isEmpty) return null;
    final user = User.fromMap(rows.first);
    if (!user.active) return null;
    if (user.passwordHash != hashPassword(password)) return null;
    return user;
  }

  Future<List<Accountant>> getAll({int? limit, int? offset}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'accountants',
      orderBy: 'name COLLATE NOCASE ASC, username COLLATE NOCASE ASC',
      limit: limit,
      offset: offset,
    );
    return maps.map(Accountant.fromMap).toList();
  }

  Future<Accountant?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps =
        await db.query('accountants', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Accountant.fromMap(maps.first);
  }

  Future<int> count() async {
    final db = await _dbHelper.database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM accountants'),
        ) ??
        0;
  }
}
