import 'package:generatormanagment/data/db_helper.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/repositories/correction_repository.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

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

  /// v23 item 1 (§2.3): all [month] prices grouped by BRANCH then category —
  /// `{ branchKey: { category: pricePerAmp } }` (branchKey normalizes NULL to
  /// [DbHelper.kMainBranchId], matching `SubscriberRepository.ampsByBranchCategory`).
  /// Lets the CONSOLIDATED (All-branches) report price each branch's amps with
  /// that branch's OWN tariff instead of the flat last-row-wins collapse in
  /// [pricesForMonth]. Additive — never modify [pricesForMonth].
  Future<Map<String, Map<String, double>>> pricesForMonthByBranch(
      String month) async {
    final db = await _dbHelper.database;
    final rows = await db
        .query('monthly_prices', where: 'month = ?', whereArgs: [month]);
    final map = <String, Map<String, double>>{};
    for (final r in rows) {
      final mp = MonthlyPrice.fromMap(r);
      final br = mp.branchId ?? DbHelper.kMainBranchId;
      (map[br] ??= <String, double>{})[mp.category] = mp.pricePerAmp;
    }
    return map;
  }
}

class ReceiptRepository {
  final DbHelper _dbHelper = DbHelper();

  // v43: the append-only adjustment ledger, folded into [getCollectedSum] only
  // (plan §5) — never into receipt_no allocation, printing, or paid/unpaid.
  final CorrectionRepository _corrections = CorrectionRepository();

