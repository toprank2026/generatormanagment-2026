import 'package:get/get.dart';
import 'package:intl/intl.dart';

/// Global selected-month context (R9). A SINGLE source of truth for the billing
/// month, mirroring [BranchController]: it is `permanent` so it is established
/// from launch, and every feature controller reacts to it via `ever()`.
///
/// The month is MUTATED only from the Monthly Pricing screen (the sole month
/// selector). Every other screen — the dashboard banner, subscriber detail,
/// payment history — reads it READ-ONLY and re-binds when it changes, so the
/// whole app stays synchronized on one month. A subscriber opened from Home
/// therefore uses exactly the month shown on Home (R6).
///
/// Not persisted across restarts: the app launches on the current calendar
/// month each time (acceptable per spec).
class MonthController extends GetxController {
  /// `yyyy-MM`. The one selected month used everywhere.
  final RxString selectedMonth =
      DateFormat('yyyy-MM').format(DateTime.now()).obs;

  /// Set the global month. The ONLY mutation entry point — called from the
  /// Monthly Pricing screen. No-op if unchanged so reactive loaders don't
  /// double-fire.
  void setMonth(String month) {
    if (month == selectedMonth.value) return;
    selectedMonth.value = month;
    update();
  }
}
