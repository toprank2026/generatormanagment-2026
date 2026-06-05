import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/connectivity_service.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/models/plan.dart';
import 'package:generatormanagment/data/repositories/subscription_repository.dart';

/// Drives the plan-selection screen: lists plans (online), shows current
/// subscription status, and requests a plan (→ pending until admin approves).
class SubscriptionController extends GetxController {
  final SubscriptionRepository _repo = SubscriptionRepository();
  final ConnectivityService _net = ConnectivityService();

  final plans = <Plan>[].obs;
  final isLoading = false.obs;
  final isRequesting = false.obs;
  final error = RxnString();

  Subscription? get current => Get.find<AuthController>().subscription;

  @override
  void onReady() {
    super.onReady();
    loadPlans();
  }

  Future<void> loadPlans() async {
    isLoading.value = true;
    error.value = null;
    try {
      if (!await _net.isOnline()) {
        error.value = 'You are offline. Connect to load plans.';
      } else {
        plans.assignAll(await _repo.getPlans());
      }
    } on ApiException catch (e) {
      error.value = e.message;
    } catch (e) {
      error.value = '$e';
    } finally {
      isLoading.value = false;
      update();
    }
  }

  /// Requests a plan, then refreshes the account so the gate re-evaluates.
  Future<bool> requestPlan(String planCode) async {
    isRequesting.value = true;
    try {
      await _repo.requestPlan(planCode);
      await Get.find<AuthController>().refreshSubscription();
      Get.snackbar('success'.tr, 'plan_requested'.tr);
      return true;
    } on ApiException catch (e) {
      Get.snackbar('error'.tr, e.message);
      return false;
    } catch (e) {
      Get.snackbar('error'.tr, '$e');
      return false;
    } finally {
      isRequesting.value = false;
      update();
    }
  }
}
