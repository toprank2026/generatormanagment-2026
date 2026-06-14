import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/subscription_controller.dart';
import 'package:generatormanagment/data/models/plan.dart';

/// Shown by the root gate when the account has no active subscription.
/// Lists plans, shows pending/rejected status, lets the owner request a plan,
/// and offers a manual re-check (after admin approval). Also polls the server
/// every ~12s (online-gated inside [AuthController.refreshSubscription]) so an
/// admin approval is auto-detected and the root gate swaps to the main screen
/// without any user action.
class PlanSelectionScreen extends StatefulWidget {
  const PlanSelectionScreen({super.key});

  @override
  State<PlanSelectionScreen> createState() => _PlanSelectionScreenState();
}

class _PlanSelectionScreenState extends State<PlanSelectionScreen> {
  Timer? _pollTimer;
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _refreshOnce(); // immediate check on screen open
    _pollTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => _refreshOnce(),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  /// Auto-poll tick: skipped while a previous refresh is still running.
  Future<void> _refreshOnce() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      await Get.find<AuthController>().refreshSubscription();
    } finally {
      _refreshing = false;
    }
  }

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
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.autorenew, size: 14, color: Colors.grey[500]),
                  const SizedBox(width: 6),
                  Text(
                    'auto_checking_approval'.tr,
                    style: TextStyle(color: Colors.grey[500], fontSize: 12),
                  ),
                ],
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
                SizedBox(
                  height: 450,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: controller.plans.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, i) {
                      final p = controller.plans[i];
                      return _PlanCard(
                        plan: p,
                        isCurrent: sub?.planCode == p.code,
                        onSelect: () => _confirm(controller, p),
                      );
                    },
                  ),
                ),
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
    const blue = Color(0xFF1565C0);
    return Container(
      width: 250,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isCurrent ? blue : Colors.transparent,
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.blue.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.workspace_premium, color: blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  plan.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            plan.price > 0 ? '${plan.price}' : '0',
            style: const TextStyle(
                fontSize: 30, fontWeight: FontWeight.bold, color: blue),
          ),
          Text('iqd'.tr, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          const SizedBox(height: 14),
          _feature(Icons.calendar_today, '${plan.durationDays} ${'days'.tr}'),
          const SizedBox(height: 6),
          _feature(Icons.devices, '${plan.maxDevices} ${'devices'.tr}'),
          const SizedBox(height: 10),
          // Per-plan capability marks: green check when this plan includes the
          // feature, dimmed red cross when it doesn't (mirrors the per-plan
          // flags the backend returns for each plan, not the current account).
          _capability(Icons.sync, 'feature_sync'.tr, plan.syncEnabled),
          _capability(Icons.backup, 'feature_backup'.tr, plan.backupEnabled),
          _capability(Icons.admin_panel_settings, 'feature_owner_panel'.tr,
              plan.ownerPanelEnabled),
          const SizedBox(height: 4),
          if (plan.description != null && plan.description!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Expanded(
              child: Text(
                plan.description!,
                style: TextStyle(color: Colors.grey[700], fontSize: 12),
                overflow: TextOverflow.fade,
              ),
            ),
          ] else
            const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onSelect,
              style: FilledButton.styleFrom(
                backgroundColor: blue,
                padding: const EdgeInsets.symmetric(vertical: 12),
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

  Widget _feature(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey[500]),
        const SizedBox(width: 8),
        Text(text, style: TextStyle(color: Colors.grey[700], fontSize: 13)),
      ],
    );
  }

  /// One capability row: a leading feature-type icon + label, with a trailing
  /// green check (included) or dimmed red cross (excluded). The excluded row is
  /// faded and struck through so the on/off state reads without relying on
  /// colour alone. Colours/icons match the app's paid/unpaid convention.
  Widget _capability(IconData icon, String label, bool included) {
    const green = Color(0xFF2E7D32);
    const red = Color(0xFFD32F2F);
    return Opacity(
      opacity: included ? 1 : 0.6,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Icon(icon,
                size: 16,
                color: included ? const Color(0xFF1565C0) : Colors.grey),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  color: included ? Colors.grey[800] : Colors.grey[600],
                  decoration:
                      included ? null : TextDecoration.lineThrough,
                  decorationColor: red,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(included ? Icons.check_circle : Icons.cancel,
                size: 18, color: included ? green : red),
          ],
        ),
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
