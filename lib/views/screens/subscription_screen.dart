import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/views/screens/plan_selection_screen.dart';

/// Settings → subscription management: shows the current plan, its status and
/// dates, lets the owner refresh the status and upgrade/change the plan.
class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  String _statusKey(String s) {
    switch (s) {
      case 'active':
        return 'status_active';
      case 'pending':
        return 'status_pending';
      case 'rejected':
        return 'status_rejected';
      case 'expired':
        return 'status_expired';
      default:
        return 'status_none';
    }
  }

  Color _statusColor(String s) {
    switch (s) {
      case 'active':
        return Colors.green;
      case 'pending':
        return Colors.orange;
      case 'rejected':
      case 'expired':
        return Colors.red;
      default:
        return Colors.blueGrey;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthController auth = Get.find();
    return Scaffold(
      backgroundColor: const Color(0xFFE3F2FD),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1565C0),
        iconTheme: const IconThemeData(color: Colors.white),
        centerTitle: true,
        elevation: 0,
        title: Text(
          'subscription'.tr,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'check_status'.tr,
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await auth.refreshSubscription();
              Get.snackbar('subscription'.tr, 'status_refreshed'.tr);
            },
          ),
        ],
      ),
      body: SafeArea(child: Obx(() {
        final sub = auth.subscription;
        final status = sub?.status ?? 'none';
        final color = _statusColor(status);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.withValues(alpha: 0.05),
                    blurRadius: 10,
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.workspace_premium, color: color),
                      const SizedBox(width: 8),
                      Text(
                        'current_plan'.tr,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  _row('current_plan'.tr, sub?.planCode ?? 'no_active_plan'.tr),
                  _row('plan_status'.tr, _statusKey(status).tr,
                      valueColor: color),
                  if (sub?.startedAt != null)
                    _row('plan_started'.tr, sub!.startedAt!.split('T').first),
                  if (sub?.expiresAt != null)
                    _row('plan_expires'.tr, sub!.expiresAt!.split('T').first),
                ],
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Get.to(() => const PlanSelectionScreen()),
                icon: const Icon(Icons.upgrade),
                label: Text('upgrade_change_plan'.tr),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        );
      })),
    );
  }

  Widget _row(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: TextStyle(fontWeight: FontWeight.w600, color: valueColor),
            ),
          ),
        ],
      ),
    );
  }
}
