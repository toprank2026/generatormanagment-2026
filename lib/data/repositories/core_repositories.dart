import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:sqflite/sqflite.dart';

// Per-accountant scoping convention used across these repositories:
//   accountantId == null  -> owner/admin view: no filter (sees & owns all).
//   accountantId != null  -> only rows whose accountant_id matches.
// The acting layer (AuthController.scopeAccountantId) decides which to pass.
//
// Per-branch scoping (full-isolation, additive) composes with the above:
//   branchId == null  -> consolidated / All branches (no branch filter).
//   branchId != null  -> only rows whose branch_id matches the active branch.
// The branch layer (BranchController.scopeBranchId) decides which to pass.
// Boards/circuits/subscribers are SHARED across accountants WITHIN a branch, so
// in practice they are scoped by branch only (accountantId stays null); receipts
// and expenses are scoped by BOTH branch and accountant.

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
  /// circuits, subscribers and their receipts so no orphan rows remain. When
  /// [accountantId] is given (an accountant), only that accountant's own rows
  /// are touched — never another accountant's data under the same board.
  /// Branch scoping isn't needed here: ids are globally-unique UUIDs, so a
  /// board (and its children) already belong to exactly one branch.
  Future<int> delete(String id, {String? accountantId}) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      if (accountantId == null) {
        await txn.delete(
          'receipts',
          where:
              'subscriber_id IN (SELECT id FROM subscribers WHERE board_id = ?)',
          whereArgs: [id],
        );
        await txn.delete('subscribers', where: 'board_id = ?', whereArgs: [id]);
        await txn.delete('circuits', where: 'board_id = ?', whereArgs: [id]);
        return await txn.delete('boards', where: 'id = ?', whereArgs: [id]);
      }
      await txn.delete(
        'receipts',
        where:
            'subscriber_id IN (SELECT id FROM subscribers WHERE board_id = ? AND accountant_id = ?) AND accountant_id = ?',
        whereArgs: [id, accountantId, accountantId],
      );
      await txn.delete('subscribers',
          where: 'board_id = ? AND accountant_id = ?',
          whereArgs: [id, accountantId]);
      await txn.delete('circuits',
          where: 'board_id = ? AND accountant_id = ?',
          whereArgs: [id, accountantId]);
      return await txn.delete('boards',
          where: 'id = ? AND accountant_id = ?', whereArgs: [id, accountantId]);
    });
  }

  Future<List<Board>> getAll(
      {int limit = -1,
      int offset = 0,
      String? accountantId,
      String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>[];
    final args = <dynamic>[];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps = await db.query(
      'boards',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
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
  Future<int> delete(String id, {String? accountantId}) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      if (accountantId == null) {
        await txn.delete(
          'receipts',
          where:
              'subscriber_id IN (SELECT id FROM subscribers WHERE circuit_id = ?)',
          whereArgs: [id],
        );
        await txn.delete('subscribers',
            where: 'circuit_id = ?', whereArgs: [id]);
        return await txn.delete('circuits', where: 'id = ?', whereArgs: [id]);
      }
      await txn.delete(
        'receipts',
        where:
            'subscriber_id IN (SELECT id FROM subscribers WHERE circuit_id = ? AND accountant_id = ?) AND accountant_id = ?',
        whereArgs: [id, accountantId, accountantId],
      );
      await txn.delete('subscribers',
          where: 'circuit_id = ? AND accountant_id = ?',
          whereArgs: [id, accountantId]);
      return await txn.delete('circuits',
          where: 'id = ? AND accountant_id = ?', whereArgs: [id, accountantId]);
    });
  }

  Future<List<Circuit>> getByBoardId(
    String boardId, {
    int limit = -1,
    int offset = 0,
    String? accountantId,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final clauses = <String>['board_id = ?'];
    final args = <dynamic>[boardId];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps = await db.query(
      'circuits',
      where: clauses.join(' AND '),
      whereArgs: args,
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
  Future<int> delete(String id, {String? accountantId}) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      // Only delete a subscriber the caller owns (accountant) or any (owner).
      final guard = accountantId == null ? '' : ' AND accountant_id = ?';
      final ownArgs = accountantId == null ? [id] : [id, accountantId];
      await txn.delete(
        'refunds',
        where:
            'receipt_uuid IN (SELECT uuid FROM receipts WHERE subscriber_id = ?)',
        whereArgs: [id],
      );
      await txn.delete('receipts', where: 'subscriber_id = ?', whereArgs: [id]);
      return await txn
          .delete('subscribers', where: 'id = ?$guard', whereArgs: ownArgs);
    });
  }

  Future<List<Subscriber>> getAll({
    int limit = 20,
    int offset = 0,
    String? query,
    String? accountantId,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;

    final clauses = <String>[];
    final args = <dynamic>[];
    if (query != null && query.isNotEmpty) {
      clauses.add('(name LIKE ? OR phone LIKE ?)');
      args.addAll(['%$query%', '%$query%']);
    }
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }

    final List<Map<String, dynamic>> maps = await db.query(
      'subscribers',
      where: clauses.isEmpty ? null : clauses.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'name ASC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByCircuit(String circuitId,
      {String? accountantId, String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['circuit_id = ?'];
    final args = <dynamic>[circuitId];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps =
        await db.query('subscribers', where: clauses.join(' AND '), whereArgs: args);
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByBoard(String boardId,
      {String? accountantId, String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['board_id = ?'];
    final args = <dynamic>[boardId];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps =
        await db.query('subscribers', where: clauses.join(' AND '), whereArgs: args);
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByPaymentStatus({
    required String month,
    required double pricePerAmp,
    required bool isPaid,
    String? accountantId,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    // We use a raw query to join with aggregated receipts. Args are assembled in
    // the exact textual order of the `?` placeholders below:
    //   inner: month [, branch_id]   then   outer: pricePerAmp [, s.accountant_id] [, s.branch_id]
    final String operator = isPaid ? '>=' : '<';
    final args = <dynamic>[month];
    // The receipts sub-query is branch-scoped too: a shared subscriber id can
    // carry receipts in more than one branch, so the paid total must count only
    // the active branch's receipts (full isolation). null = all branches.
    final String innerScope = branchId == null ? '' : 'AND branch_id = ?';
    if (branchId != null) args.add(branchId);
    args.add(pricePerAmp);
    final outerScopes = <String>[];
    if (accountantId != null) {
      outerScopes.add('AND s.accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      outerScopes.add('AND s.branch_id = ?');
      args.add(branchId);
    }

    final String sql =
        """
      SELECT s.* FROM subscribers s
      LEFT JOIN (
        SELECT subscriber_id, SUM(paid_amount) as total_paid
        FROM receipts
        WHERE month = ? AND status = 'valid' $innerScope
        GROUP BY subscriber_id
      ) r ON s.id = r.subscriber_id
      WHERE COALESCE(r.total_paid, 0) $operator (s.amps * ?) ${outerScopes.join(' ')}
    """;

    final List<Map<String, dynamic>> maps = await db.rawQuery(sql, args);
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<int> countByPaymentStatus({
    required String month,
    required double pricePerAmp,
    required bool isPaid,
    String? accountantId,
    String? branchId,
  }) async {
    final list = await getByPaymentStatus(
      month: month,
      pricePerAmp: pricePerAmp,
      isPaid: isPaid,
      accountantId: accountantId,
      branchId: branchId,
    );
    return list.length;
  }

  Future<int> countByBoard(String boardId,
      {String? accountantId, String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['board_id = ?'];
    final args = <dynamic>[boardId];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM subscribers WHERE ${clauses.join(' AND ')}',
            args,
          ),
        ) ??
        0;
  }

  Future<int> countByCircuit(String circuitId,
      {String? accountantId, String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['circuit_id = ?'];
    final args = <dynamic>[circuitId];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM subscribers WHERE ${clauses.join(' AND ')}',
            args,
          ),
        ) ??
        0;
  }
}
