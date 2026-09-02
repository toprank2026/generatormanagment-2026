import 'package:sqflite/sqflite.dart';
import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/correction_models.dart';

/// v43: corrections after invoicing — the request document (`corrections`) and
/// the immutable money delta it produces (`financial_adjustments`).
///
/// Two rules shape every method below, and neither is a UI concern:
///
///  1. **Nothing already recorded is ever rewritten.** A correction is an audit
///     document beside the invoice: approving one writes an adjustment row, it
///     never edits the receipt, the settlement, the monthly price or the
///     subscriber. Lock state stays DERIVED (a valid receipt for the
///     subscriber-month / an active settlement for the month), never stored —
///     `SyncService.pull` writes `INSERT OR REPLACE`, so a stored lock column
///     would be reset account-wide by any older device's push.
///  2. **`financial_adjustments` is APPEND-ONLY.** See the banner above
///     [insertAdjustment]: this file deliberately contains NO update and NO
///     delete method for that table.
///
/// Month semantics are the v40 accounting rule the whole system already uses:
/// invoice month = accounting month = settlement month = correction month
/// (`'YYYY-MM'`), so a correction can never move money into another month.
class CorrectionRepository {
  final DbHelper _dbHelper = DbHelper();

  // ---------------------------------------------------------------------------
  // corrections — the request + its lifecycle
  // ---------------------------------------------------------------------------

