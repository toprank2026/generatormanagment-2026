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

  /// v30 (reversal lock): the NEWEST ACTIVE (pending|approved) settlement
  /// request time for [accountantId]+[method], or null when none exists. A
  /// receipt issued AT/BEFORE this moment had its cash included in that
  /// settlement's requested balance → it is locked against reversal. Receipts
  /// issued after the last request stay reversible. 'rejected' requests do NOT
  /// lock (the owner declined — the money never left the wallet).
  Future<String?> lastActiveRequestAt(String accountantId, String method) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      "SELECT requested_at FROM settlements WHERE accountant_id = ? "
      "AND COALESCE(method,'cash') = ? AND status IN ('pending','approved') "
      "ORDER BY requested_at DESC LIMIT 1",
      [accountantId, method],
    );
    return rows.isEmpty ? null : rows.first['requested_at'] as String?;
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
  /// v27 item 6: optional [month] ('YYYY-MM' → requested_at prefix) and
  /// [accountantId] filters (both additive; omitting them keeps the old
  /// all-time / all-accountants behavior exactly).
  Future<List<({Settlement settlement, String accountantName})>> listAllForOwner({
    int limit = 100,
    int offset = 0,
    String? month,
    String? accountantId,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>[];
    final args = <dynamic>[];
    if (month != null && month.isNotEmpty) {
      // v27 review: a month filter must NEVER hide a PENDING approval (a
      // pending request from another month would otherwise be silently missed).
      // Pending rows always surface; the summary banner stays month-scoped.
      where.add("(s.requested_at LIKE ? OR s.status = 'pending')");
      args.add('$month%');
    }
    if (accountantId != null && accountantId.isNotEmpty) {
      where.add("s.accountant_id = ?");
      args.add(accountantId);
    }
    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')} ';
    args.addAll([limit, offset]);
    final maps = await db.rawQuery(
      "SELECT s.*, COALESCE(NULLIF(a.name,''), a.username, '') AS _acct_name "
      "FROM settlements s "
      "LEFT JOIN accountants a ON a.id = s.accountant_id "
      "$whereSql"
      "ORDER BY CASE s.status WHEN 'pending' THEN 0 ELSE 1 END, "
      "s.requested_at DESC "
      "LIMIT ? OFFSET ?",
      args,
    );
    return maps
        .map((m) => (
              settlement: Settlement.fromMap(m),
              accountantName: (m['_acct_name'] ?? '').toString(),
            ))
        .toList();
  }

  /// v27 item 6: Σ APPROVED settlements of [method] in [month] (requested_at
  /// prefix), optionally scoped to one [accountantId]. Feeds the summary
  /// banner's "salary received" figure. Additive, read-only.
  /// NOTE: [month] matches the UTC `requested_at` prefix, so at a month boundary
  /// it can differ by a few hours from the local calendar month (banner-only;
  /// no stored balance / sync is affected).
  Future<double> approvedSumForMonth(String month, String method,
      {String? accountantId}) async {
    final db = await _dbHelper.database;
    final where = <String>[
      "status = 'approved'",
      "COALESCE(method,'cash') = ?",
      "requested_at LIKE ?",
    ];
    final args = <dynamic>[method, '$month%'];
    if (accountantId != null && accountantId.isNotEmpty) {
      where.add('accountant_id = ?');
      args.add(accountantId);
    }
    final r = await db.rawQuery(
      "SELECT SUM(amount) AS s FROM settlements WHERE ${where.join(' AND ')}",
      args,
    );
    return ((r.isNotEmpty ? r.first['s'] as num? : 0) ?? 0).toDouble();
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

  /// v27 item 3: Σ APPROVED settlement amounts of [method] for [accountantId]
  /// (the salary wallet's "received" figure + the settlement summary banner).
  /// Additive, read-only.
  Future<double> approvedSum(String accountantId, String method) async {
    final db = await _dbHelper.database;
    final r = await db.rawQuery(
      "SELECT SUM(amount) AS s FROM settlements "
      "WHERE accountant_id = ? AND status = 'approved' "
      "AND COALESCE(method,'cash') = ?",
      [accountantId, method],
    );
    return ((r.isNotEmpty ? r.first['s'] as num? : 0) ?? 0).toDouble();
  }

  /// v28 item 11: the status of THIS accountant's salary settlement for [month]
  /// (local `yyyy-MM`), or null when none exists. Enforces "one salary request
  /// per month": returns 'pending' or 'approved' to block a new request, and
  /// drives the "تم استلام الراتب" button state after approval. A 'rejected' row
  /// does NOT block (the owner declined it, so the month is still open).
  /// Additive, read-only.
  ///
  /// `requested_at` is stored UTC, but [month] is the accountant's LOCAL calendar
  /// month, so we parse each row to local time and compare there — otherwise a
  /// request made in the first local hours of a month (persisted under the
  /// PREVIOUS UTC month) would slip past a raw UTC-prefix match and a duplicate
  /// salary could be requested at the month boundary.
  Future<String?> salaryStatusForMonth(String accountantId, String month) async {
    final db = await _dbHelper.database;
    final rows = await db.rawQuery(
      "SELECT status, requested_at FROM settlements "
      "WHERE accountant_id = ? AND COALESCE(method,'cash') = 'salary' "
      "AND status IN ('pending','approved') "
      "ORDER BY requested_at DESC",
      [accountantId],
    );
    for (final r in rows) {
      final raw = r['requested_at'] as String?;
      if (raw == null) continue;
      final dt = DateTime.tryParse(raw);
      if (dt == null) continue;
      final local = dt.toLocal();
      final m = '${local.year.toString().padLeft(4, '0')}-'
          '${local.month.toString().padLeft(2, '0')}';
      if (m == month) return r['status'] as String?;
    }
    return null;
  }

  /// v16: owner/admin decision on a settlement. Updates the LOCAL row
  /// (status + decided_at/by) and — because [Settlement.toMap] stamps a fresh
  /// `updated_at` — the sync triggers queue it so a `SyncController.poke()`
  /// pushes the decision to the mirror; the accountant then PULLS it. [status]
  /// is 'approved' | 'rejected'. (Offline-first: mirrors the Owner Panel, no
  /// direct API call.) v27 item 3: [amount], when given, is set on approval —
  /// used for salary settlements where the owner enters the amount at approval.
  Future<void> decide(Settlement s, String status,
      {String? decidedBy, double? amount}) async {
    final db = await _dbHelper.database;
    s.status = status;
    if (amount != null) s.amount = amount;
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
