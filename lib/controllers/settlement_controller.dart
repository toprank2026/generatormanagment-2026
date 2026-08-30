import 'package:flutter/material.dart' show Colors;
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/month_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v11/v12 — accountant wallets: a CASH wallet and a CREDIT-CARD wallet. Each
/// shows the collected − settled balance for its method and supports a per-method
/// settlement request the owner approves from the Owner Panel. Balances are
/// SERVER-AUTHORITATIVE, with a local per-method derivation as the offline
/// fallback.
///
/// v42 item 1 — every figure here is now ISOLATED PER ACCOUNTING MONTH (the
/// global tariff month): the wallet balances, collected/settled sub-figures, the
/// pending guard, the settlement request and the history all belong to exactly
/// one month. Money collected in August is settled in August and never leaks
/// into September's balance, and each month's accounting stands alone.
class SettlementController extends GetxController {
  final SettlementRepository _repo = SettlementRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();
  final MonthController _month = Get.find();
  final ConnectivityService _net = ConnectivityService();
  // v39 item 1: the history follows the global pricing month. Workers on the
  // PERMANENT MonthController must be stored + disposed (v36 review pattern).
  Worker? _monthFollow;

  // Cash wallet.
  final cashCollected = 0.0.obs;
  final cashSettled = 0.0.obs;
  final cashBalance = 0.0.obs;
  final hasPendingCash = false.obs;
  // Credit-card wallet (v12).
  final cardCollected = 0.0.obs;
  final cardSettled = 0.0.obs;
  final cardBalance = 0.0.obs;
  final hasPendingCard = false.obs;
  // v35 item 12: the SALARY wallet (v27/v28) was REMOVED — no new salary
  // requests can be created. Legacy 'salary' settlement rows remain in the
  // history list (and the owner can still decide old pending ones).

  // v42 review fix — the LIFETIME unsettled balance (cash + card), kept visible
  // alongside the per-month figures. Month-scoping the wallet is what the owner
  // asked for, but on its own it would make cash collected in a month nobody
  // reopens invisible on every screen. This is the "still in hand overall"
  // number, and it is also the ceiling every settlement request is capped at.
  final lifetimeCashBalance = 0.0.obs;
  final lifetimeCardBalance = 0.0.obs;

  final isLoading = false.obs;
  final isRequesting = false.obs; // v14: loading while a settlement request saves

  final RxList<Settlement> history = <Settlement>[].obs;
  static const int _perPage = 15;
  int _page = 1;
  final hasMore = false.obs;
  final isMoreLoading = false.obs;

  String? get _acctId => _auth.currentUser.value?.id;
  double _d(dynamic v) => ((v as num?) ?? 0).toDouble();

  /// v37 item 5: a wallet BALANCE is never shown negative. Structural causes
  /// are already prevented (v31 reversal lock, v35 delete guards); a negative
  /// here is either TRANSIENT (server/pull not caught up) or pre-guard
  /// historical data. v42: both sides are now the SAME month, which removes the
  /// old month-scoped-receipts-vs-all-time-settlements mismatch entirely. The
  /// raw collected/settled sub-figures stay visible for diagnosis.
  double _clamp0(double v) => v < 0 ? 0 : v;

  @override
  void onInit() {
    super.onInit();
    // v22 item 7: re-scope the wallet when the acting user changes — zero the
    // previous account's balances/history on logout (user == null) and reload
    // for the new one, matching the other feature controllers.
    ever(_auth.currentUser, (user) {
      if (user == null) {
        _resetWallet();
      } else {
        load();
      }
    });
    // v39 item 1 / v42 item 1: the whole page — balances, guards AND history —
    // is isolated to the globally selected accounting month; re-load on change.
    _monthFollow = ever(_month.selectedMonth, (_) {
      if (_acctId != null) load();
    });
  }

  @override
  void onClose() {
    _monthFollow?.dispose();
    super.onClose();
  }

  /// Zeroes all wallet figures + history (logout cleanup).
  void _resetWallet() {
    cashCollected.value = 0;
    cashSettled.value = 0;
    cashBalance.value = 0;
    hasPendingCash.value = false;
    cardCollected.value = 0;
    cardSettled.value = 0;
    cardBalance.value = 0;
    hasPendingCard.value = false;
    lifetimeCashBalance.value = 0;
    lifetimeCardBalance.value = 0;
    history.clear();
    hasMore.value = false;
    update();
  }

  @override
  void onReady() {
    super.onReady();
    load(pull: true);
  }

