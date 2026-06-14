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

  Future<MonthlyPrice?> getByMonth(String month) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'monthly_prices',
      where: 'month = ?',
      whereArgs: [month],
    );
    if (maps.isNotEmpty) return MonthlyPrice.fromMap(maps.first);
    return null;
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
  // optional [accountantId] scopes the list (null = owner/admin = all).
  Future<List<Receipt>> getBySubscriber(
    String subscriberId, {
    required int limit,
    required int offset,
    String? accountantId,
  }) async {
    final db = await _dbHelper.database;
    final where = accountantId == null
        ? 'subscriber_id = ?'
        : 'subscriber_id = ? AND accountant_id = ?';
    final args =
        accountantId == null ? [subscriberId] : [subscriberId, accountantId];
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: where,
      whereArgs: args,
      orderBy: 'issued_at DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Receipt.fromMap(maps[i]));
  }

  Future<List<Receipt>> getBySubscriberAndMonth(
    String subscriberId,
    String month,
  ) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: 'subscriber_id = ? AND month = ? AND status = ?',
      whereArgs: [subscriberId, month, 'valid'],
    );
    return List.generate(maps.length, (i) => Receipt.fromMap(maps[i]));
  }

  // Get next receipt number
  Future<int> getNextReceiptNumber() async {
    final db = await _dbHelper.database;
    final res = await db.rawQuery(
      "SELECT MAX(receipt_no) as max_no FROM receipts",
    );
    int max = (res.first['max_no'] as int?) ?? 0;
    return max + 1;
  }

  // Get receipts for a specific month, newest first (for reports), with
  // optional limit/offset for pagination. When [accountantId] is given, only
  // that accountant's receipts are returned (per-accountant reports).
  Future<List<Receipt>> getByMonth(String month,
      {int? limit, int? offset, String? accountantId}) async {
    final db = await _dbHelper.database;
    final where =
        accountantId == null ? 'month = ?' : 'month = ? AND accountant_id = ?';
    final args = accountantId == null ? [month] : [month, accountantId];
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: where,
      whereArgs: args,
      orderBy: 'issued_at DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Receipt.fromMap(maps[i]));
  }

  // Get total collected amount for a specific month. Only 'valid' receipts
  // count, matching the paid/unpaid status query — so a refunded receipt never
  // inflates the collected total. Optionally scoped to one accountant.
  Future<double> getCollectedSum(String month, {String? accountantId}) async {
    final db = await _dbHelper.database;
    final scope = accountantId == null ? '' : 'AND accountant_id = ?';
    final args = accountantId == null ? [month] : [month, accountantId];
    final result = await db.rawQuery(
      "SELECT SUM(paid_amount) as total FROM receipts WHERE month = ? AND status = 'valid' $scope",
      args,
    );
    if (result.isNotEmpty && result.first['total'] != null) {
      return (result.first['total'] as num).toDouble();
    }
    return 0.0;
  }
}
