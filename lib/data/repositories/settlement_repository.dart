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
      // v39 item 1 (owner decision, overriding the v27 rule): the history is
      // STRICTLY month-isolated — a settlement appears only in its request
      // month, pending included. An out-of-month pending request is reached by
      // browsing to its month (the pending banner is month-scoped the same way).
      where.add("s.requested_at LIKE ?");
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

  /// v16: count of PENDING settlements (the admin screen's pending banner).
  /// v39 item 1: optional [month] scopes the count to the requests of that
  /// month (`requested_at` UTC prefix), matching the strictly month-isolated
  /// history list. Omitting it keeps the all-time count.
  Future<int> pendingCount({String? month}) async {
    final db = await _dbHelper.database;
    final bool scoped = month != null && month.isNotEmpty;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM settlements WHERE status = 'pending'"
            "${scoped ? " AND requested_at LIKE ?" : ""}",
            scoped ? ['$month%'] : null,
          ),
        ) ??
        0;
  }

  /// v39 item 3 — the MONTH-ISOLATED unsettled balance for one accountant:
  /// max(0, Σ cash actually received on the month's valid receipts −
  ///        Σ approved cash/card settlements REQUESTED in the month).
  /// Both sides are scoped to [month] (receipts by their billing `month`
  /// column, settlements by the `requested_at` UTC prefix), unlike [wallet]
  /// which is deliberately an all-time balance. Clamped at 0: money of this
  /// month settled in a LATER month keeps this month's figure at 0 or above,
  /// never negative. Legacy 'salary' settlements are excluded (not collection
  /// money), matching [approvedSumForMonth].
  Future<double> monthUnsettled(String accountantId, String month) async {
    final db = await _dbHelper.database;
    final c = await db.rawQuery(
      "SELECT COALESCE(SUM(paid_amount),0) s FROM receipts "
      "WHERE accountant_id = ? AND status = 'valid' AND month = ?",
      [accountantId, month],
    );
    final s = await db.rawQuery(
      "SELECT COALESCE(SUM(amount),0) s FROM settlements "
      "WHERE accountant_id = ? AND status = 'approved' "
      "AND COALESCE(method,'cash') IN ('cash','card') "
      "AND requested_at LIKE ?",
      [accountantId, '$month%'],
    );
    final double collected = ((c.first['s'] as num?) ?? 0).toDouble();
    final double settled = ((s.first['s'] as num?) ?? 0).toDouble();
    final double diff = collected - settled;
    return diff > 0 ? diff : 0;
  }

  // v35 item 12: the salary-wallet helpers (v27 approvedSum, v28
  // salaryStatusForMonth) were REMOVED with the salary wallet. Legacy 'salary'
  // rows remain readable through history()/listAllForOwner() and decidable
  // through decide() — only the request/summary paths are gone.

  /// v16: owner/admin decision on a settlement. Updates the LOCAL row
  /// (status + decided_at/by) and — because [Settlement.toMap] stamps a fresh
  /// `updated_at` — the sync triggers queue it so a `SyncController.poke()`
  /// pushes the decision to the mirror; the accountant then PULLS it. [status]
  /// is 'approved' | 'rejected'. (Offline-first: mirrors the Owner Panel, no
  /// direct API call.) v27 item 3: [amount], when given, is set on approval —
  /// used for salary settlements where the owner enters the amount at approval.
  /// Returns true when the decision was APPLIED; false when the request was no
  /// longer pending (raced/duplicate decision → no-op, v35 item 6).
  Future<bool> decide(Settlement s, String status,
      {String? decidedBy, double? amount}) async {
    final db = await _dbHelper.database;
    // v35 item 6 (idempotency): only a PENDING request may be decided — a
    // stale UI / double-tap / raced second decision must never overwrite an
    // already-approved/rejected settlement (re-approving could double-settle).
    final fresh = await db.query('settlements',
        columns: ['status'], where: 'id = ?', whereArgs: [s.id], limit: 1);
    if (fresh.isEmpty || (fresh.first['status'] as String?) != 'pending') {
      return false; // already decided (or gone) — callers reload and see it
    }
    s.status = status;
    if (amount != null) s.amount = amount;
    s.decidedAt = DateTime.now().toUtc().toIso8601String();
    if (decidedBy != null) s.decidedBy = decidedBy;
    await db.update('settlements', s.toMap(),
        where: 'id = ?', whereArgs: [s.id]);
    return true;
  }

  /// Paginated settlement history for [accountantId], newest first.
  /// v39 item 1: optional [month] restricts the history to that month's
  /// requests (`requested_at` UTC prefix) — used by the accountant's My Wallet
  /// so the list follows the globally selected pricing month.
  Future<List<Settlement>> history(String accountantId,
      {required int limit, required int offset, String? month}) async {
    final db = await _dbHelper.database;
    final bool scoped = month != null && month.isNotEmpty;
    final maps = await db.query(
      'settlements',
      where: 'accountant_id = ?${scoped ? " AND requested_at LIKE ?" : ""}',
      whereArgs: [accountantId, if (scoped) '$month%'],
      orderBy: 'requested_at DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => Settlement.fromMap(m)).toList();
  }
}
