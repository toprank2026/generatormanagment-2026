import 'package:get/get.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/repositories/device_repository.dart';

/// v18 item 1 — device unbind/rebind confirmation.
///
/// Before Logout / Create branch / Create accountant the user is told that THIS
/// device is bound to the current account and must be unbound + recreated so a
/// different account/branch/accountant can use it (avoids DEVICE_LIMIT). On
/// Continue we remove the current binding, clear the local device-binding data,
/// and (except on logout, where the next login does it) re-run the existing
/// fresh-registration binding flow. The whole thing is best-effort/online-gated
/// and never throws, so it can never break logout or the create flows.
class DeviceRebind {
  /// Shows the confirmation dialog. Returns true if the user chose Continue.
  static Future<bool> confirm() async {
    final ok = await Get.defaultDialog<bool>(
      title: 'device_binding'.tr,
      middleText: 'device_rebind_confirm'.tr,
      textConfirm: 'continue'.tr,
      textCancel: 'cancel'.tr,
      onConfirm: () => Get.back(result: true),
      onCancel: () {},
    );
    return ok == true;
  }

  /// Remove the current binding + clear local install-id, then (if [rebind])
  /// re-bind via the fresh-registration flow. Online-gated + never throws.
  static Future<void> apply({bool rebind = true}) async {
    try {
      if (!await ConnectivityService().isOnline()) return;
      await DeviceRepository().rebindCurrent(rebind: rebind);
    } catch (_) {/* best-effort: never block the caller */}
  }

  /// Convenience: confirm THEN apply (for create-branch / create-accountant).
  /// Returns true if the user confirmed (apply already ran), false if cancelled.
  static Future<bool> confirmAndApply({bool rebind = true}) async {
    if (!await confirm()) return false;
    await apply(rebind: rebind);
    return true;
  }
}
