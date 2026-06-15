import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/branch_controller.dart';
import 'package:generatormanagment/controllers/billing_controller.dart';
import 'package:generatormanagment/controllers/core_controller.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';
import 'package:generatormanagment/controllers/expense_controller.dart';
import 'package:generatormanagment/controllers/reports_controller.dart';
import 'package:generatormanagment/controllers/settings_controller.dart';
import 'package:generatormanagment/controllers/subscription_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';

/// Central dependency injection — replaces the scattered per-screen `Get.put`.
/// Screens use `Get.find<XController>()`.
///
/// - [AuthController] is permanent (drives the root gate from launch).
/// - Feature controllers are lazy + `fenix` so they are created on first use
///   and re-created if disposed, while staying singletons across screens.
class AppBinding extends Bindings {
  @override
  void dependencies() {
    Get.put<AuthController>(AuthController(), permanent: true);
    // Branch context (active branch / consolidated) — permanent so the active
    // branch is established from launch and every feature controller can scope.
    Get.put<BranchController>(BranchController(), permanent: true);
    Get.put<SyncController>(SyncController(), permanent: true);

    Get.lazyPut<CoreController>(() => CoreController(), fenix: true);
    Get.lazyPut<DashboardController>(() => DashboardController(), fenix: true);
    Get.lazyPut<BillingController>(() => BillingController(), fenix: true);
    Get.lazyPut<ExpenseController>(() => ExpenseController(), fenix: true);
    Get.lazyPut<ReportsController>(() => ReportsController(), fenix: true);
    Get.lazyPut<SettingsController>(() => SettingsController(), fenix: true);
    Get.lazyPut<SubscriptionController>(() => SubscriptionController(), fenix: true);
  }
}
