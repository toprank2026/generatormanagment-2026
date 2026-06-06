import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/core/logger.dart';
import 'package:generatormanagment/core/sync_service.dart';

/// Orchestrates offline-first sync: the app always reads/writes local SQLite;
/// whenever it's online (connectivity regained or a periodic tick) it pushes
/// pending local changes to the server mirror. If a LOT of data is pending it
/// asks the user before uploading; a small amount uploads silently.
class SyncController extends GetxController {
  final SyncService _sync = SyncService();
  final ConnectivityService _net = ConnectivityService();

  /// Above this many pending items, ask before uploading.
  static const int largeThreshold = 100;

  final pendingCount = 0.obs;
  final isSyncing = false.obs;
  final lastSyncAt = RxnString();

  StreamSubscription<bool>? _netSub;
  Timer? _timer;
  bool _askOpen = false;

  bool get _loggedIn =>
      Get.isRegistered<AuthController>() &&
      Get.find<AuthController>().isLoggedIn.value;

  @override
  void onReady() {
    super.onReady();
    refreshPending();
    _netSub = _net.onStatusChange.listen((online) {
      if (online) maybeAutoSync();
    });
    // Periodic "sync new data" heartbeat.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => maybeAutoSync());
    maybeAutoSync();
  }

  @override
  void onClose() {
    _netSub?.cancel();
    _timer?.cancel();
    super.onClose();
  }

  Future<void> refreshPending() async {
    pendingCount.value = await _sync.pendingCount();
  }

  /// Decides whether to sync silently, ask first, or skip.
  Future<void> maybeAutoSync() async {
    if (isSyncing.value || _askOpen) return;
    await refreshPending();
    if (!_loggedIn || pendingCount.value == 0) return;
    if (!await _net.isOnline()) return;

    if (pendingCount.value > largeThreshold) {
      _askLargeUpload();
    } else {
      await syncNow();
    }
  }

  void _askLargeUpload() {
    if (_askOpen) return;
    _askOpen = true;
    Get.defaultDialog(
      title: 'sync'.tr,
      middleText:
          '${pendingCount.value} ${'sync_pending_items'.tr}\n${'sync_confirm_large'.tr}',
      textConfirm: 'sync_now'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: const Color(0xFF1565C0),
      onConfirm: () {
        Get.back();
        _askOpen = false;
        syncNow();
      },
      onCancel: () => _askOpen = false,
    );
  }

  /// Pushes pending changes now (used by auto-sync and the manual button).
  Future<void> syncNow() async {
    if (isSyncing.value) return;
    if (!await _net.isOnline()) {
      Get.snackbar('sync'.tr, 'online_only'.tr);
      return;
    }
    isSyncing.value = true;
    try {
      await _sync.push();
      lastSyncAt.value = DateTime.now().toIso8601String();
    } catch (e) {
      Log.e('sync failed', e);
      Get.snackbar('sync'.tr, 'sync_failed'.tr);
    } finally {
      isSyncing.value = false;
      await refreshPending();
    }
  }
}
