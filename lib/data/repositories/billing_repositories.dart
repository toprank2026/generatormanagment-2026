import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:sqflite/sqflite.dart';

class MonthlyPriceRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<int> insert(MonthlyPrice item) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'monthly_prices',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Price for a [month] in a given branch + [category] (R4: pricing varies per
  /// branch AND per category). [branchId] null = consolidated/legacy.
  Future<MonthlyPrice?> getByMonth(String month,
      {String? branchId, String category = 'standard'}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['month = ?', 'category = ?'];
    final args = <dynamic>[month, category];
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps = await db.query(
      'monthly_prices',
      where: clauses.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    if (maps.isNotEmpty) return MonthlyPrice.fromMap(maps.first);
    return null;
  }

  /// All category prices for a [month]/branch as {category: pricePerAmp} — used
  /// to compute category-aware expected totals without N+1 queries.
  Future<Map<String, double>> pricesForMonth(String month,
      {String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['month = ?'];
    final args = <dynamic>[month];
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final rows = await db.query('monthly_prices',
        where: clauses.join(' AND '), whereArgs: args);
    final map = <String, double>{};
    for (final r in rows) {
      final mp = MonthlyPrice.fromMap(r);
      map[mp.category] = mp.pricePerAmp;
    }
    return map;
  }
}

class ReceiptRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<int> insert(Receipt item) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'receipts',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Receipt history for a subscriber. Subscribers are shared across accountants,
  // but each accountant's HISTORY shows only the receipts THEY collected, so an
  // optional [accountantId] scopes the list (null = owner/admin = all). The
  // optional [branchId] further scopes to the active branch (full isolation).
  Future<List<Receipt>> getBySubscriber(
    String subscriberId, {
    required int limit,
    required int offset,
    String? accountantId,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final clauses = <String>['subscriber_id = ?'];
    final args = <dynamic>[subscriberId];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'issued_at DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Receipt.fromMap(maps[i]));
  }

  // Valid receipts for a subscriber in a month — drives the due calculation.
  // MUST be branch-scoped (full isolation): a shared subscriber id can carry
  // receipts under more than one branch, so an unscoped sum would let another
  // branch's payments reduce this branch's due. [branchId] null = all branches.
  Future<List<Receipt>> getBySubscriberAndMonth(
    String subscriberId,
    String month, {
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final clauses = <String>['subscriber_id = ?', 'month = ?', 'status = ?'];
    final args = <dynamic>[subscriberId, month, 'valid'];
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: clauses.join(' AND '),
      whereArgs: args,
    );
    return List.generate(maps.length, (i) => Receipt.fromMap(maps[i]));
  }

  // Get next receipt number. Numbering is INDEPENDENT per branch (D-3): the
  // sequence is MAX(receipt_no)+1 within the active branch, so each branch keeps
  // its own 1..N run. [branchId] null = global (consolidated/legacy).
  Future<int> getNextReceiptNumber({String? branchId}) async {
    final db = await _dbHelper.database;
    final where = branchId == null ? '' : 'WHERE branch_id = ?';
    final args = branchId == null ? <dynamic>[] : <dynamic>[branchId];
    final res = await db.rawQuery(
      "SELECT MAX(receipt_no) as max_no FROM receipts $where",
      args,
    );
    int max = (res.first['max_no'] as int?) ?? 0;
    return max + 1;
  }

  // Get receipts for a specific month, newest first (for reports), with
  // optional limit/offset for pagination. When [accountantId] is given, only
  // that accountant's receipts are returned (per-accountant reports); when
  // [branchId] is given, only that branch's receipts (full isolation).
  Future<List<Receipt>> getByMonth(String month,
      {int? limit, int? offset, String? accountantId, String? branchId}) async {
    final db = await _dbHelper.database;
    final clauses = <String>['month = ?'];
    final args = <dynamic>[month];
    if (accountantId != null) {
      clauses.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      clauses.add('branch_id = ?');
      args.add(branchId);
    }
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: clauses.join(' AND '),
      whereArgs: args,
      orderBy: 'issued_at DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Receipt.fromMap(maps[i]));
  }

  // Get total collected amount for a specific month. Only 'valid' receipts
  // count, matching the paid/unpaid status query — so a refunded receipt never
  // inflates the collected total. Optionally scoped to one accountant and/or
  // one branch.
  Future<double> getCollectedSum(String month,
      {String? accountantId, String? branchId}) async {
    final db = await _dbHelper.database;
    final scopes = <String>[];
    final args = <dynamic>[month];
    if (accountantId != null) {
      scopes.add('AND accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null) {
      scopes.add('AND branch_id = ?');
      args.add(branchId);
    }
    final result = await db.rawQuery(
      "SELECT SUM(paid_amount) as total FROM receipts WHERE month = ? AND status = 'valid' ${scopes.join(' ')}",
      args,
    );
    if (result.isNotEmpty && result.first['total'] != null) {
      return (result.first['total'] as num).toDouble();
    }
    return 0.0;
  }
}
