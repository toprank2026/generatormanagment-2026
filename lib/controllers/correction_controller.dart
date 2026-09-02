import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/billing_models.dart';
import 'package:generatormanagment/data/models/core_models.dart';
import 'package:generatormanagment/data/models/correction_models.dart';
import 'package:generatormanagment/data/repositories/billing_repositories.dart';
import 'package:generatormanagment/data/repositories/core_repositories.dart';
import 'package:generatormanagment/data/repositories/correction_repository.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v43 — corrections after invoicing.
///
/// The accountant may no longer silently rewrite the billing basis of a month
/// that has already been invoiced or settled: they FILE A CORRECTION, and the
/// owner/admin decides it. Approving one never edits the receipt, the
/// settlement, the monthly price or the subscriber — it APPENDS an immutable
/// row to `financial_adjustments`, which the derived wallet / revenue figures
/// pick up (and nothing else does: never the paid/unpaid derivation, never
/// coverage, never a printed receipt, never `receipt_no`).
///
/// The Golden Rule this controller exists to enforce:
///
/// > Invoice month = accounting month = settlement month = correction month.
/// > A correction for one billing month never touches another month, and the
/// > accountant's wallet is never driven negative by a historical correction.
///
/// Modelled on [SettlementController]: `.obs` state, [MonthController] via
/// `Get.find`, `SyncController.poke()` after every write, and `ever()` workers
/// that are STORED and DISPOSED (the v36 review pattern — both AuthController
/// and MonthController are permanent, so an undisposed worker outlives this
/// controller and fires into a dead instance).
class CorrectionController extends GetxController {
  final CorrectionRepository _repo = CorrectionRepository();
  final ReceiptRepository _receiptRepo = ReceiptRepository();
  final MonthlyPriceRepository _priceRepo = MonthlyPriceRepository();
  final SettlementRepository _settleRepo = SettlementRepository();
  final SubscriberRepository _subRepo = SubscriberRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();
  final MonthController _month = Get.find();
  final ConnectivityService _net = ConnectivityService();

  /// Workers on the PERMANENT Auth/Month controllers — stored so [onClose] can
  /// dispose them (v36 review pattern).
  Worker? _monthFollow;
  Worker? _userFollow;

  // --- list state (the correction queue) ---
  final RxList<Correction> corrections = <Correction>[].obs;
  final isLoading = false.obs;
  final isMoreLoading = false.obs;
  final hasMore = false.obs;

  /// True while a request/decision is being written — the UI disables its
  /// buttons on this, and [_busy] refuses re-entry regardless.
  final isSaving = false.obs;

  /// Translation KEY of the last refusal, or null. Deliberately not a
  /// `Get.snackbar` from inside the controller: the money paths here are
  /// exercised by unit tests with no GetMaterialApp overlay, and a snackbar
  /// raised before a dialog's `Get.back()` makes `Get.isDialogOpen` read false
  /// and BLOCKS the close (the documented stuck-overlay trap). The view reads
  /// this and shows the message.
  final lastError = RxnString();

  /// Optional status filter (`null` = every status). `refund_due` is the useful
  /// one for the owner: "cash still to be physically returned".
  final statusFilter = RxnString();

  /// The list follows the global accounting month by default (the Golden Rule
  /// — a correction belongs to exactly one month). Flip this to see every
  /// month's queue, so a pending request can never become invisible merely
  /// because the owner browsed to another month.
  final allMonths = false.obs;

  /// PENDING corrections in the current scope, capped at [_countCap] — the
  /// owner's queue badge. Capped because it is a badge, not a report; a
  /// three-digit backlog reads the same as "lots".
  final pendingCount = 0.obs;

  static const int _perPage = 15;
  static const int _countCap = 99;
  int _page = 1;

  /// One write at a time. Dart runs this controller on a single isolate, so a
  /// double-tap (or a screen racing itself) can only interleave at an `await`;
  /// this latch closes that window, which matters because
  /// `financial_adjustments` is APPEND-ONLY — a second adjustment for the same
  /// correction could never be deleted.
  bool _busy = false;

  // ---------------------------------------------------------------------------
  // Roles — EXPLICIT, never `auth.isAdmin`
  //
  // `AuthController.isAdmin` is true for role `owner`, for role `admin` AND for
  // the `DEV_ADMIN` compile flag. Gating an approval on it would let a
  // DEV_ADMIN build approve corrections (i.e. mint wallet credit) while acting
  // as an accountant. Every gate below reads the role itself.
  // ---------------------------------------------------------------------------