  Future<int> insert(Receipt item) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'receipts',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Allocates the next per-branch receipt_no AND inserts the row in ONE
  /// transaction, so two near-simultaneous collections on the same device can't
  /// both read the same MAX and mint a duplicate number (audit: the alloc was a
  /// separate read-then-insert). Returns the allocated number (also set on
  /// [item]). NOTE: cross-DEVICE uniqueness is a separate server-side concern
  /// (intentionally not addressed here).
  Future<int> insertWithAllocatedNumber(Receipt item, {String? branchId}) async {
    final db = await _dbHelper.database;
    return await db.transaction((txn) async {
      final where = branchId == null ? '' : 'WHERE branch_id = ?';
      final args = branchId == null ? <Object?>[] : <Object?>[branchId];
      final res = await txn
          .rawQuery("SELECT MAX(receipt_no) as max_no FROM receipts $where", args);
      final next = ((res.first['max_no'] as int?) ?? 0) + 1;
      item.receiptNo = next;
      await txn.insert('receipts', item.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
      return next;
    });
  }

  /// v35 item 5 (delete guards): the VALID receipts that a subscriber/circuit/
  /// board delete would cascade-remove. Exactly one of the scopes applies.
  /// Used to refuse deletes that would erase cash already inside a settlement
  /// (dropping Collected while Settled stays → a negative wallet).
  Future<List<Receipt>> validReceiptsForDeleteScope({
    String? subscriberId,
    String? circuitId,
    String? boardId,
  }) async {
    final db = await _dbHelper.database;
    String where;
    List<dynamic> args;
    if (subscriberId != null) {
      where = "subscriber_id = ? AND status = 'valid'";
      args = [subscriberId];
    } else if (circuitId != null) {
      where =
          "subscriber_id IN (SELECT id FROM subscribers WHERE circuit_id = ?) "
          "AND status = 'valid'";
      args = [circuitId];
    } else if (boardId != null) {
      where =
          "subscriber_id IN (SELECT id FROM subscribers WHERE board_id = ?) "
          "AND status = 'valid'";
      args = [boardId];
    } else {
      return const [];
    }
    final maps = await db.query('receipts', where: where, whereArgs: args);
    return maps.map((m) => Receipt.fromMap(m)).toList();
  }

  /// Fetch a single receipt by its uuid (null when not found).
  Future<Receipt?> getByUuid(String uuid) async {
    final db = await _dbHelper.database;
    final maps = await db.query('receipts',
        where: 'uuid = ?', whereArgs: [uuid], limit: 1);
    if (maps.isEmpty) return null;
    return Receipt.fromMap(maps.first);
  }

  /// v30 F2: soft-void a receipt — flip status 'valid' → 'refunded'. Every
  /// money / paid-unpaid / wallet / dashboard / report aggregate filters
  /// status = 'valid', so this single flip restores the subscriber to UNPAID and
  /// reverses every derived figure. Written via the full [Receipt.toMap()] so
  /// `updated_at` re-stamps (backend last-EDIT-wins accepts it over the older
  /// 'valid' row) and the AFTER-UPDATE sync trigger enqueues one clean upsert —
  /// NOT a delete (which would re-mint an already-printed receipt_no).
  ///
  /// v43 audit fix (spec §5): the flip itself is UNCHANGED — every derivation
  /// depends on it — but it no longer happens without evidence. Until now a
  /// reversal rewrote the receipt in place and wrote NOTHING to the `refunds`
  /// table, which exists, is synced and has triggers, yet had no insert path in
  /// any code: a reversal left no record that it ever happened. The row is
  /// appended in the SAME transaction as the flip, so the two can never diverge
  /// (evidence without a reversal, or a reversal without evidence), and the
  /// AFTER-INSERT trigger mirrors it to the server like any other business row.
  /// Purely additive: nothing reads `refunds` yet, so nothing can regress.
  ///
  /// [reason] is free text for the audit ('receipt_reversal' when the caller
  /// gives none); [performedByUserId] is the actor, defaulting to the receipt's
  /// collecting accountant — which is who reversed it, since
  /// `BillingController.reverseReceipt` lets ONLY the collecting accountant
  /// reverse their own receipt. Both are optional, so existing callers are
  /// unaffected.
  Future<void> markRefunded(
    Receipt r, {
    String? reason,
    String? performedByUserId,
  }) async {
    final db = await _dbHelper.database;
    r.status = 'refunded';
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((txn) async {
      await txn.update('receipts', r.toMap(),
          where: 'uuid = ?', whereArgs: [r.uuid]);
      await txn.insert('refunds', {
        'uuid': const Uuid().v4(),
        'receipt_uuid': r.uuid,
        // The CASH that was handed back = what was actually collected. A waived
        // discount was never cash, so it is not part of the refunded amount.
        'amount': r.paidAmount,
        'reason': reason ?? 'receipt_reversal',
        'performed_by_user_id': performedByUserId ?? r.accountantId,
        'branch_id': r.branchId,
        'created_at': now,
        'updated_at': now, // conflict resolution (last-EDIT-wins), like every model
      });
    });
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

  /// v43 §3.3 — the INVOICE LOCK predicate, DERIVED and never stored: a
  /// subscriber-month is invoice-locked exactly when a VALID receipt exists for
  /// `(subscriber_id, month)`. Deliberately NOT a column on `subscribers` or
  /// `receipts`: `SyncService.pull` writes with `ConflictAlgorithm.replace`
  /// (INSERT OR REPLACE = delete + insert), so a lock column an older device
  /// doesn't know about would be reset ACCOUNT-WIDE on every device's next pull.
  ///
  /// Same shape as [getBySubscriberAndMonth] (status = 'valid', so a REVERSED
  /// receipt unlocks the month again, exactly as it restores the subscriber to
  /// unpaid) and branch-scoped for the same reason: a shared subscriber id can
  /// carry receipts under more than one branch. [branchId] null = all branches.
  /// `LIMIT 1` on `idx_receipts_sub_month` — an existence check, not a sum.
  Future<bool> hasValidReceipt(
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
    final maps = await db.query(
      'receipts',
      columns: ['uuid'],
      where: clauses.join(' AND '),
      whereArgs: args,
      limit: 1,
    );
    return maps.isNotEmpty;
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
  //
  // v43 (plan §5): PLUS the month's approved CORRECTION adjustments. A
  // correction delta is real collected money for that month — it just cannot
  // live in `receipts` (a row there would consume a real `receipt_no` and the
  // status='valid' filter would either hide the delta from ~20 money queries or
  // print a phantom invoice, spec §3.2), so it is summed from the append-only
  // `financial_adjustments` ledger and added on top of the receipts SQL, which
  // is left byte-identical. A month with no adjustment therefore returns
  // EXACTLY what it returns today. Same (month, accountant, branch) scope as
  // the receipts side, so a per-accountant or per-branch figure never picks up
  // another scope's delta. Deliberately NOT folded into the paid/unpaid
  // derivation or coverageBySubscriber: a correction changes what is DUE, and
  // mixing it into coverage would flip paid/unpaid on historical rows.
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
    double total = 0.0;
    if (result.isNotEmpty && result.first['total'] != null) {
      total = (result.first['total'] as num).toDouble();
    }
    final adjustments = await _corrections.adjustmentTotal(
      month: month,
      accountantId: accountantId,
      branchId: branchId,
    );
    return total + adjustments;
  }

  /// Σ of WAIVED discount (discount_value) for the month (same scope as
  /// [getCollectedSum]). The discount is NOT cash, so it is excluded from
  /// collected/revenue — but it DOES reduce what is still owed, so the
  /// "remaining" figure must subtract it (audit: discount lockstep). Coverage
  /// for paid/unpaid already counts paid_amount + discount_value.
  Future<double> getDiscountSum(String month,
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
      "SELECT SUM(IFNULL(discount_value,0)) as total FROM receipts WHERE month = ? AND status = 'valid' ${scopes.join(' ')}",
      args,
    );
    if (result.isNotEmpty && result.first['total'] != null) {
      return (result.first['total'] as num).toDouble();
    }
    return 0.0;
  }
}