  /// Loads both wallets + the history FOR THE SELECTED ACCOUNTING MONTH (v42
  /// item 1). [pull] (item 2) first syncs down the latest receipts + owner
  /// settlement decisions so the page shows current data.
  Future<void> load({bool pull = false}) async {
    final id = _acctId;
    if (id == null) return;
    isLoading.value = true;
    try {
      final online = await _net.isOnline();
      if (pull && online && Get.isRegistered<SyncController>()) {
        try {
          await Get.find<SyncController>().pull(silent: true);
        } catch (_) {/* fall through to server/local figures */}
      }
      // v42 item 1: the wallet is now ISOLATED PER ACCOUNTING MONTH — every
      // figure below belongs to `month` and to no other month.
      final String month = _month.selectedMonth.value;
      bool gotServer = false;
      if (online) {
        try {
          final res = await ApiClient().get(
              '${ApiConfig.accountWallet}?month=${Uri.encodeQueryComponent(month)}');
          if (res is Map) {
            final cash = (res['cash'] as Map?) ?? res; // back-compat: top-level=cash
            final card = (res['card'] as Map?) ?? const {};
            cashCollected.value = _d(cash['collected']);
            cashSettled.value = _d(cash['settled']);
            cashBalance.value = _clamp0(_d(cash['balance'])); // v37 item 5
            cardCollected.value = _d(card['collected']);
            cardSettled.value = _d(card['settled']);
            cardBalance.value = _clamp0(_d(card['balance'])); // v37 item 5
            gotServer = true;
          }
        } catch (_) {/* offline-ish → local fallback */}
      }
      if (!gotServer) {
        final w = await _repo.walletForMonth(id, month);
        cashCollected.value = w.cashCollected;
        cashSettled.value = w.cashSettled;
        cashBalance.value = _clamp0(w.cashBalance); // v37 item 5
        cardCollected.value = w.cardCollected;
        cardSettled.value = w.cardSettled;
        cardBalance.value = _clamp0(w.cardBalance); // v37 item 5
      }
      // v42 review fix: the lifetime figures, always from the LOCAL tables (the
      // conservation law Σcollected − Σsettled holds there regardless of how any
      // single settlement was bucketed). Shown on the wallet so money collected
      // in a month nobody reopens is never invisible.
      final life = await _repo.wallet(id);
      lifetimeCashBalance.value = _clamp0(life.cashBalance);
      lifetimeCardBalance.value = _clamp0(life.cardBalance);
      // v42 item 1: the duplicate-request guard is per MONTH, so a pending
      // August request no longer blocks a September settlement.
      hasPendingCash.value = await _repo.hasPending(id, 'cash', month: month);
      hasPendingCard.value = await _repo.hasPending(id, 'card', month: month);
      _page = 1;
      // v39 item 1: history shows ONLY the selected pricing month's requests.
      final page =
          await _repo.history(id, limit: _perPage + 1, offset: 0, month: month);
      hasMore.value = page.length > _perPage;
      history.assignAll(hasMore.value ? page.sublist(0, _perPage) : page);
    } finally {
      isLoading.value = false;
    }
    update();
  }

  Future<void> loadMore() async {
    if (isMoreLoading.value || !hasMore.value) return;
    final id = _acctId;
    if (id == null) return;
    isMoreLoading.value = true;
    try {
      final next = await _repo.history(id,
          limit: _perPage + 1,
          offset: _page * _perPage,
          month: _month.selectedMonth.value);
      hasMore.value = next.length > _perPage;
      history.addAll(hasMore.value ? next.sublist(0, _perPage) : next);
      _page++;
    } finally {
      isMoreLoading.value = false;
    }
    update();
  }

  /// Request a settlement for the [method] ('cash'|'card') wallet's balance —
  /// stays PENDING until the owner approves it in the Owner Panel.
  /// v35 item 12: the salary method was removed — only cash/card remain.
  ///
  /// v42 item 1 (LIFETIME CAP — money safety): the DISPLAYED balance is now
  /// per-month, but "how much cash the accountant still physically holds" is a
  /// LIFETIME fact: Σ(all collected) − Σ(all approved settlements). Those two
  /// figures do not slice into months cleanly, because a settlement is an
  /// AMOUNT, not a link to specific receipts — a settlement bucketed to July
  /// (a legacy row keyed on `requested_at`, or a v40 row stamped to another
  /// tariff month) can have paid out cash that was COLLECTED in August. August
  /// then shows `collected − 0`, and requesting it would hand over money that
  /// was already handed over — the same cash settled twice.
  ///
  /// So the request is CAPPED at the lifetime unsettled balance. Per-month
  /// display is preserved (the owner's requirement), while the sum of all
  /// requests can never exceed what was actually collected. The cap only ever
  /// binds when the month figure would over-state reality; in the normal case
  /// (settlements bucketed with their own month's receipts) it is a no-op.
  Future<bool> requestSettlement(String method) async {
    final id = _acctId;
    if (id == null) return false;
    final monthBal = method == 'card' ? cardBalance.value : cashBalance.value;
    if (monthBal <= 0) {
      Get.snackbar('settlement'.tr, 'wallet_no_balance'.tr);
      return false;
    }
    // The lifetime ceiling — never request more cash than is actually still held.
    final life = await _repo.wallet(id);
    final double lifetimeBal =
        method == 'card' ? life.cardBalance : life.cashBalance;
    final double bal = monthBal < lifetimeBal ? monthBal : lifetimeBal;
    if (bal <= 0) {
      // Every IQD of this month's collection was already settled elsewhere.
      Get.snackbar('settlement'.tr, 'wallet_no_balance'.tr);
      return false;
    }
    // v42 item 1: month-scoped guard (see hasPending).
    final String month = _month.selectedMonth.value;
    if (await _repo.hasPending(id, method, month: month)) {
      Get.snackbar('settlement'.tr, 'wallet_pending_exists'.tr);
      return false;
    }
    // v14: loading until the request is saved + synced (prevents double-tap).
    isRequesting.value = true;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _repo.insert(Settlement(
        id: const Uuid().v4(),
        accountantId: id,
        branchId: _branch.writeBranchId,
        amount: bal,
        method: method,
        status: 'pending',
        // v40: the TARIFF month is the accounting bucket — a settlement of
        // August money requested on July 28 books into August. requestedAt
        // below stays the untouched historical transaction timestamp.
        // v42 item 1: this is also the month whose wallet balance is settled.
        month: month,
        requestedAt: now,
      ));
      SyncController.poke(); // push the request into the owner's mirror
      await load();
    } finally {
      isRequesting.value = false;
    }
    Get.snackbar('settlement'.tr, 'settlement_requested'.tr,
        backgroundColor: Colors.green, colorText: Colors.white);
    return true;
  }
}
