import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:generatormanagment/controllers/dashboard_controller.dart';
import 'package:generatormanagment/controllers/auth_controller.dart';
import 'package:generatormanagment/controllers/sync_controller.dart';
import 'package:generatormanagment/views/widgets/shimmer_loading.dart';
import 'package:generatormanagment/views/screens/subscribers_screen.dart';
import 'package:generatormanagment/views/screens/boards_screen.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final DashboardController controller = Get.find<DashboardController>();
    final AuthController authController = Get.find<AuthController>();
    final SyncController syncController = Get.find<SyncController>();

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(
          'dashboard'.tr,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        elevation: 0,
      ),
      body: RefreshIndicator(
        onRefresh: () => controller.loadStats(),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Banner / Carousel Placeholder
              Container(
                height: 210,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: LinearGradient(
                    colors: [Colors.blue.shade800, Colors.blue.shade400],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: Stack(
                  children: [
                    // Background Pattern
                    Positioned(
                      right: -30,
                      top: -30,
                      child: Icon(
                        Icons.flash_on,
                        size: 150,
                        color: Colors.white.withOpacity(0.15),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: 20,
                      top: 20,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              shape: BoxShape.circle,
                            ),
                            child: const CircleAvatar(
                              radius: 30,
                              backgroundColor: Colors.white,
                              child: Icon(
                                Icons.person,
                                size: 35,
                                color: Color(0xFF1565C0),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                // Account (icon + data)
                                _bannerRow(
                                  Icons.phone_android,
                                  Obx(
                                    () => Text(
                                      authController
                                              .currentUser.value?.username
                                              .toUpperCase() ??
                                          'ADMIN',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.0,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                // Current plan name (icon + data)
                                _bannerRow(
                                  Icons.workspace_premium,
                                  Obx(() {
                                    final plan = authController.account.value
                                        ?.subscription.planCode;
                                    return Text(
                                      (plan == null || plan.isEmpty)
                                          ? 'no_plan'.tr
                                          : plan.toUpperCase(),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    );
                                  }),
                                ),
                                const SizedBox(height: 10),
                                // Unsynced count + immediate sync button
                                Obx(() {
                                  final pending =
                                      syncController.pendingCount.value;
                                  final syncing =
                                      syncController.isSyncing.value;
                                  return Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.2),
                                          borderRadius:
                                              BorderRadius.circular(8),
                                        ),
                                        child: Icon(
                                          syncing
                                              ? Icons.sync
                                              : (pending == 0
                                                  ? Icons.cloud_done
                                                  : Icons.cloud_upload),
                                          color: Colors.white,
                                          size: 16,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          syncing
                                              ? 'syncing'.tr
                                              : (pending == 0
                                                  ? 'all_synced'.tr
                                                  : '$pending ${'sync_pending'.tr}'),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      SizedBox(
                                        height: 30,
                                        child: ElevatedButton.icon(
                                          onPressed: syncing
                                              ? null
                                              : () => syncController.syncNow(),
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.white,
                                            foregroundColor:
                                                const Color(0xFF1565C0),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12),
                                            shape: RoundedRectangleBorder(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            textStyle: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold),
                                          ),
                                          icon: syncing
                                              ? const SizedBox(
                                                  width: 14,
                                                  height: 14,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    valueColor:
                                                        AlwaysStoppedAnimation(
                                                            Color(0xFF1565C0)),
                                                  ),
                                                )
                                              : const Icon(Icons.sync, size: 16),
                                          label: Text('sync_now'.tr),
                                        ),
                                      ),
                                    ],
                                  );
                                }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Stats Grid
              Text(
                'overview'.tr,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              Obx(() {
                if (controller.isLoading.value) {
                  return const DashboardShimmer();
                }

                return GetBuilder<DashboardController>(
                  builder: (ctrl) => GridView.count(
                    crossAxisCount: 2,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 1.3,
                    children: [
                      _buildStatCard(
                        icon: Icons.people,
                        color: Colors.blue,
                        label: 'total_subscribers'.tr,
                        value: ctrl.totalSubscribers.value.toString(),
                        onTap: () => Get.to(() => const SubscribersScreen()),
                      ),
                      _buildStatCard(
                        icon: Icons.check_circle,
                        color: Colors.green,
                        label: 'paid_subscribers'.tr,
                        value: ctrl.paidCount.value.toString(),
                        onTap: () => Get.to(
                          () => const SubscribersScreen(filter: 'paid'),
                        ),
                      ),
                      _buildStatCard(
                        icon: Icons.pending_actions,
                        color: Colors.redAccent,
                        label: 'unpaid_subscribers'.tr,
                        value: ctrl.unpaidCount.value.toString(),
                        onTap: () => Get.to(
                          () => const SubscribersScreen(filter: 'unpaid'),
                        ),
                      ),
                      _buildStatCard(
                        icon: Icons.grid_view,
                        color: Colors.indigo,
                        label: 'total_boards'.tr,
                        value: ctrl.boardsCount.value.toString(),
                        onTap: () => Get.to(() => const BoardsScreen()),
                      ),
                      _buildStatCard(
                        icon: Icons.settings_input_component,
                        color: Colors.cyan,
                        label: 'total_circuits'.tr,
                        value: ctrl.circuitsCount.value.toString(),
                        onTap: () =>
                            Get.to(() => const BoardsScreen(forCircuits: true)),
                      ),
                      _buildStatCard(
                        icon: Icons.electric_bolt,
                        color: Colors.orange,
                        label: 'amps'.tr,
                        value: ctrl.totalAmps.value.toStringAsFixed(1),
                      ),
                      _buildStatCard(
                        icon: Icons.account_balance_wallet,
                        color: Colors.green,
                        label: 'collected_revenue'.tr,
                        value: ctrl.totalCollected.value.toStringAsFixed(0),
                      ),
                      _buildStatCard(
                        icon: Icons.monetization_on,
                        color: Colors.redAccent,
                        label: 'remaining_fees'.tr,
                        value: ctrl.totalDue.value.toStringAsFixed(0),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  /// One "icon + data" row for the dashboard header column.
  Widget _bannerRow(IconData icon, Widget data) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(icon, color: Colors.white, size: 16),
        ),
        const SizedBox(width: 10),
        Expanded(child: data),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    VoidCallback? onTap,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),

      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: color),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        value,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      label,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
