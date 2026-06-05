import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/user_model.dart';
import 'package:sqflite/sqflite.dart';

class UserRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<int> insertUser(User user) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'users',
      user.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<User?> getUserByUsername(String username) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'users',
      where: 'username = ?',
      whereArgs: [username],
    );

    if (maps.isNotEmpty) {
      return User.fromMap(maps.first);
    }
    return null;
  }

  Future<User?> getUserById(String id) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (maps.isNotEmpty) {
      return User.fromMap(maps.first);
    }
    return null;
  }

  Future<List<User>> getAllUsers({int? limit, int? offset}) async {
    final db = await _dbHelper.database;
    // Stable ordering so pagination is deterministic across pages.
    final List<Map<String, dynamic>> maps = await db.query(
      'users',
      orderBy: 'username COLLATE NOCASE ASC, id ASC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => User.fromMap(maps[i]));
  }

  Future<int> countUsers() async {
    final db = await _dbHelper.database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM users'),
        ) ??
        0;
  }

  Future<void> deleteUser(String id) async {
    final db = await _dbHelper.database;
    await db.delete('users', where: 'id = ?', whereArgs: [id]);
  }
}
