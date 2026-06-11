import 'dart:async';

import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';

/// Screen-local navigation state for [MainScreen]'s bottom navigation bar.
///
/// Holds the currently selected tab index as a reactive value so the
/// body ([IndexedStack]) and the [BottomNavigationBar] can be driven by
/// `Obx` instead of `StatefulWidget` + `setState`.
class MainNavController extends GetxController {
  final RxInt currentIndex = 0.obs;

  /// Minimum gap between nav-triggered session re-checks so rapid tab
  /// switching doesn't hammer `/auth/me`.
  static const _navRecheckThrottle = Duration(seconds: 60);

  /// When the last nav-triggered re-check fired (null = never).
  DateTime? _lastNavRecheckAt;

  void setIndex(int index) {
    if (index == currentIndex.value) return;
    currentIndex.value = index;
    _maybeRecheckSession();
  }

  /// On a tab change, re-validate the session exactly like pull-to-refresh
  /// (fire-and-forget; [AuthController.guardedRecheck] is online-gated and
  /// silent on network errors, so offline navigation is untouched). Throttled
  /// to at most one check per [_navRecheckThrottle].
  void _maybeRecheckSession() {
    if (!Get.isRegistered<AuthController>()) return;
    final now = DateTime.now();
    final last = _lastNavRecheckAt;
    if (last != null && now.difference(last) < _navRecheckThrottle) return;
    _lastNavRecheckAt = now;
    unawaited(Get.find<AuthController>().guardedRecheck());
  }
}
