import 'package:sqflite/sqflite.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';

/// v11: accountant wallet. The balance is DERIVED from the local tables —
/// Σ(cash collected by the accountant on valid receipts) − Σ(approved
/// settlement amounts) — never a stored counter (consistent with paid/unpaid).
class SettlementRepository {
  final DbHelper _dbHelper = DbHelper();

  Future<void> insert(Settlement s) async {
    final db = await _dbHelper.database;
    await db.insert('settlements', s.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Wallet figures for [accountantId]: total collected cash, total settled
  /// (approved), and the current balance (collected − settled).
  Future<({double collected, double settled, double balance})> wallet(
      String accountantId) async {
    final db = await _dbHelper.database;
    final cr = await db.rawQuery(
      "SELECT COALESCE(SUM(paid_amount),0) s FROM receipts "
      "WHERE accountant_id = ? AND status = 'valid'",
      [accountantId],
    );
    final collected = ((cr.first['s'] as num?) ?? 0).toDouble();
    final sr = await db.rawQuery(
      "SELECT COALESCE(SUM(amount),0) s FROM settlements "
      "WHERE accountant_id = ? AND status = 'approved'",
      [accountantId],
    );
    final settled = ((sr.first['s'] as num?) ?? 0).toDouble();
    return (collected: collected, settled: settled, balance: collected - settled);
  }

  /// True when the accountant already has an outstanding (pending) request —
  /// used to block duplicate settlement requests.
  Future<bool> hasPending(String accountantId) async {
    final db = await _dbHelper.database;
    final r = await db.rawQuery(
      "SELECT COUNT(*) c FROM settlements WHERE accountant_id = ? AND status = 'pending'",
      [accountantId],
    );
    return (Sqflite.firstIntValue(r) ?? 0) > 0;
  }

  /// Paginated settlement history for [accountantId], newest first.
  Future<List<Settlement>> history(String accountantId,
      {required int limit, required int offset}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'settlements',
      where: 'accountant_id = ?',
      whereArgs: [accountantId],
      orderBy: 'requested_at DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => Settlement.fromMap(m)).toList();
  }
}
