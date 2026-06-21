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

/// v11 — accountant "My Wallet": shows the cash the accountant has collected and
/// not yet settled, and lets them request a settlement the owner approves from
/// the Owner Panel. Balance is DERIVED (Σ collected − Σ approved settlements)
/// from the local tables. NOTE: with the current-month load scope (item 3) the
/// receipts on-device are the current period, so the wallet reflects the current
/// uncleared period; settlements are fully synced (not month-scoped).
class SettlementController extends GetxController {
  final SettlementRepository _repo = SettlementRepository();
  final AuthController _auth = Get.find();
  final BranchController _branch = Get.find();
  final ConnectivityService _net = ConnectivityService();

  final collected = 0.0.obs;
  final settled = 0.0.obs;
  final balance = 0.0.obs;
  final hasPending = false.obs;
  final isLoading = false.obs;

  final RxList<Settlement> history = <Settlement>[].obs;
  static const int _perPage = 15;
  int _page = 1;
  final hasMore = false.obs;
  final isMoreLoading = false.obs;

  String? get _acctId => _auth.currentUser.value?.id;

  @override
  void onReady() {
    super.onReady();
    load();
  }

  Future<void> load() async {
    final id = _acctId;
    if (id == null) return;
    isLoading.value = true;
    try {
      // Server-authoritative balance (all-time; unaffected by the current-month
      // receipt scope). Fall back to the local derivation when offline.
      bool gotServer = false;
      if (await _net.isOnline()) {
        try {
          final res = await ApiClient().get(ApiConfig.accountWallet);
          if (res is Map) {
            collected.value = ((res['collected'] as num?) ?? 0).toDouble();
            settled.value = ((res['settled'] as num?) ?? 0).toDouble();
            balance.value = ((res['balance'] as num?) ?? 0).toDouble();
            gotServer = true;
          }
        } catch (_) {/* offline-ish / server hiccup → local fallback */}
      }
      if (!gotServer) {
        final w = await _repo.wallet(id);
        collected.value = w.collected;
        settled.value = w.settled;
        balance.value = w.balance;
      }
      hasPending.value = await _repo.hasPending(id);
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

  /// Submit a settlement request for the current balance — stays PENDING until
  /// the owner approves it from the Owner Panel.
  Future<bool> requestSettlement() async {
    final id = _acctId;
    if (id == null) return false;
    if (balance.value <= 0) {
      Get.snackbar('settlement'.tr, 'wallet_no_balance'.tr);
      return false;
    }
    if (await _repo.hasPending(id)) {
      Get.snackbar('settlement'.tr, 'wallet_pending_exists'.tr);
      return false;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    await _repo.insert(Settlement(
      id: const Uuid().v4(),
      accountantId: id,
      branchId: _branch.writeBranchId,
      amount: balance.value,
      status: 'pending',
      requestedAt: now,
    ));
    SyncController.poke(); // push the request into the owner's mirror
    await load();
    Get.snackbar('settlement'.tr, 'settlement_requested'.tr,
        backgroundColor: Colors.green, colorText: Colors.white);
    return true;
  }
}
