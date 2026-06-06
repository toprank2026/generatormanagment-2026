import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:sqflite/sqflite.dart';

class BoardRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<int> insert(Board item) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'boards',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> update(Board item) async {
    final db = await _dbHelper.database;
    return await db.update(
      'boards',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  /// Cascades manually (SQLite FK enforcement is off): removes the board's
  /// circuits, subscribers and their receipts so no orphan rows remain.
  Future<int> delete(String id) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      await txn.delete(
        'receipts',
        where: 'subscriber_id IN (SELECT id FROM subscribers WHERE board_id = ?)',
        whereArgs: [id],
      );
      await txn.delete('subscribers', where: 'board_id = ?', whereArgs: [id]);
      await txn.delete('circuits', where: 'board_id = ?', whereArgs: [id]);
      return await txn.delete('boards', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Board>> getAll({int limit = -1, int offset = 0}) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'boards',
      orderBy: 'name ASC',
      limit: limit < 0 ? null : limit,
      offset: limit < 0 ? null : offset,
    );
    return List.generate(maps.length, (i) => Board.fromMap(maps[i]));
  }
}

class CircuitRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<int> insert(Circuit item) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'circuits',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> update(Circuit item) async {
    final db = await _dbHelper.database;
    return await db.update(
      'circuits',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  /// Cascades manually: removes the circuit's subscribers and their receipts.
  Future<int> delete(String id) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      await txn.delete(
        'receipts',
        where: 'subscriber_id IN (SELECT id FROM subscribers WHERE circuit_id = ?)',
        whereArgs: [id],
      );
      await txn.delete('subscribers', where: 'circuit_id = ?', whereArgs: [id]);
      return await txn.delete('circuits', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Circuit>> getByBoardId(
    String boardId, {
    int limit = -1,
    int offset = 0,
  }) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'circuits',
      where: 'board_id = ?',
      whereArgs: [boardId],
      orderBy: 'name ASC',
      limit: limit < 0 ? null : limit,
      offset: limit < 0 ? null : offset,
    );
    return List.generate(maps.length, (i) => Circuit.fromMap(maps[i]));
  }
}

class SubscriberRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<int> insert(Subscriber item) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'subscribers',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> update(Subscriber item) async {
    final db = await _dbHelper.database;
    return await db.update(
      'subscribers',
      item.toMap(),
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  /// Cascades manually: removes the subscriber's receipts (and their refunds).
  Future<int> delete(String id) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      await txn.delete(
        'refunds',
        where: 'receipt_uuid IN (SELECT uuid FROM receipts WHERE subscriber_id = ?)',
        whereArgs: [id],
      );
      await txn.delete('receipts', where: 'subscriber_id = ?', whereArgs: [id]);
      return await txn.delete('subscribers', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<List<Subscriber>> getAll({
    int limit = 20,
    int offset = 0,
    String? query,
  }) async {
    final db = await _dbHelper.database;

    String? whereClause;
    List<dynamic>? whereArgs;

    if (query != null && query.isNotEmpty) {
      whereClause = "name LIKE ? OR phone LIKE ?";
      whereArgs = ['%$query%', '%$query%'];
    }

    final List<Map<String, dynamic>> maps = await db.query(
      'subscribers',
      where: whereClause,
      whereArgs: whereArgs,
      orderBy: 'name ASC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByCircuit(String circuitId) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'subscribers',
      where: 'circuit_id = ?',
      whereArgs: [circuitId],
    );
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByBoard(String boardId) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'subscribers',
      where: 'board_id = ?',
      whereArgs: [boardId],
    );
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByPaymentStatus({
    required String month,
    required double pricePerAmp,
    required bool isPaid,
  }) async {
    final db = await _dbHelper.database;
    // We use a raw query to join with aggregated receipts
    final String operator = isPaid ? '>=' : '<';

    final String sql =
        """
      SELECT s.* FROM subscribers s
      LEFT JOIN (
        SELECT subscriber_id, SUM(paid_amount) as total_paid
        FROM receipts
        WHERE month = ? AND status = 'valid'
        GROUP BY subscriber_id
      ) r ON s.id = r.subscriber_id
      WHERE COALESCE(r.total_paid, 0) $operator (s.amps * ?)
    """;

    final List<Map<String, dynamic>> maps = await db.rawQuery(sql, [
      month,
      pricePerAmp,
    ]);
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<int> countByPaymentStatus({
    required String month,
    required double pricePerAmp,
    required bool isPaid,
  }) async {
    final list = await getByPaymentStatus(
      month: month,
      pricePerAmp: pricePerAmp,
      isPaid: isPaid,
    );
    return list.length;
  }

  Future<int> countByBoard(String boardId) async {
    final db = await _dbHelper.database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM subscribers WHERE board_id = ?',
            [boardId],
          ),
        ) ??
        0;
  }

  Future<int> countByCircuit(String circuitId) async {
    final db = await _dbHelper.database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM subscribers WHERE circuit_id = ?',
            [circuitId],
          ),
        ) ??
        0;
  }
}
