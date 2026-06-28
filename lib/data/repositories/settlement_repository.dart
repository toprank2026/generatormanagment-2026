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

  /// Per-method wallet figures for [accountantId] (v12: cash + card). For each
  /// method: collected = Σ that-method valid receipts; settled = Σ approved
  /// settlements of that method; balance = collected − settled. (Local
  /// fallback; the My Wallet page prefers the server-authoritative endpoint.)
  Future<
      ({
        double cashCollected,
        double cashSettled,
        double cashBalance,
        double cardCollected,
        double cardSettled,
        double cardBalance,
      })> wallet(String accountantId) async {
    final db = await _dbHelper.database;
    Future<double> collected(String m) async {
      final r = await db.rawQuery(
        "SELECT COALESCE(SUM(paid_amount),0) s FROM receipts "
        "WHERE accountant_id = ? AND status = 'valid' "
        "AND COALESCE(payment_method,'cash') = ?",
        [accountantId, m],
      );
      return ((r.first['s'] as num?) ?? 0).toDouble();
    }

    Future<double> settled(String m) async {
      final r = await db.rawQuery(
        "SELECT COALESCE(SUM(amount),0) s FROM settlements "
        "WHERE accountant_id = ? AND status = 'approved' "
        "AND COALESCE(method,'cash') = ?",
        [accountantId, m],
      );
      return ((r.first['s'] as num?) ?? 0).toDouble();
    }

    final cc = await collected('cash');
    final cs = await settled('cash');
    final dc = await collected('card');
    final ds = await settled('card');
    return (
      cashCollected: cc,
      cashSettled: cs,
      cashBalance: cc - cs,
      cardCollected: dc,
      cardSettled: ds,
      cardBalance: dc - ds,
    );
  }

  /// True when the accountant already has an outstanding (pending) request for
  /// the given [method] — blocks duplicate settlement requests per wallet.
  Future<bool> hasPending(String accountantId, String method) async {
    final db = await _dbHelper.database;
    final r = await db.rawQuery(
      "SELECT COUNT(*) c FROM settlements WHERE accountant_id = ? "
      "AND status = 'pending' AND COALESCE(method,'cash') = ?",
      [accountantId, method],
    );
    return (Sqflite.firstIntValue(r) ?? 0) > 0;
  }

  /// v16: ALL settlements (owner/admin view) with the accountant's display
  /// name, pending first then newest — backs the in-app settlement-approval
  /// screen (Admin-only). Read-only join; never mutates.
  Future<List<({Settlement settlement, String accountantName})>> listAllForOwner({
    int limit = 100,
    int offset = 0,
  }) async {
    final db = await _dbHelper.database;
    final maps = await db.rawQuery(
      "SELECT s.*, COALESCE(NULLIF(a.name,''), a.username, '') AS _acct_name "
      "FROM settlements s "
      "LEFT JOIN accountants a ON a.id = s.accountant_id "
      "ORDER BY CASE s.status WHEN 'pending' THEN 0 ELSE 1 END, "
      "s.requested_at DESC "
      "LIMIT ? OFFSET ?",
      [limit, offset],
    );
    return maps
        .map((m) => (
              settlement: Settlement.fromMap(m),
              accountantName: (m['_acct_name'] ?? '').toString(),
            ))
        .toList();
  }

  /// v16: count of PENDING settlements (Admin badge on the Settings tile).
  Future<int> pendingCount() async {
    final db = await _dbHelper.database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM settlements WHERE status = 'pending'",
          ),
        ) ??
        0;
  }

  /// v16: owner/admin decision on a settlement. Updates the LOCAL row
  /// (status + decided_at/by) and — because [Settlement.toMap] stamps a fresh
  /// `updated_at` — the sync triggers queue it so a `SyncController.poke()`
  /// pushes the decision to the mirror; the accountant then PULLS it. [status]
  /// is 'approved' | 'rejected'. (Offline-first: mirrors the Owner Panel, no
  /// direct API call.)
  Future<void> decide(Settlement s, String status, {String? decidedBy}) async {
    final db = await _dbHelper.database;
    s.status = status;
    s.decidedAt = DateTime.now().toUtc().toIso8601String();
    if (decidedBy != null) s.decidedBy = decidedBy;
    await db.update('settlements', s.toMap(),
        where: 'id = ?', whereArgs: [s.id]);
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
