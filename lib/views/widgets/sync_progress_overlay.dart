import 'package:flutter/material.dart';
import 'package:get/get.dart';

/// A blocking, non-dismissible progress overlay shown during large sync work
/// (R7b): branch-switch clear+pull, the dashboard "pull latest", and large
/// uploads. It keeps the UI from being interacted with mid-operation so a big
/// push/pull can't be interrupted into a half-applied / crashing state.
class SyncProgress {
  SyncProgress._();

  static bool _open = false;
  static final RxString _message = ''.obs;

  /// Show the overlay with [message]. Safe to call repeatedly (updates text).
  static void show(String message) {
    _message.value = message;
    if (_open) return;
    _open = true;
    Get.dialog(
      PopScope(
        canPop: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            margin: const EdgeInsets.symmetric(horizontal: 40),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation(Color(0xFF1565C0)),
                ),
                const SizedBox(height: 18),
                Obx(
                  () => Text(
                    _message.value,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1565C0),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      barrierDismissible: false,
    );
  }

  /// Update the message while the overlay stays open.
  static void update(String message) => _message.value = message;

  /// Close the overlay if open.
  static void hide() {
    if (_open && (Get.isDialogOpen ?? false)) Get.back();
    _open = false;
  }
}
