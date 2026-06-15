import 'package:sqflite/sqflite.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/branch_model.dart';

/// Owner-managed branches (org partitions). Synced via the generic engine
/// (whole-row push); no credentials. The Main Branch is created idempotently
/// with the fixed [DbHelper.kMainBranchId] so it is the same row across all of
/// an owner's devices and matches the v5 legacy backfill.
class BranchRepository {
  final DbHelper _dbHelper = DbHelper();

  /// Ensure the default Main Branch exists (idempotent — safe on every launch).
  Future<Branch> ensureMain() async {
    final db = await _dbHelper.database;
    final existing = await db.query('branches',
        where: 'id = ?', whereArgs: [DbHelper.kMainBranchId], limit: 1);
    if (existing.isNotEmpty) return Branch.fromMap(existing.first);
    await db.insert(
      'branches',
      {
        'id': DbHelper.kMainBranchId,
        'name': 'الفرع الرئيسي', // Main Branch
        'is_main': 1,
        'active': 1,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final row = await db.query('branches',
        where: 'id = ?', whereArgs: [DbHelper.kMainBranchId], limit: 1);
    return Branch.fromMap(row.first);
  }

  Future<void> create({
    required String id,
    required String name,
    String? code,
    bool active = true,
  }) async {
    final db = await _dbHelper.database;
    await db.insert(
      'branches',
      {
        'id': id,
        'name': name,
        'code': code,
        'is_main': 0,
        'active': active ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> update({
    required String id,
    String? name,
    String? code,
    bool? active,
  }) async {
    final db = await _dbHelper.database;
    final values = <String, dynamic>{};
    if (name != null) values['name'] = name;
    if (code != null) values['code'] = code;
    if (active != null) values['active'] = active ? 1 : 0;
    if (values.isEmpty) return;
    await db.update('branches', values, where: 'id = ?', whereArgs: [id]);
  }

  /// The Main Branch can never be deleted (it owns all legacy data).
  Future<void> delete(String id) async {
    if (id == DbHelper.kMainBranchId) return;
    final db = await _dbHelper.database;
    await db.delete('branches', where: 'id = ?', whereArgs: [id]);
  }

  Future<List<Branch>> getAll({bool activeOnly = false}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'branches',
      where: activeOnly ? 'active = 1' : null,
      orderBy: 'is_main DESC, name COLLATE NOCASE ASC',
    );
    return maps.map(Branch.fromMap).toList();
  }

  Future<Branch?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps =
        await db.query('branches', where: 'id = ?', whereArgs: [id], limit: 1);
    if (maps.isEmpty) return null;
    return Branch.fromMap(maps.first);
  }

  Future<int> count() async {
    final db = await _dbHelper.database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM branches'),
        ) ??
        0;
  }
}
