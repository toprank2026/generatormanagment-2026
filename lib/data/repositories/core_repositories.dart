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

  /// v27 item 7: board display name by id (printed receipt lookup). Additive.
  Future<String?> nameById(String id) async {
    final db = await _dbHelper.database;
    final m = await db.query('boards',
        columns: ['name'], where: 'id = ?', whereArgs: [id], limit: 1);
    return m.isEmpty ? null : m.first['name'] as String?;
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
      // v20/v42: ALWAYS show boards in CREATION order (oldest→newest), stable
      // for Arabic names. v42 item 6 replaced the old `created_at ASC, rowid
      // ASC` with the canonical [DbHelper.creationOrder] — rowid is DEVICE-LOCAL
      // and re-assigned in pull-arrival order, so legacy NULL-created_at boards
      // reordered after every sync. The UUID tie-break is identical on every
      // device, so the order is now fixed everywhere.
      orderBy: DbHelper.creationOrder(),
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

  /// v27 item 7: circuit display name by id (printed receipt lookup). Additive.
  Future<String?> nameById(String id) async {
    final db = await _dbHelper.database;
    final m = await db.query('circuits',
        columns: ['name'], where: 'id = ?', whereArgs: [id], limit: 1);
    return m.isEmpty ? null : m.first['name'] as String?;
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
      // v20: circuits (الجوزات) ALWAYS in CREATION order (oldest→newest), stable
      // across languages — created_at (set on insert), rowid tiebreaker for
      // legacy NULL rows. Replaces the unstable 'name ASC'.
      orderBy: DbHelper.creationOrder(),
      limit: limit < 0 ? null : limit,
      offset: limit < 0 ? null : offset,
    );
    return List.generate(maps.length, (i) => Circuit.fromMap(maps[i]));
  }

  /// v22 item 9: every circuit in scope (all boards) in ONE query — feeds the
  /// id→name map so subscriber rows can show their linked circuit (جوزة)
  /// without a per-row lookup.
  Future<List<Circuit>> getAllInBranch({String? branchId}) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'circuits',
      where: branchId == null ? null : 'branch_id = ?',
      whereArgs: branchId == null ? null : [branchId],
      orderBy: DbHelper.creationOrder(),
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
      // v22 item 5 / v42 item 6: subscribers ALWAYS in CREATION order
      // (oldest→newest), language-independent and DEVICE-INDEPENDENT — see
      // [DbHelper.creationOrder].
      orderBy: DbHelper.creationOrder(),
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByCircuit(String circuitId,
      {String? accountantId, String? branchId, String? query}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['circuit_id = ?'];
    final args = <dynamic>[circuitId];
    // v22 item 1: search composes with the circuit scope.
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
    final List<Map<String, dynamic>> maps = await db.query('subscribers',
        where: clauses.join(' AND '),
        whereArgs: args,
        // v22 item 5 / v42 item 6: canonical creation order.
        orderBy: DbHelper.creationOrder());
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  Future<List<Subscriber>> getByBoard(String boardId,
      {String? accountantId,
      String? branchId,
      String? query,
      int? limit,
      int? offset}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['board_id = ?'];
    final args = <dynamic>[boardId];
    // v22 item 1: search composes with the board scope.
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
    final List<Map<String, dynamic>> maps = await db.query('subscribers',
        where: clauses.join(' AND '),
        whereArgs: args,
        // v22 item 5 / v42 item 6: canonical creation order.
        orderBy: DbHelper.creationOrder(),
        // v23 item 7: paginate the board-scoped list (existing callers pass
        // neither → full result set as before).
        limit: limit,
        offset: (limit != null) ? offset : null);
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
  /// `FROM subscribers s ...`. Arg order follows the `?` placeholders EXACTLY
  /// (v22/v23 — keep in sync when editing):
  ///   inner receipts: month [, branch] [, receiptAccountant]   mp join: month
  ///   outer: [accountant] [branch] [category] [query ×2] activationMonth
  /// (v42 item 5 appends the always-present activation month LAST.)
  ({String sql, List<dynamic> args}) _paymentStatusFrom({
    required String month,
    required bool isPaid,
    String? accountantId,
    String? branchId,
    String? category,
    String? query,
    String? receiptAccountantId,
  }) {
    const main = DbHelper.kMainBranchId;
    final args = <dynamic>[month];
    // Receipts sub-query is branch-scoped (a shared subscriber id can carry
    // receipts in >1 branch — count only this branch's). null = all branches.
    // v22 item 6: receiptAccountantId additionally scopes the INNER receipts to
    // one COLLECTOR (receipts.accountant_id) — "paid" then means "collected by
    // that accountant" for the owner's per-accountant report. This is distinct
    // from [accountantId], which filters the OUTER s.accountant_id (subscriber
    // ownership — mostly NULL because subscribers are shared).
    String innerScope = branchId == null ? '' : 'AND branch_id = ?';
    if (branchId != null) args.add(branchId);
    if (receiptAccountantId != null) {
      innerScope += ' AND accountant_id = ?';
      args.add(receiptAccountantId);
    }
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
    // R5: category-tab filter. Order matters: each clause's arg is appended in
    // the same position as its `?` in the WHERE (category, then query, last).
    if (category != null) {
      outerScopes.add("AND IFNULL(s.category, 'standard') = ?");
      args.add(category);
    }
    // v22 item 1: search composes with the paid/unpaid filter.
    if (query != null && query.isNotEmpty) {
      outerScopes.add('AND (s.name LIKE ? OR s.phone LIKE ?)');
      args.addAll(['%$query%', '%$query%']);
    }
    // v42 item 5 — MONTH ONBOARDING. A subscriber is part of a month's billing
    // ONLY from the month it was added onwards: five subscribers added in month
    // 9 must NOT appear as unpaid in month 8 (which silently corrupted every
    // historical unpaid list, count and remaining-fees total).
    //
    // Two deliberate fallbacks make this safe on LIVE data:
    //  • COALESCE chain — a legacy row has no `billing_start_month`, so it falls
    //    back to its `created_at` prefix, and a row with no timestamp at all
    //    ('0000-00') is ALWAYS included. Nothing needed a backfill; no stored
    //    value was rewritten.
    //  • `OR r.subscriber_id IS NOT NULL` SAFETY VALVE — a subscriber that
    //    actually holds a valid receipt in this month stays visible in this
    //    month whatever its start stamp says, so no existing record can ever be
    //    orphaned or hidden by this filter.
    // Appended LAST so the positional-arg order above is unaffected.
    outerScopes.add(
      "AND (COALESCE(s.billing_start_month, "
      "substr(REPLACE(s.created_at, 'T', ' '), 1, 7), '0000-00') <= ? "
      "OR r.subscriber_id IS NOT NULL)",
    );
    args.add(month);
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
    String? query,
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
      query: query,
    );
    final args = [...q.args];
    // v22 item 5 / v42 item 6: canonical creation order (was unordered).
    String tail = ' ORDER BY ${DbHelper.creationOrder('s')}';
    if (limit != null) {
      tail += ' LIMIT ?';
      args.add(limit);
      if (offset != null) {
        tail += ' OFFSET ?';
        args.add(offset);
      }
    }
    final maps = await db.rawQuery('SELECT s.* ${q.sql}$tail', args);
    return List.generate(maps.length, (i) => Subscriber.fromMap(maps[i]));
  }

  /// v22 item 2: the ids of PAID subscribers for [month] in [branchId] — ONE
  /// query for the whole list (no per-row N+1), so every subscriber row can
  /// paint its green/red payment dot via `paidIds.contains(sub.id)`. Same
  /// category-aware derived-status SQL as [getByPaymentStatus].
  Future<Set<String>> paidSubscriberIds({
    required String month,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final q = _paymentStatusFrom(month: month, isPaid: true, branchId: branchId);
    final rows = await db.rawQuery('SELECT s.id ${q.sql}', q.args);
    return rows.map((r) => r['id'] as String).toSet();
  }

  /// v26 item 2: per-subscriber COVERAGE (cash + waived discount) for [month]
  /// in ONE grouped query — feeds the per-row "amount due" line in the
  /// subscriber lists without an N+1. Same coverage rule as
  /// [getByPaymentStatus] (valid receipts only, branch-scoped).
  Future<Map<String, double>> coverageBySubscriber({
    required String month,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final clauses = <String>['month = ?', "status = 'valid'"];
    final args = <dynamic>[month];
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final rows = await db.rawQuery(
      'SELECT subscriber_id, '
      'SUM(paid_amount) + SUM(IFNULL(discount_value, 0)) AS coverage '
      'FROM receipts WHERE ${clauses.join(' AND ')} GROUP BY subscriber_id',
      args,
    );
    final map = <String, double>{};
    for (final r in rows) {
      map[r['subscriber_id'] as String] =
          ((r['coverage'] as num?) ?? 0).toDouble();
    }
    return map;
  }

  /// v42 item 5: the ids of subscribers in scope that are NOT YET active in
  /// [month] — i.e. added in a LATER accounting month. Lets a list row paint a
  /// neutral dot instead of a false red "unpaid" for a subscriber that simply
  /// does not belong to the viewed month's billing yet.
  ///
  /// Mirrors the safety valve of [_paymentStatusFrom]: a subscriber holding a
  /// valid receipt in [month] is NEVER reported as inactive, so an existing
  /// record can never be mislabelled.
  Future<Set<String>> notYetActiveIds({
    required String month,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final clauses = <String>[
      "COALESCE(billing_start_month, "
          "substr(REPLACE(created_at, 'T', ' '), 1, 7), '0000-00') > ?",
      // `subscriber_id IS NOT NULL` is not cosmetic: in SQL, `x NOT IN (…)` is
      // NULL — i.e. matches NOTHING — as soon as the subquery yields a single
      // NULL. The column is NOT NULL in our schema, but a row written by the
      // raw sync-pull path bypasses the model, so this keeps one malformed
      // mirror row from silently emptying the whole result.
      "id NOT IN (SELECT subscriber_id FROM receipts "
          "WHERE month = ? AND status = 'valid' AND subscriber_id IS NOT NULL)",
    ];
    final args = <dynamic>[month, month];
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final rows = await db.rawQuery(
      'SELECT id FROM subscribers WHERE ${clauses.join(' AND ')}',
      args,
    );
    return rows.map((r) => r['id'] as String).toSet();
  }

  /// v42 item 3 — PREVIOUS OUTSTANDING MONTHS for one subscriber.
  ///
  /// Returns the months STRICTLY BEFORE [beforeMonth] in which this subscriber
  /// was already active, a price exists for its category/branch, and coverage
  /// (cash + waived discount on valid receipts) is still short of the due —
  /// newest first.
  ///
  /// **This is a NOTIFICATION source only.** Nothing else in the app reads it:
  /// no dashboard figure, no wallet, no settlement, no receipt and no
  /// paid/unpaid derivation. The current month's accounting therefore stays
  /// completely independent of previous months, exactly as required.
  ///
  /// Due uses the subscriber's CURRENT amps — the same rule
  /// [BillingController.getDueAmount] already applies, so the notice can never
  /// disagree with what that month's screen would show.
  Future<List<({String month, double due, double coverage, double remaining})>>
      previousUnpaidMonths(
    String subscriberId, {
    required String beforeMonth,
    String? branchId,
    int limit = 24,
  }) async {
    final db = await _dbHelper.database;
    const main = DbHelper.kMainBranchId;
    final String receiptBranch = branchId == null ? '' : 'AND branch_id = ?';
    final args = <dynamic>[beforeMonth, subscriberId];
    if (branchId != null) args.add(branchId);
    args.addAll([subscriberId, limit]);
    final rows = await db.rawQuery("""
      SELECT mp.month AS month,
             (s.amps * mp.price_per_amp) AS due,
             COALESCE(r.cov, 0) AS coverage
      FROM subscribers s
      JOIN monthly_prices mp
        ON mp.category = IFNULL(s.category, 'standard')
       AND IFNULL(mp.branch_id, '$main') = IFNULL(s.branch_id, '$main')
       AND mp.month < ?
       AND mp.month >= COALESCE(s.billing_start_month,
                                substr(REPLACE(s.created_at, 'T', ' '), 1, 7),
                                '0000-00')
      LEFT JOIN (
        SELECT month, SUM(paid_amount) + SUM(IFNULL(discount_value, 0)) AS cov
        FROM receipts
        WHERE subscriber_id = ? AND status = 'valid' $receiptBranch
        GROUP BY month
      ) r ON r.month = mp.month
      WHERE s.id = ?
        AND (s.amps * mp.price_per_amp) - COALESCE(r.cov, 0) > 0
        -- v42 review fix — NEVER accuse a paid-up subscriber. `SyncController`
        -- pulls receipts MONTH-SCOPED (`receiptsMonth`), so a device that has
        -- not held a past month's receipts locally sees zero coverage for it and
        -- would report EVERY earlier month as outstanding. A month is only
        -- claimed when this device actually holds receipt data for it; with no
        -- local evidence the month is skipped. A false "you owe nothing" is a
        -- far safer failure for a NOTICE than a false "you owe 12 months".
        AND EXISTS (SELECT 1 FROM receipts ev
                    WHERE ev.month = mp.month AND ev.status = 'valid')
      ORDER BY mp.month DESC
      LIMIT ?
    """, args);
    return rows.map((m) {
      final double due = ((m['due'] as num?) ?? 0).toDouble();
      final double cov = ((m['coverage'] as num?) ?? 0).toDouble();
      return (
        month: (m['month'] ?? '').toString(),
        due: due,
        coverage: cov,
        remaining: due - cov,
      );
    }).toList();
  }

  /// v22 item 10: paid/unpaid subscriber counts PER BOARD for [month] — one
  /// GROUP BY query for the whole boards grid (no per-board N+1). Same
  /// category-aware derived-status rule as [getByPaymentStatus]: paid = a price
  /// exists AND coverage (cash + discount) >= amps × price; everything else
  /// (including a missing price) is unpaid. Args follow the ? placeholders:
  /// inner receipts month [, branch], mp join month, [outer branch].
  Future<Map<String, ({int paid, int unpaid})>> paymentCountsByBoard({
    required String month,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    const main = DbHelper.kMainBranchId;
    final args = <dynamic>[month];
    final String innerScope = branchId == null ? '' : 'AND branch_id = ?';
    if (branchId != null) args.add(branchId);
    args.add(month); // monthly_prices join month
    // v42 item 5: the board grid counts only subscribers already active in the
    // month (same predicate + safety valve as _paymentStatusFrom).
    final String activation =
        "(COALESCE(s.billing_start_month, "
        "substr(REPLACE(s.created_at, 'T', ' '), 1, 7), '0000-00') <= ? "
        "OR r.subscriber_id IS NOT NULL)";
    final String outerScope = branchId == null
        ? 'WHERE $activation'
        : 'WHERE s.branch_id = ? AND $activation';
    if (branchId != null) args.add(branchId);
    args.add(month); // activation month (LAST — follows the ? order above)
    final rows = await db.rawQuery("""
      SELECT s.board_id AS bid,
             COUNT(*) AS total,
             SUM(CASE WHEN mp.price_per_amp IS NOT NULL
                       AND (COALESCE(r.total_paid, 0) + COALESCE(r.total_discount, 0))
                           >= (s.amps * mp.price_per_amp)
                 THEN 1 ELSE 0 END) AS paid
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
      $outerScope
      GROUP BY s.board_id
    """, args);
    final map = <String, ({int paid, int unpaid})>{};
    for (final row in rows) {
      final int total = (row['total'] as int?) ?? 0;
      final int paid = ((row['paid'] as num?) ?? 0).toInt();
      map[row['bid'] as String] = (paid: paid, unpaid: total - paid);
    }
    return map;
  }

  /// COUNT of paid/unpaid subscribers WITHOUT hydrating rows (was building and
  /// discarding the full List just for .length — twice per dashboard refresh).
  Future<int> countByPaymentStatus({
    required String month,
    required bool isPaid,
    String? accountantId,
    String? branchId,
    String? category,
    String? receiptAccountantId,
  }) async {
    final db = await _dbHelper.database;
    final q = _paymentStatusFrom(
      month: month,
      isPaid: isPaid,
      accountantId: accountantId,
      branchId: branchId,
      category: category,
      receiptAccountantId: receiptAccountantId,
    );
    final r = await db.rawQuery('SELECT COUNT(*) as c ${q.sql}', q.args);
    return (r.isNotEmpty ? r.first['c'] as int? : 0) ?? 0;
  }

  /// v33 (audit fix): the TRUE remaining fees for [month] — Σ over the UNPAID
  /// subscribers of (due − coverage), per subscriber, from the SAME derivation
  /// as the unpaid list/counts. Unlike `expected − collected − discounts`, this
  /// never NETS an overpayment (a subscriber whose coverage exceeds their
  /// current due after an amps/price change) against other subscribers' dues —
  /// so the remaining card always equals the sum of the unpaid list's
  /// "المبلغ الواجب تحصيله" rows exactly. Unpriced categories contribute 0
  /// (nothing billable yet), matching `expected`.
  Future<double> remainingFeesTotal({
    required String month,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final q =
        _paymentStatusFrom(month: month, isPaid: false, branchId: branchId);
    final r = await db.rawQuery(
      'SELECT SUM(MAX(s.amps * mp.price_per_amp '
      '- COALESCE(r.total_paid, 0) - COALESCE(r.total_discount, 0), 0)) AS rem '
      '${q.sql}',
      q.args,
    );
    return ((r.isNotEmpty ? r.first['rem'] as num? : 0) ?? 0).toDouble();
  }

  /// v32 item 1: Σ subscriber AMPS per category for the derived PAID or UNPAID
  /// set of [month] — the SAME category-aware coverage rule as
  /// [getByPaymentStatus]/[countByPaymentStatus], so the paid + unpaid amp
  /// totals partition [ampsByCategory] exactly (overall total stays accurate).
  Future<Map<String, double>> ampsByPaymentStatusCategory({
    required String month,
    required bool isPaid,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final q =
        _paymentStatusFrom(month: month, isPaid: isPaid, branchId: branchId);
    final rows = await db.rawQuery(
      "SELECT IFNULL(s.category, 'standard') AS cat, SUM(s.amps) AS amps "
      "${q.sql} GROUP BY IFNULL(s.category, 'standard')",
      q.args,
    );
    final map = <String, double>{};
    for (final r in rows) {
      map[r['cat'] as String] = ((r['amps'] as num?) ?? 0).toDouble();
    }
    return map;
  }

  /// v42 item 5: the "is this subscriber already active in [month]?" predicate
  /// for the SIMPLE (no receipts join) aggregates — subscriber count, Σ amps,
  /// per-branch amps.
  ///
  /// It carries the SAME two safeguards as [_paymentStatusFrom], so the two can
  /// never disagree about who belongs to a month:
  ///  • the COALESCE fallback chain (billing_start_month -> created_at prefix ->
  ///    '0000-00' = always included), so legacy rows keep their meaning;
  ///  • the receipts SAFETY VALVE, expressed here as an EXISTS sub-query because
  ///    these queries have no join to hang it on. Without it a subscriber who
  ///    PAID in the month would be counted by paid/unpaid (which has the valve)
  ///    while being dropped from the subscriber count, Σ amps and EXPECTED — so
  ///    `paid + unpaid` could exceed `totalSubscribers` on the same dashboard,
  ///    and that subscriber's cash would sit in `collected` with no matching due.
  ///
  /// Takes the month TWICE (the `<= ?` and the EXISTS `month = ?`), in that
  /// order — every caller must push it twice.
  static const String _activeInMonthSql =
      "(COALESCE(billing_start_month, "
      "substr(REPLACE(created_at, 'T', ' '), 1, 7), '0000-00') <= ? "
      "OR EXISTS (SELECT 1 FROM receipts rr WHERE rr.subscriber_id = subscribers.id "
      "AND rr.month = ? AND rr.status = 'valid'))";

  /// COUNT of subscribers in scope (no row hydration) — for the dashboard.
  /// Scopes with plain `branch_id = ?` to match [getAll]/[getByPaymentStatus].
  /// v42 item 5: passing [month] additionally counts only subscribers already
  /// active in that accounting month (omitting it keeps the all-time count).
  Future<int> countByBranch(
      {String? accountantId, String? branchId, String? month}) async {
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
    if (month != null && month.isNotEmpty) {
      clauses.add(_activeInMonthSql);
      args.add(month); // '<= ?'
      args.add(month); // EXISTS receipts month

    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final r =
        await db.rawQuery('SELECT COUNT(*) as c FROM subscribers $where', args);
    return (r.isNotEmpty ? r.first['c'] as int? : 0) ?? 0;
  }

  /// Σ amps grouped by category (normalized) in scope — lets the dashboard
  /// compute expected = Σ ampsByCategory[c] × price[c] WITHOUT loading every row.
  /// v42 item 5: [month] additionally restricts to subscribers already active
  /// in that accounting month (omitted = all-time, exactly as before).
  Future<Map<String, double>> ampsByCategory(
      {String? accountantId, String? branchId, String? month}) async {
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
    if (month != null && month.isNotEmpty) {
      clauses.add(_activeInMonthSql);
      args.add(month); // '<= ?'
      args.add(month); // EXISTS receipts month

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

  /// v23 item 1 (§2.3): Σ amps grouped by BRANCH and category (both normalized)
  /// — lets the CONSOLIDATED (All-branches) report compute expected per branch
  /// per category instead of collapsing every branch's prices into one map
  /// (last-row-wins bug). Returned as `{ branchKey: { category: amps } }` where
  /// branchKey normalizes a NULL branch_id to [DbHelper.kMainBranchId], matching
  /// [pricesForMonthByBranch]. Additive — never modify [ampsByCategory].
  /// v42 item 5: [month] additionally restricts to subscribers already active
  /// in that accounting month (omitted = all-time, exactly as before) — so the
  /// CONSOLIDATED report's "expected" for August never prices in a subscriber
  /// that was only added in September.
  Future<Map<String, Map<String, double>>> ampsByBranchCategory(
      {String? accountantId, String? month}) async {
    final db = await _dbHelper.database;
    final clauses = <String>[];
    final args = <dynamic>[];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (month != null && month.isNotEmpty) {
      clauses.add(_activeInMonthSql);
      args.add(month); // '<= ?'
      args.add(month); // EXISTS receipts month

    }
    final where = clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}';
    final rows = await db.rawQuery(
      "SELECT IFNULL(branch_id, '${DbHelper.kMainBranchId}') as br, "
      "IFNULL(category,'standard') as cat, SUM(amps) as amps "
      "FROM subscribers $where "
      "GROUP BY IFNULL(branch_id, '${DbHelper.kMainBranchId}'), "
      "IFNULL(category,'standard')",
      args.isEmpty ? null : args,
    );
    final map = <String, Map<String, double>>{};
    for (final row in rows) {
      final br = row['br'] as String;
      final cat = row['cat'] as String;
      (map[br] ??= <String, double>{})[cat] =
          ((row['amps'] as num?) ?? 0).toDouble();
    }
    return map;
  }

  /// v27 item 1: Σ amps of all subscribers on [boardId] (branch-scoped) — the
  /// board page's "total board amps" summary. One SQL SUM, additive.
  Future<double> sumAmpsByBoard(String boardId,
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
    final r = await db.rawQuery(
      'SELECT SUM(amps) AS s FROM subscribers WHERE ${clauses.join(' AND ')}',
      args,
    );
    return ((r.isNotEmpty ? r.first['s'] as num? : 0) ?? 0).toDouble();
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
