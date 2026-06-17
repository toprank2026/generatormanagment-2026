import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// A blocking, non-dismissible progress overlay shown during large sync work
/// (R7b): branch-switch clear+pull, the dashboard "pull latest", and large
/// uploads. It keeps the UI from being interacted with mid-operation so a big
/// push/pull can't be interrupted into a half-applied / crashing state.
///
/// Shown as a GetX dialog with `barrierDismissible:false`. IMPORTANT: it must
/// NOT be wrapped in `PopScope(canPop:false)` — that blocks the programmatic
/// `Get.back()` in [hide], which previously left the overlay stuck open after
/// the work finished (greying the whole app). The system back button dismissing
/// it mid-op is acceptable; the operation guards itself (isPulling/isSyncing).
class SyncProgress {
  SyncProgress._();

  static bool _open = false;
  static final RxString _message = ''.obs;

  /// Show (or update) the blocking overlay. Never throws — a failure to show
  /// must not break the calling sync operation.
  static void show(String message) {
    _message.value = message;
    if (_open) return; // already showing — text updates reactively
    _open = true;
    try {
      Get.dialog(
        Center(
          // Material gives the Text a proper DefaultTextStyle (without it the
          // text renders oversized with Flutter's yellow "unstyled" underline).
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 260,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: CircularProgressIndicator(
                      strokeWidth: 3.5,
                      valueColor: AlwaysStoppedAnimation(Color(0xFF1565C0)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Obx(
                    () => Text(
                      _message.value,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1565C0),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        barrierDismissible: false,
        barrierColor: Colors.black54,
      ).then((_) => _open = false); // reset if dismissed (e.g. system back)
    } catch (_) {
      _open = false;
    }
  }

  /// Update the message while the overlay stays open.
  static void update(String message) => _message.value = message;

  /// Close the overlay if open. Never throws. Safe to call multiple times.
  static void hide() {
    if (!_open) return;
    _open = false;
    try {
      if (Get.isDialogOpen ?? false) {
        Get.back();
      } else {
        // Get.isDialogOpen can read false while a snackbar is active; close the
        // top route directly via the root navigator as a fallback. (We only get
        // here while _open was true, so our dialog is the topmost route.)
        final nav = Get.key.currentState;
        if (nav != null && nav.canPop()) nav.pop();
      }
    } catch (_) {/* already closed */}
  }
}
