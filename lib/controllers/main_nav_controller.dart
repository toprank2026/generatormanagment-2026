import 'package:get/get.dart';

/// Screen-local navigation state for [MainScreen]'s bottom navigation bar.
///
/// Holds the currently selected tab index as a reactive value so the
/// body ([IndexedStack]) and the [BottomNavigationBar] can be driven by
/// `Obx` instead of `StatefulWidget` + `setState`.
class MainNavController extends GetxController {
  final RxInt currentIndex = 0.obs;

  void setIndex(int index) => currentIndex.value = index;
}