  /// The acting role. Reads `currentUser` FIRST so the getter stays reactive
  /// inside an `Obx` (an `Obx` whose condition short-circuits before touching
  /// an observable throws at build and greys the whole screen in release).
  String get role {
    final String? acting = _auth.currentUser.value?.role;
    return acting ?? (_auth.account.value?.role ?? '');
  }

  /// Owner/admin — the only roles that may decide a correction or record a
  /// physical cash return.
  bool get canDecide => role == 'owner' || role == 'admin';

  /// Who may FILE a correction request.
  ///
  /// v43 review fix: this was accountant-only, but the invoice lock applies to
  /// the OWNER too — so an owner was blocked from editing an invoiced month
  /// with no sanctioned remedy anywhere in the app (a capability removed with
  /// no substitute). Owner/admin may now file as well; the request still goes
  /// through the same ledger, so the correction is recorded and auditable
  /// rather than being a silent edit of an original.
  bool get canRequest =>
      role == 'accountant' || role == 'owner' || role == 'admin';

  String? get _actingUserId => _auth.currentUser.value?.id;

  /// The month the list is scoped to (`null` = every month, see [allMonths]).
  String? get _monthScope =>
      allMonths.value ? null : _month.selectedMonth.value;

  @override
  void onInit() {
    super.onInit();
    // Re-scope on the acting user (logout clears, login reloads) — the same
    // lifecycle every other feature controller follows.
    _userFollow = ever(_auth.currentUser, (user) {
      if (user == null) {
        _reset();
      } else {
        load();
      }
    });
    // The queue is month-isolated like the wallet: changing the global
    // accounting month reloads it.
    _monthFollow = ever(_month.selectedMonth, (_) {
      if (_auth.currentUser.value != null) load();
    });
  }

  @override
  void onClose() {
    _monthFollow?.dispose();
    _userFollow?.dispose();
    super.onClose();
  }

  @override
  void onReady() {
    super.onReady();
    // v43 review fix: LOCAL load only — never a network pull here.
    //
    // This controller is `lazyPut(fenix: true)`, so the FIRST `Get.find` builds
    // it. That happens when a user merely OPENS an invoiced subscriber's detail
    // screen (to read the month-lock notice), which made opening a subscriber
    // fire a full push+pull the user never asked for — `SyncController.pull()`
    // pushes first, so this was a whole sync round-trip on a screen open.
    // `CorrectionsScreen` already calls `load(pull: true)` in its own
    // post-frame callback, which is where a refresh actually belongs.
    load();
  }

  void _reset() {
    corrections.clear();
    hasMore.value = false;
    pendingCount.value = 0;
    lastError.value = null;
    _page = 1;
    update();
  }

  /// Change the status filter and reload from page 1.
  void setStatusFilter(String? status) {
    if (statusFilter.value == status) return;
    statusFilter.value = status;
    load();
  }

  /// Toggle month-isolated / all-months listing and reload from page 1.
  void setAllMonths(bool value) {
    if (allMonths.value == value) return;
    allMonths.value = value;
    load();
  }

  // ---------------------------------------------------------------------------
  // Listing (canonical pagination idiom: fetch perPage + 1 to detect the next
  // page, trim, page-1 assignAll / later pages addAll, reset to 1 on a filter
  // change — reference: CoreController.loadSubscribers).
  // ---------------------------------------------------------------------------

