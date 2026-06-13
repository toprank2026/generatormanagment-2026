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

  Future<List<Receipt>> getBySubscriber(
    String subscriberId, {
    required int limit,
    required int offset,
  }) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: 'subscriber_id = ?',
      whereArgs: [subscriberId],
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
  // optional limit/offset for pagination.
  Future<List<Receipt>> getByMonth(String month, {int? limit, int? offset}) async {
    final db = await _dbHelper.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'receipts',
      where: 'month = ?',
      whereArgs: [month],
      orderBy: 'issued_at DESC',
      limit: limit,
      offset: offset,
    );
    return List.generate(maps.length, (i) => Receipt.fromMap(maps[i]));
  }

  // Get total collected amount for a specific month. Only 'valid' receipts
  // count, matching the paid/unpaid status query — so a refunded receipt never
  // inflates the collected total.
  Future<double> getCollectedSum(String month) async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery(
      "SELECT SUM(paid_amount) as total FROM receipts WHERE month = ? AND status = 'valid'",
      [month],
    );
    if (result.isNotEmpty && result.first['total'] != null) {
      return (result.first['total'] as num).toDouble();
    }
    return 0.0;
  }
}
