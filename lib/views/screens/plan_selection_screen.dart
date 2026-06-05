import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/subscription_controller.dart';
import 'package:generatormanagment/data/models/plan.dart';

/// Shown by the root gate when the account has no active subscription.
/// Lists plans, shows pending/rejected status, lets the owner request a plan,
/// and offers a manual re-check (after admin approval).
class PlanSelectionScreen extends StatelessWidget {
  const PlanSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final SubscriptionController controller = Get.find();
    final AuthController auth = Get.find();

    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        title: Text('subscription'.tr,
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: const Color(0xFF1565C0),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'logout'.tr,
            icon: const Icon(Icons.logout, color: Colors.white),
            onPressed: auth.logout,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await controller.loadPlans();
          await auth.refreshSubscription();
        },
        child: Obx(() {
          final sub = auth.subscription;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _StatusBanner(
                status: sub?.status ?? 'none',
                planCode: sub?.planCode,
              ),
              const SizedBox(height: 16),
              if (controller.isLoading.value)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (controller.error.value != null)
                _ErrorBox(
                  message: controller.error.value!,
                  onRetry: controller.loadPlans,
                )
              else if (controller.plans.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Center(child: Text('no_plans'.tr)),
                )
              else
                ...controller.plans.map((p) => _PlanCard(
                      plan: p,
                      isCurrent: sub?.planCode == p.code,
                      onSelect: () => _confirm(controller, p),
                    )),
              const SizedBox(height: 24),
              TextButton.icon(
                onPressed: () async {
                  await auth.refreshSubscription();
                  Get.snackbar('subscription'.tr, 'status_refreshed'.tr);
                },
                icon: const Icon(Icons.refresh),
                label: Text('check_status'.tr),
              ),
            ],
          );
        }),
      ),
    );
  }

  void _confirm(SubscriptionController controller, Plan plan) {
    Get.defaultDialog(
      title: 'confirm'.tr,
      middleText: '${'request_plan_confirm'.tr} "${plan.name}"?',
      textConfirm: 'confirm'.tr,
      textCancel: 'cancel'.tr,
      confirmTextColor: Colors.white,
      buttonColor: const Color(0xFF1565C0),
      onConfirm: () {
        Get.back();
        controller.requestPlan(plan.code);
      },
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final String status;
  final String? planCode;
  const _StatusBanner({required this.status, this.planCode});

  @override
  Widget build(BuildContext context) {
    late final Color color;
    late final IconData icon;
    late final String text;
    switch (status) {
      case 'pending':
        color = Colors.orange;
        icon = Icons.hourglass_top;
        text = 'subscription_pending'.tr;
        break;
      case 'rejected':
        color = Colors.red;
        icon = Icons.cancel;
        text = 'subscription_rejected'.tr;
        break;
      case 'expired':
        color = Colors.red;
        icon = Icons.timer_off;
        text = 'subscription_expired'.tr;
        break;
      default:
        color = Colors.blueGrey;
        icon = Icons.info_outline;
        text = 'subscription_required'.tr;
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  final Plan plan;
  final bool isCurrent;
  final VoidCallback onSelect;
  const _PlanCard({
    required this.plan,
    required this.isCurrent,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(plan.name,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              if (plan.price > 0)
                Text('${plan.price}',
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1565C0))),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${plan.durationDays} ${'days'.tr} • ${plan.maxDevices} ${'devices'.tr}',
            style: TextStyle(color: Colors.grey[600], fontSize: 13),
          ),
          if (plan.description != null && plan.description!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(plan.description!,
                style: TextStyle(color: Colors.grey[700], fontSize: 13)),
          ],
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onSelect,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1565C0),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(isCurrent ? 'renew'.tr : 'choose_plan'.tr),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 24),
        Icon(Icons.wifi_off, size: 56, color: Colors.grey[400]),
        const SizedBox(height: 12),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: onRetry,
          icon: const Icon(Icons.refresh),
          label: Text('retry'.tr),
        ),
      ],
    );
  }
}