  Future<void> load({bool pull = false}) async {
    if (_auth.currentUser.value == null) {
      _reset();
      return;
    }
    isLoading.value = true;
    try {
      if (pull &&
          Get.isRegistered<SyncController>() &&
          await _net.isOnline()) {
        try {
          await Get.find<SyncController>().pull(silent: true);
        } catch (_) {/* fall through to the local rows */}
      }
      _page = 1;
      final page = await _repo.list(
        status: statusFilter.value,
        month: _monthScope,
        branchId: _branch.scopeBranchId,
        limit: _perPage + 1,
        offset: 0,
      );
      hasMore.value = page.length > _perPage;
      corrections.assignAll(hasMore.value ? page.sublist(0, _perPage) : page);
      final pending = await _repo.list(
        status: CorrectionStatus.pending,
        month: _monthScope,
        branchId: _branch.scopeBranchId,
        limit: _countCap,
        offset: 0,
      );
      pendingCount.value = pending.length;
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<void> loadMore() async {
    if (isMoreLoading.value || isLoading.value || !hasMore.value) return;
    isMoreLoading.value = true;
    try {
      final next = await _repo.list(
        status: statusFilter.value,
        month: _monthScope,
        branchId: _branch.scopeBranchId,
        limit: _perPage + 1,
        offset: _page * _perPage,
      );
      hasMore.value = next.length > _perPage;
      corrections.addAll(hasMore.value ? next.sublist(0, _perPage) : next);
      _page++;
    } finally {
      isMoreLoading.value = false;
    }
    update();
  }

  /// The corrections filed for one subscriber-month — backs the "a correction
  /// is already pending for this month" notice on the subscriber detail screen.
  Future<List<Correction>> forSubscriberMonth(
      String subscriberId, String month) async {
    return _repo.list(
      subscriberId: subscriberId,
      month: month,
      limit: _perPage,
      offset: 0,
    );
  }

  /// The immutable adjustment ledger of one accounting month (optionally one
  /// subscriber), oldest first — the audit trail shown beside a corrected
  /// month. Read-only.
  Future<List<FinancialAdjustment>> ledgerFor(
      {required String month, String? subscriberId}) async {
    return _repo.adjustmentsFor(month: month, subscriberId: subscriberId);
  }

  // ---------------------------------------------------------------------------
  // ACCOUNTANT — file a correction request
  // ---------------------------------------------------------------------------

  /// Files a correction for [sub] in the accounting [month] (`'YYYY-MM'`).
  ///
  /// It records what the month IS billed at against what it SHOULD be, and
  /// changes NOTHING else: the subscriber row, the receipt, the monthly price
  /// and the settlement are all left exactly as they are. `difference =
  /// newDue − oldDue` is the whole money story, and it is only booked if and
  /// when the owner approves.
  ///
  /// `oldDue` is computed from the month's tariff and the subscriber's CURRENT
  /// amps/category (re-read from the DB at this choke point, never trusted from
  /// a possibly stale screen); `newDue` from [newAmps] and [newCategory].
  /// The request is linked to the invoice (`receipt_uuid`) and to the active
  /// settlement (`settlement_id`) that lock the month, when they exist, so the
  /// decision carries its own evidence.
  ///
  /// Returns the stored [Correction], or null with [lastError] set to a
  /// translation key.
  Future<Correction?> requestCorrection({
    required Subscriber sub,
    required String month,
    required double newAmps,
    String? newCategory,
    required String reason,
  }) async {
    lastError.value = null;
    // Explicit roles, never `isAdmin` (see the note above `canDecide`).
    if (!canRequest) {
      lastError.value = 'correction_not_allowed';
      return null;
    }
    if (month.isEmpty) {
      lastError.value = 'correction_month_missing';
      return null;
    }
    if (reason.trim().isEmpty) {
      lastError.value = 'correction_reason_required';
      return null;
    }
    if (newAmps <= 0) {
      lastError.value = 'amps_invalid';
      return null;
    }
    if (_busy) return null;
    _busy = true;
    isSaving.value = true;
    try {
      // Re-fetch at the write choke point: a stale caller must never file a
      // correction against amps/category the subscriber no longer has.
      final Subscriber s = await _subRepo.getById(sub.id) ?? sub;
      // SAME branch resolution as BillingController.getDueAmount, so the due
      // computed here can never disagree with the due shown on the screen.
      final String? lookupBranch = s.branchId ?? _branch.scopeBranchId;
      // A written row always carries a concrete branch (legacy rows may not).
      final String branchId = s.branchId ?? _branch.writeBranchId;
      final String oldCategory = SubscriberCategory.normalize(s.category);
      final String newCat =
          SubscriberCategory.normalize(newCategory ?? s.category);
      if (newAmps == s.amps && newCat == oldCategory) {
        lastError.value = 'correction_no_change';
        return null;
      }
      final MonthlyPrice? oldPrice = await _priceRepo.getByMonth(month,
          branchId: lookupBranch, category: oldCategory);
      final MonthlyPrice? newPrice = newCat == oldCategory
          ? oldPrice
          : await _priceRepo.getByMonth(month,
              branchId: lookupBranch, category: newCat);
      // No tariff for the month/branch/category → the month has no due at all
      // and there is nothing to correct against.
      if (oldPrice == null || newPrice == null) {
        lastError.value = 'correction_no_price';
        return null;
      }
      // v43.1 — `s.amps` is ALREADY the corrected basis: approving a correction
      // now writes the new amps onto the subscriber (so future months bill it).
      // So the current due is simply amps x price, and a SECOND correction is
      // automatically incremental.
      //
      // NOTE: v43's review added a `netDueDeltaFor` compensation here, because
      // back then approval left the subscriber untouched and `s.amps` was still
      // the ORIGINAL value, so a second correction re-booked the first delta.
      // Applying the amps fixes that at the source; keeping the compensation as
      // well would DOUBLE-compensate (a 10->15->20 chain would price the second
      // step off 20,000 instead of 15,000).
      final double oldDue = s.amps * oldPrice.pricePerAmp;
      final double newDue = newAmps * newPrice.pricePerAmp;
      final double difference = newDue - oldDue;
      if (difference == 0) {
        lastError.value = 'correction_no_change';
        return null;
      }
      // One open request per subscriber-month: a second pending correction for
      // the same month could be approved twice and book the delta twice.
      final open = await _repo.list(
        status: CorrectionStatus.pending,
        month: month,
        subscriberId: s.id,
        limit: 1,
        offset: 0,
      );
      if (open.isNotEmpty) {
        lastError.value = 'correction_pending_exists';
        return null;
      }
      // Evidence: the invoice that locked the month (newest valid receipt of
      // that subscriber-month) and the settlement that locked it, if any.
      final Receipt? receipt =
          await _newestReceipt(s.id, month, lookupBranch);
      // Whose wallet the delta belongs to: the accountant who actually
      // collected the month, falling back to the one filing the request.
      final String? receiptAccountant = receipt?.accountantId;
      final String? walletAccountant =
          (receiptAccountant != null && receiptAccountant.isNotEmpty)
              ? receiptAccountant
              : _actingUserId;
      final String? settlementId = walletAccountant == null
          ? null
          : await _activeSettlementId(walletAccountant, month);

      final c = Correction(
        id: const Uuid().v4(),
        subscriberId: s.id,
        month: month,
        branchId: branchId,
        accountantId: walletAccountant,
        receiptUuid: receipt?.uuid,
        settlementId: settlementId,
        reason: reason.trim(),
        oldAmps: s.amps,
        newAmps: newAmps,
        oldDue: oldDue,
        newDue: newDue,
        difference: difference,
        status: CorrectionStatus.pending,
        requestedBy: _actingUserId,
      );
      await _repo.create(c); // stamps created_at / requested_at
      SyncController.poke(); // push the request into the owner's mirror
      await load();
      return c;
    } finally {
      _busy = false;
      isSaving.value = false;
    }
  }

  // ---------------------------------------------------------------------------
  // OWNER / ADMIN — decide
  // ---------------------------------------------------------------------------

  /// Approves [c]. THE ORIGINAL RECEIPT AND SETTLEMENT ARE NEVER TOUCHED —
  /// approval appends one immutable adjustment and moves the correction on:
  ///
  ///  * INCREASE (`difference > 0`) → `correction_increase` for `+difference`
  ///    → that month's wallet rises → an additional settlement for the month
  ///    becomes possible → status `approved`.
  ///  * DECREASE (`difference < 0`) → `correction_decrease` for the ABSOLUTE
  ///    difference → status `refund_due`. The wallet is NOT reduced (a
  ///    historical correction must never drive it negative); the money is an
  ///    obligation on the correction until the cash is physically returned via
  ///    [recordRefundPaid]. `CorrectionRepository.adjustmentTotal` is where
  ///    that "counts as zero" rule lives — one place, never duplicated here.
  ///
  /// Returns true when the decision was applied; false (with [lastError]) when
  /// the caller lacked the role or the row was no longer pending.
  Future<bool> approve(Correction c) async {
    lastError.value = null;
    if (!canDecide) {
      lastError.value = 'correction_not_allowed';
      return false;
    }
    if (_busy) return false;
    _busy = true;
    isSaving.value = true;
    try {
      // Never trust the status held by a screen: re-read it.
      final Correction? fresh = await _repo.getById(c.id);
      if (fresh == null || !fresh.isPending) {
        lastError.value = 'correction_not_pending';
        await load();
        return false;
      }
      final double delta = fresh.difference;
      final bool increase = delta > 0;
      // Only a DECREASE creates a refund obligation. A zero-difference row
      // (nothing the request path can create, but a legacy/pulled row could)
      // books no adjustment and is simply `approved` — never `refund_due`,
      // which would ask the owner to hand back nothing.
      final bool decrease = delta < 0;
      // v43 review fix — ORDER MATTERS. The guarded status transition runs
      // FIRST; the append-only adjustment is written only after it succeeds.
      // Previously the adjustment was appended before the guard, so a device
      // that LOST the race to a REJECT left a permanent, unremovable wallet
      // credit for a correction that was never approved (the ledger has no
      // update/delete path by design, so it could not be taken back).
      final bool ok = await _repo.decide(
        fresh,
        decrease ? CorrectionStatus.refundDue : CorrectionStatus.approved,
        decidedBy: _actingUserId,
      );
      if (!ok) {
        // Raced from another device between the re-read and the write. Nothing
        // has been booked, so there is nothing to unwind.
        lastError.value = 'correction_not_pending';
        await load();
        return false;
      }
      if (delta != 0) {
        final String kind =
            increase ? AdjustmentKind.increase : AdjustmentKind.decrease;
        // The id is DERIVED from the correction id, so even if two devices
        // both reach this line for the same correction they write the SAME
        // row — an insert-or-replace, never a second credit.
        await _repo.insertAdjustment(FinancialAdjustment(
          id: _adjustmentId(fresh.id, kind),
          correctionId: fresh.id,
          subscriberId: fresh.subscriberId,
          month: fresh.month,
          branchId: fresh.branchId,
          // The wallet the delta lands in. A `correction_decrease` is stored
          // with the accountant for the audit trail but contributes exactly 0
          // to every wallet figure (adjustmentTotal zeroes that kind).
          accountantId: fresh.accountantId,
          kind: kind,
          amount: delta.abs(),
          method: await _methodFor(fresh),
          createdBy: _actingUserId,
        ));
      }
      // v43.1 — APPLY THE CORRECTED AMPS TO THE SUBSCRIBER.
      //
      // Without this the approval moved money but the subscriber kept billing
      // the OLD amps forever, so every future month was wrong (the defect this
      // fixes). Writing it is only safe because `subscribers.amps` is read LIVE
      // by every money query, for every month: `DbHelper.effectiveAmps` reads
      // THIS correction's `old_amps` for any month at or before it, so the
      // corrected month and all history keep exactly the basis they were
      // invoiced on. The new value takes effect from the NEXT month onwards.
      //
      // Deliberately last: if it were to fail, the correction is still decided
      // and the ledger still balances — and a later approval re-applies it.
      final double? applied = fresh.newAmps;
      final String? targetId = fresh.subscriberId;
      if (applied != null && applied > 0 && targetId != null && targetId.isNotEmpty) {
        final Subscriber? target = await _subRepo.getById(targetId);
        if (target != null && target.amps != applied) {
          target.amps = applied;
          await _subRepo.update(target);
        }
      }
      SyncController.poke();
      await load();
      return true;
    } finally {
      _busy = false;
      isSaving.value = false;
    }
  }

  /// v44 — closes a decrease by CARRYING the credit FORWARD to the next month
  /// instead of returning cash. `refund_due -> carried_forward`, then ONE
  /// `credit_applied` adjustment on the TARGET month (the month after the
  /// corrected one), which reduces that month's due by the credit. Wallets
  /// never move: no cash changed hands. Guarded transition first, like every
  /// decision here, so a lost race books nothing.
  Future<bool> carryForward(Correction c) async {
    lastError.value = null;
    if (!canDecide) {
      lastError.value = 'correction_not_allowed';
      return false;
    }
    if (_busy) return false;
    _busy = true;
    isSaving.value = true;
    try {
      final Correction? fresh = await _repo.getById(c.id);
      if (fresh == null || !fresh.isRefundDue) {
        lastError.value = 'correction_not_refund_due';
        await load();
        return false;
      }
      final String? srcMonth = fresh.month;
      if (srcMonth == null || srcMonth.isEmpty) {
        lastError.value = 'correction_month_missing';
        return false;
      }
      final String target = _nextMonth(srcMonth);
      // v44 review fix — a credit is applied ONLY when the target month can
      // absorb it in full. Otherwise the surplus would be silently destroyed
      // (the derived due would go negative and read as "paid" with no
      // receipt). Refuse and point to the cash-refund path; nothing is written.
      // Same three refusals as the backend's carry-forward route.
      final String? sid = fresh.subscriberId;
      final Subscriber? target0 =
          (sid == null || sid.isEmpty) ? null : await _subRepo.getById(sid);
      if (target0 == null) {
        lastError.value = 'correction_carry_forward_unpriced';
        return false;
      }
      final BillingController billing = Get.find<BillingController>();
      if (!await billing.hasPriceFor(target0, target)) {
        lastError.value = 'correction_carry_forward_unpriced';
        return false;
      }
      final double targetDue = await billing.getDueAmount(target0, target);
      final double credit = fresh.difference.abs();
      if (targetDue <= 0) {
        lastError.value = 'correction_carry_forward_covered';
        return false;
      }
      if (credit > targetDue + 0.000001) {
        lastError.value = 'correction_carry_forward_too_large';
        return false;
      }
      final bool ok = await _repo.carryForward(fresh, by: _actingUserId);
      if (!ok) {
        lastError.value = 'correction_not_refund_due';
        await load();
        return false;
      }
      try {
        await _repo.insertAdjustment(FinancialAdjustment(
          id: _adjustmentId(fresh.id, AdjustmentKind.creditApplied),
          correctionId: fresh.id,
          subscriberId: fresh.subscriberId,
          month: target, // the month the credit is applied TO
          branchId: fresh.branchId,
          accountantId: null, // a due reduction, never a wallet movement
          kind: AdjustmentKind.creditApplied,
          amount: fresh.difference.abs(),
          method: await _methodFor(fresh),
          createdBy: _actingUserId,
        ));
      } catch (_) {
        // v44 review fix: the flip happened but the credit was never booked —
        // put the correction back to refund_due so the credit is not lost
        // (the backend's carry-forward reverts the same way).
        await _repo.reopenRefundDue(fresh);
        rethrow;
      }
      SyncController.poke();
      await load();
      return true;
    } finally {
      _busy = false;
      isSaving.value = false;
    }
  }

  /// 'yyyy-MM' + 1 month (year wrap safe).
  static String _nextMonth(String m) {
    final parts = m.split('-');
    if (parts.length != 2) return m;
    final int y = int.tryParse(parts[0]) ?? 0;
    final int mo = int.tryParse(parts[1]) ?? 1;
    final DateTime d = DateTime(y, mo + 1);
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}';
  }

  /// Rejects [c]. No adjustment is written and no money moves — the month keeps
  /// exactly the figures it already has.
  Future<bool> reject(Correction c, {String? note}) async {
    lastError.value = null;
    if (!canDecide) {
      lastError.value = 'correction_not_allowed';
      return false;
    }
    if (_busy) return false;
    _busy = true;
    isSaving.value = true;
    try {
      final Correction? fresh = await _repo.getById(c.id);
      if (fresh == null || !fresh.isPending) {
        lastError.value = 'correction_not_pending';
        await load();
        return false;
      }
      final bool ok = await _repo.decide(
        fresh,
        CorrectionStatus.rejected,
        decidedBy: _actingUserId,
        note: note,
      );
      if (!ok) {
        lastError.value = 'correction_not_pending';
        await load();
        return false;
      }
      SyncController.poke();
      await load();
      return true;
    } finally {
      _busy = false;
      isSaving.value = false;
    }
  }

  /// Records the PHYSICAL cash return that closes a decrease correction:
  /// `refund_due → completed`, plus one `refund_return` row in the ledger.
  /// Owner/admin only, and only from `refund_due` — approving a decrease never
  /// asserted that money moved, which is why this is a separate operation with
  /// its own record.
  ///
  /// The row is stamped so the return has the RIGHT financial effect and no
  /// other:
  ///
  ///  * `amount` is NEGATIVE (`−|difference|`): cash physically left the
  ///    business, so the month's collected/revenue figure must fall by it.
  ///    `adjustmentTotal` sums `refund_return` at its stored sign precisely so
  ///    the writer can express this.
  ///  * `accountant_id` is deliberately LEFT NULL: the OWNER/ADMIN returns the
  ///    cash, not the accountant, so no accountant's derived wallet may be
  ///    reduced by it. Every wallet query filters `accountant_id = ?`, so a
  ///    null-accountant row is invisible to all of them — which is what keeps
  ///    the wallet from ever going negative (and, through the v42 lifetime cap,
  ///    from silently blocking every future legitimate settlement). The audit
  ///    link is unaffected: the row still carries `correction_id`,
  ///    `subscriber_id`, `month` and `branch_id`.
  Future<bool> recordRefundPaid(Correction c) async {
    lastError.value = null;
    if (!canDecide) {
      lastError.value = 'correction_not_allowed';
      return false;
    }
    if (_busy) return false;
    _busy = true;
    isSaving.value = true;
    try {
      final Correction? fresh = await _repo.getById(c.id);
      if (fresh == null || !fresh.isRefundDue) {
        lastError.value = 'correction_not_refund_due';
        await load();
        return false;
      }
      // v43 review fix — same ordering rule as approve(): the guarded status
      // transition runs FIRST, so a device that loses the race writes nothing
      // into the append-only ledger (which has no delete path to undo it).
      final String method = await _methodFor(fresh);
      final bool ok = await _repo.markRefundPaid(fresh, paidBy: _actingUserId);
      if (!ok) {
        lastError.value = 'correction_not_refund_due';
        await load();
        return false;
      }
      await _repo.insertAdjustment(FinancialAdjustment(
        id: _adjustmentId(fresh.id, AdjustmentKind.refundReturn),
        correctionId: fresh.id,
        subscriberId: fresh.subscriberId,
        month: fresh.month,
        branchId: fresh.branchId,
        accountantId: null, // see the doc comment — never an accountant wallet
        kind: AdjustmentKind.refundReturn,
        amount: -fresh.difference.abs(),
        method: method,
        createdBy: _actingUserId,
      ));
      SyncController.poke();
      await load();
      return true;
    } finally {
      _busy = false;
      isSaving.value = false;
    }
  }

  // ---------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------

  /// A DETERMINISTIC id for the adjustment of one correction + kind.
  ///
  /// `financial_adjustments` is append-only and `insertAdjustment` uses
  /// `ConflictAlgorithm.ignore`, so deriving the id from `(correction, kind)`
  /// makes the append IDEMPOTENT: a retried approval, a re-delivered command,
  /// or the same decision arriving from a second device can only ever write
  /// the row that is already there. With a random uuid it would instead
  /// DOUBLE-CREDIT the wallet — and, the table being append-only, the mistake
  /// could never be deleted. Still a real (v5, name-based) UUID, so every id
  /// in the system keeps the same shape.
  String _adjustmentId(String correctionId, String kind) => const Uuid()
      .v5(Namespace.url.value, 'moldati/v43/adjustment/$correctionId/$kind');

  /// The newest VALID receipt of a subscriber-month, or null. Branch-scoped
  /// exactly like the due calculation, so another branch's invoice can never be
  /// linked to this correction.
  Future<Receipt?> _newestReceipt(
      String subscriberId, String month, String? branchId) async {
    final list = await _receiptRepo.getBySubscriberAndMonth(subscriberId, month,
        branchId: branchId);
    Receipt? newest;
    for (final r in list) {
      if (newest == null || r.issuedAt.compareTo(newest.issuedAt) > 0) {
        newest = r;
      }
    }
    return newest;
  }

  /// The id of an ACTIVE (pending|approved) settlement covering [month] for
  /// [accountantId], or null. `SettlementRepository.history` already buckets by
  /// the v40 rule `COALESCE(month, substr(requested_at,1,7))` and orders newest
  /// first, so this is the same month lock the rest of the system uses.
  Future<String?> _activeSettlementId(
      String accountantId, String month) async {
    final rows = await _settleRepo.history(accountantId,
        limit: _perPage, offset: 0, month: month);
    for (final s in rows) {
      if (s.status == 'pending' || s.status == 'approved') return s.id;
    }
    return null;
  }

  /// Which wallet the adjustment belongs to — mirrored from the invoice the
  /// correction is about ('cash' | 'card'), defaulting to cash exactly like
  /// every other `COALESCE(payment_method,'cash')` in the money queries.
  Future<String> _methodFor(Correction c) async {
    final String? uuid = c.receiptUuid;
    if (uuid == null || uuid.isEmpty) return 'cash';
    final r = await _receiptRepo.getByUuid(uuid);
    return r?.paymentMethod == 'card' ? 'card' : 'cash';
  }
}
