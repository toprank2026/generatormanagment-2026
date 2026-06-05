import 'package:generatormanagment/core/api_client.dart';
import 'package:generatormanagment/core/api_config.dart';
import 'package:generatormanagment/data/models/account.dart';
import 'package:generatormanagment/data/models/plan.dart';

/// Backend subscription/plan operations. Online-only by nature.
class SubscriptionRepository {
  final ApiClient _api = ApiClient();

  Future<List<Plan>> getPlans() async {
    final res = await _api.get(ApiConfig.plans, auth: false);
    final list = (res is Map ? res['plans'] : res) as List? ?? const [];
    return list
        .whereType<Map<String, dynamic>>()
        .map(Plan.fromJson)
        .toList();
  }

  Future<Subscription> getSubscription() async {
    final res = await _api.get(ApiConfig.subscription);
    final j = (res is Map ? res['subscription'] : res) as Map<String, dynamic>?;
    return Subscription.fromJson(j);
  }

  Future<Subscription> requestPlan(String planCode) async {
    final res = await _api.post(
      ApiConfig.subscriptionRequest,
      body: {'planCode': planCode},
    );
    final j = (res is Map ? res['subscription'] : res) as Map<String, dynamic>?;
    return Subscription.fromJson(j);
  }
}
