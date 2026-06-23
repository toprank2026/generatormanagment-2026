import 'package:flutter/material.dart' show Colors;
import 'package:get/get.dart';
import 'package:uuid/uuid.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/settlement_model.dart';
import 'package:generatormanagment/data/repositories/settlement_repository.dart';

/// v11/v12 — accountant wallets: a CASH wallet and a CREDIT-CARD wallet. Each
/// shows the collected − settled balance for its method and supports a per-method
/// settlement request the owner approves from the Owner Panel. Balances are
/// SERVER-AUTHORITATIVE (all-time, unaffected by the current-month receipt pull
/// scope), with a local per-method derivation as the offline fallback.
class SettlementController extends GetxController {
  final SettlementRepository _repo = SettlementRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();
  final ConnectivityService _net = ConnectivityService();

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

  final isLoading = false.obs;
  final isRequesting = false.obs; // v14: loading while a settlement request saves

  final RxList<Settlement> history = <Settlement>[].obs;
  static const int _perPage = 15;
  int _page = 1;
  final hasMore = false.obs;
  final isMoreLoading = false.obs;

  String? get _acctId => _auth.currentUser.value?.id;
  double _d(dynamic v) => ((v as num?) ?? 0).toDouble();

  @override
  void onReady() {
    super.onReady();
    load(pull: true);
  }

  /// Loads both wallets + the history. [pull] (item 2) first syncs down the
  /// latest receipts + owner settlement decisions so the page shows current data.
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
      bool gotServer = false;
      if (online) {
        try {
          final res = await ApiClient().get(ApiConfig.accountWallet);
          if (res is Map) {
            final cash = (res['cash'] as Map?) ?? res; // back-compat: top-level=cash
            final card = (res['card'] as Map?) ?? const {};
            cashCollected.value = _d(cash['collected']);
            cashSettled.value = _d(cash['settled']);
            cashBalance.value = _d(cash['balance']);
            cardCollected.value = _d(card['collected']);
            cardSettled.value = _d(card['settled']);
            cardBalance.value = _d(card['balance']);
            gotServer = true;
          }
        } catch (_) {/* offline-ish → local fallback */}
      }
      if (!gotServer) {
        final w = await _repo.wallet(id);
        cashCollected.value = w.cashCollected;
        cashSettled.value = w.cashSettled;
        cashBalance.value = w.cashBalance;
        cardCollected.value = w.cardCollected;
        cardSettled.value = w.cardSettled;
        cardBalance.value = w.cardBalance;
      }
      hasPendingCash.value = await _repo.hasPending(id, 'cash');
      hasPendingCard.value = await _repo.hasPending(id, 'card');
      _page = 1;
      final page = await _repo.history(id, limit: _perPage + 1, offset: 0);
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
      final next =
          await _repo.history(id, limit: _perPage + 1, offset: _page * _perPage);
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
  Future<bool> requestSettlement(String method) async {
    final id = _acctId;
    if (id == null) return false;
    final bal = method == 'card' ? cardBalance.value : cashBalance.value;
    if (bal <= 0) {
      Get.snackbar('settlement'.tr, 'wallet_no_balance'.tr);
      return false;
    }
    if (await _repo.hasPending(id, method)) {
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
