import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:sqflite/sqflite.dart';

/// Thrown by controllers when a subscriber create/edit breaks a business rule
/// (R7 socket already in use, R8 duplicate name). [messageKey] is a translation
/// key the UI shows. Enforced at the app layer only (the raw sync-pull path
/// writes server rows directly and must not be blocked).
class ValidationException implements Exception {
  final String messageKey;
  final String? arg;
  ValidationException(this.messageKey, {this.arg});
  @override
  String toString() => messageKey;
}

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

  /// R1: does another board (other than [exceptId]) in the same branch already
  /// use [name] (case-insensitive, trimmed)? Legacy NULL branch maps to Main.
  Future<bool> nameExists(String name,
      {String? branchId, String? exceptId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['TRIM(name) = ? COLLATE NOCASE'];
    final args = <dynamic>[name.trim()];
    if (branchId != null) {
      clauses.add("IFNULL(branch_id, '${DbHelper.kMainBranchId}') = ?");
      args.add(branchId);
    }
    if (exceptId != null) {
      clauses.add('id != ?');
      args.add(exceptId);
    }
    final n = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM boards WHERE ${clauses.join(' AND ')}',
          args,
        )) ??
        0;
    return n > 0;
  }

  /// COUNT of boards in scope (no row hydration) — for the dashboard.
  Future<int> countByBranch({String? accountantId, String? branchId}) async {
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
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM boards $where', args)) ??
        0;
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

  /// COUNT of circuits in the active branch (no row hydration, no N+1 over
  /// boards) — for the dashboard.
  Future<int> countByBranch({String? accountantId, String? branchId}) async {
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
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    return Sqflite.firstIntValue(
            await db.rawQuery('SELECT COUNT(*) FROM circuits $where', args)) ??
        0;
  }

  /// R1: does another circuit (other than [exceptId]) under the SAME board
  /// already use [name] (case-insensitive, trimmed)? Feed names are unique per
  /// board. Branch is also matched (legacy NULL → Main) for full isolation.
  Future<bool> nameExists(String name, String boardId,
      {String? branchId, String? exceptId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>[
      'board_id = ?',
      'TRIM(name) = ? COLLATE NOCASE',
    ];
    final args = <dynamic>[boardId, name.trim()];
    if (branchId != null) {
      clauses.add("IFNULL(branch_id, '${DbHelper.kMainBranchId}') = ?");
      args.add(branchId);
    }
    if (exceptId != null) {
      clauses.add('id != ?');
      args.add(exceptId);
    }
    final n = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM circuits WHERE ${clauses.join(' AND ')}',
          args,
        )) ??
        0;
    return n > 0;
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

  Future<Subscriber?> getById(String id) async {
    final db = await _dbHelper.database;
    final m =
        await db.query('subscribers', where: 'id = ?', whereArgs: [id], limit: 1);
    return m.isEmpty ? null : Subscriber.fromMap(m.first);
  }

  /// R5/R7: is [circuitId] already held by an ACTIVE subscriber (other than
  /// [exceptId]) in the same branch? Branch-scoped so a circuit can be reused
  /// across branches but is exclusive within one.
  Future<bool> isCircuitTaken(String circuitId,
      {String? branchId, String? exceptId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['circuit_id = ?', "status = 'active'"];
    final args = <dynamic>[circuitId];
    if (branchId != null) {
      clauses.add("IFNULL(branch_id, '${DbHelper.kMainBranchId}') = ?");
      args.add(branchId);
    }
    if (exceptId != null) {
      clauses.add('id != ?');
      args.add(exceptId);
    }
    final n = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM subscribers WHERE ${clauses.join(' AND ')}',
          args,
        )) ??
        0;
    return n > 0;
  }

  /// R8: does another subscriber (other than [exceptId]) in the same branch
  /// already use [name] (case-insensitive, trimmed)?
  Future<bool> nameExists(String name,
      {String? branchId, String? exceptId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['TRIM(name) = ? COLLATE NOCASE'];
    final args = <dynamic>[name.trim()];
    if (branchId != null) {
      clauses.add("IFNULL(branch_id, '${DbHelper.kMainBranchId}') = ?");
      args.add(branchId);
    }
    if (exceptId != null) {
      clauses.add('id != ?');
      args.add(exceptId);
    }
    final n = Sqflite.firstIntValue(await db.rawQuery(
          'SELECT COUNT(*) FROM subscribers WHERE ${clauses.join(' AND ')}',
          args,
        )) ??
        0;
    return n > 0;
  }

  /// Circuit ids in [branchId] that already have an active subscriber — used to
  /// grey-out/hide taken sockets in the add/edit picker (R5).
  Future<Set<String>> takenCircuitIds({String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>["status = 'active'"];
    final args = <dynamic>[];
    if (branchId != null) {
      clauses.add("IFNULL(branch_id, '${DbHelper.kMainBranchId}') = ?");
      args.add(branchId);
    }
    final rows = await db.rawQuery(
      'SELECT DISTINCT circuit_id FROM subscribers WHERE ${clauses.join(' AND ')}',
      args.isEmpty ? null : args,
    );
    return rows.map((r) => r['circuit_id'] as String).toSet();
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
    String? category,
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
    // R5: category-tab filter (null = all categories). Legacy NULL category
    // rows behave as 'standard'.
    if (category != null) {
      clauses.add("IFNULL(category, 'standard') = ?");
      args.add(category);
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

  /// Subscribers whose paid total for [month] is >= (paid) or < (unpaid) their
  /// expected due. Due is **category-aware** (R4): each subscriber's expected =
  /// amps × the price for ITS category that month/branch, via a join to
  /// monthly_prices. A (month,branch,category) with NO price row is NOT yet
  /// billable, so its subscribers are counted UNPAID (not paid) — matching the
  /// v7 spec "all subscribers start unpaid for the new month" (audit fix). An
  /// explicit price of 0 still counts as paid (owes nothing).
  /// Shared FROM/JOIN/WHERE (+ positional args) for the paid/unpaid query, so the
  /// row fetch and the COUNT use identical logic. The returned [sql] begins at
  /// `FROM subscribers s ...`. Arg order follows the `?` placeholders:
  ///   inner receipts: month [, branch]   mp join: month
  ///   outer: [accountant] [branch] [category]
  ({String sql, List<dynamic> args}) _paymentStatusFrom({
    required String month,
    required bool isPaid,
    String? accountantId,
    String? branchId,
    String? category,
  }) {
    const main = DbHelper.kMainBranchId;
    final args = <dynamic>[month];
    // Receipts sub-query is branch-scoped (a shared subscriber id can carry
    // receipts in >1 branch — count only this branch's). null = all branches.
    final String innerScope = branchId == null ? '' : 'AND branch_id = ?';
    if (branchId != null) args.add(branchId);
    args.add(month); // monthly_prices join month
    final outerScopes = <String>[];
    if (accountantId != null) {
      outerScopes.add('AND s.accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      outerScopes.add('AND s.branch_id = ?');
      args.add(branchId);
    }
    // R5: category-tab filter (null = all). MUST stay last so the appended arg
    // matches this clause's position in the WHERE.
    if (category != null) {
      outerScopes.add("AND IFNULL(s.category, 'standard') = ?");
      args.add(category);
    }
    final String sql =
        """
      FROM subscribers s
      LEFT JOIN (
        SELECT subscriber_id,
               SUM(paid_amount) as total_paid,
               SUM(IFNULL(discount_value, 0)) as total_discount
        FROM receipts
        WHERE month = ? AND status = 'valid' $innerScope
        GROUP BY subscriber_id
      ) r ON s.id = r.subscriber_id
      LEFT JOIN monthly_prices mp
        ON mp.month = ?
        AND mp.category = IFNULL(s.category, 'standard')
        AND IFNULL(mp.branch_id, '$main') = IFNULL(s.branch_id, '$main')
      WHERE ${isPaid ? "mp.price_per_amp IS NOT NULL AND (COALESCE(r.total_paid, 0) + COALESCE(r.total_discount, 0)) >= (s.amps * mp.price_per_amp)" : "(mp.price_per_amp IS NULL OR (COALESCE(r.total_paid, 0) + COALESCE(r.total_discount, 0)) < (s.amps * mp.price_per_amp))"} ${outerScopes.join(' ')}
    """;
    return (sql: sql, args: args);
  }

  Future<List<Subscriber>> getByPaymentStatus({
    required String month,
    required bool isPaid,
    String? accountantId,
    String? branchId,
    String? category,
    int? limit,
    int? offset,
  }) async {
    final db = await _dbHelper.database;
    final q = _paymentStatusFrom(
      month: month,
      isPaid: isPaid,
      accountantId: accountantId,
      branchId: branchId,
      category: category,
    );
    final args = [...q.args];
    String tail = '';
    if (limit != null) {
      tail = ' LIMIT ?';
      args.add(limit);
      if (offset != null) {
        tail += ' OFFSET ?';
        args.add(offset);
      }
    }
    final maps = await db.rawQuery('SELECT s.* ${q.sql}$tail', args);
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  /// COUNT of paid/unpaid subscribers WITHOUT hydrating rows (was building and
  /// discarding the full List just for .length — twice per dashboard refresh).
  Future<int> countByPaymentStatus({
    required String month,
    required bool isPaid,
    String? accountantId,
    String? branchId,
    String? category,
  }) async {
    final db = await _dbHelper.database;
    final q = _paymentStatusFrom(
      month: month,
      isPaid: isPaid,
      accountantId: accountantId,
      branchId: branchId,
      category: category,
    );
    final r = await db.rawQuery('SELECT COUNT(*) as c ${q.sql}', q.args);
    return (r.isNotEmpty ? r.first['c'] as int? : 0) ?? 0;
  }

  /// COUNT of subscribers in scope (no row hydration) — for the dashboard.
  /// Scopes with plain `branch_id = ?` to match [getAll]/[getByPaymentStatus].
  Future<int> countByBranch({String? accountantId, String? branchId}) async {
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
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final r =
        await db.rawQuery('SELECT COUNT(*) as c FROM subscribers $where', args);
    return (r.isNotEmpty ? r.first['c'] as int? : 0) ?? 0;
  }

  /// Σ amps grouped by category (normalized) in scope — lets the dashboard
  /// compute expected = Σ ampsByCategory[c] × price[c] WITHOUT loading every row.
  Future<Map<String, double>> ampsByCategory(
      {String? accountantId, String? branchId}) async {
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
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = await db.rawQuery(
      "SELECT IFNULL(category,'standard') as cat, SUM(amps) as amps "
      "FROM subscribers $where GROUP BY IFNULL(category,'standard')",
      args,
    );
    final map = <String, double>{};
    for (final row in rows) {
      map[row['cat'] as String] = ((row['amps'] as num?) ?? 0).toDouble();
    }
    return map;
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