  /// Files a correction request. The row is inserted as-is (the caller owns the
  /// UUID, the branch/accountant scope and the computed old/new/difference
  /// figures); the sync triggers queue it for the mirror.
  ///
  /// `created_at`/`requested_at` are stamped here when the caller left them
  /// null: sqflite writes an explicit NULL for a null map value, which would
  /// defeat the column DEFAULT and leave the row without the timestamp the
  /// history ordering and the panel both read. The stamped values are written
  /// back onto [c] so the caller keeps the same instance it inserted.
  Future<void> create(Correction c) async {
    final db = await _dbHelper.database;
    final String now = DateTime.now().toUtc().toIso8601String();
    c.createdAt ??= now;
    c.requestedAt ??= now;
    await db.insert('corrections', c.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Paginated correction list — **pending first, then newest**, mirroring
  /// `SettlementRepository.listAllForOwner` so the admin queue reads the same
  /// way in both screens. Every filter is additive and optional: omitting all of
  /// them lists the whole account.
  ///
  /// [status] is one of [CorrectionStatus.all] (`refund_due` is the useful
  /// filter for "cash still to be returned"); [month] is the tariff month being
  /// corrected, matched exactly on the stored column (a correction is always
  /// stamped with its accounting month at request time, so there is no legacy
  /// `requested_at` fallback to make here — unlike settlements).
  ///
  /// Ordering tie-breaks on the UUID `id` so LIMIT/OFFSET paging stays stable
  /// when several rows share a timestamp (`rowid` is device-local and is
  /// re-assigned by every pull, so it must never be an ordering key).
  Future<List<Correction>> list({
    String? status,
    String? month,
    String? subscriberId,
    String? branchId,
    required int limit,
    required int offset,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>[];
    final args = <dynamic>[];
    if (status != null && status.isNotEmpty) {
      where.add('status = ?');
      args.add(status);
    }
    if (month != null && month.isNotEmpty) {
      where.add('month = ?');
      args.add(month);
    }
    if (subscriberId != null && subscriberId.isNotEmpty) {
      where.add('subscriber_id = ?');
      args.add(subscriberId);
    }
    if (branchId != null && branchId.isNotEmpty) {
      where.add('branch_id = ?');
      args.add(branchId);
    }
    final maps = await db.query(
      'corrections',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: where.isEmpty ? null : args,
      orderBy: "CASE status WHEN 'pending' THEN 0 ELSE 1 END, "
          "COALESCE(requested_at, created_at, '') DESC, id DESC",
      limit: limit,
      offset: offset,
    );
    return maps.map((m) => Correction.fromMap(m)).toList();
  }

  /// One correction by id, or null when it is gone. Used before acting on a row
  /// held by a screen (the decision paths below re-read the status themselves).
  Future<Correction?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query('corrections',
        where: 'id = ?', whereArgs: [id], limit: 1);
    return maps.isEmpty ? null : Correction.fromMap(maps.first);
  }

  /// Owner/admin decision on a correction request: [status] is `approved`,
  /// `rejected`, or `refund_due` (the decrease branch — approved, but the cash
  /// has not been physically returned yet). Updates the LOCAL row (status +
  /// decided_at/by + note) and, because [Correction.toMap] stamps a fresh
  /// `updated_at`, the sync triggers queue the decision for the mirror.
  ///
  /// Idempotency guard, copied from `SettlementRepository.decide` (v35 item 6):
  /// **only a PENDING row may be decided.** A stale screen, a double-tap or a
  /// decision raced in from another device must never re-decide an already
  /// decided correction — re-approving would let the caller write a SECOND
  /// adjustment for the same delta and double-credit the wallet. The status is
  /// re-read from the DB inside the method, not trusted from [c].
  ///
  /// Returns true when the decision was APPLIED; false when the row was no
  /// longer pending (or gone) — callers reload and show the current state.
  /// `completed` is not a decision: it is reached only through
  /// [markRefundPaid], which records the physical cash return separately.
  Future<bool> decide(Correction c, String status,
      {String? decidedBy, String? note}) async {
    const allowed = [
      CorrectionStatus.approved,
      CorrectionStatus.rejected,
      CorrectionStatus.refundDue,
    ];
    if (!allowed.contains(status)) return false;
    final db = await _dbHelper.database;
    final fresh = await db.query('corrections',
        columns: ['status'], where: 'id = ?', whereArgs: [c.id], limit: 1);
    if (fresh.isEmpty ||
        (fresh.first['status'] as String?) != CorrectionStatus.pending) {
      return false; // already decided (or gone) — no-op, never a re-decision
    }
    c.status = status;
    c.decidedAt = DateTime.now().toUtc().toIso8601String();
    if (decidedBy != null) c.decidedBy = decidedBy;
    if (note != null) c.decisionNote = note;
    await db
        .update('corrections', c.toMap(), where: 'id = ?', whereArgs: [c.id]);
    return true;
  }

  /// Records the PHYSICAL cash return that closes a decrease correction:
  /// `refund_due -> completed`, stamping `refund_paid_at`/`refund_paid_by`.
  ///
  /// Approving a decrease and handing the money back are two separate,
  /// separately-recorded operations — approval alone never asserts that cash
  /// moved. Accordingly this transition is allowed **only from `refund_due`**:
  /// the status is re-read inside, so a double-tap or a raced second
  /// confirmation cannot re-stamp the payment (and, in the caller, cannot
  /// append a second `refund_return` adjustment for the same obligation).
  ///
  /// Returns true when applied; false when the row was not in `refund_due`
  /// (already completed, never approved, or gone).
  Future<bool> markRefundPaid(Correction c, {String? paidBy}) async {
    final db = await _dbHelper.database;
    final fresh = await db.query('corrections',
        columns: ['status'], where: 'id = ?', whereArgs: [c.id], limit: 1);
    if (fresh.isEmpty ||
        (fresh.first['status'] as String?) != CorrectionStatus.refundDue) {
      return false; // not awaiting a cash return — no-op
    }
    c.status = CorrectionStatus.completed;
    c.refundPaidAt = DateTime.now().toUtc().toIso8601String();
    if (paidBy != null) c.refundPaidBy = paidBy;
    await db
        .update('corrections', c.toMap(), where: 'id = ?', whereArgs: [c.id]);
    return true;
  }

  /// v44 — closes a decrease by CARRYING its credit FORWARD instead of
  /// returning cash: `refund_due -> carried_forward`. The caller then appends
  /// one `credit_applied` adjustment on the TARGET month, which reduces that
  /// month's due by the credit. Same guarded shape as [markRefundPaid], so a
  /// device that loses the race writes nothing.
  Future<bool> carryForward(Correction c, {String? by, String? note}) async {
    final db = await _dbHelper.database;
    final fresh = await db.query('corrections',
        columns: ['status'], where: 'id = ?', whereArgs: [c.id], limit: 1);
    if (fresh.isEmpty ||
        (fresh.first['status'] as String?) != CorrectionStatus.refundDue) {
      return false; // not holding a credit — no-op
    }
    c.status = CorrectionStatus.carriedForward;
    c.refundPaidAt = DateTime.now().toUtc().toIso8601String();
    if (by != null) c.refundPaidBy = by;
    if (note != null) c.decisionNote = note;
    await db
        .update('corrections', c.toMap(), where: 'id = ?', whereArgs: [c.id]);
    return true;
  }

  /// v44 review fix — compensating write used ONLY when the ledger insert
  /// that must follow a carry-forward fails: `carried_forward -> refund_due`,
  /// so the credit is still held on the correction instead of vanishing.
  Future<void> reopenRefundDue(Correction c) async {
    final db = await _dbHelper.database;
    c.status = CorrectionStatus.refundDue;
    c.refundPaidAt = null;
    c.refundPaidBy = null;
    await db
        .update('corrections', c.toMap(), where: 'id = ?', whereArgs: [c.id]);
  }

  // ---------------------------------------------------------------------------
  // financial_adjustments — the APPEND-ONLY ledger
  //
  // 🚨 THERE IS DELIBERATELY NO UPDATE AND NO DELETE METHOD FOR
  // `financial_adjustments` IN THIS FILE, AND NONE MAY EVER BE ADDED.
  // A row is written once and is never edited and never removed, by anyone —
  // no repository method, no controller, no admin action. Correcting a mistake
  // means APPENDING another adjustment, never rewriting this one. This is the
  // only append-only financial record the system has; it is what makes the
  // money path auditable.
  // ---------------------------------------------------------------------------

  /// Appends one immutable money delta. Written at approval (the correction
  /// delta) or when the physical cash return is recorded — never anywhere else.
  ///
  /// `ConflictAlgorithm.ignore` (not `replace`, which the other repositories
  /// use) is the append-only rule expressed in SQL: if a row with this id
  /// somehow already exists — a retried write, a re-delivered command — the
  /// STORED row wins and is left exactly as it was, instead of being deleted
  /// and re-inserted with new values. Ids are fresh UUIDs, so in practice this
  /// only ever fires on an exact retry.
  Future<void> insertAdjustment(FinancialAdjustment a) async {
    final db = await _dbHelper.database;
    a.createdAt ??= DateTime.now().toUtc().toIso8601String();
    await db.insert('financial_adjustments', a.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// The signed WALLET effect of the adjustments in one accounting [month] —
  /// the figure folded into `walletForMonth`, `wallet()`, `monthUnsettled` and
  /// the revenue sum, and into nothing else (never the paid/unpaid derivation,
  /// never coverage, never a printed receipt, never `receipt_no`).
  ///
  /// The sign rule, which IS the wallet-never-negative rule:
  ///
  ///  * `correction_increase` — counted **positively**, at its stored amount.
  ///    The month was under-invoiced, the extra cash is in the wallet, so an
  ///    additional settlement for the month becomes possible.
  ///  * `refund_return` — counted **positively**, at its stored amount (the
  ///    writer stamps the sign that expresses its wallet effect; this method
  ///    never re-signs a stored row).
  ///  * `correction_decrease` — contributes **exactly 0**. A decrease NEVER
  ///    reduces the wallet: an over-invoiced month becomes a `refund_due`
  ///    obligation on the correction, discharged by physically returning the
  ///    cash. Subtracting it here would let a historical correction drive an
  ///    accountant's wallet negative, which must never happen.
  ///
  /// An adjustment exists only because a correction was approved (or a refund
  /// recorded), so there is no status filter to apply — the row's existence is
  /// the approval. Every filter beyond [month] is optional and additive;
  /// [method] matches `COALESCE(method,'cash')`, the same expression the
  /// settlement wallet queries use.
  Future<double> adjustmentTotal({
    required String month,
    String? accountantId,
    String? branchId,
    String? method,
    String? subscriberId,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>['month = ?'];
    final args = <dynamic>[month];
    if (accountantId != null && accountantId.isNotEmpty) {
      where.add('accountant_id = ?');
      args.add(accountantId);
    }
    if (branchId != null && branchId.isNotEmpty) {
      where.add('branch_id = ?');
      args.add(branchId);
    }
    if (method != null && method.isNotEmpty) {
      where.add("COALESCE(method,'cash') = ?");
      args.add(method);
    }
    if (subscriberId != null && subscriberId.isNotEmpty) {
      where.add('subscriber_id = ?');
      args.add(subscriberId);
    }
    // v44 MONEY RULE — only the PHYSICAL cash return moves collected money.
    //   refund_return       -> its (negative) amount: cash actually left.
    //   correction_increase -> 0. The customer OWES the difference; it reaches
    //                          the wallet only through a real receipt (v43 had
    //                          credited it here — phantom cash nobody handed
    //                          over, flagged by the adversarial review).
    //   correction_decrease -> 0. The customer stays paid; the credit lives on
    //                          the correction until refunded or applied.
    //   credit_applied      -> 0. A DUE reduction on its target month, not cash.
    // The kind is bound, not interpolated; its `?` sits in the SELECT list, so
    // it must be the FIRST positional argument (the raw-SQL convention here).
    // STATUS-AWARE (v44 review fix): the cash return counts only while its
    // correction is `completed` — see DbHelper.correctionDueDelta.
    // Alias every clause to the ledger table `a` (the method clause is an
    // expression, so its column is aliased inside the COALESCE).
    final String scoped = where
        .map((w) => w.startsWith('COALESCE(')
            ? w.replaceFirst('COALESCE(method', 'COALESCE(a.method')
            : 'a.$w')
        .join(' AND ');
    final r = await db.rawQuery(
      "SELECT COALESCE(SUM(CASE WHEN a.kind = ? AND c.status = 'completed' "
      "THEN COALESCE(a.amount, 0) ELSE 0 END), 0) s "
      "FROM financial_adjustments a "
      "LEFT JOIN corrections c ON c.id = a.correction_id WHERE $scoped",
      [AdjustmentKind.refundReturn, ...args],
    );
    return ((r.first['s'] as num?) ?? 0).toDouble();
  }

  /// v44 — the Dart twin of `DbHelper.correctionDueDelta`: the signed change
  /// to [subscriberId]'s DUE in [month] from decided corrections
  /// (+ increases, − credits applied). `BillingController.getDueAmount` uses
  /// it so the detail screen and the list SQL can never disagree.
  Future<double> dueDeltaFor({
    required String subscriberId,
    required String month,
  }) async {
    if (subscriberId.isEmpty || month.isEmpty) return 0;
    final db = await _dbHelper.database;
    // STATUS-AWARE — the Dart twin of DbHelper.correctionDueDelta.
    final r = await db.rawQuery(
      "SELECT COALESCE(SUM(CASE "
      "WHEN a.kind = ? AND c.status = 'approved' THEN COALESCE(a.amount, 0) "
      "WHEN a.kind = ? AND c.status = 'carried_forward' "
      "THEN -COALESCE(a.amount, 0) ELSE 0 END), 0) s "
      "FROM financial_adjustments a "
      "LEFT JOIN corrections c ON c.id = a.correction_id "
      "WHERE a.subscriber_id = ? AND a.month = ?",
      [AdjustmentKind.increase, AdjustmentKind.creditApplied, subscriberId, month],
    );
    return ((r.first['s'] as num?) ?? 0).toDouble();
  }

  /// v44 — the corrections of one accounting [month] joined to their
  /// subscriber (name / current amps), newest first, for the Subscribers
  /// screen's Corrections tab. Paginated like every list here.
  Future<List<Map<String, Object?>>> correctedInMonth({
    required String month,
    String? branchId,
    required int limit,
    required int offset,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>['c.month = ?'];
    final args = <dynamic>[month];
    if (branchId != null && branchId.isNotEmpty) {
      where.add("IFNULL(c.branch_id, '${DbHelper.kMainBranchId}') = ?");
      args.add(branchId);
    }
    args.addAll([limit, offset]);
    return db.rawQuery(
      'SELECT c.*, s.name AS subscriber_name, s.amps AS subscriber_amps, '
      's.phone AS subscriber_phone '
      'FROM corrections c LEFT JOIN subscribers s ON s.id = c.subscriber_id '
      'WHERE ${where.join(' AND ')} '
      'ORDER BY c.requested_at DESC, c.id DESC LIMIT ? OFFSET ?',
      args,
    );
  }

  /// v43.1 — the amps that were in force for [subscriberId] in [month].
  ///
  /// The Dart twin of `DbHelper.effectiveAmps`, so `BillingController
  /// .getDueAmount` (the subscriber-detail figure) and the list/report SQL can
  /// never disagree about a month's due. Returns null when no decided
  /// correction covers the month, meaning "use the subscriber's live amps".
  ///
  ///   month  > every correction  -> null (the corrected, current value)
  ///   month <= a correction      -> that correction's old_amps (as invoiced)
  Future<double?> effectiveAmpsFor({
    required String subscriberId,
    required String month,
  }) async {
    if (subscriberId.isEmpty || month.isEmpty) return null;
    final db = await _dbHelper.database;
    final r = await db.rawQuery(
      'SELECT old_amps FROM corrections '
      'WHERE subscriber_id = ? AND month >= ? AND old_amps IS NOT NULL '
      "AND status IN ('approved', 'refund_due', 'completed', 'carried_forward') "
      "ORDER BY month ASC, COALESCE(requested_at, '') ASC, id ASC LIMIT 1",
      [subscriberId, month],
    );
    if (r.isEmpty) return null;
    return (r.first['old_amps'] as num?)?.toDouble();
  }

  /// v44 review fix — the month's TOTAL signed due delta (+ increases in
  /// force − credits in force), optionally per branch, so the app's
  /// "expected" figure folds it in exactly like `remaining` and the backend
  /// `expected` already do. Status-aware like `dueDeltaFor`.
  Future<double> dueDeltaTotal({
    required String month,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>['a.month = ?'];
    final args = <dynamic>[month];
    if (branchId != null && branchId.isNotEmpty) {
      where.add("IFNULL(a.branch_id, '${DbHelper.kMainBranchId}') = ?");
      args.add(branchId);
    }
    final r = await db.rawQuery(
      "SELECT COALESCE(SUM(CASE "
      "WHEN a.kind = 'correction_increase' AND c.status = 'approved' "
      "THEN COALESCE(a.amount, 0) "
      "WHEN a.kind = 'credit_applied' AND c.status = 'carried_forward' "
      "THEN -COALESCE(a.amount, 0) ELSE 0 END), 0) s "
      "FROM financial_adjustments a "
      "LEFT JOIN corrections c ON c.id = a.correction_id "
      "WHERE ${where.join(' AND ')}",
      args,
    );
    return ((r.first['s'] as num?) ?? 0).toDouble();
  }

  /// The adjustment rows of one accounting [month] (optionally one subscriber /
  /// branch), oldest first — the ledger is read in the order it was appended,
  /// which is the order the money actually moved. Read-only; backs the audit
  /// trail shown next to a corrected month.
  ///
  /// Tie-breaks on the UUID `id`, never on `rowid` (device-local, re-assigned
  /// by every sync pull).
  Future<List<FinancialAdjustment>> adjustmentsFor({
    required String month,
    String? subscriberId,
    String? branchId,
  }) async {
    final db = await _dbHelper.database;
    final where = <String>['month = ?'];
    final args = <dynamic>[month];
    if (subscriberId != null && subscriberId.isNotEmpty) {
      where.add('subscriber_id = ?');
      args.add(subscriberId);
    }
    if (branchId != null && branchId.isNotEmpty) {
      where.add('branch_id = ?');
      args.add(branchId);
    }
    final maps = await db.query(
      'financial_adjustments',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: "COALESCE(created_at, '') ASC, id ASC",
    );
    return maps.map((m) => FinancialAdjustment.fromMap(m)).toList();
  }
}
