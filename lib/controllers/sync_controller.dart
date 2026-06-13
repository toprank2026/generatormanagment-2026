import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';
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
  final isPulling = false.obs;
  final lastSyncAt = RxnString();
  final lastPullAt = RxnString();

  /// True when there are no local changes waiting to upload.
  bool get isUpToDate => pendingCount.value == 0;

  StreamSubscription<bool>? _netSub;
  Timer? _timer;
  bool _askOpen = false;

  bool get _loggedIn =>
      Get.isRegistered<AuthController>() &&
      Get.find<AuthController>().isLoggedIn.value;

  /// True unless the active plan disables sync. When false the app stays in
  /// "offline-only" mode: local SQLite + outbox keep working, but we never hit
  /// the network (push/pull). Defaults to allowed when AuthController is absent.
  bool get _canSync =>
      !Get.isRegistered<AuthController>() ||
      Get.find<AuthController>().canSync;

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
    // Offline-only mode: the active plan disables sync — never auto-push.
    if (!_canSync) return;
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
    // Offline-only mode: sync is disabled by the active plan — do nothing.
    if (!_canSync) return;
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

  /// Pulls this account's latest data from the server into local SQLite. Any
  /// pending local changes are pushed first so they aren't lost, then the server
  /// copy is applied (server wins). Used by the dashboard "update" button and
  /// after clearing local data / signing in on a new device.
  Future<void> pull({bool silent = false}) async {
    // Offline-only mode: pull is disabled by the active plan — do nothing.
    if (!_canSync) return;
    if (isPulling.value || isSyncing.value) return;
    if (!await _net.isOnline()) {
      if (!silent) Get.snackbar('sync'.tr, 'online_only'.tr);
      return;
    }
    isPulling.value = true;
    try {
      // Preserve local changes first.
      if (pendingCount.value > 0) await _sync.push();
      final n = await _sync.pull();
      lastPullAt.value = DateTime.now().toIso8601String();
      await _reloadAppData();
      if (!silent) {
        Get.snackbar('sync'.tr, '${'pulled_records'.tr}: $n');
      }
    } catch (e) {
      Log.e('pull failed', e);
      if (!silent) Get.snackbar('sync'.tr, 'sync_failed'.tr);
    } finally {
      isPulling.value = false;
      await refreshPending();
    }
  }

  /// Clears all local business data (boards/subscribers/receipts/…) and the
  /// pending outbox. The server mirror is untouched, so [pull] restores it.
  Future<void> deleteLocalData() async {
    try {
      await _sync.deleteLocalData();
      await _reloadAppData();
      Get.snackbar('settings'.tr, 'local_data_deleted'.tr);
    } catch (e) {
      Log.e('delete local failed', e);
      Get.snackbar('error'.tr, '$e');
    } finally {
      await refreshPending();
    }
  }

  /// Refresh the in-memory app state after a pull / local wipe so the UI updates.
  Future<void> _reloadAppData() async {
    try {
      if (Get.isRegistered<DashboardController>()) {
        await Get.find<DashboardController>().loadStats();
      }
    } catch (_) {}
  }
}
